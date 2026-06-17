// MusicBrainzService.swift
// Simi — Music Discovery App
//
// MusicBrainz is a free, open music metadata encyclopedia.
// We use it for one thing: looking up a song's MusicBrainz Recording ID (MBID),
// which is the universal key we need to fetch AcousticBrainz audio features.
//
// No API key required — just a descriptive User-Agent header (their policy).
// Rate limit: ~1 req/sec. We stagger requests in the caller to stay under that.

import Foundation

class MusicBrainzService {

    private let baseURL   = "https://musicbrainz.org/ws/2"
    // MusicBrainz requires a User-Agent that identifies your app + contact
    private let userAgent = "Simi/1.0 (batboyskip@gmail.com)"

    // ──────────────────────────────────────────────
    // MARK: - Find MBID for a Track
    // ──────────────────────────────────────────────

    /// Searches MusicBrainz for a recording and returns its MBID.
    /// Returns nil gracefully if the track isn't in the database.
    func findMBID(title: String, artist: String) async -> String? {
        // Build a Lucene query: recording:"title" AND artist:"artist"
        // Quotes around the values help match exact phrases
        let rawQuery = "recording:\"\(title)\" AND artist:\"\(artist)\""
        guard let encoded = rawQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/recording?query=\(encoded)&fmt=json&limit=3") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        guard let result = try? JSONDecoder().decode(MBRecordingSearch.self, from: data),
              let best = result.recordings.first else {
            return nil
        }

        print("🎵 MusicBrainz MBID for \"\(title)\" by \(artist): \(best.id) (score: \(best.score ?? 0))")
        return best.id
    }
}

// ──────────────────────────────────────────────
// MARK: - Response Models
// ──────────────────────────────────────────────

private struct MBRecordingSearch: Codable {
    let recordings: [MBRecording]
}

private struct MBRecording: Codable {
    let id: String       // This is the MBID we want
    let score: Int?      // Relevance score 0–100 (higher = better match)
    let title: String?
}
