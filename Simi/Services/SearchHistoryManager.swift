// SearchHistoryManager.swift
// Simi — Music Discovery App
//
// Saves and loads the user's past searches using UserDefaults.
// Each entry records the source song + when it was searched.
// Max 50 entries — oldest are trimmed automatically.

import Foundation
import Combine

// ──────────────────────────────────────────────
// MARK: - HistoryEntry
// One saved search: the song that was looked up + when
// ──────────────────────────────────────────────

struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    let song: Song
    let searchedAt: Date
    let queryString: String  // The URL or text the user typed — for re-running the search

    init(song: Song, searchedAt: Date, queryString: String) {
        self.id = UUID()
        self.song = song
        self.searchedAt = searchedAt
        self.queryString = queryString
    }

    // Backward-compatible decode: old entries stored without an id field get a fresh UUID.
    enum CodingKeys: String, CodingKey { case id, song, searchedAt, queryString }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        song        = try c.decode(Song.self, forKey: .song)
        searchedAt  = try c.decode(Date.self, forKey: .searchedAt)
        queryString = try c.decode(String.self, forKey: .queryString)
    }
}

// ──────────────────────────────────────────────
// MARK: - SearchHistoryManager
// ──────────────────────────────────────────────

@MainActor
class SearchHistoryManager: ObservableObject {

    @Published var entries: [HistoryEntry] = []

    private let storageKey = "simi_search_history"
    private let maxEntries = 50

    init() {
        load()
    }

    // ──────────────────────────────────────────────
    // MARK: - Public API
    // ──────────────────────────────────────────────

    /// Call this after a successful search to save it to history
    func record(song: Song, query: String) {
        // Don't duplicate: remove any existing entry for the same song
        entries.removeAll { $0.song.id == song.id }

        let entry = HistoryEntry(song: song, searchedAt: Date(), queryString: query)
        entries.insert(entry, at: 0) // Most recent first

        // Trim to max
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }

        save()
    }

    /// Remove a single entry
    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.song.id == entry.song.id }
        save()
    }

    /// Wipe all history
    func clearAll() {
        entries = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // ──────────────────────────────────────────────
    // MARK: - Persistence
    // ──────────────────────────────────────────────

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    /// Human-readable timestamp: "Today", "Yesterday", "3 days ago", etc.
    func relativeDate(for entry: HistoryEntry) -> String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(entry.searchedAt) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: entry.searchedAt)
        } else if calendar.isDateInYesterday(entry.searchedAt) {
            return "Yesterday"
        } else {
            let days = calendar.dateComponents([.day], from: entry.searchedAt, to: now).day ?? 0
            return "\(days) days ago"
        }
    }
}
