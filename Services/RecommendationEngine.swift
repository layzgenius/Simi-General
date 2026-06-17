// ⚠️ ARCHIVED — active code is Simi/Simi/Services/RecommendationEngine.swift
// This file predates the librosa pipeline and has stale weights. Do not edit.

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
    @Published var recommendations: [SimilarSong] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var detectedGenres: [Genre] = []

    // ──────────────────────────────────────────────
    // MARK: - Services
    // ──────────────────────────────────────────────

    private let spotifyService      = SpotifyService()
    private let lastFMService       = LastFMService()
    private let deezerService       = DeezerService()
    private let musicBrainzService  = MusicBrainzService()
    private let acousticBrainzService = AcousticBrainzService()
    private let urlParser           = URLParserService()
    let history                     = SearchHistoryManager()

    // Stored so background enrichment can re-score recommendations
    private var lastSourceFeatures: AudioFeatures?
    private var lastGenres: [Genre] = []

    // ──────────────────────────────────────────────
    // MARK: - URL Search Entry Point
    // ──────────────────────────────────────────────

    func findSimilarSongs(for urlString: String) async {
        guard !urlString.isEmpty else {
            errorMessage = "Paste a song link to get started."
            return
        }

        isLoading = true
        errorMessage = nil
        recommendations = []
        sourceSong = nil

        do {
            let parsed = urlParser.parse(urlString)
            guard parsed.isValid else { throw SimiError.invalidURL }

            let song = try await resolveSong(from: parsed)
            self.sourceSong = song

            let features = await fetchAudioFeaturesWithFallback(song: song)
            self.sourceSong?.audioFeatures = features
            self.lastSourceFeatures = features

            async let genresTask          = lastFMService.fetchTags(title: song.title, artist: song.artist)
            async let similarTracksTask   = lastFMService.fetchSimilarTracks(title: song.title, artist: song.artist)
            async let tagCandidatesTask   = fetchTagSeededCandidates(song: song, features: features)

            let (genres, lastFMTracks) = try await (genresTask, similarTracksTask)
            let tagCandidates = await tagCandidatesTask
            self.detectedGenres = genres
            self.lastGenres = genres

            let merged = try await mergeAndScore(
                lastFMTracks: lastFMTracks + tagCandidates,
                sourceSong: song,
                sourceFeatures: features,
                genres: genres
            )
            self.recommendations = merged

            if let song = self.sourceSong {
                history.record(song: song, query: urlString)
            }

            // Show results immediately, then enrich with AcousticBrainz in the background
            isLoading = false
            Task { await enrichWithABFeatures(sourceFeatures: features, genres: genres) }
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
    // MARK: - Text Search Entry Point
    // ──────────────────────────────────────────────

    func findSimilarSongs(title: String, artist: String) async {
        let query = artist.isEmpty ? title : "\(title) \(artist)"
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Enter a song title to search."
            return
        }

        isLoading = true
        errorMessage = nil
        recommendations = []
        sourceSong = nil

        do {
            guard let song = try await spotifyService.searchTrack(title: title, artist: artist) else {
                throw SimiError.songNotFound
            }
            self.sourceSong = song

            let features = await fetchAudioFeaturesWithFallback(song: song)
            self.sourceSong?.audioFeatures = features
            self.lastSourceFeatures = features

            async let genresTask          = lastFMService.fetchTags(title: song.title, artist: song.artist)
            async let similarTracksTask   = lastFMService.fetchSimilarTracks(title: song.title, artist: song.artist)
            async let tagCandidatesTask   = fetchTagSeededCandidates(song: song, features: features)

            let (genres, lastFMTracks) = try await (genresTask, similarTracksTask)
            let tagCandidates = await tagCandidatesTask
            self.detectedGenres = genres
            self.lastGenres = genres

            let merged = try await mergeAndScore(
                lastFMTracks: lastFMTracks + tagCandidates,
                sourceSong: song,
                sourceFeatures: features,
                genres: genres
            )
            self.recommendations = merged

            history.record(song: song, query: query)

            // Show results immediately, then enrich in background
            isLoading = false
            Task { await enrichWithABFeatures(sourceFeatures: features, genres: genres) }
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
    // MARK: - Resolve Song from Parsed URL
    // ──────────────────────────────────────────────

    private func resolveSong(from parsed: ParsedURL) async throws -> Song {
        switch parsed.source {
        case .spotify:
            guard let id = parsed.spotifyTrackID else { throw SimiError.invalidURL }
            return try await spotifyService.fetchSong(trackID: id)

        case .youtube, .soundcloud:
            let title  = parsed.guessedTitle  ?? ""
            let artist = parsed.guessedArtist ?? ""
            guard let song = try await spotifyService.searchTrack(title: title, artist: artist) else {
                throw SimiError.songNotFound
            }
            return song

        case .unknown:
            throw SimiError.invalidURL
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Audio Features — Full Priority Chain
    // ──────────────────────────────────────────────

    /// Fetches the best audio features available, working down the priority chain:
    /// AcousticBrainz → Deezer → neutral defaults
    /// (Spotify audio-features endpoint removed — restricted to Extended Quota Mode apps)
    private func fetchAudioFeaturesWithFallback(song: Song) async -> AudioFeatures {

        // 1. AcousticBrainz via MusicBrainz (community-powered, full features)
        print("🎵 Fetching features for \(song.title) via AcousticBrainz")
        if let mbid = await musicBrainzService.findMBID(title: song.title, artist: song.artist),
           let features = await acousticBrainzService.fetchFeatures(mbid: mbid) {
            print("✅ AcousticBrainz features: \(song.title)")
            return features
        }

        // 2. Deezer — BPM only, rest neutral
        print("⚠️ AcousticBrainz unavailable — trying Deezer BPM for \(song.title)")
        if let track = try? await deezerService.searchTrack(title: song.title, artist: song.artist),
           let bpm = track.bpm, bpm > 0 {
            print("✅ Deezer BPM \(Int(bpm)): \(song.title)")
            return AudioFeatures(
                bpm: bpm, energy: 0.5, valence: 0.5, danceability: 0.5,
                acousticness: 0.0, instrumentalness: 0.0, liveness: 0.0,
                loudness: -10.0, key: 0, mode: 1
            )
        }

        // 3. Neutral placeholder — app still works, just less precise scoring
        print("⚠️ No audio features available for \(song.title) — using neutral defaults")
        return AudioFeatures(
            bpm: 0, energy: 0.5, valence: 0.5, danceability: 0.5,
            acousticness: 0.0, instrumentalness: 0.0, liveness: 0.0,
            loudness: -10.0, key: 0, mode: 1
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - Background AcousticBrainz Enrichment
    // ──────────────────────────────────────────────

    /// Fetches AcousticBrainz features for each recommended song in the background.
    /// Collects ALL results first, then applies them in one synchronous batch so SwiftUI
    /// triggers a single re-render instead of ~20 incremental ones (which reset scroll position).
    /// Staggered requests (150ms apart) to respect MusicBrainz's ~1 req/sec guideline.
    private func enrichWithABFeatures(sourceFeatures: AudioFeatures, genres: [Genre]) async {
        let snapshot = recommendations
        guard !snapshot.isEmpty else { return }

        print("🎵 Starting AcousticBrainz enrichment for \(snapshot.count) songs...")

        // Step 1: fetch all features concurrently — collect into local array (no UI mutations yet)
        var updates: [(index: Int, features: AudioFeatures)] = []

        await withTaskGroup(of: (Int, AudioFeatures?).self) { group in
            for (index, song) in snapshot.enumerated() {
                group.addTask {
                    // Stagger requests: 150ms per song index (MusicBrainz rate limit)
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(index) * 150_000_000)
                    }

                    // 1. Try AcousticBrainz (real measured features)
                    if let mbid = await self.musicBrainzService.findMBID(
                        title: song.title, artist: song.artist
                    ), let features = await self.acousticBrainzService.fetchFeatures(mbid: mbid) {
                        return (index, features)
                    }

                    // 2. Fallback: estimate from Last.fm genre/mood tags
                    //    Last.fm has tags for almost everything — even very underground artists.
                    let tags = await self.lastFMService.fetchRawTags(
                        title: song.title, artist: song.artist
                    )
                    if let estimated = self.estimateFeaturesFromTags(tags) {
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
            let (score, reasons) = computeSimilarity(
                source: sourceFeatures,
                target: update.features,
                genres: genres
            )
            recommendations[update.index].audioFeatures  = update.features
            recommendations[update.index].similarityScore = score
            recommendations[update.index].matchReasons    = reasons
            enrichedCount += 1
        }

        // Final re-sort with all real scores in place
        if enrichedCount > 0 {
            recommendations.sort { $0.similarityScore > $1.similarityScore }
        }
        print("✅ AcousticBrainz enrichment done: \(enrichedCount)/\(snapshot.count) songs got real features")
    }

    // ──────────────────────────────────────────────
    // MARK: - Merge and Score Recommendations
    // ──────────────────────────────────────────────

    private func mergeAndScore(
        lastFMTracks: [(title: String, artist: String)],
        sourceSong: Song,
        sourceFeatures: AudioFeatures,
        genres: [Genre]
    ) async throws -> [SimilarSong] {

        var results: [SimilarSong] = []
        var seen = Set<String>()
        seen.insert(sourceSong.id)

        // Last.fm similar tracks — search Spotify for each to get full metadata (parallel)
        let lastFMSongs: [Song] = await withTaskGroup(of: Song?.self) { group in
            for (title, artist) in lastFMTracks.prefix(30) {
                group.addTask {
                    try? await self.spotifyService.searchTrack(title: title, artist: artist)
                }
            }
            var songs: [Song] = []
            for await song in group { if let song { songs.append(song) } }
            return songs
        }

        for song in lastFMSongs {
            guard seen.insert(song.id).inserted else { continue }
            // audioFeatures starts nil — filled in by enrichWithABFeatures background pass
            let (score, reasons) = computeSimilarity(source: sourceFeatures, target: nil, genres: genres)
            results.append(SimilarSong(
                id: song.id, title: song.title, artist: song.artist,
                albumArt: song.albumArt, spotifyURL: song.spotifyURL, previewURL: song.previewURL,
                genre: genres.first ?? Genre(main: "Unknown"),
                audioFeatures: nil, similarityScore: score, matchReasons: reasons
            ))
        }

        results.sort { $0.similarityScore > $1.similarityScore }
        return results
    }

    // ──────────────────────────────────────────────
    // MARK: - Similarity Score Computation
    // ──────────────────────────────────────────────

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
        var weights = 0.0

        let bpmDiff = abs(source.bpm - target.bpm)
        let bpmScore = max(0.0, 1.0 - (bpmDiff / 15.0))
        totalScore += bpmScore * 0.25; weights += 0.25
        if bpmDiff <= 10 { reasons.append(.bpm) }

        let energyScore = 1.0 - abs(source.energy - target.energy)
        totalScore += energyScore * 0.25; weights += 0.25
        if abs(source.energy - target.energy) < 0.15 { reasons.append(.energy) }

        let valenceScore = 1.0 - abs(source.valence - target.valence)
        totalScore += valenceScore * 0.20; weights += 0.20
        if abs(source.valence - target.valence) < 0.15 { reasons.append(.mood) }

        let danceScore = 1.0 - abs(source.danceability - target.danceability)
        totalScore += danceScore * 0.15; weights += 0.15

        let acousticScore = 1.0 - abs(source.acousticness - target.acousticness)
        totalScore += acousticScore * 0.15; weights += 0.15
        if abs(source.acousticness - target.acousticness) < 0.2 { reasons.append(.acoustics) }

        let finalScore = weights > 0 ? totalScore / weights : 0.5
        reasons.insert(.genre, at: 0)
        return (finalScore, Array(reasons.prefix(3)))
    }

    // ──────────────────────────────────────────────
    // MARK: - Tag-based Feature Estimation
    // ──────────────────────────────────────────────

    /// Maps Last.fm genre/mood tags to approximate Spotify-style audio features.
    /// Averages across all matching tags. Returns nil if no tags are recognisable.
    private func estimateFeaturesFromTags(_ tags: [String], bpm: Double = 0) -> AudioFeatures? {
        guard !tags.isEmpty else { return nil }

        // Tag → (energy, valence, danceability)
        let tagMap: [String: (e: Double, v: Double, d: Double)] = [
            // Electronic
            "edm":              (0.85, 0.65, 0.85),
            "electronic":       (0.70, 0.55, 0.75),
            "dance":            (0.78, 0.70, 0.85),
            "house":            (0.80, 0.65, 0.85),
            "techno":           (0.82, 0.50, 0.80),
            "ambient":          (0.20, 0.45, 0.25),
            "lo-fi":            (0.30, 0.50, 0.45),
            "lofi":             (0.30, 0.50, 0.45),
            "chillwave":        (0.35, 0.55, 0.45),
            "synthwave":        (0.60, 0.55, 0.65),
            "synth-pop":        (0.62, 0.58, 0.68),
            "synth pop":        (0.62, 0.58, 0.68),
            "drum and bass":    (0.85, 0.50, 0.75),
            "dubstep":          (0.88, 0.45, 0.70),
            "hyperpop":         (0.80, 0.60, 0.78),
            "glitch":           (0.68, 0.45, 0.60),
            // Hip-hop / Rap
            "hip-hop":          (0.62, 0.52, 0.72),
            "hip hop":          (0.62, 0.52, 0.72),
            "rap":              (0.65, 0.50, 0.72),
            "trap":             (0.68, 0.45, 0.75),
            "cloud rap":        (0.42, 0.40, 0.55),
            "cloud":            (0.42, 0.40, 0.55),
            "boom bap":         (0.60, 0.48, 0.65),
            "drill":            (0.72, 0.38, 0.70),
            "phonk":            (0.72, 0.42, 0.72),
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
            // Soul / R&B / Funk
            "r&b":              (0.58, 0.60, 0.65),
            "soul":             (0.55, 0.62, 0.60),
            "neo-soul":         (0.52, 0.60, 0.58),
            "funk":             (0.72, 0.68, 0.80),
            // Acoustic / Folk
            "folk":             (0.38, 0.55, 0.40),
            "acoustic":         (0.35, 0.55, 0.40),
            "singer-songwriter":(0.38, 0.52, 0.42),
            "country":          (0.58, 0.60, 0.55),
            // Jazz / Blues / Classical
            "jazz":             (0.42, 0.58, 0.48),
            "blues":            (0.45, 0.35, 0.42),
            "classical":        (0.35, 0.52, 0.30),
            // Audio-derived injected tags
            "melodic trap":     (0.62, 0.58, 0.68),
            "dark trap":        (0.72, 0.32, 0.72),
            "feel good":        (0.65, 0.75, 0.72),
            "late night":       (0.42, 0.48, 0.52),
            // Mood tags
            "chill":            (0.30, 0.55, 0.40),
            "sad":              (0.35, 0.18, 0.38),
            "melancholic":      (0.38, 0.22, 0.40),
            "happy":            (0.68, 0.82, 0.72),
            "upbeat":           (0.72, 0.78, 0.75),
            "aggressive":       (0.85, 0.32, 0.55),
            "party":            (0.82, 0.72, 0.85),
            "relaxing":         (0.28, 0.55, 0.38),
            "chill out":        (0.28, 0.55, 0.38),
            "dark":             (0.55, 0.20, 0.48),
            "workout":          (0.85, 0.58, 0.75),
            "summer":           (0.70, 0.78, 0.75),
            "romantic":         (0.45, 0.65, 0.50),
        ]

        var totalE = 0.0, totalV = 0.0, totalD = 0.0
        var hits = 0

        for tag in tags {
            for (key, vals) in tagMap {
                if tag.contains(key) || key.contains(tag) {
                    totalE += vals.e; totalV += vals.v; totalD += vals.d
                    hits += 1
                    break
                }
            }
        }

        guard hits > 0 else { return nil }

        return AudioFeatures(
            bpm:              bpm,
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
    // MARK: - Audio-Derived Tag Injection
    // ──────────────────────────────────────────────

    /// Normalizes BPM to a single tempo octave (60–160 BPM).
    /// Beat trackers sometimes return 200 BPM for a 100 BPM song; halving fixes that.
    private func normalizeBPM(_ bpm: Double) -> Double {
        var b = bpm
        while b > 160 { b /= 2 }
        while b < 60  { b *= 2 }
        return b
    }

    /// Derives semantic seed tags from real audio features for Last.fm tag.getTopTracks queries.
    ///
    /// "feel good" is always injected when conditions are met — it seeds emotional tag queries
    /// that pure collaborative filtering (track.getSimilar) misses for melodic/R&B-leaning tracks.
    ///
    /// All other tags inject only when the track has no Last.fm data (trackTags.isEmpty),
    /// using artist-level fallback tags (artistTags) to detect genre context (e.g. "trap").
    private func audioInjectTags(
        features: AudioFeatures,
        trackTags: [String],
        artistTags: [String]
    ) -> [String] {
        guard !features.isEstimated else { return [] }

        var injected: [String] = []
        let normalizedBPM = normalizeBPM(features.bpm)

        // "feel good" — always inject when conditions met, regardless of tag availability
        if features.valence >= 0.50 && features.danceability >= 0.55
            && features.bpm >= 80 && features.bpm <= 160 {
            injected.append("feel good")
            print("🎵 Audio inject: feel good (valence=\(features.valence), dance=\(features.danceability), bpm=\(Int(features.bpm)))")
        }

        // Remaining injections only fire when the track has no Last.fm data
        guard trackTags.isEmpty else { return injected }

        if features.energy <= 0.75 || normalizedBPM <= 100 {
            injected.append("late night")
            print("🎵 Audio inject: late night (energy=\(features.energy), normBPM=\(Int(normalizedBPM)))")
        }

        // Use artist fallback tags to detect trap context
        let hasTrap = artistTags.contains { $0.contains("trap") }
        if hasTrap {
            if features.valence >= 0.50 {
                injected.append(contentsOf: ["melodic trap", "r&b"])
                print("🎵 Audio inject: melodic trap + r&b (trap artist, valence=\(features.valence))")
            } else if features.valence < 0.45 {
                injected.append("dark trap")
                print("🎵 Audio inject: dark trap (trap artist, valence=\(features.valence))")
            }
        }

        return injected
    }

    /// Fetches additional song candidates by querying Last.fm tag.getTopTracks for each
    /// audio-derived injected tag. Runs in parallel with the main similar-track fetch.
    ///
    /// Returns an empty list when features are estimated (no real audio data) or no tags qualify.
    private func fetchTagSeededCandidates(song: Song, features: AudioFeatures) async -> [(title: String, artist: String)] {
        guard !features.isEstimated else { return [] }

        let trackTags = await lastFMService.fetchRawTags(title: song.title, artist: song.artist)

        // Only fetch artist tags when the track has no Last.fm data — used for trap detection
        let artistTags: [String]
        if trackTags.isEmpty {
            artistTags = await lastFMService.fetchArtistTags(artist: song.artist)
        } else {
            artistTags = []
        }

        let injected = audioInjectTags(features: features, trackTags: trackTags, artistTags: artistTags)
        guard !injected.isEmpty else { return [] }

        var candidates: [(title: String, artist: String)] = []
        var seen = Set<String>()

        await withTaskGroup(of: [(title: String, artist: String)].self) { group in
            for tag in injected {
                group.addTask {
                    await self.lastFMService.fetchTracksByTag(tag, limit: 8)
                }
            }
            for await tracks in group {
                for track in tracks {
                    let key = "\(track.title.lowercased())|\(track.artist.lowercased())"
                    if seen.insert(key).inserted {
                        candidates.append(track)
                    }
                }
            }
        }

        print("🎵 Tag-seeded \(candidates.count) candidates from: \(injected.joined(separator: ", "))")
        return candidates
    }

    // ──────────────────────────────────────────────
    // MARK: - Reset
    // ──────────────────────────────────────────────

    func reset() {
        sourceSong = nil
        recommendations = []
        errorMessage = nil
        detectedGenres = []
        lastSourceFeatures = nil
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
        case .authFailed:    return "Couldn't connect to Spotify. Check your API keys in SpotifyService.swift."
        case .songNotFound:  return "Couldn't find that song on Spotify. Try a different link."
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}
