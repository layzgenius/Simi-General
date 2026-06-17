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

    // ──────────────────────────────────────────────
    // MARK: 🔑 YOUR API KEYS — Fill these in!
    // ──────────────────────────────────────────────
    private let clientID     = "819d78936ba64c0185161cf917873977"
    private let clientSecret = "34e4f125bc48494ead249d0c3a513950"

    // Internal token storage — Spotify requires a fresh token every hour
    private var accessToken: String?
    private var tokenExpiry: Date?

    // Base URL for all Spotify API calls
    private let baseURL = "https://api.spotify.com/v1"

    // ──────────────────────────────────────────────
    // MARK: - Authentication
    // ──────────────────────────────────────────────

    /// Gets a fresh Spotify access token using Client Credentials flow.
    /// This is the simplest auth method — no user login needed for search + audio features.
    func getAccessToken() async throws -> String {
        // Return cached token if it's still valid (with 60-second buffer)
        if let token = accessToken,
           let expiry = tokenExpiry,
           Date() < expiry.addingTimeInterval(-60) {
            return token
        }

        // Encode credentials as Base64 (Spotify requires this format)
        let credentials = "\(clientID):\(clientSecret)"
        guard let credData = credentials.data(using: .utf8) else {
            throw SimiError.authFailed
        }
        let base64Creds = credData.base64EncodedString()

        // Build the token request
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("Basic \(base64Creds)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=client_credentials".data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)

        // Cache the token
        self.accessToken = response.accessToken
        self.tokenExpiry = Date().addingTimeInterval(Double(response.expiresIn))

        return response.accessToken
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

        let (data, _) = try await URLSession.shared.data(for: request)
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
    // MARK: - Fetch Audio Features
    // ──────────────────────────────────────────────

    /// Gets the "audio fingerprint" for a track — BPM, energy, mood, etc.
    /// Returns nil gracefully if Spotify's endpoint is restricted (403).
    func fetchAudioFeatures(trackID: String) async throws -> AudioFeatures {
        let token = try await getAccessToken()

        var request = URLRequest(url: URL(string: "\(baseURL)/audio-features/\(trackID)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SimiError.apiError("audio-features restricted (need Extended Quota Mode)")
        }

        let features = try JSONDecoder().decode(SpotifyAudioFeatures.self, from: data)

        return AudioFeatures(
            bpm: features.tempo,
            energy: features.energy,
            valence: features.valence,
            danceability: features.danceability,
            acousticness: features.acousticness,
            instrumentalness: features.instrumentalness,
            liveness: features.liveness,
            loudness: features.loudness,
            key: features.key,
            mode: features.mode
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Search Spotify for a Song
    // ──────────────────────────────────────────────

    /// Searches Spotify by artist + title — used when we get a YouTube URL
    /// and need to find the Spotify equivalent
    func searchTrack(title: String, artist: String) async throws -> Song? {
        let token = try await getAccessToken()

        let query = "\(title) \(artist)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        var request = URLRequest(url: URL(string: "\(baseURL)/search?q=\(query)&type=track&limit=1")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
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

    /// Asks Spotify's recommendation engine for similar tracks.
    /// We feed it the seed track + the audio features to get targeted results.
    func getRecommendations(
        seedTrackID: String,
        features: AudioFeatures,
        limit: Int = 20
    ) async throws -> [Song] {
        do {
            let token = try await getAccessToken()

            // Build query with BPM ±10 range, similar energy and valence
            let bpmMin = max(60, Int(features.bpm) - 10)
            let bpmMax = Int(features.bpm) + 10
            let energyMin = max(0.0, features.energy - 0.2)
            let energyMax = min(1.0, features.energy + 0.2)
            let valenceMin = max(0.0, features.valence - 0.2)
            let valenceMax = min(1.0, features.valence + 0.2)

            let params = [
                "seed_tracks=\(seedTrackID)",
                "limit=\(limit)",
                "min_tempo=\(bpmMin)",
                "max_tempo=\(bpmMax)",
                "min_energy=\(String(format: "%.2f", energyMin))",
                "max_energy=\(String(format: "%.2f", energyMax))",
                "min_valence=\(String(format: "%.2f", valenceMin))",
                "max_valence=\(String(format: "%.2f", valenceMax))"
            ].joined(separator: "&")

            var request = URLRequest(url: URL(string: "\(baseURL)/recommendations?\(params)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("⚠️ Spotify recommendations unavailable (restricted endpoint — needs Extended Quota Mode)")
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
            print("⚠️ Spotify recommendations failed: \(error)")
            return []
        }
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

private struct SpotifyAudioFeatures: Codable {
    let tempo: Double
    let energy: Double
    let valence: Double
    let danceability: Double
    let acousticness: Double
    let instrumentalness: Double
    let liveness: Double
    let loudness: Double
    let key: Int
    let mode: Int
}

private struct SpotifySearchResult: Codable {
    let tracks: SpotifyTrackPage
}
private struct SpotifyTrackPage: Codable {
    let items: [SpotifyTrack]
}
private struct SpotifyRecommendationResult: Codable {
    let tracks: [SpotifyTrack]
}
