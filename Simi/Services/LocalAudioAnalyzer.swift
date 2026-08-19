// LocalAudioAnalyzer.swift
// Simi — Music Discovery App
//
// On-device DSP analysis producing full AudioFeatures from preview audio bytes.
// No network calls — runs in ~100-200ms per song using vDSP/Accelerate.
//
// Feature quality:
//   Measured (isEstimated=false): BPM, energy, key/mode, spectral warmth, ZCR, rolloff,
//                                  tonal clarity, chroma entropy, vocal presence, reverb space
//   Proxied (derived, not ground truth): valence, danceability, acousticness, arousal, instrumentalness, liveness
//   Missing (needs DEAM neural model): valenceEssentia — Stage 2 HF overwrites arousal + fills this
//
// Calling pattern: Priority 2 in enrichWithABFeatures after Supabase cache miss.
// All N candidates are analyzed in the existing TaskGroup (parallel).
// Stage 2 (HF Spaces) still runs for top candidates where arousal == nil.

import Foundation
import AVFoundation
import Accelerate

final class LocalAudioAnalyzer: @unchecked Sendable {

    static let shared = LocalAudioAnalyzer()
    private init() {}

    private let fftSize = 2048
    private let hopSize = 512
    private let nMels   = 128   // matches librosa n_mels default for pipeline compatibility
    private let nMFCC   = 20    // matches HF backend output length (20-coeff vectors)

    // Krumhansl-Kessler tonal hierarchy profiles (C-rooted, same as PreviewAudioAnalyzer)
    private let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                                           2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                                           2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    // Genre → expected BPM range (felt quarter-note pulse).
    // Used to rank multiple autocorrelation peaks when octave ambiguity exists —
    // e.g. a bolero peaking at both 75 and 150 BPM chooses 75 because "latin" → 70–120.
    // Hörschläger et al. (2015) showed this approach lifts tempo accuracy from ~45% to ~75%
    // on styles with strong genre-tempo relationships (electronic/dance, Latin, R&B).
    private let genreBPMRanges: [String: ClosedRange<Double>] = [
        // Very slow / half-time feel
        "bolero":           55...90,
        "danzon":           55...90,
        "danzón":           55...90,
        "rumba":            60...105,
        "ballad":           55...85,
        "slow jam":         55...90,
        "gospel":           60...100,
        "blues":            60...105,
        "ambient":          50...100,
        "downtempo":        60...95,
        "trip hop":         70...95,
        "lo-fi":            65...100,
        "lofi":             65...100,
        "chillout":         70...100,
        "chill out":        70...100,
        "trap soul":        65...90,
        "vaporwave":        70...100,
        // Latin
        "bossa nova":       70...120,
        "latin":            70...120,
        "cumbia":           80...115,
        "bachata":          104...132,
        "reggaeton":        85...105,
        "salsa":            80...110,   // felt clave pulse
        "merengue":         120...160,
        // R&B / Soul / Funk
        "r&b":              70...115,
        "rnb":              70...115,
        "soul":             70...110,
        "neo-soul":         70...105,
        "neo soul":         70...105,
        "funk":             90...120,
        "motown":           90...125,
        "disco":            108...130,
        // Hip-hop
        "boom bap":         80...100,
        "hip-hop":          80...115,
        "hip hop":          80...115,
        "rap":              80...115,
        "trap":             130...160,
        "drill":            130...160,
        "grime":            135...145,
        "phonk":            125...145,
        "cloud rap":        125...145,
        // Electronic
        "deep house":       118...130,
        "house":            118...135,
        "techno":           128...148,
        "trance":           128...148,
        "edm":              120...140,
        "drum and bass":    160...185,
        "dnb":              160...185,
        "dubstep":          135...145,
        "hardstyle":        140...175,
        "rave":             140...175,
        "breakcore":        155...200,
        "future bass":      130...160,
        "electro":          125...135,
        "synth-pop":        100...130,
        "synth pop":        100...130,
        "chillwave":        85...110,
        // Rock / Metal / Punk
        "metal":            140...200,
        "punk":             150...200,
        "pop punk":         150...190,
        "hard rock":        115...160,
        "grunge":           90...140,
        "indie rock":       90...135,
        "alternative":      90...135,
        "rock":             90...145,
        "shoegaze":         90...130,
        // Other
        "reggae":           60...90,
        "dancehall":        85...110,
        "ska":              130...165,
        "afrobeats":        90...115,
        "afropop":          95...115,
        "amapiano":         105...120,
        "folk":             80...125,
        "country":          90...130,
        "pop":              90...135,
        "k-pop":            100...135,
        "indie pop":        90...130,
        "bedroom pop":      85...115,
        "dream pop":        85...120,
    ]

    // MARK: - Genre BPM Helpers

    /// Finds the narrowest matching BPM range for a set of genre hint strings.
    /// Longest keyword wins to prevent "pop" matching before "k-pop" or "indie pop".
    private func genreRange(for hints: [String]) -> ClosedRange<Double>? {
        let sorted = genreBPMRanges.keys.sorted { $0.count > $1.count }
        for hint in hints {
            let h = hint.lowercased()
            if let range = genreBPMRanges[h] { return range }
            if let key = sorted.first(where: { h.contains($0) || $0.contains(h) }),
               let range = genreBPMRanges[key] { return range }
        }
        return nil
    }

    /// Soft affinity score [0–1] for how well a BPM fits a genre range.
    /// 1.0 inside the range, decays linearly to 0 at 2× the range width outside.
    private func genreAffinity(_ bpm: Double, range: ClosedRange<Double>) -> Double {
        if range.contains(bpm) { return 1.0 }
        let width = max(range.upperBound - range.lowerBound, 20.0)
        let dist  = bpm < range.lowerBound ? range.lowerBound - bpm : bpm - range.upperBound
        return max(0.0, 1.0 - dist / width)
    }

    // MARK: - Public API

    /// Analyzes pre-downloaded audio bytes. Returns nil only on AVFoundation decode failure.
    /// buildFeatures is dispatched onto a GCD .utility thread so the OS can preempt it
    /// in favour of the main thread without requiring cooperative yield points inside the
    /// DSP loop. Task.yield() inside a cooperative-pool task doesn't give the OS real
    /// thread-priority information — GCD QoS does.
    ///
    /// Two-window analysis: for previews ≥20 s, the second half ("body") is also analyzed.
    /// When the body is meaningfully more energetic than the full signal, the body's energy,
    /// BPM, valence, danceability, and arousal replace the full-signal values. This corrects
    /// quiet-intro deflation (Don't Stop 'Til You Get Enough, Billie Jean, Eye of the Tiger)
    /// without touching MFCC, chroma, loudness, or liveness — features that benefit from the
    /// larger sample window.
    func analyze(data: Data, sourceURL: String, title: String = "", genreHints: [String] = []) async -> AudioFeatures? {
        guard let (samples, sampleRate) = loadPCM(from: data, sourceURL: sourceURL) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let full = self.buildFeatures(samples: samples, sampleRate: sampleRate, title: title, genreHints: genreHints)

                // Only worth the extra pass when there's enough body to analyze.
                let minBodySamples = Int(sampleRate * 20)
                guard samples.count > minBodySamples else {
                    continuation.resume(returning: full)
                    return
                }

                let halfPoint   = samples.count / 2
                let bodySamples = Array(samples[halfPoint...])
                let body        = self.buildFeatures(samples: bodySamples, sampleRate: sampleRate, title: "", genreHints: genreHints)

                // Swap hot features only when body is meaningfully more energetic.
                // 0.08 gap catches quiet intros while leaving consistent-energy songs unchanged.
                guard body.energy > full.energy + 0.08 else {
                    continuation.resume(returning: full)
                    return
                }

                #if DEBUG
                simiLog("🎵 Two-window '\(title)': body e=\(String(format:"%.2f", body.energy)) bpm=\(Int(body.bpm)) > full e=\(String(format:"%.2f", full.energy)) bpm=\(Int(full.bpm)) — using body for hot features")
                #endif

                var result        = full
                result.energy     = body.energy
                result.bpm        = body.bpm
                result.valence    = body.valence
                result.danceability = body.danceability
                result.arousal    = body.arousal
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - PCM Loading

    private func loadPCM(from data: Data, sourceURL: String) -> (samples: [Float], sampleRate: Double)? {
        let ext = sourceURL.lowercased().hasSuffix(".m4a") ? "m4a" : "mp3"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        do { try data.write(to: tempURL) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let audioFile = try? AVAudioFile(forReading: tempURL,
                                               commonFormat: .pcmFormatFloat32,
                                               interleaved: false) else { return nil }

        let sampleRate = audioFile.fileFormat.sampleRate
        // Cap at 60s to capture more of the song when a longer clip is available.
        // Typical Apple/Deezer previews are 30s, so this cap mainly helps non-preview sources.
        let frameCount = AVAudioFrameCount(min(audioFile.length, AVAudioFramePosition(sampleRate * 60)))
        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        guard (try? audioFile.read(into: buffer)) != nil else { return nil }
        guard let channelData = buffer.floatChannelData else { return nil }

        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)

        // Mix down to mono
        var mono = [Float](repeating: 0, count: frames)
        for ch in 0..<channels {
            vDSP_vadd(mono, 1, channelData[ch], 1, &mono, 1, vDSP_Length(frames))
        }
        if channels > 1 {
            var scale = Float(1.0 / Float(channels))
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames))
        }
        return (mono, sampleRate)
    }

    // MARK: - Feature Computation

    private struct FrameResult {
        let centroid:      Double
        let chroma:        [Double]
        let magnitudes:    [Float]
        let totalEnergy:   Double
        let lowMidEnergy:  Double   // 100–2000 Hz — spectral warmth driver
        let midBandEnergy: Double   // 300–3000 Hz — vocal presence proxy
        let subBassEnergy: Double   // 50–200 Hz — kick drum fundamental band
        let flatness:      Double   // geometric/arithmetic mean ratio
        let hfFlatness:    Double   // same, 2 kHz+; -1 when no HF bins
        let rolloffBin:    Double   // bin index at 85th-percentile energy
    }

    private func buildFeatures(samples: [Float], sampleRate: Double, title: String, genreHints: [String] = []) -> AudioFeatures {
        let log2n = vDSP_Length(log2(Double(fftSize)))
        let window = makeHannWindow()
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return fallbackFeatures()
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let binHz = sampleRate / Double(fftSize)

        // Mel filterbank built once per call (depends on sampleRate)
        let filterbank = buildMelFilterbank(sampleRate: sampleRate)

        // Frame-by-frame accumulators
        var chromaAccum      = [Double](repeating: 0, count: 12)
        var melLogAccum      = [Float](repeating: 0, count: nMels)
        var melLogAccumSq    = [Float](repeating: 0, count: nMels)   // E[X²] for online variance
        var centroids:        [Double] = []
        var onsetFlux:        [Float]  = []
        var subBassFlux:      [Float]  = []
        var prevMagnitudes:   [Float]? = nil
        var prevSubBassEnergy: Double  = -1   // -1 = not yet seen

        var totalEnergySum    = 0.0
        var lowMidEnergySum   = 0.0
        var midBandEnergySum  = 0.0
        var flatnessSum       = 0.0
        var hfFlatnessSum     = 0.0
        var hfFlatnessCount   = 0
        var rolloffBinSum     = 0.0
        var frameCount        = 0
        var maxFrameEnergy    = 0.0
        var minNonsilentEnergy = Double.infinity   // for dynamic range → liveness proxy
        var chromaFluxSum     = 0.0               // L1 distance between consecutive chroma frames → harmonic rhythm
        var prevChromaFrame:   [Double]? = nil

        // Skip the first 5 s of clips longer than 25 s to avoid fade-ins and intros.
        // Apple/Deezer previews are often curated to start at the hook, so the skip
        // only fires for full-song sources where an extended intro is likely.
        let introSkip = samples.count > Int(sampleRate * 25) ? Int(sampleRate * 5) : 0
        var offset = introSkip
        while offset + fftSize <= samples.count {
            let r = analyzeFrame(at: offset, samples: samples, window: window,
                                 fftSetup: fftSetup, log2n: log2n, binHz: binHz)
            centroids.append(r.centroid)
            for i in 0..<12 { chromaAccum[i] += r.chroma[i] }
            if let prev = prevChromaFrame {
                chromaFluxSum += zip(prev, r.chroma).reduce(0.0) { $0 + abs($1.0 - $1.1) }
            }
            prevChromaFrame = r.chroma
            totalEnergySum   += r.totalEnergy
            lowMidEnergySum  += r.lowMidEnergy
            midBandEnergySum += r.midBandEnergy
            flatnessSum      += r.flatness
            if r.hfFlatness >= 0 { hfFlatnessSum += r.hfFlatness; hfFlatnessCount += 1 }
            rolloffBinSum    += r.rolloffBin
            frameCount       += 1
            if r.totalEnergy > maxFrameEnergy { maxFrameEnergy = r.totalEnergy }
            if r.totalEnergy > 1e-6 && r.totalEnergy < minNonsilentEnergy { minNonsilentEnergy = r.totalEnergy }

            // Mel filterbank: power spectrum → log → accumulate mean + sum-of-squares for std
            let melEnergies = applyMelFilterbank(r.magnitudes, filterbank: filterbank)
            for m in 0..<nMels {
                let logE = log(max(melEnergies[m], 1e-10))
                melLogAccum[m]   += logE
                melLogAccumSq[m] += logE * logE
            }

            // Spectral flux onset envelope: only positive magnitude differences
            if let prev = prevMagnitudes {
                var flux: Float = 0
                let n = r.magnitudes.count
                for i in 0..<n {
                    let diff = r.magnitudes[i] - prev[i]
                    if diff > 0 { flux += diff }
                }
                onsetFlux.append(flux)
            }
            prevMagnitudes = r.magnitudes

            // Sub-bass onset flux (50–200 Hz kick band) — onset-only (positive differences only).
            // Skip first frame (prevSubBassEnergy == -1) so arrays stay the same length as onsetFlux.
            if prevSubBassEnergy >= 0 {
                let diff = Float(r.subBassEnergy - prevSubBassEnergy)
                subBassFlux.append(max(0, diff))
            }
            prevSubBassEnergy = r.subBassEnergy

            offset += hopSize
        }

        guard frameCount > 0 else { return fallbackFeatures() }

        // ── MFCC mean + std ────────────────────────────────────────────────
        // mean: DCT(mean(X)) == mean(DCT(X)) since DCT is linear — compute mean first, DCT once.
        // std:  online variance from accumulated X and X² — Var = E[X²] - E[X]².
        //       std captures timbral consistency: trap 808 loops → low std; live drums → high std.
        // Both L2-normalized so cosine comparison is scale-invariant.
        let melLogMean = melLogAccum.map { $0 / Float(frameCount) }
        let mfccMean   = l2Normalize(dctII(melLogMean, nCoeffs: nMFCC))

        let melLogStd  = (0..<nMels).map { m -> Float in
            let variance = melLogAccumSq[m] / Float(frameCount) - melLogMean[m] * melLogMean[m]
            return sqrt(max(0, variance))
        }
        let mfccStd    = l2Normalize(dctII(melLogStd, nCoeffs: nMFCC))

        // ── Harmonic rhythm (chroma flux) ─────────────────
        // Average L1 distance between consecutive normalized chroma frames.
        // Fast chord changes (0.35+ avg L1) = upbeat/positive music.
        // Static/drone harmony (~0.0) = sustained, ambient, or melancholic.
        let avgChromaFlux = frameCount > 1 ? chromaFluxSum / Double(frameCount - 1) : 0.0
        let harmonicRhythm = min(1.0, avgChromaFlux / 0.35)

        // ── RMS energy + loudness ──────────────────────────
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let energy   = min(1.0, max(0.0, Double(rms) / 0.5))
        let loudness = rms > 0 ? max(-60.0, min(0.0, 20.0 * log10(Double(rms)))) : -60.0

        // ── ZCR ───────────────────────────────────────────
        let zcr = computeZCR(samples: samples)

        // ── Chroma → key/mode/confidence ──────────────────
        let chromaTotal = chromaAccum.reduce(0, +)
        let normChroma  = chromaTotal > 0 ? chromaAccum.map { $0 / chromaTotal } :
                          [Double](repeating: 1.0 / 12, count: 12)
        let (detectedKey, detectedMode, modeConf) = findKey(chroma: normChroma)

        // ── Spectral averages ──────────────────────────────
        let avgBrightness  = centroids.reduce(0, +) / Double(centroids.count)
        let avgFlatness    = flatnessSum / Double(frameCount)
        let avgHFFlatness  = hfFlatnessCount > 0 ? hfFlatnessSum / Double(hfFlatnessCount) : 0.5
        let avgRolloffBin  = rolloffBinSum / Double(frameCount)
        let rolloffNorm    = min(1.0, (avgRolloffBin * binHz) / (sampleRate / 2.0))

        let safeTotal      = max(totalEnergySum, 1e-9)
        let spectralWarmth = min(1.0, lowMidEnergySum / safeTotal)
        let vocalPresence  = min(1.0, midBandEnergySum / safeTotal)

        // ── BPM ───────────────────────────────────────────
        let fps = sampleRate / Double(hopSize)
        let bpm = estimateBPM(onsetFlux: onsetFlux, subBassFlux: subBassFlux, fps: fps, genreHints: genreHints)

        // ── Derived perceptual features ───────────────────
        let zcrNorm = min(1.0, zcr / 0.20)     // 0.20 ≈ typical speech ZCR ceiling

        // Acousticness: tonal + warm-spectrum + non-bright → acoustic guitar, piano
        let acousticness = min(1.0, max(0.0,
            0.50 * (1.0 - avgFlatness) +
            0.30 * spectralWarmth +
            0.20 * (1.0 - avgBrightness)
        ))

        // Valence: three complementary harmonic signals.
        // consonance    — absolute interval pairs (Kameoka & Kuriyagawa weights)
        // keyRelVal     — energy on bright (root/maj3/P5/maj6) vs dark (min3/tritone/min2/min7)
        //                 scale degrees relative to the detected root; catches "bright-sounding
        //                 minor key" cases that fool spectral brightness alone.
        // harmonicRhythm — fast chord changes correlate with positive affect (pop/dance);
        //                  static/slow harmony correlates with melancholy/sustained mood.
        // Dropped: avgBrightness (spectral centroid ≠ emotional valence — conflates timbre),
        //          tempoScore (fast ≠ happy; "One" by Metallica), zcrNorm (timbral, not affective).
        let consonance = chromaConsonance(normChroma)
        let keyRelVal  = keyRelativeValence(chroma: normChroma, root: detectedKey)
        let valence = min(1.0, max(0.0,
            consonance           * 0.35 +   // absolute interval consonance (primary)
            keyRelVal            * 0.25 +   // key-anchored bright vs dark scale degrees (new)
            Double(detectedMode) * 0.20 +   // major/minor binary
            harmonicRhythm       * 0.12 +   // fast chord changes → more positive affect
            modeConf             * 0.08     // confidence in mode detection
        ))

        // Instrumentalness: inverse of vocal content indicators.
        // vocalPresence (midband energy ratio) is the primary signal — vocals dominate 300–3000 Hz.
        // ZCR separates voiced singing (low ZCR) from noisy/consonant content (high ZCR).
        // Rolloff removed: it's non-monotonically related to vocals and incorrectly penalized
        // bass-heavy instrumentals (low rolloff = bass ≠ vocal).
        let instrumentalness = min(1.0, max(0.0,
            (1.0 - vocalPresence) * 0.60 +
            (1.0 - zcrNorm)       * 0.40
        ))

        // Liveness: dynamic range proxy.
        // Live recordings: crowd noise keeps quiet frames above silence → small dB range (~20-30 dB).
        // Studio recordings: true silence in sparse sections → large dB range (>45 dB).
        // Loudness correction: brick-wall mastered material (loudness > -10 dB) has artificially
        // small dynamic range from limiting — not crowd noise. Cap at 0.30 so compressed studio pop
        // doesn't score as live. Below -10 dB the DR proxy is reliable.
        let liveness: Double
        if maxFrameEnergy > 0, minNonsilentEnergy < .infinity,
           maxFrameEnergy > minNonsilentEnergy {
            let dynRangeDB = 20.0 * log10(maxFrameEnergy / minNonsilentEnergy)
            let livenessRaw = min(0.90, max(0.10, 1.0 - (dynRangeDB - 15.0) / 55.0))
            liveness = loudness > -10.0 ? min(livenessRaw, 0.30) : livenessRaw
        } else {
            liveness = 0.10
        }

        // Beat regularity: normalized autocorr at beat lag vs autocorr at zero lag.
        // Captures pulse clarity — how confidently a listener can lock onto the beat,
        // independent of loudness. Shared by both arousal and danceability below.
        let beatRegularity = computeBeatRegularity(onsetFlux: onsetFlux, fps: fps, bpm: bpm)

        // Arousal: physical intensity + pulse clarity.
        // DEAM Stage 2 overwrites this with the real value for the top 8 candidates;
        // this fills in arousal for the remaining ~90% so circumplex matching works across
        // the full result set. 180 BPM ceiling captures DnB/rave at max arousal.
        // beatRegularity raises arousal for quiet-but-rhythmically-insistent tracks —
        // minimal techno at low volume, tense ambient with a steady pulse — that energy
        // alone would mis-score as calm.
        let arousalTempoScore = min(1.0, bpm / 180.0)
        let arousal = min(1.0, max(0.0,
            energy            * 0.50 +
            arousalTempoScore * 0.25 +
            avgBrightness     * 0.10 +
            beatRegularity    * 0.15
        ))

        // Danceability: beat regularity + genre-aware BPM fit + energy.
        // bpmDanceabilityScore is genre-informed when hints are available — DnB at 170,
        // bachata at 110, boom bap at 88 all score 1.0 in their respective genre ranges
        // instead of being penalized by the old 120 BPM Gaussian.
        let danceability   = min(1.0, max(0.0,
            beatRegularity                                    * 0.50 +
            bpmDanceabilityScore(bpm, genreHints: genreHints) * 0.30 +
            energy                                            * 0.20
        ))

        // TonalClarity: how confidently tonal the clip is
        let tonalClarity = min(1.0, max(0.0, modeConf * 0.70 + (1.0 - avgFlatness) * 0.30))

        // ReverbSpace: flat HF response suggests diffuse/reverberant environment
        let reverbSpace = min(1.0, max(0.0, avgHFFlatness))

        // ChromaEntropy: 0=one dominant pitch class, 1=all equally present
        let chromaEntropy = shannonEntropy(normChroma)

        // CoreML: fill valenceEssentia + refine arousal from on-device DEAM model.
        // Priority chain: CoreML (now) < Stage 2.6 HF DEAM (overwrites async after search).
        var coreMLValence: Double? = nil
        var coreMLArousal: Double? = nil

        var coreMLFeatures: [Double] = mfccMean + mfccStd + normChroma
        coreMLFeatures.append(contentsOf: [
            chromaEntropy, Double(detectedMode), modeConf, energy, spectralWarmth, tonalClarity
        ])
        if let prediction = ValenceArousalPredictor.shared.predict(features: coreMLFeatures) {
            coreMLValence = prediction.valence
            coreMLArousal = prediction.arousal
        }

        #if DEBUG
        let keyNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let kl = detectedKey < keyNames.count ? keyNames[detectedKey] : "?"
        simiLog("🎛️ LocalAudio \"\(title)\": bpm=\(String(format:"%.0f",bpm)) energy=\(String(format:"%.2f",energy)) arousal=\(String(format:"%.2f",arousal)) pulse=\(String(format:"%.2f",beatRegularity)) valence=\(String(format:"%.2f",valence)) consonance=\(String(format:"%.2f",consonance)) harmRhythm=\(String(format:"%.2f",harmonicRhythm)) dance=\(String(format:"%.2f",danceability)) acoust=\(String(format:"%.2f",acousticness)) instr=\(String(format:"%.2f",instrumentalness)) live=\(String(format:"%.2f",liveness)) key=\(kl) \(detectedMode==1 ? "Major" : "Minor")(conf=\(String(format:"%.2f",modeConf)))")
        #endif

        return AudioFeatures(
            bpm:              bpm,
            energy:           energy,
            valence:          valence,
            danceability:     danceability,
            acousticness:     acousticness,
            instrumentalness: instrumentalness,
            liveness:         liveness,
            loudness:         loudness,
            key:              detectedKey,
            mode:             detectedMode,
            isEstimated:      false,
            isKeyEstimated:   false,
            spectralWarmth:   spectralWarmth,
            tonalClarity:     tonalClarity,
            vocalPresence:    vocalPresence,
            reverbSpace:      reverbSpace,
            mfccMean:         mfccMean,
            mfccStd:          mfccStd,
            chroma:           normChroma,
            chromaEntropy:    chromaEntropy,
            zcr:              zcr,
            rolloff:          rolloffNorm,
            arousal:          coreMLArousal ?? arousal,   // CoreML wins; DSP proxy is fallback
            valenceEssentia:  coreMLValence               // nil → 0.18 weight; set → 0.28 weight
        )
    }

    // MARK: - Per-Frame Analysis

    private func analyzeFrame(
        at offset: Int, samples: [Float], window: [Float],
        fftSetup: FFTSetup, log2n: vDSP_Length, binHz: Double
    ) -> FrameResult {
        var frame = Array(samples[offset..<(offset + fftSize)])
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var mags = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { rPtr in
            imag.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.baseAddress!.assumingMemoryBound(to: DSPComplex.self),
                              2, &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))
            }
        }

        let numBins = fftSize / 2
        var weightedSum   = 0.0
        var magSum        = 0.0
        var chroma        = [Double](repeating: 0, count: 12)
        var totalEnergy   = 0.0
        var lowMidEnergy  = 0.0
        var midBandEnergy = 0.0
        var subBassEnergy = 0.0
        var bandMags      = [Float]()   // 1 Hz+ for overall flatness
        var hfMags        = [Float]()   // 2 kHz+ for reverb proxy

        bandMags.reserveCapacity(numBins)

        for i in 1..<numBins {
            let freq = Double(i) * binHz
            let mag  = Double(mags[i])
            bandMags.append(mags[i])
            totalEnergy += mag

            if freq >= 200 && freq <= 6000 { weightedSum += freq * mag; magSum += mag }

            if freq >= 60 && freq <= 5000 && mag > 0 {
                let midi = 12.0 * log2(freq / 440.0) + 69.0
                chroma[((Int(midi.rounded()) % 12) + 12) % 12] += mag
            }
            if freq >= 100 && freq <= 2000 { lowMidEnergy  += mag }
            if freq >= 300 && freq <= 3000 { midBandEnergy += mag }
            if freq >= 50  && freq <= 200  { subBassEnergy += mag }
            if freq >= 2000                { hfMags.append(mags[i]) }
        }

        let centroid = magSum > 0 ? max(0, min(1, (weightedSum / magSum - 200) / 5800)) : 0.5

        let chromaTotal = chroma.reduce(0, +)
        let normChroma  = chromaTotal > 0 ? chroma.map { $0 / chromaTotal } :
                          [Double](repeating: 1.0 / 12, count: 12)

        let flatness   = spectralFlatness(bandMags)
        let hfFlatness = hfMags.isEmpty ? -1.0 : spectralFlatness(hfMags)

        // 85th-percentile rolloff bin
        var cumEnergy = 0.0
        let target85  = 0.85 * totalEnergy
        var rolloffBin = Double(numBins / 2)
        for i in 1..<numBins {
            cumEnergy += Double(mags[i])
            if cumEnergy >= target85 { rolloffBin = Double(i); break }
        }

        return FrameResult(
            centroid:      centroid,
            chroma:        normChroma,
            magnitudes:    mags,
            totalEnergy:   totalEnergy,
            lowMidEnergy:  lowMidEnergy,
            midBandEnergy: midBandEnergy,
            subBassEnergy: subBassEnergy,
            flatness:      flatness,
            hfFlatness:    hfFlatness,
            rolloffBin:    rolloffBin
        )
    }

    // MARK: - BPM via Onset Autocorrelation

    /// Scans 40–240 BPM via onset autocorrelation with dual-band sub-bass reinforcement.
    ///
    /// Strategy:
    ///   1. Full-band autocorr on the broadband onset flux (existing).
    ///   2. Sub-band autocorr on the 50–200 Hz kick-drum flux independently.
    ///   3. Normalize each band to [0,1] within its own max, combine 40% full + 60% sub-bass
    ///      (when sub-bass signal is usable — gated at subMax > fullMax × 0.02).
    ///   4. Find local maxima above 40% of combined global max, fold + cluster.
    ///   5. Genre tiebreaker fires only when top two peaks are within 1.5× (acoustically ambiguous).
    private func estimateBPM(onsetFlux: [Float], subBassFlux: [Float] = [],
                              fps: Double, genreHints: [String] = []) -> Double {
        guard onsetFlux.count > 20 else { return 120 }
        let n = onsetFlux.count

        // ── Full-band autocorr ──────────────────────────────────────────────────
        var fullScores = [Double](repeating: 0, count: 201)
        var bpms = [Double](repeating: 0, count: 201)
        var idx = 0
        for bpm in stride(from: 40.0, through: 240.0, by: 1.0) {
            let lag = Int((fps * 60.0 / bpm).rounded())
            guard lag > 0 && lag < n / 2 else { idx += 1; continue }
            var s = 0.0
            for t in 0..<(n - lag) { s += Double(onsetFlux[t]) * Double(onsetFlux[t + lag]) }
            fullScores[idx] = s / Double(n - lag)
            bpms[idx] = bpm
            idx += 1
        }
        let fullMax = fullScores.max() ?? 0

        // ── Sub-bass autocorr (50–200 Hz kick band) ─────────────────────────────
        let nSub = subBassFlux.count
        var subScores = [Double](repeating: 0, count: 201)
        var subMax = 0.0
        if nSub > 20 {
            for (i, bpm) in bpms.enumerated() {
                guard bpm > 0 else { continue }
                let lag = Int((fps * 60.0 / bpm).rounded())
                guard lag > 0 && lag < nSub / 2 else { continue }
                var s = 0.0
                for t in 0..<(nSub - lag) { s += Double(subBassFlux[t]) * Double(subBassFlux[t + lag]) }
                subScores[i] = s / Double(nSub - lag)
            }
            subMax = subScores.max() ?? 0
        }

        // ── Combine bands ───────────────────────────────────────────────────────
        // Gate: only blend sub-bass when it carries real signal (≥ 2% of full-band max).
        // This prevents kick-less tracks (e.g. sparse piano) from polluting the tempo estimate.
        let subBassUsable = subMax > fullMax * 0.02 && fullMax > 0
        var combinedScores = [(bpm: Double, score: Double)]()
        combinedScores.reserveCapacity(idx)
        for i in 0..<201 {
            guard bpms[i] > 0 else { continue }
            let fNorm = fullMax > 0 ? fullScores[i] / fullMax : 0
            let combined: Double
            if subBassUsable {
                let sNorm = subScores[i] / subMax
                combined = 0.40 * fNorm + 0.60 * sNorm
            } else {
                combined = fNorm
            }
            combinedScores.append((bpm: bpms[i], score: combined))
        }

        guard let globalPair = combinedScores.max(by: { $0.score < $1.score }),
              globalPair.score > 0 else { return 120 }
        let globalMax = globalPair.score

        // ── Find local maxima > 40% of combined global max ──────────────────────
        var peaks = [(bpm: Double, score: Double)]()
        for i in 1..<(combinedScores.count - 1) {
            let s = combinedScores[i]
            guard s.score > combinedScores[i - 1].score,
                  s.score > combinedScores[i + 1].score,
                  s.score > globalMax * 0.40 else { continue }
            peaks.append(s)
        }
        // No peak clears the 40% bar — fold and return the overall strongest BPM
        // instead of defaulting to 120 (which is almost always wrong here).
        if peaks.isEmpty { return foldBPM(globalPair.bpm) }

        // ── Fold + cluster within ±5 BPM ────────────────────────────────────────
        var candidates = [(bpm: Double, score: Double)]()
        for peak in peaks.sorted(by: { $0.score > $1.score }) {
            let folded = foldBPM(peak.bpm)
            if !candidates.contains(where: { abs($0.bpm - folded) < 6 }) {
                candidates.append((bpm: folded, score: peak.score))
            }
            if candidates.count == 5 { break }
        }

        // ── Sub-harmonic promotion ──────────────────────────────────────────────
        // When the top candidate is below the tactus floor (< 76 BPM), it is likely
        // the 2nd harmonic of the real felt tempo.  Promote to 2× when the double
        // has a meaningful combined score (≥ 30% of global max) and the active genre
        // is not a slow style (lower range bound < 76 BPM, e.g. bolero or latin).
        // 5% score bonus ensures the promoted candidate beats folded 3× harmonics
        // that can land at the same score tier (e.g. 50 BPM→100 BPM from a 150 BPM signal).
        var sorted = candidates.sorted { $0.score > $1.score }
        let tactusFloor = 76.0
        if let top = sorted.first, top.bpm < tactusFloor {
            let isSlowGenre: Bool = {
                if let rng = genreRange(for: genreHints) {
                    return rng.lowerBound < tactusFloor
                }
                return false
            }()
            if !isSlowGenre {
                let promoted = top.bpm * 2
                if promoted >= tactusFloor && promoted <= 180,
                   let promoEntry = combinedScores.first(where: { abs($0.bpm - promoted) < 1.5 }),
                   promoEntry.score >= globalMax * 0.30 {
                    candidates.removeAll { abs($0.bpm - top.bpm) < 6 }
                    let promoFolded = foldBPM(promoted)
                    if !candidates.contains(where: { abs($0.bpm - promoFolded) < 6 }) {
                        candidates.append((bpm: promoFolded, score: promoEntry.score * 1.05))
                    }
                    sorted = candidates.sorted { $0.score > $1.score }
                }
            }
        }

        // ── Genre tiebreaker ─────────────────────────────────────────────────────
        // Fires in two modes:
        //   Ambiguous: top < 1.5× second → weight all candidates by genre affinity.
        //   Out-of-range: top BPM is outside the genre's expected tempo band →
        //     apply genre affinity unconditionally (double-tempo correction without
        //     requiring acoustic ambiguity). This fixes slow Latin/soul songs where
        //     the 2× harmonic dominates the autocorr but genre clearly says it's wrong.
        if !genreHints.isEmpty, let range = genreRange(for: genreHints) {
            let topBPM = sorted.first?.bpm ?? 0
            let isAmbiguous = sorted.count >= 2 && sorted[0].score < sorted[1].score * 1.5
            let isOutOfRange = !range.contains(topBPM)
            if isAmbiguous || isOutOfRange {
                let winner = sorted.max {
                    genreAffinity($0.bpm, range: range) * $0.score <
                    genreAffinity($1.bpm, range: range) * $1.score
                }
                if let w = winner, w.score >= globalMax * 0.25 {
                    return w.bpm
                }
            }
        }

        // ── Non-electronic double-tempo correction (no genre hints) ───────────────
        // Acoustic, Latin, and folk tracks often show stronger autocorrelation at the
        // 8th-note level (2× felt tempo) than the quarter-note pulse, yielding e.g.
        // 150 BPM instead of 75 BPM. Sub-bass gate prevents misfiring on house/techno
        // where the kick drum IS at 130+ BPM and sub-bass confirms it.
        // Threshold: half must score ≥ 35% of global max (conservative without genre prior).
        if genreHints.isEmpty, !subBassUsable,
           let top = sorted.first, top.bpm >= 120, top.bpm <= 175 {
            let halfBPM = top.bpm / 2
            if halfBPM >= 55, halfBPM <= 100,
               let halfEntry = sorted.first(where: { abs($0.bpm - halfBPM) < 6 }),
               halfEntry.score >= globalMax * 0.35 {
                return halfEntry.bpm
            }
        }

        return sorted.first?.bpm ?? 120
    }

    // Fold BPM octave errors into 55–180 preferred range
    private func foldBPM(_ bpm: Double) -> Double {
        var b = bpm
        while b > 180 { b /= 2 }
        while b < 55  { b *= 2 }
        return max(40, min(240, b))
    }

    // MARK: - Beat Regularity (danceability proxy)

    private func computeBeatRegularity(onsetFlux: [Float], fps: Double, bpm: Double) -> Double {
        guard !onsetFlux.isEmpty, bpm > 0 else { return 0.5 }
        let n   = onsetFlux.count
        let lag = Int((fps * 60.0 / bpm).rounded())
        guard lag > 0 && lag < n else { return 0.5 }

        var dotBeat: Float = 0
        var dotSelf:  Float = 0
        for t in 0..<(n - lag) { dotBeat += onsetFlux[t] * onsetFlux[t + lag] }
        for t in 0..<n         { dotSelf  += onsetFlux[t] * onsetFlux[t]      }

        guard dotSelf > 0 else { return 0.5 }
        // Scale: autocorr at beat lag / autocorr at lag=0; multiply by 2 to expand 0–0.5 range to 0–1
        return min(1.0, max(0.0, Double(dotBeat / dotSelf) * 2.0))
    }

    // How well `bpm` fits the expected tempo for dancing.
    // With genre hints: uses genreAffinity — full score inside the genre's typical range,
    //   linear decay to 0 at 2× the range width outside.
    //   DnB at 170, bachata at 110, boom bap at 88 all score 1.0 in their genre range.
    // Without hints: full score in 75–165 BPM (covers the vast majority of dance genres),
    //   gentle ±40 BPM decay outside — far less punishing than the old 120-centred Gaussian.
    private func bpmDanceabilityScore(_ bpm: Double, genreHints: [String] = []) -> Double {
        if !genreHints.isEmpty, let range = genreRange(for: genreHints) {
            return genreAffinity(bpm, range: range)
        }
        if bpm >= 75 && bpm <= 165 { return 1.0 }
        if bpm < 75  { return max(0.0, 1.0 - (75  - bpm) / 40.0) }
        return          max(0.0, 1.0 - (bpm - 165) / 40.0)
    }

    // MARK: - Chroma Consonance (valence foundation)

    /// Computes a perceived consonance score from the 12-bin chroma vector.
    /// For every pair of pitch classes (i, j) weighted by their energy, scores the
    /// interval between them using psychoacoustic consonance ratings (Kameoka & Kuriyagawa 1969).
    ///
    /// Why this matters for valence:
    ///   - Metal/dark trap: tritone + minor-2nd clusters → low consonance → lower valence despite major key
    ///   - Pop/bright R&B: thirds + fifths dominate → high consonance → higher valence contribution
    ///   - Sad piano ballad: consonant minor thirds + major sixths → moderate-high consonance despite minor key
    private func chromaConsonance(_ chroma: [Double]) -> Double {
        // Interval consonance weights: index = semitone distance (0–11)
        // 0=unison, 1=min2, 2=maj2, 3=min3, 4=maj3, 5=perf4,
        // 6=tritone, 7=perf5, 8=min6, 9=maj6, 10=min7, 11=maj7
        let weights: [Double] = [1.00, 0.04, 0.17, 0.82, 0.88, 0.76,
                                  0.07, 1.00, 0.68, 0.81, 0.27, 0.05]
        let n = chroma.count
        var weightedSum = 0.0
        var totalWeight = 0.0
        for i in 0..<n {
            guard chroma[i] > 0 else { continue }
            for j in 0..<n {
                guard chroma[j] > 0 else { continue }
                let interval = (j - i + n) % n
                let w = chroma[i] * chroma[j]
                weightedSum += w * weights[interval]
                totalWeight += w
            }
        }
        return totalWeight > 0 ? weightedSum / totalWeight : 0.5
    }

    // MARK: - Key-Relative Valence

    /// Ratio of chroma energy on bright vs dark scale degrees relative to the detected root.
    ///
    /// Bright offsets: root (0), major-3rd (+4), perfect-5th (+7), major-6th (+9).
    /// Dark offsets:   minor-2nd (+1), minor-3rd (+3), tritone (+6), minor-7th (+10).
    ///
    /// Returns 0.0 (all energy on dark degrees) → 1.0 (all energy on bright degrees).
    /// Neutral 0.5 when total energy on these degrees is negligible.
    private func keyRelativeValence(chroma: [Double], root: Int) -> Double {
        guard chroma.count == 12 else { return 0.5 }
        let bright = [0, 4, 7, 9].reduce(0.0) { $0 + chroma[((root + $1) % 12)] }
        let dark   = [1, 3, 6, 10].reduce(0.0) { $0 + chroma[((root + $1) % 12)] }
        let total  = bright + dark
        guard total > 0.01 else { return 0.5 }
        return bright / total
    }

    // MARK: - MFCC

    /// Sparse triangular mel filter: only the non-zero FFT bin range is stored.
    private struct MelFilter {
        let startBin: Int
        let weights:  [Float]   // linear rise to peak then fall (triangular shape)
    }

    /// Builds 128 triangular mel filters on the HTK scale from 0 Hz to Nyquist.
    /// Matches librosa's default mel_filters(sr, n_mels=128, htk=True) for pipeline
    /// compatibility — same center frequencies, same triangular shape, same power-spectrum input.
    private func buildMelFilterbank(sampleRate: Double) -> [MelFilter] {
        let nBins  = fftSize / 2
        let fMax   = sampleRate / 2.0
        let binHz  = sampleRate / Double(fftSize)

        let melMin = hzToMel(0.0)
        let melMax = hzToMel(fMax)

        // nMels+2 evenly-spaced mel points → convert back to Hz → FFT bin indices
        let melPts = (0...(nMels + 1)).map { i in
            melMin + Double(i) / Double(nMels + 1) * (melMax - melMin)
        }
        let binPts = melPts.map { max(0, min(nBins, Int((melToHz($0) / binHz).rounded()))) }

        return (0..<nMels).map { m in
            let lo = binPts[m], peak = binPts[m + 1], hi = binPts[m + 2]
            guard peak > lo else { return MelFilter(startBin: lo, weights: []) }
            var weights = [Float]()
            weights.reserveCapacity(hi - lo)
            for k in lo..<hi {
                let w: Float = k < peak
                    ? Float(k - lo) / Float(peak - lo)
                    : Float(hi - k) / Float(hi - peak)
                weights.append(w)
            }
            return MelFilter(startBin: lo, weights: weights)
        }
    }

    /// Applies the mel filterbank to one frame's FFT magnitudes.
    /// Uses power spectrum (mag²) to match librosa's default MFCC input.
    private func applyMelFilterbank(_ magnitudes: [Float], filterbank: [MelFilter]) -> [Float] {
        filterbank.map { filter in
            guard !filter.weights.isEmpty else { return 0 }
            let start = filter.startBin
            let count = filter.weights.count
            guard start + count <= magnitudes.count else { return 0 }
            var energy: Float = 0
            for i in 0..<count {
                let mag = magnitudes[start + i]
                energy += mag * mag * filter.weights[i]   // power × triangular weight
            }
            return energy
        }
    }

    /// Orthogonal DCT-II (scipy.fftpack.dct type=2, norm='ortho').
    /// Matches librosa's default MFCC basis so on-device vectors are directionally
    /// aligned with HF-extracted vectors for cosine comparison.
    private func dctII(_ x: [Float], nCoeffs: Int) -> [Double] {
        let N = x.count
        guard N > 0 else { return [Double](repeating: 0, count: nCoeffs) }
        let scale0 = sqrt(1.0 / Double(N))
        let scaleK = sqrt(2.0 / Double(N))
        return (0..<nCoeffs).map { k in
            let scale = k == 0 ? scale0 : scaleK
            var sum = 0.0
            for n in 0..<N {
                sum += Double(x[n]) * cos(Double.pi * Double(k) * (Double(n) + 0.5) / Double(N))
            }
            return scale * sum
        }
    }

    /// L2-normalizes a vector to unit length.
    /// Makes cosine comparison scale-invariant: pipeline differences in absolute MFCC
    /// magnitude (librosa vs on-device) cancel out — only the spectral pattern is compared.
    private func l2Normalize(_ v: [Double]) -> [Double] {
        let norm = sqrt(v.reduce(0.0) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    // HTK mel scale (hz_to_mel with htk=True in librosa)
    private func hzToMel(_ hz: Double) -> Double { 2595.0 * log10(1.0 + hz / 700.0) }
    private func melToHz(_ mel: Double) -> Double { 700.0 * (pow(10.0, mel / 2595.0) - 1.0) }

    // MARK: - ZCR

    private func computeZCR(samples: [Float]) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count {
            if (samples[i] >= 0) != (samples[i - 1] >= 0) { crossings += 1 }
        }
        return Double(crossings) / Double(samples.count)
    }

    // MARK: - Spectral Flatness (acousticness base)

    private func spectralFlatness(_ mags: [Float]) -> Double {
        let positive = mags.filter { $0 > 1e-10 }
        guard !positive.isEmpty else { return 0.5 }
        let logSum       = positive.reduce(0.0) { $0 + Double(log(max($1, 1e-10))) }
        let geometricMean = exp(logSum / Double(positive.count))
        let arithmeticMean = positive.reduce(0.0) { $0 + Double($1) } / Double(positive.count)
        guard arithmeticMean > 0 else { return 0.5 }
        return min(1.0, max(0.0, geometricMean / arithmeticMean))
    }

    // MARK: - Chroma Entropy

    // Normalized Shannon entropy; 0 = one dominant pitch class, 1 = all equally present
    private func shannonEntropy(_ dist: [Double]) -> Double {
        let positive = dist.filter { $0 > 0 }
        guard !positive.isEmpty else { return 1.0 }
        let h = positive.reduce(0.0) { $0 - $1 * log($1) }
        return min(1.0, max(0.0, h / log(12.0)))
    }

    // MARK: - Key Finding (Krumhansl-Kessler, same as PreviewAudioAnalyzer)

    private func findKey(chroma: [Double]) -> (key: Int, mode: Int, confidence: Double) {
        var bestCorr = -2.0, secondBest = -2.0
        var bestKey = 0, bestMode = 1

        for k in 0..<12 {
            for (profile, mode) in [(majorProfile, 1), (minorProfile, 0)] {
                let corr = pearsonCorrelation(chroma, rotate(profile, by: k))
                if corr > bestCorr {
                    secondBest = bestCorr; bestCorr = corr; bestKey = k; bestMode = mode
                } else if corr > secondBest {
                    secondBest = corr
                }
            }
        }

        let margin     = bestCorr - max(0, secondBest)
        let confidence = min(1.0, max(0.0, margin / 0.15))
        return (bestKey, bestMode, confidence)
    }

    // MARK: - Helpers

    private func makeHannWindow() -> [Float] {
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return w
    }

    private func fallbackFeatures() -> AudioFeatures {
        AudioFeatures(
            bpm: 120, energy: 0.5, valence: 0.5, danceability: 0.5,
            acousticness: 0.5, instrumentalness: 0.5, liveness: 0.1, loudness: -14,
            key: 0, mode: 1, isEstimated: true, isKeyEstimated: true
        )
    }

    private func rotate(_ profile: [Double], by n: Int) -> [Double] {
        let n = ((n % profile.count) + profile.count) % profile.count
        return Array(profile[n...]) + Array(profile[..<n])
    }

    private func pearsonCorrelation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 0 }
        let mA = a.prefix(n).reduce(0, +) / Double(n)
        let mB = b.prefix(n).reduce(0, +) / Double(n)
        var num = 0.0, dA = 0.0, dB = 0.0
        for i in 0..<n {
            let da = a[i] - mA, db = b[i] - mB
            num += da * db; dA += da * da; dB += db * db
        }
        let denom = sqrt(dA * dB)
        return denom > 0 ? num / denom : 0
    }
}
