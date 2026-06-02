// RecommendationEngine.swift
// Simi — Music Discovery App
//
// The brain of Simi. Coordinates Spotify, Last.fm, Deezer, MusicBrainz, and AcousticBrainz
// to produce a ranked list of similar songs with real audio feature data.
//
// Audio feature priority chain:
//   1. Spotify audio-features  (full features — restricted until Extended Quota Mode)
//   2. AcousticBrainz via MusicBrainz  (full features — community data, free, open)
//   3. Deezer  (BPM only, neutral energy/valence)
//   4. Neutral defaults  (app still works, just less accurate scoring)
//
// Recommendation flow:
//   1. User pastes URL or types a title → resolve Spotify track
//   2. Fetch source song audio features (priority chain above)
//   3. Fetch Last.fm similar tracks + genre tags + Spotify recs in parallel
//   4. Merge, score, display results immediately
//   5. Enrich recommended songs with AcousticBrainz in the background
//      (vibe graph populates progressively as features arrive)

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
    // acousticBrainzService removed — AB deprecated 2022, disabled in fetchAudioFeaturesWithFallback
    private let itunesService       = iTunesService()
    private let getSongBPMService   = GetSongBPMService()
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
        print("⚠️ Last.fm returned no genres for \"\(title)\" — trying iTunes")
        let iTunesGenres = await itunesService.fetchGenre(title: title, artist: artist)
        if !iTunesGenres.isEmpty {
            print("✅ iTunes genre fallback: \(iTunesGenres.first?.main ?? "?")")
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
        let known = ["indie pop","dream pop","bedroom pop","indie rock","alt-rock","alternative",
                     "rock","pop","hip-hop","hip hop","rap","trap","r&b","rnb","soul","neo-soul",
                     "funk","electronic","edm","house","techno","ambient","lo-fi","lofi","folk",
                     "acoustic","jazz","blues","classical","metal","punk","country","k-pop"]
        let matched = tags.filter { tag in known.contains { tag.contains($0) || $0.contains(tag) } }
        let primary = matched.first ?? tags.first ?? "Unknown"
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
        loadingMessage = "Finding song…"
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

            loadingMessage = "Analyzing audio…"
            let features = await fetchAudioFeaturesWithFallback(song: song)
            self.sourceSong?.audioFeatures = features
            self.lastSourceFeatures = features

            loadingMessage = "Finding similar songs…"
            async let genresTask      = fetchGenresWithFallback(title: song.title, artist: song.artist)
            async let spotifyRecsTask = spotifyService.getRecommendations(seedTrackID: song.id, features: features)
            async let similarTracksTask = fetchSimilarTracksWithCache(title: song.title, artist: song.artist)
            async let rawTagsTask     = fetchRawTagsCached(song: song)

            let (genres, spotifyRecs, lastFMTracks) = try await (genresTask, spotifyRecsTask, similarTracksTask)
            let rawTags = await rawTagsTask
            self.detectedGenres = genres
            self.lastGenres = genres

            let tagCandidates = await lastFMService.fetchEmotionalTagCandidates(rawTags: rawTags)
            let expandedTracks = Self.mergeTracks(primary: lastFMTracks, secondary: tagCandidates)

            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: expandedTracks,
                sourceSong: song,
                sourceFeatures: features,
                genres: genres
            )

            guard !merged.isEmpty else {
                errorMessage = "Couldn't find similar songs for this track. Try searching by name instead."
                isLoading = false
                return
            }

            self.recommendations = merged

            // Only save to history once we know we have actual results
            if let song = self.sourceSong {
                history.record(song: song, query: urlString)
            }

            // Keep loading until enrichment finishes so results appear already sorted correctly.
            // Users see a spinner instead of a jarring re-sort 5 seconds after the list loads.
            loadingMessage = "Ranking matches…"
            await enrichWithABFeatures(sourceFeatures: features, genres: genres)
            isLoading = false
            return

        } catch let error as SimiError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Something went wrong. Please try again."
            print("Recommendation error:", error)
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
        loadingMessage = "Finding song…"
        errorMessage = nil
        recommendations = []
        sourceSong = nil
        blendedSongs = []

        do {
            guard let song = try await spotifyService.searchTrack(title: title, artist: artist) else {
                throw SimiError.songNotFound
            }
            self.sourceSong = song

            loadingMessage = "Analyzing audio…"
            let features = await fetchAudioFeaturesWithFallback(song: song)
            self.sourceSong?.audioFeatures = features
            self.lastSourceFeatures = features

            loadingMessage = "Finding similar songs…"
            async let genresTask      = fetchGenresWithFallback(title: song.title, artist: song.artist)
            async let spotifyRecsTask = spotifyService.getRecommendations(seedTrackID: song.id, features: features)
            async let similarTracksTask = fetchSimilarTracksWithCache(title: song.title, artist: song.artist)
            async let rawTagsTask     = fetchRawTagsCached(song: song)

            let (genres, spotifyRecs, lastFMTracks) = try await (genresTask, spotifyRecsTask, similarTracksTask)
            let rawTags = await rawTagsTask
            self.detectedGenres = genres
            self.lastGenres = genres

            let tagCandidates = await lastFMService.fetchEmotionalTagCandidates(rawTags: rawTags)
            let expandedTracks = Self.mergeTracks(primary: lastFMTracks, secondary: tagCandidates)

            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: expandedTracks,
                sourceSong: song,
                sourceFeatures: features,
                genres: genres
            )

            guard !merged.isEmpty else {
                errorMessage = "Couldn't find similar songs for this track. Try a different song."
                isLoading = false
                return
            }

            self.recommendations = merged
            history.record(song: song, query: query)

            loadingMessage = "Ranking matches…"
            await enrichWithABFeatures(sourceFeatures: features, genres: genres)
            isLoading = false
            return

        } catch let error as SimiError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Something went wrong. Please try again."
            print("Text search error:", error)
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

            // ── Step 3: Fetch Last.fm data + Spotify recs using all seed IDs ──
            loadingMessage = "Finding similar songs…"
            let seedIDs = resolvedSongs.map { $0.id }

            // Gather Last.fm similar tracks for all seeds (parallel, merge+dedup)
            let allLastFMTracks: [(title: String, artist: String)] = await withTaskGroup(
                of: [(title: String, artist: String)].self
            ) { group in
                for song in resolvedSongs {
                    group.addTask {
                        (try? await self.lastFMService.fetchSimilarTracks(
                            title: song.title, artist: song.artist, limit: 15
                        )) ?? []
                    }
                }
                var merged: [(title: String, artist: String)] = []
                var seen = Set<String>()
                for await tracks in group {
                    for t in tracks {
                        let key = "\(t.title.lowercased())|\(t.artist.lowercased())"
                        if seen.insert(key).inserted { merged.append(t) }
                    }
                }
                return merged
            }

            // Genres: blend across all seeds
            let allGenres: [[Genre]] = await withTaskGroup(of: [Genre].self) { group in
                for song in resolvedSongs {
                    group.addTask {
                        await self.fetchGenresWithFallback(title: song.title, artist: song.artist)
                    }
                }
                var all: [[Genre]] = []
                for await g in group { all.append(g) }
                return all
            }
            // Flatten + dedup genres, prioritise first
            var seenGenres = Set<String>()
            let mergedGenres: [Genre] = allGenres.flatMap { $0 }.filter {
                seenGenres.insert($0.main).inserted
            }
            self.detectedGenres = mergedGenres
            self.lastGenres = mergedGenres

            let spotifyRecs = try await spotifyService.getRecommendations(
                seedTrackIDs: seedIDs,
                features: blended
            )

            // Expand candidate pool with emotional tag queries across all seeds
            let allRawTags: [String] = await withTaskGroup(of: [String].self) { group in
                for song in resolvedSongs {
                    group.addTask { await self.fetchRawTagsCached(song: song) }
                }
                var tagSet = Set<String>()
                for await tags in group { tagSet.formUnion(tags) }
                return Array(tagSet)
            }
            let tagCandidates = await lastFMService.fetchEmotionalTagCandidates(rawTags: allRawTags)
            let expandedTracks = Self.mergeTracks(primary: allLastFMTracks, secondary: tagCandidates)

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
            self.recommendations = merged

            // Record history entries for each seed song
            for song in resolvedSongs {
                history.record(song: song, query: "\(song.title) \(song.artist)")
            }

            loadingMessage = "Ranking matches…"
            await enrichWithABFeatures(sourceFeatures: blended, genres: mergedGenres, seedFeatures: allFeatures)

        } catch let error as SimiError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Something went wrong. Please try again."
            print("Multi-seed search error:", error)
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
                print("🎬 YouTube oEmbed: \"\(title)\" by \(artist)")
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
                print("🔊 SoundCloud oEmbed: \"\(title)\" by \(artist)")
            }

            guard !title.isEmpty else { throw SimiError.songNotFound }

            // Try to find the track on Spotify for full metadata + album art
            if let song = try? await spotifyService.searchTrack(title: title, artist: artist) {
                return song
            }

            // SoundCloud-exclusive track — not on Spotify.
            // Build a synthetic Song so Last.fm-based recommendations can still work.
            print("⚠️ SoundCloud track not found on Spotify — using Last.fm-only recommendations for \"\(title)\"")
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

        // 0. Supabase feature cache — check before hitting any API
        if let cached = await supabase.lookupFeatures(title: song.title, artist: song.artist) {
            return cached
        }

        // 1. Spotify (full features — will work once Extended Quota Mode is approved)
        if let features = try? await spotifyService.fetchAudioFeatures(trackID: song.id) {
            print("✅ Spotify audio features: \(song.title)")
            Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: features, source: "spotify") }
            return features
        }

        // 1.5. Preview audio analysis — real energy/valence from the 30s preview clip.
        //      Runs after Spotify fails. Never runs in the background enrichment loop.
        var audioMeasurements: AudioMeasurements? = nil
        if let previewURL = song.previewURL {
            audioMeasurements = await previewAnalyzer.analyze(previewURL: previewURL)
        }

        // 2. AcousticBrainz — DISABLED (deprecated 2022, adds 2-4s latency for sparse coverage)
        //    Re-enable if Spotify Extended Quota Mode is granted and AB coverage improves.
        // if let mbid = await musicBrainzService.findMBID(title: song.title, artist: song.artist),
        //    let features = await acousticBrainzService.fetchFeatures(mbid: mbid) {
        //     print("✅ AcousticBrainz features: \(song.title)")
        //     return features
        // }

        // 3. BPM — try Deezer first, fall back to GetSongBPM if Deezer returns nothing.
        //    We DON'T return here — we still need tag estimation for energy/valence.
        //    Returning neutral 0.5/0.5 would give wrong vibe labels (e.g. punk-rap → "Melancholic & Calm").
        print("⚠️ Spotify unavailable — fetching BPM for \(song.title)")
        var bpm: Double = 0

        // 3a. GetSongBPM — primary BPM source, human-verified database.
        if let gsbpm = await getSongBPMService.fetchBPM(title: song.title, artist: song.artist) {
            print("✅ GetSongBPM \(Int(gsbpm)): \(song.title)")
            bpm = gsbpm
        }

        // 3b. Deezer — fallback only when GetSongBPM has no result.
        //     Deezer frequently halves/doubles tempo on rave, trap, hyperpop and R&B.
        if bpm == 0,
           let track = try? await deezerService.searchTrack(title: song.title, artist: song.artist),
           let deezerBPM = track.bpm, deezerBPM > 0 {
            print("✅ Deezer BPM \(Int(deezerBPM)): \(song.title)")
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
            print("⚠️ Last.fm returned no raw tags for \(song.title) — trying MusicBrainz")
            rawTags = await musicBrainzService.fetchRawTags(title: song.title, artist: song.artist)
        }

        // BPM normalization: correct Deezer's half-time / double-time detection errors.
        // e.g. James Joint reported at 135 BPM instead of ~68, hyperpop at 110 instead of 149.
        if bpm > 0 {
            bpm = normalizeBPM(bpm, tags: rawTags)
            print("🎚️ BPM after normalization: \(Int(bpm)) for \(song.title)")
        }

        // 4 + 1.5 merge: combine audio measurements with tag estimation.
        if let tagEstimated = await estimateFeaturesFromTags(rawTags, bpm: bpm) {
            if let audio = audioMeasurements {
                // Both audio analysis and tag estimation succeeded.
                // Audio RMS replaces tag energy (more accurate).
                // Valence blends audio spectral brightness (0.4) with tag valence (0.6) —
                // tags carry genre context that spectral brightness can miss (e.g. jazz brightness ≠ happy).
                let mergedValence  = (audio.spectralBrightness * 0.4) + (tagEstimated.valence * 0.6)
                let merged = AudioFeatures(
                    bpm:              tagEstimated.bpm,
                    energy:           audio.energy,
                    valence:          mergedValence,
                    danceability:     tagEstimated.danceability,
                    acousticness:     tagEstimated.acousticness,
                    instrumentalness: tagEstimated.instrumentalness,
                    liveness:         tagEstimated.liveness,
                    loudness:         tagEstimated.loudness,
                    key:              tagEstimated.key,
                    mode:             tagEstimated.mode,
                    isEstimated:      false
                )
                print("🎵 Merged audio+tag features for \(song.title)")
                Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: merged, source: "preview_audio") }
                return merged
            } else {
                // Tag estimation only.
                print("🏷️ Tag-estimated features for source \"\(song.title)\": \(rawTags.prefix(3).joined(separator: ", "))")
                Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: tagEstimated, source: "tag_estimated") }
                return tagEstimated
            }
        }

        // 4b. Audio-only fallback — tag estimation found nothing but audio analysis succeeded.
        //     Use spectral brightness directly as valence; neutral danceability (no genre signal).
        if let audio = audioMeasurements {
            let audioOnly = AudioFeatures(
                bpm:              bpm,
                energy:           audio.energy,
                valence:          audio.spectralBrightness,
                danceability:     0.5,
                acousticness:     0.0,
                instrumentalness: 0.0,
                liveness:         0.0,
                loudness:         -10.0,
                key:              0,
                mode:             1,
                isEstimated:      false
            )
            print("🎵 Audio-only features for \(song.title) (no tag match)")
            Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: audioOnly, source: "preview_audio") }
            return audioOnly
        }

        // 5. BPM only — tag estimation found nothing, but at least we have tempo.
        if bpm > 0 {
            print("✅ BPM only (no tag match): \(song.title)")
            let features = AudioFeatures(
                bpm: bpm, energy: 0.5, valence: 0.5, danceability: 0.5,
                acousticness: 0.0, instrumentalness: 0.0, liveness: 0.0,
                loudness: -10.0, key: 0, mode: 1, isEstimated: true
            )
            Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: features, source: "bpm_only") }
            return features
        }

        // 6. Neutral placeholder — app still works, just less precise scoring
        print("⚠️ No audio features available for \(song.title) — using neutral defaults")
        return AudioFeatures(
            bpm: 0, energy: 0.5, valence: 0.5, danceability: 0.5,
            acousticness: 0.0, instrumentalness: 0.0, liveness: 0.0,
            loudness: -10.0, key: 0, mode: 1, isEstimated: true
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Background AcousticBrainz Enrichment
    // ──────────────────────────────────────────────

    /// Fetches AcousticBrainz features for each recommended song in the background.
    /// Collects ALL results first, then applies them in one synchronous batch so SwiftUI
    /// triggers a single re-render instead of ~20 incremental ones (which reset scroll position).
    /// Staggered requests (150ms apart) to respect MusicBrainz's ~1 req/sec guideline.
    /// Enriches recommended songs with tag-estimated audio features in the background.
    /// When seedFeatures has >1 entry (blend mode), scores candidates against all seeds
    /// and returns the average — ensuring blend results fit the full range of the user's taste.
    private func enrichWithABFeatures(
        sourceFeatures: AudioFeatures,
        genres: [Genre],
        seedFeatures: [AudioFeatures] = []
    ) async {
        let snapshot = recommendations
        guard !snapshot.isEmpty else { return }

        print("🎵 Starting tag-feature enrichment for \(snapshot.count) songs...")

        // Step 1: fetch features concurrently via tag estimation (no AcousticBrainz — deprecated)
        var updates: [(index: Int, features: AudioFeatures)] = []

        await withTaskGroup(of: (Int, AudioFeatures?).self) { group in
            for (index, song) in snapshot.enumerated() {
                group.addTask {
                    // Stagger requests: 50ms per song index (light throttle for Last.fm)
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(index) * 50_000_000)
                    }

                    // Estimate from Last.fm genre/mood tags — covers nearly everything
                    let tags = await self.lastFMService.fetchRawTags(
                        title: song.title, artist: song.artist
                    )
                    let estimated = await self.estimateFeaturesFromTags(tags)
                    if let estimated = estimated {
                        print("🏷️ Tag-estimated features for \"\(song.title)\": \(tags.prefix(3).joined(separator: ", "))")
                        return (index, estimated)
                    }

                    return (index, nil)
                }
            }

            for await (index, features) in group {
                guard let features = features else { continue }
                updates.append((index: index, features: features))
            }
        }

        // Step 2: apply ALL updates in one tight synchronous loop.
        // No awaits → all mutations happen in the same run-loop turn → SwiftUI coalesces
        // them into a single re-render, so scroll position is preserved.
        var enrichedCount = 0
        for update in updates {
            guard update.index < recommendations.count else { continue }
            // Multi-seed: score against all seeds and average. Single: score against source.
            let (score, reasons) = seedFeatures.count > 1
                ? computeSimilarityMultiSeed(seeds: seedFeatures, target: update.features, genres: genres)
                : computeSimilarity(source: sourceFeatures, target: update.features, genres: genres)
            recommendations[update.index].audioFeatures   = update.features
            recommendations[update.index].similarityScore = score
            recommendations[update.index].matchReasons    = reasons
            enrichedCount += 1
        }

        // Final re-sort with all real scores in place
        if enrichedCount > 0 {
            recommendations.sort { $0.similarityScore > $1.similarityScore }
        }

        // Post-enrichment quality filter: drop songs that scored poorly once we have
        // actual (estimated) feature data. The initial merge uses nil features → score 0.5
        // as a placeholder, which lets everything through. Now that enrichment has run,
        // anything below 0.62 is a bad vibe match — trim it so we don't surface songs
        // that are genre-adjacent but feel completely different (e.g. Crazy in Love
        // appearing for a dark/moody R&B track).
        // Only apply when a meaningful number of songs were enriched — if enrichment
        // got <30% coverage, the scores aren't reliable enough to cut against.
        let coverageRatio = Double(enrichedCount) / Double(max(1, snapshot.count))
        if coverageRatio >= 0.3 {
            let before = recommendations.count
            recommendations = recommendations.filter { $0.similarityScore >= 0.62 }
            let removed = before - recommendations.count
            if removed > 0 {
                print("🔪 Quality filter removed \(removed) low-scoring songs (threshold 0.62)")
            }
        }

        print("✅ Tag enrichment done: \(enrichedCount)/\(snapshot.count) songs got features")
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
        seedFeatures: [AudioFeatures] = []
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

        // Resolves the best preview URL: Spotify first, iTunes as fallback.
        // Spotify removed preview_url from most tracks in 2023; iTunes still provides them for free.
        // Uses the shared itunesService instance — not a fresh one per song.
        func resolvePreview(song: Song) async -> String? {
            if let url = song.previewURL { return url }
            return await itunesService.fetchPreviewURL(title: song.title, artist: song.artist)
        }

        // Helper: look up a (title, artist) pair on Spotify, score it, and append to results
        func addTrack(title: String, artist: String) async {
            guard let song = try? await spotifyService.searchTrack(title: title, artist: artist),
                  seen.insert(song.id).inserted else { return }
            let songFeatures = try? await spotifyService.fetchAudioFeatures(trackID: song.id)
            let (s, reasons) = score(target: songFeatures)
            let preview = await resolvePreview(song: song)
            results.append(SimilarSong(
                id: song.id, title: song.title, artist: song.artist,
                albumArt: song.albumArt, spotifyURL: song.spotifyURL, previewURL: preview,
                genre: genres.first ?? Genre(main: "Unknown"),
                audioFeatures: songFeatures, similarityScore: s, matchReasons: reasons
            ))
        }

        // ── Source 1: Spotify recommendations ──
        for song in spotifyRecs {
            guard seen.insert(song.id).inserted else { continue }
            let songFeatures = try? await spotifyService.fetchAudioFeatures(trackID: song.id)
            let (s, reasons) = score(target: songFeatures)
            let preview = await resolvePreview(song: song)
            results.append(SimilarSong(
                id: song.id, title: song.title, artist: song.artist,
                albumArt: song.albumArt, spotifyURL: song.spotifyURL, previewURL: preview,
                genre: genres.first ?? Genre(main: "Unknown"),
                audioFeatures: songFeatures, similarityScore: s, matchReasons: reasons
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
        for song in lastFMSongs {
            guard seen.insert(song.id).inserted else { continue }
            let songFeatures = try? await spotifyService.fetchAudioFeatures(trackID: song.id)
            let (s, reasons) = score(target: songFeatures)
            let preview = await resolvePreview(song: song)
            results.append(SimilarSong(
                id: song.id, title: song.title, artist: song.artist,
                albumArt: song.albumArt, spotifyURL: song.spotifyURL, previewURL: preview,
                genre: genres.first ?? Genre(main: "Unknown"),
                audioFeatures: songFeatures, similarityScore: s, matchReasons: reasons
            ))
        }

        results.sort { $0.similarityScore > $1.similarityScore }
        return applyArtistDiversity(results, sourceArtist: sourceSong.artist)
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
    // MARK: - Similarity Score Computation
    // ──────────────────────────────────────────────

    // Scoring philosophy: match the *emotional imprint* of a song, not its technical fingerprint.
    // People don't want the same BPM — they want the same feeling.
    // Weights: valence 0.30, energy 0.30, danceability 0.20, BPM 0.10, acoustics 0.10.
    // Danceability carries real weight because it separates slow jams from club tracks even
    // when both have warm valence — the critical failure mode within warm-valence genres like R&B.
    // BPM is loosened to a ±40 window so a punk song at 175 BPM can still match dark trap at 100 BPM
    // if they share the same defiant, heavy emotional imprint.
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
            if source.valence < 0.42 {
                reasons.append(.darkMood)       // Genuinely dark: metal, emo, sad rap
            } else if source.valence > 0.72 {
                reasons.append(.upbeatMood)     // Genuinely bright: pop, dance, k-pop
            } else {
                reasons.append(.mood)           // Neutral: "Similar Mood" — honest
            }
        }

        // Valence — the emotional color (happy / dark / bittersweet).
        let valenceDiff = abs(source.valence - target.valence)
        let valenceScore = 1.0 - valenceDiff
        totalScore += valenceScore * 0.30
        if !bothEstimated && valenceDiff < 0.15 {
            // Emotionally specific: name the actual mood shared, not just "Same Mood"
            let avgValence = (source.valence + target.valence) / 2
            if avgValence < 0.40 {
                reasons.append(.darkMood)      // Both dark/heavy — defiant, bleak, raw
            } else if avgValence > 0.65 {
                reasons.append(.upbeatMood)    // Both bright/joyful
            } else {
                reasons.append(.mood)          // Mid-range emotional match
            }
        }

        // Energy — the intensity of the feeling (mosh-pit vs. bedroom).
        let energyDiff = abs(source.energy - target.energy)
        let energyScore = 1.0 - energyDiff
        totalScore += energyScore * 0.30
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
        // Raised to 0.20 to discriminate within warm-valence genres (R&B, soul) where
        // valence alone can't separate a slow jam from a club banger.
        let danceDiff = abs(source.danceability - target.danceability)
        let danceScore = 1.0 - danceDiff
        totalScore += danceScore * 0.20

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

        // BPM — secondary. Tolerance window widened to ±40 so songs at different tempos
        // (e.g. punk 175 BPM vs. dark trap 100 BPM) can still match on emotional imprint.
        let bpmDiff = abs(source.bpm - target.bpm)
        let bpmScore = max(0.0, 1.0 - (bpmDiff / 40.0))
        totalScore += bpmScore * 0.10
        if bpmDiff <= 15 { reasons.append(.bpm) }

        // Acousticness — sonic texture, not emotional feel. Least important.
        let acousticScore = 1.0 - abs(source.acousticness - target.acousticness)
        totalScore += acousticScore * 0.10
        if abs(source.acousticness - target.acousticness) < 0.2 { reasons.append(.acoustics) }

        let finalScore = totalScore
        // For estimated features the first two slots are energy + mood — far more useful
        // than a generic "Same Genre" label. Only prepend genre for measured features.
        if !bothEstimated {
            reasons.insert(.genre, at: 0)
        }
        return (finalScore, Array(reasons.prefix(3)))
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
    private func normalizeBPM(_ bpm: Double, tags: [String]) -> Double {
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

        // If Deezer returns a suspiciously low BPM for a fast genre, try doubling it.
        // e.g. Deezer reads half-time feel on a 149 BPM hyperpop track → returns 74–110 → double.
        if hasFastTag && bpm < 120 {
            let doubled = bpm * 2
            print("🎚️ BPM doubled \(Int(bpm)) → \(Int(doubled)) (fast genre tag, BPM too low)")
            return doubled
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

        // Slow-tag halving: only kick in above 155 BPM.
        // R&B, soul, neo-soul etc. legitimately live in the 130–155 range
        // (e.g. "All Back" CB at 146 BPM). Halving a 180 reading when the song is
        // actually ~146 produces 90 — wrong in both directions.
        // Threshold 155 means: 155÷2 = 77.5, which is the right felt-tempo for a slow jam
        // that the detector read at double-time. Below 155, trust the source.
        if hasSlowTag && bpm > 155 {
            let halved = bpm / 2
            print("🎚️ BPM halved \(Int(bpm)) → \(Int(halved)) (slow genre tag + >155 BPM)")
            return halved
        }

        // Catch doubled BPM for non-fast genres in the 155–200 range.
        // Genuine 155+ BPM songs (drum & bass, hardstyle, hyperpop) all have fast genre tags —
        // those are already handled above. Pop, rock, R&B, indie, etc. at 155+ BPM means
        // the tempo detector locked onto the subdivisions instead of the felt beat.
        // e.g. Sunday Morning (Maroon 5): tagged "pop/rock", 176 BPM detected → 88 BPM felt.
        if bpm > 155 && !hasFastTag {
            let halved = bpm / 2
            print("🎚️ BPM halved \(Int(bpm)) → \(Int(halved)) (non-fast genre, suspicious tempo)")
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
            // Hip-hop / Rap
            "hip-hop":          (0.62, 0.52, 0.72),
            "hip hop":          (0.62, 0.52, 0.72),
            "rap":              (0.65, 0.50, 0.72),
            "trap":             (0.70, 0.48, 0.75),  // slightly warmer — dark but not fully brooding
            "cloud rap":        (0.42, 0.40, 0.55),
            "cloud":            (0.42, 0.40, 0.55),
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
            // Jazz / Blues / Classical
            "jazz":             (0.42, 0.58, 0.48),
            "blues":            (0.45, 0.35, 0.42),
            "classical":        (0.35, 0.52, 0.30),
            // Mood tags
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
            "80s":              (0.65, 0.62, 0.62),  // synth-pop / new wave / rock era
            "90s":              (0.60, 0.55, 0.58),  // grunge / britpop / r&b era
            "70s":              (0.58, 0.62, 0.58),  // classic rock / soul / disco era
            "60s":              (0.55, 0.68, 0.58),  // light pop / motown era
            // Meta-genre / style tags Last.fm commonly assigns
            "new wave":         (0.62, 0.52, 0.62),  // post-punk pop, synth-driven
            "classic rock":     (0.68, 0.50, 0.55),  // polished rock, slightly less raw than "rock"
            "disco":            (0.78, 0.72, 0.82),  // high energy, high dance, bright
            "motown":           (0.60, 0.72, 0.68),  // soulful pop, upbeat
        ]

        var totalE = 0.0, totalV = 0.0, totalD = 0.0
        var hits = 0
        var missedTags: [String] = []

        // Sort keys longest-first so specific keys (e.g. "trap") beat substrings (e.g. "rap")
        let sortedTagMap = tagMap.sorted { $0.key.count > $1.key.count }

        for tag in tags {
            if let match = tagMap[tag] {
                totalE += match.e; totalV += match.v; totalD += match.d
                hits += 1
            } else if let match = sortedTagMap.first(where: { tag.contains($0.key) }) {
                totalE += match.value.e; totalV += match.value.v; totalD += match.value.d
                hits += 1
            } else {
                missedTags.append(tag)
            }
        }

        // Supabase enrichment: look up any tags that weren't in the hardcoded map.
        // This is how the genre_tag_map grows — new tags discovered at runtime get stored.
        if !missedTags.isEmpty {
            let remoteMatches = await supabase.lookupTagMap(tags: missedTags)
            for (tag, tf) in remoteMatches {
                totalE += tf.energy; totalV += tf.valence; totalD += tf.danceability
                hits += 1
                print("🌐 Supabase genre map hit: \"\(tag)\" → e:\(tf.energy) v:\(tf.valence)")
            }
        }

        guard hits > 0 else { return nil }

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
                "phonk": 135, "cloud rap": 80, "cloud": 80,
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
                "reggae": 80, "ska": 140,
                "80s": 108, "90s": 100, "70s": 95, "60s": 95,
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
            energy:           totalE / Double(hits),
            valence:          totalV / Double(hits),
            danceability:     totalD / Double(hits),
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
}

// ──────────────────────────────────────────────
// MARK: - SimiError
// ──────────────────────────────────────────────

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
