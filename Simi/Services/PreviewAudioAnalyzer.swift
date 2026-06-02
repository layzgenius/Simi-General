// PreviewAudioAnalyzer.swift
// Simi — Music Discovery App
//
// On-device audio analysis using AVFoundation and Accelerate.
// Downloads a preview clip, computes RMS energy and spectral centroid
// (brightness) without any third-party dependencies.
//
// Actor isolation ensures only one analysis runs at a time — safe because
// analysis only runs for the source song, never in parallel enrichment loops.

import Foundation
import AVFoundation
import Accelerate

// MARK: - Result type

struct AudioMeasurements {
    let energy: Double              // 0–1, RMS-derived
    let spectralBrightness: Double  // 0–1, spectral centroid normalized to 500–8000 Hz
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

    // ──────────────────────────────────────────────
    // MARK: - Public API

    func analyze(previewURL urlString: String) async -> AudioMeasurements? {
        guard let url = URL(string: urlString) else { return nil }

        // Download preview clip to a temp file
        let tempURL: URL
        do {
            let (downloadedURL, _) = try await session.download(from: url)
            tempURL = downloadedURL
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Open with explicit float32 processing format so the buffer format matches
        // processingFormat exactly. Using the plain init sets processingFormat to the
        // file's native (often stereo compressed) format; passing a mono buffer to
        // read(into:) then fails with ExtAudioFileRead error -50.
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: tempURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            return nil
        }

        let sampleRate = audioFile.fileFormat.sampleRate
        let frameCount = AVAudioFrameCount(audioFile.length)
        let processingFormat = audioFile.processingFormat  // float32, native channels and rate

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

        // Average all channels into a single mono array using vDSP
        var monoSamples = [Float](repeating: 0, count: actualFrames)
        for ch in 0 ..< channelCount {
            vDSP_vadd(monoSamples, 1, channelData[ch], 1, &monoSamples, 1, vDSP_Length(actualFrames))
        }
        if channelCount > 1 {
            var scale = Float(1.0 / Float(channelCount))
            vDSP_vsmul(monoSamples, 1, &scale, &monoSamples, 1, vDSP_Length(actualFrames))
        }

        let samples = monoSamples
        let sampleCount = actualFrames

        // ── RMS energy ──────────────────────────────
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(sampleCount))
        // Normalize: full-scale sine RMS ≈ 0.5; clamp to [0, 1]
        let energy = min(1.0, max(0.0, Double(rms) / 0.5))

        // ── Spectral brightness ──────────────────────
        let brightness = computeSpectralBrightness(samples: samples,
                                                   sampleCount: sampleCount,
                                                   sampleRate: sampleRate)

        #if DEBUG
        print("🎵 Audio analysis: energy=\(energy), brightness=\(brightness)")
        #endif
        return AudioMeasurements(energy: energy, spectralBrightness: brightness)
    }

    // ──────────────────────────────────────────────
    // MARK: - Spectral analysis

    private func computeSpectralBrightness(samples: [Float],
                                           sampleCount: Int,
                                           sampleRate: Double) -> Double {
        let stride = max(fftSize, sampleCount / 16)
        let log2n = vDSP_Length(log2(Double(fftSize)))

        // Hann window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // FFT setup
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return 0.5
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var centroids: [Double] = []
        var offset = 0
        while offset + fftSize <= sampleCount {
            if let c = centroid(at: offset,
                                in: samples,
                                window: window,
                                fftSetup: fftSetup,
                                log2n: log2n,
                                sampleRate: sampleRate) {
                centroids.append(c)
            }
            offset += stride
        }

        guard !centroids.isEmpty else { return 0.5 }
        return centroids.reduce(0.0, +) / Double(centroids.count)
    }

    private func centroid(at offset: Int,
                          in samples: [Float],
                          window: [Float],
                          fftSetup: FFTSetup,
                          log2n: vDSP_Length,
                          sampleRate: Double) -> Double? {
        guard offset + fftSize <= samples.count else { return nil }

        // Extract and window the frame
        var frame = Array(samples[offset ..< offset + fftSize])
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftSize))

        // Pack real input into split-complex form, run FFT, compute magnitudes.
        // All Accelerate calls that touch splitComplex must live inside the
        // withUnsafeMutableBufferPointer scopes so the raw pointers stay valid.
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

        // Spectral centroid
        let binHz = sampleRate / Double(fftSize)
        var weightedSum = 0.0
        var magSum = 0.0
        for i in 0 ..< fftSize / 2 {
            let freq = Double(i) * binHz
            let mag  = Double(magnitudes[i])
            weightedSum += freq * mag
            magSum      += mag
        }
        guard magSum > 0 else { return nil }
        let centroidHz = weightedSum / magSum

        // Normalize to perceptual band 500–8000 Hz → 0–1
        let lo = 500.0, hi = 8000.0
        let normalized = (centroidHz - lo) / (hi - lo)
        return max(0.0, min(1.0, normalized))
    }
}
