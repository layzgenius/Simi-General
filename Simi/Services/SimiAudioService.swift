// SimiAudioService.swift
// Simi — Music Discovery App
//
// Client for the Railway-hosted librosa audio analysis microservice.
// Source: backend/audio-analyzer/ — deployed to simi-audio-analyzer-production.up.railway.app
//
// This is the primary audio feature source. /analyze downloads a 30-second preview
// and returns full measured BPM, energy, valence, danceability, acousticness,
// instrumentalness, liveness, loudness, key, and mode via FFT/chroma/MFCC.
// Falls through silently when Railway is unreachable — tag estimation takes over.

import Foundation

class SimiAudioService {

    static let shared = SimiAudioService()

    private let baseURL = "https://simi-audio-analyzer-production.up.railway.app"

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25.0   // librosa analysis takes ~3–8s
        session = URLSession(configuration: config)
    }

    // ──────────────────────────────────────────────
    // MARK: - /analyze
    // ──────────────────────────────────────────────

    /// Downloads the preview URL and extracts full audio features via librosa.
    /// Returns nil if the service is unreachable or analysis fails — the caller
    /// should fall through to the existing tag estimation path.
    func analyzePreview(url: String) async -> AudioFeatures? {
        guard let endpoint = URL(string: "\(baseURL)/analyze") else { return nil }

        let body = ["previewUrl": url]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

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
        request.timeoutInterval = 90.0   // 12 songs × ~7s worst-case with semaphore
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
}
