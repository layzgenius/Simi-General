// FreqBlogService.swift
// Simi — Music Discovery App
//
// FreqBlog replaces Spotify's deprecated audio_features endpoint. It runs Essentia
// on iTunes preview clips — BPM, key, danceability, and valence are reliable;
// energy, acousticness, and liveness are not (preview-clip analysis artifacts).
//
// API: GET https://api.freqblog.com/lookup?track=TITLE&artist=ARTIST
//      X-Api-Key: <key>   (injected by Cloudflare Worker)
//
// Unknown tracks return { "status": "queued", "retry_after_seconds": 30 }.
// 30s is too long to block the UI — return nil and let fallbacks handle it.
// The track will be in the catalog on the next search of the same song.

import Foundation

class FreqBlogService {

    private let proxyURL = APIKeys.freqBlogProxyURL
    private let proxyKey = APIKeys.proxyKey

    struct TrackFeatures {
        let bpm: Double
        let key: Int        // Spotify pitch class (0=C … 11=B) from key_int
        let mode: Int       // 0=minor, 1=major
        let danceability: Double   // reliable from preview
        let valence: Double        // reliable from preview
        // energy, acousticness, liveness NOT included — preview artifacts
    }

    /// Returns features for a track. Tries title+artist, then title alone.
    func fetchFeatures(title: String, artist: String) async -> TrackFeatures? {
        if let f = await lookup(track: title, artist: artist) { return f }
        if let f = await lookup(track: title, artist: "")     { return f }
        return nil
    }

    private func lookup(track: String, artist: String) async -> TrackFeatures? {
        var components = URLComponents(string: proxyURL)
        components?.queryItems = [
            URLQueryItem(name: "track",  value: track),
            URLQueryItem(name: "artist", value: artist)
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(proxyKey, forHTTPHeaderField: "X-Proxy-Key")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // 202 = queued for analysis (retry_after_seconds: 30 — too long for UI)
        guard status == 200 else { return nil }

        // Try full response first; if bpm is nil it's a queued/error body
        guard let result = try? JSONDecoder().decode(FreqBlogTrack.self, from: data),
              let bpm = result.bpm, bpm > 0 else { return nil }

        return TrackFeatures(
            bpm:          bpm,
            key:          result.key_int ?? 0,
            mode:         result.mode    ?? 1,
            danceability: result.danceability ?? 0.5,
            valence:      result.valence      ?? 0.5
        )
    }
}

// MARK: - Response Type (flat JSON)

private struct FreqBlogTrack: Decodable {
    let bpm:          Double?
    let bpm_confidence: Double?
    let key_int:      Int?      // Spotify pitch class 0-11 — use this, not the key string
    let mode:         Int?      // 0=minor, 1=major
    let key:          String?   // human-readable e.g. "C#-Minor" — ignored, key_int is cleaner
    let camelot:      String?
    let danceability: Double?
    let valence:      Double?
    // Intentionally omitted: energy, acousticness, liveness, speechiness
    // — all unreliable when computed from 30-second iTunes preview clips.
    let track_name:   String?
    let artist_name:  String?
    let genre:        String?
    let mood:         String?
    let feature_source: String?
}
