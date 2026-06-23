// Song.swift
// Simi — Music Discovery App
//
// This file defines the core data models used throughout the app.
// A "model" is just a blueprint that describes what data a song has.

import Foundation

// MARK: - Song
// Represents the song the user pastes in — the one they love
struct Song: Identifiable, Codable, Equatable {
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
struct AudioFeatures: Codable, Sendable, Equatable {
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
    var grooveRatio: Double?           // onset_std / onset_mean — syncopation proxy (funky ~0.8–1.8, smooth ~0.3–0.7)
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
        grooveRatio: Double? = nil,
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
        self.grooveRatio      = grooveRatio
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
        grooveRatio      = try c.decodeIfPresent(Double.self,   forKey: .grooveRatio)
        arousal          = try c.decodeIfPresent(Double.self,    forKey: .arousal)
        valenceEssentia  = try c.decodeIfPresent(Double.self,    forKey: .valenceEssentia)
        dclapEmbedding   = try c.decodeIfPresent([Double].self,  forKey: .dclapEmbedding)
    }

    // Human-readable helpers

    /// Returns the BPM for display and vibeSummary. Applies a display-time half-time
    /// correction when librosa has detected double-time on a low-energy track — e.g. a
    /// ~72 BPM bedroom R&B song reads as 143 because librosa locked onto the subdivisions.
    /// Only fires for measured features (not estimated) with energy < 0.50 in the 130–155 range.
    var normalizedBPM: Double {
        if !isEstimated && energy < 0.50 && bpm > 130 && bpm <= 155 { return bpm / 2 }
        return bpm
    }

    var bpmFormatted: String { normalizedBPM > 0 ? "\(Int(normalizedBPM)) BPM" : "BPM unknown" }
    var keyName: String {
        let keys = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let modeName = mode == 1 ? "Major" : "Minor"
        return keys[safe: key].map { "\($0) \(modeName)" } ?? "Unknown"
    }

    // Vibe summary — 8 labels derived from a composite kinetic score.
    // Pure energy-gating mislabeled high-danceability/BPM tracks: HUMBLE. (150 BPM,
    // dance=0.90, energy=0.61) scored "mid-energy" and landed "Moody & Driving";
    // Seven Nation Army (heavy, minor, val=0.26) also got "Moody & Driving". The
    // composite score weights felt kinetic energy across all three dimensions.
    //
    //   kinetic = energy×0.40 + danceability×0.35 + min(bpm/160, 1)×0.25
    //
    // Labels: Energetic & Upbeat · Hype & Hard · Intense & Dark · Warm & Groovy
    //         Moody & Driving · Smooth & Mellow · Chill & Happy · Melancholic & Calm
    var vibeSummary: String {
        let nbpm = normalizedBPM
        let kinetic = energy * 0.40 + danceability * 0.35 + min(nbpm / 160.0, 1.0) * 0.25

        // ── HIGH KINETIC (> 0.65) ────────────────────────────────────────────
        // e.g. HUMBLE.=0.79, Uptown Funk=0.83, Master of Puppets=0.68
        if kinetic > 0.65 {
            if valence > 0.55 { return "Energetic & Upbeat" }
            // Dark/neutral + kinetic + danceable: drill, dark trap, hard rap, industrial dance.
            // e.g. HUMBLE. (dance=0.90), Sicko Mode (dance=0.67), Y FI DAT (dance=0.68, val=0.51).
            if danceability > 0.65 { return "Hype & Hard" }
            // Dark + kinetic + low danceability: metal, hard rock, dark electronic.
            // e.g. Master of Puppets (dance=0.38), Blinding Lights (dance=0.51).
            return "Intense & Dark"
        }

        // ── MID KINETIC (0.40 – 0.65) ────────────────────────────────────────
        // e.g. Seven Nation Army=0.65, Africa (Toto)=0.61, God's Plan=0.56
        if kinetic > 0.40 {
            if valence > 0.55 {
                // BPM gate prevents slow R&B ballads (68 BPM, high Spotify danceability)
                // from landing on Warm & Groovy — they belong in Smooth & Mellow.
                if danceability > 0.62 && nbpm > 85 { return "Warm & Groovy" }
                return "Smooth & Mellow"
            }
            // Very low valence OR minor-key dark without groove → driven and heavy, not sad.
            // Four gates cover different "dark" shapes:
            //   1. val < 0.25            — universally very dark (Revenge, Creep chorus)
            //   2. minor + val<0.35 + low dance  — slow/moderate minor dark (Lose Yourself, In the End)
            //   3. minor + val<0.42 + active BPM — fast minor moderately dark (Come As You Are,
            //      Seven Nation Army) but NOT quiet slow grunge (All Apologies, nbpm=80)
            //   4. minor + val<0.50 + fast BPM — metal/hard-rock where the 30-second preview
            //      captures a quiet intro (Enter Sandman: energy=0.32, valence=0.45, BPM=123).
            //      No danceability gate: librosa's tempo sweet-spot formula (peak at 120 BPM) gives
            //      high dance scores to any 110-130 BPM track, making danceability useless here.
            //      Mode + tempo alone reliably identify fast minor-key heavy songs in mid-kinetic range.
            if valence < 0.25
                || (mode == 0 && valence < 0.35 && danceability < 0.65)
                || (mode == 0 && valence < 0.42 && danceability < 0.70 && nbpm > 100)
                || (mode == 0 && valence < 0.50 && nbpm > 110) {
                return "Intense & Dark"
            }
            return "Moody & Driving"
        }

        // ── LOW ENERGY (≤ 0.40) ──────────────────────────────────────────────
        // Major-key slow songs route to warm labels before Melancholic.
        if mode == 1 && nbpm > 0 && nbpm <= 115 && valence > 0.55 { return "Smooth & Mellow" }
        if valence > 0.55 { return "Chill & Happy" }
        if mode == 1 && nbpm > 0 && nbpm <= 115 && valence >= 0.45 && danceability > 0.55 { return "Warm & Groovy" }
        if mode == 1 && nbpm > 0 && nbpm <= 115 && valence >= 0.35 { return "Smooth & Mellow" }
        // Fast minor-key tracks where the 30s preview captured a quiet intro section.
        // The actual song is heavy — use mode + tempo as the stable signal.
        if nbpm > 110 && mode == 0 && valence < 0.45 { return "Intense & Dark" }
        if nbpm > 110 && mode == 0 { return "Moody & Driving" }
        if valence >= 0.45 { return "Smooth & Mellow" }
        return "Melancholic & Calm"
    }
}

// MARK: - FeedbackState
enum FeedbackState: String, Codable {
    case fits, close, miss
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

    // Human-readable match explanation with specific dimensions
    var matchExplanation: MatchExplanation? = nil

    // Feedback state — session-only, not persisted to Supabase.
    // Set via engine.setFeedback(songID:state:) — never mutate directly (struct value copy).
    var feedbackState: FeedbackState? = nil

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

// MARK: - MatchExplanation
// Pre-computed human-readable explanation of why a song was recommended.
// Generated in enrichWithABFeatures alongside matchReasons; never persisted to Supabase.
struct MatchExplanationRow: Codable {
    let label: String       // e.g. "Emotional weight"
    let descriptor: String  // e.g. "Same melancholic weight"
}

struct MatchExplanation: Codable {
    let rows: [MatchExplanationRow]  // only rows where data is reliable and dimensions are close
    let genreBridgeLabel: String?    // e.g. "Jazz → Hip-Hop"; nil when same genre family
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
