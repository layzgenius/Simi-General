// RecommendationEngine.swift
// Simi — Music Discovery App
//
// The brain of Simi. Coordinates Spotify, Last.fm, Deezer, MusicBrainz, ListenBrainz,
// and a HuggingFace-hosted librosa microservice to produce a ranked list of similar songs.
//
// Audio feature priority chain:
//   1. Supabase feature cache  (any prior source — instant)
//   2. HF librosa              (full measured FFT/chroma/MFCC + DEAM arousal — primary source)
//   3. SonicDNA LocalAudio     (on-device DSP: BPM, key, chroma, mfccMean — enables MFCC cosine)
//   4. Local preview analyzer  (energy + brightness) merged with tag estimation
//   5. Tag estimation alone    (genre/mood tags → energy, valence, danceability)
//   5.5. FreqBlog              (BPM always; energy/valence/danceability/key when estimated)
//   6. GetSongBPM              (BPM + key only — FreqBlog fallback)
//   7. Neutral defaults        (app still works, just less accurate scoring)
//
// Recommendation flow:
//   1. User pastes URL or types a title → resolve Spotify track
//   2. Fetch source song audio features (priority chain above)
//   3. Fetch Last.fm + ListenBrainz + vector catalog candidates in parallel
//   4. Merge and score candidates
//   5. Enrich ALL candidates with librosa + tags before showing results
//      (user sees a pre-scored, pre-sorted list on first render — no re-sort jitter)

import Foundation
import Combine

// Represents a point on the valence × arousal (mood) plane chosen by the user.
struct MoodTarget: Equatable {
    let valence: Double   // 0 = dark/sad, 1 = bright/happy
    let arousal: Double   // 0 = calm, 1 = energetic

    var label: String {
        let v = valence > 0.5 ? "Bright" : "Dark"
        let a = arousal > 0.5 ? "Energetic" : "Calm"
        return "\(v) & \(a)"
    }
}

@MainActor
class RecommendationEngine: ObservableObject {

    // ──────────────────────────────────────────────
    // MARK: - Published State (drives the UI)
    // ──────────────────────────────────────────────

    @Published var sourceSong: Song?
    @Published var blendedSongs: [Song] = []    // Populated when blending >1 seeds; empty for single-song searches
    @Published var moodTarget: MoodTarget? = nil  // Set when searching by mood coordinates; nil otherwise
    @Published var recommendations: [SimilarSong] = []
    @Published var isLoading = false
    @Published var loadingMessage = "Finding songs…"
    @Published var errorMessage: String?
    @Published var infoMessage: String?     // Non-blocking hint (e.g. YouTube radio warning)
    @Published var detectedGenres: [Genre] = []

    // ──────────────────────────────────────────────
    // MARK: - Services
    // ──────────────────────────────────────────────

    private let spotifyService      = SpotifyService()
    private let lastFMService       = LastFMService()
    private let deezerService       = DeezerService()
    private let soundCloudService   = SoundCloudService()
    private let musicBrainzService  = MusicBrainzService()
    private let listenBrainzService = ListenBrainzService()
    private let itunesService       = iTunesService()
    private let getSongBPMService   = GetSongBPMService()
    private let freqBlogService        = FreqBlogService()
    private let acousticBrainzService  = AcousticBrainzService()
    private let discogsService         = DiscogsService()
    private let simiAudioService       = SimiAudioService.shared
    private let localAudioAnalyzer  = LocalAudioAnalyzer.shared
    private let urlParser           = URLParserService()
    private let supabase            = SupabaseCacheService()
    private let previewAnalyzer      = PreviewAudioAnalyzer.shared
    let history                     = SearchHistoryManager()

    // Stored so background enrichment can re-score recommendations
    private var lastSourceFeatures: AudioFeatures?
    private var lastSeedFeatures: [AudioFeatures] = []   // Individual seed features for multi-seed scoring
    private var lastGenres: [Genre] = []

    // ──────────────────────────────────────────────
    // MARK: - Genre Fetch with iTunes Fallback
    // ──────────────────────────────────────────────

    /// Fetches genre tags for a song.
    /// Priority: Supabase cache (specific genres only) → Last.fm → iTunes Search API
    /// Returns at least [Genre(main: "Unknown")] — never empty.
    private func fetchGenresWithFallback(title: String, artist: String) async -> [Genre] {
        // Stage 0: Supabase tag cache — fast return when cache has a specific subgenre.
        // If cache only has generic umbrella labels (e.g. "pop rap", "trap"), fall through
        // to Last.fm so stale entries self-heal and the pool gets accurate genre seeds.
        if let cached = await supabase.lookupTags(title: title, artist: artist), !cached.isEmpty {
            let hasSpecific = cached.contains { Self.specificSubgenres.contains($0.lowercased()) }
            if hasSpecific { return genresFromRawTags(cached) }
            // Cache is all-generic — try Last.fm for a more specific tag before giving up.
        }

        // Stage 1: Last.fm
        if let lastFMGenres = try? await lastFMService.fetchTags(title: title, artist: artist),
           !lastFMGenres.isEmpty,
           lastFMGenres.first?.main != "Unknown" {
            let rawTags = lastFMGenres.map { $0.main.lowercased() }
            // Fire-and-forget — don't block the return path on a cache write
            Task { await supabase.storeTags(title: title, artist: artist, tags: rawTags, source: "lastfm") }
            return lastFMGenres
        }

        // Stage 2: iTunes Search API
        simiLog("⚠️ Last.fm returned no genres for \"\(title)\" — trying iTunes")
        let iTunesGenres = await itunesService.fetchGenre(title: title, artist: artist)
        if !iTunesGenres.isEmpty {
            simiLog("✅ iTunes genre fallback: \(iTunesGenres.first?.main ?? "?")")
            let rawTags = iTunesGenres.map { $0.main.lowercased() }
            Task { await supabase.storeTags(title: title, artist: artist, tags: rawTags, source: "itunes") }
            return iTunesGenres
        }

        return [Genre(main: "Unknown")]
    }

    /// Strips featured-artist credits that confuse ACR/MBID lookups.
    /// ListenBrainz often stores the recording as "Gold Feet" not "Gold Feet (feat. J.I.D.)".
    private func cleanTitleForMBID(_ title: String) -> String {
        var result = title
        let patterns = [
            "\\s*\\(feat\\..*?\\)", "\\s*\\(ft\\..*?\\)", "\\s*\\(featuring.*?\\)",
            "\\s*\\[feat\\..*?\\]", "\\s*\\[ft\\..*?\\]",
            "\\s+feat\\..*$", "\\s+ft\\..*$", "\\s+featuring.*$",
        ]
        for pattern in patterns {
            if let range = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                result.removeSubrange(range)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Checks Supabase similar_tracks_cache first; falls back to Last.fm on miss.
    /// Cache write is fire-and-forget — doesn't block the return path.
    private func fetchSimilarTracksWithCache(title: String, artist: String) async -> [(title: String, artist: String)] {
        if let cached = await supabase.lookupSimilarTracks(title: title, artist: artist), !cached.isEmpty {
            return cached
        }
        let tracks = await lastFMService.fetchSimilarTracksWithFallback(title: title, artist: artist)
        if !tracks.isEmpty {
            Task { await supabase.storeSimilarTracks(title: title, artist: artist, tracks: tracks) }
        }
        return tracks
    }

    /// Fetches similar recordings from ListenBrainz collaborative filtering.
    ///
    /// Path A (preferred): ListenBrainz Labs session-based CF model.
    ///   - ACR lookup: title+artist → MBID in one fast GET (no rate-limit sleep)
    ///   - similar-recordings: MBID → ranked (title, artist) pairs from 100M+ sessions
    ///   - Handles metal, soul, pop equally — uses listening behavior, not genre tags
    ///
    /// Path B (fallback): MusicBrainz search (1.1s sleep) + lb-radio playlist endpoint.
    ///   Only used when Labs returns no results for the recording.
    private func fetchListenBrainzTracks(title: String, artist: String) async -> [(title: String, artist: String)] {
        // Strip "feat. X" credits — ListenBrainz often stores recordings without them.
        // Try cleaned title first; fall back to original on miss.
        let clean = cleanTitleForMBID(title)

        // ── Path A: Labs (fast, genre-agnostic, session-based CF) ──
        var mbidA = await listenBrainzService.resolveACRMBID(title: clean, artist: artist)
        if mbidA == nil, clean != title {
            mbidA = await listenBrainzService.resolveACRMBID(title: title, artist: artist)
        }

        if let mbid = mbidA {
            let labsTracks = await listenBrainzService.fetchLabsSimilarTracks(mbid: mbid)
            if !labsTracks.isEmpty { return labsTracks }
            // Labs had the MBID but no similar recordings — try lb-radio on same MBID
            let radioTracks = await listenBrainzService.fetchSimilarRecordings(mbid: mbid)
            if !radioTracks.isEmpty { return radioTracks }
        }

        // ── Path B: MusicBrainz search + lb-radio (1.1s rate-limit sleep) ──
        guard let mbid = await musicBrainzService.findMBID(title: clean, artist: artist) else {
            return []
        }
        return await listenBrainzService.fetchSimilarRecordings(mbid: mbid)
    }

    /// Fetches top tracks from up to 8 artists similar to the given artist.
    /// Always-on parallel source — not a fallback. Returns up to ~40 deduplicated (title, artist) pairs.
    /// Fetches discovery candidates from artists similar to the source.
    /// Primary: Spotify related-artists (600M-user co-listening graph, works for niche artists).
    /// Fallback: Last.fm artist.getSimilar (scrobble-based, weaker for niche).
    /// Takes tracks 2-4 from each similar artist — skips their #1 hit to avoid chart-toppers.
    /// Fetches the source artist's own top tracks (excluding the source song itself).
    /// These are always the closest stylistic match and belong in the pool — the diversity
    /// filter caps them at 3 so they don't monopolize the list.
    private func fetchSourceArtistCandidates(song: Song) async -> [(title: String, artist: String)] {
        let all = await lastFMService.fetchArtistTopTracks(artist: song.artist, limit: 15)
        let sourceKey = "\(song.title)|\(song.artist)".lowercased()
        return all
            .filter { "\($0.title)|\($0.artist)".lowercased() != sourceKey }
            .prefix(12)
            .map { $0 }
    }

    private func fetchArtistSimilarCandidates(song: Song) async -> [(title: String, artist: String)] {
        // Deep 2-hop graph: hop-1 + related-of-related for 5 closest hop-1 artists.
        // Falls back to Last.fm if Spotify returns nothing (no Spotify ID, niche artist).
        let spotifyRelated = await spotifyService.fetchRelatedArtistsDeep(forTrackId: song.id)
        let similarArtists: [String]
        if !spotifyRelated.isEmpty {
            similarArtists = spotifyRelated
        } else {
            similarArtists = (try? await lastFMService.fetchSimilarArtists(artist: song.artist)) ?? []
            if !similarArtists.isEmpty {
                simiLog("🎸 Artist pool: Spotify empty → Last.fm fallback (\(similarArtists.count) artists)")
            }
        }
        guard !similarArtists.isEmpty else { return [] }

        var tracks: [(title: String, artist: String)] = []
        await withTaskGroup(of: [(title: String, artist: String)].self) { group in
            for similarArtist in similarArtists.prefix(20) {
                group.addTask {
                    let all = await self.lastFMService.fetchArtistTopTracks(artist: similarArtist, limit: 15)
                    // Skip rank-1 hit; take the next 3 (well-known but not chart-toppers).
                    // Hop-2 artists are already further from source so deeper cuts make sense.
                    return Array(all.dropFirst(min(1, all.count)).prefix(3))
                }
            }
            for await artistTracks in group { tracks += artistTracks }
        }
        var seen = Set<String>()
        return tracks.filter { t in seen.insert("\(t.title)|\(t.artist)".lowercased()).inserted }
    }

    /// Looks up the source song's raw Last.fm tags using the Supabase cache first.
    /// In production, fetchGenresWithFallback has already written the tags to Supabase,
    /// so this is almost always a fast cache hit. In debug (cache disabled), it makes
    /// one extra Last.fm call — acceptable, and the result feeds the tag pool expansion.
    private func fetchRawTagsCached(song: Song) async -> [String] {
        if let cached = await supabase.lookupTags(title: song.title, artist: song.artist) {
            return cached
        }
        return await lastFMService.fetchRawTags(title: song.title, artist: song.artist)
    }

    /// Merges two (title, artist) track lists, deduplicating by lowercase key.
    /// Primary tracks appear first; secondary tracks that are already in primary are dropped.
    private static func mergeTracks(
        primary: [(title: String, artist: String)],
        secondary: [(title: String, artist: String)]
    ) -> [(title: String, artist: String)] {
        var seen = Set<String>()
        var merged = [(title: String, artist: String)]()
        for t in primary + secondary {
            let key = "\(t.title.lowercased())|\(t.artist.lowercased())"
            if seen.insert(key).inserted { merged.append(t) }
        }
        return merged
    }

    // Specific subgenres — preferred over generic umbrella labels when present.
    // Used both in genresFromRawTags and in fetchGenresWithFallback to detect stale cache entries.
    private static let specificSubgenres: Set<String> = [
        // Hip-hop
        "cloud rap", "cloud trap", "psychedelic trap", "melodic trap", "dark trap",
        "emo rap", "emo trap", "rage rap", "boom bap", "uk drill", "phonk", "grime",
        "alternative hip hop", "alternative rap", "experimental hip hop", "punk rap",
        "rap rock", "southern hip hop", "trap soul",
        // R&B / Soul
        // "alternative rnb" / "alternative r&b" must be here so that songs like Love Galore
        // (SZA, tags: "pop rap, alternative rnb, rnb") don't resolve to hiphop family via
        // "pop rap" and escape the hiphop↔rnb genre penalty entirely.
        "alternative rnb", "alternative r&b", "alt r&b",
        "neo-soul", "neo soul", "slow jam", "quiet storm", "smooth r&b", "contemporary r&b",
        "gospel",
        // Pop / Electronic
        "dream pop", "bedroom pop", "indie pop", "indie rock", "alt-rock",
        "electropop", "synth-pop", "synth pop", "chillwave", "synthwave",
        "lo-fi", "lofi", "drum and bass", "future bass", "hyperpop", "breakcore",
        "vaporwave", "chiptune", "jersey club", "amapiano",
        // Rock
        "post-rock", "post-punk", "shoegaze", "darkwave", "hard rock", "classic rock",
        "grunge", "new wave", "progressive rock", "prog rock", "nu-metal", "metalcore",
        "pop punk", "folk rock",
        // Acoustic / World
        "disco", "funk", "ska",
        // Latin / Ibero-Caribbean — exact-match fallback behind the identity-tier all-tags scan
        "latin", "latin alternative", "latin pop", "latin jazz", "latin rock",
        "latin trap", "latin indie",
        "salsa", "cumbia", "bachata", "merengue", "vallenato", "reggaeton",
        "nueva cancion", "nueva canción", "bolero", "bossa nova",
        "afro-cuban", "afro-caribbean",
        // African / Afrodiaspora
        "afrobeats", "afropop", "afroswing", "amapiano", "afro house",
        // Caribbean
        "reggae", "dancehall",
        "americana", "bluegrass",
        // Jazz
        "jazz fusion", "smooth jazz",
    ]

    private func genresFromRawTags(_ tags: [String]) -> [Genre] {
        let generic = [
            "indie pop","dream pop","bedroom pop","indie rock","alt-rock","alternative",
            "rock","pop","hip-hop","hip hop","rap","trap","r&b","rnb","soul","neo-soul",
            "funk","electronic","edm","house","techno","ambient","lo-fi","lofi","folk",
            "acoustic","jazz","blues","classical","metal","punk","country","k-pop",
            "reggae","reggaeton","afrobeats","latin","gospel","dancehall",
        ]

        // Trap-pop detection: if "pop" appears in the top 3 tags alongside "trap" or "drill",
        // treat it as pop — not hip-hop. Ariana Grande "7 rings", Dua Lipa, Billie Eilish
        // often land here. Genuine trap/drill tracks don't carry a top-3 "pop" tag.
        let top3 = Set(tags.prefix(3).map { $0.lowercased() })
        if top3.contains("pop") && (top3.contains("trap") || top3.contains("drill")) {
            return [Genre(main: "Pop")]
        }

        // ── Identity-tier override: scan ALL tags regardless of position ──────────
        // Cultural/regional genres are routinely outranked by mainstream cross-genre labels
        // ("alternative", "indie") in Last.fm's vote-ordered tag list. A single identity
        // tag anywhere in the list is authoritative — these genres are too sonically distinct
        // to let positional tag ordering win. To add a new cultural genre: extend this set.
        let identityTags: [String: String] = [
            // East Asian pop
            "k-pop": "K-Pop",   "kpop": "K-Pop",  "k pop": "K-Pop",
            "korean pop": "K-Pop", "korean music": "K-Pop",
            "j-pop": "J-Pop",   "jpop": "J-Pop",  "j pop": "J-Pop",
            "japanese pop": "J-Pop",
            "c-pop": "C-Pop",   "cpop": "C-Pop",  "mandopop": "C-Pop", "sino-pop": "C-Pop",
            // Latin / Ibero-Caribbean
            "latin": "Latin",               "latin alternative": "Latin Alternative",
            "latin pop": "Latin Pop",        "latin jazz": "Latin Jazz",
            "latin rock": "Latin Rock",      "latin trap": "Latin Trap",
            "latin indie": "Latin Indie",
            "salsa": "Salsa",               "cumbia": "Cumbia",
            "bachata": "Bachata",            "merengue": "Merengue",
            "vallenato": "Vallenato",        "reggaeton": "Reggaeton",
            "nueva cancion": "Nueva Cancion","nueva canción": "Nueva Canción",
            "bolero": "Bolero",
            "afro-cuban": "Afro-Cuban",     "afro-caribbean": "Afro-Caribbean",
            "bossa nova": "Bossa Nova",
            // African / Afrodiaspora
            "afrobeats": "Afrobeats",  "afropop": "Afropop",
            "afroswing": "Afroswing",  "amapiano": "Amapiano", "afro house": "Afro House",
            // Caribbean
            "dancehall": "Dancehall",  "reggae": "Reggae",
        ]
        if let found = tags.first(where: { identityTags[$0.lowercased()] != nil }),
           let canonical = identityTags[found.lowercased()] {
            return [Genre(main: canonical)]
        }

        // Pop-adjacent tags that should win over any specific subgenre found deeper in the list.
        // "pop rock" and "pop punk" are Last.fm's most-applied tags for acts like Olivia Rodrigo
        // and Paramore — if they appear in the top-2 positions they represent the dominant genre,
        // not a minor "rap rock" tag that appears at position 3.
        let popPriorityTags: Set<String> = ["pop punk", "pop rock", "power pop", "teen pop", "bubblegum pop"]
        if let popTag = tags.prefix(2).first(where: { popPriorityTags.contains($0.lowercased()) }) {
            return [Genre(main: popTag.capitalized)]
        }

        let primary: String
        if let specific = tags.first(where: { Self.specificSubgenres.contains($0) }) {
            primary = specific
        } else {
            let matched = tags.filter { tag in generic.contains { tag.contains($0) || $0.contains(tag) } }
            primary = matched.first ?? tags.first ?? "Unknown"
        }
        return [Genre(main: primary.capitalized)]
    }

    // ──────────────────────────────────────────────
    // MARK: - URL Search Entry Point
    // ──────────────────────────────────────────────

    func findSimilarSongs(for urlString: String) async {
        guard !urlString.isEmpty else {
            errorMessage = "Paste a song link to get started."
            return
        }

        isLoading = true
        loadingMessage = "Reading the song…"
        errorMessage = nil
        infoMessage = nil
        recommendations = []
        sourceSong = nil
        blendedSongs = []

        do {
            let parsed = urlParser.parse(urlString)
            guard parsed.isValid else { throw SimiError.invalidURL }

            // Warn the user when they paste a YouTube Music radio URL.
            // The radio link always points to the *seed* song that started the mix,
            // not whatever was actively playing when they copied the URL.
            if parsed.isYouTubeMusicRadio {
                infoMessage = "YouTube Music radio link detected — showing the song that started this radio mix. If you heard a different song playing, use \"Find by Name\" and search for it there."
            }

            let song = try await resolveSong(from: parsed)
            self.sourceSong = song

            loadingMessage = "Analyzing the feeling…"
            // Launch source-independent candidate fetches immediately — don't stall behind HF/GetSongBPM.
            // genres, Last.fm similar tracks, and ListenBrainz only need title+artist, not audio features.
            async let featuresTask              = fetchAudioFeaturesWithFallback(song: song)
            async let tagsEarlyTask             = fetchRawTagsCached(song: song)
            async let genresTask                = fetchGenresWithFallback(title: song.title, artist: song.artist)
            async let similarTracksTask         = fetchSimilarTracksWithCache(title: song.title, artist: song.artist)
            async let lbTask                    = fetchListenBrainzTracks(title: song.title, artist: song.artist)
            async let artistCandidatesTask      = fetchArtistSimilarCandidates(song: song)
            async let sourceArtistTask          = fetchSourceArtistCandidates(song: song)
            async let deezerTask                = deezerService.fetchSimilarTracks(title: song.title, artist: song.artist)
            async let soundCloudTask            = soundCloudService.fetchRelatedTracks(title: song.title, artist: song.artist)
            // Spotify artist genres run concurrently — they don't need audio features or rawTags.
            // Two-hop: track ID → artist ID → full artist object (search endpoint omits genres).
            async let spotifyGenresTask         = spotifyService.fetchArtistGenres(forTrackId: song.id)
            async let discogsTask               = discogsService.fetchStyles(title: song.title, artist: song.artist)

            let earlyTags     = await tagsEarlyTask + (await discogsTask)
            // Launch tag pool in parallel — earlyTags needed to pick the right vibe queries.
            async let emotionalTagTask    = lastFMService.fetchEmotionalTagCandidates(rawTags: earlyTags)
            // Underground mood chain: mood tags → page-2 artists (past mainstream) → their tracks.
            async let undergroundMoodTask = lastFMService.fetchUndergroundMoodCandidates(rawTags: earlyTags)
            let spotifyGenres = await spotifyGenresTask
            if !spotifyGenres.isEmpty { simiLog("🎸 Spotify genres: \(spotifyGenres.prefix(5).joined(separator: ", "))") }

            // Wait for features — needed for BPM correction and feature-dependent searches.
            var features = await featuresTask
            let correctedBPM = normalizeBPM(features.bpm, tags: earlyTags)
            if correctedBPM != features.bpm {
                simiLog("🎚️ Source BPM corrected \(Int(features.bpm)) → \(Int(correctedBPM)) via genre tags")
                var fixed = features
                fixed.bpm = correctedBPM
                features = fixed
                Task { await self.supabase.storeFeatures(title: song.title, artist: song.artist, features: fixed, source: "librosa") }
            }
            // FreqBlog: BPM (always), key (when estimated), danceability + valence
            // (when features are tag-estimated). Energy/acousticness/liveness skipped —
            // FreqBlog analyses 30-second iTunes previews; those fields are unreliable.
            // Falls back to GetSongBPM (BPM + key only) when FreqBlog misses or queues.
            if let fb = await freqBlogService.fetchFeatures(title: song.title, artist: song.artist) {
                let fbBPM = normalizeBPM(fb.bpm, tags: earlyTags)
                simiLog("🎸 FreqBlog source: \(song.title) — \(Int(fbBPM))BPM, V:\(String(format:"%.2f",fb.valence)), D:\(String(format:"%.2f",fb.danceability))")
                var updated = features
                updated.bpm = fbBPM
                if features.isEstimated {
                    updated.valence      = fb.valence
                    updated.danceability = fb.danceability
                } else {
                    // Python ran — blend with FreqBlog perceptual read.
                    // FreqBlog hears the emotional feel; Python reads signal math.
                    // Average pulls the valence toward how it actually sounds.
                    let blended = (features.valence + fb.valence) / 2.0
                    simiLog("🎸 FreqBlog source valence blend: Python=\(String(format:"%.2f",features.valence)) FreqBlog=\(String(format:"%.2f",fb.valence)) → \(String(format:"%.2f",blended))")
                    updated.valence = blended
                }
                if features.isKeyEstimated {
                    updated.key            = fb.key
                    updated.mode           = fb.mode
                    updated.isKeyEstimated = false
                }
                features = updated
            } else if let bpmData = await getSongBPMService.fetchSongData(title: song.title, artist: song.artist),
                      bpmData.bpm > 0 {
                let gBPM = normalizeBPM(bpmData.bpm, tags: earlyTags)
                simiLog("🎵 GetSongBPM source (FreqBlog miss): \(song.title) — \(Int(gBPM))BPM")
                var updated = features
                updated.bpm = gBPM
                if let key = bpmData.key, let mode = bpmData.mode, features.isKeyEstimated {
                    updated.key = key; updated.mode = mode; updated.isKeyEstimated = false
                    let keyNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
                    simiLog("🎵 GetSongBPM source key: \(keyNames[safe: key] ?? "?") \(mode == 1 ? "Major" : "Minor") for \(song.title)")
                }
                features = updated
            }
            self.sourceSong?.audioFeatures = features
            self.lastSourceFeatures = features
            let sourceFeatures = features  // immutable copy — safe to capture in async let / Task

            // Feature-dependent searches + audio-derived emotional tags.
            loadingMessage = "Searching for its emotional kin…"
            async let spotifyRecsTask = spotifyService.getRecommendations(seedTrackID: song.id, features: sourceFeatures)
            async let vectorTask      = supabase.fetchSimilarByVector(embedding: SupabaseCacheService.buildEmbedding(from: sourceFeatures))
            async let dclapTask       = fetchVectorCandidates(embedding: sourceFeatures.dclapEmbedding ?? [])
            async let musicnnTask     = fetchMusiCNNCandidates(embedding: sourceFeatures.musicnnEmbedding ?? [])

            let genres = await genresTask
            // Phase 1: await early candidates (Last.fm + ListenBrainz arrive first)
            let lastFMTracks     = await similarTracksTask
            let lbTracks         = await lbTask

            // Early Supabase pre-fetch — runs while Spotify/vector/DCLAP are still in flight.
            // Results passed to prefetchCandidateFeatures() as prewarmedCache to skip duplicate lookups.
            let earlyLookupTask = Task<[String: AudioFeatures], Never> {
                var cache: [String: AudioFeatures] = [:]
                await withTaskGroup(of: (String, AudioFeatures?).self) { group in
                    for track in (lastFMTracks + lbTracks).prefix(20) {
                        group.addTask {
                            let key = "\(track.title)|\(track.artist)".lowercased()
                            let features = await self.supabase.lookupFeatures(title: track.title, artist: track.artist)
                            return (key, features)
                        }
                    }
                    for await (key, features) in group {
                        if let features { cache[key] = features }
                    }
                }
                return cache
            }

            // Phase 2: await remaining candidates
            let spotifyRecs          = (try? await spotifyRecsTask) ?? []
            let vectorCandidates     = await vectorTask
            let dclapCandidates      = await dclapTask
            let musicnnCandidates    = await musicnnTask
            self.detectedGenres  = genres
            self.lastGenres      = genres

            let artistCandidates       = await artistCandidatesTask
            let sourceArtistCandidates = await sourceArtistTask
            let deezerCandidates       = await deezerTask
            let soundCloudCandidates   = await soundCloudTask
            let emotionalTagCandidates = await emotionalTagTask
            let undergroundMoodCandidates = await undergroundMoodTask
            let expandedTracks = Self.mergeTracks(
                primary: Self.mergeTracks(
                    primary:   Array(dclapCandidates.prefix(25)),
                    secondary: Self.mergeTracks(
                        primary:   Array(musicnnCandidates.prefix(20)),
                        secondary: Array(vectorCandidates.prefix(20))
                    )
                ),
                secondary: Self.mergeTracks(
                    primary:   Array(lastFMTracks.prefix(25)),
                    secondary: Self.mergeTracks(
                        primary:   Array(lbTracks.prefix(10)),
                        secondary: Self.mergeTracks(
                            primary:   Array(soundCloudCandidates.prefix(25)),
                            secondary: Self.mergeTracks(
                                primary:   Array(emotionalTagCandidates.prefix(20)),
                                secondary: Self.mergeTracks(
                                    primary:   Array(undergroundMoodCandidates.prefix(20)),
                                    secondary: Self.mergeTracks(
                                        primary:   Array(deezerCandidates.prefix(15)),
                                        secondary: Self.mergeTracks(
                                            primary:   Array(sourceArtistCandidates.prefix(4)),
                                            secondary: Array(artistCandidates.prefix(8))
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            )
            simiLog("🧬 Source embeddings: dclap=\(sourceFeatures.dclapEmbedding.map { "\($0.count)d" } ?? "nil") musicnn=\(sourceFeatures.musicnnEmbedding.map { "\($0.count)d" } ?? "nil")")
            simiLog("📦 Pool: dclap=\(min(dclapCandidates.count, 25)) musicnn=\(min(musicnnCandidates.count, 20)) vec=\(min(vectorCandidates.count, 20)) lfm=\(min(lastFMTracks.count, 25)) lb=\(min(lbTracks.count, 25)) sc=\(min(soundCloudCandidates.count, 25)) tag=\(min(emotionalTagCandidates.count, 20)) mood=\(min(undergroundMoodCandidates.count, 20)) deezer=\(min(deezerCandidates.count, 15)) src=\(min(sourceArtistCandidates.count, 4)) artist=\(min(artistCandidates.count, 8)) → \(expandedTracks.count) unique")

            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: expandedTracks,
                sourceSong: song,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prefetchedFeatures: [:]
            )
            simiLog("🔀 mergeAndScore → \(merged.count) candidates (top score: \(String(format: "%.3f", merged.first?.similarityScore ?? 0.0)))")

            guard !merged.isEmpty else {
                simiLog("⛔ mergeAndScore empty — all \(expandedTracks.count) tracks failed Spotify search or were deduped")
                errorMessage = "Couldn't find similar songs for this track. Try searching by name instead."
                isLoading = false
                return
            }

            loadingMessage = "Putting it together…"
            let earlyCache = await earlyLookupTask.value
            let gated = await applyGenreGate(candidates: merged, genres: genres)
            let enriched = await prefetchCandidateFeatures(
                candidates: gated,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prewarmedCache: earlyCache,
                sourceArtist: song.artist
            )
            simiLog("✅ prefetchCandidateFeatures → \(enriched.count) songs (top score: \(String(format: "%.3f", enriched.first?.similarityScore ?? 0.0)), min: \(String(format: "%.3f", enriched.last?.similarityScore ?? 0.0)))")
            self.recommendations = enriched
            if let song = self.sourceSong {
                history.record(song: song, query: urlString)
            }
            isLoading = false

            await enrichWithABFeatures(sourceFeatures: sourceFeatures, genres: genres, rawTags: earlyTags)
            // Fire AFTER enrichWithABFeatures — self.recommendations has iTunes previewURLs
            // filled in by then, which /embed-candidates needs as the audio source.
            Task { await self.embedCandidatesInBackground(songs: self.recommendations, sourceFeatures: sourceFeatures) }
            Task { await self.warmArtistCache(artist: self.sourceSong?.artist ?? "") }
            return

        } catch let error as SimiError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Something went wrong. Please try again."
            simiLog("Recommendation error:", error)
        }

        isLoading = false
    }

    // ──────────────────────────────────────────────
    // MARK: - Multi-URL Blend Entry Point
    // ──────────────────────────────────────────────

    /// Blends up to 5 URLs into a single vibe target.
    /// If only one URL is provided, falls back to the standard single-song flow.
    func findSimilarSongs(for urls: [String]) async {
        let validURLs = urls.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !validURLs.isEmpty else {
            errorMessage = "Paste at least one song link to get started."
            return
        }

        // Single URL — use the existing optimised single-song flow
        if validURLs.count == 1 {
            await findSimilarSongs(for: validURLs[0])
            return
        }

        isLoading = true
        loadingMessage = "Resolving songs…"
        errorMessage = nil
        infoMessage = nil
        recommendations = []
        sourceSong = nil
        blendedSongs = []

        // ── Step 1: Parse all URLs on the main actor first, then resolve in parallel ──
        let parsedURLs = validURLs.prefix(5).map { urlParser.parse($0) }.filter { $0.isValid }

        let resolvedSongs: [Song] = await withTaskGroup(of: Song?.self) { group in
            for parsed in parsedURLs {
                group.addTask {
                    return try? await self.resolveSong(from: parsed)
                }
            }
            var songs: [Song] = []
            for await song in group { if let song { songs.append(song) } }
            return songs
        }

        guard !resolvedSongs.isEmpty else {
            errorMessage = "Couldn't resolve any of those links. Check they're valid Spotify, YouTube, or SoundCloud links."
            isLoading = false
            return
        }

        // ── Step 2: Hand off to the existing multi-seed blend flow ──
        let seedPairs = resolvedSongs.map { (title: $0.title, artist: $0.artist) }
        await findSimilarSongs(seeds: seedPairs)
    }

    // ──────────────────────────────────────────────
    // MARK: - Text Search Entry Point
    // ──────────────────────────────────────────────

    func findSimilarSongs(title: String, artist: String) async {
        let query = artist.isEmpty ? title : "\(title) \(artist)"
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Enter a song title to search."
            return
        }

        isLoading = true
        loadingMessage = "Reading the song…"
        errorMessage = nil
        recommendations = []
        sourceSong = nil
        blendedSongs = []

        do {
            let song: Song
            if let cached = await supabase.lookupSpotifyTrack(title: title, artist: artist) {
                // Supabase hit — zero Spotify calls, instant
                song = cached
            } else if let spotifySong = try? await spotifyService.searchTrack(title: title, artist: artist) {
                // Spotify hit — write through to cache for next user
                await supabase.storeSpotifyTrack(spotifySong)
                song = spotifySong
            } else {
                // Spotify unavailable (rate-limit, network, or song not catalogued).
                // iTunes is free, requires no auth, covers most mainstream + indie tracks.
                let (previewURL, artwork) = await itunesService.fetchPreviewAndArtwork(title: title, artist: artist)
                guard previewURL != nil || artwork != nil else {
                    throw SimiError.songNotFound
                }
                simiLog("🎵 Spotify miss — iTunes fallback for '\(title)' by '\(artist)'")
                song = Song(
                    id: "itunes:\(title.lowercased()):\(artist.lowercased())",
                    title: title,
                    artist: artist.isEmpty ? "Unknown" : artist,
                    albumArt: artwork ?? "",
                    previewURL: previewURL,
                    spotifyURL: "",
                    sourceURL: ""
                )
            }
            self.sourceSong = song

            loadingMessage = "Analyzing the feeling…"
            // Launch source-independent candidate fetches immediately.
            async let featuresTask           = fetchAudioFeaturesWithFallback(song: song)
            async let tagsEarlyTask          = fetchRawTagsCached(song: song)
            async let genresTask             = fetchGenresWithFallback(title: song.title, artist: song.artist)
            async let similarTracksTask      = fetchSimilarTracksWithCache(title: song.title, artist: song.artist)
            async let lbTask                 = fetchListenBrainzTracks(title: song.title, artist: song.artist)
            async let artistCandidatesTask   = fetchArtistSimilarCandidates(song: song)
            async let sourceArtistTask2      = fetchSourceArtistCandidates(song: song)
            async let deezerTask             = deezerService.fetchSimilarTracks(title: song.title, artist: song.artist)
            async let soundCloudTask2        = soundCloudService.fetchRelatedTracks(title: song.title, artist: song.artist)
            async let spotifyGenresTask      = spotifyService.fetchArtistGenres(forTrackId: song.id)
            async let discogsTask2           = discogsService.fetchStyles(title: song.title, artist: song.artist)

            let earlyTags     = await tagsEarlyTask + (await discogsTask2)
            async let emotionalTagTask2    = lastFMService.fetchEmotionalTagCandidates(rawTags: earlyTags)
            async let undergroundMoodTask2 = lastFMService.fetchUndergroundMoodCandidates(rawTags: earlyTags)
            let spotifyGenres = await spotifyGenresTask
            if !spotifyGenres.isEmpty { simiLog("🎸 Spotify genres: \(spotifyGenres.prefix(5).joined(separator: ", "))") }
            var features = await featuresTask
            let correctedBPM = normalizeBPM(features.bpm, tags: earlyTags)
            if correctedBPM != features.bpm {
                simiLog("🎚️ Source BPM corrected \(Int(features.bpm)) → \(Int(correctedBPM)) via genre tags")
                var fixed = features
                fixed.bpm = correctedBPM
                features = fixed
                Task { await self.supabase.storeFeatures(title: song.title, artist: song.artist, features: fixed, source: "librosa") }
            }
            // FreqBlog: BPM (always), key (when estimated), danceability + valence.
            // When Python ran (isEstimated=false), blend valences — Python reads signal math,
            // FreqBlog hears perceptual feel. Average anchors to how the track actually sounds.
            if let fb = await freqBlogService.fetchFeatures(title: song.title, artist: song.artist) {
                let fbBPM = normalizeBPM(fb.bpm, tags: earlyTags)
                simiLog("🎸 FreqBlog source: \(song.title) — \(Int(fbBPM))BPM, V:\(String(format:"%.2f",fb.valence)), D:\(String(format:"%.2f",fb.danceability))")
                var updated = features
                updated.bpm = fbBPM
                if features.isEstimated {
                    updated.valence      = fb.valence
                    updated.danceability = fb.danceability
                } else {
                    let blended = (features.valence + fb.valence) / 2.0
                    simiLog("🎸 FreqBlog source valence blend: Python=\(String(format:"%.2f",features.valence)) FreqBlog=\(String(format:"%.2f",fb.valence)) → \(String(format:"%.2f",blended))")
                    updated.valence = blended
                }
                if features.isKeyEstimated {
                    updated.key            = fb.key
                    updated.mode           = fb.mode
                    updated.isKeyEstimated = false
                }
                features = updated
            } else if let bpmData = await getSongBPMService.fetchSongData(title: song.title, artist: song.artist),
                      bpmData.bpm > 0 {
                let gBPM = normalizeBPM(bpmData.bpm, tags: earlyTags)
                simiLog("🎵 GetSongBPM source (FreqBlog miss): \(song.title) — \(Int(gBPM))BPM")
                var updated = features
                updated.bpm = gBPM
                if let key = bpmData.key, let mode = bpmData.mode, features.isKeyEstimated {
                    updated.key = key; updated.mode = mode; updated.isKeyEstimated = false
                    let keyNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
                    simiLog("🎵 GetSongBPM source key: \(keyNames[safe: key] ?? "?") \(mode == 1 ? "Major" : "Minor") for \(song.title)")
                }
                features = updated
            }
            self.sourceSong?.audioFeatures = features
            self.lastSourceFeatures = features
            let sourceFeatures = features

            loadingMessage = "Searching for its emotional kin…"
            async let spotifyRecsTask = spotifyService.getRecommendations(seedTrackID: song.id, features: sourceFeatures)
            async let vectorTask      = supabase.fetchSimilarByVector(embedding: SupabaseCacheService.buildEmbedding(from: sourceFeatures))
            async let dclapTask2      = fetchVectorCandidates(embedding: sourceFeatures.dclapEmbedding ?? [])
            async let musicnnTask2    = fetchMusiCNNCandidates(embedding: sourceFeatures.musicnnEmbedding ?? [])

            let genres = await genresTask
            // Phase 1: await early candidates (Last.fm + ListenBrainz arrive first)
            let lastFMTracks     = await similarTracksTask
            let lbTracks         = await lbTask

            // Early Supabase pre-fetch — runs while Spotify/vector/DCLAP are still in flight.
            // Results passed to prefetchCandidateFeatures() as prewarmedCache to skip duplicate lookups.
            let earlyLookupTask = Task<[String: AudioFeatures], Never> {
                var cache: [String: AudioFeatures] = [:]
                await withTaskGroup(of: (String, AudioFeatures?).self) { group in
                    for track in (lastFMTracks + lbTracks).prefix(20) {
                        group.addTask {
                            let key = "\(track.title)|\(track.artist)".lowercased()
                            let features = await self.supabase.lookupFeatures(title: track.title, artist: track.artist)
                            return (key, features)
                        }
                    }
                    for await (key, features) in group {
                        if let features { cache[key] = features }
                    }
                }
                return cache
            }

            // Phase 2: await remaining candidates
            let spotifyRecs          = (try? await spotifyRecsTask) ?? []
            let vectorCandidates     = await vectorTask
            let dclapCandidates2     = await dclapTask2
            let musicnnCandidates2   = await musicnnTask2
            self.detectedGenres  = genres
            self.lastGenres      = genres

            let artistCandidates          = await artistCandidatesTask
            let sourceArtistCandidates2   = await sourceArtistTask2
            let deezerCandidates          = await deezerTask
            let soundCloudCandidates2     = await soundCloudTask2
            let emotionalTagCandidates2   = await emotionalTagTask2
            let undergroundMoodCandidates2 = await undergroundMoodTask2
            let expandedTracks = Self.mergeTracks(
                primary: Self.mergeTracks(
                    primary:   Array(dclapCandidates2.prefix(25)),
                    secondary: Self.mergeTracks(
                        primary:   Array(musicnnCandidates2.prefix(20)),
                        secondary: Array(vectorCandidates.prefix(20))
                    )
                ),
                secondary: Self.mergeTracks(
                    primary:   Array(lastFMTracks.prefix(25)),
                    secondary: Self.mergeTracks(
                        primary:   Array(lbTracks.prefix(10)),
                        secondary: Self.mergeTracks(
                            primary:   Array(soundCloudCandidates2.prefix(25)),
                            secondary: Self.mergeTracks(
                                primary:   Array(emotionalTagCandidates2.prefix(20)),
                                secondary: Self.mergeTracks(
                                    primary:   Array(undergroundMoodCandidates2.prefix(20)),
                                    secondary: Self.mergeTracks(
                                        primary:   Array(deezerCandidates.prefix(15)),
                                        secondary: Self.mergeTracks(
                                            primary:   Array(sourceArtistCandidates2.prefix(4)),
                                            secondary: Array(artistCandidates.prefix(8))
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            )
            simiLog("🧬 Source embeddings: dclap=\(sourceFeatures.dclapEmbedding.map { "\($0.count)d" } ?? "nil") musicnn=\(sourceFeatures.musicnnEmbedding.map { "\($0.count)d" } ?? "nil")")
            simiLog("📦 Pool: dclap=\(min(dclapCandidates2.count, 25)) musicnn=\(min(musicnnCandidates2.count, 20)) vec=\(min(vectorCandidates.count, 20)) lfm=\(min(lastFMTracks.count, 25)) lb=\(min(lbTracks.count, 25)) sc=\(min(soundCloudCandidates2.count, 25)) tag=\(min(emotionalTagCandidates2.count, 20)) mood=\(min(undergroundMoodCandidates2.count, 20)) deezer=\(min(deezerCandidates.count, 15)) src=\(min(sourceArtistCandidates2.count, 4)) artist=\(min(artistCandidates.count, 8)) → \(expandedTracks.count) unique")

            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: expandedTracks,
                sourceSong: song,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prefetchedFeatures: [:]
            )
            simiLog("🔀 mergeAndScore → \(merged.count) candidates (top score: \(String(format: "%.3f", merged.first?.similarityScore ?? 0.0)))")

            guard !merged.isEmpty else {
                simiLog("⛔ mergeAndScore empty — all \(expandedTracks.count) tracks failed Spotify search or were deduped")
                errorMessage = "Couldn't find similar songs for this track. Try a different song."
                isLoading = false
                return
            }

            loadingMessage = "Putting it together…"
            let earlyCache = await earlyLookupTask.value
            let gated = await applyGenreGate(candidates: merged, genres: genres)
            let enriched = await prefetchCandidateFeatures(
                candidates: gated,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prewarmedCache: earlyCache,
                sourceArtist: song.artist
            )
            simiLog("✅ prefetchCandidateFeatures → \(enriched.count) songs (top score: \(String(format: "%.3f", enriched.first?.similarityScore ?? 0.0)), min: \(String(format: "%.3f", enriched.last?.similarityScore ?? 0.0)))")
            self.recommendations = enriched
            history.record(song: song, query: query)
            isLoading = false

            await enrichWithABFeatures(sourceFeatures: sourceFeatures, genres: genres, rawTags: earlyTags)
            Task { await self.embedCandidatesInBackground(songs: self.recommendations, sourceFeatures: sourceFeatures) }
            Task { await self.warmArtistCache(artist: self.sourceSong?.artist ?? "") }
            return

        } catch let error as SimiError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Something went wrong. Please try again."
            simiLog("Text search error:", error)
        }

        isLoading = false
    }

    // ──────────────────────────────────────────────
    // MARK: - Multi-Seed Search Entry Point
    // Blends up to 5 songs into one vibe target
    // ──────────────────────────────────────────────

    func findSimilarSongs(seeds: [(title: String, artist: String)]) async {
        guard !seeds.isEmpty else { return }

        // Single seed — use the regular path
        if seeds.count == 1 {
            await findSimilarSongs(title: seeds[0].title, artist: seeds[0].artist)
            return
        }

        isLoading = true
        loadingMessage = "Finding songs…"
        errorMessage = nil
        recommendations = []
        sourceSong = nil
        blendedSongs = []

        do {
            // ── Step 1: Resolve all seeds in parallel ──
            loadingMessage = "Finding \(seeds.count) songs…"
            let resolvedSongs: [Song] = await withTaskGroup(of: Song?.self) { group in
                for seed in seeds {
                    group.addTask {
                        try? await self.spotifyService.searchTrack(title: seed.title, artist: seed.artist)
                    }
                }
                var songs: [Song] = []
                for await song in group { if let song { songs.append(song) } }
                return songs
            }

            guard !resolvedSongs.isEmpty else { throw SimiError.songNotFound }

            // Use the first resolved song as the "display" source song
            self.sourceSong = resolvedSongs.first
            // Store all resolved songs so the UI can show the full blend
            self.blendedSongs = resolvedSongs

            // ── Step 2: Fetch features for all seeds in parallel, then blend ──
            loadingMessage = "Analyzing audio…"
            let allFeatures: [AudioFeatures] = await withTaskGroup(of: AudioFeatures.self) { group in
                for song in resolvedSongs {
                    group.addTask { await self.fetchAudioFeaturesWithFallback(song: song) }
                }
                var results: [AudioFeatures] = []
                for await f in group { results.append(f) }
                return results
            }

            let blended = blendFeatures(allFeatures)
            self.sourceSong?.audioFeatures = blended
            self.lastSourceFeatures = blended

            // ── Step 3: All candidate fetches concurrently ──
            // None of these depend on each other — they all need only resolvedSongs/blended/seedIDs.
            // Previously sequential (allLastFMTracks → allGenres → spotifyRecs) added ~2s.
            loadingMessage = "Finding similar songs…"
            let seedIDs = resolvedSongs.map { $0.id }

            async let lastFMTracksTask  = withTaskGroup(of: [(title: String, artist: String)].self) { group in
                for song in resolvedSongs {
                    group.addTask { (try? await self.lastFMService.fetchSimilarTracks(title: song.title, artist: song.artist, limit: 15)) ?? [] }
                }
                var merged: [(title: String, artist: String)] = []; var seen = Set<String>()
                for await tracks in group {
                    for t in tracks { let k = "\(t.title.lowercased())|\(t.artist.lowercased())"; if seen.insert(k).inserted { merged.append(t) } }
                }
                return merged
            }
            async let allGenresTask = withTaskGroup(of: [Genre].self) { group in
                for song in resolvedSongs { group.addTask { await self.fetchGenresWithFallback(title: song.title, artist: song.artist) } }
                var all: [[Genre]] = []; for await g in group { all.append(g) }; return all
            }
            async let spotifyRecsTask   = spotifyService.getRecommendations(seedTrackIDs: seedIDs, features: blended)
            async let vectorTask        = supabase.fetchSimilarByVector(embedding: SupabaseCacheService.buildEmbedding(from: blended))
            async let dclapTask3        = fetchVectorCandidates(embedding: blended.dclapEmbedding ?? [])
            async let musicnnTask3      = fetchMusiCNNCandidates(embedding: blended.musicnnEmbedding ?? [])
            // Use first seed for Deezer + SoundCloud radio — close enough for blend context
            let deezerSeed = resolvedSongs.first
            async let deezerTask3      = deezerService.fetchSimilarTracks(
                title: deezerSeed?.title ?? "", artist: deezerSeed?.artist ?? "")
            async let soundCloudTask3  = soundCloudService.fetchRelatedTracks(
                title: deezerSeed?.title ?? "", artist: deezerSeed?.artist ?? "")

            let allLastFMTracks     = await lastFMTracksTask
            let allGenres           = await allGenresTask
            let spotifyRecs         = (try? await spotifyRecsTask) ?? []
            let vectorCandidates    = await vectorTask
            let dclapCandidates3    = await dclapTask3
            let musicnnCandidates3  = await musicnnTask3
            let deezerCandidates3   = await deezerTask3
            let soundCloudCandidates3 = await soundCloudTask3

            // Flatten + dedup genres
            var seenGenres = Set<String>()
            let mergedGenres: [Genre] = allGenres.flatMap { $0 }.filter { seenGenres.insert($0.main).inserted }
            self.detectedGenres = mergedGenres
            self.lastGenres = mergedGenres

            // Multi-seed: allLastFMTracks is the union across all seeds, so it's bigger than single-seed.
            let expandedTracks = Self.mergeTracks(
                primary: Self.mergeTracks(
                    primary:   Array(dclapCandidates3.prefix(25)),
                    secondary: Self.mergeTracks(
                        primary:   Array(musicnnCandidates3.prefix(20)),
                        secondary: Array(vectorCandidates.prefix(20))
                    )
                ),
                secondary: Self.mergeTracks(
                    primary:   Array(allLastFMTracks.prefix(25)),
                    secondary: Self.mergeTracks(
                        primary:   Array(deezerCandidates3.prefix(15)),
                        secondary: Array(soundCloudCandidates3.prefix(15))
                    )
                )
            )
            simiLog("📦 Pool (blend): dclap=\(min(dclapCandidates3.count, 25)) musicnn=\(min(musicnnCandidates3.count, 20)) vec=\(min(vectorCandidates.count, 20)) lfm=\(min(allLastFMTracks.count, 25)) deezer=\(min(deezerCandidates3.count, 15)) sc=\(min(soundCloudCandidates3.count, 15)) → \(expandedTracks.count) unique")

            // Exclude all seed songs from results
            let seedIDSet = Set(seedIDs)

            // Store individual seed features so enrichment can score against each seed,
            // not just the blended midpoint. This is the fix for blend scoring accuracy.
            self.lastSeedFeatures = allFeatures

            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs.filter { !seedIDSet.contains($0.id) },
                lastFMTracks: expandedTracks,
                sourceSong: resolvedSongs.first!,
                sourceFeatures: blended,
                genres: mergedGenres,
                excludeIDs: seedIDSet,
                seedFeatures: allFeatures          // ← score against each seed independently
            )

            loadingMessage = "Almost ready…"
            let gated = await applyGenreGate(candidates: merged, genres: mergedGenres)
            let enriched = await prefetchCandidateFeatures(
                candidates: gated,
                sourceFeatures: blended,
                genres: mergedGenres,
                seedFeatures: allFeatures
            )
            self.recommendations = enriched

            for song in resolvedSongs {
                history.record(song: song, query: "\(song.title) \(song.artist)")
            }
            isLoading = false

            await enrichWithABFeatures(sourceFeatures: blended, genres: mergedGenres, seedFeatures: allFeatures)
            Task { await self.embedCandidatesInBackground(songs: self.recommendations, sourceFeatures: blended) }
            Task { await self.warmArtistCache(artist: self.sourceSong?.artist ?? "") }

        } catch let error as SimiError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Something went wrong. Please try again."
            simiLog("Multi-seed search error:", error)
        }

        isLoading = false
    }

    // ──────────────────────────────────────────────
    // MARK: - Mood Coordinate Search
    // No reference song — user picks a valence × arousal point.
    // Spotify genre seeds replace the track seed; a synthetic source
    // AudioFeatures drives the scoring pipeline as-is.
    // ──────────────────────────────────────────────

    func findSimilarSongs(valence: Double, arousal: Double) async {
        isLoading = true
        loadingMessage = "Finding the feeling…"
        errorMessage = nil
        recommendations = []
        sourceSong = nil
        blendedSongs = []
        moodTarget = MoodTarget(valence: valence, arousal: arousal)

        // Synthetic source features derived from mood coordinates.
        // Energy and valence are set directly; other dims are estimated
        // to give the scoring pipeline plausible context.
        let syntheticFeatures = AudioFeatures(
            bpm: 0,
            energy: arousal,
            valence: valence,
            danceability: (arousal + valence) / 2.0,
            acousticness: max(0.0, 0.65 - arousal * 0.6),
            instrumentalness: 0.1,
            liveness: 0.1,
            loudness: -14.0 + arousal * 9.0,
            key: 0,
            mode: valence > 0.5 ? 1 : 0,
            isEstimated: true
        )
        lastSourceFeatures = syntheticFeatures
        detectedGenres = []
        lastGenres = []

        do {
            loadingMessage = "Searching by feel…"
            let moodSongs = (try? await spotifyService.getRecommendationsByMood(
                valence: valence, arousal: arousal, limit: 20
            )) ?? []

            guard !moodSongs.isEmpty else {
                errorMessage = "Couldn't find songs for this mood. Try a different area on the pad."
                isLoading = false
                return
            }

            // Placeholder source: its ID is a UUID, so nothing gets excluded from results.
            let placeholder = Song(
                id: "mood-\(UUID().uuidString)",
                title: moodTarget?.label ?? "Mood",
                artist: "",
                albumArt: "",
                previewURL: nil,
                spotifyURL: "",
                sourceURL: "",
                releaseYear: nil
            )

            loadingMessage = "Analyzing the feel…"
            let merged = try await mergeAndScore(
                spotifyRecs: moodSongs,
                lastFMTracks: [],
                sourceSong: placeholder,
                sourceFeatures: syntheticFeatures,
                genres: []
            )

            guard !merged.isEmpty else {
                errorMessage = "Couldn't score results for this mood. Try a different area."
                isLoading = false
                return
            }

            loadingMessage = "Putting it together…"
            let enriched = await prefetchCandidateFeatures(
                candidates: merged,
                sourceFeatures: syntheticFeatures,
                genres: []
            )
            recommendations = enriched
            isLoading = false

            await enrichWithABFeatures(sourceFeatures: syntheticFeatures, genres: [])
        } catch {
            errorMessage = "Something went wrong. Please try again."
            simiLog("Mood search error:", error)
            isLoading = false
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Blend Audio Features
    // Averages features across multiple seeds
    // ──────────────────────────────────────────────

    private func blendFeatures(_ features: [AudioFeatures]) -> AudioFeatures {
        guard !features.isEmpty else {
            return AudioFeatures(bpm: 120, energy: 0.5, valence: 0.5, danceability: 0.5,
                                 acousticness: 0.0, instrumentalness: 0.0, liveness: 0.0,
                                 loudness: -10.0, key: 0, mode: 1)
        }
        let n = Double(features.count)
        return AudioFeatures(
            bpm:              features.map { $0.bpm }.reduce(0, +) / n,
            energy:           features.map { $0.energy }.reduce(0, +) / n,
            valence:          features.map { $0.valence }.reduce(0, +) / n,
            danceability:     features.map { $0.danceability }.reduce(0, +) / n,
            acousticness:     features.map { $0.acousticness }.reduce(0, +) / n,
            instrumentalness: features.map { $0.instrumentalness }.reduce(0, +) / n,
            liveness:         features.map { $0.liveness }.reduce(0, +) / n,
            loudness:         features.map { $0.loudness }.reduce(0, +) / n,
            key:              features.first?.key ?? 0,
            mode:             features.first?.mode ?? 1
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Resolve Song from Parsed URL
    // ──────────────────────────────────────────────

    private func resolveSong(from parsed: ParsedURL) async throws -> Song {
        switch parsed.source {
        case .spotify:
            guard let id = parsed.spotifyTrackID else { throw SimiError.invalidURL }
            return try await spotifyService.fetchSong(trackID: id)

        case .youtube:
            // Try oEmbed first to get real title + channel from the video ID
            var title  = parsed.guessedTitle  ?? ""
            var artist = parsed.guessedArtist ?? ""

            if title.isEmpty, let videoID = parsed.youtubeVideoID,
               let info = await urlParser.fetchYouTubeInfo(videoID: videoID) {
                title  = info.title
                artist = info.author
                simiLog("🎬 YouTube oEmbed: \"\(title)\" by \(artist)")
            }

            guard !title.isEmpty else { throw SimiError.songNotFound }
            guard let song = try await spotifyService.searchTrack(title: title, artist: artist) else {
                throw SimiError.songNotFound
            }
            return song

        case .soundcloud:
            // Use oEmbed to get the real title/artist — slug-to-text guesses are often wrong
            // (they lose punctuation, featured artists, capitalisation, etc.)
            var title       = parsed.guessedTitle  ?? ""
            var artist      = parsed.guessedArtist ?? ""
            var thumbnailURL: String? = nil

            if let info = await urlParser.fetchSoundCloudInfo(url: parsed.rawURL) {
                title       = info.title
                artist      = info.artist
                thumbnailURL = info.thumbnailURL
                simiLog("🔊 SoundCloud oEmbed: \"\(title)\" by \(artist)")
            }

            guard !title.isEmpty else { throw SimiError.songNotFound }

            // Try to find the track on Spotify for full metadata + album art
            if let song = try? await spotifyService.searchTrack(title: title, artist: artist) {
                return song
            }

            // SoundCloud-exclusive track — not on Spotify.
            // Build a synthetic Song so Last.fm-based recommendations can still work.
            simiLog("⚠️ SoundCloud track not found on Spotify — using Last.fm-only recommendations for \"\(title)\"")
            return Song(
                id: UUID().uuidString,
                title: title,
                artist: artist,
                albumArt: thumbnailURL ?? "",
                previewURL: nil,
                spotifyURL: parsed.rawURL,
                sourceURL: parsed.rawURL
            )

        case .unknown:
            throw SimiError.invalidURL
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Audio Features — Full Priority Chain
    // ──────────────────────────────────────────────

    /// Fetches the best audio features available, working down the priority chain:
    /// Spotify → AcousticBrainz → Deezer BPM + tag energy/valence → tag-only → neutral
    ///
    /// Key change: Deezer only gives us BPM — we no longer return early when Deezer finds a tempo.
    /// Instead we continue to tag estimation so we get real energy/valence (not neutral 0.5/0.5).
    /// The Deezer BPM is passed into tag estimation to override the genre-estimated tempo.
    private func fetchAudioFeaturesWithFallback(song: Song) async -> AudioFeatures {

        // 0. Supabase feature cache — fast path.
        //    Only call GetSongBPM when key is still estimated or BPM is unknown —
        //    avoids a 1-8s network round-trip on repeat searches where data is already confirmed.
        if var cached = await supabase.lookupFeatures(title: song.title, artist: song.artist) {
            if (cached.isKeyEstimated || cached.bpm == 0),
               let songData = await getSongBPMService.fetchSongData(title: song.title, artist: song.artist) {
                var updated = false

                // Refresh BPM if GetSongBPM has a value (overrides cached/normalized BPM)
                if songData.bpm > 0 {
                    let corrected = normalizeBPM(songData.bpm, tags: [])
                    if abs(corrected - cached.bpm) > 2 {
                        simiLog("🎵 BPM refreshed \(Int(cached.bpm)) → \(Int(corrected)) for \(song.title)")
                        cached.bpm = corrected
                        updated = true
                    }
                }

                // Inject real key data if we don't have it yet
                if cached.isKeyEstimated, let key = songData.key, let mode = songData.mode {
                    let keyNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
                    let modeName = mode == 1 ? "Major" : "Minor"
                    let keyLabel = key >= 0 && key < keyNames.count ? keyNames[key] : "?"
                    simiLog("🎵 Key from GetSongBPM: \(keyLabel) \(modeName) for \(song.title)")
                    cached.key = key
                    cached.mode = mode
                    cached.isKeyEstimated = false
                    updated = true
                }

                if updated {
                    Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: cached, source: "refreshed") }
                }
            }
            return cached
        }

        // 1. Preview audio analysis — resolve URL first (Spotify preview → iTunes fallback).
        //      iTunes is the fallback source for preview URLs: Spotify stopped returning
        //      preview_url on most tracks in late 2024.
        var audioMeasurements: AudioMeasurements? = nil
        let previewURL: String?
        if let url = song.previewURL {
            previewURL = url
        } else if let url = await itunesService.fetchPreviewURL(title: song.title, artist: song.artist) {
            previewURL = url
        } else {
            previewURL = await deezerService.fetchPreviewURL(title: song.title, artist: song.artist)
        }

        // 2. Audio analysis — download once, try HF then SonicDNA.
        //    2a. HF librosa: DEAM arousal/valence + full librosa features (gold standard).
        //    2b. LocalAudioAnalyzer: full SonicDNA features including mfccMean — activates
        //        the 0.08 mfccCosine weight in computeSimilarity for source-side scoring.
        //    Both receive the same downloaded bytes — no double-download on HF failure.
        if let previewURL {
            var downloadedAudio: Data? = nil
            if let audioURL = URL(string: previewURL),
               let (data, audioResp) = try? await URLSession.shared.data(from: audioURL),
               (audioResp as? HTTPURLResponse)?.statusCode == 200 {
                downloadedAudio = data
            }

            if let audioData = downloadedAudio {
                // 2a: HF librosa
                if let pyFeatures = await simiAudioService.analyzeDownloadedAudio(
                       data: audioData, sourceURL: previewURL,
                       artist: song.artist, title: song.title, spotifyId: song.id) {
                    simiLog("✅ Python audio analyzer: \(song.title) — \(Int(pyFeatures.bpm))BPM energy=\(String(format: "%.2f", pyFeatures.energy)) valence=\(String(format: "%.2f", pyFeatures.valence))")
                    Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: pyFeatures, source: "librosa") }
                    return pyFeatures
                }

                // 2b: SonicDNA on-device analysis
                if let localFeatures = await localAudioAnalyzer.analyze(
                       data: audioData, sourceURL: previewURL, title: song.title) {
                    simiLog("✅ SonicDNA source: \(song.title) — \(Int(localFeatures.bpm))BPM energy=\(String(format: "%.2f", localFeatures.energy)) valence=\(String(format: "%.2f", localFeatures.valence))")
                    Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: localFeatures, source: "preview_audio") }
                    return localFeatures
                }
            }

            // Both failed or audio unavailable — fall through to PreviewAudioAnalyzer + tag estimation.
            audioMeasurements = await previewAnalyzer.analyze(previewURL: previewURL)
        }

        // 2. AcousticBrainz — DISABLED (deprecated 2022, adds 2-4s latency for sparse coverage)
        //    Re-enable if Spotify Extended Quota Mode is granted and AB coverage improves.
        // if let mbid = await musicBrainzService.findMBID(title: song.title, artist: song.artist),
        //    let features = await acousticBrainzService.fetchFeatures(mbid: mbid) {
        //     simiLog("✅ AcousticBrainz features: \(song.title)")
        //     return features
        // }

        // 3. BPM — try Deezer first, fall back to GetSongBPM if Deezer returns nothing.
        //    We DON'T return here — we still need tag estimation for energy/valence.
        //    Returning neutral 0.5/0.5 would give wrong vibe labels (e.g. punk-rap → "Melancholic & Calm").
        simiLog("⚠️ Spotify unavailable — fetching BPM for \(song.title)")
        var bpm: Double = 0
        var gsbpmKey: Int? = nil
        var gsbpmMode: Int? = nil

        // 3a. GetSongBPM — primary BPM source, also provides musical key via Open Key notation.
        if let songData = await getSongBPMService.fetchSongData(title: song.title, artist: song.artist) {
            simiLog("✅ GetSongBPM \(Int(songData.bpm)): \(song.title)")
            bpm = songData.bpm
            gsbpmKey  = songData.key
            gsbpmMode = songData.mode
            if let k = gsbpmKey, let m = gsbpmMode {
                let keyNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
                let modeName = m == 1 ? "Major" : "Minor"
                let keyName  = (k >= 0 && k < keyNames.count) ? "\(keyNames[k]) \(modeName)" : "?"
                simiLog("🎵 GetSongBPM key: \(keyName) for \(song.title)")
            }
        }

        // 3b. Deezer — fallback only when GetSongBPM has no result.
        //     Deezer frequently halves/doubles tempo on rave, trap, hyperpop and R&B.
        if bpm == 0,
           let track = try? await deezerService.searchTrack(title: song.title, artist: song.artist),
           let deezerBPM = track.bpm, deezerBPM > 0 {
            simiLog("✅ Deezer BPM \(Int(deezerBPM)): \(song.title)")
            bpm = deezerBPM
        }

        // 4. Tag-based estimation — provides energy/valence from genre/mood tags.
        //    Check Supabase tag cache first (written by fetchGenresWithFallback earlier in the
        //    same search), then Last.fm, then MusicBrainz as a last resort.
        var rawTags = await supabase.lookupTags(title: song.title, artist: song.artist) ?? []
        if rawTags.isEmpty {
            rawTags = await lastFMService.fetchRawTags(title: song.title, artist: song.artist)
            if !rawTags.isEmpty {
                Task { await supabase.storeTags(title: song.title, artist: song.artist, tags: rawTags, source: "lastfm") }
            }
        }
        if rawTags.isEmpty {
            simiLog("⚠️ Last.fm returned no raw tags for \(song.title) — trying MusicBrainz")
            rawTags = await musicBrainzService.fetchRawTags(title: song.title, artist: song.artist)
        }

        // BPM normalization: correct Deezer's half-time / double-time detection errors.
        // e.g. James Joint reported at 135 BPM instead of ~68, hyperpop at 110 instead of 149.
        if bpm > 0 {
            bpm = normalizeBPM(bpm, tags: rawTags)
            simiLog("🎚️ BPM after normalization: \(Int(bpm)) for \(song.title)")
        }

        // 4 + 1.5 merge: combine audio measurements with tag estimation.
        if let tagEstimated = await estimateFeaturesFromTags(rawTags, bpm: bpm) {
            if let audio = audioMeasurements {
                // Valence: tag estimate anchors to genre baseline; chroma-detected mode shifts it
                // ±0.08 scaled by modeConfidence; spectral brightness adds ±0.06 timbral nuance.
                // This approach mirrors Spotify's two strongest valence signals (mode + brightness)
                // while keeping genre tags as the primary anchor so rap doesn't score like pop.
                let modeShift      = audio.modeConfidence * (audio.detectedMode == 1 ? 0.08 : -0.08)
                let brightnessShift = (audio.spectralBrightness - 0.5) * 0.12
                let mergedValence  = max(0, min(1, tagEstimated.valence + modeShift + brightnessShift))
                // Energy: blend RMS (physical loudness) with tag-estimated energy.
                // Tags correct for 808-heavy tracks where RMS is misleadingly high.
                let mergedEnergy   = (audio.energy * 0.45) + (tagEstimated.energy * 0.55)
                // Key/mode: use GetSongBPM if available (human-verified); otherwise use
                // chroma-detected key/mode — a real measurement, not a default C-Major placeholder.
                let finalKey  = gsbpmKey  ?? audio.detectedKey
                let finalMode = gsbpmMode ?? audio.detectedMode
                // Key is reliable if GetSongBPM provided it OR if chroma detection was confident.
                let keyIsReliable = gsbpmKey != nil || audio.modeConfidence >= 0.4
                // Acousticness: blend on-device measurement with tag estimate.
                // Liveness: on-device RMS variance is more reliable than any tag guess.
                let mergedAcousticness = audio.acousticness * 0.6 + tagEstimated.acousticness * 0.4
                let merged = AudioFeatures(
                    bpm:              tagEstimated.bpm,
                    energy:           mergedEnergy,
                    valence:          mergedValence,
                    danceability:     tagEstimated.danceability,
                    acousticness:     mergedAcousticness,
                    instrumentalness: tagEstimated.instrumentalness,
                    liveness:         audio.liveness,
                    loudness:         tagEstimated.loudness,
                    key:              finalKey,
                    mode:             finalMode,
                    isEstimated:      true,   // tag contributes significantly; don't inflate confidence
                    isKeyEstimated:   !keyIsReliable
                )
                simiLog("🎵 Merged audio+tag features for \(song.title) — mode=\(finalMode == 1 ? "major" : "minor") conf=\(String(format:"%.2f", audio.modeConfidence)) valence=\(String(format:"%.2f", mergedValence))")
                Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: merged, source: "preview_audio") }
                return merged
            } else {
                // Tag estimation only.
                simiLog("🏷️ Tag-estimated features for source \"\(song.title)\": \(rawTags.prefix(3).joined(separator: ", "))")
                Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: tagEstimated, source: "tag_estimated") }
                return tagEstimated
            }
        }

        // 4b. Audio-only fallback — tag estimation found nothing but audio analysis succeeded.
        //     Use chroma-detected mode as the primary valence signal (major → 0.60, minor → 0.40),
        //     scaled by modeConfidence so atonal/noisy clips default toward neutral 0.5.
        if let audio = audioMeasurements {
            let modeBase        = audio.detectedMode == 1 ? 0.60 : 0.40
            let brightnessShift = (audio.spectralBrightness - 0.5) * 0.15
            let audioValence    = max(0, min(1,
                modeBase * audio.modeConfidence + 0.5 * (1 - audio.modeConfidence) + brightnessShift
            ))
            let audioOnly = AudioFeatures(
                bpm:              bpm,
                energy:           audio.energy,
                valence:          audioValence,
                danceability:     0.5,
                acousticness:     audio.acousticness,
                instrumentalness: 0.0,
                liveness:         audio.liveness,
                loudness:         -10.0,
                key:              audio.detectedKey,
                mode:             audio.detectedMode,
                isEstimated:      true,   // no genre anchor — mark as estimated
                isKeyEstimated:   audio.modeConfidence < 0.4
            )
            simiLog("🎵 Audio-only features for \(song.title): mode=\(audio.detectedMode == 1 ? "major" : "minor") conf=\(String(format:"%.2f", audio.modeConfidence)) valence=\(String(format:"%.2f", audioValence))")
            Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: audioOnly, source: "preview_audio") }
            return audioOnly
        }

        // 5. BPM only — tag estimation found nothing, but at least we have tempo.
        if bpm > 0 {
            simiLog("✅ BPM only (no tag match): \(song.title)")
            let features = AudioFeatures(
                bpm: bpm, energy: 0.5, valence: 0.5, danceability: 0.5,
                acousticness: 0.0, instrumentalness: 0.0, liveness: 0.0,
                loudness: -10.0, key: 0, mode: 1, isEstimated: true
            )
            Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: features, source: "bpm_only") }
            return features
        }

        // 6. Neutral placeholder — app still works, just less precise scoring
        simiLog("⚠️ No audio features available for \(song.title) — using neutral defaults")
        return AudioFeatures(
            bpm: 0, energy: 0.5, valence: 0.5, danceability: 0.5,
            acousticness: 0.0, instrumentalness: 0.0, liveness: 0.0,
            loudness: -10.0, key: 0, mode: 1, isEstimated: true
        )
    }

    // ──────────────────────────────────────────────
    // ──────────────────────────────────────────────
    // MARK: - Match Explanation Builder
    // ──────────────────────────────────────────────

    /// Generates a human-readable explanation of why `target` was recommended for `source`.
    /// Only includes rows where the data is reliable and the match is close enough to describe.
    /// Called from enrichWithABFeatures after features are known — never in the initial mergeAndScore pass.
    private func buildMatchExplanation(
        source: AudioFeatures,
        target: AudioFeatures,
        sourceGenres: [Genre],
        targetGenre: Genre
    ) -> MatchExplanation {
        var rows: [MatchExplanationRow] = []

        // Row 1: Emotional weight — valence.
        // Use DEAM only when BOTH songs have it (same measurement scale). Mixing DEAM source with
        // SonicDNA-proxy target compresses all candidates to an equal distance from the source,
        // making energy the sole discriminator and producing cross-genre false matches.
        let srcValence: Double
        let tgtValence: Double
        if let sv = source.valenceEssentia, let tv = target.valenceEssentia {
            (srcValence, tgtValence) = (sv, tv)
        } else {
            (srcValence, tgtValence) = (source.valence, target.valence)
        }
        let isEitherEstimated = source.isEstimated || target.isEstimated
        if abs(srcValence - tgtValence) < 0.20 {
            let avg = (srcValence + tgtValence) / 2
            let descriptor: String
            if isEitherEstimated {
                switch avg {
                case ..<0.35:        descriptor = "Similar emotional feel"
                case 0.35..<0.50:    descriptor = "Similar bittersweet range"
                case 0.50..<0.65:    descriptor = "Similar balanced mood"
                default:             descriptor = "Similar warmth"
                }
            } else {
                switch avg {
                case ..<0.35:        descriptor = "Same melancholic weight"
                case 0.35..<0.50:    descriptor = "Same bittersweet edge"
                case 0.50..<0.65:    descriptor = "Same balanced mood"
                default:             descriptor = "Same bright energy"
                }
            }
            rows.append(MatchExplanationRow(label: "Emotional weight", descriptor: descriptor))
        }

        // Row 1.5: Activation level — circumplex arousal axis (librosa only)
        if let srcArousal = source.arousal, let tgtArousal = target.arousal,
           abs(srcArousal - tgtArousal) < 0.20 {
            let avgArousal = (srcArousal + tgtArousal) / 2
            let descriptor: String
            if isEitherEstimated {
                switch avgArousal {
                case ..<0.35:         descriptor = "Similarly calm"
                case 0.35..<0.55:     descriptor = "Similarly measured"
                default:              descriptor = "Similarly activated"
                }
            } else {
                switch avgArousal {
                case ..<0.35:         descriptor = "Equally calm and unhurried"
                case 0.35..<0.55:     descriptor = "Equally measured activation"
                default:              descriptor = "Equally heightened"
                }
            }
            rows.append(MatchExplanationRow(label: "Activation level", descriptor: descriptor))
        }

        // Row 2: Intensity — energy
        // isEstimated check removed — softer descriptors for estimated songs.
        if abs(source.energy - target.energy) < 0.20 {
            let avg = (source.energy + target.energy) / 2
            let descriptor: String
            if isEitherEstimated {
                switch avg {
                case ..<0.35:        descriptor = "Roughly as restrained"
                case 0.35..<0.55:    descriptor = "Roughly as measured"
                case 0.55..<0.75:    descriptor = "Roughly as driven"
                default:             descriptor = "Roughly as intense"
                }
            } else {
                switch avg {
                case ..<0.35:        descriptor = "Equally restrained"
                case 0.35..<0.55:    descriptor = "Equally measured"
                case 0.55..<0.75:    descriptor = "Equally driven"
                default:             descriptor = "Equally intense"
                }
            }
            rows.append(MatchExplanationRow(label: "Intensity", descriptor: descriptor))
        }

        // Row 3: Key — only when both songs have a real measured key (not a C-Major placeholder)
        if !source.isKeyEstimated && !target.isKeyEstimated && source.mode == target.mode {
            let descriptor = source.mode == 1 ? "Both major key" : "Both minor key"
            rows.append(MatchExplanationRow(label: "Key", descriptor: descriptor))
        }

        // Row 4: Groove feel — librosa only (grooveRatio is nil for tag-estimated songs)
        if let srcGroove = source.grooveRatio, let tgtGroove = target.grooveRatio,
           abs(srcGroove - tgtGroove) < 0.35 {
            let avg = (srcGroove + tgtGroove) / 2
            let descriptor: String
            switch avg {
            case ..<0.5:         descriptor = "Smooth and flowing"
            case 0.5..<0.9:      descriptor = "Equally measured pulse"
            default:             descriptor = "Equally syncopated"
            }
            rows.append(MatchExplanationRow(label: "Groove feel", descriptor: descriptor))
        }

        // Row 5: Sonic texture — librosa only (spectralWarmth defaults to 0.5 for estimated songs,
        // but isEstimated=false is the reliable gate since 0.5 is also a valid measured value)
        if !source.isEstimated && !target.isEstimated,
           abs(source.spectralWarmth - target.spectralWarmth) < 0.20 {
            let avg = (source.spectralWarmth + target.spectralWarmth) / 2
            let descriptor: String
            switch avg {
            case ..<0.35:        descriptor = "Both bright and airy"
            case 0.35..<0.65:    descriptor = "Similar tonal warmth"
            default:             descriptor = "Both warm and full"
            }
            rows.append(MatchExplanationRow(label: "Sonic texture", descriptor: descriptor))
        }

        // Genre bridge — compare genre families; show when they differ and both are known
        let sourceFamily = detectGenreFamily(sourceGenres)
        let targetFamily = detectGenreFamily([targetGenre])
        var genreBridgeLabel: String?
        if sourceFamily != targetFamily, sourceFamily != .unknown, targetFamily != .unknown {
            genreBridgeLabel = "\(sourceFamily.displayName) → \(targetFamily.displayName)"
        }

        return MatchExplanation(rows: rows, genreBridgeLabel: genreBridgeLabel)
    }

    /// Computes the feature-space centroid of multiple seed songs for blend-mode explanation.
    /// `isEstimated` / `isKeyEstimated` are conservative: centroid is marked estimated if any
    /// seed is estimated, so explanation row gates behave correctly for mixed-quality blends.
    private func centroid(of seeds: [AudioFeatures]) -> AudioFeatures {
        guard seeds.count > 1 else { return seeds[0] }
        let n = Double(seeds.count)

        func avg(_ kp: KeyPath<AudioFeatures, Double>) -> Double {
            seeds.map { $0[keyPath: kp] }.reduce(0, +) / n
        }
        func avgOpt(_ kp: KeyPath<AudioFeatures, Double?>) -> Double? {
            let vals = seeds.compactMap { $0[keyPath: kp] }
            return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        }
        func majority(_ kp: KeyPath<AudioFeatures, Int>) -> Int {
            let counts = Dictionary(seeds.map { ($0[keyPath: kp], 1) }, uniquingKeysWith: +)
            return counts.max(by: { $0.value < $1.value })?.key ?? seeds[0][keyPath: kp]
        }

        var c = seeds[0]
        c.bpm              = avg(\.bpm)
        c.energy           = avg(\.energy)
        c.valence          = avg(\.valence)
        c.danceability     = avg(\.danceability)
        c.acousticness     = avg(\.acousticness)
        c.instrumentalness = avg(\.instrumentalness)
        c.liveness         = avg(\.liveness)
        c.loudness         = avg(\.loudness)
        c.key              = majority(\.key)
        c.mode             = majority(\.mode)
        c.isEstimated      = seeds.contains { $0.isEstimated }
        c.isKeyEstimated   = seeds.contains { $0.isKeyEstimated }
        c.spectralWarmth   = avg(\.spectralWarmth)
        c.tonalClarity     = avg(\.tonalClarity)
        c.vocalPresence    = avg(\.vocalPresence)
        c.reverbSpace      = avg(\.reverbSpace)
        c.grooveRatio      = avgOpt(\.grooveRatio)
        c.arousal          = avgOpt(\.arousal)
        c.valenceEssentia  = avgOpt(\.valenceEssentia)
        c.chromaEntropy    = avgOpt(\.chromaEntropy)
        c.mfccMean = nil; c.mfccStd = nil; c.spectralContrast = nil; c.chroma = nil
        return c
    }

    // MARK: - Background AcousticBrainz Enrichment
    // ──────────────────────────────────────────────

    /// Enriches recommended songs with tag-estimated audio features + GetSongBPM musical keys.
    /// Collects ALL results first, then applies them in one synchronous batch so SwiftUI
    /// triggers a single re-render instead of ~20 incremental ones (which reset scroll position).
    /// Staggered requests (50ms per song) to avoid bursting Last.fm's rate limit.
    /// GetSongBPM key lookups run after tag estimation for each song — enables the Same Key
    /// filter on recommended songs without requiring Spotify Extended Quota Mode.
    /// When seedFeatures has >1 entry (blend mode), scores candidates against all seeds
    /// and returns the average — ensuring blend results fit the full range of the user's taste.
    // Genre → expected Spotify-scale energy/valence.
    // Python+SonicDNA measure RMS/spectral — systematically ~40-50% lower than
    // Spotify's perceptual energy for groovy/rhythmic genres. These tables let us
    // detect and correct for that bias when raw tags are available.
    private static let genreEnergyTable: [String: Double] = [
        "funk": 0.75, "disco": 0.78, "dance": 0.76, "electronic": 0.74,
        "edm": 0.84, "house": 0.80, "techno": 0.82, "hip-hop": 0.68,
        "hip hop": 0.68, "rap": 0.70, "soul": 0.58, "rnb": 0.58,
        "r&b": 0.58, "pop": 0.64, "rock": 0.70, "punk": 0.82,
        "metal": 0.90, "jazz": 0.44, "blues": 0.46, "folk": 0.38,
        "country": 0.54, "classical": 0.24, "ambient": 0.14,
        "neo-soul": 0.52, "motown": 0.62, "gospel": 0.66
    ]
    private static let genreValenceTable: [String: Double] = [
        "funk": 0.80, "disco": 0.84, "dance": 0.78, "pop": 0.72,
        "soul": 0.64, "rnb": 0.60, "r&b": 0.60, "motown": 0.68,
        "jazz": 0.60, "blues": 0.38, "hip-hop": 0.54, "rap": 0.52,
        "rock": 0.52, "punk": 0.54, "metal": 0.32, "electronic": 0.60,
        "house": 0.74, "folk": 0.54, "country": 0.62, "classical": 0.48,
        "ambient": 0.42, "gospel": 0.72, "neo-soul": 0.56
    ]

    private func enrichWithABFeatures(
        sourceFeatures: AudioFeatures,
        genres: [Genre],
        rawTags: [String] = [],
        seedFeatures: [AudioFeatures] = []
    ) async {
        let snapshot = recommendations
        simiLog("🎵 enrichWithABFeatures called: \(snapshot.count) songs in recommendations")
        guard !snapshot.isEmpty else { return }

        // Stage 0.5: pre-calibrate source before Stage 1 candidate scoring.
        // SonicDNA/Python measure RMS/spectral amplitude — 40-50% lower than Spotify's
        // perceptual energy for groovy genres. Without this, Boogie Wonderland (tag energy 0.75)
        // scores terribly against Fantasy's raw energy (0.27), gets cut by the quality filter,
        // and never reaches Stage 2.5 where calibration previously lived. Classic rock songs
        // with moderate estimated energy (~0.45) survive instead because they're "closer" to 0.27.
        // Calibrating here ensures genre-correct candidates aren't filtered before they can compete.
        var sourceFeatures = sourceFeatures
        if !rawTags.isEmpty {
            let tagEnergies = rawTags.compactMap { Self.genreEnergyTable[$0.lowercased()] }
            let tagValences = rawTags.compactMap { Self.genreValenceTable[$0.lowercased()] }
            if !tagEnergies.isEmpty {
                let genreMeanEnergy = tagEnergies.reduce(0, +) / Double(tagEnergies.count)
                let energyGap = genreMeanEnergy - sourceFeatures.energy
                if energyGap > 0.25 {
                    let calibrated = sourceFeatures.energy * 0.35 + genreMeanEnergy * 0.65
                    simiLog("📈 Stage 1 source energy calibration (\(rawTags.prefix(3).joined(separator: "/"))): \(String(format: "%.2f", sourceFeatures.energy)) → \(String(format: "%.2f", calibrated)) (genre mean \(String(format: "%.2f", genreMeanEnergy)))")
                    sourceFeatures.energy = calibrated
                }
            }
            if !tagValences.isEmpty {
                let genreMeanValence = tagValences.reduce(0, +) / Double(tagValences.count)
                let valenceGap = genreMeanValence - sourceFeatures.valence
                if valenceGap > 0.20 {
                    let calibrated = sourceFeatures.valence * 0.35 + genreMeanValence * 0.65
                    simiLog("📈 Stage 1 source valence calibration (\(rawTags.prefix(3).joined(separator: "/"))): \(String(format: "%.2f", sourceFeatures.valence)) → \(String(format: "%.2f", calibrated)) (genre mean \(String(format: "%.2f", genreMeanValence)))")
                    sourceFeatures.valence = calibrated
                }
            }
        }

        simiLog("🎵 Starting tag-feature enrichment for \(snapshot.count) songs...")

        // Fill preview URLs so the audio player can play songs.
        // Snapshot is intentionally taken before the fill: songs from Last.fm/MusicBrainz arrive
        // without previewURL, so Priority 2 (LocalAudio) fails immediately and falls through to fast
        // tag estimation for them. Stage 2 then handles the top-10 with SonicDNA.
        // Running fill first would make Priority 2 fire for 50+ songs simultaneously, turning
        // a 3s enrichment into a 2-minute download+analyze marathon.
        await fillMissingPreviewURLs()

        var tagUpdates: [(index: Int, features: AudioFeatures, genre: Genre?)] = []

        // Limits adjacent-genre candidates (penalty 0.12) to 10 slots across the entire pool.
        // Distant-genre candidates (penalty 0.18+) remain hard-excluded regardless.
        // Same-genre candidates are uncapped.
        // The actor counter is claimed in index order, so higher-priority (lower-index) candidates
        // consume slots first — tag/vector candidates before social-graph candidates.
        // 10 (up from 5) to accommodate hybrid-family sources like "raprock" where both
        // hiphop AND rock neighbours are adjacent — previously both were free (same "hiphop" family).
        let adjacentQuota = GenreQuotaTracker(limit: 10)
        // Captured once on main actor so child tasks don't hop back to it for every analyze call.
        let analyzer = localAudioAnalyzer

        await withTaskGroup(of: (Int, AudioFeatures?, Genre?).self) { group in
            for (index, song) in snapshot.enumerated() {
                group.addTask {
                    // ── Step 0: Last.fm tags → genre pre-filter ──
                    // Tags are fetched first for ALL candidates so that:
                    // (1) cross-genre songs are excluded before any expensive feature lookups,
                    // (2) Supabase/AB cache hits get the correct targetGenre (fixes nil-genre
                    //     bug where cached songs inherited the SOURCE genre and escaped penalty).
                    // Stagger applies to all paths since all now call Last.fm.
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(min(index, 15)) * 20_000_000)
                    }
                    // Fetch track-level AND artist-level tags in parallel.
                    // Track tags alone are unreliable — community mis-tags happen constantly
                    // (BTS "Aliens" → "trap, pop rap" at track level, "k-pop" at artist level).
                    // Merging both gives the genre filter the full picture.
                    async let trackTagsTask   = self.lastFMService.fetchRawTags(title: song.title, artist: song.artist)
                    async let artistTagsTask  = self.lastFMService.fetchArtistRawTags(artist: song.artist)
                    let trackTags  = await trackTagsTask
                    let artistTags = await artistTagsTask
                    // Append artist tags that aren't already covered by track tags (up to 5 extra).
                    let trackTagSet = Set(trackTags)
                    let extraArtist = artistTags.filter { !trackTagSet.contains($0) }.prefix(5)
                    let tags = trackTags + Array(extraArtist)
                    let targetGenre = await self.genresFromRawTags(tags).first

                    // Genre gate: hard-exclude distant families; soft-cap adjacent families at 5.
                    // Distant (0.18+): never passes regardless of acoustic score.
                    // Adjacent (0.12): max 5 candidates across the whole pool — prevents social-graph
                    //   bleed from filling result slots that should go to genre-correct candidates,
                    //   while still allowing the rare emotionally-matched cross-genre find.
                    // Same family (0): uncapped.
                    if let tg = targetGenre, !genres.isEmpty {
                        let penalty = self.genrePenalty(sourceGenres: genres, targetGenre: tg)
                        if penalty >= 0.18 {
                            simiLog("🚫 Pool pre-filter: excluded \"\(song.title)\" (\(tg.main), penalty \(String(format: "%.2f", penalty)))")
                            return (index, nil, nil)
                        } else if penalty > 0 {
                            let allowed = await adjacentQuota.claim()
                            if !allowed {
                                simiLog("🚫 Adjacent quota full: excluded \"\(song.title)\" (\(tg.main))")
                                return (index, nil, nil)
                            }
                        }
                    }

                    // ── Priority 1: Supabase feature cache ──
                    if let cached = await self.supabase.lookupFeatures(title: song.title, artist: song.artist) {
                        simiLog("✅ Supabase cache hit (enrichment): \"\(song.title)\"")
                        return (index, cached, targetGenre)
                    }

                    // ── Priority 2: on-device local audio analysis ──
                    // Only fires for songs that already had previewURL before enrichment started
                    // (Spotify-sourced songs). Last.fm/MusicBrainz songs have nil previewURL here
                    // since the snapshot is taken before fillMissingPreviewURLs — intentional, keeps
                    // enrichment fast. Stage 2 covers the top 10 with SonicDNA after tag estimation.
                    if let previewURL = song.previewURL,
                       let audioURL = URL(string: previewURL),
                       let (audioData, audioResp) = try? await URLSession.shared.data(from: audioURL),
                       (audioResp as? HTTPURLResponse)?.statusCode == 200,
                       let measured = await analyzer.analyze(data: audioData, sourceURL: previewURL, title: song.title) {
                        simiLog("🎛️ LocalAudio measured: \"\(song.title)\"")
                        Task { await self.supabase.storeFeatures(title: song.title, artist: song.artist, features: measured, source: "preview_audio") }
                        return (index, measured, targetGenre)
                    }

                    // ── Priority 3: tag estimation (fallback when no preview URL or download failed) ──
                    guard var estimated = await self.estimateFeaturesFromTags(tags) else {
                        return (index, nil, nil)
                    }
                    simiLog("🏷️ Tag-estimated features for \"\(song.title)\": \(tags.prefix(3).joined(separator: ", "))")

                    // GetSongBPM key: only needed here because tag estimation leaves key=0/mode=1
                    // (LocalAudio songs already have measured key/BPM — quota saved there).
                    // Capped to top 20 songs: protects the 500 req/day quota.
                    if index < 20,
                       let songData = await self.getSongBPMService.fetchSongData(title: song.title, artist: song.artist),
                       let key = songData.key, let mode = songData.mode {
                        let rawBPM = songData.bpm > 0 ? songData.bpm : estimated.bpm
                        let resolvedBPM = songData.bpm > 0 ? self.normalizeBPM(rawBPM, tags: tags) : estimated.bpm
                        estimated = AudioFeatures(
                            bpm:              resolvedBPM,
                            energy:           estimated.energy,
                            valence:          estimated.valence,
                            danceability:     estimated.danceability,
                            acousticness:     estimated.acousticness,
                            instrumentalness: estimated.instrumentalness,
                            liveness:         estimated.liveness,
                            loudness:         estimated.loudness,
                            key:              key,
                            mode:             mode,
                            isEstimated:      true,
                            isKeyEstimated:   false
                        )
                        let keyNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
                        let modeName = mode == 1 ? "Major" : "Minor"
                        let keyLabel = key >= 0 && key < keyNames.count ? keyNames[key] : "?"
                        simiLog("🎵 Key from GetSongBPM: \(keyLabel) \(modeName) for \"\(song.title)\"")
                    }

                    return (index, estimated, targetGenre)
                }
            }

            for await (index, features, genre) in group {
                if let features {
                    tagUpdates.append((index: index, features: features, genre: genre))
                } else if index < recommendations.count {
                    // Stage 1 excluded this song (distant genre / quota). Zero its score so
                    // the quality filter removes it before Stage 2 picks it up via previewURL.
                    // Without this, excluded songs (e.g. L.E.S. Girl for a rap search) keep
                    // their mergeAndScore value, survive the filter, and get SonicDNA analysis
                    // with no genre penalty applied — producing nonsense "Very similar" matches.
                    recommendations[index].similarityScore = 0
                }
            }
        }

        // ── STAGE 1: apply tag estimates immediately — UI renders before librosa finishes ──
        var enrichedCount = 0
        for update in tagUpdates {
            guard update.index < recommendations.count else { continue }
            // Store the candidate's own genre derived from its Last.fm tags so the genre
            // penalty has real target data and the UI shows the correct genre label.
            if let tg = update.genre {
                recommendations[update.index].genre = tg
            }
            let targetGenre = recommendations[update.index].genre
            let (score, reasons) = seedFeatures.count > 1
                ? computeSimilarityMultiSeed(seeds: seedFeatures, target: update.features, genres: genres, targetGenre: targetGenre)
                : computeSimilarity(source: sourceFeatures, target: update.features, genres: genres, targetGenre: targetGenre)
            recommendations[update.index].audioFeatures   = update.features
            recommendations[update.index].similarityScore = score
            recommendations[update.index].matchReasons    = reasons
            let explanationSource = seedFeatures.count > 1 ? centroid(of: seedFeatures) : sourceFeatures
            recommendations[update.index].matchExplanation = buildMatchExplanation(
                source: explanationSource,
                target: update.features,
                sourceGenres: genres,
                targetGenre: targetGenre
            )
            enrichedCount += 1
        }

        if enrichedCount > 0 {
            simiLog("✅ Background tag enrichment updated \(enrichedCount) songs")
        }

        let coverageRatio = Double(enrichedCount) / Double(max(1, snapshot.count))
        simiLog("📊 Enrichment coverage: \(enrichedCount)/\(snapshot.count) (\(String(format: "%.0f", coverageRatio * 100))%) — quality filter \(coverageRatio >= 0.3 ? "will run" : "skipped (low coverage)")")
        if coverageRatio >= 0.3 {
            let before = recommendations.count
            let scoreRange = recommendations.map { $0.similarityScore }
            let minScore = scoreRange.min() ?? 0
            let maxScore = scoreRange.max() ?? 0
            simiLog("📊 Score distribution before filter: min=\(String(format: "%.3f", minScore)) max=\(String(format: "%.3f", maxScore))")
            let threshold = 0.65
            let minFloor  = 8
            let filtered  = recommendations.filter { $0.similarityScore >= threshold }
            // Never show fewer than minFloor results — if threshold is too aggressive for this
            // pool (e.g. Spotify down, only LB candidates), keep the top minFloor by score.
            recommendations = filtered.count >= minFloor ? filtered : Array(recommendations.prefix(minFloor))
            let removed = before - recommendations.count
            if removed > 0 {
                simiLog("🔪 Quality filter removed \(removed) low-scoring songs (threshold \(threshold)), \(recommendations.count) remain")
            }
        }

        recommendations.sort { $0.similarityScore > $1.similarityScore }
        simiLog("✅ Tag enrichment done: \(enrichedCount)/\(snapshot.count) songs got features")

        // ── STAGE 2: SonicDNA on-device analysis for top candidates ──
        // Replaces remote HF Spaces with LocalAudioAnalyzer — the same DSP engine
        // used for source songs. All songs run fully concurrently: no batching needed,
        // no cold starts, no network roundtrip. Each call writes its own temp file so
        // concurrent execution is safe by design (see LocalAudioAnalyzer comments).
        guard !Task.isCancelled else {
            simiLog("⚠️ SonicDNA Stage 2 cancelled before start — new search fired")
            return
        }

        // Filter: only songs still on tag-estimated features (isEstimated = true or nil features).
        // Songs already measured (isEstimated = false) came from Supabase or source analysis — skip.
        let sonicTargets = Array(recommendations
            .prefix(15)
            .enumerated()
            .compactMap { (i, song) -> (index: Int, url: String, title: String, artist: String, genreHints: [String])? in
                guard let url = song.previewURL,
                      song.audioFeatures?.isEstimated != false else { return nil }
                var hints = [song.genre.main.lowercased()]
                if let sub = song.genre.sub { hints.append(sub.lowercased()) }
                return (index: i, url: url, title: song.title, artist: song.artist, genreHints: hints)
            }
            .prefix(10))

        guard !sonicTargets.isEmpty else {
            simiLog("🎛️ Stage 2 skipped — top songs already have measured features")
            return
        }

        simiLog("🎛️ SonicDNA Stage 2: \(sonicTargets.count) candidates, fully concurrent…")

        // Phase 1: Download all preview audio in parallel (pure I/O).
        typealias DownloadedTarget = (index: Int, data: Data, url: String, title: String, artist: String, genreHints: [String])
        let downloaded: [DownloadedTarget] = await withTaskGroup(of: DownloadedTarget?.self) { group in
            for target in sonicTargets {
                group.addTask {
                    guard !Task.isCancelled,
                          let audioURL = URL(string: target.url),
                          let (data, response) = try? await URLSession.shared.data(from: audioURL),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return (target.index, data, target.url, target.title, target.artist, target.genreHints)
                }
            }
            var results: [DownloadedTarget] = []
            for await result in group { if let r = result { results.append(r) } }
            return results
        }

        guard !downloaded.isEmpty else { return }

        // Phase 2: Analyze downloads with SonicDNA via DSPCoolant.
        // Coolant caps concurrent analyze() calls at 3 and staggers the initial
        // burst (80 ms between the first 3 starts) to smooth the CPU ramp-up.
        // Task.yield() inside buildFeatures() every 128 frames makes each task
        // genuinely cooperative so the OS can service UI events mid-analysis.
        var sonicSucceeded = 0
        let coolant = DSPCoolant(slots: 3)
        await withTaskGroup(of: (Int, AudioFeatures?).self) { group in
            for dl in downloaded {
                group.addTask(priority: .utility) {
                    await coolant.enter()
                    defer { Task { await coolant.exit() } }
                    guard !Task.isCancelled else { return (dl.index, nil) }
                    return (dl.index, await analyzer.analyze(data: dl.data, sourceURL: dl.url, title: dl.title, genreHints: dl.genreHints))
                }
            }
            for await result in group {
                let (idx, features) = result
                guard let features, idx < self.recommendations.count else { continue }
                let song = self.recommendations[idx]
                let targetGenre = self.recommendations[idx].genre
                let (score, reasons) = seedFeatures.count > 1
                    ? self.computeSimilarityMultiSeed(seeds: seedFeatures, target: features, genres: genres, targetGenre: targetGenre)
                    : self.computeSimilarity(source: sourceFeatures, target: features, genres: genres, targetGenre: targetGenre)
                self.recommendations[idx].audioFeatures   = features
                self.recommendations[idx].similarityScore = score
                self.recommendations[idx].matchReasons    = reasons
                let explanationSource = seedFeatures.count > 1 ? self.centroid(of: seedFeatures) : sourceFeatures
                self.recommendations[idx].matchExplanation = self.buildMatchExplanation(
                    source: explanationSource,
                    target: features,
                    sourceGenres: genres,
                    targetGenre: self.recommendations[idx].genre
                )
                Task { await self.supabase.storeFeatures(title: song.title, artist: song.artist, features: features, source: "sonicdna") }
                sonicSucceeded += 1
            }
        }

        if sonicSucceeded > 0 {
            recommendations.sort { $0.similarityScore > $1.similarityScore }
            simiLog("✅ SonicDNA Stage 2 done: \(sonicSucceeded)/\(sonicTargets.count) measured, list re-sorted")

            // Stage 2.6: Silent async DEAM enrichment for top candidates.
            // Fires non-blocking after Stage 2 — the user already sees results.
            // Re-downloads preview audio for up to 5 top-ranked candidates with
            // a previewURL, runs HF Essentia/DEAM, and overwrites valenceEssentia
            // + arousal (including any CoreML bootstrap) with ground-truth DEAM.
            // Persists to Supabase — future searches get DEAM-quality valence
            // with zero wait time (cache hit at Stage 1).
            let deamQueue = recommendations
                .prefix(8)
                .filter { $0.previewURL != nil }
                .prefix(5)
                .map { ($0.title, $0.artist, $0.id, $0.previewURL!) }

            if !deamQueue.isEmpty {
                simiLog("🔬 Stage 2.6: queuing DEAM enrichment for \(deamQueue.count) candidates")
                Task(priority: .background) {
                    for (title, artist, songId, urlStr) in deamQueue {
                        guard let audioURL = URL(string: urlStr),
                              let (data, resp) = try? await URLSession.shared.data(from: audioURL),
                              (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }

                        guard let pyFeatures = await simiAudioService.analyzeDownloadedAudio(
                            data: data, sourceURL: urlStr,
                            artist: artist, title: title, spotifyId: songId) else { continue }

                        guard let liveIdx = recommendations.firstIndex(where: {
                            $0.title == title && $0.artist == artist
                        }), var af = recommendations[liveIdx].audioFeatures else { continue }

                        if let vv = pyFeatures.valenceEssentia { af.valenceEssentia = vv }
                        if let da = pyFeatures.arousal { af.arousal = da }
                        recommendations[liveIdx].audioFeatures = af
                        let enriched = af  // snapshot before Task capture
                        Task { await supabase.storeFeatures(title: title, artist: artist, features: enriched, source: "deam_enriched") }
                        simiLog("🔬 Stage 2.6 ✓ \(title): valenceEssentia=\(String(format:"%.2f", pyFeatures.valenceEssentia ?? -1)) arousal=\(String(format:"%.2f", pyFeatures.arousal ?? -1))")
                    }
                }
            }

            // Stage 2.5: source re-analysis.
            // Triggers when source is tag-estimated OR Python-measured (valenceEssentia != nil).
            // Python (DEAM neural) and SonicDNA (DSP proxy) don't share a measurement scale —
            // comparing Python source to SonicDNA candidates inflates scores for any song with
            // similar energy regardless of actual vibe. Re-analyzing the source with SonicDNA
            // gives apples-to-apples comparison and fixes "family ties looks like Peso" false matches.
            if (sourceFeatures.isEstimated || sourceFeatures.valenceEssentia != nil), let srcSong = self.sourceSong {
                let srcURL: String?
                if let url = srcSong.previewURL {
                    srcURL = url
                } else if let url = await itunesService.fetchPreviewURL(title: srcSong.title, artist: srcSong.artist) {
                    srcURL = url
                } else if let url = await deezerService.fetchPreviewURL(title: srcSong.title, artist: srcSong.artist) {
                    srcURL = url
                } else {
                    srcURL = nil
                }
                if let url = srcURL,
                   let audioURL = URL(string: url),
                   let (data, response) = try? await URLSession.shared.data(from: audioURL),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   var real = await localAudioAnalyzer.analyze(data: data, sourceURL: url, title: srcSong.title, genreHints: rawTags) {
                    // BPM octave guard: the local analyzer uses a 30-second preview and can land
                    // at half- or double-tempo. Python librosa analyzes the full track and is
                    // more reliable in most cases — but half-time feel songs (bolero, danzón,
                    // slow rumba) have a slow felt groove that Python double-detects as subdivisions.
                    // When SonicDNA reads ~half Python's BPM and energy is low, trust SonicDNA.
                    let pythonBPM = sourceFeatures.bpm
                    var halfTimeFeel = false
                    if pythonBPM > 0 && real.bpm > 0 {
                        let directDiff = abs(real.bpm - pythonBPM)
                        let halfDiff   = abs(real.bpm * 2.0 - pythonBPM)
                        let dblDiff    = abs(real.bpm / 2.0 - pythonBPM)
                        if directDiff > 15 && (halfDiff < 20 || dblDiff < 20) {
                            let sonicIsHalf = halfDiff < 20
                            if sonicIsHalf && real.bpm < 100 && real.energy < 0.55 {
                                // Half-time feel: Python locked onto subdivisions of a slow groove.
                                // SonicDNA's lower BPM is the actual felt tempo — keep it.
                                halfTimeFeel = true
                                simiLog("🥁 Stage 2.5 BPM: half-time feel (SonicDNA=\(Int(real.bpm))BPM energy=\(String(format: "%.2f", real.energy))) — trusting SonicDNA over Python \(Int(pythonBPM))BPM")
                            } else {
                                simiLog("🥁 Stage 2.5 BPM octave correction: SonicDNA=\(Int(real.bpm)) → keeping Python \(Int(pythonBPM))BPM")
                                real.bpm = pythonBPM
                            }
                        }
                    }
                    // Quiet-intro deflation guard: some songs have soft intros; the 30-second
                    // preview deflates energy/valence vs the full song that Python measured.
                    // Blend 50/50 so Stage 2.5 stays on the SonicDNA scale (apples-to-apples with
                    // candidates) while anchoring against intro-only misreadings.
                    // Skip the blend for half-time feel songs — SonicDNA's low energy is correct.
                    if !sourceFeatures.isEstimated && !halfTimeFeel {
                        // Always log the SonicDNA↔Python delta — calibration feedback loop.
                        let vDelta = real.valence - sourceFeatures.valence
                        let eDelta = real.energy - sourceFeatures.energy
                        let arousalDeltaStr: String
                        if let ra = real.arousal, let sa = sourceFeatures.arousal {
                            arousalDeltaStr = " | arousal SonicDNA=\(String(format:"%.2f",ra)) Python=\(String(format:"%.2f",sa)) Δ=\(String(format:"%+.2f",ra-sa))"
                        } else {
                            arousalDeltaStr = ""
                        }
                        simiLog("📐 Stage 2.5 delta: valence SonicDNA=\(String(format:"%.2f",real.valence)) Python=\(String(format:"%.2f",sourceFeatures.valence)) Δ=\(String(format:"%+.2f",vDelta)) | energy SonicDNA=\(String(format:"%.2f",real.energy)) Python=\(String(format:"%.2f",sourceFeatures.energy)) Δ=\(String(format:"%+.2f",eDelta))\(arousalDeltaStr)")
                        let eDropped = sourceFeatures.energy - real.energy
                        if eDropped > 0.12 {
                            let blended = (sourceFeatures.energy + real.energy) / 2.0
                            simiLog("⚡ Stage 2.5 energy blend: SonicDNA=\(String(format: "%.2f", real.energy)) Python=\(String(format: "%.2f", sourceFeatures.energy)) → \(String(format: "%.2f", blended))")
                            real.energy = blended
                        }
                        let vDropped = sourceFeatures.valence - real.valence
                        if vDropped > 0.12 {
                            let blended = (sourceFeatures.valence + real.valence) / 2.0
                            simiLog("🎭 Stage 2.5 valence blend: SonicDNA=\(String(format: "%.2f", real.valence)) Python=\(String(format: "%.2f", sourceFeatures.valence)) → \(String(format: "%.2f", blended))")
                            real.valence = blended
                        }
                    }
                    // Genre calibration: Python+SonicDNA measure RMS/spectral amplitude;
                    // Spotify's energy is perceptual (rhythm, groove, dynamic complexity).
                    // For funk/disco/soul, the gap is ~40-50%. When the raw tags strongly
                    // suggest a high-energy genre but measured energy is low, blend toward
                    // the genre expectation to avoid matching quiet ballads as "Near-perfect".
                    if !rawTags.isEmpty {
                        let tagEnergies = rawTags.compactMap { Self.genreEnergyTable[$0.lowercased()] }
                        let tagValences = rawTags.compactMap { Self.genreValenceTable[$0.lowercased()] }
                        if !tagEnergies.isEmpty {
                            let genreMeanEnergy = tagEnergies.reduce(0, +) / Double(tagEnergies.count)
                            let energyGap = genreMeanEnergy - real.energy
                            if energyGap > 0.25 {
                                let calibrated = real.energy * 0.35 + genreMeanEnergy * 0.65
                                simiLog("📈 Genre energy calibration (\(rawTags.prefix(3).joined(separator: "/"))): \(String(format: "%.2f", real.energy)) → \(String(format: "%.2f", calibrated)) (genre mean \(String(format: "%.2f", genreMeanEnergy)))")
                                real.energy = calibrated
                            }
                        }
                        if !tagValences.isEmpty {
                            let genreMeanValence = tagValences.reduce(0, +) / Double(tagValences.count)
                            let valenceGap = genreMeanValence - real.valence
                            if valenceGap > 0.20 {
                                let calibrated = real.valence * 0.35 + genreMeanValence * 0.65
                                simiLog("📈 Genre valence calibration (\(rawTags.prefix(3).joined(separator: "/"))): \(String(format: "%.2f", real.valence)) → \(String(format: "%.2f", calibrated)) (genre mean \(String(format: "%.2f", genreMeanValence)))")
                                real.valence = calibrated
                            }
                        }
                    }
                    // Preserve source key — SonicDNA key detection on quiet-intro previews is
                    // unreliable (e.g. Ab Major confidently detected as D# Minor via chroma
                    // centroid confusion). The key from Spotify is reliable; estimated key keeps
                    // mode scoring neutral. Either is better than SonicDNA's guess here.
                    real.key           = sourceFeatures.key
                    real.mode          = sourceFeatures.mode
                    real.isKeyEstimated = sourceFeatures.isKeyEstimated
                    simiLog("✅ Source re-analyzed (SonicDNA): \(srcSong.title) — \(Int(real.bpm))BPM e=\(String(format: "%.2f", real.energy)) v=\(String(format: "%.2f", real.valence))")
                    self.lastSourceFeatures = real
                    self.sourceSong?.audioFeatures = real
                    Task { await self.supabase.storeFeatures(title: srcSong.title, artist: srcSong.artist, features: real, source: "sonicdna") }
                    for i in 0..<recommendations.count {
                        guard let tf = recommendations[i].audioFeatures else { continue }
                        let tg = recommendations[i].genre
                        let (score, reasons) = seedFeatures.count > 1
                            ? computeSimilarityMultiSeed(seeds: seedFeatures, target: tf, genres: genres, targetGenre: tg)
                            : computeSimilarity(source: real, target: tf, genres: genres, targetGenre: tg)
                        recommendations[i].similarityScore = score
                        recommendations[i].matchReasons    = reasons
                        recommendations[i].matchExplanation = buildMatchExplanation(
                            source: real, target: tf, sourceGenres: genres, targetGenre: tg
                        )
                    }
                    recommendations.sort { $0.similarityScore > $1.similarityScore }
                    simiLog("🎯 Source upgraded estimated → measured, list re-sorted")
                }
            }
        } else {
            simiLog("⚠️ SonicDNA Stage 2: 0/\(sonicTargets.count) — audio decode failed or search cancelled")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Background Preview URL Fill
    // ──────────────────────────────────────────────

    /// Fills in missing preview URLs via iTunes after results are already shown.
    /// Runs all iTunes lookups concurrently — was sequential per-song in mergeAndScore
    /// (up to 60 calls × ~0.8s = ~48s). Now parallel: all complete in ~1-3s wall time.
    private func fillMissingPreviewURLs() async {
        let snapshot = recommendations
        let needsURL = snapshot.enumerated()
            .filter { $0.element.previewURL == nil || $0.element.albumArt.isEmpty }
            .map { (index: $0.offset, title: $0.element.title, artist: $0.element.artist,
                    needsPreview: $0.element.previewURL == nil) }
        guard !needsURL.isEmpty else { return }

        simiLog("🎵 Fetching \(needsURL.count) iTunes preview URLs in parallel…")
        let updates: [(Int, String?, String?)] = await withTaskGroup(of: (Int, String?, String?).self) { group in
            for item in needsURL {
                group.addTask {
                    let (itPreview, artwork) = await self.itunesService.fetchPreviewAndArtwork(
                        title: item.title, artist: item.artist)
                    var preview: String? = itPreview
                    if item.needsPreview && preview == nil {
                        preview = await self.deezerService.fetchPreviewURL(title: item.title, artist: item.artist)
                    }
                    // LB crosswalk fallback: MBID → Apple Music ID → iTunes /lookup
                    // More precise than fuzzy search — resolves tracks iTunes search misses.
                    if item.needsPreview && preview == nil,
                       let mbid   = await self.listenBrainzService.resolveACRMBID(title: item.title, artist: item.artist),
                       let amID   = await self.listenBrainzService.resolveAppleMusicID(mbid: mbid),
                       let lbPreview = await self.itunesService.fetchPreviewByAppleMusicID(amID) {
                        preview = lbPreview
                        simiLog("🔗 LB crosswalk resolved preview for \(item.title)")
                    }
                    return (item.index, item.needsPreview ? preview : nil, artwork)
                }
            }
            var result: [(Int, String?, String?)] = []
            for await tuple in group { result.append(tuple) }
            return result
        }

        guard !updates.isEmpty else { return }
        var previewCount = 0, artCount = 0
        for (index, preview, artwork) in updates {
            guard index < recommendations.count else { continue }
            if let preview { recommendations[index].previewURL = preview; previewCount += 1 }
            if let artwork, recommendations[index].albumArt.isEmpty {
                recommendations[index].albumArt = artwork; artCount += 1
            }
        }
        let needsPreviewCount = needsURL.filter { $0.needsPreview }.count
        simiLog("🎵 Preview URLs filled: \(previewCount)/\(needsPreviewCount)")
        if artCount > 0 { simiLog("🖼️ Album art filled: \(artCount)") }
    }

    // ──────────────────────────────────────────────
    // MARK: - Merge and Score Recommendations
    // ──────────────────────────────────────────────

    /// Merges recommendations from Spotify, Last.fm similarity, and genre tag pools.
    /// Deduplicates, scores each candidate, and applies artist diversity.
    ///
    /// Three candidate sources:
    ///   1. Spotify recs — restricted until Extended Quota Mode; usually empty
    ///   2. Last.fm track.getSimilar — co-listening patterns; tends to cluster by artist
    ///   3. tag-based pool — top tracks from the source song's genre tags; spans many artists
    ///
    /// When seedFeatures has >1 entry (blend mode), each candidate is scored against every seed
    /// individually and the average is returned — so results reflect the full blend, not just
    /// the averaged midpoint.
    private func mergeAndScore(
        spotifyRecs: [Song],
        lastFMTracks: [(title: String, artist: String)],
        sourceSong: Song,
        sourceFeatures: AudioFeatures,
        genres: [Genre],
        excludeIDs: Set<String> = [],
        seedFeatures: [AudioFeatures] = [],
        prefetchedFeatures: [String: AudioFeatures] = [:]
    ) async throws -> [SimilarSong] {

        var results: [SimilarSong] = []
        // Pre-seed with source + any extra IDs to exclude (multi-seed search)
        var seen = Set<String>(excludeIDs)
        seen.insert(sourceSong.id)

        // Picks the right scoring strategy: multi-seed average or single-source
        func score(target: AudioFeatures?) -> (Double, [MatchReason]) {
            seedFeatures.count > 1
                ? computeSimilarityMultiSeed(seeds: seedFeatures, target: target, genres: genres)
                : computeSimilarity(source: sourceFeatures, target: target, genres: genres)
        }

        // ── Source 1: Spotify recommendations ──
        // For the top 5 songs, use prefetched librosa features if available (keyed by Spotify track ID).
        // This ensures the first render is scored with real measured features rather than nil.
        // Remaining songs fall through to nil-score as before; enrichment fills them in background.
        // Preview URL: use Spotify's if available, nil otherwise. fillMissingPreviewURLs() fills
        // in the iTunes fallback in parallel after results are shown — not on the critical path.
        for song in spotifyRecs {
            guard seen.insert(song.id).inserted else { continue }
            let features = prefetchedFeatures[song.id]
            let (s, reasons) = score(target: features)
            let era = eraPenalty(sourceYear: sourceSong.releaseYear, targetYear: song.releaseYear)
            results.append(SimilarSong(
                id: song.id, title: song.title, artist: song.artist,
                albumArt: song.albumArt, spotifyURL: song.spotifyURL, previewURL: song.previewURL,
                genre: genres.first ?? Genre(main: "Unknown"),
                audioFeatures: features, similarityScore: max(0, s - era), matchReasons: reasons
            ))
        }

        // ── Source 2: Last.fm similar tracks + emotional tag pool ──
        // Resolve in parallel, then score sequentially to avoid races on `seen`.
        // Cache-first Spotify resolution:
        //   1. Check Supabase — popular songs served instantly, zero Spotify calls
        //   2. On Supabase miss, call Spotify and write result back to cache
        //   3. On Spotify 429/failure, fall through to stub (iTunes fills art + preview later)
        // Cap at 25 (was 60) — shared credentials mean shared rate limit across all users.
        // Stagger: 80ms/track so 25 calls spread over ~2s instead of bursting.
        let lastFMSongs: [Song] = await withTaskGroup(of: Song.self) { group in
            for (index, (title, artist)) in lastFMTracks.prefix(25).enumerated() {
                group.addTask {
                    // Layer 1: Supabase cache — free, instant, no rate limit
                    if let cached = await self.supabase.lookupSpotifyTrack(title: title, artist: artist) {
                        return cached
                    }
                    // Layer 2: Spotify live search — staggered to avoid burst
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(index) * 80_000_000)
                    }
                    if let found = try? await self.spotifyService.searchTrack(title: title, artist: artist) {
                        // Write through to cache so next user gets it for free
                        await self.supabase.storeSpotifyTrack(found)
                        return found
                    }
                    // Layer 3: Stub — iTunes fills art + preview in enrichWithABFeatures
                    let stubID = "stub:\(title.lowercased()):\(artist.lowercased())"
                    return Song(id: stubID, title: title, artist: artist,
                                albumArt: "", previewURL: nil, spotifyURL: "",
                                sourceURL: "")
                }
            }
            var songs: [Song] = []
            for await song in group { songs.append(song) }
            return songs
        }
        let spotifyHits = lastFMSongs.filter { !$0.id.hasPrefix("stub:") }.count
        if spotifyHits < lastFMSongs.count {
            simiLog("⚠️ Spotify search: \(spotifyHits)/\(lastFMSongs.count) resolved — \(lastFMSongs.count - spotifyHits) using stubs (no art/link)")
        }
        // Batch-lookup Supabase feature cache for all resolved Last.fm songs in parallel.
        // Songs analyzed in a previous session get real similarity scores on first render
        // instead of the flat 0.50 nil-features fallback.
        let supabasePrefetch: [String: AudioFeatures] = await withTaskGroup(of: (String, AudioFeatures?).self) { group in
            for song in lastFMSongs {
                group.addTask {
                    let f = await self.supabase.lookupFeatures(title: song.title, artist: song.artist)
                    return (song.id, f)
                }
            }
            var map: [String: AudioFeatures] = [:]
            for await (id, f) in group {
                if let f { map[id] = f }
            }
            return map
        }
        let supabaseHits = supabasePrefetch.count
        if supabaseHits > 0 {
            simiLog("✅ Supabase prefetch: \(supabaseHits)/\(lastFMSongs.count) Last.fm songs have cached features for first render")
        }

        for song in lastFMSongs {
            guard seen.insert(song.id).inserted else { continue }
            let cachedFeatures = supabasePrefetch[song.id]
            let (s, reasons) = score(target: cachedFeatures)
            let era = eraPenalty(sourceYear: sourceSong.releaseYear, targetYear: song.releaseYear)
            results.append(SimilarSong(
                id: song.id, title: song.title, artist: song.artist,
                albumArt: song.albumArt, spotifyURL: song.spotifyURL, previewURL: song.previewURL,
                genre: genres.first ?? Genre(main: "Unknown"),
                audioFeatures: cachedFeatures, similarityScore: max(0, s - era), matchReasons: reasons
            ))
        }

        results.sort { $0.similarityScore > $1.similarityScore }
        return applyArtistDiversity(results, sourceArtist: sourceSong.artist)
    }

    // ──────────────────────────────────────────────
    // MARK: - Genre Gate (pre-enrichment pass)
    // ──────────────────────────────────────────────

    /// Removes genre-distant candidates BEFORE the enrichment timeout race.
    /// This is the critical fix: the genre gate used to live inside runPrefetchEnrichment
    /// which is inside the 10s timeout. When the timeout fired, unfiltered candidates
    /// (K-pop, distant genres) sailed through. Now the gate runs first, independently,
    /// with its own 6s timeout. If Last.fm is slow the gate fails open (returns all),
    /// which is safer than blocking forever.
    private func applyGenreGate(candidates: [SimilarSong], genres: [Genre]) async -> [SimilarSong] {
        guard !genres.isEmpty, !candidates.isEmpty else { return candidates }

        return await withTaskGroup(of: [SimilarSong].self) { outer in
            outer.addTask {
                let adjacentQuota = GenreQuotaTracker(limit: 10)
                let decisions: [(Int, Bool)] = await withTaskGroup(of: (Int, Bool).self) { inner in
                    for (index, song) in candidates.enumerated() {
                        inner.addTask {
                            if index > 0 {
                                try? await Task.sleep(nanoseconds: UInt64(min(index, 15)) * 20_000_000)
                            }
                            async let trackTagsTask  = self.lastFMService.fetchRawTags(title: song.title, artist: song.artist)
                            async let artistTagsTask = self.lastFMService.fetchArtistRawTags(artist: song.artist)
                            let trackTags  = await trackTagsTask
                            let artistTags = await artistTagsTask
                            let trackTagSet = Set(trackTags)
                            let extraArtist = artistTags.filter { !trackTagSet.contains($0) }.prefix(5)
                            let tags = trackTags + Array(extraArtist)
                            guard let targetGenre = await self.genresFromRawTags(tags).first else {
                                return (index, true) // no tags → let through
                            }
                            let penalty = self.genrePenalty(sourceGenres: genres, targetGenre: targetGenre)
                            if penalty >= 0.18 {
                                simiLog("🚫 GenreGate: excluded \"\(song.title)\" (\(targetGenre.main), penalty \(String(format: "%.2f", penalty)))")
                                return (index, false)
                            }
                            if penalty > 0 {
                                let allowed = await adjacentQuota.claim()
                                if !allowed {
                                    simiLog("🚫 GenreGate adjacent quota: excluded \"\(song.title)\"")
                                    return (index, false)
                                }
                            }
                            return (index, true)
                        }
                    }
                    var out: [(Int, Bool)] = []
                    for await d in inner { out.append(d) }
                    return out
                }
                let allowed = Set(decisions.compactMap { $0.1 ? $0.0 : nil })
                let result = candidates.enumerated().compactMap { allowed.contains($0.offset) ? $0.element : nil }
                simiLog("🎯 GenreGate: \(result.count)/\(candidates.count) passed genre check")

                // ── Floor pass 1: full misclassification ────────────────────────────
                // If all candidates are excluded, the source genre is almost certainly wrong.
                // Return the unfiltered pool rather than a blank screen.
                if result.isEmpty {
                    simiLog("⚠️ GenreGate: all candidates excluded — source genre likely misclassified, falling back to unfiltered pool")
                    return candidates
                }

                // ── Floor pass 2: thin-pool relaxation ──────────────────────────────
                // Fewer than 5 results after the full gate usually means a niche source
                // genre where the pool has few cultural matches (e.g. amapiano, bolero).
                // Re-admit adjacent-family candidates that were blocked only by the quota
                // cap, without lifting the hard distant-family exclusion.
                if result.count < 5 {
                    let relaxedQuota = GenreQuotaTracker(limit: candidates.count) // uncapped
                    let relaxedDecisions: [(Int, Bool)] = await withTaskGroup(of: (Int, Bool).self) { inner in
                        for (index, song) in candidates.enumerated() {
                            guard !allowed.contains(index) else {
                                // Already passed — keep as-is, don't re-fetch tags.
                                inner.addTask { (index, true) }
                                continue
                            }
                            inner.addTask {
                                async let tt = self.lastFMService.fetchRawTags(title: song.title, artist: song.artist)
                                async let at = self.lastFMService.fetchArtistRawTags(artist: song.artist)
                                let tTags = await tt; let aTags = await at
                                let tags = tTags + aTags.filter { !Set(tTags).contains($0) }.prefix(5)
                                guard let tg = await self.genresFromRawTags(tags).first else { return (index, true) }
                                let p = self.genrePenalty(sourceGenres: genres, targetGenre: tg)
                                if p >= 0.18 { return (index, false) }          // still hard-exclude distant
                                let ok = await relaxedQuota.claim()
                                return (index, ok)
                            }
                        }
                        var out: [(Int, Bool)] = []
                        for await d in inner { out.append(d) }
                        return out
                    }
                    let relaxedAllowed = Set(relaxedDecisions.compactMap { $0.1 ? $0.0 : nil })
                    let relaxed = candidates.enumerated().compactMap { relaxedAllowed.contains($0.offset) ? $0.element : nil }
                    if relaxed.count > result.count {
                        simiLog("⚠️ GenreGate thin-pool: relaxed adjacent quota, \(result.count) → \(relaxed.count) candidates")
                        return relaxed
                    }
                }

                return result
            }
            // Fail open: if Last.fm is unreachable, return all candidates rather than block.
            outer.addTask {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                simiLog("⚠️ GenreGate timed out — passing all \(candidates.count) candidates unfiltered")
                return candidates
            }
            let result = await outer.next()!
            outer.cancelAll()
            return result
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Pre-render Enrichment
    // ──────────────────────────────────────────────

    /// Enriches all candidates with Supabase cache + Last.fm tag estimation before first render.
    /// Runs as two racing tasks: the enrichment work vs. a 7-second timeout.
    /// Whichever finishes first wins — skeletons never persist past 7s.
    private func prefetchCandidateFeatures(
        candidates: [SimilarSong],
        sourceFeatures: AudioFeatures,
        genres: [Genre],
        seedFeatures: [AudioFeatures] = [],
        prewarmedCache: [String: AudioFeatures] = [:],
        sourceArtist: String = ""
    ) async -> [SimilarSong] {
        guard !candidates.isEmpty else { return candidates }

        // Race: enrichment vs. 10s timeout. Returns unenriched candidates on timeout.
        // 10s gives AcousticBrainz time to respond for pools of 40-50 songs in parallel.
        return await withTaskGroup(of: [SimilarSong].self) { group in
            // Task A: do the actual enrichment
            group.addTask {
                await self.runPrefetchEnrichment(
                    candidates: candidates,
                    sourceFeatures: sourceFeatures,
                    genres: genres,
                    seedFeatures: seedFeatures,
                    prewarmedCache: prewarmedCache,
                    sourceArtist: sourceArtist
                )
            }
            // Task B: 16-second timeout fallback.
            // FreqBlog is 8s per call; with stagger (max 300ms) + API latency variance,
            // 10s was firing before most candidates got FreqBlog data. 16s gives headroom.
            group.addTask {
                try? await Task.sleep(nanoseconds: 16_000_000_000)
                simiLog("⚠️ prefetchCandidateFeatures timed out — revealing with best-effort features")
                return candidates
            }
            // First to finish wins; cancel the other
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func runPrefetchEnrichment(
        candidates: [SimilarSong],
        sourceFeatures: AudioFeatures,
        genres: [Genre],
        seedFeatures: [AudioFeatures],
        prewarmedCache: [String: AudioFeatures] = [:],
        sourceArtist: String = ""
    ) async -> [SimilarSong] {
        var result = candidates

        // Collect (index, features) for all candidates in parallel.
        // Priority 0: prewarmed cache (populated by earlyLookupTask during candidate fetch phase).
        // Priority 1: Supabase cache (instant, no rate-limit concern).
        // Priority 2: Last.fm tag estimation for cache misses (staggered 20ms, capped at index 15).
        let fetched: [(Int, AudioFeatures?)] = await withTaskGroup(of: (Int, AudioFeatures?).self) { group in
            for (index, song) in candidates.enumerated() {
                group.addTask {
                    let cacheKey = "\(song.title)|\(song.artist)".lowercased()
                    if let prewarmed = prewarmedCache[cacheKey] {
                        return (index, prewarmed)
                    }
                    if let cached = await self.supabase.lookupFeatures(title: song.title, artist: song.artist) {
                        return (index, cached)
                    }
                    // Stagger: indices 0–15 get 20ms delay each (max 300ms).
                    // Indices 16+ fire immediately — they don't wait longer.
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(min(index, 15)) * 20_000_000)
                    }
                    // FreqBlog and Last.fm tags run concurrently — FreqBlog gives real
                    // valence/BPM/key/danceability measured from the actual audio preview.
                    // Tag estimation fills in energy/acousticness (FreqBlog doesn't measure
                    // these reliably from 30s clips). The overlay replaces the generic genre
                    // centroid with track-specific feel data — the core of the sound/feel engine.
                    async let fbFetch  = self.freqBlogService.fetchFeatures(title: song.title, artist: song.artist)
                    let tags           = await self.lastFMService.fetchRawTags(title: song.title, artist: song.artist)
                    var features       = await self.estimateFeaturesFromTags(tags)
                    if let fb = await fbFetch {
                        features?.valence        = fb.valence
                        features?.danceability   = fb.danceability
                        features?.bpm            = fb.bpm
                        features?.key            = fb.key
                        features?.mode           = fb.mode
                        features?.isKeyEstimated = false
                        simiLog("🎵 FreqBlog candidate: \(song.title) — v=\(String(format:"%.2f",fb.valence)) d=\(String(format:"%.2f",fb.danceability)) bpm=\(Int(fb.bpm))")
                    } else {
                        // No iTunes preview → FreqBlog can't analyze. Try AcousticBrainz
                        // frozen dump (7.5M tracks keyed by MBID) for real BPM/key/mode/energy.
                        // Underground mood-artist chain tracks are the primary beneficiaries —
                        // they're the most likely to lack previews but exist in MusicBrainz.
                        if let mbid = await self.listenBrainzService.resolveACRMBID(title: song.title, artist: song.artist),
                           let ab   = await self.acousticBrainzService.fetchFeatures(mbid: mbid) {
                            features?.bpm          = ab.bpm
                            features?.key          = ab.key
                            features?.mode         = ab.mode
                            features?.energy       = ab.energy
                            features?.danceability = ab.danceability
                            features?.isKeyEstimated = false
                            simiLog("📀 AcousticBrainz candidate: \(song.title) — \(Int(ab.bpm))BPM k:\(ab.key) m:\(ab.mode) e:\(String(format:"%.2f",ab.energy))")
                        }
                    }
                    return (index, features)
                }
            }
            var updates: [(Int, AudioFeatures?)] = []
            for await update in group { updates.append(update) }
            return updates
        }

        let explanationSource = seedFeatures.count > 1 ? centroid(of: seedFeatures) : sourceFeatures

        for (idx, features) in fetched {
            guard let features, idx < result.count else { continue }
            let (rawScore, reasons) = seedFeatures.count > 1
                ? computeSimilarityMultiSeed(seeds: seedFeatures, target: features, genres: genres)
                : computeSimilarity(source: sourceFeatures, target: features, genres: genres)
            // Tag-estimated features are synthetic (genre → BPM/energy table lookup).
            // They can produce false-positive similarity when a track is mis-tagged (e.g. K-pop
            // tagged as "trap" → estimates Kanye-like features → scores 0.88 against Flashing Lights).
            // Cap estimated scores so they can never beat a song with real measured data.
            let score = features.isEstimated ? min(rawScore, 0.68) : rawScore
            result[idx].audioFeatures    = features
            result[idx].similarityScore  = score
            result[idx].matchReasons     = reasons
            result[idx].matchExplanation = buildMatchExplanation(
                source: explanationSource,
                target: features,
                sourceGenres: genres,
                targetGenre: result[idx].genre
            )
        }

        let sorted = result.sorted { $0.similarityScore > $1.similarityScore }
        return applyArtistDiversity(sorted, sourceArtist: sourceArtist)
    }

    // ──────────────────────────────────────────────
    // MARK: - Artist Diversity
    // ──────────────────────────────────────────────

    /// Re-ranks a sorted results list so no single artist dominates the top.
    /// Rules:
    ///   - Source artist: max 2 songs (they're the most "identical" match, one or two is fine)
    ///   - Any other artist: max 3 songs in the top section
    ///   - Overflow songs are appended at the end in original score order
    /// Score order within each artist group is preserved, so the best overall
    /// match still appears first — we only push excess same-artist songs down.
    private func applyArtistDiversity(_ songs: [SimilarSong], sourceArtist: String) -> [SimilarSong] {
        let sourceKey = sourceArtist.lowercased().trimmingCharacters(in: .whitespaces)
        var artistCount: [String: Int] = [:]
        var primary:  [SimilarSong] = []
        var overflow: [SimilarSong] = []

        for song in songs {
            let key   = song.artist.lowercased().trimmingCharacters(in: .whitespaces)
            // Source artist gets 3 slots — their own catalog IS the closest match.
            // Every other artist gets 1 slot to keep the list varied.
            let limit = (!sourceKey.isEmpty && key == sourceKey) ? 3 : 1
            let count = artistCount[key, default: 0]
            if count < limit {
                artistCount[key] = count + 1
                primary.append(song)
            } else {
                overflow.append(song)
            }
        }
        return primary + overflow
    }

    // ──────────────────────────────────────────────
    // MARK: - Genre Family Detection
    // ──────────────────────────────────────────────

    private enum GenreFamily: Equatable {
        case metal, rock, blues, hiphop, rnb, pop, electronic, folk, jazz, classical, latin, unknown

        var displayName: String {
            switch self {
            case .metal:      return "Metal"
            case .rock:       return "Rock"
            case .blues:      return "Blues"
            case .hiphop:     return "Hip-Hop"
            case .rnb:        return "R&B"
            case .pop:        return "Pop"
            case .electronic: return "Electronic"
            case .folk:       return "Folk"
            case .jazz:       return "Jazz"
            case .classical:  return "Classical"
            case .latin:      return "Latin"
            case .unknown:    return ""
            }
        }
    }

    private func detectGenreFamily(_ genres: [Genre]) -> GenreFamily {
        // Single source of truth: delegate to genreFamily() which owns the family mapping
        // for penalty calculation. detectGenreFamily is only used for the UI badge — using
        // the same logic prevents the two systems from diverging when new genres are added.
        // Blues is a special case: genreFamily() maps it to "jazz" (penalty-equivalent), but
        // the UI badge distinguishes it, so we check blues first before delegating.
        let names = genres.map { $0.main.lowercased() }
        if names.contains(where: { $0.contains("blues") }) { return .blues }
        switch genreFamily(genres.first?.main ?? "") {
        case "metal":       return .metal
        case "rock":        return .rock
        case "hiphop":      return .hiphop
        case "rnb":         return .rnb
        case "pop":         return .pop
        case "electronic":  return .electronic
        case "folk":        return .folk
        case "jazz":        return .jazz
        case "classical":   return .classical
        case "latin":       return .latin
        default:            return .unknown
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Similarity Score Computation
    // ──────────────────────────────────────────────

    // Scoring philosophy: match the *emotional imprint* of a song, not its technical fingerprint.
    // People don't want the same BPM — they want the same feeling.
    //
    // Weights (sum = 1.00):
    //   valence        0.28 — emotional color; prefers valenceEssentia (DEAM) over Spotify proxy
    //   arousal        0.15 — calm/relaxed vs. excited/tense (DEAM y-axis; maps to circumplex quadrant)
    //   danceability   0.17 — groove/rhythm feel (slow jam vs. dance track within the same mood)
    //   energy         0.15 — intensity of the feeling (mellow bedroom vs. mosh pit)
    //   mode           0.09 — major/minor emotional signature; neutral when key is estimated
    //   mfccCosine     0.08 — timbral texture similarity via MFCC cosine (when available)
    //   acousticness   0.05 — sonic warmth texture (acoustic vs. electronic)
    //   chromaEntropy  0.02 — tonal complexity (simple/resolved vs chromatic/tense)
    //   tonalClarity   0.01 — harmonic focus (melody-driven vs. beat-driven)
    //   bpm            0.00 — disabled: subsumed by arousal + danceability
    //   spectralWarmth 0.00 — disabled pending sub-bass RMS fix (stored, contributes nothing)
    //   vocalPresence  0.00 — disabled: 808 in y_harmonic inverts expected ordering (stored)
    //   reverbSpace    0.00 — disabled: HF noise floor in trap inverts expected ordering (stored)
    //
    // New signals:
    //   arousal (DEAM): captures "how activated/calm" independently of loudness. A soft-but-intense
    //     string quartet scores high arousal / low energy — a distinction librosa energy alone misses.
    //   mfccCosine: captures timbral "feel" (warmth, breathiness, roughness) beyond valence/energy.
    //     Cosine similarity on 20-coeff MFCC mean vectors; only applied when both songs have MFCC data.
    //   chromaEntropy: tonal complexity. High = chromatic/jazzy/unresolved; low = clear diatonic melody.
    //     Prevents matching a simple pop hook to a jazz standard on valence alone.
    //
    // Danceability still carries weight because it separates slow jams from club tracks even
    // when both have warm valence — the critical failure mode within warm-valence genres like R&B.
    // BPM tolerance widened to ±60 so songs at very different tempos can match on emotional feel.

    // Counts adjacent-genre candidates as they claim slots in the enrichment pool.
    // Swift actor makes the counter safe across the concurrent task group without locks.
    private actor GenreQuotaTracker {
        private var adjacentCount = 0
        private let limit: Int
        init(limit: Int) { self.limit = limit }
        /// Attempts to claim one adjacent-genre slot. Returns true (allow) or false (quota full).
        func claim() -> Bool {
            guard adjacentCount < limit else { return false }
            adjacentCount += 1
            return true
        }
    }

    // Maps a genre name to a broad family bucket used for cross-genre penalty.
    nonisolated private func genreFamily(_ genreName: String) -> String {
        let g = genreName.lowercased()
        // Hybrid genres — must be checked before the hip-hop and rock sweeps.
        if g.contains("rap rock") || g.contains("raprock") || g.contains("punk rap") { return "raprock" }
        // Pop sub-genres that share "rock" or "punk" vocabulary but live in the pop world, not the rock world.
        // "pop punk" = Olivia Rodrigo, Paramore; "pop rock" = Bruno Mars, Maroon 5 — pop-adjacent, not rock-adjacent.
        if g == "pop punk" || g.contains("pop punk") || g == "pop rock" || g.contains("pop rock") || g == "power pop" { return "pop" }
        // "trap pop" / "pop trap" = Ariana Grande "7 rings" style — trap production under pop vocals.
        // Must be caught before the bare "trap" sweep or it resolves as hiphop.
        if g.contains("trap pop") || g.contains("pop trap") || g.contains("electropop") || g.contains("synth pop") { return "pop" }
        if g.contains("hip") || g.contains("hop") || g.contains("rap") || g.contains("trap") || g.contains("drill") || g.contains("grime") { return "hiphop" }
        if g.contains("r&b") || g.contains("rnb") || g.contains("soul") || g.contains("funk") || g.contains("slow jam") { return "rnb" }
        // Latin must be checked before "alternative" — "Latin Alternative" (iLe, Natalia Lafourcade) is
        // a Latin subgenre that contains the word "alternative"; catching it after the rock sweep would
        // misclassify the source as "rock" and hard-exclude all Latin candidates via GenreGate.
        if g.contains("latin") || g.contains("reggaeton") || g.contains("salsa") || g.contains("cumbia") || g.contains("bossa nova") || g.contains("samba") || g.contains("merengue") || g.contains("bachata") || g.contains("bolero") || g.contains("nueva cancion") || g.contains("nueva canción") { return "latin" }
        if g.contains("rock") || g.contains("indie") || g.contains("alternative") || g.contains("punk") || g.contains("grunge") || g.contains("shoegaze") || g.contains("emo") { return "rock" }
        if g.contains("metal") || g.contains("hardcore") || g.contains("screamo") { return "metal" }
        if g.contains("electronic") || g.contains("edm") || g.contains("house") || g.contains("techno") || g.contains("ambient") || g.contains("dubstep") || g.contains("trance") { return "electronic" }
        if g.contains("jazz") || g.contains("blues") { return "jazz" }
        if g.contains("classical") || g.contains("orchestral") || g.contains("opera") { return "classical" }
        if g.contains("country") || g.contains("folk") || g.contains("bluegrass") || g.contains("americana") { return "country" }
        if g.contains("pop") { return "pop" }
        return "other"
    }

    // Cross-genre penalty: 0 for same/adjacent families, 0.18 for distant ones.
    // Applied after all feature scoring so it can push an audio-similar cross-genre
    // candidate below a slightly-lower-scoring same-genre candidate.
    nonisolated private func genrePenalty(sourceGenres: [Genre], targetGenre: Genre) -> Double {
        let targetFamily = genreFamily(targetGenre.main)
        guard targetFamily != "other" && targetFamily != "unknown" else { return 0 }
        let sourceFamilies = Set(sourceGenres.map { genreFamily($0.main) })
        guard !sourceFamilies.contains("other") else { return 0 }
        if sourceFamilies.contains(targetFamily) { return 0 }
        // raprock is a hip-hop/rock hybrid. It's adjacent to both parent families (0.12),
        // but hard-excluded from pop and R&B (0.20 ≥ 0.18 threshold → pool pre-filter removes them).
        // This is the fix for Olivia Rodrigo-style pop-punk songs scoring high on rap-rock source songs:
        // "get him back!" (pop-punk → pop family) gets 0.20 → hard excluded before scoring.
        if sourceFamilies.contains("raprock") || targetFamily == "raprock" {
            let other = sourceFamilies.contains("raprock") ? targetFamily : sourceFamilies.first ?? "other"
            switch other {
            case "hiphop", "rock", "metal": return 0.12
            case "pop", "rnb":              return 0.20  // hard-excluded (≥ 0.18 threshold)
            default:                         return 0.18
            }
        }
        // Pairs that are culturally/sonically adjacent — small friction only.
        // hiphop↔pop removed: pure pop (Nelly Furtado, Taylor Swift) is not adjacent to hip-hop.
        // Pop rap is a hip-hop subgenre and resolves to "hiphop" family already, so no penalty is applied.
        // hiphop↔rnb: requires penalty > 0.21 to filter Doja Cat / SZA songs that
        // score ~86% raw acoustic similarity to Drake (shared BPM, energy, danceability).
        // 0.22 ensures cross-genre R&B is cut at Stage 1 (64% < 0.65 threshold).
        // Trade-off: Drake R&B tracks (Shut It Down, ~80% raw → 58%) also filter,
        // but the top-of-list experience is fully hip-hop, which is what we want.
        if sourceFamilies.contains("hiphop") && targetFamily == "rnb" { return 0.22 }
        if sourceFamilies.contains("rnb") && targetFamily == "hiphop" { return 0.22 }
        let adjacent: Set<Set<String>> = [
            ["rnb", "pop"],
            ["pop", "electronic"], ["rock", "metal"], ["rock", "pop"],
            ["country", "folk"],
            // Latin crosses many families — Latin pop, Latin R&B, bossa nova (jazz), cumbia (folk).
            // Adjacent (not same) so it's a soft preference, not a free pass.
            ["latin", "pop"], ["latin", "rnb"], ["latin", "folk"], ["latin", "jazz"],
            // Electro-cumbia, Latin trap, and reggaeton all blend Latin and electronic production.
            // Adjacent pair prevents Latin candidates from being hard-excluded when the source
            // genre is misread as "electronic" (e.g. iLe's "Tu Rumba" with synth production).
            ["latin", "electronic"],
        ]
        for family in sourceFamilies {
            if adjacent.contains([family, targetFamily]) { return 0.12 }
        }
        return 0.18  // distant families: indie rock ≠ trap, classical ≠ hip-hop, etc.
    }

    private func computeSimilarity(
        source: AudioFeatures,
        target: AudioFeatures?,
        genres: [Genre],
        targetGenre: Genre? = nil
    ) -> (Double, [MatchReason]) {
        guard let target = target else {
            return (0.5, [.genre])
        }

        var totalScore = 0.0
        var reasons: [MatchReason] = []

        // When BOTH source and target features are estimated from genre tags,
        // the raw diff will be ~0 (same tag map → same estimated values), making
        // diff-based reasons meaningless AND misleading (e.g. "Dark Mood" on a
        // song that's clearly upbeat because both had 0.66 valence from "r&b" tag).
        //
        // Instead: describe the source's absolute vibe using its real tag labels,
        // but only use a directional mood label when the valence is clearly one-sided.
        // Ambiguous / mid-range valence → generic "Similar Vibe" to avoid false labels.
        let bothEstimated = source.isEstimated && (target.isEstimated)
        if bothEstimated {
            // Energy label — reliable because tag energy ranges are wide.
            // Even in the estimated path we can distinguish archetype from the source's danceability.
            if source.energy > 0.70 {
                if source.danceability < 0.65 {
                    reasons.append(.anthemic)       // soaring/epic — low dance even if high energy
                } else if source.danceability > 0.72 {
                    reasons.append(.danceFloor)     // built to move — high energy + high dance
                } else {
                    reasons.append(.highIntensity)  // mixed — honest generic label
                }
            } else if source.energy < 0.40 {
                reasons.append(.mellowMatch)
            } else {
                reasons.append(.energy)
            }
            // Mood label — use circumplex quadrant when source has DEAM arousal,
            // otherwise fall back to valence-only directional labels.
            let srcValenceForLabel = source.valenceEssentia ?? source.valence
            if let srcArousal = source.arousal {
                // Russell's circumplex: valence (x) × arousal (y) → 4 emotionally specific labels
                if srcValenceForLabel >= 0.55 && srcArousal >= 0.55 {
                    reasons.append(.euphoric)
                } else if srcValenceForLabel >= 0.55 && srcArousal < 0.45 {
                    reasons.append(.serene)
                } else if srcValenceForLabel < 0.45 && srcArousal >= 0.55 {
                    reasons.append(.tense)
                } else if srcValenceForLabel < 0.45 && srcArousal < 0.45 {
                    reasons.append(.melancholic)
                } else {
                    reasons.append(.mood)       // Mid-quadrant — not clearly assignable
                }
            } else {
                // No DEAM arousal — fall back to valence-only labels.
                // Mid-range R&B/hip-hop estimates sit around 0.50–0.68; labelling that
                // range "Dark Mood" is wrong for upbeat songs. Use a neutral label instead.
                if srcValenceForLabel < 0.42 {
                    reasons.append(.darkMood)   // Genuinely dark: metal, emo, sad rap
                } else if srcValenceForLabel > 0.72 && source.energy > 0.50 {
                    reasons.append(.upbeatMood) // Genuinely bright AND energetic: pop, dance, k-pop
                } else {
                    reasons.append(.mood)       // Warm, mellow, or mid-range: "Same Mood"
                }
            }
        }

        // Valence — the emotional color (happy / dark / bittersweet).
        // Use DEAM only when BOTH songs have it. Mixing DEAM source (e.g. Python-analyzed)
        // with SonicDNA-proxy target collapses all candidates to an equal valence distance,
        // killing discrimination and elevating wrong matches like "family ties ≈ Peso".
        let srcValence: Double
        let tgtValence: Double
        let hasDeamValence: Bool
        if let sv = source.valenceEssentia, let tv = target.valenceEssentia {
            (srcValence, tgtValence) = (sv, tv)
            hasDeamValence = true
        } else {
            (srcValence, tgtValence) = (source.valence, target.valence)
            hasDeamValence = false
        }
        let valenceDiff = abs(srcValence - tgtValence)
        let valenceScore = 1.0 - valenceDiff
        // Without DEAM valenceEssentia, audio-only proxy is structurally weaker.
        // Reduce weight by 0.10 and redistribute to danceability (see danceWeight below).
        let valenceWeight = hasDeamValence ? 0.28 : 0.18
        totalScore += valenceScore * valenceWeight
        // Tighter threshold when source is measured but target is tag-estimated:
        // soul-genre centroids cluster close enough that a 0.15 gate produces false "Same Mood"
        // labels between emotionally opposite songs (e.g. Tar Baby vs Respect).
        let moodThreshold = (!source.isEstimated && target.isEstimated) ? 0.10 : 0.15
        if !bothEstimated && valenceDiff < moodThreshold {
            let avgValence = (srcValence + tgtValence) / 2
            let avgEnergy  = (source.energy + target.energy) / 2
            // Prefer circumplex quadrant labels when both songs have DEAM arousal.
            // Falls back to valence-only labels when arousal is unavailable.
            if let srcArousal = source.arousal, let tgtArousal = target.arousal {
                let avgArousal = (srcArousal + tgtArousal) / 2
                if avgValence >= 0.55 && avgArousal >= 0.55 {
                    reasons.append(.euphoric)      // happy + activated
                } else if avgValence >= 0.55 && avgArousal < 0.45 {
                    reasons.append(.serene)        // happy + calm
                } else if avgValence < 0.45 && avgArousal >= 0.55 {
                    reasons.append(.tense)         // dark + activated
                } else if avgValence < 0.45 && avgArousal < 0.45 {
                    reasons.append(.melancholic)   // dark + calm
                } else {
                    reasons.append(.mood)          // mid-quadrant
                }
            } else {
                // Valence-only fallback — no DEAM arousal available.
                if avgValence < 0.40 {
                    reasons.append(.darkMood)      // Both dark/heavy — defiant, bleak, raw
                } else if avgValence > 0.72 && avgEnergy > 0.50 {
                    // "Upbeat" requires both brightness AND energy — bedroom R&B can be
                    // emotionally positive but sonically laid-back; that's "Same Mood", not "Upbeat".
                    reasons.append(.upbeatMood)    // Both bright AND energetic
                } else {
                    reasons.append(.mood)          // Warm, mellow, or mid-range emotional match
                }
            }
        }

        // Arousal — calm/relaxed vs energetic/excited (DEAM regression).
        // Distinct from energy: a tense quiet string quartet is high arousal / low energy.
        // Only applied when both songs have Essentia arousal; falls through silently otherwise.
        if let srcArousal = source.arousal, let tgtArousal = target.arousal {
            let arousalDiff = abs(srcArousal - tgtArousal)
            totalScore += (1.0 - arousalDiff) * 0.15
        }

        // Energy — the intensity of the feeling (mosh-pit vs. bedroom).
        // Restrained sources (energy < 0.45) need energy matching more strictly — the whole
        // point of a quiet song is that it's quiet. Danceability gives up weight to compensate.
        let energyWeight = source.energy < 0.45 ? 0.25 : 0.15
        let energyDiff = abs(source.energy - target.energy)
        let energyScore = 1.0 - energyDiff
        totalScore += energyScore * energyWeight
        if !bothEstimated && energyDiff < 0.15 {
            let avgEnergy = (source.energy + target.energy) / 2
            if avgEnergy > 0.65 {
                // Distinguish anthemic (soaring, low danceability) from dance-floor (built to move).
                // Both are "high intensity" but feel emotionally different.
                let srcLowDance = source.danceability < 0.65
                let tgtLowDance = target.danceability < 0.65
                let srcHighDance = source.danceability > 0.72
                let tgtHighDance = target.danceability > 0.72
                if srcLowDance && tgtLowDance {
                    reasons.append(.anthemic)    // Both epic/soaring — Purple Rain, Bohemian Rhapsody
                } else if srcHighDance && tgtHighDance {
                    reasons.append(.danceFloor)  // Both built to move — Beat It, Get Lucky
                } else {
                    reasons.append(.highIntensity) // Mixed — honest generic label
                }
            } else if avgEnergy < 0.45 {
                reasons.append(.mellowMatch)
            } else {
                reasons.append(.energy)
            }
        }

        // Danceability — introspective slow jam vs. built-to-move club track.
        // Discriminates within warm-valence genres (R&B, soul) where valence alone can't
        // separate a slow jam from a club banger. Weight reduced for restrained sources
        // since energy already carries the primary discrimination signal there.
        // Absorb the 0.10 freed from valence when DEAM is absent — danceability
        // is a reliable audio-only signal (beat regularity + BPM fit + energy).
        let danceBaseWeight = source.energy < 0.45 ? 0.07 : 0.17
        let danceWeight = hasDeamValence ? danceBaseWeight : danceBaseWeight + 0.10
        let danceDiff = abs(source.danceability - target.danceability)
        let danceScore = 1.0 - danceDiff
        totalScore += danceScore * danceWeight

        // Cross-archetype penalty (a): measured high-energy songs with diverging danceability.
        // Soaring anthems (Purple Rain) and dance tracks (Beat It) share intensity but not shape.
        if !bothEstimated && source.energy > 0.60 && target.energy > 0.60 && danceDiff > 0.25 {
            totalScore = max(0, totalScore - 0.05)
        }
        // Cross-archetype penalty (b): slow-jam source vs. club/dance-heavy target.
        // Fires even with estimated features — warm valence doesn't distinguish "Let Me Love You"
        // from "Family Affair" without this. The danceability buckets do.
        if danceDiff > 0.12 && source.danceability < 0.60 && target.danceability > 0.65 {
            totalScore = max(0, totalScore - 0.06)
        }
        // Cross-archetype penalty: upward energy gap.
        // When a recommended song has significantly more energy than the source, it's pulling
        // in a different emotional direction. e.g. HUMBLE. (aggressive, 0.66 energy) shouldn't
        // rank equally to cloud-rap (atmospheric, 0.59) when the source is mid-energy (0.50).
        // Floor: skip when source.energy < 0.30. Below 0.30 (ambient, drone, extreme darkwave)
        // the source is an outlier even within its genre — penalising every normal-energy track
        // produces false negatives. Sources in the 0.30–0.45 restrained zone (Tar Baby, After Dark)
        // should still penalise overtly energetic candidates.
        // Threshold raised from 0.14 → 0.20: disco centroid (0.78) was getting penalized vs sources
        // at 0.61 (gap 0.17 < 0.20), causing soul/motown to outscore disco for Don't Stop.
        // Magnolia (0.86) vs Peso (0.59) still gets gap=0.27 → 0.14 penalty (slightly softer than before).
        if source.energy >= 0.30 {
            let energyGap = target.energy - source.energy
            if energyGap > 0.20 {
                let gapPenalty = min(0.16, (energyGap - 0.20) * 2.0)
                totalScore = max(0, totalScore - gapPenalty)
            }
        }

        // BPM reason tag — "Same Tempo" badge when BPM is very close (direct or octave match).
        // The mismatch penalty lives below, applied post-normalization.
        let bpmDirectDiff = abs(source.bpm - target.bpm)
        let bpmOctaveDiff = source.bpm > 0 && target.bpm > 0
            ? min(abs(source.bpm - target.bpm * 2.0), abs(source.bpm - target.bpm / 2.0))
            : Double.infinity
        if bpmDirectDiff <= 15 || bpmOctaveDiff <= 8 { reasons.append(.bpm) }

        // MFCC cosine similarity — timbral texture (warmth, breathiness, roughness, instrument blend).
        // Captures acoustic "feel" that valence/energy don't express.
        // Only applied when both songs have MFCC data from HF backend.
        if let srcMFCC = source.mfccMean, let tgtMFCC = target.mfccMean,
           srcMFCC.count == tgtMFCC.count, !srcMFCC.isEmpty {
            let cosine = mfccCosineSimilarity(srcMFCC, tgtMFCC)  // [-1, 1]
            let mfccScore = (cosine + 1.0) / 2.0                 // → [0, 1]
            totalScore += mfccScore * 0.08
        }

        // MFCC std cosine — timbral consistency (uniform vs. dynamic texture).
        // Dense 808 trap loops: low std per-bin. Live drums + room: high std.
        // Separates "same timbre family" songs that differ in texture variability.
        if let srcStd = source.mfccStd, let tgtStd = target.mfccStd,
           srcStd.count == tgtStd.count, !srcStd.isEmpty {
            let cosine = mfccCosineSimilarity(srcStd, tgtStd)
            totalScore += ((cosine + 1.0) / 2.0) * 0.04
        }

        // Chroma entropy — tonal complexity / harmonic tension.
        // High entropy: jazz, modal, chromatic (complex, unresolved).
        // Low entropy: pop, folk, diatonic (clear, resolved).
        // Prevents matching a simple pop hook to a jazz standard on valence alone.
        if let srcEntropy = source.chromaEntropy, let tgtEntropy = target.chromaEntropy {
            let maxEntropy = 3.0   // practical ceiling for music
            let entropyScore = max(0, 1.0 - abs(srcEntropy - tgtEntropy) / maxEntropy)
            totalScore += entropyScore * 0.02
        }

        // Acousticness — sonic texture (acoustic warmth vs. electronic brightness).
        let acousticScore = 1.0 - abs(source.acousticness - target.acousticness)
        totalScore += acousticScore * 0.05
        if abs(source.acousticness - target.acousticness) < 0.2 { reasons.append(.acoustics) }

        // Instrumentalness — vocal vs. instrumental separation.
        // Only scored when both songs have SonicDNA-measured features; tag-estimated songs
        // carry a neutral 0.5 which would produce false high scores against any measured value.
        let estimatedPair = source.isEstimated || target.isEstimated
        if !estimatedPair {
            let instrScore = 1.0 - abs(source.instrumentalness - target.instrumentalness)
            totalScore += instrScore * 0.05

            // Liveness — studio vs. live recording. Only meaningful when both are measured;
            // tag-estimated songs all carry 0.1 default and would produce false perfect scores.
            let livenessScore = 1.0 - abs(source.liveness - target.liveness)
            totalScore += livenessScore * 0.04
        }

        // Mode — major/minor emotional signature. Major keys tend to feel brighter and more
        // resolved; minor keys darker and more tense. Only applied when both songs have
        // real key measurements (librosa or Spotify). Neutral 0.5 when mode is estimated.
        let modeScore: Double
        if !source.isKeyEstimated && !target.isKeyEstimated {
            modeScore = source.mode == target.mode ? 1.0 : 0.3
        } else {
            modeScore = 0.5
        }
        totalScore += modeScore * 0.09

        // Key harmony — circle-of-fifths compatibility. Keys adjacent on the circle share
        // the most harmonic content (e.g. C↔G, Am↔Dm). Only when both keys are measured.
        // CoF position map: C=0,G=1,D=2,A=3,E=4,B=5,F#=6,Db=7,Ab=8,Eb=9,Bb=10,F=11
        if !source.isKeyEstimated && !target.isKeyEstimated {
            let cofPositions = [0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5]
            let pos1 = cofPositions[source.key % 12]
            let pos2 = cofPositions[target.key % 12]
            let rawDist = abs(pos1 - pos2)
            let cofDist = min(rawDist, 12 - rawDist)  // 0–6
            let keyHarmonyScore: Double
            switch cofDist {
            case 0: keyHarmonyScore = 1.00
            case 1: keyHarmonyScore = 0.85  // dominant / subdominant — extremely compatible
            case 2: keyHarmonyScore = 0.65  // two steps — compatible
            case 3: keyHarmonyScore = 0.40  // distant
            case 4: keyHarmonyScore = 0.20  // very distant
            default: keyHarmonyScore = 0.00 // tritone — maximally dissonant
            }
            totalScore += keyHarmonyScore * 0.06
        }

        // Spectral warmth — disabled pending sub-bass RMS fix. Stored, contributes nothing.
        totalScore += (1.0 - abs(source.spectralWarmth - target.spectralWarmth)) * 0.00

        // Tonal clarity — harmonic focus (melody-driven trap vs. beat-driven trap).
        totalScore += (1.0 - abs(source.tonalClarity - target.tonalClarity)) * 0.01

        // Vocal presence — disabled (weight 0.00); stored, contributes nothing.
        // Calibration: 808 sine waves stay in y_harmonic, inverting expected ordering.
        totalScore += (1.0 - abs(source.vocalPresence - target.vocalPresence)) * 0.00

        // Reverb space — disabled (weight 0.00); stored, contributes nothing.
        // Calibration: HF noise floor in trap gives falsely high spectral flatness.
        totalScore += (1.0 - abs(source.reverbSpace - target.reverbSpace)) * 0.00

        // Normalize by used weight. When arousal, MFCC, and chroma entropy are
        // all unavailable (0.25 combined), raw scores are capped at ~0.75 even for a
        // perfect match. Dividing by the weight actually earned restores the full
        // 0–1 scale so songs that feel similar score like it.
        let missedWeight = (source.arousal == nil || target.arousal == nil           ? 0.15 : 0.0)
                         + (source.mfccMean == nil || target.mfccMean == nil       ? 0.08 : 0.0)
                         + (source.mfccStd  == nil || target.mfccStd  == nil       ? 0.04 : 0.0)
                         + (source.chromaEntropy == nil || target.chromaEntropy == nil ? 0.02 : 0.0)
                         + (estimatedPair                                          ? 0.09 : 0.0) // instrumentalness 0.05 + liveness 0.04
                         + (source.isKeyEstimated || target.isKeyEstimated         ? 0.06 : 0.0) // key harmony (CoF)
        let usedWeight = 1.0 - missedWeight
        if usedWeight > 0 && usedWeight < 1.0 {
            totalScore = min(1.0, totalScore / usedWeight)
        }

        // Genre family penalty — fires when we know the target's actual genre and it
        // belongs to a different sonic family from the source (e.g. indie rock vs trap).
        // Applied after feature scoring so it overrides audio similarities that are
        // coincidental rather than stylistic.
        if let tg = targetGenre, !genres.isEmpty {
            let penalty = genrePenalty(sourceGenres: genres, targetGenre: tg)
            if penalty > 0 {
                simiLog("🚫 Genre penalty \(String(format: "%.2f", penalty)): \(genres.first?.main ?? "?") → \(tg.main)")
                totalScore = max(0, totalScore - penalty)
            }
        }

        // BPM mismatch penalty — applied post-normalization so it isn't absorbed by the
        // 1.0 cap on already-high raw scores. The arousal proxy compresses all hip-hop into
        // 0.38–0.62 regardless of actual BPM, causing 69 BPM Afrobeats to score as
        // "Near-perfect" for 142 BPM cloud rap. Octave matches still incur +50 friction
        // because a perceptual half-time groove is a meaningful sonic difference.
        // Gated on !target.isEstimated: tag-estimated BPMs are genre centroids, not real
        // measurements — penalising a disco song at centroid 88 BPM vs 117 BPM source
        // would filter it out based on a made-up number. SonicDNA-measured BPMs only.
        if source.bpm > 0 && target.bpm > 0 && !target.isEstimated {
            let directDiff = abs(source.bpm - target.bpm)
            let octaveDiff = min(abs(source.bpm - target.bpm * 2.0),
                                 abs(source.bpm - target.bpm / 2.0))
            let effectiveDiff: Double
            if directDiff <= 25 {
                effectiveDiff = directDiff
            } else if octaveDiff <= 20 {
                effectiveDiff = octaveDiff + 50
            } else {
                effectiveDiff = min(directDiff, octaveDiff + 50)
            }
            if effectiveDiff > 25 {
                let bpmPenalty = min(0.22, (effectiveDiff - 25) / 250.0)
                simiLog("🥁 BPM penalty \(String(format: "%.3f", bpmPenalty)): \(Int(source.bpm))→\(Int(target.bpm)) BPM (eff diff \(Int(effectiveDiff)))")
                totalScore = max(0, totalScore - bpmPenalty)
            }
        }

        // Valence mismatch penalty for measured pairs — applied post-normalization.
        // The 0.28 linear weight isn't enough when BPM/energy/danceability align but
        // mood quadrants diverge (bright G Major cloud rap vs. dark D# Minor trap scores
        // near-perfect purely on tempo/groove match). Estimated pairs share genre centroids
        // so their valence already clusters within ±0.10 — no penalty needed there.
        if !source.isEstimated && !target.isEstimated {
            let vgap = abs(srcValence - tgtValence)
            if vgap > 0.12 {
                let valencePenalty = min(0.12, (vgap - 0.12) * 2.0)
                simiLog("🎭 Valence gap penalty \(String(format: "%.3f", valencePenalty)): src=\(String(format: "%.2f", srcValence)) tgt=\(String(format: "%.2f", tgtValence))")
                totalScore = max(0, totalScore - valencePenalty)
            }
        }

        // Confidence adjustment: tag-estimated features cluster near genre centroids,
        // so raw diff scores overstate precision (e.g. "trap" vs "trap" → 0.87 from
        // identical centroid values). Compress toward 0.65 proportional to how much
        // estimation was involved — preserves relative ordering, kills false perfects.
        // When the SOURCE is measured (false, true), there's genuine signal in the
        // comparison to the centroid — don't compress it; the normalization above already
        // accounts for incomplete target data.
        let adjustedScore: Double
        switch (source.isEstimated, target.isEstimated) {
        case (true, true):   adjustedScore = 0.65 + (totalScore - 0.65) * 0.50
        case (true, false):  adjustedScore = 0.65 + (totalScore - 0.65) * 0.75
        // Real source vs tag-estimated target: weight normalization inflates centroid
        // scores (arousal/MFCC/chromaEntropy always nil → usedWeight 0.80 → totalScore/0.80).
        // Compress 45% toward 0.65 so Stage 1 ranks these conservatively until Stage 2
        // can measure real features and replace these estimates.
        case (false, true):  adjustedScore = 0.65 + (totalScore - 0.65) * 0.55
        case (false, false): adjustedScore = totalScore
        }

        // For estimated features the first two slots are energy + mood — far more useful
        // than a generic "Same Genre" label. Only prepend genre for measured features.
        if !bothEstimated {
            reasons.insert(.genre, at: 0)
        }
        return (adjustedScore, Array(reasons.prefix(3)))
    }

    /// Soft era penalty for temporal mismatch. No penalty within 12 years; scales to 0.08 max.
    /// Keeps results temporally coherent without hard-filtering cross-era discoveries.
    private func eraPenalty(sourceYear: Int?, targetYear: Int?) -> Double {
        guard let src = sourceYear, let tgt = targetYear, src > 1950, tgt > 1950 else { return 0 }
        let gap = abs(src - tgt)
        guard gap > 12 else { return 0 }
        return min(0.08, Double(gap - 12) / 150.0)
    }

    /// Cosine similarity between two MFCC mean vectors. Returns [-1, 1].
    /// Uses Accelerate-style loop — no external deps, ~0.01ms for 20-dim vectors.
    private func mfccCosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, magA = 0.0, magB = 0.0
        for i in 0..<a.count {
            dot  += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }

    /// Scores a candidate against multiple seed songs and returns the average similarity.
    /// This is the right strategy for blended searches — a song that's 85% like seed 1
    /// and 80% like seed 2 (avg 82.5%) should rank above a song that's 95% like seed 1
    /// but 55% like seed 2 (avg 75%). The blend should serve both seeds, not just one.
    private func computeSimilarityMultiSeed(
        seeds: [AudioFeatures],
        target: AudioFeatures?,
        genres: [Genre],
        targetGenre: Genre? = nil
    ) -> (Double, [MatchReason]) {
        guard !seeds.isEmpty else { return (0.5, [.genre]) }
        guard seeds.count > 1 else {
            return computeSimilarity(source: seeds[0], target: target, genres: genres, targetGenre: targetGenre)
        }

        var totalScore = 0.0
        var reasonFrequency: [MatchReason: Int] = [:]

        for seed in seeds {
            let (score, reasons) = computeSimilarity(source: seed, target: target, genres: genres, targetGenre: targetGenre)
            totalScore += score
            for reason in reasons {
                reasonFrequency[reason, default: 0] += 1
            }
        }

        let avgScore = totalScore / Double(seeds.count)

        // Return reasons shared by at least half the seeds — these signal a truly common trait
        let threshold = max(1, (seeds.count + 1) / 2)
        let commonReasons = reasonFrequency
            .filter { $0.value >= threshold }
            .sorted { $0.value > $1.value } // most common first
            .map { $0.key }

        // Always include .genre as the baseline reason
        var finalReasons = Array(commonReasons.prefix(2))
        if !finalReasons.contains(.genre) { finalReasons.insert(.genre, at: 0) }

        return (avgScore, Array(finalReasons.prefix(3)))
    }

    // ──────────────────────────────────────────────
    // MARK: - Audio-Derived Emotional Query Tags
    // ──────────────────────────────────────────────

    /// Derives Last.fm query tags from a source song's MEASURED audio features.
    /// These describe the actual emotional feel (e.g. "late night", "melancholic")
    /// rather than genre labels (e.g. "trap"), so candidate discovery targets vibe
    /// rather than co-listening patterns.
    ///
    /// Generates compound tags by pairing mood tags with genre info (e.g. "late night neo soul"),
    /// targeting niche catalogs that bare mood tags miss.
    ///
    /// Only runs when features are real (isEstimated=false) — tag-estimated features
    /// default to energy 0.7/valence 0.48 for trap, which would always return "trap"
    /// candidates and defeat the purpose.
    private func deriveAudioQueryTags(from features: AudioFeatures, genreTags: [Genre] = [], rawTags: [String] = [], spotifyGenres: [String] = []) -> [String] {
        guard !features.isEstimated else { return [] }

        // Broad-umbrella set used in two places below:
        // (A) as a filter to identify specific Spotify genre labels
        // (B) as the guard deciding whether audio-feature routing should fire at all.
        //
        // These are top-level genre umbrellas that carry no subgenre information on their
        // own — every Spotify artist tagged "hip-hop" also gets more specific labels like
        // "new orleans rap" or "conscious hip hop". The umbrella terms alone are noise.
        let broadUmbrella: Set<String> = [
            // Root-level genre umbrellas
            "hip-hop", "hip hop", "rap", "pop", "rock", "alternative", "indie",
            "electronic", "edm", "r&b", "rnb", "soul", "metal", "punk", "jazz",
            "blues", "classical", "country", "folk", "acoustic", "funk", "gospel",
            "reggae", "reggaeton", "latin", "k-pop", "dancehall", "afrobeats", "afropop",
            "house", "techno", "trance", "ambient",
            // Era descriptors
            "80s", "90s", "2000s", "2010s", "70s", "60s", "50s",
            // Meta/descriptor tags
            "seen live", "favorites", "love", "female vocalist", "male vocalist",
            "british", "american",
        ]

        // ── Path A: Spotify artist genres (preferred) ──────────────────────────────
        //
        // Spotify's "Every Noise at Once" taxonomy covers thousands of micro-genre
        // labels ("new orleans rap", "vapor trap", "chamber pop", "dark clubbing")
        // maintained by genre experts at scale. These are far more reliable than
        // inferring subgenre from audio features alone.
        //
        // When Spotify returns specific labels, skip audio-feature routing entirely
        // and use the Spotify labels directly as Last.fm search anchors. They map
        // well to Last.fm tags for mainstream micro-genres and return zero results
        // for hyper-niche labels — both are better than wrong-subgenre injection.
        let spotifySpecific = spotifyGenres.filter { !broadUmbrella.contains($0.lowercased()) }
        if !spotifySpecific.isEmpty {
            return Array(spotifySpecific.prefix(2))
        }

        // ── Path B: audio-feature routing, guarded by subgenre context ─────────────
        //
        // Only fires when Spotify has no specific genres AND Last.fm tags contain at
        // least one non-umbrella term. Without any subgenre anchor, audio features
        // alone mis-route songs: a soul-sampled boom-bap track reads high valence and
        // pulls "melodic rap"; an ambient record reads low energy and pulls dark jazz.
        // The social graph handles these better — return [] and let it.
        guard !rawTags.isEmpty,
              rawTags.contains(where: { !broadUmbrella.contains($0.lowercased()) }) else {
            return []
        }

        // Use VALENCE as the primary axis — it's derived from spectral brightness which
        // correctly captures dark/warm vs bright/intense emotional quality.
        // Audio RMS energy is NOT used here: it measures physical loudness, not emotional
        // intensity (e.g. Tiramisu has 0.82 RMS due to 808 bass but feels dreamy and dark).
        let baseTags: [String] = {
            let v = features.valence

            if v < 0.30 {
                // Major-key: low valence is a measurement artifact (slow tempo penalty, low spectral
                // brightness) not an emotional one — a major-key ballad is never genuinely "sad/dark".
                if features.mode == 1 {
                    if features.energy < 0.55 { return ["mellow"] }
                    if features.danceability > 0.40 { return ["groove"] }
                    return ["smooth"]
                }
                return ["sad", "dark"]                            // very dark: grief, heavy, bleak
            }
            // Major-key songs in the mid-dark valence range feel warm/mellow, not melancholic.
            // Low valence in a major-key song is often a measurement artifact (slow tempo, low
            // spectral brightness) rather than genuine sadness — e.g. DeBarge "I Like It":
            // librosa reads energy=0.47, valence=0.45 but the song is a warm groovy soul track.
            if v < 0.45 {
                if features.mode == 1 {
                    if features.energy < 0.55 { return ["mellow"] }
                    if features.danceability > 0.40 { return ["groove"] }
                    return ["smooth"]
                }
                return ["late night", "melancholic"]              // dark-warm: After Hours
            }
            if v < 0.55 {
                if features.mode == 1 {
                    if features.energy < 0.55 { return ["mellow"] }
                    if features.danceability > 0.40 { return ["groove"] }
                    return ["smooth"]
                }
                return ["melancholic"]                            // neutral-dark: introspective
            }
            if v < 0.65 {
                // High energy + low danceability = smooth/melodic trap (Tiramisu archetype)
                // Pulls R&B/melodic-trap candidates rather than bright indie/pop
                if features.energy > 0.60 && features.danceability < 0.62 { return ["smooth", "late night"] }
                return ["feel good"]                              // warm: genuinely danceable or low-energy
            }
            // v >= 0.65 — bright/warm spectrum. Gate on energy before calling it "upbeat":
            // e.g. Redbone (energy=0.44, valence=0.72) is warm & smooth — NOT hype pop/dance.
            if features.energy < 0.50 {
                // "feel good" requires upbeat tempo AND major key.
                // Minor key OR slow BPM → "late night" (Redbone: F minor, 86 BPM, valence=0.72)
                if features.mode == 0 || features.bpm < 100 {
                    return ["late night"]
                }
                if features.danceability > 0.50 { return ["feel good", "groove"] }
                return ["smooth", "feel good"]
            }
            if features.energy < 0.68 {
                // Mid energy + bright = feel-good but not hype
                if features.danceability > 0.65 { return ["feel good", "groove"] }
                return ["feel good"]
            }
            // Hip-hop genre routing: route by subgenre feel rather than bare "upbeat"/"energetic",
            // which produce cross-genre noise on Last.fm. This injects melodic-rap / pop-rap
            // candidates (Aston Martin Music, Devil In A New Dress) that the social graph misses.
            // Subgenre context is guaranteed here — the broadUmbrella guard at the top of this
            // function already returned [] for songs with only generic hip-hop/rap tags.
            let genreMain = genreTags.first?.main.lowercased() ?? ""
            let isHipHop = genreMain.contains("hip") || genreMain.contains("hop") ||
                           genreMain.contains("rap") || genreMain.contains("trap")
            if isHipHop {
                let v = features.valence
                let d = features.danceability
                if v >= 0.65 && d < 0.68 {
                    // Bright, polished, mid-danceability: pop rap / luxury rap (Fancy, Aston Martin Music)
                    // "feel good" excluded — it's a cross-genre mood tag that pulls in Nelly Furtado,
                    // Kylie Minogue, Taylor Swift etc. which beat hip-hop on raw audio score.
                    return ["pop rap", "melodic rap", "luxury rap"]
                } else if v >= 0.65 {
                    // Bright + very danceable: party rap / feel-good rap
                    return ["melodic rap", "pop rap", "luxury rap"]
                } else {
                    // High energy but not as bright: trap-leaning but still hype
                    return ["melodic trap", "energetic"]
                }
            }
            // Mid-tempo bright songs (90-109 BPM) feel warm/feel-good, not hype pop/dance.
            // "Upbeat" and "energetic" tags on Last.fm index fast dance/pop tracks (120+ BPM).
            // e.g. All Too Well: energy=0.71, valence=0.67, BPM=92 → should be "feel good", not "upbeat".
            if features.bpm < 110 {
                return features.danceability > 0.55 ? ["feel good", "groove"] : ["feel good"]
            }
            return ["upbeat", "energetic"]                        // genuinely bright AND energetic: pop, dance (120+ BPM)
        }()

        // Append genre+mood compound queries (e.g. "late night neo soul", "melancholic dream pop").
        // Compound tags target a genre-specific slice of Last.fm's tag index, reaching niche catalogs
        // that bare mood tags miss. Sub-genre beats main (e.g. "dream pop" > "indie pop").
        guard !baseTags.isEmpty,
              let genreLabel = genreTags.first?.sub ?? genreTags.first?.main,
              !genreLabel.isEmpty else {
            return baseTags
        }
        let compounds = baseTags.prefix(2).map { "\($0) \(genreLabel)" }
        return baseTags + compounds
    }

    // ──────────────────────────────────────────────
    // MARK: - BPM Normalization
    // ──────────────────────────────────────────────

    /// Corrects BPM doubling — a common artifact where audio analysis counts beat
    /// subdivisions instead of the actual tempo. Slow R&B, soul, chill, and ballad
    /// tracks are most affected: a ~68 BPM song often comes back as 136 BPM.
    ///
    /// Strategy: if the measured BPM is > 130 AND the genre tags strongly suggest
    /// a slow song, halve it. We cross-check against the tag-estimated BPM (from
    /// the genre map) — if the measured BPM is more than 40% above the estimate,
    /// it's almost certainly doubled.
    private nonisolated func normalizeBPM(_ bpm: Double, tags: [String]) -> Double {
        // Tags that reliably indicate a fast/high-energy genre
        let fastIndicators = [
            "hyperpop", "hybrid trap", "trap", "drill", "uk drill", "phonk",
            "drum and bass", "dnb", "dubstep", "brostep", "filthstep", "breakcore",
            "hardstyle", "hardcore", "edm", "electro", "techno", "trance",
            "club", "dance", "rave"
        ]
        // Only check tag.contains($0) — not the reverse.
        // $0.contains(tag) causes false positives: "pop" matches "hyperpop", "rap" matches "trap".
        let hasFastTag = tags.contains { tag in
            fastIndicators.contains { tag.contains($0) }
        }

        // If the BPM source returns a suspiciously low reading for a fast genre, try doubling it.
        // e.g. GetSongBPM reads half-time feel on a 149 BPM hyperpop track → returns ~74 → double.
        // Guard: only double if the result lands in a plausible range (120–175).
        // This prevents 70 BPM × 2 = 140 for dreamy trap like Tiramisu (real BPM ~133) where
        // GetSongBPM measured ~67 at half-time — doubling 67 gives 134, but 70 gives 140.
        // The result check catches this: if doubled > 138 for plain trap (not dnb/hardstyle),
        // the reading is probably not a clean half-time doubling — trust the source instead.
        // Only attempt doubling when BPM looks like it was measured at half-time (< 90 BPM).
        // 90–120 BPM is a legitimate tempo range for trap/rap — don't touch it.
        // "hardcore rap".contains("hardcore") was a false positive triggering 103 → 206.
        if hasFastTag && bpm < 90 {
            let doubled = bpm * 2
            // "hardcore" alone matches "hardcore rap"/"hardcore hip hop" — exclude those.
            // Real fast-electronic genres (dnb, hardstyle, hyperpop) don't have "rap" in the tag.
            let isVeryFastGenre = tags.contains { tag in
                let noRapModifier = !tag.contains("rap") && !tag.contains("hip")
                return noRapModifier && ["drum and bass", "dnb", "hardstyle", "hardcore", "hyperpop", "breakcore", "rave", "trance"]
                    .contains { tag.contains($0) }
            }
            // Non-extreme: only double if result lands in the 100–165 BPM trap/dance range.
            // Very-fast genres (dnb 170+, hardstyle 150+) can go higher.
            let resultInRange = isVeryFastGenre ? doubled <= 200 : (doubled >= 100 && doubled <= 165)
            if resultInRange {
                simiLog("🎚️ BPM doubled \(Int(bpm)) → \(Int(doubled)) (fast genre tag, BPM too low)")
                return doubled
            }
            simiLog("🎚️ BPM doubling skipped \(Int(bpm)) → would be \(Int(doubled)) (out of valid range for genre)")
        }

        // ── Genre-range correction ─────────────────────────────────────────────────
        // Catches cached BPMs at 2× or ½× the felt tempo when the genre tag makes the
        // correct range unambiguous. This is the fix for stale Supabase cache entries:
        // normalizeBPM is called at every BPM read site (lines ~405, ~705, ~1843), so
        // any BPM that passes through with earlyTags available gets rewritten here and
        // the corrected value is stored back to Supabase by the caller.
        //
        // Priority order: specific subgenres before broad labels so "salsa" (80–115)
        // wins over "latin" (70–125) when both appear in the tag list.
        // Correction only fires when the halved/doubled value falls strictly inside
        // the range — no tolerance buffer, to avoid over-correcting ambiguous tempos.
        let genreRanges: [(keys: [String], range: ClosedRange<Double>)] = [
            (["bolero"],                              45.0...85.0),
            (["nueva cancion", "nueva canción"],      55.0...100.0),
            (["rumba"],                               60.0...105.0),
            (["bossa nova"],                          75.0...130.0),
            (["salsa"],                               80.0...115.0),
            (["cumbia"],                              80.0...115.0),
            (["bachata"],                             104.0...132.0),
            (["reggaeton"],                           70.0...105.0),
            (["latin"],                               70.0...125.0),
        ]
        if !tags.isEmpty {
            let lTags = tags.map { $0.lowercased() }
            for entry in genreRanges {
                guard lTags.contains(where: { tag in
                    entry.keys.contains(where: { tag.contains($0) || $0.contains(tag) })
                }) else { continue }
                let range = entry.range
                if range.contains(bpm) { break }     // in range — no correction needed
                if bpm > range.upperBound {
                    let halved = bpm / 2
                    if range.contains(halved) {
                        simiLog("🎚️ BPM halved \(Int(bpm)) → \(Int(halved)) (genre range '\(entry.keys[0])')")
                        return halved
                    }
                } else if bpm > 0 {
                    let doubled = bpm * 2
                    if range.contains(doubled) {
                        simiLog("🎚️ BPM doubled \(Int(bpm)) → \(Int(doubled)) (genre range '\(entry.keys[0])')")
                        return doubled
                    }
                }
                break  // matched genre but correction out of range — don't try broader genres
            }
        }

        guard bpm > 130 else { return bpm }  // Only fast readings need further correction

        // Tags that reliably indicate a slow tempo
        let slowIndicators = [
            "r&b", "rnb", "soul", "neo-soul", "neo soul", "chill", "chillout", "chill out",
            "ambient", "lo-fi", "lofi", "blues", "gospel", "ballad", "slow jam", "slow",
            "bedroom pop", "dream pop", "folk", "acoustic", "romantic", "melancholic",
            "sad", "relaxing", "smooth", "laid back", "downtempo", "trip hop",
            // Slow Latin subgenres — "latin" is intentionally excluded (salsa/merengue are genuinely fast).
            // These specific subgenres are always slow enough that > 155 BPM is a detector error.
            "bolero", "bossa nova", "nueva cancion", "nueva canción",
        ]

        // Same direction fix: only tag.contains($0), not the reverse.
        // "bedroom pop".contains("pop") → false positive if reversed.
        let hasSlowTag = tags.contains { tag in
            slowIndicators.contains { tag.contains($0) }
        }

        // 130–155 gap: ballads and slow jams are almost never genuinely 130–155 BPM.
        // When the detector lands here for a clearly slow genre, it almost certainly
        // locked onto the subdivisions (e.g. "Hello" by Adele: real ~79 BPM → 158 BPM
        // detected at double-time; a 140-read of a 70 BPM ballad lands here).
        // We use a narrow tag set to avoid halving legitimately fast R&B/trap
        // (e.g. "All Back" by CB is a real 146 BPM neo-soul — "r&b" alone is too broad).
        // Slow Latin subgenres (bolero, nueva cancion) have the same double-tempo artifact
        // as ballads and never live in the 130–155 range genuinely.
        let stronglySlowTags: Set<String> = [
            "ballad", "slow jam", "slow jams", "gospel", "blues",
            "bolero", "nueva cancion", "nueva canción",
        ]
        let hasStronglySlowTag = tags.contains { tag in stronglySlowTags.contains { tag.contains($0) } }
        if hasStronglySlowTag && bpm > 130 && bpm <= 155 {
            let halved = bpm / 2
            if halved >= 55 && halved <= 90 {
                simiLog("🎚️ BPM halved \(Int(bpm)) → \(Int(halved)) (ballad/slow tag, 130–155 range)")
                return halved
            }
        }

        // Slow-tag halving: only kick in above 155 BPM.
        // R&B, soul, neo-soul etc. legitimately live in the 130–155 range
        // (e.g. "All Back" CB at 146 BPM). Halving a 180 reading when the song is
        // actually ~146 produces 90 — wrong in both directions.
        // Threshold 155 means: 155÷2 = 77.5, which is the right felt-tempo for a slow jam
        // that the detector read at double-time. Below 155, trust the source.
        if hasSlowTag && bpm > 155 {
            let halved = bpm / 2
            simiLog("🎚️ BPM halved \(Int(bpm)) → \(Int(halved)) (slow genre tag + >155 BPM)")
            return halved
        }

        // Catch doubled BPM for non-fast genres in the 155–200 range.
        // Genuine 155+ BPM songs (drum & bass, hardstyle, hyperpop) all have fast genre tags —
        // those are already handled above. Pop, rock, R&B, indie, etc. at 155+ BPM means
        // the tempo detector locked onto the subdivisions instead of the felt beat.
        // e.g. Sunday Morning (Maroon 5): tagged "pop/rock", 176 BPM detected → 88 BPM felt.
        if bpm > 155 && !hasFastTag {
            let halved = bpm / 2
            simiLog("🎚️ BPM halved \(Int(bpm)) → \(Int(halved)) (non-fast genre, suspicious tempo)")
            return halved
        }

        // Catch extreme values regardless of genre (>200 BPM is almost never real)
        if bpm > 200 {
            return bpm / 2
        }

        return bpm
    }

    // ──────────────────────────────────────────────
    // MARK: - Tag-based Feature Estimation
    // ──────────────────────────────────────────────

    /// Maps Last.fm genre/mood tags to approximate Spotify-style audio features.
    /// Averages across all matching tags. Returns nil if no tags are recognisable.
    private func estimateFeaturesFromTags(_ tags: [String], bpm: Double = 0) async -> AudioFeatures? {
        guard !tags.isEmpty else { return nil }

        // Tag → (energy, valence, danceability)
        let tagMap: [String: (e: Double, v: Double, d: Double)] = [
            // Electronic
            "edm":              (0.85, 0.65, 0.85),
            "electronic":       (0.70, 0.55, 0.75),
            "dance":            (0.78, 0.70, 0.85),
            "house":            (0.80, 0.65, 0.85),
            "electro house":    (0.88, 0.62, 0.85),
            "big room":         (0.90, 0.68, 0.88),
            "techno":           (0.82, 0.50, 0.80),
            "trance":           (0.82, 0.60, 0.78),
            "rave":             (0.92, 0.58, 0.85),
            "hardstyle":        (0.95, 0.50, 0.82),
            "ambient":          (0.20, 0.45, 0.25),
            "lo-fi":            (0.30, 0.50, 0.45),
            "lofi":             (0.30, 0.50, 0.45),
            "chillwave":        (0.35, 0.55, 0.45),
            "synthwave":        (0.60, 0.55, 0.65),
            "synth-pop":        (0.62, 0.58, 0.68),
            "synth pop":        (0.62, 0.58, 0.68),
            "drum and bass":    (0.85, 0.50, 0.75),
            "dubstep":          (0.88, 0.45, 0.70),
            "brostep":          (0.92, 0.40, 0.72),  // heavy Skrillex-style dubstep — aggressive, festival
            "filthstep":        (0.90, 0.35, 0.68),  // nastier/darker dubstep variant
            "future bass":      (0.85, 0.68, 0.82),
            "hyperpop":         (0.85, 0.72, 0.82),  // chaotic-fun, bright — not dark
            "hybrid trap":      (0.78, 0.62, 0.78),  // hype/energetic, warmer valence than dark trap
            "breakcore":        (0.92, 0.30, 0.60),  // chaotic, aggressive, fast-chopped breaks
            "electro":          (0.80, 0.52, 0.76),  // electro (not house) — robot-funk, raw
            "idm":              (0.55, 0.40, 0.45),  // Intelligent Dance Music — complex, introspective
            "experimental":     (0.55, 0.38, 0.42),  // catch-all avant-garde — low valence, unpredictable
            "bass":             (0.78, 0.48, 0.72),  // generic bass music — heavy but broad
            "glitch":           (0.68, 0.45, 0.60),
            "vaporwave":        (0.28, 0.52, 0.38),  // slow, pitch-shifted nostalgia — very low energy
            "chiptune":         (0.72, 0.68, 0.68),  // 8-bit game music — bright, energetic
            "jersey club":      (0.85, 0.58, 0.82),  // fast chopped-vocal club from NJ — intense, danceable
            "amapiano":         (0.65, 0.65, 0.78),  // South African log-drum house — groovy, warm
            // Hip-hop / Rap
            "hip-hop":          (0.62, 0.52, 0.72),
            "hip hop":          (0.62, 0.52, 0.72),
            "rap":              (0.65, 0.50, 0.72),
            "trap":             (0.70, 0.48, 0.75),  // slightly warmer — dark but not fully brooding
            "cloud rap":        (0.42, 0.40, 0.55),  // dreamy, lo-fi trap — Don Toliver, Travis Scott
            "cloud":            (0.42, 0.40, 0.55),
            "cloud trap":       (0.42, 0.38, 0.52),  // alias used by Last.fm for psychedelic trap sound
            "melodic trap":     (0.50, 0.42, 0.58),  // trap with melodic hooks — mid energy, dark-leaning
            "melodic rap":      (0.52, 0.45, 0.58),  // rap with sung melodies — moderate, introspective
            "psychedelic trap": (0.40, 0.38, 0.50),  // hazy, reverb-heavy, low energy — Don Toliver core sound
            "emo rap":          (0.50, 0.25, 0.52),  // heavy emotional weight, dark valence
            "emo trap":         (0.50, 0.25, 0.52),
            "rage rap":         (0.75, 0.38, 0.68),  // Playboi Carti, Destroy Lonely — aggressive, dark
            "dark trap":        (0.65, 0.28, 0.65),  // aggressive and heavy, very low valence
            "boom bap":         (0.60, 0.48, 0.65),
            "drill":            (0.72, 0.38, 0.70),
            "uk drill":         (0.74, 0.35, 0.68),
            "phonk":            (0.72, 0.42, 0.72),
            "grime":            (0.78, 0.42, 0.70),
            "uk hip hop":       (0.65, 0.45, 0.68),
            "uk rap":           (0.65, 0.45, 0.68),
            "punk rap":         (0.82, 0.42, 0.65),
            "rap rock":         (0.80, 0.45, 0.62),
            "alternative hip hop": (0.60, 0.42, 0.60),
            "alternative rap":  (0.60, 0.42, 0.60),
            "experimental hip hop": (0.58, 0.40, 0.58),
            "trap soul":        (0.45, 0.55, 0.55),  // Bryson Tiller — slow R&B with trap production
            "pop rap":          (0.65, 0.68, 0.72),  // Drake/J.Cole accessible mode — upbeat, bright, polished
            "luxury rap":       (0.62, 0.65, 0.68),  // Rick Ross/Jay-Z/Drake — opulent, mid-tempo, smooth
            // Pop
            "pop":              (0.65, 0.68, 0.72),
            "k-pop":            (0.72, 0.72, 0.78),
            "j-pop":            (0.68, 0.70, 0.72),
            "indie pop":        (0.52, 0.58, 0.58),
            "electropop":       (0.68, 0.62, 0.72),
            "bedroom pop":      (0.45, 0.55, 0.52),
            "dream pop":        (0.45, 0.55, 0.50),
            // Rock / Alt
            "rock":             (0.72, 0.48, 0.55),
            "alternative":      (0.55, 0.45, 0.52),
            "alt-rock":         (0.62, 0.45, 0.55),
            "indie rock":       (0.55, 0.48, 0.55),
            "post-rock":        (0.58, 0.40, 0.45),
            "punk":             (0.85, 0.48, 0.62),
            "metal":            (0.90, 0.28, 0.45),
            "hard rock":        (0.82, 0.42, 0.55),
            "grunge":           (0.70, 0.38, 0.50),
            "shoegaze":         (0.52, 0.38, 0.42),
            "indie":            (0.50, 0.50, 0.52),
            "progressive rock": (0.55, 0.45, 0.42),  // Pink Floyd, Yes — complex, dynamic, lower dance
            "prog rock":        (0.55, 0.45, 0.42),
            "nu-metal":         (0.85, 0.35, 0.52),  // Linkin Park, SOAD — aggressive, rap-influenced
            "metalcore":        (0.88, 0.28, 0.48),  // heavy breakdowns — very dark, intense
            "pop punk":         (0.78, 0.50, 0.62),  // Blink-182, Paramore — fast, emotional, catchy
            "folk rock":        (0.52, 0.55, 0.50),  // Eagles, Fleetwood Mac — warm acoustic meets rock
            // Emo / Dark
            "emo":              (0.58, 0.25, 0.48),
            "post-punk":        (0.58, 0.35, 0.50),
            "gothic":           (0.52, 0.22, 0.40),
            "darkwave":         (0.50, 0.25, 0.42),
            // Soul / R&B / Funk — split by energy level so "slow jam" and "hype R&B"
            // estimate very different features and don't collapse into the same bucket.
            "r&b":              (0.58, 0.62, 0.65),   // baseline: mid-energy, warm
            "rnb":              (0.58, 0.62, 0.65),   // alias — Last.fm tags both spellings
            "soul":             (0.52, 0.64, 0.58),
            "neo-soul":         (0.48, 0.60, 0.55),
            "neo soul":         (0.48, 0.60, 0.55),  // alias — Last.fm uses both spellings
            "gospel":           (0.62, 0.75, 0.60),  // uplifting, choir-heavy, warm valence
            "funk":             (0.72, 0.70, 0.80),
            // Slow / intimate R&B — low energy, warm valence
            "slow jam":         (0.35, 0.62, 0.45),
            "slow jams":        (0.35, 0.62, 0.45),
            "quiet storm":      (0.38, 0.60, 0.45),
            "bedroom":          (0.38, 0.58, 0.48),
            "late night":       (0.38, 0.55, 0.45),
            "smooth r&b":       (0.42, 0.64, 0.50),
            "contemporary r&b": (0.52, 0.62, 0.60),
            "alternative rnb":  (0.48, 0.42, 0.55),  // SZA, Frank Ocean, Miguel — darker, introspective alt-R&B
            "alternative r&b":  (0.48, 0.42, 0.55),  // alias — Last.fm uses both spellings
            // Hype / club R&B — high energy, high valence, very different from slow jams
            "new jack swing":   (0.78, 0.68, 0.80),
            "club":             (0.82, 0.68, 0.85),
            "banger":           (0.85, 0.65, 0.82),
            "hype":             (0.85, 0.62, 0.80),
            "crunk":            (0.88, 0.55, 0.82),
            // Acoustic / Folk
            "folk":             (0.38, 0.55, 0.40),
            "acoustic":         (0.35, 0.55, 0.40),
            "singer-songwriter":(0.38, 0.52, 0.42),
            "country":          (0.58, 0.60, 0.55),
            "americana":        (0.50, 0.58, 0.52),  // country-adjacent, earthy — Sturgill, Jason Isbell
            "bluegrass":        (0.58, 0.62, 0.55),  // Appalachian string band — upbeat but rootsy
            // Reggae / Dancehall / Ska
            "reggae":           (0.50, 0.68, 0.62),  // Bob Marley — warm, laid-back, positive
            "dancehall":        (0.70, 0.65, 0.78),  // Jamaican dancehall — uptempo, heavy bass
            "ska":              (0.72, 0.62, 0.68),  // punky upstrokes — fast, fun, energetic
            // Afro / World
            "afrobeats":        (0.75, 0.72, 0.82),  // Burna Boy, Wizkid — rhythmic, warm, very danceable
            "afropop":          (0.70, 0.75, 0.78),  // more pop-polished afrobeats
            // Latin
            "reggaeton":        (0.78, 0.65, 0.85),  // Bad Bunny, J Balvin — heavy dembow, club-ready
            "latin":            (0.68, 0.68, 0.75),  // broad Latin catch-all
            "bossa nova":       (0.38, 0.65, 0.55),  // Brazilian jazz-folk — gentle, warm, sophisticated
            // Jazz / Blues / Classical
            "jazz":             (0.42, 0.58, 0.48),
            "jazz fusion":      (0.52, 0.55, 0.52),  // Herbie Hancock, Chick Corea — complex, energetic jazz
            "smooth jazz":      (0.35, 0.58, 0.42),  // Kenny G — mellow, background, polished
            "blues":            (0.45, 0.35, 0.42),
            "classical":        (0.35, 0.52, 0.30),
            // Mood tags
            "emotional":        (0.42, 0.38, 0.40),  // prevents false-match to "emo" genre; reflective, subdued
            "chill":            (0.30, 0.55, 0.40),
            "sad":              (0.35, 0.18, 0.38),
            "melancholic":      (0.38, 0.22, 0.40),
            "happy":            (0.68, 0.82, 0.72),
            "upbeat":           (0.75, 0.78, 0.78),
            "aggressive":       (0.85, 0.32, 0.55),
            "party":            (0.88, 0.75, 0.88),  // high — "party" means hype, not slow
            "relaxing":         (0.28, 0.55, 0.38),
            "chill out":        (0.28, 0.55, 0.38),
            "dark":             (0.55, 0.20, 0.48),
            "workout":          (0.88, 0.58, 0.78),
            "summer":           (0.70, 0.78, 0.75),
            "romantic":         (0.40, 0.65, 0.48),
            "sensual":          (0.42, 0.60, 0.50),
            "seductive":        (0.42, 0.58, 0.50),
            "smooth":           (0.40, 0.62, 0.48),  // "smooth" = slow/mellow, not club
            // Era / decade tags — act as tiebreakers, not primary genre signals
            "2010s":            (0.65, 0.60, 0.65),  // streaming era — pop/trap/indie mix
            "2000s":            (0.65, 0.58, 0.62),  // aughts pop/rock/R&B
            "80s":              (0.65, 0.62, 0.62),  // synth-pop / new wave / rock era
            "90s":              (0.60, 0.55, 0.58),  // grunge / britpop / r&b era
            "70s":              (0.58, 0.62, 0.58),  // classic rock / soul / disco era
            "60s":              (0.55, 0.68, 0.58),  // light pop / motown era
            // Meta-genre / style tags Last.fm commonly assigns
            "new wave":         (0.62, 0.52, 0.62),  // post-punk pop, synth-driven
            "classic rock":     (0.68, 0.50, 0.55),  // polished rock, slightly less raw than "rock"
            "disco":            (0.78, 0.72, 0.82),  // high energy, high dance, bright
            "motown":           (0.60, 0.72, 0.68),  // soulful pop, upbeat
            // Atmospheric / hazy mood tags — common in cloud rap, psychedelic trap, modern R&B
            "atmospheric":      (0.35, 0.45, 0.38),  // ambient-textured, moody
            "dreamy":           (0.38, 0.52, 0.42),  // floaty, hazy — cloud rap/dream pop overlap
            "hazy":             (0.36, 0.42, 0.40),  // smoky, low-energy, slightly dark
            "woozy":            (0.38, 0.38, 0.45),  // disoriented/hazy — modern trap production feel
            "moody":            (0.42, 0.35, 0.45),  // dark but not bleak — introspective modern R&B/trap
            "introspective":    (0.38, 0.42, 0.40),  // thoughtful, inward — melodic rap, bedroom pop
            "nocturnal":        (0.38, 0.42, 0.42),  // night-time atmosphere — late-night driving
            "trippy":           (0.42, 0.38, 0.48),  // psychedelic quality — reverb-heavy production
            "ethereal":         (0.32, 0.50, 0.38),  // otherworldly, airy — ambient/cloud overlap
            "melancholy":       (0.38, 0.22, 0.40),  // alias for melancholic — common Last.fm spelling
            "melodic":          (0.52, 0.52, 0.58),  // catch-all for songs with strong melodic hooks
            "stoner":           (0.38, 0.45, 0.42),  // slow, hazy, heavy — stoner rock/rap overlap
            "psychedelic":      (0.48, 0.45, 0.48),  // broad psych tag — lower energy, fluid rhythm
        ]

        var totalE = 0.0, totalV = 0.0, totalD = 0.0
        var totalWeight = 0.0
        var missedTags: [String] = []

        // Era/decade and atmospheric mood tags are weak genre signals — they dilute the
        // feature estimate when mixed with strong genre tags. Weight them at 0.3× so
        // "trap + 2010s + dreamy" is still dominated by "trap", not averaged into a
        // vague mid-point. Specific genre tags (hip-hop, soul, metal…) stay at 1.0×.
        let dilutingTags: Set<String> = [
            "2010s", "2000s", "80s", "90s", "70s", "60s",
            "melodic", "atmospheric", "dreamy", "hazy", "woozy", "moody",
            "introspective", "nocturnal", "trippy", "ethereal", "melancholy",
            "stoner", "psychedelic", "emotional"
        ]

        // Sort keys longest-first so specific keys (e.g. "trap") beat substrings (e.g. "rap")
        let sortedTagMap = tagMap.sorted { $0.key.count > $1.key.count }

        for tag in tags {
            let weight = dilutingTags.contains(tag) ? 0.3 : 1.0
            if let match = tagMap[tag] {
                totalE += match.e * weight; totalV += match.v * weight; totalD += match.d * weight
                totalWeight += weight
            } else if let match = sortedTagMap.first(where: { tag.contains($0.key) }) {
                totalE += match.value.e * weight; totalV += match.value.v * weight; totalD += match.value.d * weight
                totalWeight += weight
            } else {
                missedTags.append(tag)
            }
        }

        // Supabase enrichment: look up any tags that weren't in the hardcoded map.
        // This is how the genre_tag_map grows — new tags discovered at runtime get stored.
        if !missedTags.isEmpty {
            let remoteMatches = await supabase.lookupTagMap(tags: missedTags)
            for (tag, tf) in remoteMatches {
                let weight = dilutingTags.contains(tag) ? 0.3 : 1.0
                totalE += tf.energy * weight; totalV += tf.valence * weight; totalD += tf.danceability * weight
                totalWeight += weight
                simiLog("🌐 Supabase genre map hit: \"\(tag)\" → e:\(tf.energy) v:\(tf.valence)")
            }
        }

        guard totalWeight > 0 else { return nil }

        // If no measured BPM available, estimate from the genre tags.
        // These are typical midpoints — not precise, but far better than showing "Unknown".
        let finalBPM: Double
        if bpm > 0 {
            finalBPM = bpm
        } else {
            let bpmByGenre: [String: Double] = [
                "funk": 100, "soul": 87, "r&b": 90, "rnb": 90, "neo-soul": 85, "neo soul": 85,
                "disco": 118, "gospel": 88, "motown": 110,
                "hip-hop": 88, "hip hop": 88, "rap": 90, "trap": 140, "drill": 145, "uk drill": 145, "boom bap": 90,
                "phonk": 135, "cloud rap": 130, "cloud": 130,
                "cloud trap": 130, "melodic trap": 135, "melodic rap": 90, "psychedelic trap": 125,
                "emo rap": 85, "emo trap": 130, "rage rap": 145, "dark trap": 140,
                "grime": 140, "uk hip hop": 90, "uk rap": 90, "punk rap": 155, "rap rock": 140,
                "alternative hip hop": 90, "alternative rap": 90, "experimental hip hop": 88,
                "pop": 110, "k-pop": 118, "j-pop": 115, "indie pop": 108, "electropop": 118,
                "bedroom pop": 100, "dream pop": 105,
                "dance": 126, "house": 126, "electro house": 128, "big room": 128,
                "techno": 135, "trance": 138, "edm": 128, "drum and bass": 174,
                "rave": 150, "hardstyle": 150, "future bass": 150,
                "dubstep": 140, "brostep": 140, "filthstep": 140, "breakcore": 160,
                "electro": 130, "idm": 120, "experimental": 110, "bass": 140,
                "ambient": 75, "lo-fi": 83, "lofi": 83, "chillwave": 95,
                "synthwave": 105, "synth-pop": 110, "synth pop": 110,
                "rock": 120, "indie rock": 115, "alt-rock": 118, "alternative": 115,
                "punk": 160, "metal": 150, "hard rock": 130, "grunge": 120, "shoegaze": 105,
                "indie": 112, "folk": 95, "acoustic": 95, "singer-songwriter": 95, "country": 108,
                "jazz": 120, "blues": 85, "classical": 100,
                "reggae": 80, "dancehall": 95, "ska": 140,
                "afrobeats": 100, "afropop": 105,
                "reggaeton": 92, "latin": 100, "bossa nova": 120,
                "vaporwave": 85, "chiptune": 140, "jersey club": 150, "amapiano": 112,
                "trap soul": 75,
                "progressive rock": 110, "prog rock": 110, "nu-metal": 130,
                "metalcore": 155, "pop punk": 155, "folk rock": 105,
                "americana": 95, "bluegrass": 130,
                "jazz fusion": 115, "smooth jazz": 88,
                "2000s": 110, "2010s": 112,
                "80s": 108, "90s": 100, "70s": 95, "60s": 95,
                // Atmospheric/mood tags BPM estimates
                "atmospheric": 90, "dreamy": 95, "hazy": 88, "woozy": 90, "moody": 88,
                "introspective": 90, "nocturnal": 88, "trippy": 92, "ethereal": 85,
                "melancholy": 85, "melodic": 95, "stoner": 80, "psychedelic": 90,
            ]
            // Sort longest-first so "trap" beats "rap", "drum and bass" beats "bass", etc.
            let sortedBpm = bpmByGenre.sorted { $0.key.count > $1.key.count }
            let estimatedBPM = tags.compactMap { tag -> Double? in
                if let exact = bpmByGenre[tag] { return exact }
                return sortedBpm.first(where: { tag.contains($0.key) || $0.key.contains(tag) })?.value
            }.first ?? 0
            finalBPM = estimatedBPM
        }

        return AudioFeatures(
            bpm:              finalBPM,
            energy:           totalE / totalWeight,
            valence:          totalV / totalWeight,
            danceability:     totalD / totalWeight,
            acousticness:     0.0,
            instrumentalness: 0.0,
            liveness:         0.0,
            loudness:         -10.0,
            key:              0,
            mode:             1,
            isEstimated:      true
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - DCLAP Background Catalog Builder
    // ──────────────────────────────────────────────

    /// Pre-analyzes the source artist's top tracks via Last.fm + SonicDNA and caches
    /// them to Supabase. Runs entirely in the background after enrichment completes.
    /// Next time the user searches any track by this artist, Stage 1 gets a cache hit
    /// and skips the 3-5s LocalAudio analysis entirely.
    private func warmArtistCache(artist: String) async {
        guard !artist.isEmpty else { return }
        let topTracks = await lastFMService.fetchArtistTopTracks(artist: artist)
        guard !topTracks.isEmpty else { return }

        // Filter out tracks already in Supabase before spawning tasks — avoids
        // paying download + analysis cost for tracks we already have.
        var uncached: [(title: String, artist: String)] = []
        for track in topTracks.prefix(12) {
            if await supabase.lookupFeatures(title: track.title, artist: track.artist) == nil {
                uncached.append(track)
            }
        }
        guard !uncached.isEmpty else { return }
        simiLog("🔥 Cache warming \(uncached.count) tracks for \(artist)")

        // 2 slots, 150 ms stagger: background work should barely be felt.
        // Lower slot count + wider stagger than Stage 2 since the user isn't
        // waiting on this — spread the CPU cost over time, not over results.
        let analyzer = localAudioAnalyzer
        let warmCoolant = DSPCoolant(slots: 2)
        await withTaskGroup(of: Void.self) { group in
            for track in uncached {
                group.addTask(priority: .background) {
                    await warmCoolant.enter()
                    defer { Task { await warmCoolant.exit() } }
                    var previewURL = await self.itunesService.fetchPreviewURL(title: track.title, artist: artist)
                    if previewURL == nil { previewURL = await self.deezerService.fetchPreviewURL(title: track.title, artist: artist) }
                    guard let url = previewURL,
                          let audioURL = URL(string: url),
                          let (data, resp) = try? await URLSession.shared.data(from: audioURL),
                          (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
                    guard let features = await analyzer.analyze(data: data, sourceURL: url, title: track.title) else { return }
                    await self.supabase.storeFeatures(title: track.title, artist: artist, features: features, source: "preview_audio")
                    simiLog("🔥 Warmed: \(track.title) by \(artist)")
                }
            }
            for await _ in group {}
        }
    }

    /// Fire-and-forget: sends the top results to HF /embed-candidates so their
    /// DCLAP embeddings are computed and written to Supabase track_embeddings.
    /// The catalog self-populates from actual user searches — no manual seeding needed.
    private func embedCandidatesInBackground(songs: [SimilarSong], sourceFeatures: AudioFeatures) async {
        // Only embed songs that earned their position. Score ≥ 0.60 filters noise without
        // requiring isEstimated=false — the DCLAP embedding is derived from audio waveform,
        // not from features, so feature source doesn't affect embedding quality. Requiring
        // isEstimated=false blocked all tag-estimated songs (capped at 0.68) and starved
        // the catalog. 0.60 still excludes poor matches while letting the catalog grow.
        let candidates = songs.prefix(25)
            .filter { $0.similarityScore >= 0.60 }
            .compactMap { song -> [String: Any]? in
            guard let preview = song.previewURL else { return nil }
            var c: [String: Any] = [
                "spotifyId":  song.id,
                "title":      song.title,
                "artist":     song.artist,
                "previewUrl": preview,
            ]
            if let f = song.audioFeatures {
                if let a  = f.arousal          { c["arousal"]     = a }
                if let v  = f.valenceEssentia  { c["valenceDeam"] = v }
                if f.bpm > 0                   { c["bpm"]         = f.bpm }
            }
            return c
        }
        guard !candidates.isEmpty else { return }

        let payload: [String: Any] = ["candidates": candidates]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var request = URLRequest(url: URL(string: "https://layzskolah-simi-audio-analyzer.hf.space/embed-candidates")!)
        request.httpMethod  = "POST"
        request.httpBody    = body
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        simiLog("🌱 embedCandidatesInBackground: sending \(candidates.count) candidates to /embed-candidates")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            simiLog("🌱 /embed-candidates → HTTP \(status): \(preview)")
        } catch {
            simiLog("⚠️ /embed-candidates failed: \(error)")
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - DCLAP Vector Candidate Fetch
    // ──────────────────────────────────────────────

    /// Sends a 512-dim DCLAP embedding to the HF /vector-search endpoint and
    /// returns (title, artist) pairs for the nearest neighbours in track_embeddings.
    /// Returns [] when the source song has no embedding or the backend is unreachable.
    private func fetchVectorCandidates(embedding: [Double]) async -> [(title: String, artist: String)] {
        guard !embedding.isEmpty else { return [] }
        let payload: [String: Any] = [
            "embedding":   embedding,
            "matchCount":  20,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return [] }

        var request = URLRequest(url: URL(string: "https://layzskolah-simi-audio-analyzer.hf.space/vector-search")!)
        request.httpMethod  = "POST"
        request.httpBody    = body
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response  = try JSONDecoder().decode(VectorSearchResponse.self, from: data)
            return response.results
                .map { (title: $0.title, artist: $0.artist) }
        } catch {
            simiLog("⚠️ DCLAP vector-search failed: \(error)")
            return []
        }
    }

    /// Sends a 200-dim MusiCNN embedding to the HF /musicnn-vector-search endpoint and
    /// returns (title, artist) pairs for the nearest neighbours in track_embeddings.
    /// Falls back to [] gracefully — catalog starts empty and populates over time via /embed-candidates.
    private func fetchMusiCNNCandidates(embedding: [Double]) async -> [(title: String, artist: String)] {
        guard !embedding.isEmpty else { return [] }
        let payload: [String: Any] = [
            "embedding":  embedding,
            "matchCount": 20,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return [] }

        var request = URLRequest(url: URL(string: "https://layzskolah-simi-audio-analyzer.hf.space/musicnn-vector-search")!)
        request.httpMethod  = "POST"
        request.httpBody    = body
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response  = try JSONDecoder().decode(VectorSearchResponse.self, from: data)
            let results   = response.results
                .map { (title: $0.title, artist: $0.artist) }
            if !results.isEmpty { simiLog("🎼 MusiCNN ANN: \(results.count) candidates") }
            return results
        } catch {
            simiLog("⚠️ MusiCNN vector-search failed: \(error)")
            return []
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Reset
    // ──────────────────────────────────────────────

    func reset() {
        sourceSong = nil
        blendedSongs = []
        moodTarget = nil
        recommendations = []
        errorMessage = nil
        detectedGenres = []
        lastSourceFeatures = nil
        lastSeedFeatures = []
        lastGenres = []
    }

    // ──────────────────────────────────────────────
    // MARK: - Feedback
    // ──────────────────────────────────────────────

    /// Updates the feedback state for a single recommendation.
    /// Uses index-based reassignment because SimilarSong is a struct — direct property
    /// mutation on an array element would create a copy and leave @Published unchanged.
    func setFeedback(songID: String, state: FeedbackState?) {
        guard let idx = recommendations.firstIndex(where: { $0.id == songID }) else { return }
        recommendations[idx].feedbackState = state
    }
}

// ──────────────────────────────────────────────────────────────
// MARK: - DSPCoolant
//
// Thermal throttle for concurrent on-device DSP analysis.
// Like a car's coolant system: keeps the engine powerful without
// letting it run dangerously hot.
//
// Two mechanisms:
//   1. Slot cap — never more than `slots` analyze() calls live at once.
//   2. Stagger — the first `slots` tasks start with `startIntervalMs`
//      spacing so they don't all pile onto the CPU simultaneously.
//      After the initial burst, tasks start the moment a slot frees.
//
// Usage:
//   let coolant = DSPCoolant(slots: 3, startIntervalMs: 80)
//   group.addTask(priority: .utility) {
//       let delay = await coolant.enter()
//       defer { Task { await coolant.exit() } }
//       if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
//       return await analyzer.analyze(...)
//   }
// ──────────────────────────────────────────────────────────────

private actor DSPCoolant {
    private let slots: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(slots: Int = 3) {
        self.slots = slots
    }

    /// Waits for a free slot before the caller starts DSP work.
    func enter() async {
        if active >= slots {
            await withCheckedContinuation { waiters.append($0) }
        }
        active += 1
    }

    func exit() {
        active -= 1
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - SimiError
// ──────────────────────────────────────────────

// ──────────────────────────────────────────────
// MARK: - DCLAP Vector Search Response Models
// ──────────────────────────────────────────────

struct VectorCandidate: Codable {
    var spotifyId:   String
    var title:       String
    var artist:      String
    var similarity:  Double
    var arousal:     Double?
    var valenceDeam: Double?
    var bpm:         Double?

    enum CodingKeys: String, CodingKey {
        case spotifyId   = "spotifyId"
        case title, artist, similarity, arousal, bpm
        case valenceDeam = "valenceDeam"
    }
}

struct VectorSearchResponse: Codable {
    var results: [VectorCandidate]
}

enum SimiError: LocalizedError {
    case invalidURL
    case authFailed
    case songNotFound
    case rateLimited
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:    return "That doesn't look like a valid song link. Try pasting a Spotify, YouTube, or SoundCloud URL."
        case .authFailed:    return "Couldn't connect to Spotify. Check your internet connection and try again."
        case .songNotFound:  return "Couldn't find that song. Try a different title or artist spelling."
        case .rateLimited:   return "Too many requests — please wait a moment and try again."
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}
