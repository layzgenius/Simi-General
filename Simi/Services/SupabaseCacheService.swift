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

    // In debug builds the cache is bypassed so Xcode test runs always hit live APIs
    // and never lock in stale values. Remove this flag or flip it to true to test
    // cache behaviour locally.
    #if DEBUG
    private let cacheEnabled = false
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

        print("✅ Supabase tag cache hit: \"\(title)\"")
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

        print("✅ Supabase feature cache hit: \"\(title)\"")
        return features
    }

    func storeFeatures(title: String, artist: String, features: AudioFeatures, source: String = "tag_estimated") async {
        guard cacheEnabled else { return }
        guard let url = URL(string: "\(baseURL)/rest/v1/audio_features_cache"),
              let featuresData = try? JSONEncoder().encode(features),
              let featuresJSON = try? JSONSerialization.jsonObject(with: featuresData) else { return }
        let key = cacheKey(title: title, artist: artist)
        // Shorter TTL for estimated data so bad values self-correct sooner.
        // Spotify features are ground truth; tag/BPM estimates are rougher.
        let ttlDays: Int
        switch source {
        case "spotify":       ttlDays = 30
        case "tag_estimated": ttlDays = 7
        case "preview_audio": ttlDays = 14
        default:              ttlDays = 3   // bpm_only or unknown
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
            "expires_at": expiresAt
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

        print("✅ Supabase similar-tracks cache hit: \"\(title)\"")
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
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both directives must be in ONE Prefer header — setValue overwrites, not appends.
        request.setValue("resolution=merge-duplicates,on_conflict=\(conflictColumn)", forHTTPHeaderField: "Prefer")
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

// ──────────────────────────────────────────────
// MARK: - URL Encoding Helper
// ──────────────────────────────────────────────

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
