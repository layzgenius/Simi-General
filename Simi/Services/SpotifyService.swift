// SpotifyService.swift
// Simi — Music Discovery App
//
// Handles all communication with the Spotify Web API.
// This is the heart of Simi — Spotify gives us BPM, energy, mood, etc.
//
// SETUP REQUIRED:
//   1. Go to https://developer.spotify.com/dashboard
//   2. Create an app → copy Client ID and Client Secret
//   3. Paste them in the constants below

import Foundation

class SpotifyService {

    // Thread-safe token cache — prevents concurrent token refreshes racing each other
    private let tokenCache = TokenCache()

    // Shared URLSession with a 10-second request timeout
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 10
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    // Base URL for all Spotify API calls
    private let baseURL = "https://api.spotify.com/v1"

    // ──────────────────────────────────────────────
    // MARK: - Authentication
    // ──────────────────────────────────────────────

    /// Gets a Spotify access token via the Simi token proxy.
    /// Credentials live server-side (Cloudflare Worker) — never in the app binary.
    func getAccessToken() async throws -> String {
        // Return cached token if still valid — thread-safe via TokenCache actor
        if let cached = await tokenCache.validToken() { return cached }

        guard let url = URL(string: APIKeys.spotifyProxyURL) else {
            throw SimiError.authFailed
        }

        var request = URLRequest(url: url)
        request.setValue(APIKeys.proxyKey, forHTTPHeaderField: "X-App-Key")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SimiError.authFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        // Store in thread-safe cache
        let expiry = Date().addingTimeInterval(Double(tokenResponse.expiresIn))
        await tokenCache.set(token: tokenResponse.accessToken, expiry: expiry)

        return tokenResponse.accessToken
    }

    // ──────────────────────────────────────────────
    // MARK: - Extract Spotify Track ID from URL
    // ──────────────────────────────────────────────

    /// Pulls the track ID out of a Spotify URL.
    /// Example: "https://open.spotify.com/track/3n3Ppam7vgaVa1iaRUIOKE" → "3n3Ppam7vgaVa1iaRUIOKE"
    func extractTrackID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // Path looks like: /track/3n3Ppam7vgaVa1iaRUIOKE
        let pathParts = components.path.split(separator: "/")
        guard pathParts.count >= 2, pathParts[0] == "track" else { return nil }
        return String(pathParts[1])
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Song by Track ID
    // ──────────────────────────────────────────────

    /// Given a Spotify track ID, returns a full Song object with all metadata
    func fetchSong(trackID: String) async throws -> Song {
        let token = try await getAccessToken()

        var request = URLRequest(url: URL(string: "\(baseURL)/tracks/\(trackID)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)
        let track = try JSONDecoder().decode(SpotifyTrack.self, from: data)

        return Song(
            id: track.id,
            title: track.name,
            artist: track.artists.first?.name ?? "Unknown Artist",
            albumArt: track.album.images.first?.url ?? "",
            previewURL: track.previewURL,
            spotifyURL: track.externalURLs.spotify,
            sourceURL: track.externalURLs.spotify
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Search Spotify for a Song
    // ──────────────────────────────────────────────

    /// Searches Spotify by title + artist using a three-stage strategy:
    ///   1. Field-filtered  — track:"X" artist:"Y"  (most precise — avoids cross-artist hits)
    ///   2. Title-only      — track:"X"             (catches mismatched artist names, e.g. SoundCloud handles)
    ///   3. Freetext        — "X Y"                 (last resort for unusual titles)
    ///
    /// Every candidate is validated against the search title before being returned.
    /// This prevents Spotify returning a wildly wrong song when it can't find an exact match.
    func searchTrack(title: String, artist: String) async throws -> Song? {
        let token = try await getAccessToken()

        // Strategy 1: field-filtered — precise
        let fieldQuery = "track:\(title) artist:\(artist)"
        if let song = try? await _searchSpotify(query: fieldQuery, token: token),
           titleMatches(returned: song.title, searched: title) {
            return song
        }

        // Strategy 2: title-only — handles SoundCloud handles, YouTube channel names, etc.
        let titleQuery = "track:\(title)"
        if let song = try? await _searchSpotify(query: titleQuery, token: token),
           titleMatches(returned: song.title, searched: title) {
            return song
        }

        // Strategy 3: freetext fallback — last resort
        let freeQuery = "\(title) \(artist)"
        if let song = try? await _searchSpotify(query: freeQuery, token: token),
           titleMatches(returned: song.title, searched: title) {
            return song
        }

        return nil
    }

    /// True when the Spotify-returned title is a plausible match for the search title.
    /// Prevents accepting a completely wrong song when Spotify finds no real match.
    private func titleMatches(returned: String, searched: String) -> Bool {
        let r = returned.lowercased()
        let s = searched.lowercased()

        // Direct containment (most common case)
        if r.contains(s) || s.contains(r) { return true }

        // Word-overlap fallback: ≥50% of meaningful search words appear in the returned title.
        // Handles slight rewording, featured-artist suffixes, etc.
        let words = s.components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 }
        guard !words.isEmpty else { return true }
        let hits = words.filter { r.contains($0) }
        return Double(hits.count) / Double(words.count) >= 0.5
    }

    /// Low-level Spotify search — fires a single query and returns the first track.
    private func _searchSpotify(query: String, token: String) async throws -> Song? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/search?q=\(encoded)&type=track&limit=1") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)
        let result = try JSONDecoder().decode(SpotifySearchResult.self, from: data)

        guard let track = result.tracks.items.first else { return nil }

        return Song(
            id: track.id,
            title: track.name,
            artist: track.artists.first?.name ?? "Unknown Artist",
            albumArt: track.album.images.first?.url ?? "",
            previewURL: track.previewURL,
            spotifyURL: track.externalURLs.spotify,
            sourceURL: "\(baseURL)/tracks/\(track.id)"
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Get Recommendations
    // ──────────────────────────────────────────────

    /// Single-seed convenience wrapper — calls the multi-seed variant.
    func getRecommendations(
        seedTrackID: String,
        features: AudioFeatures,
        limit: Int = 20
    ) async throws -> [Song] {
        return try await getRecommendations(seedTrackIDs: [seedTrackID], features: features, limit: limit)
    }

    /// Asks Spotify's recommendation engine for similar tracks.
    /// Supports up to 5 seed track IDs (Spotify's limit).
    /// We feed it the seed tracks + blended audio features to get targeted results.
    func getRecommendations(
        seedTrackIDs: [String],
        features: AudioFeatures,
        limit: Int = 20
    ) async throws -> [Song] {
        do {
            let token = try await getAccessToken()

            // Spotify allows max 5 combined seeds
            let seeds = seedTrackIDs.prefix(5).joined(separator: ",")

            let energyMin = max(0.0, features.energy - 0.2)
            let energyMax = min(1.0, features.energy + 0.2)
            let valenceMin = max(0.0, features.valence - 0.2)
            let valenceMax = min(1.0, features.valence + 0.2)

            // Only include BPM constraints when we have a real measured tempo.
            // bpm==0 means no data available — sending min_tempo=60&max_tempo=10 returns nothing.
            var paramParts = [
                "seed_tracks=\(seeds)",
                "limit=\(limit)",
                "min_energy=\(String(format: "%.2f", energyMin))",
                "max_energy=\(String(format: "%.2f", energyMax))",
                "min_valence=\(String(format: "%.2f", valenceMin))",
                "max_valence=\(String(format: "%.2f", valenceMax))",
            ]
            if features.bpm > 0 {
                paramParts += [
                    "min_tempo=\(max(60, Int(features.bpm) - 10))",
                    "max_tempo=\(Int(features.bpm) + 10)",
                ]
            }
            let params = paramParts.joined(separator: "&")

            var request = URLRequest(url: URL(string: "\(baseURL)/recommendations?\(params)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                simiLog("⚠️ Spotify recommendations unavailable (restricted endpoint — needs Extended Quota Mode)")
                return []
            }

            let result = try JSONDecoder().decode(SpotifyRecommendationResult.self, from: data)

            return result.tracks.map { track in
                Song(
                    id: track.id,
                    title: track.name,
                    artist: track.artists.first?.name ?? "Unknown Artist",
                    albumArt: track.album.images.first?.url ?? "",
                    previewURL: track.previewURL,
                    spotifyURL: track.externalURLs.spotify,
                    sourceURL: track.externalURLs.spotify
                )
            }
        } catch {
            simiLog("⚠️ Spotify recommendations failed: \(error)")
            return []
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Token Cache (thread-safe)
// ──────────────────────────────────────────────

/// Protects accessToken / tokenExpiry from concurrent refresh races.
/// Using an actor ensures only one task reads or writes at a time.
private actor TokenCache {
    private var token: String?
    private var expiry: Date?

    /// Returns a cached token if still valid (with 60s buffer), else nil.
    func validToken() -> String? {
        guard let t = token, let e = expiry,
              Date() < e.addingTimeInterval(-60) else { return nil }
        return t
    }

    func set(token: String, expiry: Date) {
        self.token = token
        self.expiry = expiry
    }
}

// ──────────────────────────────────────────────
// MARK: - Internal Spotify API Response Types
// These match exactly what Spotify sends back in JSON.
// You don't need to touch these.
// ──────────────────────────────────────────────

private struct TokenResponse: Codable {
    let accessToken: String
    let expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

private struct SpotifyTrack: Codable {
    let id: String
    let name: String
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum
    let previewURL: String?
    let externalURLs: SpotifyExternalURLs
    enum CodingKeys: String, CodingKey {
        case id, name, artists, album
        case previewURL = "preview_url"
        case externalURLs = "external_urls"
    }
}

private struct SpotifyArtist: Codable { let name: String }
private struct SpotifyAlbum: Codable {
    let name: String
    let images: [SpotifyImage]
}
private struct SpotifyImage: Codable { let url: String }
private struct SpotifyExternalURLs: Codable { let spotify: String }

private struct SpotifySearchResult: Codable {
    let tracks: SpotifyTrackPage
}
private struct SpotifyTrackPage: Codable {
    let items: [SpotifyTrack]
}
private struct SpotifyRecommendationResult: Codable {
    let tracks: [SpotifyTrack]
}

