# Design Spec: Match Explanation Card
**Date:** 2026-06-17  
**Priority:** P0 (Blue Ocean Memo — Task 1)  
**Gap addressed:** Gap 5 — Opaque recommendations  
**Effort:** Low (scores already computed)

---

## Problem

Simi's core differentiator is emotional imprint matching — we know *why* two songs match. That reasoning is invisible to the user. The current expanded card shows raw numbers (BPM, Energy%, Mood%) which feel technical, not transparent. Spotify has the same problem by design; we can own explainability as a feature.

---

## Goal

When a user taps a song card to expand it, show a human-readable breakdown of *why* that song was recommended — emotional language, not percentages. Make the invisible visible.

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Placement | Replace the `AudioFeaturesGrid` number grid | Cleaner, more opinionated — emotional language only |
| Style | Row-by-row breakdown with label + descriptor | Scannable, transparent, matches memo spec |
| Missing data | Hide the row entirely | What's shown is always trustworthy — no fake insight |
| Fallback | Show `AudioFeaturesGrid` when `matchExplanation == nil` | Safe during loading phase, zero regression risk |

---

## Architecture

### New file
- `Simi/Views/MatchExplanationView.swift` — purely presentational, receives `MatchExplanation` and renders rows

### Modified files
- `Simi/Models/Song.swift` — add `MatchExplanation` struct + `matchExplanation: MatchExplanation?` to `SimilarSong`
- `Simi/Services/RecommendationEngine.swift` — add `buildMatchExplanation(source:target:sourceGenres:targetGenre:)` helper; call it in `enrichWithABFeatures` Stage 1 (tag estimates) and Stage 2 (librosa overlay)
- `Simi/Views/SongCard.swift` — swap `AudioFeaturesGrid` for `MatchExplanationView` in expanded section, with `AudioFeaturesGrid` as nil-guard fallback

### What does NOT change
- `computeSimilarity` return type stays `(Double, [MatchReason])` — no call-site changes
- `SimilarSong.matchReasons` stays as-is — explanation is additive
- Supabase schema — `MatchExplanation` is derived at display time, never persisted

---

## Data Model

```swift
// Song.swift

struct MatchExplanationRow {
    let label: String       // e.g. "Emotional weight"
    let descriptor: String  // e.g. "Same melancholic weight"
}

struct MatchExplanation {
    let rows: [MatchExplanationRow]  // only rows with reliable data; min 0, max 5
    let genreBridgeLabel: String?    // e.g. "Jazz → Hip-Hop", nil if same genre family
}

// Added to SimilarSong:
var matchExplanation: MatchExplanation? = nil
```

`MatchExplanation` is computed from already-cached audio features. No new API calls, no schema changes.

---

## Descriptor Logic

`buildMatchExplanation(source: AudioFeatures, target: AudioFeatures, sourceGenres: [Genre], targetGenre: Genre) -> MatchExplanation`

Called in `enrichWithABFeatures` after features are set on each recommendation — Stage 1 (tag estimates) and Stage 2 (librosa). At that point both source features (`lastSourceFeatures`) and target features (`recommendations[i].audioFeatures`) are in scope, as are `lastGenres` and `recommendations[i].genre`.

### Row 1 — Emotional weight (always available)
**Condition:** `abs(srcValence - tgtValence) < 0.20`  
**Descriptor** based on `(srcValence + tgtValence) / 2`:

| Avg valence | Descriptor |
|-------------|------------|
| < 0.35 | "Same melancholic weight" |
| 0.35–0.50 | "Same bittersweet edge" |
| 0.50–0.65 | "Same balanced mood" |
| > 0.65 | "Same bright energy" |

Uses `valenceEssentia ?? valence` (prefers DEAM-regressed value), consistent with `computeSimilarity`.

### Row 2 — Intensity (always available)
**Condition:** `abs(source.energy - target.energy) < 0.20`  
**Descriptor** based on `(source.energy + target.energy) / 2`:

| Avg energy | Descriptor |
|------------|------------|
| < 0.35 | "Equally restrained" |
| 0.35–0.55 | "Equally measured" |
| 0.55–0.75 | "Equally driven" |
| > 0.75 | "Equally intense" |

### Row 3 — Key (only when both songs have measured key)
**Field note:** `AudioFeatures` has two distinct flags — `isEstimated: Bool` (whole feature set came from tag estimation) and `isKeyEstimated: Bool` (key/mode is a C-Major placeholder, not a real measurement). Row 3 uses `isKeyEstimated`, which is correct — a tag-estimated song can still have a real key if GetSongBPM or Spotify provided it.

**Condition:** `!source.isKeyEstimated && !target.isKeyEstimated && source.mode == target.mode`  
**Descriptor:** `"Both minor key"` or `"Both major key"`  
Different modes → row hidden.

### Row 4 — Groove feel (librosa only)
**Field:** `AudioFeatures.grooveRatio: Double?` — `onset_std / onset_mean`, syncopation proxy. Range ~0–2 (funky ~0.8–1.8, smooth ~0.3–0.7). Populated by Railway librosa backend only; nil for tag-estimated songs. Confirmed present at `Song.swift:68`.

**Condition:** `source.grooveRatio != nil && target.grooveRatio != nil && delta < 0.35`  
**Descriptor** based on `(srcGroove + tgtGroove) / 2`:

| Avg groove ratio | Descriptor |
|-----------------|------------|
| < 0.5 | "Smooth and flowing" |
| 0.5–0.9 | "Equally measured pulse" |
| > 0.9 | "Equally syncopated" |

### Row 5 — Sonic texture (librosa only)
**Condition:** Both songs have `spectralWarmth` from librosa (`!isEstimated`) and `delta < 0.20`  
**Descriptor** based on `(srcWarmth + tgtWarmth) / 2`:

| Avg spectralWarmth | Descriptor |
|--------------------|------------|
| < 0.35 | "Both bright and airy" |
| 0.35–0.65 | "Similar tonal warmth" |
| > 0.65 | "Both warm and full" |

### Genre bridge (not a scored row)
**Function:** `detectGenreFamily(_ genres: [Genre]) -> GenreFamily` — private method on `RecommendationEngine`, confirmed at `RecommendationEngine.swift:1414`. Returns a `GenreFamily` enum (`.hiphop`, `.rnb`, `.rock`, `.metal`, `.blues`, `.jazz`, `.classical`, `.electronic`, `.folk`, `.pop`, `.unknown`). Since `buildMatchExplanation` will also be a method on `RecommendationEngine`, it can call `detectGenreFamily` directly — no visibility issue.

Compares `detectGenreFamily(sourceGenres)` vs `detectGenreFamily([targetGenre])`.  
If genre families differ → `genreBridgeLabel = "\(sourceGenre.main) → \(targetGenre.main)"`  
If same family → `genreBridgeLabel = nil`, row hidden.  
If either genre family resolves to `.unknown` → `genreBridgeLabel = nil`. A bridge label like "Unknown → Jazz" carries no useful signal.

---

## View Design

`MatchExplanationView` — replaces `AudioFeaturesGrid` in `SongCard`'s expanded section.

```
WHY THIS MATCHES
────────────────────────────────────────
Emotional weight    Same melancholic weight
Intensity           Equally restrained
Key                 Both minor key
Genre bridge 🌉     Jazz → Hip-Hop
```

- **Header:** `"WHY THIS MATCHES"` — `.simiMicro.weight(.semibold)`, uppercase, tracked, `.simiSubtext` color. Matches existing label style used throughout the app.
- **Rows:** Two-column `HStack` — label in `.simiMicro` / `.simiSubtext`, descriptor in `.simiCaption.weight(.semibold)` / `.simiText`
- **Genre bridge row:** label and descriptor both in `.simiAccent` to visually distinguish the cross-genre signal
- **Minimum card:** 0 rows shown (explanation still renders, just shows header — edge case for songs with no close-matching dimensions)
- **Maximum card:** 5 rows + genre bridge

### Timing
`matchExplanation` is nil until `enrichWithABFeatures` runs (Stage 1, ~5s after display). Since `isExpanded` defaults to false, users never see a blank explanation panel — they can only expand after enrichment has populated `audioFeatures`, which is the same gate that triggers the explanation computation.

### Fallback behavior in `SongCard`
```swift
if let explanation = song.matchExplanation,
   !explanation.rows.isEmpty || explanation.genreBridgeLabel != nil {
    MatchExplanationView(explanation: explanation)
} else if let features = song.audioFeatures {
    AudioFeaturesGrid(features: features)  // existing behavior preserved
}
```

Zero-row explanation (no dimensions matched closely enough) falls through to `AudioFeaturesGrid` — avoids a header-with-nothing-under-it broken state.

---

## Execution scope

This is a pure SwiftUI + model-layer task. No backend changes, no new API calls, no Supabase schema changes. The Railway backend and audio analysis pipeline are untouched.

**Files to create:** 1 (`MatchExplanationView.swift`)  
**Files to modify:** 3 (`Song.swift`, `RecommendationEngine.swift`, `SongCard.swift`)
