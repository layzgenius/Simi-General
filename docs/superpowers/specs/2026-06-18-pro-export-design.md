# Design Spec: Pro Export Mode
**Date:** 2026-06-18
**Priority:** P2 (Blue Ocean Memo — Task 7)
**Gaps addressed:** Gap 7 — professional/sync gap
**Effort:** Medium (scoped to export only; batch discovery is out of scope for this task)

---

## Problem

Music supervisors and sync licensing professionals who find results in Simi have no way to extract those results into a working document. They can screenshot, manually copy URLs, or share individual song cards — but there is no structured export that lets them drop results into a spreadsheet, share a data file with a client, or pipe results into a sync licensing dashboard.

---

## Goal

Add an export button to the results view that exports the current result list as a CSV or JSON file, opened via the system share sheet so the user can save it to Files, AirDrop it, or email it.

**In scope:**
- CSV export (primary — spreadsheet-ready)
- JSON export (secondary — pipeline-ready)
- Export button in the results toolbar
- Format picker dialog before export
- System share sheet with the generated file

**Out of scope (future task):**
- Batch discovery (multiple seed songs in one session)
- A separate "Pro Mode" tab or subscription gate
- Apple Music URLs (not in the data model)
- Release year (not in the data model)

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Entry point | Second trailing toolbar item in ResultsView | No new tab needed; consistent with existing share patterns in app |
| SF symbol | `tablecells` | Clearly "spreadsheet/data" — distinct from the `square.and.arrow.up` share icon |
| Button visibility | Only when `!engine.isLoading && !engine.recommendations.isEmpty` | No point exporting an empty or in-progress list |
| Format picker | `.confirmationDialog` with "Export as CSV" / "Export as JSON" | Lightweight, system-native, no new view |
| Share mechanism | `ActivitySheetView` (already exists from Task 3) with a temp file URL | File URL enables Save to Files, AirDrop, email attachment — more useful than raw string |
| Temp file location | `FileManager.default.temporaryDirectory` | Standard pattern; OS cleans up automatically |
| Seed row | JSON only — a `"seed"` object at the top level | CSV with a header comment is non-standard; JSON can cleanly separate seed from results |
| Audio feature formatting | 2 decimal places for 0–1 values; BPM as integer | Readable in a spreadsheet without scientific notation |
| Nil audio features | Empty string in CSV columns; `null` in JSON | Graceful fallback when Stage 1 enrichment hasn't completed |
| Match reasons | Joined with ` · ` in CSV; array in JSON | CSV needs a single column; JSON can be structured |

---

## Architecture

### New files
- Create: `Simi/Simi/Services/ProExportService.swift` — CSV and JSON generation only, no UIKit

### Modified files
- Modify: `Simi/Simi/Views/ResultsView.swift` — toolbar button, format picker state, share sheet trigger

### What does NOT change
- `Song.swift` — no model changes
- `RecommendationEngine.swift` — no engine changes
- Backend — no API calls needed
- Any other file

---

## CSV Format

**Filename:** `simi-export-YYYY-MM-DD.csv`

**Columns (header row + one row per result):**
```
Title,Artist,Genre,Sub-Genre,Similarity %,BPM,Valence,Energy,Danceability,Acousticness,Match Reasons,Spotify URL
```

**Example:**
```
Title,Artist,Genre,Sub-Genre,Similarity %,BPM,Valence,Energy,Danceability,Acousticness,Match Reasons,Spotify URL
"Lua","Bright Eyes","Folk","Indie Folk",91,96,0.13,0.21,0.44,0.84,"Dark Mood · Acoustic Match",https://open.spotify.com/track/abc123
"Casimir Pulaski Day","Sufjan Stevens","Folk","Chamber Folk",88,88,0.16,0.18,0.34,0.92,"Dark Mood · Mellow Match",https://open.spotify.com/track/def456
```

**Rules:**
- Fields that contain commas or quotes are wrapped in double-quotes per RFC 4180
- Quotes inside field values are escaped as `""`
- BPM as integer (no decimal)
- Valence, Energy, Danceability, Acousticness formatted to 2 decimal places
- Similarity % as integer (0–100, no `%` symbol in the value)
- Empty string for any nil audio feature field

---

## JSON Format

**Filename:** `simi-export-YYYY-MM-DD.json`

```json
{
  "seed": {
    "title": "Lua",
    "artist": "Bright Eyes",
    "spotifyURL": "https://open.spotify.com/track/seedid"
  },
  "exportedAt": "2026-06-18T14:32:00Z",
  "resultCount": 15,
  "results": [
    {
      "title": "Casimir Pulaski Day",
      "artist": "Sufjan Stevens",
      "genre": "Folk",
      "subGenre": "Chamber Folk",
      "similarityPercent": 88,
      "bpm": 88,
      "valence": 0.16,
      "energy": 0.18,
      "danceability": 0.34,
      "acousticness": 0.92,
      "matchReasons": ["Dark Mood", "Acoustic Match"],
      "spotifyURL": "https://open.spotify.com/track/def456"
    }
  ]
}
```

**Rules:**
- `bpm`, `valence`, `energy`, `danceability`, `acousticness` are `null` when audio features unavailable
- `similarityPercent` is always present (Int, 0–100)
- `matchReasons` is an array of strings (raw values from `MatchReason.rawValue`)
- `exportedAt` is ISO 8601 UTC

---

## ProExportService

```swift
import Foundation

struct ProExportService {
    static func csv(seed: Song, results: [SimilarSong]) -> (filename: String, data: Data)
    static func json(seed: Song, results: [SimilarSong]) -> (filename: String, data: Data)
}
```

Both methods are synchronous and pure (no side effects, no network calls, no file I/O). The caller writes the temp file and handles the share sheet.

---

## ResultsView changes

### State additions
```swift
@State private var showExportPicker = false
@State private var exportShareItems: [Any] = []
@State private var showExportSheet   = false
```

### Export toolbar button
Added as a second `ToolbarItem(placement: .navigationBarTrailing)` before the existing count label:

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

### Export helper
```swift
private enum ExportFormat { case csv, json }

private func triggerExport(format: ExportFormat) {
    guard let seed = engine.sourceSong else { return }
    let results = engine.recommendations  // full list, not filtered
    
    let (filename, data): (String, Data)
    switch format {
    case .csv:  (filename, data) = ProExportService.csv(seed: seed, results: results)
    case .json: (filename, data) = ProExportService.json(seed: seed, results: results)
    }
    
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    try? data.write(to: url)
    exportShareItems = [url]
    showExportSheet = true
}
```

---

## Execution scope

Two files only:
1. `Simi/Simi/Services/ProExportService.swift` — new file, pure Swift
2. `Simi/Simi/Views/ResultsView.swift` — state vars, toolbar button, `triggerExport`

**Changes summary:**
1. `ProExportService.swift` with `csv()` and `json()` methods
2. Three `@State` vars in ResultsView
3. New `ToolbarItem` in the toolbar
4. `triggerExport(format:)` helper
5. `ExportFormat` enum (private to ResultsView)
