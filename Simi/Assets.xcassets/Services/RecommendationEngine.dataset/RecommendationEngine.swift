// RecommendationEngine.swift
// Simi — Music Discovery App
//
// This is the brain of Simi. It coordinates between Spotify and Last.fm
// to produce a final ranked list of similar songs.
//
// Flow:
//   1. User pastes URL → URLParserService identifies platform + track ID
//   2. SpotifyService fetches track metadata + audio features (BPM, energy, etc.)
//   3. LastFMService fetches genre tags + similar tracks
//   4. RecommendationEngine combines everything → ranked list of SimilarSong

import Foundation
import Combine

@MainActor
class RecommendationEngine: ObservableObject {

    // ──────────────────────────────────────────────
    // MARK: - Published State (drives the UI)
    // ──────────────────────────────────────────────
    // @Published means: when these values change, SwiftUI automatically redraws the screen

    @Published var sourceSong: Song?                    // The song the user pasted
    @Published var recommendations: [SimilarSong] = []  // The results list
    @Published var isLoading = false                    // Shows a spinner when true
    @Published var errorMessage: String?                // Shown if something goes wrong
    @Published var detectedGenres: [Genre] = []         // Genre tags from Last.fm

    // ──────────────────────────────────────────────
    // MARK: - Services
    // ──────────────────────────────────────────────

    private let spotifyService = SpotifyService()
    private let lastFMService  = LastFMService()
    private let urlParser      = URLParserService()
    let history                = SearchHistoryManager()

    // ──────────────────────────────────────────────
    // MARK: - Main Entry Point
    // ──────────────────────────────────────────────

    /// Call this when the user taps "Find Songs Like This"
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
            // Step 1 — Parse the URL
            let parsed = urlParser.parse(urlString)
            guard parsed.isValid else {
                throw SimiError.invalidURL
            }

            // Step 2 — Get the Spotify track (handles Spotify links directly,
            //          searches Spotify for YouTube/SoundCloud links)
            let song = try await resolveSong(from: parsed)
            self.sourceSong = song

            // Step 3 — Fetch audio features from Spotify
            let features = try await spotifyService.fetchAudioFeatures(trackID: song.id)
            self.sourceSong?.audioFeatures = features

            // Step 4 — Fetch genre tags from Last.fm (run in parallel with Step 5)
            async let genresTask = lastFMService.fetchTags(title: song.title, artist: song.artist)
            async let similarTracksTask = lastFMService.fetchSimilarTracks(title: song.title, artist: song.artist)
            async let spotifyRecsTask = spotifyService.getRecommendations(seedTrackID: song.id, features: features)

            let (genres, lastFMTracks, spotifyRecs) = try await (genresTask, similarTracksTask, spotifyRecsTask)
            self.detectedGenres = genres

            // Step 5 — Merge Spotify recs + Last.fm similar tracks, deduplicate, and score
            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: lastFMTracks,
                sourceSong: song,
                sourceFeatures: features,
                genres: genres
            )

            self.recommendations = merged

            // Record to history after a successful search
            if let song = self.sourceSong {
                history.record(song: song, query: urlString)
            }

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

    /// Call this when the user types a song title + artist instead of pasting a URL.
    /// Searches Spotify for the track, then runs the same recommendation pipeline.
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

            let features = try await spotifyService.fetchAudioFeatures(trackID: song.id)
            self.sourceSong?.audioFeatures = features

            async let genresTask        = lastFMService.fetchTags(title: song.title, artist: song.artist)
            async let similarTracksTask = lastFMService.fetchSimilarTracks(title: song.title, artist: song.artist)
            async let spotifyRecsTask   = spotifyService.getRecommendations(seedTrackID: song.id, features: features)

            let (genres, lastFMTracks, spotifyRecs) = try await (genresTask, similarTracksTask, spotifyRecsTask)
            self.detectedGenres = genres

            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: lastFMTracks,
                sourceSong: song,
                sourceFeatures: features,
                genres: genres
            )
            self.recommendations = merged

            // Record to history
            history.record(song: song, query: query)

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
            // For YouTube/SoundCloud, we guess the song from the URL slug
            // then search Spotify to get the full metadata
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
    // MARK: - Merge and Score Recommendations
    // ──────────────────────────────────────────────

    /// Combines results from both sources, removes duplicates, and ranks them
    private func mergeAndScore(
        spotifyRecs: [Song],
        lastFMTracks: [(title: String, artist: String)],
        sourceSong: Song,
        sourceFeatures: AudioFeatures,
        genres: [Genre]
    ) async throws -> [SimilarSong] {

        var results: [SimilarSong] = []

        // Process Spotify recommendations (we already have audio features for these)
        for song in spotifyRecs {
            let songFeatures = try? await spotifyService.fetchAudioFeatures(trackID: song.id)
            let (score, reasons) = computeSimilarity(
                source: sourceFeatures,
                target: songFeatures,
                genres: genres
            )

            let similar = SimilarSong(
                id: song.id,
                title: song.title,
                artist: song.artist,
                albumArt: song.albumArt,
                spotifyURL: song.spotifyURL,
                previewURL: song.previewURL,
                genre: genres.first ?? Genre(main: "Unknown"),
                audioFeatures: songFeatures,
                similarityScore: score,
                matchReasons: reasons
            )
            results.append(similar)
        }

        // Sort by similarity score, highest first
        results.sort { $0.similarityScore > $1.similarityScore }

        // Deduplicate by track ID
        var seen = Set<String>()
        results = results.filter { seen.insert($0.id).inserted }

        return results
    }

    // ──────────────────────────────────────────────
    // MARK: - Similarity Score Computation
    // ──────────────────────────────────────────────

    /// Computes a 0.0–1.0 similarity score between source and target audio features.
    /// Also returns a list of reasons why the songs match.
    private func computeSimilarity(
        source: AudioFeatures,
        target: AudioFeatures?,
        genres: [Genre]
    ) -> (Double, [MatchReason]) {
        guard let target = target else {
            return (0.5, [.genre]) // If no features, give it a neutral score
        }

        var totalScore = 0.0
        var reasons: [MatchReason] = []
        var weights = 0.0

        // BPM match — songs ±5 BPM score perfectly, ±15 BPM score 50%
        let bpmDiff = abs(source.bpm - target.bpm)
        let bpmScore = max(0.0, 1.0 - (bpmDiff / 15.0))
        totalScore += bpmScore * 0.25
        weights += 0.25
        if bpmDiff <= 10 { reasons.append(.bpm) }

        // Energy match
        let energyScore = 1.0 - abs(source.energy - target.energy)
        totalScore += energyScore * 0.25
        weights += 0.25
        if abs(source.energy - target.energy) < 0.15 { reasons.append(.energy) }

        // Valence (mood) match
        let valenceScore = 1.0 - abs(source.valence - target.valence)
        totalScore += valenceScore * 0.20
        weights += 0.20
        if abs(source.valence - target.valence) < 0.15 { reasons.append(.mood) }

        // Danceability match
        let danceScore = 1.0 - abs(source.danceability - target.danceability)
        totalScore += danceScore * 0.15
        weights += 0.15

        // Acousticness match
        let acousticScore = 1.0 - abs(source.acousticness - target.acousticness)
        totalScore += acousticScore * 0.15
        weights += 0.15
        if abs(source.acousticness - target.acousticness) < 0.2 { reasons.append(.acoustics) }

        let finalScore = weights > 0 ? totalScore / weights : 0.5

        // Always credit genre (since Spotify already filtered by genre)
        reasons.insert(.genre, at: 0)

        return (finalScore, Array(reasons.prefix(3)))
    }

    // ──────────────────────────────────────────────
    // MARK: - Reset
    // ──────────────────────────────────────────────

    func reset() {
        sourceSong = nil
        recommendations = []
        errorMessage = nil
        detectedGenres = []
    }
}

// ──────────────────────────────────────────────
// MARK: - SimiError
// Custom errors with user-friendly messages
// ──────────────────────────────────────────────

enum SimiError: LocalizedError {
    case invalidURL
    case authFailed
    case songNotFound
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn't look like a valid song link. Try pasting a Spotify, YouTube, or SoundCloud URL."
        case .authFailed:
            return "Couldn't connect to Spotify. Check your API keys in SpotifyService.swift."
        case .songNotFound:
            return "Couldn't find that song on Spotify. Try a different link."
        case .apiError(let msg):
            return "API error: \(msg)"
        }
    }
}
