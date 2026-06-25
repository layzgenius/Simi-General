// RecommendationEngine.swift
// Simi — Music Discovery App
//
// The brain of Simi. Coordinates Spotify, Last.fm, Deezer, MusicBrainz, ListenBrainz,
// and a Railway-hosted librosa microservice to produce a ranked list of similar songs.
//
// Audio feature priority chain:
//   1. Supabase feature cache  (any prior source — instant)
//   2. Railway librosa         (full measured FFT/chroma/MFCC — primary source)
//   3. Local preview analyzer  (energy + brightness) merged with tag estimation
//   4. Tag estimation alone    (genre/mood tags → energy, valence, danceability)
//   5. BPM only                (GetSongBPM/Deezer + neutral energy/valence)
//   6. Neutral defaults        (app still works, just less accurate scoring)
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

@MainActor
class RecommendationEngine: ObservableObject {

    // ──────────────────────────────────────────────
    // MARK: - Published State (drives the UI)
    // ──────────────────────────────────────────────

    @Published var sourceSong: Song?
    @Published var blendedSongs: [Song] = []    // Populated when blending >1 seeds; empty for single-song searches
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
    private let musicBrainzService  = MusicBrainzService()
    private let listenBrainzService = ListenBrainzService()
    private let acousticBrainzService = AcousticBrainzService()
    private let itunesService       = iTunesService()
    private let getSongBPMService   = GetSongBPMService()
    private let simiAudioService    = SimiAudioService.shared
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
    /// Priority: Last.fm → iTunes Search API
    /// Returns at least [Genre(main: "Unknown")] — never empty.
    private func fetchGenresWithFallback(title: String, artist: String) async -> [Genre] {
        // Stage 0: Supabase tag cache — instant, no API call needed
        if let cached = await supabase.lookupTags(title: title, artist: artist), !cached.isEmpty {
            return genresFromRawTags(cached)
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
        // ── Path A: Labs (fast, genre-agnostic, session-based CF) ──
        if let mbid = await listenBrainzService.resolveACRMBID(title: title, artist: artist) {
            let labsTracks = await listenBrainzService.fetchLabsSimilarTracks(mbid: mbid)
            if !labsTracks.isEmpty {
                return labsTracks
            }
            // Labs had the MBID but no similar recordings — try lb-radio on same MBID
            let radioTracks = await listenBrainzService.fetchSimilarRecordings(mbid: mbid)
            if !radioTracks.isEmpty { return radioTracks }
        }
        // ── Path B: MusicBrainz search + lb-radio (1.1s rate-limit sleep) ──
        guard let mbid = await musicBrainzService.findMBID(title: title, artist: artist) else {
            return []
        }
        return await listenBrainzService.fetchSimilarRecordings(mbid: mbid)
    }

    /// Fetches top tracks from up to 8 artists similar to the given artist.
    /// Always-on parallel source — not a fallback. Returns up to ~40 deduplicated (title, artist) pairs.
    private func fetchArtistSimilarCandidates(artist: String) async -> [(title: String, artist: String)] {
        let similarArtists = (try? await lastFMService.fetchSimilarArtists(artist: artist)) ?? []
        guard !similarArtists.isEmpty else { return [] }
        var tracks: [(title: String, artist: String)] = []
        await withTaskGroup(of: [(title: String, artist: String)].self) { group in
            for similarArtist in similarArtists.prefix(8) {
                group.addTask {
                    await self.lastFMService.fetchArtistTopTracks(artist: similarArtist)
                }
            }
            for await artistTracks in group {
                tracks += artistTracks
            }
        }
        var seen = Set<String>()
        return tracks.filter { t in
            seen.insert("\(t.title)|\(t.artist)".lowercased()).inserted
        }
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

    private func genresFromRawTags(_ tags: [String]) -> [Genre] {
        // Specific subgenres — preferred over generic umbrella labels when present.
        // e.g. "cloud rap" beats "rap", "psychedelic trap" beats "trap".
        let specificSubgenres: Set<String> = [
            // Hip-hop
            "cloud rap", "cloud trap", "psychedelic trap", "melodic trap", "dark trap",
            "emo rap", "emo trap", "rage rap", "boom bap", "uk drill", "phonk", "grime",
            "alternative hip hop", "alternative rap", "experimental hip hop", "punk rap",
            "trap soul",
            // R&B / Soul
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
            "disco", "funk", "reggae", "dancehall", "ska",
            "afrobeats", "afropop",
            "reggaeton", "latin", "bossa nova",
            "americana", "bluegrass",
            // Jazz
            "jazz fusion", "smooth jazz",
        ]
        let generic = [
            "indie pop","dream pop","bedroom pop","indie rock","alt-rock","alternative",
            "rock","pop","hip-hop","hip hop","rap","trap","r&b","rnb","soul","neo-soul",
            "funk","electronic","edm","house","techno","ambient","lo-fi","lofi","folk",
            "acoustic","jazz","blues","classical","metal","punk","country","k-pop",
            "reggae","reggaeton","afrobeats","latin","gospel","dancehall",
        ]

        let primary: String
        if let specific = tags.first(where: { specificSubgenres.contains($0) }) {
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
            // Launch source-independent candidate fetches immediately — don't stall behind Railway/GetSongBPM.
            // genres, Last.fm similar tracks, and ListenBrainz only need title+artist, not audio features.
            async let featuresTask      = fetchAudioFeaturesWithFallback(song: song)
            async let tagsEarlyTask     = fetchRawTagsCached(song: song)
            async let genresTask        = fetchGenresWithFallback(title: song.title, artist: song.artist)
            async let similarTracksTask = fetchSimilarTracksWithCache(title: song.title, artist: song.artist)
            async let lbTask            = fetchListenBrainzTracks(title: song.title, artist: song.artist)
            async let artistSimilarTask = fetchArtistSimilarCandidates(artist: song.artist)

            // Genre-based tag candidates don't need audio features — start as soon as rawTags arrive.
            // Previously this waited for full feature analysis, adding ~1-2s to the critical path.
            let earlyTags = await tagsEarlyTask
            async let genreTagCandidatesTask = lastFMService.fetchEmotionalTagCandidates(rawTags: earlyTags)

            // Wait for features — needed for BPM correction and feature-dependent searches.
            var features = await featuresTask
            let correctedBPM = normalizeBPM(features.bpm, tags: earlyTags)
            if correctedBPM != features.bpm {
                simiLog("🎚️ Source BPM corrected \(Int(features.bpm)) → \(Int(correctedBPM)) via genre tags")
                let fixed = AudioFeatures(
                    bpm: correctedBPM, energy: features.energy, valence: features.valence,
                    danceability: features.danceability, acousticness: features.acousticness,
                    instrumentalness: features.instrumentalness, liveness: features.liveness,
                    loudness: features.loudness, key: features.key, mode: features.mode,
                    isEstimated: features.isEstimated, isKeyEstimated: features.isKeyEstimated,
                    spectralWarmth: features.spectralWarmth, tonalClarity: features.tonalClarity,
                    vocalPresence: features.vocalPresence, reverbSpace: features.reverbSpace
                )
                features = fixed
                Task { await self.supabase.storeFeatures(title: song.title, artist: song.artist, features: fixed, source: "librosa") }
            }
            self.sourceSong?.audioFeatures = features
            self.lastSourceFeatures = features
            let sourceFeatures = features  // immutable copy — safe to capture in async let / Task

            // Feature-dependent searches + audio-derived emotional tags.
            loadingMessage = "Searching for its emotional kin…"
            async let spotifyRecsTask = spotifyService.getRecommendations(seedTrackID: song.id, features: sourceFeatures)
            async let vectorTask      = supabase.fetchSimilarByVector(embedding: SupabaseCacheService.buildEmbedding(from: sourceFeatures))
            async let dclapTask       = fetchVectorCandidates(embedding: sourceFeatures.dclapEmbedding ?? [])

            let genres = await genresTask
            let highEnergyMarkers1 = ["metal", "hard rock", "punk", "thrash", "hardcore", "grunge"]
            let genreSaysLoud1 = earlyTags.contains { tag in highEnergyMarkers1.contains { tag.lowercased().contains($0) } }
            let audioTags = (genreSaysLoud1 && sourceFeatures.energy < 0.45)
                ? []
                : deriveAudioQueryTags(from: sourceFeatures, genreTags: genres).filter { !$0.isEmpty }
            if !audioTags.isEmpty { simiLog("🎵 Audio-derived query tags: \(audioTags)") }

            // Supplementary fetch for audio-derived tags not already covered by earlyTags (~1-2 tags).
            // Runs concurrently with Spotify recs + vector search — typically done in <0.5s.
            let audioOnlyTags = audioTags.filter { !earlyTags.contains($0) }
            let audioTagCandidatesTask = Task<[(title: String, artist: String)], Never> {
                guard !audioOnlyTags.isEmpty else { return [] }
                return await self.lastFMService.fetchEmotionalTagCandidates(rawTags: audioOnlyTags)
            }

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
            let artistSimilarCandidates = await artistSimilarTask
            self.detectedGenres  = genres
            self.lastGenres      = genres

            let genreTagCandidates = await genreTagCandidatesTask
            let audioTagCandidates = await audioTagCandidatesTask.value
            let tagCandidates      = Self.mergeTracks(primary: genreTagCandidates, secondary: audioTagCandidates)
            let expandedTracks     = Self.mergeTracks(
                primary: Self.mergeTracks(primary: lastFMTracks, secondary: tagCandidates),
                secondary: Self.mergeTracks(
                    primary: Self.mergeTracks(primary: lbTracks, secondary: vectorCandidates),
                    secondary: Self.mergeTracks(primary: dclapCandidates, secondary: artistSimilarCandidates)
                )
            )

            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: expandedTracks,
                sourceSong: song,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prefetchedFeatures: [:]
            )

            guard !merged.isEmpty else {
                errorMessage = "Couldn't find similar songs for this track. Try searching by name instead."
                isLoading = false
                return
            }

            loadingMessage = "Putting it together…"
            let earlyCache = await earlyLookupTask.value
            let enriched = await prefetchCandidateFeatures(
                candidates: merged,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prewarmedCache: earlyCache
            )
            self.recommendations = enriched
            if let song = self.sourceSong {
                history.record(song: song, query: urlString)
            }
            isLoading = false

            // Background: embed result candidates so the catalog self-populates.
            if sourceFeatures.dclapEmbedding != nil {
                Task { await self.embedCandidatesInBackground(songs: merged, sourceFeatures: sourceFeatures) }
            }

            await enrichWithABFeatures(sourceFeatures: sourceFeatures, genres: genres)
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
            guard let song = try await spotifyService.searchTrack(title: title, artist: artist) else {
                throw SimiError.songNotFound
            }
            self.sourceSong = song

            loadingMessage = "Analyzing the feeling…"
            // Launch source-independent candidate fetches immediately.
            async let featuresTask      = fetchAudioFeaturesWithFallback(song: song)
            async let tagsEarlyTask     = fetchRawTagsCached(song: song)
            async let genresTask        = fetchGenresWithFallback(title: song.title, artist: song.artist)
            async let similarTracksTask = fetchSimilarTracksWithCache(title: song.title, artist: song.artist)
            async let lbTask            = fetchListenBrainzTracks(title: song.title, artist: song.artist)
            async let artistSimilarTask = fetchArtistSimilarCandidates(artist: song.artist)

            // Genre-based tag candidates don't need features — start as soon as rawTags arrive.
            let earlyTags = await tagsEarlyTask
            async let genreTagCandidatesTask = lastFMService.fetchEmotionalTagCandidates(rawTags: earlyTags)

            var features = await featuresTask
            let correctedBPM = normalizeBPM(features.bpm, tags: earlyTags)
            if correctedBPM != features.bpm {
                simiLog("🎚️ Source BPM corrected \(Int(features.bpm)) → \(Int(correctedBPM)) via genre tags")
                let fixed = AudioFeatures(
                    bpm: correctedBPM, energy: features.energy, valence: features.valence,
                    danceability: features.danceability, acousticness: features.acousticness,
                    instrumentalness: features.instrumentalness, liveness: features.liveness,
                    loudness: features.loudness, key: features.key, mode: features.mode,
                    isEstimated: features.isEstimated, isKeyEstimated: features.isKeyEstimated,
                    spectralWarmth: features.spectralWarmth, tonalClarity: features.tonalClarity,
                    vocalPresence: features.vocalPresence, reverbSpace: features.reverbSpace
                )
                features = fixed
                Task { await self.supabase.storeFeatures(title: song.title, artist: song.artist, features: fixed, source: "librosa") }
            }
            self.sourceSong?.audioFeatures = features
            self.lastSourceFeatures = features
            let sourceFeatures = features

            loadingMessage = "Searching for its emotional kin…"
            async let spotifyRecsTask = spotifyService.getRecommendations(seedTrackID: song.id, features: sourceFeatures)
            async let vectorTask      = supabase.fetchSimilarByVector(embedding: SupabaseCacheService.buildEmbedding(from: sourceFeatures))
            async let dclapTask2      = fetchVectorCandidates(embedding: sourceFeatures.dclapEmbedding ?? [])

            let genres = await genresTask
            let highEnergyMarkers2 = ["metal", "hard rock", "punk", "thrash", "hardcore", "grunge"]
            let genreSaysLoud2 = earlyTags.contains { tag in highEnergyMarkers2.contains { tag.lowercased().contains($0) } }
            let audioTags = (genreSaysLoud2 && sourceFeatures.energy < 0.45)
                ? []
                : deriveAudioQueryTags(from: sourceFeatures, genreTags: genres).filter { !$0.isEmpty }
            if !audioTags.isEmpty { simiLog("🎵 Audio-derived query tags: \(audioTags)") }

            let audioOnlyTags = audioTags.filter { !earlyTags.contains($0) }
            let audioTagCandidatesTask = Task<[(title: String, artist: String)], Never> {
                guard !audioOnlyTags.isEmpty else { return [] }
                return await self.lastFMService.fetchEmotionalTagCandidates(rawTags: audioOnlyTags)
            }

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
            let artistSimilarCandidates = await artistSimilarTask
            self.detectedGenres  = genres
            self.lastGenres      = genres

            let genreTagCandidates = await genreTagCandidatesTask
            let audioTagCandidates = await audioTagCandidatesTask.value
            let tagCandidates      = Self.mergeTracks(primary: genreTagCandidates, secondary: audioTagCandidates)
            let expandedTracks     = Self.mergeTracks(
                primary: Self.mergeTracks(primary: lastFMTracks, secondary: tagCandidates),
                secondary: Self.mergeTracks(
                    primary: Self.mergeTracks(primary: lbTracks, secondary: vectorCandidates),
                    secondary: Self.mergeTracks(primary: dclapCandidates2, secondary: artistSimilarCandidates)
                )
            )

            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: expandedTracks,
                sourceSong: song,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prefetchedFeatures: [:]
            )

            guard !merged.isEmpty else {
                errorMessage = "Couldn't find similar songs for this track. Try a different song."
                isLoading = false
                return
            }

            loadingMessage = "Putting it together…"
            let earlyCache = await earlyLookupTask.value
            let enriched = await prefetchCandidateFeatures(
                candidates: merged,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prewarmedCache: earlyCache
            )
            self.recommendations = enriched
            history.record(song: song, query: query)
            isLoading = false

            if sourceFeatures.dclapEmbedding != nil {
                Task { await self.embedCandidatesInBackground(songs: merged, sourceFeatures: sourceFeatures) }
            }

            await enrichWithABFeatures(sourceFeatures: sourceFeatures, genres: genres)
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
            // Previously sequential (allLastFMTracks → allGenres → spotifyRecs → allRawTags) added ~2s.
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
            async let allRawTagsTask = withTaskGroup(of: [String].self) { group in
                for song in resolvedSongs { group.addTask { await self.fetchRawTagsCached(song: song) } }
                var tagSet = Set<String>(); for await tags in group { tagSet.formUnion(tags) }; return Array(tagSet)
            }
            async let spotifyRecsTask   = spotifyService.getRecommendations(seedTrackIDs: seedIDs, features: blended)
            async let vectorTask        = supabase.fetchSimilarByVector(embedding: SupabaseCacheService.buildEmbedding(from: blended))
            async let dclapTask3        = fetchVectorCandidates(embedding: blended.dclapEmbedding ?? [])

            let allLastFMTracks  = await lastFMTracksTask
            let allGenres        = await allGenresTask
            let allRawTags       = await allRawTagsTask
            let spotifyRecs      = (try? await spotifyRecsTask) ?? []
            let vectorCandidates = await vectorTask
            let dclapCandidates3 = await dclapTask3

            // Flatten + dedup genres
            var seenGenres = Set<String>()
            let mergedGenres: [Genre] = allGenres.flatMap { $0 }.filter { seenGenres.insert($0.main).inserted }
            self.detectedGenres = mergedGenres
            self.lastGenres = mergedGenres

            // Tag candidates — rawTags available now; audio-derived tags are a small supplementary fetch
            let highEnergyMarkers3 = ["metal", "hard rock", "punk", "thrash", "hardcore", "grunge"]
            let genreSaysLoud3 = allRawTags.contains { tag in highEnergyMarkers3.contains { tag.lowercased().contains($0) } }
            let audioTags = (genreSaysLoud3 && blended.energy < 0.45)
                ? []
                : deriveAudioQueryTags(from: blended).filter { !$0.isEmpty }
            if !audioTags.isEmpty { simiLog("🎵 Audio-derived query tags (blend): \(audioTags)") }

            async let genreTagCandidatesTask = lastFMService.fetchEmotionalTagCandidates(rawTags: allRawTags)
            let audioOnlyTags = audioTags.filter { !allRawTags.contains($0) }
            let audioTagCandidatesTask2 = Task<[(title: String, artist: String)], Never> {
                guard !audioOnlyTags.isEmpty else { return [] }
                return await self.lastFMService.fetchEmotionalTagCandidates(rawTags: audioOnlyTags)
            }

            let genreTagCandidates = await genreTagCandidatesTask
            let audioTagCandidates = await audioTagCandidatesTask2.value
            let tagCandidates      = Self.mergeTracks(primary: genreTagCandidates, secondary: audioTagCandidates)
            let expandedTracks     = Self.mergeTracks(
                primary: Self.mergeTracks(primary: allLastFMTracks, secondary: tagCandidates),
                secondary: Self.mergeTracks(primary: vectorCandidates, secondary: dclapCandidates3)
            )

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
            let enriched = await prefetchCandidateFeatures(
                candidates: merged,
                sourceFeatures: blended,
                genres: mergedGenres,
                seedFeatures: allFeatures
            )
            self.recommendations = enriched

            for song in resolvedSongs {
                history.record(song: song, query: "\(song.title) \(song.artist)")
            }
            isLoading = false

            if blended.dclapEmbedding != nil {
                Task { await self.embedCandidatesInBackground(songs: merged, sourceFeatures: blended) }
            }

            await enrichWithABFeatures(sourceFeatures: blended, genres: mergedGenres, seedFeatures: allFeatures)

        } catch let error as SimiError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Something went wrong. Please try again."
            simiLog("Multi-seed search error:", error)
        }

        isLoading = false
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

        // 2. Railway librosa — full measured analysis (BPM, energy, valence, danceability,
        //    acousticness, instrumentalness, liveness, loudness, key, mode via FFT/chroma/MFCC).
        //    Falls through silently when Railway is unreachable so tag estimation takes over.
        if let previewURL {
            if let pyFeatures = await simiAudioService.analyzePreview(url: previewURL) {
                simiLog("✅ Python audio analyzer: \(song.title) — \(Int(pyFeatures.bpm))BPM energy=\(String(format: "%.2f", pyFeatures.energy)) valence=\(String(format: "%.2f", pyFeatures.valence))")
                Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: pyFeatures, source: "librosa") }
                return pyFeatures
            }
            // Service unreachable or analysis failed — fall through to local analyzer + tag estimation.
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
                let merged = AudioFeatures(
                    bpm:              tagEstimated.bpm,
                    energy:           mergedEnergy,
                    valence:          mergedValence,
                    danceability:     tagEstimated.danceability,
                    acousticness:     tagEstimated.acousticness,
                    instrumentalness: tagEstimated.instrumentalness,
                    liveness:         tagEstimated.liveness,
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
                acousticness:     0.0,
                instrumentalness: 0.0,
                liveness:         0.0,
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

        // Row 1: Emotional weight — valence (prefer DEAM-regressed value, consistent with computeSimilarity)
        // Gate: threshold unchanged (0.20), but isEstimated check removed — estimated songs show
        // softer descriptors instead of nothing.
        let srcValence = source.valenceEssentia ?? source.valence
        let tgtValence = target.valenceEssentia ?? target.valence
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
    private func enrichWithABFeatures(
        sourceFeatures: AudioFeatures,
        genres: [Genre],
        seedFeatures: [AudioFeatures] = []
    ) async {
        let snapshot = recommendations
        guard !snapshot.isEmpty else { return }

        simiLog("🎵 Starting tag-feature enrichment for \(snapshot.count) songs...")

        // Fill preview URLs so the audio player can play songs.
        await fillMissingPreviewURLs()

        var tagUpdates: [(index: Int, features: AudioFeatures)] = []

        await withTaskGroup(of: (Int, AudioFeatures?).self) { group in
            for (index, song) in snapshot.enumerated() {
                group.addTask {
                    // ── Priority 1: Supabase feature cache ──
                    // Songs analyzed in a previous session are stored here; skip Last.fm
                    // entirely for them. No stagger needed — cache hit is a single indexed read.
                    if let cached = await self.supabase.lookupFeatures(title: song.title, artist: song.artist) {
                        simiLog("✅ Supabase cache hit (enrichment): \"\(song.title)\"")
                        return (index, cached)
                    }

                    // ── Priority 2: AcousticBrainz (pre-2022 real measurements) ──
                    // MBID lookup short-circuits on miss for modern tracks (one fast indexed GET).
                    // AB fetch only fires on MBID hit. Returns isEstimated=false by default.
                    if let mbid = await self.listenBrainzService.resolveACRMBID(title: song.title, artist: song.artist),
                       let abFeatures = await self.acousticBrainzService.fetchFeatures(mbid: mbid) {
                        simiLog("✅ AcousticBrainz features: \"\(song.title)\"")
                        return (index, abFeatures)
                    }

                    // ── Priority 3: tag estimation ──
                    // Stagger requests to respect Last.fm rate limits.
                    // Capped at index 15 (300ms max) — was unbounded × 20ms (760ms for song 38).
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(min(index, 15)) * 20_000_000)
                    }
                    // Estimate from Last.fm genre/mood tags — covers nearly everything
                    let tags = await self.lastFMService.fetchRawTags(
                        title: song.title, artist: song.artist
                    )
                    guard var estimated = await self.estimateFeaturesFromTags(tags) else {
                        return (index, nil)
                    }
                    simiLog("🏷️ Tag-estimated features for \"\(song.title)\": \(tags.prefix(3).joined(separator: ", "))")

                    // Fetch musical key from GetSongBPM — makes the Same Key filter work.
                    // Capped to top 20 songs: protects the 500 req/day quota and keeps
                    // tail latency bounded (lower-ranked songs rarely need key accuracy).
                    if index < 20,
                       let songData = await self.getSongBPMService.fetchSongData(title: song.title, artist: song.artist),
                       let key = songData.key, let mode = songData.mode {
                        // Apply the same BPM correction used for the source song so recommended
                        // songs aren't penalized by doubled/halved GetSongBPM readings.
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

                    return (index, estimated)
                }
            }

            for await (index, features) in group {
                guard let features = features else { continue }
                tagUpdates.append((index: index, features: features))
            }
        }

        // ── STAGE 1: apply tag estimates immediately — UI renders before librosa finishes ──
        var enrichedCount = 0
        for update in tagUpdates {
            guard update.index < recommendations.count else { continue }
            let (score, reasons) = seedFeatures.count > 1
                ? computeSimilarityMultiSeed(seeds: seedFeatures, target: update.features, genres: genres)
                : computeSimilarity(source: sourceFeatures, target: update.features, genres: genres)
            recommendations[update.index].audioFeatures   = update.features
            recommendations[update.index].similarityScore = score
            recommendations[update.index].matchReasons    = reasons
            let explanationSource = seedFeatures.count > 1 ? centroid(of: seedFeatures) : sourceFeatures
            recommendations[update.index].matchExplanation = buildMatchExplanation(
                source: explanationSource,
                target: update.features,
                sourceGenres: genres,
                targetGenre: recommendations[update.index].genre
            )
            enrichedCount += 1
        }

        if enrichedCount > 0 {
            simiLog("✅ Background tag enrichment updated \(enrichedCount) songs")
        }

        let coverageRatio = Double(enrichedCount) / Double(max(1, snapshot.count))
        if coverageRatio >= 0.3 {
            let before = recommendations.count
            recommendations = recommendations.filter { $0.similarityScore >= 0.62 }
            let removed = before - recommendations.count
            if removed > 0 {
                simiLog("🔪 Quality filter removed \(removed) low-scoring songs (threshold 0.62)")
            }
            // Re-sort after quality filter so the highest-scoring songs surface to the top.
            recommendations.sort { $0.similarityScore > $1.similarityScore }
        }

        simiLog("✅ Tag enrichment done: \(enrichedCount)/\(snapshot.count) songs got features")

        // ── STAGE 2: librosa enrichment for top candidates ──
        // Check cancellation first — a new search may have fired during Stage 1.
        guard !Task.isCancelled else {
            simiLog("⚠️ Librosa enrichment cancelled before Stage 2 — new search started")
            return
        }

        let librosaTargets = recommendations
            .prefix(10)
            .enumerated()
            .compactMap { (i, song) -> (index: Int, url: String)? in
                guard let url = song.previewURL,
                      song.audioFeatures?.isEstimated != false else { return nil }
                return (index: i, url: url)
            }

        guard !librosaTargets.isEmpty else {
            simiLog("🎵 No librosa candidates (all measured or no preview URLs)")
            return
        }

        simiLog("🎵 Starting librosa enrichment for \(librosaTargets.count) candidates (max 2 concurrent)...")

        // Chunk into pairs to keep Railway at ≤2 concurrent requests.
        // Python GIL serializes librosa; >2 concurrent causes queue buildup and timeouts.
        let chunks = stride(from: 0, to: librosaTargets.count, by: 2).map {
            Array(librosaTargets[$0..<min($0 + 2, librosaTargets.count)])
        }

        var librosaSucceeded = 0
        for chunk in chunks {
            guard !Task.isCancelled else {
                simiLog("⚠️ Librosa enrichment cancelled mid-run — new search started")
                return
            }

            let batchResults: [(Int, AudioFeatures?)] = await withTaskGroup(of: (Int, AudioFeatures?).self) { group in
                for (idx, url) in chunk {
                    group.addTask {
                        guard !Task.isCancelled else { return (idx, nil) }
                        let features = await self.simiAudioService.analyzePreview(url: url)
                        return (idx, features)
                    }
                }
                var results: [(Int, AudioFeatures?)] = []
                for await result in group { results.append(result) }
                return results
            }

            for (idx, features) in batchResults {
                guard let features, idx < recommendations.count else { continue }
                let song = recommendations[idx]
                let (score, reasons) = seedFeatures.count > 1
                    ? computeSimilarityMultiSeed(seeds: seedFeatures, target: features, genres: genres)
                    : computeSimilarity(source: sourceFeatures, target: features, genres: genres)
                recommendations[idx].audioFeatures   = features
                recommendations[idx].similarityScore = score
                recommendations[idx].matchReasons    = reasons
                let explanationSource = seedFeatures.count > 1 ? centroid(of: seedFeatures) : sourceFeatures
                recommendations[idx].matchExplanation = buildMatchExplanation(
                    source: explanationSource,
                    target: features,
                    sourceGenres: genres,
                    targetGenre: recommendations[idx].genre
                )
                // Write to Supabase so the next time this song appears it's a cache hit — no Railway call.
                Task { await self.supabase.storeFeatures(title: song.title, artist: song.artist, features: features, source: "librosa") }
                librosaSucceeded += 1
            }
        }

        if librosaSucceeded > 0 {
            // Re-sort after librosa upgrades so measured-feature winners surface to the top.
            recommendations.sort { $0.similarityScore > $1.similarityScore }
            simiLog("✅ Librosa Stage 2 done: \(librosaSucceeded)/\(librosaTargets.count) songs upgraded, re-sorted")
        } else {
            simiLog("⚠️ Librosa Stage 2: 0/\(librosaTargets.count) — Railway may be cold or busy")
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
            .filter { $0.element.previewURL == nil }
            .map { (index: $0.offset, title: $0.element.title, artist: $0.element.artist) }
        guard !needsURL.isEmpty else { return }

        simiLog("🎵 Fetching \(needsURL.count) iTunes preview URLs in parallel…")
        let updates: [(Int, String)] = await withTaskGroup(of: (Int, String?).self) { group in
            for item in needsURL {
                group.addTask {
                    var url = await self.itunesService.fetchPreviewURL(title: item.title, artist: item.artist)
                    if url == nil {
                        url = await self.deezerService.fetchPreviewURL(title: item.title, artist: item.artist)
                    }
                    return (item.index, url)
                }
            }
            var result: [(Int, String)] = []
            for await (index, url) in group {
                if let url { result.append((index, url)) }
            }
            return result
        }

        guard !updates.isEmpty else { return }
        for (index, url) in updates {
            guard index < recommendations.count else { continue }
            recommendations[index].previewURL = url
        }
        simiLog("🎵 Preview URLs filled: \(updates.count)/\(needsURL.count)")
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
            results.append(SimilarSong(
                id: song.id, title: song.title, artist: song.artist,
                albumArt: song.albumArt, spotifyURL: song.spotifyURL, previewURL: song.previewURL,
                genre: genres.first ?? Genre(main: "Unknown"),
                audioFeatures: features, similarityScore: s, matchReasons: reasons
            ))
        }

        // ── Source 2: Last.fm similar tracks + emotional tag pool ──
        // Resolve in parallel, then score sequentially to avoid races on `seen`.
        // Limit raised to 40 to accommodate the tag-expanded pool (was 20).
        let lastFMSongs: [Song] = await withTaskGroup(of: Song?.self) { group in
            for (title, artist) in lastFMTracks.prefix(40) {
                group.addTask { try? await self.spotifyService.searchTrack(title: title, artist: artist) }
            }
            var songs: [Song] = []
            for await song in group { if let song { songs.append(song) } }
            return songs
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
            results.append(SimilarSong(
                id: song.id, title: song.title, artist: song.artist,
                albumArt: song.albumArt, spotifyURL: song.spotifyURL, previewURL: song.previewURL,
                genre: genres.first ?? Genre(main: "Unknown"),
                audioFeatures: cachedFeatures, similarityScore: s, matchReasons: reasons
            ))
        }

        results.sort { $0.similarityScore > $1.similarityScore }
        return applyArtistDiversity(results, sourceArtist: sourceSong.artist)
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
        prewarmedCache: [String: AudioFeatures] = [:]
    ) async -> [SimilarSong] {
        guard !candidates.isEmpty else { return candidates }

        // Race: enrichment vs. 7s timeout. Returns unenriched candidates on timeout.
        return await withTaskGroup(of: [SimilarSong].self) { group in
            // Task A: do the actual enrichment
            group.addTask {
                await self.runPrefetchEnrichment(
                    candidates: candidates,
                    sourceFeatures: sourceFeatures,
                    genres: genres,
                    seedFeatures: seedFeatures,
                    prewarmedCache: prewarmedCache
                )
            }
            // Task B: 7-second timeout fallback
            group.addTask {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
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
        prewarmedCache: [String: AudioFeatures] = [:]
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
                    let tags = await self.lastFMService.fetchRawTags(title: song.title, artist: song.artist)
                    let estimated = await self.estimateFeaturesFromTags(tags)
                    return (index, estimated)
                }
            }
            var updates: [(Int, AudioFeatures?)] = []
            for await update in group { updates.append(update) }
            return updates
        }

        let explanationSource = seedFeatures.count > 1 ? centroid(of: seedFeatures) : sourceFeatures

        for (idx, features) in fetched {
            guard let features, idx < result.count else { continue }
            let (score, reasons) = seedFeatures.count > 1
                ? computeSimilarityMultiSeed(seeds: seedFeatures, target: features, genres: genres)
                : computeSimilarity(source: sourceFeatures, target: features, genres: genres)
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

        return result.sorted { $0.similarityScore > $1.similarityScore }
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
            let limit = key == sourceKey ? 2 : 3
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
        case metal, rock, blues, hiphop, rnb, pop, electronic, folk, jazz, classical, unknown

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
            case .unknown:    return ""
            }
        }
    }

    private func detectGenreFamily(_ genres: [Genre]) -> GenreFamily {
        let names = genres.map { $0.main.lowercased() }
        func any(_ check: (String) -> Bool) -> Bool { names.contains(where: check) }
        // Blues wins over rock/metal when any tag in the array is blues — Last.fm often returns
        // "Classic Rock" first even for blues artists, so scan the whole list.
        if any({ $0.contains("blues") }) { return .blues }
        if any({ $0.contains("metal") || $0.contains("thrash") || $0.contains("metalcore") || $0.contains("deathcore") || $0.contains("doom") }) { return .metal }
        if any({ $0.contains("hard rock") || $0.contains("punk") || $0.contains("grunge") || $0.contains("rock") || $0.contains("hardcore") || $0.contains("shoegaze") || $0.contains("post-rock") }) { return .rock }
        if any({ $0.contains("hip") || $0.contains("rap") || $0.contains("trap") || $0.contains("drill") || $0.contains("grime") || $0.contains("phonk") }) { return .hiphop }
        if any({ $0.contains("r&b") || $0.contains("rnb") || $0.contains("soul") || $0.contains("funk") || $0.contains("gospel") || $0.contains("slow jam") || $0.contains("neo-soul") }) { return .rnb }
        if any({ $0.contains("jazz") }) { return .jazz }
        if any({ $0.contains("classical") || $0.contains("orchestral") }) { return .classical }
        if any({ $0.contains("electronic") || $0.contains("edm") || $0.contains("house") || $0.contains("techno") || $0.contains("trance") || $0.contains("drum and bass") || $0.contains("dubstep") || $0.contains("synthwave") || $0.contains("synth") }) { return .electronic }
        if any({ $0.contains("folk") || $0.contains("acoustic") || $0.contains("country") || $0.contains("americana") || $0.contains("bluegrass") || $0.contains("singer-songwriter") }) { return .folk }
        if any({ $0.contains("pop") }) { return .pop }
        return .unknown
    }

    // ──────────────────────────────────────────────
    // MARK: - Similarity Score Computation
    // ──────────────────────────────────────────────

    // Scoring philosophy: match the *emotional imprint* of a song, not its technical fingerprint.
    // People don't want the same BPM — they want the same feeling.
    //
    // Weights (sum = 1.00):
    //   valence        0.30 — emotional color; prefers valenceEssentia (DEAM) over Spotify proxy
    //   arousal        0.10 — calm/relaxed vs energetic/excited (new DEAM axis, distinct from energy)
    //   danceability   0.20 — groove/rhythm feel (slow jam vs. dance track within the same mood)
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
    private func computeSimilarity(
        source: AudioFeatures,
        target: AudioFeatures?,
        genres: [Genre]
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
            // Mood label — only use directional labels for clearly skewed valence.
            // Mid-range R&B/hip-hop estimates sit around 0.50–0.68; labelling that
            // range "Dark Mood" is wrong for upbeat songs. Use a neutral label instead.
            let srcValenceForLabel = source.valenceEssentia ?? source.valence
            if srcValenceForLabel < 0.42 {
                reasons.append(.darkMood)       // Genuinely dark: metal, emo, sad rap
            } else if srcValenceForLabel > 0.72 && source.energy > 0.50 {
                reasons.append(.upbeatMood)     // Genuinely bright AND energetic: pop, dance, k-pop
            } else {
                reasons.append(.mood)           // Warm, mellow, or mid-range: "Same Mood"
            }
        }

        // Valence — the emotional color (happy / dark / bittersweet).
        // Prefer DEAM-regressed valence (human-annotated) over Spotify proxy when available.
        let srcValence = source.valenceEssentia ?? source.valence
        let tgtValence = target.valenceEssentia ?? target.valence
        let valenceDiff = abs(srcValence - tgtValence)
        let valenceScore = 1.0 - valenceDiff
        totalScore += valenceScore * 0.30
        // Tighter threshold when source is measured but target is tag-estimated:
        // soul-genre centroids cluster close enough that a 0.15 gate produces false "Same Mood"
        // labels between emotionally opposite songs (e.g. Tar Baby vs Respect).
        let moodThreshold = (!source.isEstimated && target.isEstimated) ? 0.10 : 0.15
        if !bothEstimated && valenceDiff < moodThreshold {
            // Emotionally specific: name the actual mood shared, not just "Same Mood"
            let avgValence = (srcValence + tgtValence) / 2
            let avgEnergy  = (source.energy + target.energy) / 2
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

        // Arousal — calm/relaxed vs energetic/excited (DEAM regression).
        // Distinct from energy: a tense quiet string quartet is high arousal / low energy.
        // Only applied when both songs have Essentia arousal; falls through silently otherwise.
        if let srcArousal = source.arousal, let tgtArousal = target.arousal {
            let arousalDiff = abs(srcArousal - tgtArousal)
            totalScore += (1.0 - arousalDiff) * 0.10
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
        let danceWeight = source.energy < 0.45 ? 0.10 : 0.20
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
        if source.energy >= 0.30 {
            let energyGap = target.energy - source.energy
            if energyGap > 0.14 {
                let gapPenalty = min(0.10, (energyGap - 0.14) * 2.0)
                totalScore = max(0, totalScore - gapPenalty)
            }
        }

        // BPM — disabled: arousal + danceability already capture tempo feel. Keeping the
        // reason tag so "Same Tempo" still surfaces in the UI when BPM is very close.
        let bpmDiff = abs(source.bpm - target.bpm)
        if bpmDiff <= 15 { reasons.append(.bpm) }

        // MFCC cosine similarity — timbral texture (warmth, breathiness, roughness, instrument blend).
        // Captures acoustic "feel" that valence/energy don't express.
        // Only applied when both songs have MFCC data from Railway backend.
        if let srcMFCC = source.mfccMean, let tgtMFCC = target.mfccMean,
           srcMFCC.count == tgtMFCC.count, !srcMFCC.isEmpty {
            let cosine = mfccCosineSimilarity(srcMFCC, tgtMFCC)  // [-1, 1]
            let mfccScore = (cosine + 1.0) / 2.0                 // → [0, 1]
            totalScore += mfccScore * 0.08
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

        // Normalize by used weight. When MFCC, arousal, or chroma entropy are
        // unavailable (0.20 combined), raw scores are capped at ~0.80 even for a
        // perfect match. Dividing by the weight actually earned restores the full
        // 0–1 scale so songs that feel similar score like it.
        let missedWeight = (source.arousal == nil || target.arousal == nil ? 0.10 : 0.0)
                         + (source.mfccMean == nil || target.mfccMean == nil ? 0.08 : 0.0)
                         + (source.chromaEntropy == nil || target.chromaEntropy == nil ? 0.02 : 0.0)
        let usedWeight = 1.0 - missedWeight
        if usedWeight > 0 && usedWeight < 1.0 {
            totalScore = min(1.0, totalScore / usedWeight)
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
        case (false, true):  adjustedScore = totalScore   // real source vs centroid — trust the score
        case (false, false): adjustedScore = totalScore
        }

        // For estimated features the first two slots are energy + mood — far more useful
        // than a generic "Same Genre" label. Only prepend genre for measured features.
        if !bothEstimated {
            reasons.insert(.genre, at: 0)
        }
        return (adjustedScore, Array(reasons.prefix(3)))
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
        genres: [Genre]
    ) -> (Double, [MatchReason]) {
        guard !seeds.isEmpty else { return (0.5, [.genre]) }
        guard seeds.count > 1 else {
            return computeSimilarity(source: seeds[0], target: target, genres: genres)
        }

        var totalScore = 0.0
        var reasonFrequency: [MatchReason: Int] = [:]

        for seed in seeds {
            let (score, reasons) = computeSimilarity(source: seed, target: target, genres: genres)
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
    private func deriveAudioQueryTags(from features: AudioFeatures, genreTags: [Genre] = []) -> [String] {
        guard !features.isEstimated else { return [] }

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
            return ["upbeat", "energetic"]                        // genuinely bright AND energetic: pop, dance
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
        if hasFastTag && bpm < 120 {
            let doubled = bpm * 2
            // Don't double into the ambiguous 135–160 range for generic trap/rap —
            // that zone overlaps real half-time reads AND correct tempos.
            // Fast genres like dnb (170+), hardstyle (150+), hyperpop (145+) are exempt.
            let isVeryFastGenre = tags.contains { tag in
                ["drum and bass", "dnb", "hardstyle", "hardcore", "hyperpop", "breakcore", "rave", "trance"]
                    .contains { tag.contains($0) }
            }
            if isVeryFastGenre || doubled <= 138 {
                simiLog("🎚️ BPM doubled \(Int(bpm)) → \(Int(doubled)) (fast genre tag, BPM too low)")
                return doubled
            }
            // Doubling would land in the ambiguous 139–175 range for normal trap/rap —
            // leave the value as-is and let the BPM source's reading stand.
            simiLog("🎚️ BPM doubling skipped \(Int(bpm)) → would be \(Int(doubled)) (ambiguous range for non-extreme genre)")
        }

        guard bpm > 130 else { return bpm }  // Only fast readings need further correction

        // Tags that reliably indicate a slow tempo
        let slowIndicators = [
            "r&b", "rnb", "soul", "neo-soul", "neo soul", "chill", "chillout", "chill out",
            "ambient", "lo-fi", "lofi", "blues", "gospel", "ballad", "slow jam", "slow",
            "bedroom pop", "dream pop", "folk", "acoustic", "romantic", "melancholic",
            "sad", "relaxing", "smooth", "laid back", "downtempo", "trip hop"
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
        let stronglySlowTags: Set<String> = ["ballad", "slow jam", "slow jams", "gospel", "blues"]
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

    /// Fire-and-forget: sends the top results to Railway /embed-candidates so their
    /// DCLAP embeddings are computed and written to Supabase track_embeddings.
    /// The catalog self-populates from actual user searches — no manual seeding needed.
    private func embedCandidatesInBackground(songs: [SimilarSong], sourceFeatures: AudioFeatures) async {
        let candidates = songs.prefix(15).compactMap { song -> [String: Any]? in
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

        var request = URLRequest(url: URL(string: "https://simi-audio-analyzer-production.up.railway.app/embed-candidates")!)
        request.httpMethod  = "POST"
        request.httpBody    = body
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        _ = try? await URLSession.shared.data(for: request)
    }

    // ──────────────────────────────────────────────
    // MARK: - DCLAP Vector Candidate Fetch
    // ──────────────────────────────────────────────

    /// Sends a 512-dim DCLAP embedding to the Railway /vector-search endpoint and
    /// returns (title, artist) pairs for the nearest neighbours in track_embeddings.
    /// Returns [] when the source song has no embedding or the backend is unreachable.
    private func fetchVectorCandidates(embedding: [Double]) async -> [(title: String, artist: String)] {
        guard !embedding.isEmpty else { return [] }
        let payload: [String: Any] = [
            "embedding":   embedding,
            "matchCount":  20,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return [] }

        var request = URLRequest(url: URL(string: "https://simi-audio-analyzer-production.up.railway.app/vector-search")!)
        request.httpMethod  = "POST"
        request.httpBody    = body
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let response  = try JSONDecoder().decode(VectorSearchResponse.self, from: data)
            return response.results.map { (title: $0.title, artist: $0.artist) }
        } catch {
            simiLog("⚠️ DCLAP vector-search failed: \(error)")
            return []
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Reset
    // ──────────────────────────────────────────────

    func reset() {
        sourceSong = nil
        blendedSongs = []
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
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:    return "That doesn't look like a valid song link. Try pasting a Spotify, YouTube, or SoundCloud URL."
        case .authFailed:    return "Couldn't connect to Spotify. Check your internet connection and try again."
        case .songNotFound:  return "Couldn't find that song on Spotify. Try a different link."
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}
