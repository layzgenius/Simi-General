// ListenBrainzService.swift
// Simi — Music Discovery App
//
// Wraps two ListenBrainz/MetaBrainz candidate-fetch paths:
//
// ── Path A: ListenBrainz Labs (preferred) ──────────────────────────────────
//   1. GET labs.api.listenbrainz.org/acr-lookup/json
//        ?artist_credit_name=X&recording_name=Y
//      → returns recording_mbid (fast, no rate-limit sleep required)
//
//   2. GET labs.api.listenbrainz.org/similar-recordings/json
//        ?recording_mbids=<mbid>&algorithm=session_based_days_7500_…
//      → returns ranked list of {recording_mbid, recording_name,
//        artist_credit_name, score} — session-based collaborative filtering
//        from 100M+ real listening sessions; handles metal/soul/pop equally
//        because it uses listening behavior, not genre tags
//
// ── Path B: lb-radio fallback ──────────────────────────────────────────────
//   fetchSimilarRecordings(mbid:) — JSPF playlist endpoint; kept as fallback
//   for the rare case where Labs has no data for a recording.
//   Caller is responsible for providing the MBID (from MusicBrainzService).
//
// No API key required for either path.

import Foundation

class ListenBrainzService {

    private let baseURL   = "https://api.listenbrainz.org"
    private let labsURL   = "https://labs.api.listenbrainz.org"
    private let userAgent = "Simi/1.0 (batboyskip@gmail.com)"

    // ──────────────────────────────────────────────
    // MARK: - Path A: Labs ACR Lookup
    // ──────────────────────────────────────────────

    /// Resolves a title + artist to a MusicBrainz Recording ID via the Labs
    /// Artist Credit Recording (ACR) lookup. No rate-limit sleep needed.
    ///
    /// GET /acr-lookup/json?artist_credit_name=X&recording_name=Y
    /// Response: [{recording_mbid, artist_credit_name, recording_name, ...}]
    func resolveACRMBID(title: String, artist: String) async -> String? {
        guard var components = URLComponents(string: "\(labsURL)/acr-lookup/json") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "artist_credit_name", value: artist),
            URLQueryItem(name: "recording_name",     value: title),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let results = try? JSONDecoder().decode([ACRResult].self, from: data),
              let first = results.first else {
            return nil
        }

        simiLog("🎵 Labs ACR: MBID for \"\(title)\" by \(artist) → \(first.recording_mbid)")
        return first.recording_mbid
    }

    // ──────────────────────────────────────────────
    // MARK: - Path A: Labs Similar Recordings
    // ──────────────────────────────────────────────

    /// Fetches similar recordings from the ListenBrainz Labs session-based
    /// collaborative filtering model. Returns up to 50 (title, artist) pairs
    /// ranked by co-listening score.
    ///
    /// GET /similar-recordings/json?recording_mbids=X&algorithm=Y
    /// Response: [{recording_mbid, recording_name, artist_credit_name, score, …}]
    ///
    /// The response already includes recording_name + artist_credit_name —
    /// no additional MBID→metadata lookup is required.
    func fetchLabsSimilarTracks(mbid: String) async -> [(title: String, artist: String)] {
        let algorithm = "session_based_days_7500_session_300_contribution_5_threshold_15_limit_50_skip_30"
        guard var components = URLComponents(string: "\(labsURL)/similar-recordings/json") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "recording_mbids", value: mbid),
            URLQueryItem(name: "algorithm",       value: algorithm),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let results = try? JSONDecoder().decode([LabsSimilarRecording].self, from: data),
              !results.isEmpty else {
            return []
        }

        // Sort descending by score (API usually returns sorted, but be safe)
        let sorted = results.sorted { $0.score > $1.score }
        let tracks = sorted.compactMap { rec -> (title: String, artist: String)? in
            let t = rec.recording_name.trimmingCharacters(in: .whitespaces)
            let a = rec.artist_credit_name.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !a.isEmpty else { return nil }
            return (title: t, artist: a)
        }

        simiLog("🎵 Labs similar-recordings: \(tracks.count) results for MBID \(mbid)")
        return tracks
    }

    // ──────────────────────────────────────────────
    // MARK: - Path B: lb-radio Fallback
    // ──────────────────────────────────────────────

    /// Returns up to ~20 similar recording (title, artist) pairs via the
    /// lb-radio JSPF playlist endpoint.
    /// Used as a fallback when the Labs similar-recordings endpoint returns
    /// no results for an MBID.
    func fetchSimilarRecordings(mbid: String) async -> [(title: String, artist: String)] {
        guard let url = URL(string: "\(baseURL)/1/lb-radio/playlist/similar-recordings/\(mbid)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(LBPlaylistResponse.self, from: data) else {
            return []
        }

        let tracks = result.playlist.track.compactMap { track -> (title: String, artist: String)? in
            guard !track.title.isEmpty, !track.creator.isEmpty else { return nil }
            return (title: track.title, artist: track.creator)
        }

        simiLog("🎵 LB lb-radio fallback: \(tracks.count) results for MBID \(mbid)")
        return tracks
    }
}

// ──────────────────────────────────────────────
// MARK: - Response Models
// ──────────────────────────────────────────────

// acr-lookup response item
private struct ACRResult: Codable {
    let recording_mbid: String
    let artist_credit_name: String?
    let recording_name: String?
}

// similar-recordings response item
private struct LabsSimilarRecording: Codable {
    let recording_mbid: String
    let recording_name: String
    let artist_credit_name: String
    let score: Double

    // The API returns score as an integer sometimes; handle both
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recording_mbid      = try container.decode(String.self, forKey: .recording_mbid)
        recording_name      = try container.decode(String.self, forKey: .recording_name)
        artist_credit_name  = try container.decode(String.self, forKey: .artist_credit_name)
        // Score comes back as either Int or Double depending on the algorithm
        if let intScore = try? container.decode(Int.self, forKey: .score) {
            score = Double(intScore)
        } else {
            score = (try? container.decode(Double.self, forKey: .score)) ?? 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case recording_mbid, recording_name, artist_credit_name, score
    }
}

// lb-radio JSPF playlist (Path B)
private struct LBPlaylistResponse: Codable {
    let playlist: LBPlaylist
}

private struct LBPlaylist: Codable {
    let track: [LBTrack]
}

private struct LBTrack: Codable {
    let title: String
    let creator: String
}
