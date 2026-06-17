// Song.swift
// Simi — Music Discovery App
//
// This file defines the core data models used throughout the app.
// A "model" is just a blueprint that describes what data a song has.

import Foundation

// MARK: - Song
// Represents the song the user pastes in — the one they love
struct Song: Identifiable, Codable {
    var id: String          // Unique ID from Spotify (e.g. "3n3Ppam7vgaVa1iaRUIOKE")
    var title: String       // Song name
    var artist: String      // Artist name
    var albumArt: String    // URL to the cover image
    var previewURL: String? // 30-second preview audio (optional — not all songs have one)
    var spotifyURL: String  // Link back to Spotify
    var sourceURL: String   // The URL the user originally pasted (Spotify, YouTube, etc.)

    // Audio fingerprint — the "DNA" of the song
    var audioFeatures: AudioFeatures?
}

// MARK: - AudioFeatures
// Spotify gives us these numbers for every song.
// They're the secret sauce behind matching songs that "feel" the same.
struct AudioFeatures: Codable {
    var bpm: Double         // Beats per minute — e.g. 120.4
    var energy: Double      // 0.0 (calm) to 1.0 (intense) — think lullaby vs. EDM drop
    var valence: Double     // 0.0 (sad/dark) to 1.0 (happy/upbeat)
    var danceability: Double // 0.0 (not danceable) to 1.0 (very danceable)
    var acousticness: Double // 0.0 (electronic) to 1.0 (fully acoustic)
    var instrumentalness: Double // 0.0 (has vocals) to 1.0 (purely instrumental)
    var liveness: Double    // Probability it was recorded live
    var loudness: Double    // In decibels — usually between -60 and 0

    // The musical key (0 = C, 1 = C#, 2 = D, etc.) and mode (0 = minor, 1 = major)
    var key: Int
    var mode: Int

    // True when features were estimated from genre tags rather than measured by AcousticBrainz.
    // Used to render estimated dots differently on the Vibe Map.
    var isEstimated: Bool = false

    // Human-readable helpers
    var bpmFormatted: String { bpm > 0 ? "\(Int(bpm)) BPM" : "BPM unknown" }
    var keyName: String {
        let keys = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let modeName = mode == 1 ? "Major" : "Minor"
        return keys[safe: key].map { "\($0) \(modeName)" } ?? "Unknown"
    }

    // Vibe summary — a short label based on energy + valence
    var vibeSummary: String {
        switch (energy > 0.6, valence > 0.5) {
        case (true, true):   return "Energetic & Upbeat"
        case (true, false):  return "Intense & Dark"
        case (false, true):  return "Chill & Happy"
        case (false, false): return "Melancholic & Calm"
        }
    }
}

// MARK: - Genre
// Genre + sub-genre pair — sourced from Last.fm tags or Spotify artist data
struct Genre: Identifiable, Codable, Hashable {
    var id: String { "\(main)-\(sub ?? "")" }
    var main: String        // e.g. "Indie Pop"
    var sub: String?        // e.g. "Dream Pop", "Bedroom Pop"
}

// MARK: - SimilarSong
// A song recommended because it matches the user's input song
struct SimilarSong: Identifiable, Codable {
    var id: String
    var title: String
    var artist: String
    var albumArt: String
    var spotifyURL: String
    var previewURL: String?

    var genre: Genre
    var audioFeatures: AudioFeatures?

    // How similar is this song to the original? 0.0 to 1.0
    var similarityScore: Double

    // Why was this recommended?
    var matchReasons: [MatchReason]

    // Human-readable match percentage
    var similarityLabel: String {
        "\(Int(similarityScore * 100))% match"
    }
}

// MARK: - MatchReason
// Tells the user *why* a song was recommended — makes the app feel smart
enum MatchReason: String, Codable, CaseIterable {
    case bpm          = "Similar BPM"
    case genre        = "Same Genre"
    case subGenre     = "Same Sub-Genre"
    case energy       = "Similar Energy"
    case vibe         = "Same Vibe"
    case acoustics    = "Similar Sound"
    case mood         = "Same Mood"
}

// MARK: - URLSource
// Which platform did the user paste from?
enum URLSource: String, CaseIterable {
    case spotify    = "Spotify"
    case youtube    = "YouTube"
    case soundcloud = "SoundCloud"
    case unknown    = "Unknown"

    static func detect(from urlString: String) -> URLSource {
        let lower = urlString.lowercased()
        if lower.contains("spotify.com")    { return .spotify }
        if lower.contains("youtube.com") || lower.contains("youtu.be") { return .youtube }
        if lower.contains("soundcloud.com") { return .soundcloud }
        return .unknown
    }
}

// MARK: - Safe Array Index Helper
// This prevents crashes when accessing an array index that might not exist
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
