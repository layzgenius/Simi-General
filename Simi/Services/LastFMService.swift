// LastFMService.swift
// Simi — Music Discovery App
//
// Last.fm is a music data service that's great for two things:
//   1. Genre tags — it has crowd-sourced tags like "indie pop", "dream pop", "shoegaze"
//   2. Similar artists — a huge database of "fans also like" relationships
//
// Requests are routed through the Cloudflare Worker proxy — the real API key
// lives server-side as a Worker environment secret (LASTFM_KEY).
//
// Upstream: https://ws.audioscrobbler.com/2.0/

import Foundation

class LastFMService {

    // ──────────────────────────────────────────────
    // MARK: - Proxy config (key held server-side)
    // ──────────────────────────────────────────────
    private let proxyURL = APIKeys.lastFMProxyURL
    private let proxyKey = APIKeys.proxyKey

    // ──────────────────────────────────────────────
    // MARK: - Fetch Genre Tags for a Track
    // ──────────────────────────────────────────────

    /// Returns the top genre tags for a song (e.g., ["indie pop", "dream pop", "chill"])
    /// Last.fm tags are crowd-sourced — they're surprisingly accurate for genre detection.
    /// Falls back to artist-level tags when track tags are missing (common for older songs).
    func fetchTags(title: String, artist: String) async throws -> [Genre] {
        let params = buildParams([
            "method": "track.getTopTags",
            "track": title,
            "artist": artist,
            "autocorrect": "1"
        ])

        guard let request = makeRequest(queryString: params) else {
            throw SimiError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(for: request)

        // Try track-level tags first
        if let result = try? JSONDecoder().decode(LastFMTagsResult.self, from: data),
           !result.toptags.tag.isEmpty {
            let allTags = result.toptags.tag
                .prefix(8)
                .map { $0.name.lowercased() }
            return genresToReturn(from: allTags)
        }

        // Fallback: artist-level tags (much broader coverage, especially for older/classic artists)
        // The Gap Band, Stevie Wonder, etc. all have rich artist tags even if track tags are sparse.
        simiLog("⚠️ No track tags for \"\(title)\" — falling back to artist tags for \(artist)")
        return await fetchArtistTags(artist: artist)
    }

    /// Fetches genre tags at the artist level — used as a fallback when track tags are missing.
    func fetchArtistTags(artist: String) async -> [Genre] {
        let params = buildParams([
            "method": "artist.getTopTags",
            "artist": artist,
            "autocorrect": "1"
        ])
        guard let request = makeRequest(queryString: params),
              let (data, _) = try? await URLSession.shared.data(for: request),
              let result = try? JSONDecoder().decode(LastFMTagsResult.self, from: data),
              !result.toptags.tag.isEmpty else {
            return [Genre(main: "Unknown")]
        }

        let allTags = result.toptags.tag
            .prefix(8)
            .map { $0.name.lowercased() }
        return genresToReturn(from: allTags)
    }

    /// Converts a flat tag list to Genre objects, preferring recognised genre keywords over
    /// mood/decade labels ("80s", "favorites", "seen live" etc.)
    private func genresToReturn(from tags: [String]) -> [Genre] {
        // Junk tags — crowd-sourced Last.fm noise that should never be shown to the user.
        let blockedTags: Set<String> = [
            "ass", "sexy", "sex", "hot", "naked", "nsfw", "explicit",
            "seen live", "favorites", "favourite", "favorite", "love",
            "my favorite", "my favourite", "awesome", "amazing", "great",
            "good", "best", "top", "liked", "owned", "have it",
            "wishlist", "to listen", "to buy", "heard on", "heard at",
            "00s", "10s", "20s", "30s", "40s", "50s", "60s", "70s", "80s", "90s",
            "2000s", "2010s", "2020s", "female vocalists", "male vocalists",
            "guitar", "drums", "bass", "piano", "vocals", "singer", "band",
            "long", "short", "slow", "fast", "loud", "quiet", "beautiful",
            "epic", "sad", "happy", "dark", "chill", "classic"
        ]

        let cleanTags = tags.filter { tag in
            !blockedTags.contains(tag) &&
            !blockedTags.contains(where: { tag == $0 }) &&
            tag.count > 2
        }

        // Tier 1: specific subgenres — more informative than broad genre labels.
        // e.g. "cloud rap" is preferred over "rap"; "psychedelic trap" over "trap".
        // Last.fm tags are ordered by play count — check for specifics first regardless of order.
        let specificSubgenres: Set<String> = [
            // Hip-hop / Trap subgenres
            "cloud rap", "cloud trap", "psychedelic trap", "melodic trap", "dark trap",
            "emo rap", "emo trap", "rage rap", "boom bap", "uk drill", "phonk", "grime",
            "alternative hip hop", "alternative rap", "experimental hip hop", "punk rap",
            "rap rock", "uk hip hop", "uk rap",
            // R&B / Soul subgenres
            "neo-soul", "neo soul", "slow jam", "slow jams", "quiet storm",
            "smooth r&b", "contemporary r&b", "new jack swing",
            // Rock / Alt subgenres
            "indie rock", "alt-rock", "hard rock", "classic rock", "grunge",
            "post-rock", "post-punk", "shoegaze", "darkwave", "new wave",
            // Pop subgenres
            "indie pop", "dream pop", "bedroom pop", "electropop", "synth-pop", "synth pop",
            "k-pop", "j-pop",
            // Electronic subgenres
            "lo-fi", "lofi", "chillwave", "synthwave", "vaporwave",
            "drum and bass", "dnb", "future bass", "hyperpop", "breakcore",
            "dubstep", "brostep", "filthstep", "hybrid trap",
            // Other
            "disco", "funk", "bossa nova", "afrobeats", "reggae",
        ]

        // Tier 2: broad genre keywords — fallback when no specific subgenre found
        let genreKeywords = [
            "soul", "r&b", "rnb", "funk", "hip-hop", "hip hop", "rap", "trap", "pop",
            "rock", "jazz", "blues", "electronic", "dance", "house", "techno", "edm",
            "indie", "folk", "country", "classical", "metal", "punk", "alternative",
            "reggae", "gospel", "disco", "neo-soul", "neo soul", "synth", "ambient",
            "lo-fi", "lofi", "drill", "phonk", "k-pop", "j-pop",
            "grime", "uk hip hop", "uk rap", "uk drill", "punk rap", "rap rock",
            "alternative hip hop", "alternative rap", "experimental hip hop"
        ]

        // Two-pass selection: specific first, then generic
        let mainTag: String
        if let specific = cleanTags.first(where: { specificSubgenres.contains($0) }) {
            mainTag = specific
        } else {
            mainTag = cleanTags.first(where: { tag in
                genreKeywords.contains(where: { tag.contains($0) || $0.contains(tag) })
            }) ?? cleanTags.first ?? tags.first ?? "Unknown"
        }

        // Sub-genre: first clean tag that differs from main and is an informative genre/mood label
        let subTag = cleanTags.first(where: { tag in
            tag != mainTag && (specificSubgenres.contains(tag) || genreKeywords.contains(where: { tag.contains($0) || $0.contains(tag) }))
        })

        return [Genre(main: mainTag.capitalized, sub: subTag?.capitalized)]
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Similar Tracks
    // ──────────────────────────────────────────────

    /// Gets a list of similar songs from Last.fm's "track.getSimilar" endpoint
    /// These are based on listening patterns — "people who liked X also liked Y"
    func fetchSimilarTracks(title: String, artist: String, limit: Int = 20) async throws -> [(title: String, artist: String)] {
        let params = buildParams([
            "method": "track.getSimilar",
            "track": title,
            "artist": artist,
            "limit": "\(limit)",
            "autocorrect": "1"
        ])

        guard let request = makeRequest(queryString: params) else {
            throw SimiError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(for: request)

        // Last.fm returns an error object when the track isn't in its database.
        // Return empty gracefully rather than crashing.
        guard let result = try? JSONDecoder().decode(LastFMSimilarTracksResult.self, from: data) else {
            return []
        }

        return result.similartracks.track.map {
            (title: $0.name, artist: $0.artist.name)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Raw Tags (for feature estimation)
    // ──────────────────────────────────────────────

    /// Returns the top Last.fm tag names for a track as lowercase strings.
    /// Used downstream to estimate energy/valence when AcousticBrainz has no data.
    /// Never throws — returns [] on any error.
    func fetchRawTags(title: String, artist: String) async -> [String] {
        let params = buildParams([
            "method": "track.getTopTags",
            "track": title,
            "artist": artist,
            "autocorrect": "1"
        ])
        if let request = makeRequest(queryString: params),
           let (data, _) = try? await URLSession.shared.data(for: request),
           let result = try? JSONDecoder().decode(LastFMTagsResult.self, from: data),
           !result.toptags.tag.isEmpty {
            return result.toptags.tag.prefix(8).map { $0.name.lowercased() }
        }

        // Fallback to artist tags so feature estimation works for classic/older songs
        let artistParams = buildParams([
            "method": "artist.getTopTags",
            "artist": artist,
            "autocorrect": "1"
        ])
        guard let artistRequest = makeRequest(queryString: artistParams),
              let (artistData, _) = try? await URLSession.shared.data(for: artistRequest),
              let artistResult = try? JSONDecoder().decode(LastFMTagsResult.self, from: artistData) else {
            return []
        }
        return artistResult.toptags.tag.prefix(8).map { $0.name.lowercased() }
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Similar Tracks (with Artist Fallback)
    // ──────────────────────────────────────────────

    /// Smart wrapper around track.getSimilar with a two-stage fallback:
    ///   Stage 1 — track.getSimilar (best: listening-pattern data)
    ///   Stage 2 — artist.getSimilar → top tracks from similar artists
    ///             (kicks in when the track isn't in Last.fm's database,
    ///              which happens often for niche/regional/YouTube artists)
    func fetchSimilarTracksWithFallback(title: String, artist: String) async -> [(title: String, artist: String)] {
        // Stage 1 — track-level similar tracks.
        // Use a large limit (50) so we surface enough cross-artist results — at limit 20,
        // Last.fm tends to fill most slots with the source artist's own catalogue.
        // Caps: source artist max 2 (they ARE similar, but we want variety);
        //       any other single artist max 3 (prevents a different artist flooding the pool).
        if let tracks = try? await fetchSimilarTracks(title: title, artist: artist, limit: 50),
           !tracks.isEmpty {
            // Loose pool cap — only prevents complete flooding by one artist.
            // Final artist diversity enforcement (2 source / 3 others) happens in
            // RecommendationEngine.applyArtistDiversity after scoring all sources.
            let sourceKey = artist.lowercased().trimmingCharacters(in: .whitespaces)
            var artistCounts: [String: Int] = [:]
            let diversified = tracks.filter { track in
                let key = track.artist.lowercased().trimmingCharacters(in: .whitespaces)
                let cap = key == sourceKey ? 5 : 7
                let count = artistCounts[key, default: 0]
                if count < cap {
                    artistCounts[key] = count + 1
                    return true
                }
                return false
            }
            return diversified
        }

        // Stage 2 — get similar artists, then pull top tracks from each
        simiLog("⚠️ No track.getSimilar results for \"\(title)\" — falling back to artist.getSimilar")
        let similarArtists = (try? await fetchSimilarArtists(artist: artist)) ?? []
        guard !similarArtists.isEmpty else { return [] }

        var fallback: [(title: String, artist: String)] = []
        var seen = Set<String>()

        for similarArtist in similarArtists.prefix(6) {
            let topTracks = await fetchArtistTopTracks(artist: similarArtist)
            for track in topTracks.prefix(4) {
                let key = "\(track.title.lowercased())|\(track.artist.lowercased())"
                if seen.insert(key).inserted {
                    fallback.append(track)
                }
            }
        }

        simiLog("✅ Artist fallback: \(fallback.count) tracks from \(similarArtists.prefix(6).count) similar artists")
        return fallback
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Artist Top Tracks
    // ──────────────────────────────────────────────

    /// Returns an artist's most popular tracks — used as a fallback when track.getSimilar
    /// returns nothing (e.g. niche artists or songs too new to have listener data)
    func fetchArtistTopTracks(artist: String) async -> [(title: String, artist: String)] {
        let params = buildParams([
            "method": "artist.getTopTracks",
            "artist": artist,
            "limit": "5",
            "autocorrect": "1"
        ])
        guard let request = makeRequest(queryString: params),
              let (data, _) = try? await URLSession.shared.data(for: request),
              let result = try? JSONDecoder().decode(LastFMArtistTopTracksResult.self, from: data) else {
            return []
        }
        return result.toptracks.track.map { (title: $0.name, artist: artist) }
    }

    // ──────────────────────────────────────────────
    // MARK: - Tag Top Tracks (cross-era candidate pool)
    // ──────────────────────────────────────────────

    /// Fetches the most popular tracks for a Last.fm tag.
    /// Used to expand the candidate pool beyond co-listening patterns —
    /// "slow jam" surfaces Frank Ocean and Barry White alongside 2000s R&B,
    /// where track.getSimilar would only return era peers.
    func fetchTopTracks(forTag tag: String, limit: Int = 12) async -> [(title: String, artist: String)] {
        let params = buildParams([
            "method": "tag.getTopTracks",
            "tag": tag,
            "limit": "\(limit)"
        ])
        guard let request = makeRequest(queryString: params),
              let (data, _) = try? await URLSession.shared.data(for: request),
              let result = try? JSONDecoder().decode(LastFMTagTopTracksResult.self, from: data) else {
            return []
        }
        return result.tracks.track.map { (title: $0.name, artist: $0.artist.name) }
    }

    /// Selects up to 5 emotional/subgenre tags from a song's raw tag list and queries
    /// tag.getTopTracks for each — concurrently. Returns a deduplicated cross-era pool.
    func fetchEmotionalTagCandidates(rawTags: [String]) async -> [(title: String, artist: String)] {
        let queries = selectEmotionalQueries(from: rawTags)
        guard !queries.isEmpty else { return [] }

        simiLog("🎭 Emotional tag queries: \(queries)")

        var results: [(title: String, artist: String)] = []
        var seen = Set<String>()

        await withTaskGroup(of: [(title: String, artist: String)].self) { group in
            for tag in queries {
                group.addTask { await self.fetchTopTracks(forTag: tag, limit: 12) }
            }
            for await tracks in group {
                for t in tracks {
                    let key = "\(t.title.lowercased())|\(t.artist.lowercased())"
                    if seen.insert(key).inserted { results.append(t) }
                }
            }
        }

        simiLog("🎭 Tag pool: \(results.count) candidates from \(queries.count) tags")
        return results
    }

    /// Picks which emotional/subgenre tags to query from a song's raw tag list.
    /// Only includes tags specific enough to produce cross-era results — broad genre
    /// tags (r&b, pop, rock) are excluded because they would mirror the co-listening pool.
    private func selectEmotionalQueries(from rawTags: [String]) -> [String] {
        // Specific subgenre/mood tags that work well as tag.getTopTracks queries.
        // These produce meaningfully cross-era results (e.g. "slow jam" → Marvin Gaye + Frank Ocean).
        let directQueryable: Set<String> = [
            // Slow/romantic R&B
            "slow jam", "slow jams", "quiet storm", "neo-soul", "neo soul",
            // Indie / dream
            "dream pop", "bedroom pop", "indie folk", "shoegaze", "chillwave", "melancholic",
            // Mood / atmosphere — injected by audio-feature derivation in RecommendationEngine
            "late night", "dark", "sad", "feel good", "upbeat", "energetic", "aggressive",
            // Electronic chill
            "lo-fi", "lofi", "ambient", "chillhop", "vaporwave",
            // Electronic energetic
            "hyperpop", "future bass",
            // Electronic subgenres
            "techno", "trance", "drum and bass", "dubstep", "breakcore",
            "synthwave", "synth-pop", "hardstyle",
            // Rock / alt subgenres
            "post-rock", "post-punk", "emo", "darkwave", "math rock",
            "punk", "metal", "grunge", "indie rock", "alt-rock", "classic rock",
            // Soul / vintage
            "funk", "soul", "disco", "motown", "gospel", "bossa nova",
            "reggae", "afrobeats", "house",
            // Hip-hop specific — general to specific
            "boom bap", "cloud rap", "cloud trap", "psychedelic trap", "dark trap",
            "melodic trap", "melodic rap", "emo trap", "emo rap", "rage rap",
            "trap", "drill", "uk drill", "phonk", "grime", "punk rap",
            "alternative hip hop", "alternative rap", "experimental hip hop",
            // Acoustic / singer-songwriter
            "folk", "acoustic", "singer-songwriter",
            // Jazz / blues
            "jazz", "blues",
            // Pop subgenres
            "indie pop", "electropop", "k-pop", "j-pop",
        ]
        // Broad / mood tags remapped to more specific Last.fm query equivalents.
        let mappedQueries: [String: String] = [
            "romantic":      "slow jam",
            "sensual":       "slow jam",
            "seductive":     "slow jam",
            "bedroom":       "bedroom pop",
            "chill":         "late night",     // "chill" alone is too vague — late night is more evocative
            "chill out":     "lo-fi",
            "chillout":      "lo-fi",
            "melancholic":   "melancholic",
            "melancholy":    "melancholic",
            "sad":           "melancholic",
            "dark":          "melancholic",    // was "darkwave" — wrong genre for modern dark trap/r&b
            "aggressive":    "aggressive",
            "heavy":         "metal",
            "party":         "disco",
            "workout":       "drum and bass",
            "summer":        "indie pop",
            "electronic":    "synthwave",
            "nocturnal":     "late night",
            "dreamy":        "cloud rap",      // dreamy trap / cloud rap overlap
            "atmospheric":   "cloud rap",
            "hazy":          "cloud rap",
            "woozy":         "psychedelic trap",
            "moody":         "melancholic",
            "introspective": "cloud rap",
            "trippy":        "psychedelic trap",
            "ethereal":      "dream pop",
            "psychedelic":   "psychedelic trap",
            "stoner":        "cloud rap",
            // Broad genre tags — map to more evocative specific queries
            "rnb":           "late night",   // R&B with dark valence → late-night/slow-jam feel
            "r&b":           "late night",
        ]

        var queries: [String] = []
        var seen = Set<String>()
        for tag in rawTags {
            let q: String?
            if directQueryable.contains(tag) {
                q = tag
            } else {
                q = mappedQueries[tag]
            }
            guard let q, seen.insert(q).inserted else { continue }
            queries.append(q)
            if queries.count >= 5 { break }
        }
        return queries
    }

    // ──────────────────────────────────────────────
    // MARK: - Fetch Similar Artists
    // ──────────────────────────────────────────────

    /// Gets artists similar to a given artist — useful for broadening recommendations
    func fetchSimilarArtists(artist: String) async throws -> [String] {
        let params = buildParams([
            "method": "artist.getSimilar",
            "artist": artist,
            "limit": "10",
            "autocorrect": "1"
        ])

        guard let request = makeRequest(queryString: params) else {
            throw SimiError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONDecoder().decode(LastFMSimilarArtistsResult.self, from: data)

        return result.similarartists.artist.map { $0.name }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helper
    // ──────────────────────────────────────────────

    /// Builds the URL query string, always including `format=json`.
    /// The real API key is injected server-side by the Cloudflare Worker.
    private func buildParams(_ params: [String: String]) -> String {
        var all = params
        all["format"] = "json"

        return all.map { key, value in
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(key)=\(encodedValue)"
        }.joined(separator: "&")
    }

    /// Constructs a URLRequest aimed at the Worker proxy with the shared auth header.
    private func makeRequest(queryString: String) -> URLRequest? {
        guard let url = URL(string: "\(proxyURL)?\(queryString)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(proxyKey, forHTTPHeaderField: "X-Proxy-Key")
        return request
    }
}

// ──────────────────────────────────────────────
// MARK: - Last.fm API Response Types
// ──────────────────────────────────────────────

private struct LastFMTagsResult: Codable {
    let toptags: LastFMTopTags
}
private struct LastFMTopTags: Codable {
    let tag: [LastFMTag]
}
private struct LastFMTag: Codable {
    let name: String
    let count: Int
}

private struct LastFMSimilarTracksResult: Codable {
    let similartracks: LastFMSimilarTracks
}
private struct LastFMSimilarTracks: Codable {
    let track: [LastFMTrack]
}
private struct LastFMTrack: Codable {
    let name: String
    let artist: LastFMTrackArtist
}
private struct LastFMTrackArtist: Codable {
    let name: String
}

private struct LastFMSimilarArtistsResult: Codable {
    let similarartists: LastFMSimilarArtists
}
private struct LastFMSimilarArtists: Codable {
    let artist: [LastFMArtist]
}
private struct LastFMArtist: Codable {
    let name: String
}

private struct LastFMArtistTopTracksResult: Codable {
    let toptracks: LastFMArtistTopTracks
}
private struct LastFMArtistTopTracks: Codable {
    let track: [LastFMTopTrack]
}
private struct LastFMTopTrack: Codable {
    let name: String
}

private struct LastFMTagTopTracksResult: Codable {
    let tracks: LastFMTagTopTracks
}
private struct LastFMTagTopTracks: Codable {
    let track: [LastFMTagTrack]
}
private struct LastFMTagTrack: Codable {
    let name: String
    let artist: LastFMTrackArtist
}

