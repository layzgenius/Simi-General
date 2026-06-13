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

    // Shared session with a short timeout — oEmbed calls should be fast
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 8
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

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
    ///   https://music.youtube.com/watch?v=dQw4w9WgXcQ
    ///   YouTube Music radio links: ?v=xxx&list=RDxxx&start_radio=1
    ///   (radio params are stripped — only v= is used)
    private func parseYouTube(_ urlString: String) -> ParsedURL {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ParsedURL(source: .youtube, rawURL: urlString)
        }

        var videoID: String?

        // Format 1: youtube.com/watch?v=VIDEO_ID  (also music.youtube.com)
        if let vParam = components.queryItems?.first(where: { $0.name == "v" }) {
            videoID = vParam.value
        }
        // Format 2: youtu.be/VIDEO_ID
        else if url.host?.contains("youtu.be") == true {
            videoID = components.path.replacingOccurrences(of: "/", with: "")
        }

        // Detect YouTube Music radio URLs.
        // list=RDxxx means it's an auto-generated radio mix.
        // start_radio=1 is the explicit radio flag.
        // When list=RD{same videoID}, the user is on the *seed* song of the radio —
        // not necessarily the song that was actively playing.
        let listValue = components.queryItems?.first(where: { $0.name == "list" })?.value ?? ""
        let isRadio = listValue.hasPrefix("RD") ||
                      components.queryItems?.first(where: { $0.name == "start_radio" })?.value == "1"

        return ParsedURL(
            source: .youtube,
            rawURL: urlString,
            youtubeVideoID: videoID,
            isYouTubeMusicRadio: isRadio
        )
    }

    // ──────────────────────────────────────────────
    // MARK: - SoundCloud oEmbed Title Lookup
    // ──────────────────────────────────────────────

    /// Fetches the real title and artist name for a SoundCloud track using
    /// SoundCloud's official free oEmbed endpoint — no API key needed.
    /// Much more reliable than slug-based guessing (slugs lose punctuation,
    /// features, capitalization, etc.)
    /// Returns (title, artist, thumbnailURL) or nil on failure.
    func fetchSoundCloudInfo(url: String) async -> (title: String, artist: String, thumbnailURL: String?)? {
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        guard let apiURL = URL(string: "https://soundcloud.com/oembed?url=\(encoded)&format=json"),
              let (data, _) = try? await session.data(from: apiURL),
              let json = try? JSONDecoder().decode(SoundCloudOEmbedResponse.self, from: data),
              !json.title.isEmpty else {
            return nil
        }
        return (title: json.title, artist: json.authorName, thumbnailURL: json.thumbnailUrl)
    }

    // ──────────────────────────────────────────────
    // MARK: - YouTube oEmbed Title Lookup
    // ──────────────────────────────────────────────

    /// Fetches the real title and uploader name for a YouTube video using
    /// YouTube's official free oEmbed endpoint — no API key needed.
    /// Returns (title, authorName) or nil on failure.
    func fetchYouTubeInfo(videoID: String) async -> (title: String, author: String)? {
        let encoded = "https://www.youtube.com/watch?v=\(videoID)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? videoID
        guard let url = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONDecoder().decode(YouTubeOEmbedResponse.self, from: data),
              !json.title.isEmpty else {
            return nil
        }
        return (title: json.title, author: json.authorName)
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

// ──────────────────────────────────────────────
// MARK: - YouTube oEmbed Response
// ──────────────────────────────────────────────

private struct YouTubeOEmbedResponse: Codable {
    let title: String
    let authorName: String
    enum CodingKeys: String, CodingKey {
        case title
        case authorName = "author_name"
    }
}

// ──────────────────────────────────────────────
// MARK: - SoundCloud oEmbed Response
// ──────────────────────────────────────────────

private struct SoundCloudOEmbedResponse: Codable {
    let title: String
    let authorName: String
    let thumbnailUrl: String?
    enum CodingKeys: String, CodingKey {
        case title
        case authorName  = "author_name"
        case thumbnailUrl = "thumbnail_url"
    }
}

// ──────────────────────────────────────────────

struct ParsedURL {
    let source: URLSource
    let rawURL: String

    var spotifyTrackID: String? = nil       // Only set for Spotify URLs
    var youtubeVideoID: String? = nil       // Only set for YouTube URLs
    var guessedTitle: String? = nil         // Best-guess song title (from URL slug)
    var guessedArtist: String? = nil        // Best-guess artist name (from URL slug)
    var error: String? = nil                // Human-readable error if parsing failed
    var isYouTubeMusicRadio: Bool = false   // True when URL has list=RD... (YouTube Music radio)

    var isValid: Bool {
        error == nil && (spotifyTrackID != nil || youtubeVideoID != nil || guessedTitle != nil)
    }
}
