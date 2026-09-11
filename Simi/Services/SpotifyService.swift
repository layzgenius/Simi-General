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

// ──────────────────────────────────────────────
// MARK: - Search Circuit Breaker
// ──────────────────────────────────────────────

/// Shared across all SpotifyService instances. When Spotify returns 429,
/// all search calls stop immediately for 60 seconds — no piling on.
private actor SearchCircuitBreaker {
    static let shared = SearchCircuitBreaker()
    private var blockedUntil: Date?

    var isOpen: Bool {
        guard let until = blockedUntil else { return false }
        if Date() > until { blockedUntil = nil; return false }
        return true
    }

    func trip(retryAfter: TimeInterval? = nil) {
        // Don't extend an existing block — first 429 sets the window
        guard blockedUntil == nil || Date() > blockedUntil! else { return }
        // Use Spotify's Retry-After header when available; clamp 30–300s
        let wait = min(max(retryAfter ?? 60, 30), 300)
        blockedUntil = Date().addingTimeInterval(wait)
        simiLog("🚧 Spotify search circuit breaker tripped — pausing all searches for \(Int(wait))s")
    }

    func reset() {
        blockedUntil = nil
    }
}

class SpotifyService {

    // Thread-safe token cache — prevents concurrent token refreshes racing each other
    private let tokenCache = TokenCache()
    private let circuitBreaker = SearchCircuitBreaker.shared

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
            sourceURL: track.externalURLs.spotify,
            releaseYear: track.album.releaseYear
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
        // Don't fire if circuit breaker is open — fail fast, save quota
        guard await !circuitBreaker.isOpen else {
            throw SimiError.rateLimited
        }

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/search?q=\(encoded)&type=track&limit=1") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
            await circuitBreaker.trip(retryAfter: retryAfter)
            throw SimiError.rateLimited
        }
        let result = try JSONDecoder().decode(SpotifySearchResult.self, from: data)

        guard let track = result.tracks.items.first else { return nil }

        return Song(
            id: track.id,
            title: track.name,
            artist: track.artists.first?.name ?? "Unknown Artist",
            albumArt: track.album.images.first?.url ?? "",
            previewURL: track.previewURL,
            spotifyURL: track.externalURLs.spotify,
            sourceURL: "\(baseURL)/tracks/\(track.id)",
            releaseYear: track.album.releaseYear
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Artist Genre Lookup
    // ──────────────────────────────────────────────

    /// Returns Spotify's artist genre list using a track-ID two-hop lookup.
    ///
    /// Spotify uses the "Every Noise at Once" taxonomy — thousands of micro-genre
    /// labels like "new orleans rap", "vapor trap", "chamber pop", "dark clubbing".
    /// These are far more specific than Last.fm track tags and are maintained at
    /// scale, making them the best available signal for subgenre disambiguation.
    ///
    /// The search endpoint returns simplified artist objects (no genres field).
    /// The full artist object — reachable via /artists/{id} — carries the genre list.
    /// We get the artist ID from the track object, avoiding artist-name ambiguity.
    ///
    /// Used by RecommendationEngine to anchor audio-derived tag queries to the
    /// correct subgenre rather than guessing from audio features alone.
    func fetchArtistGenres(forTrackId trackId: String) async -> [String] {
        guard !trackId.isEmpty else {
            simiLog("🎸 fetchArtistGenres: empty trackId — skipping")
            return []
        }
        guard !trackId.hasPrefix("itunes:") else { return [] }
        guard let token = try? await getAccessToken() else {
            simiLog("🎸 fetchArtistGenres: token fetch failed")
            return []
        }

        // Hop 1: track → artist ID
        var trackRequest = URLRequest(url: URL(string: "\(baseURL)/tracks/\(trackId)")!)
        trackRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        trackRequest.timeoutInterval = 5

        struct TrackArtistStub: Decodable {
            struct ArtistIdItem: Decodable { let id: String }
            let artists: [ArtistIdItem]
        }

        guard let (trackData, trackResp) = try? await session.data(for: trackRequest) else {
            simiLog("🎸 fetchArtistGenres: hop1 network error for trackId \(trackId)")
            return []
        }
        guard (trackResp as? HTTPURLResponse)?.statusCode == 200 else {
            simiLog("🎸 fetchArtistGenres: hop1 HTTP \((trackResp as? HTTPURLResponse)?.statusCode ?? -1) for trackId \(trackId)")
            return []
        }
        guard let trackObj = try? JSONDecoder().decode(TrackArtistStub.self, from: trackData),
              let artistId = trackObj.artists.first?.id else {
            simiLog("🎸 fetchArtistGenres: hop1 decode failed for trackId \(trackId)")
            return []
        }

        // Hop 2: artist ID → full artist object → genres
        var artistRequest = URLRequest(url: URL(string: "\(baseURL)/artists/\(artistId)")!)
        artistRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        artistRequest.timeoutInterval = 5

        struct ArtistFull: Decodable { let name: String; let genres: [String]? }

        guard let (artistData, artistResp) = try? await session.data(for: artistRequest) else {
            simiLog("🎸 fetchArtistGenres: hop2 network error for artistId \(artistId)")
            return []
        }
        guard (artistResp as? HTTPURLResponse)?.statusCode == 200 else {
            simiLog("🎸 fetchArtistGenres: hop2 HTTP \((artistResp as? HTTPURLResponse)?.statusCode ?? -1) for artistId \(artistId)")
            return []
        }
        guard let artist = try? JSONDecoder().decode(ArtistFull.self, from: artistData) else {
            simiLog("🎸 fetchArtistGenres: hop2 decode failed for artistId \(artistId)")
            return []
        }

        let genres = artist.genres ?? []
        simiLog("🎸 Spotify genres for \(artist.name): \(genres.isEmpty ? "(none on Spotify)" : genres.prefix(5).joined(separator: ", "))")
        return genres
    }

    // ──────────────────────────────────────────────
    // MARK: - Related Artists
    // ──────────────────────────────────────────────

    /// Returns artist names from Spotify's related-artists graph for the given track's primary artist.
    /// Uses Spotify's 600M-user co-listening data — covers niche artists that Last.fm lacks.
    /// Two-hop: track ID → artist ID → /related-artists.
    func fetchRelatedArtists(forTrackId trackId: String) async -> [String] {
        guard !trackId.isEmpty, !trackId.hasPrefix("itunes:"), !trackId.hasPrefix("stub:") else { return [] }
        guard let token = try? await getAccessToken() else { return [] }

        var trackRequest = URLRequest(url: URL(string: "\(baseURL)/tracks/\(trackId)")!)
        trackRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        trackRequest.timeoutInterval = 5

        struct TrackArtistStub: Decodable {
            struct ArtistIdItem: Decodable { let id: String }
            let artists: [ArtistIdItem]
        }

        guard let (trackData, trackResp) = try? await session.data(for: trackRequest),
              (trackResp as? HTTPURLResponse)?.statusCode == 200,
              let trackObj = try? JSONDecoder().decode(TrackArtistStub.self, from: trackData),
              let artistId = trackObj.artists.first?.id else { return [] }

        var relatedRequest = URLRequest(url: URL(string: "\(baseURL)/artists/\(artistId)/related-artists")!)
        relatedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        relatedRequest.timeoutInterval = 5

        struct RelatedArtistsResponse: Decodable {
            struct Artist: Decodable { let name: String }
            let artists: [Artist]
        }

        guard let (relData, relResp) = try? await session.data(for: relatedRequest),
              (relResp as? HTTPURLResponse)?.statusCode == 200,
              let related = try? JSONDecoder().decode(RelatedArtistsResponse.self, from: relData) else { return [] }

        let names = related.artists.map { $0.name }
        simiLog("🎸 Spotify related artists (\(names.count)): \(names.prefix(5).joined(separator: ", "))")
        return names
    }

    /// Two-hop expansion of Spotify's related-artists graph.
    /// Hop-1: artists directly related to the source artist.
    /// Hop-2: for the 5 closest hop-1 artists, fetch their related artists too.
    /// Returns a deduplicated list (hop-1 first, then new hop-2 discoveries).
    func fetchRelatedArtistsDeep(forTrackId trackId: String) async -> [String] {
        guard !trackId.isEmpty, !trackId.hasPrefix("itunes:"), !trackId.hasPrefix("stub:") else { return [] }
        guard let token = try? await getAccessToken() else { return [] }

        // Hop 0: resolve track → primary artist ID
        struct TrackArtistStub: Decodable {
            struct Item: Decodable { let id: String }
            let artists: [Item]
        }
        var trackReq = URLRequest(url: URL(string: "\(baseURL)/tracks/\(trackId)")!)
        trackReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        trackReq.timeoutInterval = 5
        guard let (trackData, trackResp) = try? await session.data(for: trackReq),
              (trackResp as? HTTPURLResponse)?.statusCode == 200,
              let trackObj = try? JSONDecoder().decode(TrackArtistStub.self, from: trackData),
              let artistId = trackObj.artists.first?.id else { return [] }

        // Hop 1: primary artist → related artists (names + IDs needed for hop-2)
        var hop1Req = URLRequest(url: URL(string: "\(baseURL)/artists/\(artistId)/related-artists")!)
        hop1Req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        hop1Req.timeoutInterval = 5
        guard let (hop1Data, hop1Resp) = try? await session.data(for: hop1Req),
              (hop1Resp as? HTTPURLResponse)?.statusCode == 200,
              let hop1 = try? JSONDecoder().decode(SpotifyRelatedArtistsResponse.self, from: hop1Data) else { return [] }

        var seen = Set<String>()
        var ordered: [String] = []
        for a in hop1.artists {
            if seen.insert(a.name.lowercased()).inserted { ordered.append(a.name) }
        }
        simiLog("🎸 Spotify hop-1 (\(hop1.artists.count) artists): \(hop1.artists.prefix(5).map { $0.name }.joined(separator: ", "))")

        // Hop 2: for the 5 closest hop-1 artists, fetch their related artists concurrently
        await withTaskGroup(of: [SpotifyRelatedArtistsResponse.Artist].self) { group in
            for hopArtist in hop1.artists.prefix(5) {
                let aid = hopArtist.id
                group.addTask {
                    var req = URLRequest(url: URL(string: "\(self.baseURL)/artists/\(aid)/related-artists")!)
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 4
                    guard let (data, resp) = try? await self.session.data(for: req),
                          (resp as? HTTPURLResponse)?.statusCode == 200,
                          let res = try? JSONDecoder().decode(SpotifyRelatedArtistsResponse.self, from: data) else { return [] }
                    return res.artists
                }
            }
            for await artists in group {
                for a in artists {
                    if seen.insert(a.name.lowercased()).inserted { ordered.append(a.name) }
                }
            }
        }
        simiLog("🎸 Spotify deep graph: \(ordered.count) unique artists after 2-hop expansion")
        return ordered
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
                    sourceURL: track.externalURLs.spotify,
                    releaseYear: track.album.releaseYear
                )
            }
        } catch {
            simiLog("⚠️ Spotify recommendations failed: \(error)")
            return []
        }
    }

    /// Fetches songs targeted to a specific mood point (valence × energy) using genre seeds.
    /// Used by the mood coordinate search — no reference track required.
    func getRecommendationsByMood(valence: Double, arousal: Double, limit: Int = 20) async throws -> [Song] {
        do {
            let token = try await getAccessToken()

            let energyMin  = max(0.0, arousal  - 0.25)
            let energyMax  = min(1.0, arousal  + 0.25)
            let valenceMin = max(0.0, valence  - 0.25)
            let valenceMax = min(1.0, valence  + 0.25)

            let paramParts = [
                "seed_genres=pop,rock,hip-hop,electronic,indie",
                "limit=\(limit)",
                "target_valence=\(String(format: "%.2f", valence))",
                "target_energy=\(String(format: "%.2f", arousal))",
                "min_energy=\(String(format: "%.2f", energyMin))",
                "max_energy=\(String(format: "%.2f", energyMax))",
                "min_valence=\(String(format: "%.2f", valenceMin))",
                "max_valence=\(String(format: "%.2f", valenceMax))",
            ]
            let params = paramParts.joined(separator: "&")

            var request = URLRequest(url: URL(string: "\(baseURL)/recommendations?\(params)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                simiLog("⚠️ Spotify mood recommendations unavailable")
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
                    sourceURL: track.externalURLs.spotify,
                    releaseYear: track.album.releaseYear
                )
            }
        } catch {
            simiLog("⚠️ Spotify mood recommendations failed: \(error)")
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

// Shared response type for /artists/{id}/related-artists — used in both hop-1 and
// hop-2 calls in fetchRelatedArtistsDeep. Defined at file scope so it is nonisolated
// and can be decoded inside a non-main-actor TaskGroup.
private struct SpotifyRelatedArtistsResponse: Decodable, Sendable {
    struct Artist: Decodable, Sendable { let name: String; let id: String }
    let artists: [Artist]
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
    let releaseDate: String?
    enum CodingKeys: String, CodingKey {
        case name, images
        case releaseDate = "release_date"
    }
    var releaseYear: Int? {
        guard let d = releaseDate else { return nil }
        return Int(d.prefix(4))
    }
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

