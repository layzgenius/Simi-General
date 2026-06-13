// PreviewAudioAnalyzer.swift
// Simi — Music Discovery App
//
// On-device audio analysis using AVFoundation and Accelerate.
// Downloads a preview clip and computes:
//   • RMS energy
//   • Spectral centroid (brightness), 200–6000 Hz
//   • Chroma vector + Krumhansl-Kessler key-finding → detectedKey, detectedMode, modeConfidence
//
// modeConfidence is the single most important output: major keys consistently score higher
// Spotify valence than minor keys. It's the primary on-device valence signal.
//
// Actor isolation ensures only one analysis runs at a time — safe because
// analysis only runs for the source song, never in parallel enrichment loops.

import Foundation
import AVFoundation
import Accelerate

// MARK: - Result type

struct AudioMeasurements {
    let energy: Double              // 0–1, RMS-derived
    let spectralBrightness: Double  // 0–1, spectral centroid 200–6000 Hz
    let detectedKey: Int            // 0=C … 11=B (Krumhansl-Kessler)
    let detectedMode: Int           // 0=minor, 1=major
    let modeConfidence: Double      // 0–1 — how clearly tonal the clip is
}

// MARK: - Analyzer

actor PreviewAudioAnalyzer {

    static let shared = PreviewAudioAnalyzer()

    private let fftSize = 4096

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 8
        cfg.timeoutIntervalForResource = 12
        return URLSession(configuration: cfg)
    }()

    // Krumhansl-Kessler tonal hierarchy profiles (C-rooted)
    private let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                                           2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                                           2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    // ──────────────────────────────────────────────
    // MARK: - Public API

    func analyze(previewURL urlString: String) async -> AudioMeasurements? {
        guard let url = URL(string: urlString) else { return nil }

        let tempURL: URL
        do {
            let (downloadedURL, _) = try await session.download(from: url)
            tempURL = downloadedURL
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: tempURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            return nil
        }

        let sampleRate = audioFile.fileFormat.sampleRate
        let frameCount = AVAudioFrameCount(audioFile.length)
        let processingFormat = audioFile.processingFormat

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            return nil
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            return nil
        }

        guard let channelData = buffer.floatChannelData else { return nil }
        let actualFrames = Int(buffer.frameLength)
        let channelCount = Int(processingFormat.channelCount)

        // Average all channels into mono using vDSP
        var monoSamples = [Float](repeating: 0, count: actualFrames)
        for ch in 0 ..< channelCount {
            vDSP_vadd(monoSamples, 1, channelData[ch], 1, &monoSamples, 1, vDSP_Length(actualFrames))
        }
        if channelCount > 1 {
            var scale = Float(1.0 / Float(channelCount))
            vDSP_vsmul(monoSamples, 1, &scale, &monoSamples, 1, vDSP_Length(actualFrames))
        }

        let samples = monoSamples

        // ── RMS energy ──────────────────────────────
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(actualFrames))
        let energy = min(1.0, max(0.0, Double(rms) / 0.5))

        // ── Spectral analysis + chroma ───────────────
        let (brightness, chroma) = computeSpectralAndChroma(
            samples: samples, sampleCount: actualFrames, sampleRate: sampleRate
        )

        // ── Key / mode from chroma ───────────────────
        let (detectedKey, detectedMode, modeConfidence) = findKey(chroma: chroma)

        #if DEBUG
        let keyNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let modeName = detectedMode == 1 ? "Major" : "Minor"
        let keyLabel = detectedKey >= 0 && detectedKey < keyNames.count ? keyNames[detectedKey] : "?"
        simiLog("🎵 Audio analysis: energy=\(String(format:"%.2f",energy)) brightness=\(String(format:"%.2f",brightness)) key=\(keyLabel) \(modeName) conf=\(String(format:"%.2f",modeConfidence))")
        #endif

        return AudioMeasurements(
            energy: energy,
            spectralBrightness: brightness,
            detectedKey: detectedKey,
            detectedMode: detectedMode,
            modeConfidence: modeConfidence
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Spectral + Chroma (single FFT pass)

    private func computeSpectralAndChroma(
        samples: [Float], sampleCount: Int, sampleRate: Double
    ) -> (brightness: Double, chroma: [Double]) {
        let stride = max(fftSize, sampleCount / 16)
        let log2n = vDSP_Length(log2(Double(fftSize)))

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return (0.5, [Double](repeating: 1.0 / 12, count: 12))
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var centroids: [Double] = []
        var chromaAccum = [Double](repeating: 0, count: 12)
        var offset = 0

        while offset + fftSize <= sampleCount {
            if let (c, chromaFrame) = frameAnalysis(
                at: offset, in: samples, window: window,
                fftSetup: fftSetup, log2n: log2n, sampleRate: sampleRate
            ) {
                centroids.append(c)
                for i in 0 ..< 12 { chromaAccum[i] += chromaFrame[i] }
            }
            offset += stride
        }

        let brightness = centroids.isEmpty ? 0.5 : centroids.reduce(0, +) / Double(centroids.count)

        let chromaTotal = chromaAccum.reduce(0, +)
        let normalizedChroma = chromaTotal > 0
            ? chromaAccum.map { $0 / chromaTotal }
            : [Double](repeating: 1.0 / 12, count: 12)

        return (brightness, normalizedChroma)
    }

    // ──────────────────────────────────────────────
    // MARK: - Per-frame FFT → centroid + chroma

    private func frameAnalysis(
        at offset: Int, in samples: [Float],
        window: [Float], fftSetup: FFTSetup,
        log2n: vDSP_Length, sampleRate: Double
    ) -> (centroid: Double, chroma: [Double])? {
        guard offset + fftSize <= samples.count else { return nil }

        var frame = Array(samples[offset ..< offset + fftSize])
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                frame.withUnsafeBytes { ptr in
                    let complexPtr = ptr.baseAddress!.assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        let binHz = sampleRate / Double(fftSize)
        var weightedSum = 0.0
        var magSum = 0.0
        var chroma = [Double](repeating: 0, count: 12)

        for i in 1 ..< fftSize / 2 {
            let freq = Double(i) * binHz
            let mag  = Double(magnitudes[i])

            // Centroid: perceptual band 200–6000 Hz.
            // Lower floor (was 500 Hz) prevents 808-heavy music from clipping to 0.0 —
            // bass music had all centroid information stripped, making it indistinguishable.
            if freq >= 200 && freq <= 6000 {
                weightedSum += freq * mag
                magSum      += mag
            }

            // Chroma: 60–5000 Hz covers all musical notes across octaves.
            // Map each bin to its pitch class via MIDI note number.
            if freq >= 60 && freq <= 5000 && mag > 0 {
                let midiNote   = 12.0 * log2(freq / 440.0) + 69.0
                let pitchClass = ((Int(midiNote.rounded()) % 12) + 12) % 12
                chroma[pitchClass] += mag
            }
        }

        guard magSum > 0 else { return nil }

        let centroidHz = weightedSum / magSum
        let normalized = (centroidHz - 200.0) / (6000.0 - 200.0)
        let brightness  = max(0.0, min(1.0, normalized))

        let chromaTotal = chroma.reduce(0, +)
        let normalizedChroma = chromaTotal > 0 ? chroma.map { $0 / chromaTotal } : chroma

        return (brightness, normalizedChroma)
    }

    // ──────────────────────────────────────────────
    // MARK: - Key finding (Krumhansl-Kessler)

    private func findKey(chroma: [Double]) -> (key: Int, mode: Int, confidence: Double) {
        var bestCorr   = -2.0
        var bestKey    = 0
        var bestMode   = 1
        var secondBest = -2.0

        for k in 0 ..< 12 {
            let majorCorr = pearsonCorrelation(chroma, rotate(majorProfile, by: k))
            let minorCorr = pearsonCorrelation(chroma, rotate(minorProfile, by: k))

            for (corr, mode) in [(majorCorr, 1), (minorCorr, 0)] {
                if corr > bestCorr {
                    secondBest = bestCorr
                    bestCorr   = corr
                    bestKey    = k
                    bestMode   = mode
                } else if corr > secondBest {
                    secondBest = corr
                }
            }
        }

        // Confidence: normalised margin between best and second-best.
        // Low margin → ambiguous tonality (noise, atonal music, very short clips).
        let margin     = bestCorr - max(0, secondBest)
        let confidence = min(1.0, margin / 0.15)   // 0.15 margin → full confidence
        return (key: bestKey, mode: bestMode, confidence: max(0, confidence))
    }

    private func rotate(_ profile: [Double], by n: Int) -> [Double] {
        let n = ((n % profile.count) + profile.count) % profile.count
        return Array(profile[n...]) + Array(profile[..<n])
    }

    private func pearsonCorrelation(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 1 else { return 0 }
        let meanA = a.prefix(n).reduce(0, +) / Double(n)
        let meanB = b.prefix(n).reduce(0, +) / Double(n)
        var num = 0.0, da2 = 0.0, db2 = 0.0
        for i in 0 ..< n {
            let da = a[i] - meanA, db = b[i] - meanB
            num += da * db; da2 += da * da; db2 += db * db
        }
        let denom = sqrt(da2 * db2)
        return denom > 0 ? num / denom : 0
    }
}

