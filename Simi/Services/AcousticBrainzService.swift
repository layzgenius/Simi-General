// AcousticBrainzService.swift
// Simi — Music Discovery App
//
// Queries the AcousticBrainz frozen dump (7.5M tracks, keyed by MBID) via the
// HF Space /ab-lookup endpoint. The Space serves lookups from a local SQLite file
// populated by import_acousticbrainz.py from the July 2022 frozen dump.
//
// Returns real BPM, key, mode, energy, and danceability — all from Essentia signal
// analysis, not genre estimates. The primary use case is candidates that don't have
// an iTunes preview URL, where FreqBlog can't run and tag estimation is the fallback.
//
// The AB live API shut down Feb 2022. This service goes through our own backend.

import Foundation

class AcousticBrainzService {

    private let lookupURL = "https://layzskolah-simi-audio-analyzer.hf.space/ab-lookup"

    // ──────────────────────────────────────────────
    // MARK: - Lookup
    // ──────────────────────────────────────────────

    /// Returns low-level audio features from the AcousticBrainz frozen dump for the
    /// given MusicBrainz Recording ID. Returns nil when the MBID isn't in the dump
    /// or the Space is unavailable — callers should treat nil as a graceful miss.
    func fetchFeatures(mbid: String) async -> AcousticBrainzFeatures? {
        guard !mbid.isEmpty,
              var components = URLComponents(string: lookupURL) else { return nil }
        components.queryItems = [URLQueryItem(name: "mbid", value: mbid)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(ABLookupResponse.self, from: data) else {
            return nil
        }

        simiLog("📀 AcousticBrainz: \(mbid) — \(Int(result.bpm))BPM k:\(result.key) m:\(result.mode) e:\(String(format:"%.2f",result.energy))")
        return AcousticBrainzFeatures(
            bpm:         result.bpm,
            key:         result.key,
            mode:        result.mode,
            energy:      result.energy,
            danceability: result.danceability
        )
    }
}

// ──────────────────────────────────────────────
// MARK: - Models
// ──────────────────────────────────────────────

struct AcousticBrainzFeatures {
    let bpm:          Double
    let key:          Int
    let mode:         Int
    let energy:       Double
    let danceability: Double
}

private struct ABLookupResponse: Codable {
    let bpm:          Double
    let key:          Int
    let mode:         Int
    let energy:       Double
    let danceability: Double
}
