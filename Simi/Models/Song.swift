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
struct AudioFeatures: Codable, Sendable {
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

    // True when the key/mode values are a default placeholder rather than a measured pitch.
    // Tag estimation and audio preview analysis do NOT detect musical key — they always
    // fall back to key=0, mode=1 (C Major). Only Spotify's audio-features endpoint gives
    // a real key. This flag prevents the Same Key filter from activating on unreliable data.
    var isKeyEstimated: Bool = true

    // Richer audio DNA — populated by librosa analysis (isEstimated=false songs only).
    // Decoded with decodeIfPresent so old cached JSON without these keys still works.
    var spectralWarmth: Double = 0.5  // 0=thin/acoustic, 1=thick/warm (lower SC bands)
    var tonalClarity: Double = 0.5    // 0=percussive/atonal, 1=melodic/harmonic (tonnetz RMS)
    var vocalPresence: Double = 0.5   // 0=instrumental/orchestral, 1=voice-forward (mel 300–3kHz ratio)
    var reverbSpace: Double = 0.5     // 0=dry & tight, 1=wet/spacious (HF spectral flatness)

    // Extended librosa features — only present when backend returns them
    var mfccMean: [Double]?
    var mfccStd: [Double]?
    var spectralContrast: [Double]?   // 7-band spectral contrast means
    var chroma: [Double]?             // 12-bin chroma CQT means
    var chromaEntropy: Double?        // normalized chroma entropy [0,1]
    var zcr: Double?                  // zero-crossing rate mean
    var rolloff: Double?              // spectral rolloff / Nyquist [0,1]
    var onsetMean: Double?
    var onsetStd: Double?
    // Essentia DEAM predictions — nil when essentia unavailable on backend
    var arousal: Double?              // DEAM arousal [0,1]
    var valenceEssentia: Double?      // DEAM valence [0,1]
    // DCLAP neural embedding — nil when backend unavailable or track not yet embedded
    var dclapEmbedding: [Double]?     // 512-dim L2-normalised DCLAP vector

    // Memberwise initializer — required because defining init(from:) suppresses
    // Swift's auto-synthesized memberwise init. All new fields default to neutral.
    nonisolated init(
        bpm: Double,
        energy: Double,
        valence: Double,
        danceability: Double,
        acousticness: Double,
        instrumentalness: Double,
        liveness: Double,
        loudness: Double,
        key: Int,
        mode: Int,
        isEstimated: Bool = false,
        isKeyEstimated: Bool = true,
        spectralWarmth: Double = 0.5,
        tonalClarity: Double = 0.5,
        vocalPresence: Double = 0.5,
        reverbSpace: Double = 0.5,
        mfccMean: [Double]? = nil,
        mfccStd: [Double]? = nil,
        spectralContrast: [Double]? = nil,
        chroma: [Double]? = nil,
        chromaEntropy: Double? = nil,
        zcr: Double? = nil,
        rolloff: Double? = nil,
        onsetMean: Double? = nil,
        onsetStd: Double? = nil,
        arousal: Double? = nil,
        valenceEssentia: Double? = nil,
        dclapEmbedding: [Double]? = nil
    ) {
        self.bpm              = bpm
        self.energy           = energy
        self.valence          = valence
        self.danceability     = danceability
        self.acousticness     = acousticness
        self.instrumentalness = instrumentalness
        self.liveness         = liveness
        self.loudness         = loudness
        self.key              = key
        self.mode             = mode
        self.isEstimated      = isEstimated
        self.isKeyEstimated   = isKeyEstimated
        self.spectralWarmth   = spectralWarmth
        self.tonalClarity     = tonalClarity
        self.vocalPresence    = vocalPresence
        self.reverbSpace      = reverbSpace
        self.mfccMean         = mfccMean
        self.mfccStd          = mfccStd
        self.spectralContrast = spectralContrast
        self.chroma           = chroma
        self.chromaEntropy    = chromaEntropy
        self.zcr              = zcr
        self.rolloff          = rolloff
        self.onsetMean        = onsetMean
        self.onsetStd         = onsetStd
        self.arousal          = arousal
        self.valenceEssentia  = valenceEssentia
        self.dclapEmbedding   = dclapEmbedding
    }

    // Custom decoder — new fields fall back to 0.5 (neutral) when absent from older
    // cached responses or tag-estimated feature objects that predate this schema.
    init(from decoder: Decoder) throws {
        let c            = try decoder.container(keyedBy: CodingKeys.self)
        bpm              = try c.decode(Double.self, forKey: .bpm)
        energy           = try c.decode(Double.self, forKey: .energy)
        valence          = try c.decode(Double.self, forKey: .valence)
        danceability     = try c.decode(Double.self, forKey: .danceability)
        acousticness     = try c.decode(Double.self, forKey: .acousticness)
        instrumentalness = try c.decode(Double.self, forKey: .instrumentalness)
        liveness         = try c.decode(Double.self, forKey: .liveness)
        loudness         = try c.decode(Double.self, forKey: .loudness)
        key              = try c.decode(Int.self,    forKey: .key)
        mode             = try c.decode(Int.self,    forKey: .mode)
        isEstimated      = try c.decodeIfPresent(Bool.self,   forKey: .isEstimated)    ?? false
        isKeyEstimated   = try c.decodeIfPresent(Bool.self,   forKey: .isKeyEstimated) ?? true
        spectralWarmth   = try c.decodeIfPresent(Double.self, forKey: .spectralWarmth) ?? 0.5
        tonalClarity     = try c.decodeIfPresent(Double.self, forKey: .tonalClarity)   ?? 0.5
        vocalPresence    = try c.decodeIfPresent(Double.self, forKey: .vocalPresence)  ?? 0.5
        reverbSpace      = try c.decodeIfPresent(Double.self, forKey: .reverbSpace)    ?? 0.5
        mfccMean         = try c.decodeIfPresent([Double].self, forKey: .mfccMean)
        mfccStd          = try c.decodeIfPresent([Double].self, forKey: .mfccStd)
        spectralContrast = try c.decodeIfPresent([Double].self, forKey: .spectralContrast)
        chroma           = try c.decodeIfPresent([Double].self, forKey: .chroma)
        chromaEntropy    = try c.decodeIfPresent(Double.self,   forKey: .chromaEntropy)
        zcr              = try c.decodeIfPresent(Double.self,   forKey: .zcr)
        rolloff          = try c.decodeIfPresent(Double.self,   forKey: .rolloff)
        onsetMean        = try c.decodeIfPresent(Double.self,   forKey: .onsetMean)
        onsetStd         = try c.decodeIfPresent(Double.self,   forKey: .onsetStd)
        arousal          = try c.decodeIfPresent(Double.self,    forKey: .arousal)
        valenceEssentia  = try c.decodeIfPresent(Double.self,    forKey: .valenceEssentia)
        dclapEmbedding   = try c.decodeIfPresent([Double].self,  forKey: .dclapEmbedding)
    }

    // Human-readable helpers

    /// Corrects half-time BPM at display time: high-energy songs (energy ≥ 0.68) with BPM
    /// in [60, 95] are typically analyzed at half-time (e.g. DnB at 172 BPM reads as 86).
    /// Applies to both fresh analysis and cached Supabase features so the display is always correct.
    var normalizedBPM: Double {
        guard bpm > 0 else { return 0 }
        if energy >= 0.68 && bpm >= 60 && bpm <= 95 { return bpm * 2 }
        return bpm
    }

    var bpmFormatted: String { normalizedBPM > 0 ? "\(Int(normalizedBPM)) BPM" : "BPM unknown" }
    var keyName: String {
        let keys = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let modeName = mode == 1 ? "Major" : "Minor"
        return keys[safe: key].map { "\($0) \(modeName)" } ?? "Unknown"
    }

    // Vibe summary — a short label based on energy + valence + mode + bpm + danceability.
    // Energy threshold is 0.7 for "Intense" — songs in the 0.45–0.7 range feel groovy/warm.
    // Mode + bpm guards prevent slow major-key ballads (End of the Road, Let's Stay Together)
    // from falling to "Melancholic & Calm": major-key songs with valence >= 0.35 get
    // "Warm & Groovy" or "Smooth & Mellow" instead. Slow major-key songs with valence > 0.55
    // are routed to "Smooth & Mellow" before the generic "Chill & Happy" check so that
    // intimate R&B ballads (Come Over, Body Party) don't read as generically upbeat.
    var vibeSummary: String {
        // Use normalizedBPM so half-time tracks (e.g. DnB stored at 86 BPM) hit the
        // correct branch. Without this, a 172 BPM DnB track stored at 86 skips the
        // fast-tempo branch entirely and may land on "Melancholic & Calm".
        let nbpm = normalizedBPM
        // Very fast tempos (DnB, hardstyle, hyperpop: >155 BPM).
        // Energy gate (≥0.5) prevents jazz in unusual time signatures (Take Five: 5/4 → 173 BPM
        // detected but energy=0.23) from misfiring here.
        // Danceability escape matches Branch 2 — DnB at 170 BPM is upbeat, not "Intense & Dark".
        if nbpm > 155 && energy >= 0.5 {
            if valence > 0.55 || danceability >= 0.65 { return "Energetic & Upbeat" }
            return "Intense & Dark"
        }
        // High energy (≥0.7): three-way split.
        //   valence > 0.55       → Energetic & Upbeat (clearly happy)
        //   danceability >= 0.65 → Energetic & Upbeat (club/EDM/dubstep: Bangarang, Turn Down for What)
        //   valence > 0.45       → Energetic & Upbeat (stadium anthem: Titanium, Eye of the Tiger)
        //   else                 → Intense & Dark (non-danceable dark: grunge, metal)
        // "Moody & Driving" is mid-energy only — never applied at ≥0.7 energy.
        if energy >= 0.7 {
            if valence > 0.55 { return "Energetic & Upbeat" }
            if danceability >= 0.65 { return "Energetic & Upbeat" }
            if valence > 0.45 { return "Energetic & Upbeat" }
            return "Intense & Dark"
        }
        // Mid energy (≥0.45): split by valence + danceability.
        // >= 0.45 (not >) closes the boundary gap so energy=0.45 songs use this branch.
        if energy >= 0.45 {
            if valence > 0.55 {
                if danceability > 0.62 { return "Warm & Groovy" }
                // Electric/compressed production at active tempo isn't "Smooth & Mellow"
                if acousticness < 0.12 && nbpm > 110 { return "Moody & Driving" }
                return "Smooth & Mellow"
            } else {
                if danceability > 0.62 {
                    // Near-positive valence + high dance = Warm & Groovy, not Moody & Driving.
                    // e.g. neutral-mood danceable pop (valence=0.52, dance=0.70) vs dark groove
                    // (valence=0.35, dance=0.70 → Moody & Driving stays correct).
                    return valence > 0.48 ? "Warm & Groovy" : "Moody & Driving"
                }
                // Very low valence (<0.20) at mid-energy is aggressive-dark, not quietly sad.
                // e.g. Revenge – XXXTentacion (energy=0.55, valence=0.11) → "Intense & Dark".
                return valence < 0.20 ? "Intense & Dark" : "Melancholic & Calm"
            }
        }
        // Low energy: slow major-key songs route to warm labels before Melancholic.
        // bpm > 0 guard prevents unknown-BPM songs (bpm=0) from firing ballad guards.
        // bpm <= 115 (inclusive) — "< 115" accidentally excluded ballads at exactly 115 BPM.
        // Slow major-key positive songs are intimate, not generically "Chill & Happy".
        if mode == 1 && nbpm > 0 && nbpm <= 115 && valence > 0.55 { return "Smooth & Mellow" }
        if valence > 0.55 { return "Chill & Happy" }
        // Raised dance threshold (0.55) prevents intimate duets (The Closer I Get to You,
        // dance=0.45) from getting "Warm & Groovy".
        if mode == 1 && nbpm > 0 && nbpm <= 115 && valence >= 0.45 && danceability > 0.55 { return "Warm & Groovy" }
        // Lowered floor (0.35) catches tender ballads like End of the Road (valence=0.37).
        if mode == 1 && nbpm > 0 && nbpm <= 115 && valence >= 0.35 { return "Smooth & Mellow" }
        // Active-tempo + electric production: energy reading is likely unreliable (quiet intro
        // or short preview from the quiet section of the track). A 120 BPM electric track with
        // near-zero acousticness is never "Smooth & Mellow" — route to "Moody & Driving".
        // e.g. Enter Sandman: 123 BPM, acousticness≈0.00, energy<0.45 due to quiet-intro preview.
        if nbpm > 110 && acousticness < 0.12 { return "Moody & Driving" }
        // Catch minor-key low-energy songs with decent valence (≥0.45) before labeling them
        // melancholic — minor key ≠ sad. e.g. a gentle lo-fi beat or minor-key folk song.
        if valence >= 0.45 { return "Smooth & Mellow" }
        return "Melancholic & Calm"
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

    // Human-readable match label — emotional at high scores, numeric otherwise.
    // "Matching…" shows while enrichment is in flight (audioFeatures still nil).
    var similarityLabel: String {
        guard audioFeatures != nil else { return "Matching…" }
        switch similarityScore {
        case 0.93...: return "Near-perfect"
        case 0.85...: return "Identical vibe"
        case 0.75...: return "Very similar"
        default:      return "\(Int(similarityScore * 100))% match"
        }
    }
}

// MARK: - MatchReason
// Tells the user *why* a song was recommended — emotionally specific, not just technical
enum MatchReason: String, Codable, CaseIterable {
    // BPM
    case bpm           = "Similar BPM"
    // Energy-specific (replaces generic "Similar Energy")
    case anthemic      = "Anthemic"         // high energy + low danceability — epic, soaring, emotional
    case danceFloor    = "Dance Floor"      // high energy + high danceability — built to move
    case highIntensity = "High Intensity"   // high energy, mixed danceability — generic intense match
    case mellowMatch   = "Mellow Match"     // both low energy (<0.45) — bedroom, calm, soft
    case energy        = "Similar Energy"   // generic fallback when energy is mid-range
    // Mood-specific (replaces generic "Same Mood")
    case darkMood      = "Dark Mood"        // both dark/heavy (valence <0.40)
    case upbeatMood    = "Upbeat Mood"      // both bright/joyful (valence >0.65)
    case mood          = "Same Mood"        // generic fallback for mid-valence matches
    // Other
    case genre         = "Same Genre"
    case subGenre      = "Same Sub-Genre"
    case acoustics     = "Acoustic Match"
    case vibe          = "Same Vibe"
    // Production texture
    case vocalHeavy         = "Vocal-heavy"
    case instrumentalFeel   = "Instrumental feel"
    case spaciousProduction = "Spacious production"
    case dryAndTight        = "Dry & tight"
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
