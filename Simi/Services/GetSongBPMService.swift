// GetSongBPMService.swift
// Simi — Music Discovery App
//
// GetSongBPM is a dedicated BPM database — much more accurate than Deezer's
// tempo detector, especially for genres where Deezer halves or doubles the tempo.
//
// Requests are routed through the Cloudflare Worker proxy — the real API key
// lives server-side as a Worker environment secret (GETSONGBPM_KEY).
//
// Upstream: GET https://api.getsongbpm.com/search/?api_key=KEY&type=song&lookup=TITLE+ARTIST
// Returns:  { search: [{ title, artist: { name }, tempo, open_key, time_sig }] }

import Foundation

class GetSongBPMService {

    // ──────────────────────────────────────────────
    // MARK: - Proxy config (key held server-side)
    // ──────────────────────────────────────────────
    private let proxyURL = APIKeys.getSongBPMProxyURL
    private let proxyKey = APIKeys.proxyKey

    // ──────────────────────────────────────────────
    // MARK: - Fetch BPM for a Track
    // ──────────────────────────────────────────────

    // Combined result so we make one API call and get both BPM and key.
    struct SongData {
        let bpm: Double
        let key: Int?   // Spotify key integer (0=C … 11=B), nil if unavailable
        let mode: Int?  // 0=minor, 1=major, nil if unavailable
    }

    /// Returns BPM + musical key for a song. One call, two data points.
    func fetchSongData(title: String, artist: String) async -> SongData? {
        if let data = await searchFull(lookup: "\(title) \(artist)") { return data }
        if let data = await searchFull(lookup: title) { return data }
        return nil
    }

    /// Legacy BPM-only wrapper for callers that only need tempo.
    func fetchBPM(title: String, artist: String) async -> Double? {
        return await fetchSongData(title: title, artist: artist).map { $0.bpm }
    }

    private func searchFull(lookup: String) async -> SongData? {
        var components = URLComponents(string: proxyURL)
        components?.queryItems = [
            URLQueryItem(name: "type",   value: "song"),
            URLQueryItem(name: "lookup", value: lookup)
        ]

        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(proxyKey, forHTTPHeaderField: "X-Proxy-Key")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(GetSongBPMResult.self, from: data),
              let first = result.search.first,
              let tempoStr = first.tempo,
              let bpm = Double(tempoStr), bpm > 0 else {
            return nil
        }

        // Parse Open Key notation ("2m" = E minor, "1d" = C major, etc.)
        let (key, mode) = parseOpenKey(first.open_key)
        return SongData(bpm: bpm, key: key, mode: mode)
    }

    /// Converts GetSongBPM's Open Key string to Spotify-style (key: 0-11, mode: 0/1).
    /// Open Key uses a circle-of-fifths number (1-12) + d (major) or m (minor).
    /// Returns (nil, nil) when the string is missing or unrecognisable.
    private func parseOpenKey(_ openKey: String?) -> (Int?, Int?) {
        guard let raw = openKey?.trimmingCharacters(in: .whitespaces).lowercased(),
              raw.count >= 2 else { return (nil, nil) }

        let suffix = raw.last!               // 'd' or 'm'
        let numberStr = String(raw.dropLast())
        guard let number = Int(numberStr), number >= 1, number <= 12 else { return (nil, nil) }

        // Circle-of-fifths index → Spotify pitch class (0=C, 1=C#, 2=D … 11=B)
        // Open Key 1=C/Am, 2=G/Em, 3=D/Bm, 4=A/F#m, 5=E/C#m, 6=B/G#m,
        //          7=F#/D#m, 8=C#/A#m, 9=Ab/Fm, 10=Eb/Cm, 11=Bb/Gm, 12=F/Dm
        let majorKeys = [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5] // index 0 = OpenKey 1
        let minorKeys = [9, 4, 11, 6, 1, 8, 3, 10, 5, 0, 7, 2]

        let idx = number - 1
        if suffix == "d" {
            return (majorKeys[idx], 1)
        } else if suffix == "m" {
            return (minorKeys[idx], 0)
        }
        return (nil, nil)
    }
}

// ──────────────────────────────────────────────
// MARK: - API Response Types
// ──────────────────────────────────────────────

private struct GetSongBPMResult: Codable {
    let search: [GetSongBPMTrack]
}

private struct GetSongBPMTrack: Codable {
    let title: String?
    let tempo: String?          // BPM as a string e.g. "149"
    let open_key: String?       // Musical key in Open Key notation
    let time_sig: String?       // e.g. "4/4"
    let artist: GetSongBPMArtist?
}

private struct GetSongBPMArtist: Codable {
    let name: String?
}
