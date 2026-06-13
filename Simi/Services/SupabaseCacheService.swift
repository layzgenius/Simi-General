// SupabaseCacheService.swift
// Simi — Music Discovery App
//
// Server-side cache + genre tag enrichment database via Supabase.
//
// Cache tables (PostgREST REST API):
//   song_tags_cache       — Last.fm/MusicBrainz tag results (TTL: 7 days)
//   audio_features_cache  — Estimated audio features (TTL: 30 days)
//   similar_tracks_cache  — Last.fm similar track lists (TTL: 1 day)
//
// Enrichment table:
//   genre_tag_map         — Energy/valence/danceability per tag.
//                           Seeded with all hardcoded values from RecommendationEngine.
//                           Call storeTagMapping() to add new tags when discovered.

import Foundation

class SupabaseCacheService {

    // In debug builds the cache is bypassed so test runs always hit live APIs and never
    // lock in stale values. Set SIMI_CACHE_ENABLED=1 in a scheme's environment variables
    // to enable caching in a specific debug run without touching this file.
    #if DEBUG
    private let cacheEnabled = ProcessInfo.processInfo.environment["SIMI_CACHE_ENABLED"] == "1"
    #else
    private let cacheEnabled = true
    #endif

    private let baseURL   = APIKeys.supabaseURL
    private let anonKey   = APIKeys.supabaseAnonKey

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 6   // fast timeout — cache miss is fine
        cfg.timeoutIntervalForResource = 10
        return URLSession(configuration: cfg)
    }()

    // ──────────────────────────────────────────────
    // MARK: - Cache Key
    // ──────────────────────────────────────────────

    private func cacheKey(title: String, artist: String) -> String {
        let t = title.lowercased().trimmingCharacters(in: .whitespaces)
        let a = artist.lowercased().trimmingCharacters(in: .whitespaces)
        return "\(t)|\(a)"
    }

    // ──────────────────────────────────────────────
    // MARK: - Song Tags Cache
    // ──────────────────────────────────────────────

    func lookupTags(title: String, artist: String) async -> [String]? {
        guard cacheEnabled else { return nil }
        let key = cacheKey(title: title, artist: artist)
        guard let url = URL(string: "\(baseURL)/rest/v1/song_tags_cache?cache_key=eq.\(key.urlEncoded)&expires_at=gt.\(now())&select=tags&limit=1") else { return nil }

        guard let data = try? await get(url: url),
              let rows = try? JSONDecoder().decode([[String: TagsValue]].self, from: data),
              let first = rows.first,
              let tags = first["tags"]?.value else { return nil }

        simiLog("✅ Supabase tag cache hit: \"\(title)\"")
        return tags
    }

    func storeTags(title: String, artist: String, tags: [String], source: String = "lastfm") async {
        guard cacheEnabled else { return }
        guard let url = URL(string: "\(baseURL)/rest/v1/song_tags_cache") else { return }
        let key = cacheKey(title: title, artist: artist)
        let body: [String: Any] = [
            "cache_key": key,
            "title": title,
            "artist": artist,
            "tags": tags,
            "source": source
        ]
        await upsert(url: url, body: body, conflictColumn: "cache_key")
    }

    // ──────────────────────────────────────────────
    // MARK: - Audio Features Cache
    // ──────────────────────────────────────────────

    func lookupFeatures(title: String, artist: String) async -> AudioFeatures? {
        guard cacheEnabled else { return nil }
        let key = cacheKey(title: title, artist: artist)
        guard let url = URL(string: "\(baseURL)/rest/v1/audio_features_cache?cache_key=eq.\(key.urlEncoded)&expires_at=gt.\(now())&select=features&limit=1") else { return nil }

        guard let data = try? await get(url: url),
              let rows = try? JSONDecoder().decode([[String: FeaturesValue]].self, from: data),
              let first = rows.first,
              let features = first["features"]?.value else { return nil }

        simiLog("✅ Supabase feature cache hit: \"\(title)\"")
        return features
    }

    func storeFeatures(title: String, artist: String, features: AudioFeatures, source: String = "tag_estimated") async {
        guard cacheEnabled else { return }
        guard let url = URL(string: "\(baseURL)/rest/v1/audio_features_cache"),
              let featuresData = try? JSONEncoder().encode(features),
              let featuresJSON = try? JSONSerialization.jsonObject(with: featuresData) else { return }
        let key = cacheKey(title: title, artist: artist)
        // TTL is proportional to data quality — better sources stay cached longer.
        // librosa (Railway full-analysis) is our highest-quality on-device source,
        // on par with Spotify features. Estimated data self-corrects sooner.
        let ttlDays: Int
        switch source {
        case "spotify", "librosa": ttlDays = 30  // ground-truth sources
        case "refreshed":          ttlDays = 21  // manually re-analyzed
        case "preview_audio":      ttlDays = 7   // on-device chroma + energy only
        case "tag_estimated":      ttlDays = 2   // genre averages — least reliable
        default:                   ttlDays = 1   // bpm_only or unknown
        }
        let expiresAt = ISO8601DateFormatter().string(
            from: Calendar.current.date(byAdding: .day, value: ttlDays, to: Date())!
        )
        let body: [String: Any] = [
            "cache_key": key,
            "title": title,
            "artist": artist,
            "features": featuresJSON,
            "source": source,
            "expires_at": expiresAt,
            "schema_version": 1
        ]
        await upsert(url: url, body: body, conflictColumn: "cache_key")
    }

    // ──────────────────────────────────────────────
    // MARK: - Similar Tracks Cache
    // ──────────────────────────────────────────────

    func lookupSimilarTracks(title: String, artist: String) async -> [(title: String, artist: String)]? {
        guard cacheEnabled else { return nil }
        let key = cacheKey(title: title, artist: artist)
        guard let url = URL(string: "\(baseURL)/rest/v1/similar_tracks_cache?cache_key=eq.\(key.urlEncoded)&expires_at=gt.\(now())&select=tracks&limit=1") else { return nil }

        guard let data = try? await get(url: url),
              let rows = try? JSONDecoder().decode([[String: TracksValue]].self, from: data),
              let first = rows.first,
              let tracks = first["tracks"]?.value else { return nil }

        simiLog("✅ Supabase similar-tracks cache hit: \"\(title)\"")
        return tracks
    }

    func storeSimilarTracks(title: String, artist: String, tracks: [(title: String, artist: String)]) async {
        guard cacheEnabled else { return }
        guard let url = URL(string: "\(baseURL)/rest/v1/similar_tracks_cache") else { return }
        let key = cacheKey(title: title, artist: artist)
        let trackDicts = tracks.map { ["title": $0.title, "artist": $0.artist] }
        let body: [String: Any] = [
            "cache_key": key,
            "title": title,
            "artist": artist,
            "tracks": trackDicts
        ]
        await upsert(url: url, body: body, conflictColumn: "cache_key")
    }

    // ──────────────────────────────────────────────
    // MARK: - Genre Tag Map
    // ──────────────────────────────────────────────

    /// Fetches energy/valence/danceability for a set of tags from Supabase.
    /// Returns only the tags that exist in the database.
    func lookupTagMap(tags: [String]) async -> [String: TagFeatures] {
        guard cacheEnabled else { return [:] }
        guard !tags.isEmpty else { return [:] }
        // PostgREST in() filter uses bare comma-separated values — no SQL-style quoting.
        // Correct: tag=in.(rock,pop,soul)   Wrong: tag=in.('rock','pop','soul') → returns []
        let tagList = tags.map { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0 }.joined(separator: ",")
        guard let url = URL(string: "\(baseURL)/rest/v1/genre_tag_map?tag=in.(\(tagList))&select=tag,energy,valence,danceability,bpm_estimate") else { return [:] }

        guard let data = try? await get(url: url),
              let rows = try? JSONDecoder().decode([TagMapRow].self, from: data) else { return [:] }

        var result: [String: TagFeatures] = [:]
        for row in rows {
            result[row.tag] = TagFeatures(energy: row.energy, valence: row.valence, danceability: row.danceability, bpmEstimate: row.bpmEstimate)
        }
        return result
    }

    /// Inserts a newly discovered tag into genre_tag_map.
    /// Skips tags that already exist (ON CONFLICT DO NOTHING).
    func storeTagMapping(tag: String, energy: Double, valence: Double, danceability: Double, bpmEstimate: Double = 0) async {
        guard cacheEnabled else { return }
        guard let url = URL(string: "\(baseURL)/rest/v1/genre_tag_map") else { return }
        let body: [String: Any] = [
            "tag": tag,
            "energy": energy,
            "valence": valence,
            "danceability": danceability,
            "bpm_estimate": bpmEstimate,
            "confidence": 0.5,
            "sample_count": 1
        ]
        await insert(url: url, body: body)
    }

    // ──────────────────────────────────────────────
    // MARK: - Vector Catalog
    // ──────────────────────────────────────────────

    /// Builds the normalized 8-dim embedding from an AudioFeatures struct.
    /// Dimension order must match the SQL embedding column in analyzed_songs.
    static func buildEmbedding(from features: AudioFeatures) -> [Double] {
        [
            features.valence,
            features.energy,
            features.danceability,
            features.acousticness,
            Double(features.mode),          // 0.0 = minor, 1.0 = major
            min(features.bpm / 200.0, 1.0), // normalize BPM into 0–1
            features.tonalClarity,
            features.spectralWarmth
        ]
    }

    /// Writes a librosa-analyzed song's embedding into the vector catalog.
    /// Upserts on spotify_id — re-analyzing a song updates its stored vector.
    func storeVector(spotifyID: String, title: String, artist: String, features: AudioFeatures) async {
        guard cacheEnabled else { return }
        guard let url = URL(string: "\(baseURL)/rest/v1/analyzed_songs"),
              let featuresData = try? JSONEncoder().encode(features),
              let featuresJSON = try? JSONSerialization.jsonObject(with: featuresData) else { return }
        let emb = Self.buildEmbedding(from: features)
        let embStr = "[\(emb.map { String(format: "%.6f", $0) }.joined(separator: ","))]"
        let body: [String: Any] = [
            "spotify_id": spotifyID,
            "title":      title,
            "artist":     artist,
            "embedding":  embStr,
            "features":   featuresJSON
        ]
        await upsert(url: url, body: body, conflictColumn: "spotify_id")
    }

    /// Queries the vector catalog for nearest neighbors to the given embedding.
    /// Returns [] until the catalog crosses the cold-start threshold (300 songs) —
    /// the SQL function handles the check server-side so no extra round-trip is needed.
    func fetchSimilarByVector(embedding: [Double]) async -> [(title: String, artist: String)] {
        guard cacheEnabled else { return [] }
        guard let url = URL(string: "\(baseURL)/rest/v1/rpc/find_similar_songs") else { return [] }
        let body: [String: Any] = ["query_embedding": embedding, "limit_count": 20]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let data = await postRPC(url: url, body: bodyData),
              let rows = try? JSONDecoder().decode([VectorCandidateRow].self, from: data) else {
            return []
        }
        if !rows.isEmpty { simiLog("🔷 Vector catalog: \(rows.count) similar songs") }
        return rows.map { (title: $0.title, artist: $0.artist) }
    }

    private func postRPC(url: URL, body: Data) async -> Data? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // ──────────────────────────────────────────────
    // MARK: - HTTP Helpers
    // ──────────────────────────────────────────────

    private func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        let (data, _) = try await session.data(for: request)
        return data
    }

    private func upsert(url: URL, body: [String: Any], conflictColumn: String) async {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "on_conflict", value: conflictColumn)]
        guard let resolvedURL = components?.url,
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: resolvedURL)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        _ = try? await session.data(for: request)
    }

    private func insert(url: URL, body: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=ignore-duplicates", forHTTPHeaderField: "Prefer")
        _ = try? await session.data(for: request)
    }

    private func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

// ──────────────────────────────────────────────
// MARK: - JSON Decodable Wrappers
// These unwrap Supabase's jsonb columns into Swift types.
// ──────────────────────────────────────────────

struct TagFeatures {
    let energy: Double
    let valence: Double
    let danceability: Double
    let bpmEstimate: Double
}

private struct TagMapRow: Codable {
    let tag: String
    let energy: Double
    let valence: Double
    let danceability: Double
    let bpmEstimate: Double
    enum CodingKeys: String, CodingKey {
        case tag, energy, valence, danceability
        case bpmEstimate = "bpm_estimate"
    }
}

// Supabase returns jsonb columns as raw JSON — these decode them into Swift types.

private struct TagsValue: Codable {
    let value: [String]?
    init(from decoder: Decoder) throws {
        value = try? [String](from: decoder)
    }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

private struct FeaturesValue: Codable {
    let value: AudioFeatures?
    init(from decoder: Decoder) throws {
        value = try? AudioFeatures(from: decoder)
    }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

private struct TracksValue: Codable {
    let value: [(title: String, artist: String)]?
    init(from decoder: Decoder) throws {
        struct Track: Codable { let title: String; let artist: String }
        if let tracks = try? [Track](from: decoder) {
            value = tracks.map { (title: $0.title, artist: $0.artist) }
        } else {
            value = nil
        }
    }
    func encode(to encoder: Encoder) throws {}
}

private struct VectorCandidateRow: Codable {
    let spotifyId: String
    let title: String
    let artist: String
    let distance: Double
    enum CodingKeys: String, CodingKey {
        case spotifyId = "spotify_id"
        case title, artist, distance
    }
}

// ──────────────────────────────────────────────
// MARK: - URL Encoding Helper
// ──────────────────────────────────────────────

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
