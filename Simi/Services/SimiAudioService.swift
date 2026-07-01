// SimiAudioService.swift
// Simi — Music Discovery App
//
// Client for the Hugging Face Spaces-hosted librosa audio analysis microservice.
// Source: backend/audio-analyzer/ — deployed to layzskolah-simi-audio-analyzer.hf.space
//
// Primary audio feature source. iOS downloads the preview on-device, then POSTs
// the raw bytes to /analyze-bytes — faster than having the server fetch from Apple CDN.
// Falls through silently when the service is unreachable — tag estimation takes over.

import Foundation

class SimiAudioService {

    static let shared = SimiAudioService()

    private let baseURL = "https://layzskolah-simi-audio-analyzer.hf.space"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45.0   // download + upload + librosa can reach ~30s
        session = URLSession(configuration: config)
    }

    // ──────────────────────────────────────────────
    // MARK: - /analyze
    // ──────────────────────────────────────────────

    /// Downloads the preview URL on-device then POSTs the raw bytes to /analyze-bytes.
    /// iOS has faster CDN routing to Apple/iTunes servers than Railway does, so
    /// downloading here eliminates the main source of /analyze latency (server-side
    /// CDN fetch taking 5-30s). Returns nil on any failure — caller falls through
    /// to local PreviewAudioAnalyzer + tag estimation.
    func analyzePreview(url: String, artist: String = "", title: String = "") async -> AudioFeatures? {
        // 1. Download audio on-device (~1-3s from iTunes CDN)
        guard let audioURL = URL(string: url),
              let (audioData, audioResponse) = try? await URLSession.shared.data(from: audioURL),
              (audioResponse as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        // 2. POST bytes to Railway as multipart/form-data (~1-3s upload + librosa)
        // Pass artist/title so server fires cascade prefetch for the artist's catalog.
        var components = URLComponents(string: "\(baseURL)/analyze-bytes")!
        if !artist.isEmpty {
            components.queryItems = [
                URLQueryItem(name: "artist", value: artist),
                URLQueryItem(name: "title", value: title),
            ]
        }
        guard let endpoint = components.url else { return nil }

        let suffix = url.lowercased().contains(".m4a") ? "m4a" : "mp3"
        let mimeType = suffix == "m4a" ? "audio/mp4" : "audio/mpeg"
        let boundary = "simi-\(UUID().uuidString)"

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(suffix)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        return try? JSONDecoder().decode(AudioFeatures.self, from: data)
    }

    // ──────────────────────────────────────────────
    // MARK: - /batch-analyze
    // ──────────────────────────────────────────────

    /// Sends up to 20 preview URLs in one request; server runs them concurrently.
    /// Returns a URL → AudioFeatures mapping for every URL that succeeded.
    /// Failures (download error, bad audio) are silently omitted.
    func batchAnalyze(urls: [String]) async -> [String: AudioFeatures] {
        guard !urls.isEmpty,
              let endpoint = URL(string: "\(baseURL)/batch-analyze") else { return [:] }

        let body = ["urls": urls]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return [:] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90.0   // Railway downloading + librosa on 5-20 tracks
        request.httpBody = bodyData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }

        struct Wrapper: Decodable {
            let results: [AudioFeatures?]
        }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { return [:] }

        var mapping: [String: AudioFeatures] = [:]
        for (url, features) in zip(urls, wrapper.results) {
            if let features { mapping[url] = features }
        }
        return mapping
    }

    // ──────────────────────────────────────────────
    // MARK: - /similarity
    // ──────────────────────────────────────────────

    struct SimilarityResult: Decodable {
        let score: Double
        let reasons: [String]

        /// Converts the raw strings to typed MatchReasons, dropping any that
        /// don't match a known case (future-proofing for new reason types).
        var matchReasons: [MatchReason] {
            reasons.compactMap { MatchReason(rawValue: $0) }
        }
    }

    /// Asks the server to score two AudioFeatures objects using the same
    /// weighted similarity logic as RecommendationEngine.computeSimilarity().
    /// Useful for batch-scoring a candidate pool against a Python-analyzed source.
    func computeSimilarity(source: AudioFeatures, target: AudioFeatures) async -> SimilarityResult? {
        guard let endpoint = URL(string: "\(baseURL)/similarity") else { return nil }

        struct SimilarityRequest: Encodable {
            let source: AudioFeatures
            let target: AudioFeatures
        }

        guard let bodyData = try? JSONEncoder().encode(SimilarityRequest(source: source, target: target)) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        return try? JSONDecoder().decode(SimilarityResult.self, from: data)
    }

    // ──────────────────────────────────────────────
    // MARK: - /health
    // ──────────────────────────────────────────────

    /// Fast liveness check — 3-second timeout so the app doesn't hang on startup.
    /// RecommendationEngine calls this once at the start of each search rather
    /// than maintaining a persistent isAvailable flag (avoids stale state).
    func isReachable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Warms up the Railway container and returns whether it responded in time.
    /// Call this at enrichment start (concurrent with tag estimation) so cold-start
    /// time overlaps with Stage 1. Returns false if Railway doesn't respond within
    /// the deadline — caller should skip batch-analyze rather than immediately timeout.
    func warmUp() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 22.0   // Railway cold starts can take up to ~20s
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
