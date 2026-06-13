// AcousticBrainzService.swift
// Simi — Music Discovery App
//
// AcousticBrainz is a community-powered audio features database built by MetaBrainz.
// It stores machine-analyzed audio fingerprints for millions of songs:
//   - High-level: mood, danceability, energy, acousticness, instrumentalness
//   - Low-level:  BPM, key, scale, loudness
//
// No API key required. Free, open data. Works via MusicBrainz recording IDs (MBIDs).
//
// Data collection ended in 2022, but the existing database is still live and covers
// a huge catalog — especially good for music pre-2022 (classic, rock, pop, etc.)

import Foundation

class AcousticBrainzService {

    private let baseURL = "https://acousticbrainz.org/api/v1"

    // ──────────────────────────────────────────────
    // MARK: - Fetch Full Audio Features
    // ──────────────────────────────────────────────

    /// Fetches both low-level (BPM, key) and high-level (mood, energy, valence) data in parallel.
    /// Returns nil if AcousticBrainz doesn't have data for this MBID.
    func fetchFeatures(mbid: String) async -> AudioFeatures? {
        async let lowTask  = fetchLowLevel(mbid: mbid)
        async let highTask = fetchHighLevel(mbid: mbid)

        guard let low = await lowTask, let high = await highTask else {
            simiLog("⚠️ AcousticBrainz: no data for MBID \(mbid)")
            return nil
        }

        return AudioFeatures(
            bpm:              low.rhythm.bpm,
            energy:           high.energy,
            valence:          high.valence,
            danceability:     high.danceability,
            acousticness:     high.acousticness,
            instrumentalness: high.instrumentalness,
            liveness:         0.0,   // AB doesn't classify liveness
            loudness:         loudnessInDB(from: low.lowlevel.averageLoudness),
            key:              keyIndex(from: low.tonal.keyKey),
            mode:             low.tonal.keyScale == "major" ? 1 : 0
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Private Fetch Helpers
    // ──────────────────────────────────────────────

    private func fetchLowLevel(mbid: String) async -> ABLowLevelResponse? {
        guard let url = URL(string: "\(baseURL)/\(mbid)/low-level") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        return try? JSONDecoder().decode(ABLowLevelResponse.self, from: data)
    }

    private func fetchHighLevel(mbid: String) async -> ABHighLevelProcessed? {
        guard let url = URL(string: "\(baseURL)/\(mbid)/high-level") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        guard let raw = try? JSONDecoder().decode(ABHighLevelResponse.self, from: data) else { return nil }
        return ABHighLevelProcessed(from: raw.highlevel)
    }

    // ──────────────────────────────────────────────
    // MARK: - Conversion Helpers
    // ──────────────────────────────────────────────

    /// Convert AB's average_loudness (0–1 linear) to Spotify-style dB (-60 to 0)
    private func loudnessInDB(from avgLoudness: Double) -> Double {
        // avg_loudness ≈ 1.0 → loud → ~0 dB
        // avg_loudness ≈ 0.0 → quiet → ~-60 dB
        return (avgLoudness - 1.0) * 60.0
    }

    /// Convert note name ("C", "C#", "D" …) to Spotify-style key index (0–11)
    private func keyIndex(from key: String) -> Int {
        let keys = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        // Also handle flat spellings Bb→A#, Eb→D#, etc.
        let flatMap: [String: String] = [
            "Bb": "A#", "Eb": "D#", "Ab": "G#", "Db": "C#", "Gb": "F#"
        ]
        let normalized = flatMap[key] ?? key
        return keys.firstIndex(of: normalized) ?? 0
    }
}

// ──────────────────────────────────────────────
// MARK: - Low-Level Response Models
// ──────────────────────────────────────────────

private struct ABLowLevelResponse: Codable {
    let rhythm:   ABRhythm
    let tonal:    ABTonal
    let lowlevel: ABLowLevelBlock
}

private struct ABRhythm: Codable {
    let bpm: Double
}

private struct ABTonal: Codable {
    let keyKey:   String
    let keyScale: String

    enum CodingKeys: String, CodingKey {
        case keyKey   = "key_key"
        case keyScale = "key_scale"
    }
}

private struct ABLowLevelBlock: Codable {
    let averageLoudness: Double

    enum CodingKeys: String, CodingKey {
        case averageLoudness = "average_loudness"
    }
}

// ──────────────────────────────────────────────
// MARK: - High-Level Response Models
// ──────────────────────────────────────────────

private struct ABHighLevelResponse: Codable {
    let highlevel: ABHighLevelData
}

/// Each high-level descriptor from AcousticBrainz looks like:
/// { "value": "danceable", "probability": 0.87 }
/// The probability is always P(value) — i.e. confidence in that specific label.
private struct ABClassifier: Codable {
    let value:       String
    let probability: Double
}

private struct ABHighLevelData: Codable {
    let danceability:     ABClassifier
    let moodHappy:        ABClassifier
    let moodRelaxed:      ABClassifier
    let moodAggressive:   ABClassifier
    let moodAcoustic:     ABClassifier
    let moodParty:        ABClassifier
    let voiceInstrumental: ABClassifier

    enum CodingKeys: String, CodingKey {
        case danceability
        case moodHappy         = "mood_happy"
        case moodRelaxed       = "mood_relaxed"
        case moodAggressive    = "mood_aggressive"
        case moodAcoustic      = "mood_acoustic"
        case moodParty         = "mood_party"
        case voiceInstrumental = "voice_instrumental"
    }
}

// ──────────────────────────────────────────────
// MARK: - Processed High-Level Values
// Maps AB's classifier labels → Spotify-compatible 0.0–1.0 floats
// ──────────────────────────────────────────────

private struct ABHighLevelProcessed {

    let energy:           Double   // 0 = calm, 1 = intense
    let valence:          Double   // 0 = sad/dark, 1 = happy/upbeat
    let danceability:     Double   // 0 = not danceable, 1 = very danceable
    let acousticness:     Double   // 0 = electronic, 1 = acoustic
    let instrumentalness: Double   // 0 = vocals, 1 = instrumental

    init(from data: ABHighLevelData) {
        // AB "probability" = confidence in the named value.
        // If value == "danceable" and probability == 0.87 → P(danceable) = 0.87
        // If value == "not_danceable" and probability == 0.87 → P(danceable) = 1 - 0.87 = 0.13
        // Helper: resolve P(positive_label) regardless of which label is in "value"

        func p(_ classifier: ABClassifier, positiveLabel: String) -> Double {
            classifier.value == positiveLabel
                ? classifier.probability
                : 1.0 - classifier.probability
        }

        // Energy ≈ inverse of relaxation (relaxed = low energy, aggressive/party = high energy)
        // We blend: 60% from anti-relaxed, 40% from party/aggressive
        let antiRelaxed = 1.0 - p(data.moodRelaxed, positiveLabel: "relaxed")
        let partyBoost  = p(data.moodParty, positiveLabel: "party")
        energy = (antiRelaxed * 0.6 + partyBoost * 0.4).clamped(to: 0...1)

        // Valence = happiness. Cross-check: unhappy + aggressive = drag valence down.
        let happiness = p(data.moodHappy, positiveLabel: "happy")
        let aggression = p(data.moodAggressive, positiveLabel: "aggressive")
        valence = (happiness * 0.8 + (1.0 - aggression) * 0.2).clamped(to: 0...1)

        danceability     = p(data.danceability,      positiveLabel: "danceable")
        acousticness     = p(data.moodAcoustic,      positiveLabel: "acoustic")
        instrumentalness = p(data.voiceInstrumental, positiveLabel: "instrumental")
    }
}

// ──────────────────────────────────────────────
// MARK: - Clamped Helper
// ──────────────────────────────────────────────

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
