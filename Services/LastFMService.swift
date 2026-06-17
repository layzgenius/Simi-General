// LastFMService.swift
// Simi — Music Discovery App
//
// Last.fm is a music data service that's great for two things:
//   1. Genre tags — it has crowd-sourced tags like "indie pop", "dream pop", "shoegaze"
//   2. Similar artists — a huge database of "fans also like" relationships
//
// SETUP REQUIRED:
//   1. Go to https://www.last.fm/api/account/create
//   2. Create an app → copy your API Key
//   3. Paste it below (no secret needed for read-only calls)

import Foundation

class LastFMService {

    // ──────────────────────────────────────────────
    // MARK: 🔑 YOUR API KEY — Fill this in!
    // ──────────────────────────────────────────────
    private let apiKey = "23610218fddced195b65de2f39796dce"
    private let baseURL = "https://ws.audioscrobbler.com/2.0"

    // ──────────────────────────────────────────────
    // MARK: - Fetch Genre Tags for a Track
    // ──────────────────────────────────────────────

    /// Returns the top genre tags for a song (e.g., ["indie pop", "dream pop", "chill"])
    /// Last.fm tags are crowd-sourced — they're surprisingly accurate for genre detection
    func fetchTags(title: String, artist: String) async throws -> [Genre] {
        let params = buildParams([
            "method": "track.getTopTags",
            "track": title,
            "artist": artist,
            "autocorrect": "1"
        ])

        guard let url = URL(string: "\(baseURL)?\(params)") else {
            throw SimiError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)

        // Last.fm returns {"error":6,"message":"..."} when track isn't found.
        // Use try? so an unknown track never crashes the whole search.
        guard let result = try? JSONDecoder().decode(LastFMTagsResult.self, from: data) else {
            return [Genre(main: "Unknown")]
        }

        // Convert raw tags into Genre objects
        // The first tag is usually the most accurate (highest count)
        let allTags = result.toptags.tag
            .prefix(5) // Take top 5 tags
            .map { $0.name.lowercased() }

        // Try to identify a main genre and sub-genre from the tag list
        let mainGenre = allTags.first ?? "Unknown"
        let subGenre = allTags.dropFirst().first

        return [Genre(main: mainGenre.capitalized, sub: subGenre?.capitalized)]
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Similar Tracks
    // ──────────────────────────────────────────────

    /// Gets a list of similar songs from Last.fm's "track.getSimilar" endpoint
    /// These are based on listening patterns — "people who liked X also liked Y"
    func fetchSimilarTracks(title: String, artist: String, limit: Int = 20) async throws -> [(title: String, artist: String)] {
        let params = buildParams([
            "method": "track.getSimilar",
            "track": title,
            "artist": artist,
            "limit": "\(limit)",
            "autocorrect": "1"
        ])

        guard let url = URL(string: "\(baseURL)?\(params)") else {
            throw SimiError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)

        // Last.fm returns an error object when the track isn't in its database.
        // Return empty gracefully rather than crashing.
        guard let result = try? JSONDecoder().decode(LastFMSimilarTracksResult.self, from: data) else {
            return []
        }

        return result.similartracks.track.map {
            (title: $0.name, artist: $0.artist.name)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Raw Tags (for feature estimation)
    // ──────────────────────────────────────────────

    /// Returns the top Last.fm tag names for a track as lowercase strings.
    /// Used downstream to estimate energy/valence when AcousticBrainz has no data.
    /// Never throws — returns [] on any error.
    func fetchRawTags(title: String, artist: String) async -> [String] {
        let params = buildParams([
            "method": "track.getTopTags",
            "track": title,
            "artist": artist,
            "autocorrect": "1"
        ])
        guard let url = URL(string: "\(baseURL)?\(params)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let result = try? JSONDecoder().decode(LastFMTagsResult.self, from: data) else {
            return []
        }
        return result.toptags.tag.prefix(8).map { $0.name.lowercased() }
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Artist Tags
    // ──────────────────────────────────────────────

    /// Returns the top genre tags for an artist (e.g. ["trap", "rap", "hip-hop"]).
    /// Used as fallback genre context when a track has no Last.fm data.
    func fetchArtistTags(artist: String) async -> [String] {
        let params = buildParams([
            "method": "artist.getTopTags",
            "artist": artist,
            "autocorrect": "1"
        ])
        guard let url = URL(string: "\(baseURL)?\(params)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let result = try? JSONDecoder().decode(LastFMTagsResult.self, from: data) else {
            return []
        }
        return result.toptags.tag.prefix(5).map { $0.name.lowercased() }
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Tracks by Tag
    // ──────────────────────────────────────────────

    /// Gets top tracks for a given Last.fm tag — used to pull in additional candidates
    /// when audio-derived tags are injected (e.g. "melodic trap", "feel good").
    func fetchTracksByTag(_ tag: String, limit: Int = 10) async -> [(title: String, artist: String)] {
        let params = buildParams([
            "method": "tag.getTopTracks",
            "tag": tag,
            "limit": "\(limit)"
        ])
        guard let url = URL(string: "\(baseURL)?\(params)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let result = try? JSONDecoder().decode(LastFMTagTopTracksResult.self, from: data) else {
            return []
        }
        return result.tracks.track.map { (title: $0.name, artist: $0.artist.name) }
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Similar Artists
    // ──────────────────────────────────────────────

    /// Gets artists similar to a given artist — useful for broadening recommendations
    func fetchSimilarArtists(artist: String) async throws -> [String] {
        let params = buildParams([
            "method": "artist.getSimilar",
            "artist": artist,
            "limit": "10",
            "autocorrect": "1"
        ])

        guard let url = URL(string: "\(baseURL)?\(params)") else {
            throw SimiError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let result = try JSONDecoder().decode(LastFMSimilarArtistsResult.self, from: data)

        return result.similarartists.artist.map { $0.name }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helper
    // ──────────────────────────────────────────────

    /// Builds the URL query string, always including the API key and JSON format flag
    private func buildParams(_ params: [String: String]) -> String {
        var all = params
        all["api_key"] = apiKey
        all["format"] = "json"

        return all.map { key, value in
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(key)=\(encodedValue)"
        }.joined(separator: "&")
    }
}

// ──────────────────────────────────────────────
// MARK: - Last.fm API Response Types
// ──────────────────────────────────────────────

private struct LastFMTagsResult: Codable {
    let toptags: LastFMTopTags
}
private struct LastFMTopTags: Codable {
    let tag: [LastFMTag]
}
private struct LastFMTag: Codable {
    let name: String
    let count: Int
}

private struct LastFMSimilarTracksResult: Codable {
    let similartracks: LastFMSimilarTracks
}
private struct LastFMSimilarTracks: Codable {
    let track: [LastFMTrack]
}
private struct LastFMTrack: Codable {
    let name: String
    let artist: LastFMTrackArtist
}
private struct LastFMTrackArtist: Codable {
    let name: String
}

private struct LastFMSimilarArtistsResult: Codable {
    let similarartists: LastFMSimilarArtists
}
private struct LastFMSimilarArtists: Codable {
    let artist: [LastFMArtist]
}
private struct LastFMArtist: Codable {
    let name: String
}

private struct LastFMTagTopTracksResult: Codable {
    let tracks: LastFMTagTopTracks
}
private struct LastFMTagTopTracks: Codable {
    let track: [LastFMTagTopTrack]
}
private struct LastFMTagTopTrack: Codable {
    let name: String
    let artist: LastFMTrackArtist
}
