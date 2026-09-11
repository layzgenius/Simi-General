// SoundCloudService.swift
// Simi — Music Discovery App
//
// Uses SoundCloud's v2 API — the same API their own web/mobile clients use.
// No official registration needed; client_id is obtained from browser DevTools.
//
// Key endpoints:
//   /search/tracks         — find a track by title + artist
//   /tracks/{id}/related   — SoundCloud's recommendation engine ("Up Next")
//
// Why SoundCloud matters for discovery: niche artists (trap, hyperpop, emo rap,
// underground hip-hop) often exist primarily or exclusively on SoundCloud.
// Their co-listening graph reflects an underground demographic that doesn't
// scrobble on Last.fm or buy on Discogs — it's unique signal.

import Foundation

class SoundCloudService {

    private let baseURL = "https://api-v2.soundcloud.com"
    private var cachedClientId: String? = nil

    // Fetches the current client_id from the Worker (which auto-extracts it from
    // SoundCloud's web client JS). Falls back to the static key in APIKeys if the
    // Worker is unreachable — so the app still works even if the Worker is down.
    private func getClientId() async -> String {
        if let cached = cachedClientId { return cached }

        if let url = URL(string: APIKeys.soundcloudCidURL) {
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            req.setValue(APIKeys.proxyKey, forHTTPHeaderField: "X-Proxy-Key")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONDecoder().decode([String: String].self, from: data),
               let id = json["client_id"], !id.isEmpty {
                simiLog("🔑 SoundCloud client_id refreshed from Worker")
                cachedClientId = id
                return id
            }
        }

        // Worker miss — fall back to static key
        let fallback = APIKeys.soundcloudClientId
        if !fallback.isEmpty { cachedClientId = fallback }
        return fallback
    }

    // ──────────────────────────────────────────────
    // MARK: - Similar Tracks (main pool source)
    // ──────────────────────────────────────────────

    /// Returns tracks similar to the given song using SoundCloud's recommendation engine.
    /// Two-hop: search for the track → get its related tracks via /tracks/{id}/related.
    /// Returns [] when SoundCloud doesn't have the track or client_id is unavailable.
    func fetchRelatedTracks(title: String, artist: String) async -> [(title: String, artist: String)] {
        let clientId = await getClientId()
        guard !clientId.isEmpty else {
            simiLog("⚠️ SoundCloud: client_id unavailable — skipping")
            return []
        }
        guard let trackId = await searchTrackId(title: title, artist: artist, clientId: clientId) else { return [] }

        let query = "client_id=\(clientId)&limit=20"
        guard let url = URL(string: "\(baseURL)/tracks/\(trackId)/related?\(query)") else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        guard let result = try? JSONDecoder().decode(SCTrackCollection.self, from: data) else { return [] }
        let tracks = result.collection.map { (title: $0.title, artist: $0.user.username) }
        simiLog("🎵 SoundCloud related (\(tracks.count)): \(tracks.prefix(4).map { "\($0.artist) — \($0.title)" }.joined(separator: ", "))")
        return tracks
    }

    // ──────────────────────────────────────────────
    // MARK: - Track Search
    // ──────────────────────────────────────────────

    /// Searches SoundCloud for a track and returns its numeric ID.
    /// Prefers an exact artist match when multiple results are returned.
    private func searchTrackId(title: String, artist: String, clientId: String) async -> Int? {
        let raw = "\(artist) \(title)"
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/search/tracks?q=\(encoded)&client_id=\(clientId)&limit=10") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(SCTrackCollection.self, from: data),
              !result.collection.isEmpty else { return nil }

        // Prefer a result where the username matches the artist (case-insensitive)
        let artistLower = artist.lowercased()
        let bestMatch = result.collection.first {
            $0.user.username.lowercased().contains(artistLower) ||
            artistLower.contains($0.user.username.lowercased())
        } ?? result.collection.first

        return bestMatch?.id
    }
}

// ──────────────────────────────────────────────
// MARK: - Response Models
// ──────────────────────────────────────────────

private struct SCTrackCollection: Decodable, Sendable {
    let collection: [SCTrack]
}

private struct SCTrack: Decodable, Sendable {
    let id: Int
    let title: String
    let user: SCUser
}

private struct SCUser: Decodable, Sendable {
    let username: String
}
