// DeezerService.swift
// Simi — Music Discovery App
//
// Deezer's public API requires zero authentication for read-only calls.
// We use it for two things:
//   1. Track search — find a song by title + artist
//   2. BPM data    — Deezer stores BPM for most tracks
//
// No API key needed. No sign-up required.

import Foundation

class DeezerService {

    private let baseURL = "https://api.deezer.com"

    // ──────────────────────────────────────────────
    // MARK: - Search
    // ──────────────────────────────────────────────

    /// Search Deezer for a track, returns the best match with BPM
    func searchTrack(title: String, artist: String) async throws -> DeezerTrack? {
        let query = buildQuery(title: title, artist: artist)
        guard let url = URL(string: "\(baseURL)/search?q=\(query)&limit=5") else { return nil }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let result = try JSONDecoder().decode(DeezerSearchResponse.self, from: data)
        let best = result.data.first

        // Fetch full track to get BPM (search results don't include BPM)
        if let id = best?.id {
            return try await fetchTrack(id: id)
        }
        return best
    }

    /// Fetch full track details by Deezer track ID — includes BPM
    func fetchTrack(id: Int) async throws -> DeezerTrack? {
        guard let url = URL(string: "\(baseURL)/track/\(id)") else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(DeezerTrack.self, from: data)
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    private func buildQuery(title: String, artist: String) -> String {
        let raw = artist.isEmpty
            ? "track:\"\(title)\""
            : "artist:\"\(artist)\" track:\"\(title)\""
        return raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    }
}

// ──────────────────────────────────────────────
// MARK: - Response Models
// ──────────────────────────────────────────────

struct DeezerSearchResponse: Codable {
    let data: [DeezerTrack]
}

struct DeezerTrack: Codable, Identifiable {
    let id: Int
    let title: String
    let artist: DeezerArtist
    let album: DeezerAlbum?
    let bpm: Double?
    let duration: Int?
    let preview: String?      // 30-second MP3 preview URL
    let link: String?         // Full Deezer track URL

    /// Safe BPM — returns 0 if Deezer doesn't have data for this track
    var bpmValue: Double { bpm ?? 0 }

    /// Formatted BPM string matching AudioFeatures.bpmFormatted style
    var bpmFormatted: String {
        let val = Int(bpm ?? 0)
        return val > 0 ? "\(val) BPM" : "BPM unknown"
    }
}

struct DeezerArtist: Codable {
    let id: Int
    let name: String
    let picture: String?
    let pictureSmall: String?

    enum CodingKeys: String, CodingKey {
        case id, name, picture
        case pictureSmall = "picture_small"
    }
}

struct DeezerAlbum: Codable {
    let id: Int
    let title: String
    let cover: String?
    let coverSmall: String?
    let coverMedium: String?

    enum CodingKeys: String, CodingKey {
        case id, title, cover
        case coverSmall   = "cover_small"
        case coverMedium  = "cover_medium"
    }
}
