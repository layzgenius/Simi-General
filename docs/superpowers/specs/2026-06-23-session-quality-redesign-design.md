# Session Quality Redesign
**Date:** 2026-06-23
**Scope:** Three interlocking improvements that take Simi from good to excellent.

---

## Overview

Three features designed together because they share a foundation: enrichment must run before first render for all three to work correctly.

1. **Loading & Enrichment Redesign** — skeleton-first reveal, enrich before showing, no re-sort ever
2. **Emotional Language for Estimated Songs** — every card shows emotional descriptors, not raw numbers
3. **3-State Feedback Loop** — users signal "Fits / Close / Miss" per recommendation

---

## Section 1: Loading & Enrichment Redesign

### Problem
Current flow shows results at ~3–5s but re-sorts them 15–40s later as enrichment completes. The re-sort is jarring and breaks trust in the ordering. Users also lose patience during the initial spinner.

### New Flow

```
0s   → Source song card appears (resolved from URL)
0s   → 4 animated skeleton cards appear below it
1–3s → Candidates fetched (Last.fm, ListenBrainz, Spotify recs, vector search)
3–6s → prefetchCandidateFeatures() runs:
         - Supabase lookup via withTaskGroup (all candidates in parallel)
         - Last.fm tag estimation for cache misses (staggered, see below)
         - buildMatchExplanation() runs per candidate (explanations pre-baked)
6–8s → mergeAndScore() with enriched features → correct initial order
       Results reveal with stagger animation (~80ms between cards)
8s+  → Railway enrichment runs in background for top 5:
         - Updates audioFeatures + matchExplanation only
         - NO re-sort — positions frozen after first render
```

### Architectural Changes

**`RecommendationEngine.swift`**

- New `prefetchCandidateFeatures(candidates: [SimilarSong], sourceFeatures: AudioFeatures, genres: [Genre]) async -> [SimilarSong]`
  - Supabase lookup via `withTaskGroup` — all candidates in parallel, each a single indexed read. No new batch API needed; `lookupFeatures(title:artist:)` is already per-song.
  - Last.fm tag estimation for cache misses: stagger 20ms per song for indices 0–15 (max 300ms delay). Songs at index > 15 fire simultaneously after the 300ms cap — they don't wait longer, but do not get additional delay. This matches the existing enrichment cap logic and avoids burst-firing all tail songs at once while keeping total wait bounded.
  - If `prefetchCandidateFeatures()` has not completed within **10 seconds**, reveal results with whatever features are available. This is the max-wait fallback: skeletons never persist past 10s regardless of upstream slowness. Any remaining enrichment continues in the same background path as before.
  - Calls `buildMatchExplanation()` per candidate once features are known
  - Returns candidates with `audioFeatures` and `matchExplanation` populated
- `mergeAndScore()` receives pre-enriched candidates → scores are good on first pass
- `enrichWithABFeatures()` keeps its Railway stage but removes `recommendations.sort` — only mutates `audioFeatures` and `matchExplanation` on each song
- The `lastSourceFeatures` / `lastSeedFeatures` pattern stays unchanged

**`ResultsView.swift`**

- New `SkeletonCard` view: pulsing placeholder matching SongCard height/layout **including FeedbackRow height** — skeleton must be the same height as a fully-rendered card to avoid height jumps when results replace skeletons during the reveal animation
- While `engine.isLoading && engine.recommendations.isEmpty`: show source song card (if resolved) + 4 skeleton cards
- When `engine.recommendations` becomes non-empty: animate cards in with stagger
  - Each card: `.opacity(0) → 1` + `.offset(y: 12) → 0` with 80ms delay per rank

**`HomeView.swift`**

- Source song card appears as soon as `engine.sourceSong` is non-nil (before full results)
- No change to input/search UI

### What Stays the Same
- All existing service calls and their ordering
- Supabase cache, Railway keep-alive, DCLAP embedding pipeline
- Quality filter (0.62 threshold) still applies after enrichment

### Railway Background Enrichment — Silent Updates
Railway enrichment runs after first render and can update `audioFeatures` and `matchExplanation` on top-5 songs. This means a user who expands a card at 7s, closes it, and re-expands at 15s may see improved emotional language the second time. This is correct and expected behavior — silent improvement, not a jarring change.

---

## Section 2: Emotional Language for Estimated Songs

### Problem
`buildMatchExplanation()` gates every row on `!source.isEstimated && !target.isEstimated`. Most songs are tag-estimated, so most expanded cards show `AudioFeaturesGrid` (raw percentages) instead of emotional language. This contradicts Simi's core thesis.

### Solution: Two-Tier Descriptors

Loosen gates for valence and energy rows. Keep strict gates for rows that are genuinely unreliable when estimated.

**Valence row (Emotional weight)**
- Gate: `abs(srcValence - tgtValence) < 0.20` (threshold unchanged, `isEstimated` check removed)
- Measured: existing precise descriptors — "Same melancholic weight", "Same bittersweet edge", "Same balanced mood", "Same bright energy"
- Estimated (either song has `isEstimated = true`): softer descriptors — "Similar emotional feel", "Similar bittersweet range", "Similar balanced mood", "Similar warmth"

**Energy row (Intensity)**
- Gate: `abs(source.energy - target.energy) < 0.20` (threshold unchanged, `isEstimated` check removed)
- Measured: existing — "Equally restrained", "Equally measured", "Equally driven", "Equally intense"
- Estimated: softer — "Roughly as restrained", "Roughly as measured", "Roughly as driven", "Roughly as intense"

**Key row** — unchanged, stays gated on `!source.isKeyEstimated && !target.isKeyEstimated`. Key is a C-Major placeholder when estimated; showing it would be misleading.

**Groove feel row** — unchanged, stays gated on non-nil `grooveRatio`. Nil for all estimated songs.

**Sonic texture row** — unchanged, stays gated on `!source.isEstimated && !target.isEstimated`. `spectralWarmth` defaults to 0.5 for estimated songs; the delta check would always pass falsely.

**Genre bridge** — already shows for all songs, no change.

### `AudioFeaturesGrid` Fallback
Still shown when `matchExplanation` has zero rows AND no genre bridge. After this change this is rare — only songs where tag estimation failed entirely (no Last.fm tags found and no Supabase cache entry).

### Implementation
Single function `buildMatchExplanation()` in `RecommendationEngine.swift`:
- Add `isEitherEstimated: Bool` local var — `true` when either source or target has `isEstimated = true`
- Remove `isEstimated` guards from valence and energy rows
- Switch descriptor string based on `isEitherEstimated`
- No new files, no model changes

---

## Section 3: 3-State Feedback Loop

### Purpose
Give users emotional vocabulary to interact with Simi. The act of marking a song creates a sense of dialogue — users feel heard even before the algo learns anything. Session-only MVP; persistence and algo adjustment are a future phase.

### Data Model

Add to `SimilarSong` in `Song.swift`:

```swift
enum FeedbackState: String, Codable {
    case fits, close, miss
}

// In SimilarSong:
var feedbackState: FeedbackState? = nil
```

Not persisted to Supabase. Lives in memory for the session only.

### Struct Mutation — Important Implementation Note

`SimilarSong` is a struct. Direct property mutation on a value inside a `@Published` array does not trigger SwiftUI re-render. The feedback action in `RecommendationEngine` must use index-based reassignment:

```swift
func setFeedback(songID: String, state: FeedbackState?) {
    guard let idx = recommendations.firstIndex(where: { $0.id == songID }) else { return }
    recommendations[idx].feedbackState = state
}
```

`SongCard` calls `engine.setFeedback(songID:state:)` — it never mutates the song directly.

### UI

**Placement:** A `FeedbackRow` below the platform links row on every `SongCard`. Always visible — not behind the expand tap.

**Appearance (neutral / no feedback):**
Three small pill buttons in a row, left-aligned:
- "Fits" — teal text, transparent background, 1px teal border
- "Close" — amber text, transparent background, 1px amber border
- "Miss" — muted text, transparent background, 1px muted border

Compact: font `.simiMicro`, padding 6×12, gap 8pt between pills.

**Appearance (feedback given):**
- `fits`: "Fits ✓" pill fills teal, card gets a 2px left-border accent in teal
- `close`: "Close ~" pill fills amber, card unchanged otherwise
- `miss`: "Miss ✗" pill fills rose, card body drops to 50% opacity
- Tapping active state calls `setFeedback(songID:state: nil)` to return to neutral

**Behavior:**
- Tapping a pill calls `engine.setFeedback(songID: song.id, state: newState)`
- `recommendations[idx]` is reassigned → `@Published` fires → SwiftUI re-renders
- No re-sort under any condition
- `miss` songs dim in place; they don't move

**Accessibility:**
- Each pill: `accessibilityLabel("Mark as fits")` / `"Mark as close"` / `"Mark as miss"`
- When active: `accessibilityValue("selected")`

### What Feedback Does NOT Do (v1)
- No re-scoring or weight adjustment
- No Supabase writes
- No cross-session learning
- No re-sort of any kind

These are explicitly deferred to a future phase, after validating that users actually engage with the feedback UI.

---

## Files Changed

| File | Change |
|------|--------|
| `Simi/Services/RecommendationEngine.swift` | Add `prefetchCandidateFeatures()`, `setFeedback()`, loosen `buildMatchExplanation()` gates, remove sort from enrichment stage |
| `Simi/Models/Song.swift` | Add `FeedbackState` enum + `feedbackState` property to `SimilarSong` |
| `Simi/Views/SongCard.swift` | Add `FeedbackRow` subview, teal left-border accent, miss opacity |
| `Simi/Views/ResultsView.swift` | Add `SkeletonCard` view (FeedbackRow-height-aware), stagger animation on reveal |
| `Simi/Views/HomeView.swift` | Show source song card as soon as resolved |
| `Simi/Views/MatchExplanationView.swift` | No changes needed — already handles any `MatchExplanation` |

---

## Success Criteria

1. No visible re-sort after first render under any condition
2. Something appears on screen within 1s of starting a search (source card or skeletons)
3. Results reveal fully-scored at ~6–8s; skeletons never persist past 10s (fallback reveals best-effort results)
4. Most expanded cards show emotional language rows rather than raw percentages — `AudioFeaturesGrid` only appears when tag estimation failed entirely and no genre bridge exists
5. Feedback pills are tappable and visually respond; miss songs dim in place; no re-sort occurs under any feedback state
