# Pro Export Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an export button to the results view that lets users export the full match list as a CSV or JSON file via the system share sheet — targeted at music supervisors who need structured data for sync licensing work.

**Architecture:** A pure-Swift `ProExportService` struct handles CSV/JSON generation (no UIKit, no network). `ResultsView` adds a toolbar button, format picker dialog, and share sheet trigger using the `ActivitySheetView` already in the project.

**Tech Stack:** Swift 5.9, SwiftUI, Foundation (JSONEncoder, FileManager). No new dependencies.

## Global Constraints

- No model changes (`Song.swift`, `SimilarSong` unchanged)
- No backend API calls
- Export uses `engine.recommendations` (full list), not `displayedRecommendations` (filtered) — export what was found, not what's currently visible
- CSV format is RFC 4180 compliant (comma-separated, double-quote escaping)
- BPM formatted as integer; valence/energy/danceability/acousticness to 2 decimal places
- Similarity % as integer (0–100, no `%` symbol)
- Export button is only visible when `!engine.isLoading && !engine.recommendations.isEmpty`
- Commits go to the inner git repo at `/Users/skips/Documents/Claude/Projects/Simi App/Simi/`

---

### Task 1: `ProExportService.swift`

**Files:**
- Create: `Simi/Simi/Services/ProExportService.swift`

**Interfaces:**
- Produces:
  ```swift
  struct ProExportService {
      static func csv(seed: Song, results: [SimilarSong]) -> (filename: String, data: Data)
      static func json(seed: Song, results: [SimilarSong]) -> (filename: String, data: Data)
  }
  ```

- [ ] **Step 1: Create `ProExportService.swift`**

  Full file content:

  ```swift
  import Foundation

  struct ProExportService {

      // MARK: - CSV

      static func csv(seed: Song, results: [SimilarSong]) -> (filename: String, data: Data) {
          var lines: [String] = []

          let header = [
              "Title", "Artist", "Genre", "Sub-Genre",
              "Similarity %", "BPM", "Valence", "Energy",
              "Danceability", "Acousticness", "Match Reasons", "Spotify URL",
          ].joined(separator: ",")
          lines.append(header)

          for song in results {
              let af = song.audioFeatures
              let row = [
                  escaped(song.title),
                  escaped(song.artist),
                  escaped(song.genre.main),
                  escaped(song.genre.sub ?? ""),
                  "\(Int((song.similarityScore * 100).rounded()))",
                  af.map { "\(Int($0.bpm.rounded()))" } ?? "",
                  af.map { String(format: "%.2f", $0.valence) }      ?? "",
                  af.map { String(format: "%.2f", $0.energy) }       ?? "",
                  af.map { String(format: "%.2f", $0.danceability) } ?? "",
                  af.map { String(format: "%.2f", $0.acousticness) } ?? "",
                  escaped(song.matchReasons.map { $0.rawValue }.joined(separator: " · ")),
                  escaped(song.spotifyURL),
              ].joined(separator: ",")
              lines.append(row)
          }

          let csvString = lines.joined(separator: "\n")
          let data = Data(csvString.utf8)
          let filename = "simi-export-\(dateStamp()).csv"
          return (filename, data)
      }

      // MARK: - JSON

      static func json(seed: Song, results: [SimilarSong]) -> (filename: String, data: Data) {
          var root: [String: Any] = [:]
          root["seed"] = [
              "title":      seed.title,
              "artist":     seed.artist,
              "spotifyURL": seed.spotifyURL,
          ]
          root["exportedAt"]   = ISO8601DateFormatter().string(from: Date())
          root["resultCount"]  = results.count
          root["results"] = results.map { song -> [String: Any?] in
              let af = song.audioFeatures
              return [
                  "title":             song.title,
                  "artist":            song.artist,
                  "genre":             song.genre.main,
                  "subGenre":          song.genre.sub as Any?,
                  "similarityPercent": Int((song.similarityScore * 100).rounded()),
                  "bpm":               af.map { Int($0.bpm.rounded()) } as Any?,
                  "valence":           af.map { $0.valence }      as Any?,
                  "energy":            af.map { $0.energy }       as Any?,
                  "danceability":      af.map { $0.danceability } as Any?,
                  "acousticness":      af.map { $0.acousticness } as Any?,
                  "matchReasons":      song.matchReasons.map { $0.rawValue },
                  "spotifyURL":        song.spotifyURL,
              ]
          }
          // JSONSerialization handles [String: Any?] without NSNull conversion — use it directly.
          let data = (try? JSONSerialization.data(
              withJSONObject: root.compactMapValues { $0 as Any },
              options: [.prettyPrinted, .sortedKeys]
          )) ?? Data()
          let filename = "simi-export-\(dateStamp()).json"
          return (filename, data)
      }

      // MARK: - Helpers

      private static func escaped(_ value: String) -> String {
          if value.contains(",") || value.contains("\"") || value.contains("\n") {
              return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
          }
          return value
      }

      private static func dateStamp() -> String {
          let f = DateFormatter()
          f.dateFormat = "yyyy-MM-dd"
          return f.string(from: Date())
      }
  }
  ```

  **Note on the JSON implementation:** `[String: Any?]` with optional values requires care. The approach above passes `af.map { ... } as Any?` so nil optionals become JSON `null`. The `root.compactMapValues { $0 as Any }` at the top level only works on the top-level dict (seed, exportedAt, etc.) where no nulls are desired. The per-result dict uses `JSONSerialization` directly which handles NSNull. **Actually — JSONSerialization does NOT accept `Any?`; it requires `Any` (i.e., NSNull for nulls).** Rewrite the json() method to use JSONSerialization with explicit NSNull:

  ```swift
  static func json(seed: Song, results: [SimilarSong]) -> (filename: String, data: Data) {
      let seedDict: [String: Any] = [
          "title":      seed.title,
          "artist":     seed.artist,
          "spotifyURL": seed.spotifyURL,
      ]

      let resultDicts: [[String: Any]] = results.map { song in
          let af = song.audioFeatures
          var d: [String: Any] = [
              "title":             song.title,
              "artist":            song.artist,
              "genre":             song.genre.main,
              "subGenre":          song.genre.sub ?? NSNull(),
              "similarityPercent": Int((song.similarityScore * 100).rounded()),
              "matchReasons":      song.matchReasons.map { $0.rawValue },
              "spotifyURL":        song.spotifyURL,
          ]
          if let af {
              d["bpm"]          = Int(af.bpm.rounded())
              d["valence"]      = af.valence
              d["energy"]       = af.energy
              d["danceability"] = af.danceability
              d["acousticness"] = af.acousticness
          } else {
              d["bpm"]          = NSNull()
              d["valence"]      = NSNull()
              d["energy"]       = NSNull()
              d["danceability"] = NSNull()
              d["acousticness"] = NSNull()
          }
          return d
      }

      let root: [String: Any] = [
          "seed":        seedDict,
          "exportedAt":  ISO8601DateFormatter().string(from: Date()),
          "resultCount": results.count,
          "results":     resultDicts,
      ]
      let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
      let filename = "simi-export-\(dateStamp()).json"
      return (filename, data)
  }
  ```

  Use this second version. The first description was a design note explaining WHY, the second is the correct implementation. Write only the final correct version in the actual file.

- [ ] **Step 2: Build to verify no compile errors**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && \
  xcodebuild -project Simi.xcodeproj -scheme Simi \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    build 2>&1 | grep -E "error:|warning: 'ProExportService'|BUILD (SUCCEEDED|FAILED)"
  ```
  Expected: `BUILD SUCCEEDED` — no errors. Warnings about unused variables are acceptable if any.

- [ ] **Step 3: Verify CSV escaping logic by inspection**

  Read the `escaped()` function. Confirm:
  - A value with a comma → wrapped in double-quotes: `"hello, world"` → `"hello, world"` in CSV ✅
  - A value with a double-quote → quote escaped: `say "hi"` → `"say ""hi"""` ✅
  - A plain value → returned unchanged: `hello` → `hello` ✅

- [ ] **Step 4: Commit**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && \
  git add Simi/Services/ProExportService.swift && \
  git commit -m "feat: add ProExportService with CSV and JSON export"
  ```

---

### Task 2: Wire export button into `ResultsView.swift`

**Files:**
- Modify: `Simi/Simi/Views/ResultsView.swift`

**Interfaces:**
- Consumes from Task 1: `ProExportService.csv(seed:results:)` and `ProExportService.json(seed:results:)`
- Consumes from existing project: `ActivitySheetView(items:)` (already in `ShareCardView.swift`)
- Consumes from existing project: `engine.sourceSong: Song?`, `engine.recommendations: [SimilarSong]`, `engine.isLoading: Bool`

- [ ] **Step 1: Read `ResultsView.swift` to find the toolbar section**

  Find the `.toolbar` block (around line 215). The trailing toolbar item currently shows the count label (`"N found"` or `"Finding…"`).

- [ ] **Step 2: Add three `@State` vars to `ResultsView`**

  After the existing `@State private var showShareSheet = false` (or the last existing `@State` var), add:

  ```swift
  @State private var showExportPicker = false
  @State private var exportShareItems: [Any] = []
  @State private var showExportSheet   = false
  ```

- [ ] **Step 3: Add the `ExportFormat` enum and `triggerExport()` method**

  Add inside `ResultsView` (not inside any View body — just as a regular method):

  ```swift
  private enum ExportFormat { case csv, json }

  private func triggerExport(format: ExportFormat) {
      guard let seed = engine.sourceSong else { return }
      let (filename, data): (String, Data)
      switch format {
      case .csv:  (filename, data) = ProExportService.csv(seed: seed, results: engine.recommendations)
      case .json: (filename, data) = ProExportService.json(seed: seed, results: engine.recommendations)
      }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
      try? data.write(to: url)
      exportShareItems = [url]
      showExportSheet = true
  }
  ```

- [ ] **Step 4: Add the export toolbar item**

  In the `.toolbar` block, add a new `ToolbarItem(placement: .navigationBarTrailing)` **before** the existing count-label item. Add it immediately after the opening `ToolbarItem(placement: .navigationBarLeading)` block:

  ```swift
  ToolbarItem(placement: .navigationBarTrailing) {
      if !engine.isLoading && !engine.recommendations.isEmpty {
          Button {
              showExportPicker = true
          } label: {
              Image(systemName: "tablecells")
                  .font(.system(size: 16, weight: .medium))
                  .foregroundColor(.simiAccent)
                  .frame(minWidth: 44, minHeight: 44)
                  .contentShape(Rectangle())
          }
          .accessibilityLabel("Export results")
          .accessibilityHint("Export the match list as CSV or JSON")
          .confirmationDialog("Export results", isPresented: $showExportPicker, titleVisibility: .visible) {
              Button("Export as CSV") { triggerExport(format: .csv) }
              Button("Export as JSON") { triggerExport(format: .json) }
              Button("Cancel", role: .cancel) { }
          }
          .sheet(isPresented: $showExportSheet) {
              ActivitySheetView(items: exportShareItems)
                  .presentationDetents([.medium, .large])
          }
      }
  }
  ```

- [ ] **Step 5: Build to verify**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && \
  xcodebuild -project Simi.xcodeproj -scheme Simi \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
  ```
  Expected: `BUILD SUCCEEDED` — no errors.

- [ ] **Step 6: Self-review checklist**

  Before committing, verify by reading the diff:
  - [ ] Export button is inside an `if !engine.isLoading && !engine.recommendations.isEmpty` guard — button absent during loading
  - [ ] `triggerExport()` uses `engine.recommendations` (not `displayedRecommendations`) — full list exported
  - [ ] `ActivitySheetView` is called with `[url]` (a file URL), not with a string — enables save/AirDrop
  - [ ] `try? data.write(to: url)` — fire and forget write to temp dir is correct (OS cleans up)
  - [ ] `.confirmationDialog` is attached to the button (not to the toolbar item) — correct placement
  - [ ] `.sheet(isPresented: $showExportSheet)` is also attached to the button — matches SwiftUI sheet attachment pattern

- [ ] **Step 7: Commit**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && \
  git add Simi/Views/ResultsView.swift && \
  git commit -m "feat: wire ProExportService into ResultsView with CSV/JSON export button"
  ```
