// DiscogsService.swift
// Simi — Music Discovery App
//
// Fetches genre/style tags from the Discogs database for a source track.
// Discogs styles are more specific than Last.fm tags (e.g. "Boom Bap", "Dub Techno",
// "Electro") and get merged into earlyTags before the Last.fm tag pool runs —
// so they automatically feed `selectEmotionalQueries` with no extra pool logic.
//
// Free API, no auth required for 25 req/min. One call per recommendation session.
// Requires a User-Agent header identifying the app (Discogs policy).

import Foundation

class DiscogsService {

    private let searchURL  = "https://api.discogs.com/database/search"
    private let userAgent  = "SimiApp/1.0 (music discovery; contact via HF Space)"

    // ──────────────────────────────────────────────
    // MARK: - Fetch Styles
    // ──────────────────────────────────────────────

    /// Returns lowercased Discogs genre + style strings for the given track.
    /// Searches releases by title + artist, takes the first confident match.
    /// Returns [] on any miss or network failure — always safe to call.
    func fetchStyles(title: String, artist: String) async -> [String] {
        guard !title.isEmpty, !artist.isEmpty,
              var components = URLComponents(string: searchURL) else { return [] }

        components.queryItems = [
            URLQueryItem(name: "q",        value: "\(title) \(artist)"),
            URLQueryItem(name: "type",     value: "release"),
            URLQueryItem(name: "per_page", value: "3"),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(DiscogsSearchResponse.self, from: data),
              let release = result.results.first else { return [] }

        let styles = ((release.genre ?? []) + (release.style ?? []))
            .map { $0.lowercased() }

        if !styles.isEmpty {
            simiLog("💿 Discogs styles for \(title): \(styles.prefix(6).joined(separator: ", "))")
        }
        return styles
    }
}

// ──────────────────────────────────────────────
// MARK: - Models
// ──────────────────────────────────────────────

private struct DiscogsSearchResponse: Codable {
    let results: [DiscogsRelease]
}

private struct DiscogsRelease: Codable {
    let genre: [String]?
    let style: [String]?
}
