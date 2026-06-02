// URLParserService.swift
// Simi — Music Discovery App
//
// When the user pastes a URL (Spotify, YouTube, SoundCloud),
// this service figures out what platform it's from and extracts
// whatever info it can — track ID, title, etc.
//
// Think of it as the app's "front door" — every URL flows through here first.

import Foundation

class URLParserService {

    // ──────────────────────────────────────────────
    // MARK: - Parse a Pasted URL
    // ──────────────────────────────────────────────

    /// Main entry point — takes any URL the user pastes and returns
    /// a ParsedURL with the platform and any identifiers we can extract
    func parse(_ urlString: String) -> ParsedURL {
        let source = URLSource.detect(from: urlString)

        switch source {
        case .spotify:
            return parseSpotify(urlString)
        case .youtube:
            return parseYouTube(urlString)
        case .soundcloud:
            return parseSoundCloud(urlString)
        case .unknown:
            return ParsedURL(source: .unknown, rawURL: urlString)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Spotify Parser
    // ──────────────────────────────────────────────

    /// Extracts the track ID from Spotify URLs
    /// Handles formats like:
    ///   https://open.spotify.com/track/3n3Ppam7vgaVa1iaRUIOKE
    ///   https://open.spotify.com/track/3n3Ppam7vgaVa1iaRUIOKE?si=abc123
    private func parseSpotify(_ urlString: String) -> ParsedURL {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ParsedURL(source: .spotify, rawURL: urlString)
        }

        let pathParts = components.path.split(separator: "/")

        // We only handle track links right now (not playlists or albums)
        guard pathParts.count >= 2,
              pathParts[pathParts.startIndex] == "track" else {
            return ParsedURL(
                source: .spotify,
                rawURL: urlString,
                error: "Only track links are supported. Try pasting a track URL."
            )
        }

        let trackID = String(pathParts[pathParts.index(after: pathParts.startIndex)])
        return ParsedURL(source: .spotify, rawURL: urlString, spotifyTrackID: trackID)
    }

    // ──────────────────────────────────────────────
    // MARK: - YouTube Parser
    // ──────────────────────────────────────────────

    /// Extracts the video ID from YouTube URLs
    /// Handles formats like:
    ///   https://www.youtube.com/watch?v=dQw4w9WgXcQ
    ///   https://youtu.be/dQw4w9WgXcQ
    private func parseYouTube(_ urlString: String) -> ParsedURL {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ParsedURL(source: .youtube, rawURL: urlString)
        }

        var videoID: String?

        // Format 1: youtube.com/watch?v=VIDEO_ID
        if let vParam = components.queryItems?.first(where: { $0.name == "v" }) {
            videoID = vParam.value
        }
        // Format 2: youtu.be/VIDEO_ID
        else if url.host?.contains("youtu.be") == true {
            videoID = components.path.replacingOccurrences(of: "/", with: "")
        }

        return ParsedURL(
            source: .youtube,
            rawURL: urlString,
            youtubeVideoID: videoID
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - SoundCloud Parser
    // ──────────────────────────────────────────────

    /// SoundCloud URLs don't have easily-extractable IDs, but we can parse
    /// the artist and track slug from the URL path
    /// Example: https://soundcloud.com/artist-name/track-name
    private func parseSoundCloud(_ urlString: String) -> ParsedURL {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ParsedURL(source: .soundcloud, rawURL: urlString)
        }

        let pathParts = components.path
            .split(separator: "/")
            .map(String.init)

        // Path is /artist/track-slug
        let artistSlug = pathParts[safe: 0]
        let trackSlug  = pathParts[safe: 1]

        // Convert slug to readable name: "my-favorite-song" → "my favorite song"
        let guessedTitle  = trackSlug?.replacingOccurrences(of: "-", with: " ")
        let guessedArtist = artistSlug?.replacingOccurrences(of: "-", with: " ")

        return ParsedURL(
            source: .soundcloud,
            rawURL: urlString,
            guessedTitle: guessedTitle?.capitalized,
            guessedArtist: guessedArtist?.capitalized
        )
    }
}

// ──────────────────────────────────────────────
// MARK: - ParsedURL
// The result of parsing a URL — contains everything we know about it
// ──────────────────────────────────────────────

struct ParsedURL {
    let source: URLSource
    let rawURL: String

    var spotifyTrackID: String? = nil   // Only set for Spotify URLs
    var youtubeVideoID: String? = nil   // Only set for YouTube URLs
    var guessedTitle: String? = nil     // Best-guess song title (from URL slug)
    var guessedArtist: String? = nil    // Best-guess artist name (from URL slug)
    var error: String? = nil            // Human-readable error if parsing failed

    var isValid: Bool {
        error == nil && (spotifyTrackID != nil || youtubeVideoID != nil || guessedTitle != nil)
    }
}
