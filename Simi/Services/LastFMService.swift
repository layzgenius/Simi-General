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
            // Latin / Afro-Caribbean subgenres — must be listed before generic "alternative" sweep
            // so that "latin alternative" (iLe, Natalia Lafourcade) resolves to latin, not rock.
            "latin", "latin alternative", "latin pop", "latin jazz", "latin rock", "latin trap",
            "latin indie", "nueva cancion", "nueva canción",
            "salsa", "cumbia", "bachata", "merengue", "vallenato", "reggaeton",
            "afrobeats", "afropop", "afro-cuban", "afro-caribbean",
            // Other
            "disco", "funk", "bossa nova", "reggae",
        ]

        // Latin / Afro-Caribbean override: scan ALL tags regardless of position.
        // "latin" and its subgenres get misclassified when Last.fm returns
        // "alternative" or "electronic" before "latin" in the tag ordering.
        // Like the K-pop override, this scans the full list so the identity wins.
        let latinIdentifiers: Set<String> = [
            "latin", "latin alternative", "latin pop", "latin jazz", "latin rock", "latin trap",
            "salsa", "cumbia", "bachata", "merengue", "vallenato", "reggaeton",
            "nueva cancion", "nueva canción", "afro-cuban", "afro-caribbean",
            "latin indie", "bossa nova",
        ]
        if let found = cleanTags.first(where: { latinIdentifiers.contains($0) }) {
            return [Genre(main: found.capitalized, sub: nil)]
        }

        // Tier 2: broad genre keywords — fallback when no specific subgenre found.
        let genreKeywords = [
            "soul", "r&b", "rnb", "funk", "hip-hop", "hip hop", "rap", "trap", "pop",
            "rock", "jazz", "blues", "electronic", "dance", "house", "techno", "edm",
            "indie", "folk", "country", "classical", "metal", "punk",
            "reggae", "reggaeton", "latin", "salsa", "cumbia", "bachata", "merengue",
            "afrobeats", "afropop", "gospel", "disco", "neo-soul", "neo soul", "synth", "ambient",
            "lo-fi", "lofi", "drill", "phonk", "k-pop", "j-pop",
            "grime", "uk hip hop", "uk rap", "uk drill", "punk rap", "rap rock",
            "alternative hip hop", "alternative rap", "experimental hip hop",
            "alternative",
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
    /// Fetches artist-level top tags as raw lowercase strings.
    /// More reliable than track-level tags for genre identity — community can mislabel
    /// a single track as "trap" but an artist's overall tag profile tells the truth.
    func fetchArtistRawTags(artist: String) async -> [String] {
        let params = buildParams([
            "method": "artist.getTopTags",
            "artist": artist,
            "autocorrect": "1"
        ])
        guard let request = makeRequest(queryString: params),
              let (data, _) = try? await URLSession.shared.data(for: request),
              let result = try? JSONDecoder().decode(LastFMTagsResult.self, from: data) else {
            return []
        }
        return result.toptags.tag.prefix(8).map { $0.name.lowercased() }
    }

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
        // 30 is sufficient: the tag-based pool (pop rap, melodic rap, luxury rap) now fills
        // the front of the candidate queue, so we only need the strongest co-listening signal
        // from Last.fm — the bottom of a 50-track social-graph list is low-signal noise.
        // Caps: source artist max 2; any other single artist max 3.
        if let tracks = try? await fetchSimilarTracks(title: title, artist: artist, limit: 50),
           !tracks.isEmpty {
            // Pool-level cap: max 2 per artist so no single artist eats the pool.
            // Final enforcement (1 per artist) happens in applyArtistDiversity after scoring.
            let sourceKey = artist.lowercased().trimmingCharacters(in: .whitespaces)
            var artistCounts: [String: Int] = [:]
            let diversified = tracks.filter { track in
                let key = track.artist.lowercased().trimmingCharacters(in: .whitespaces)
                let cap = key == sourceKey ? 1 : 2
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
    func fetchArtistTopTracks(artist: String, limit: Int = 5) async -> [(title: String, artist: String)] {
        let params = buildParams([
            "method": "artist.getTopTracks",
            "artist": artist,
            "limit": "\(limit)",
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
    func fetchTopTracks(forTag tag: String, limit: Int = 12, page: Int = 1) async -> [(title: String, artist: String)] {
        let params = buildParams([
            "method": "tag.getTopTracks",
            "tag": tag,
            "limit": "\(limit)",
            "page": "\(page)"
        ])
        guard let request = makeRequest(queryString: params),
              let (data, _) = try? await URLSession.shared.data(for: request),
              let result = try? JSONDecoder().decode(LastFMTagTopTracksResult.self, from: data) else {
            return []
        }
        return result.tracks.track.map { (title: $0.name, artist: $0.artist.name) }
    }

    /// Selects up to 5 emotional/subgenre tags from a song's raw tag list and queries
    /// tag.getTopTracks for each — on TWO pages concurrently.
    /// Page 1: top-of-tag (cross-era anchor tracks)
    /// Page 2: deeper cuts — still vibe-verified by community taggers but less mainstream
    func fetchEmotionalTagCandidates(rawTags: [String]) async -> [(title: String, artist: String)] {
        let queries = selectEmotionalQueries(from: rawTags)
        guard !queries.isEmpty else { return [] }

        simiLog("🎭 Emotional tag queries: \(queries)")

        var results: [(title: String, artist: String)] = []
        var seen = Set<String>()

        await withTaskGroup(of: [(title: String, artist: String)].self) { group in
            for tag in queries {
                group.addTask { await self.fetchTopTracks(forTag: tag, limit: 15, page: 1) }
                group.addTask { await self.fetchTopTracks(forTag: tag, limit: 15, page: 2) }
            }
            for await tracks in group {
                for t in tracks {
                    let key = "\(t.title.lowercased())|\(t.artist.lowercased())"
                    if seen.insert(key).inserted { results.append(t) }
                }
            }
        }

        simiLog("🎭 Tag pool: \(results.count) candidates from \(queries.count) tags (p1+p2)")
        return results
    }

    /// Picks which emotional/subgenre tags to query from a song's raw tag list.
    /// Only includes tags specific enough to produce cross-era results — broad genre
    /// tags (r&b, pop, rock) are excluded because they would mirror the co-listening pool.
    /// Genre family gate: tags whose family is incompatible with the source are rejected.
    /// e.g. Flashing Lights (hip-hop) tagged "electronic" → "synthwave" → blocked.
    private func selectEmotionalQueries(from rawTags: [String]) -> [String] {
        let directQueryable: Set<String> = [
            "60s", "70s", "80s", "90s", "2000s", "2010s", "2020s",
            "slow jam", "slow jams", "quiet storm", "neo-soul", "neo soul",
            "dream pop", "bedroom pop", "indie folk", "shoegaze", "chillwave", "melancholic",
            "late night", "dark", "sad", "feel good", "upbeat", "energetic", "aggressive",
            "lo-fi", "lofi", "ambient", "chillhop", "vaporwave",
            "hyperpop", "future bass",
            "techno", "trance", "drum and bass", "dubstep", "breakcore",
            "synthwave", "synth-pop", "hardstyle",
            "post-rock", "post-punk", "emo", "darkwave", "math rock",
            "punk", "metal", "grunge", "indie rock", "alt-rock", "classic rock",
            "funk", "soul", "disco", "motown", "gospel", "bossa nova",
            "reggae", "afrobeats", "house",
            "boom bap", "cloud rap", "cloud trap", "psychedelic trap", "dark trap",
            "melodic trap", "melodic rap", "emo trap", "emo rap", "rage rap",
            "pop rap", "luxury rap",
            "trap", "drill", "uk drill", "phonk", "grime", "punk rap",
            "alternative hip hop", "alternative rap", "experimental hip hop",
            "rap rock", "trap soul",
            "folk", "acoustic", "singer-songwriter",
            "jazz", "blues",
            "indie pop", "electropop", "k-pop", "j-pop",
        ]
        let mappedQueries: [String: String] = [
            "romantic":      "slow jam",
            "sensual":       "slow jam",
            "seductive":     "slow jam",
            "bedroom":       "bedroom pop",
            "chill":         "late night",
            "chill out":     "lo-fi",
            "chillout":      "lo-fi",
            "melancholic":   "melancholic",
            "melancholy":    "melancholic",
            "sad":           "melancholic",
            "dark":          "melancholic",
            "aggressive":    "aggressive",
            "heavy":         "metal",
            "party":         "disco",
            "workout":       "drum and bass",
            "summer":        "indie pop",
            // "electronic" intentionally unmapped — maps to "synthwave" which is wrong for
            // non-electronic sources (hip-hop with synth production, R&B, etc.)
            "nocturnal":     "late night",
            "dreamy":        "cloud rap",
            "atmospheric":   "cloud rap",
            "hazy":          "cloud rap",
            "woozy":         "psychedelic trap",
            "moody":         "melancholic",
            "introspective": "cloud rap",
            "trippy":        "psychedelic trap",
            "ethereal":      "dream pop",
            "psychedelic":   "psychedelic trap",
            "stoner":        "cloud rap",
        ]

        // ── Genre family gate ────────────────────────────────────────────────────
        // Detect source family from top raw tags, then block query tags whose family
        // is incompatible. Mood/era tags (late night, 2000s, melancholic, etc.) have
        // no family entry and always pass through.
        let sourceFamilyMap: [String: String] = [
            "hip-hop": "hiphop", "hip hop": "hiphop", "rap": "hiphop",
            "trap": "hiphop", "drill": "hiphop", "grime": "hiphop", "phonk": "hiphop",
            "r&b": "rnb", "rnb": "rnb", "soul": "rnb", "funk": "rnb", "neo-soul": "rnb",
            "pop": "pop", "indie pop": "pop", "synth-pop": "pop", "electropop": "pop",
            "rock": "rock", "indie rock": "rock", "metal": "rock", "punk": "rock",
            "alternative": "rock", "indie": "rock", "grunge": "rock",
            "electronic": "electronic", "edm": "electronic", "house": "electronic",
            "techno": "electronic", "ambient": "electronic", "dubstep": "electronic",
            "folk": "folk", "acoustic": "folk", "singer-songwriter": "folk",
            "jazz": "jazz", "blues": "jazz",
            "classical": "classical",
        ]
        let tagFamilyMap: [String: String] = [
            "synthwave": "electronic", "synth-pop": "electronic", "techno": "electronic",
            "trance": "electronic", "drum and bass": "electronic", "dubstep": "electronic",
            "breakcore": "electronic", "hardstyle": "electronic", "hyperpop": "electronic",
            "future bass": "electronic", "house": "electronic", "vaporwave": "electronic",
            "chillwave": "electronic", "lo-fi": "electronic", "lofi": "electronic",
            "ambient": "electronic", "chillhop": "electronic",
            "post-rock": "rock", "post-punk": "rock", "emo": "rock", "darkwave": "rock",
            "math rock": "rock", "punk": "rock", "metal": "rock", "grunge": "rock",
            "indie rock": "rock", "alt-rock": "rock", "classic rock": "rock", "shoegaze": "rock",
            "dream pop": "pop", "bedroom pop": "pop", "indie pop": "pop",
            "electropop": "pop", "k-pop": "pop", "j-pop": "pop",
            "boom bap": "hiphop", "cloud rap": "hiphop", "cloud trap": "hiphop",
            "psychedelic trap": "hiphop", "dark trap": "hiphop", "melodic trap": "hiphop",
            "melodic rap": "hiphop", "emo trap": "hiphop", "emo rap": "hiphop",
            "rage rap": "hiphop", "pop rap": "hiphop", "luxury rap": "hiphop",
            "trap": "hiphop", "drill": "hiphop", "uk drill": "hiphop", "phonk": "hiphop",
            "grime": "hiphop", "punk rap": "hiphop", "alternative hip hop": "hiphop",
            "alternative rap": "hiphop", "experimental hip hop": "hiphop",
            "rap rock": "hiphop", "trap soul": "hiphop",
            "slow jam": "rnb", "slow jams": "rnb", "quiet storm": "rnb",
            "neo-soul": "rnb", "neo soul": "rnb", "funk": "rnb", "soul": "rnb",
            "motown": "rnb", "disco": "rnb",
            "folk": "folk", "acoustic": "folk", "singer-songwriter": "folk", "indie folk": "folk",
            "jazz": "jazz", "blues": "jazz",
        ]
        // Which tag families a source family accepts.
        // hiphop embraces rnb (soul samples, neo-soul features are core to the genre).
        // rnb embraces hiphop and jazz for the same reason.
        let compatibleFamilies: [String: Set<String>] = [
            "hiphop":     ["hiphop", "rnb"],
            "rnb":        ["rnb", "hiphop", "jazz"],
            "pop":        ["pop", "rnb"],
            "rock":       ["rock", "folk"],
            "electronic": ["electronic", "pop"],
            "folk":       ["folk", "rock"],
            "jazz":       ["jazz", "rnb", "folk"],
            "classical":  ["classical"],
        ]

        // Detect source family from top 4 raw tags
        var sourceFamily = "unknown"
        for tag in rawTags.prefix(4) {
            if let fam = sourceFamilyMap[tag.lowercased()] {
                sourceFamily = fam
                break
            }
        }
        let allowed = compatibleFamilies[sourceFamily] ?? []

        // Mood-first: reorder rawTags so feel/emotion tags are picked before genre tags.
        // Last.fm returns tags sorted by vote weight — popular genre labels (hip-hop, rap)
        // come before feel labels (melancholic, atmospheric) even when feel is the stronger
        // discovery signal. "melancholic" surfaces cross-genre emotional twins. "hip-hop"
        // just surfaces the genre sorted by plays.
        let moodPriorityInputTags: Set<String> = [
            "melancholic", "melancholy", "dark", "sad", "aggressive", "ethereal",
            "atmospheric", "dreamy", "introspective", "nostalgic", "hazy", "late night",
            "moody", "woozy", "trippy", "nocturnal", "stoner", "emotional", "bittersweet",
            "romantic", "sensual", "seductive", "chill", "chill out", "chillout",
            "lo-fi", "lofi", "60s", "70s", "80s", "90s", "2000s", "2010s", "2020s",
        ]
        let sortedTags = rawTags.sorted { a, b in
            let aMood = moodPriorityInputTags.contains(a.lowercased())
            let bMood = moodPriorityInputTags.contains(b.lowercased())
            if aMood && !bMood { return true }
            if !aMood && bMood { return false }
            return false
        }

        var queries: [String] = []
        var seen = Set<String>()
        for tag in sortedTags {
            let q: String?
            if directQueryable.contains(tag) {
                q = tag
            } else {
                q = mappedQueries[tag]
            }
            guard let q, seen.insert(q).inserted else { continue }
            // Family gate: if this query tag has a known genre family, reject it when
            // incompatible with the source. Tags with no family entry (era/mood/universal)
            // always pass through.
            if let tagFamily = tagFamilyMap[q], !allowed.contains(tagFamily) {
                simiLog("🚫 Tag pool family gate: skipping \"\(q)\" (\(tagFamily)) for \(sourceFamily) source")
                continue
            }
            queries.append(q)
            if queries.count >= 8 { break }
        }
        return queries
    }

    // ──────────────────────────────────────────────
    // MARK: - Underground Mood-Artist Chain
    // ──────────────────────────────────────────────

    /// Returns artists who specialize in a given tag.
    /// Page 2 skips the genre's mainstream gatekeepers (page 1 for "melancholic"
    /// returns Kanye, Drake, etc.) and surfaces underground specialists who define
    /// the tag's emotional identity.
    func fetchTopArtistsByTag(tag: String, page: Int = 2, limit: Int = 10) async -> [String] {
        let params = buildParams([
            "method": "tag.getTopArtists",
            "tag": tag,
            "limit": "\(limit)",
            "page": "\(page)"
        ])
        guard let request = makeRequest(queryString: params),
              let (data, _) = try? await URLSession.shared.data(for: request),
              let result = try? JSONDecoder().decode(LastFMTagTopArtistsResult.self, from: data) else {
            return []
        }
        return result.topartists.artist.map { $0.name }
    }

    /// Builds a discovery pool from underground artists who specialize in the source's
    /// emotional tags. Uses page 2 of tag.getTopArtists (past the mainstream acts) then
    /// fetches each artist's top tracks. Mood tags (melancholic, atmospheric, dark) produce
    /// artists who define a feel — not just a genre.
    func fetchUndergroundMoodCandidates(rawTags: [String]) async -> [(title: String, artist: String)] {
        let moodTags: Set<String> = [
            "melancholic", "melancholy", "dark", "sad", "aggressive", "ethereal",
            "atmospheric", "dreamy", "introspective", "nostalgic", "hazy", "late night",
            "moody", "emotional", "woozy", "trippy", "nocturnal", "chill", "bittersweet",
        ]
        let selected = rawTags.filter { moodTags.contains($0.lowercased()) }.prefix(3)
        guard !selected.isEmpty else { return [] }

        simiLog("🌊 Underground mood chain: \(Array(selected))")

        var results: [(title: String, artist: String)] = []
        var seen = Set<String>()

        await withTaskGroup(of: [(title: String, artist: String)].self) { group in
            for tag in selected {
                group.addTask {
                    let artists = await self.fetchTopArtistsByTag(tag: tag, page: 2, limit: 8)
                    var tracks: [(title: String, artist: String)] = []
                    await withTaskGroup(of: [(title: String, artist: String)].self) { inner in
                        for artist in artists.prefix(5) {
                            inner.addTask { await self.fetchArtistTopTracks(artist: artist, limit: 4) }
                        }
                        for await t in inner { tracks.append(contentsOf: t) }
                    }
                    return tracks
                }
            }
            for await tracks in group {
                for t in tracks {
                    let key = "\(t.title.lowercased())|\(t.artist.lowercased())"
                    if seen.insert(key).inserted { results.append(t) }
                }
            }
        }

        simiLog("🌊 Underground mood pool: \(results.count) candidates from \(selected.count) mood tags")
        return results
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

        // Must not leave & unencoded in values — it would be parsed as a param separator.
        // .urlQueryAllowed keeps & as-is, so remove it (and = / +) from the value set.
        var valueAllowed = CharacterSet.urlQueryAllowed
        valueAllowed.remove(charactersIn: "&+=")
        return all.map { key, value in
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value
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

private struct LastFMTagTopArtistsResult: Codable {
    let topartists: LastFMTagTopArtists
}
private struct LastFMTagTopArtists: Codable {
    let artist: [LastFMArtist]
}

