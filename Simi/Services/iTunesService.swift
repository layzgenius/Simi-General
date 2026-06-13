// iTunesService.swift
// Simi — Music Discovery App
//
// Apple's iTunes Search API — completely free, no auth required.
// We use it as a genre fallback when Last.fm has no tags for a track.
//
// What it gives us:
//   • primaryGenreName  — e.g. "Hip-Hop/Rap", "Electronic", "Pop"
//   • previewUrl        — 30-second audio preview (same format as Spotify's)
//   • artworkUrl100     — album art at 100px (can swap to 600 for higher res)
//   • trackName / artistName — for validation
//
// What it doesn't give us:
//   • BPM, energy, valence — no audio features, purely metadata

import Foundation

class iTunesService {

    private let baseURL = "https://itunes.apple.com/search"

    // ──────────────────────────────────────────────
    // MARK: - Fetch Genre for a Track
    // ──────────────────────────────────────────────

    /// Returns genre tags for a song using the iTunes Search API.
    /// Tries "title + artist" first, falls back to "title" alone.
    /// Never throws — returns [] on any error.
    func fetchGenre(title: String, artist: String) async -> [Genre] {
        // Stage 1: search with both title and artist (more precise)
        if let genre = await searchGenre(term: "\(title) \(artist)") {
            return genre
        }
        // Stage 2: title only (catches cases where artist name spelling differs)
        if let genre = await searchGenre(term: title) {
            return genre
        }
        return []
    }

    /// Internal search — returns nil if no confident match found
    private func searchGenre(term: String) async -> [Genre]? {
        var components = URLComponents(string: baseURL)
        components?.queryItems = [
            URLQueryItem(name: "term",   value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit",  value: "5"),
            URLQueryItem(name: "media",  value: "music")
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(iTunesSearchResult.self, from: data),
              let track = result.results.first else {
            return nil
        }

        // Convert iTunes genre string → Genre model
        // iTunes genres look like "Hip-Hop/Rap" or "Electronic" or "Alternative"
        let genreString = track.primaryGenreName
        let parts = genreString.components(separatedBy: "/")
        let main = parts[0].trimmingCharacters(in: .whitespaces)
        let sub  = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil

        return [Genre(main: main, sub: sub)]
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Preview URL
    // ──────────────────────────────────────────────

    /// Returns the 30-second preview URL for a track, if available.
    /// Validates that the iTunes result actually matches the requested song —
    /// without this, iTunes fuzzy-matches wrong tracks entirely (e.g. searching
    /// "PUT IT ONG Yeat" returns Usher's "You Got It Bad").
    func fetchPreviewURL(title: String, artist: String) async -> String? {
        var components = URLComponents(string: baseURL)
        components?.queryItems = [
            URLQueryItem(name: "term",   value: "\(title) \(artist)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit",  value: "5"),
            URLQueryItem(name: "media",  value: "music")
        ]

        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(iTunesSearchResult.self, from: data) else {
            return nil
        }

        // Find the first result that actually matches both title and artist.
        // Uses normalised string comparison to handle punctuation / casing differences.
        let normTitle  = normalize(title)
        let normArtist = normalize(artist)

        for track in result.results {
            let tName   = normalize(track.trackName  ?? "")
            let tArtist = normalize(track.artistName ?? "")

            let titleMatch  = tName.contains(normTitle)  || normTitle.contains(tName)
            let artistMatch = tArtist.contains(normArtist) || normArtist.contains(tArtist)

            if titleMatch && artistMatch {
                return track.previewUrl
            }
        }

        // No confident match — return nil rather than a wrong preview
        return nil
    }

    /// Strips punctuation, lowercases, and collapses whitespace for loose comparison.
    private func normalize(_ s: String) -> String {
        s.lowercased()
         .components(separatedBy: .punctuationCharacters).joined()
         .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// ──────────────────────────────────────────────
// MARK: - iTunes API Response Types
// ──────────────────────────────────────────────

private struct iTunesSearchResult: Codable {
    let resultCount: Int
    let results: [iTunesTrack]
}

private struct iTunesTrack: Codable {
    let trackName: String?
    let artistName: String?
    let primaryGenreName: String
    let previewUrl: String?
    let artworkUrl100: String?
}
