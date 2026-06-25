# Feature Quality Improvements — Design Spec

**Goal:** Maximize real measured audio features for niche candidates — both pre-2022 catalog and modern releases — by adding three independent, compounding changes to `enrichWithABFeatures` and `fillMissingPreviewURLs`.

**Problem:** Spec A (candidate pool expansion) increased the number of niche candidates entering the scoring pool. But those candidates still score with tag-estimated features (`isEstimated = true`), which use genre centroids instead of real measured audio values. The result: a niche soul track from 2018 and a generic R&B hit from 2024 may receive nearly identical estimated feature vectors, flattening the scoring distinction that makes niche discovery valuable.

**Root cause:**
1. `fillMissingPreviewURLs()` only tries iTunes. Niche tracks frequently lack iTunes previews, so they enter Stage 2 ineligible for librosa enrichment.
2. `AcousticBrainzService` is fully implemented (real energy/valence/danceability/acousticness/instrumentalness/BPM/key/mode) but removed as a property and never called. Pre-2022 niche tracks that are in AB's database score on tag estimation even though real measurements exist.
3. Stage 2 librosa enrichment is capped at 5 candidates. With more eligible candidates (from Components 1 and 2), this cap limits the benefit.

**Solution:** Three targeted additions — all in `RecommendationEngine.swift`.

---

## Architecture

The three components interact productively:

- **Component 1 (Deezer fallback)** → more candidates have preview URLs → more Stage 2 eligible
- **Component 2 (AcousticBrainz)** → pre-2022 candidates get `isEstimated = false` without librosa → Stage 2 budget freed for modern tracks
- **Component 3 (Stage 2 5→10)** → larger budget absorbs the additional eligible candidates from both above

Neither Component 1 nor Component 2 is load-bearing for the other — each independently increases real-feature coverage for different eras.

---

## Component 1: Deezer Preview Fallback

**Insertion point:** `fillMissingPreviewURLs()` (line 1490), inside the `withTaskGroup` closure per candidate.

**Current behavior:**
```swift
let url = await self.itunesService.fetchPreviewURL(title: item.title, artist: item.artist)
return (item.index, url)
```

**New behavior:**
```swift
let url = await self.itunesService.fetchPreviewURL(title: item.title, artist: item.artist)
    ?? (await self.deezerService.fetchPreviewURL(title: item.title, artist: item.artist))
return (item.index, url)
```

`deezerService` is already an instance property at line 48 (`private let deezerService = DeezerService()`). `fetchPreviewURL(title:artist:)` is non-throwing and returns `String?`. The Deezer call fires only on iTunes miss — zero overhead for candidates iTunes covers.

**Why no separate pass:** Chaining inside the existing task group preserves the parallel-per-candidate structure. All iTunes calls remain concurrent; Deezer fallbacks run sequentially per candidate (after its iTunes miss) but concurrently across candidates.

**Latency:** Deezer call only fires when iTunes misses. For most mainstream candidates, iTunes succeeds and there is no overhead. For niche candidates without iTunes previews — the exact tracks that need this most — Deezer adds ~200–400ms per candidate, but these run concurrently within the task group.

---

## Component 2: AcousticBrainz in Stage 1

**New property:** Add `acousticBrainzService` to `RecommendationEngine`'s service block (after line 56, before line 61):
```swift
private let acousticBrainzService = AcousticBrainzService()
```

`AcousticBrainzService` takes no parameters in its initializer.

**Insertion point:** Stage 1 `withTaskGroup` closure (lines 1299–1363), between Priority 1 (Supabase cache, line 1305) and the existing stagger + tag estimation block (line 1310).

**New priority order per candidate:**

```swift
// ── Priority 1: Supabase feature cache ── (unchanged)
if let cached = await self.supabase.lookupFeatures(title: song.title, artist: song.artist) {
    simiLog("✅ Supabase cache hit (enrichment): \"\(song.title)\"")
    return (index, cached)
}

// ── Priority 2: AcousticBrainz (pre-2022 real measurements) ──
if let mbid = await self.listenBrainzService.resolveACRMBID(title: song.title, artist: song.artist),
   let abFeatures = await self.acousticBrainzService.fetchFeatures(mbid: mbid) {
    simiLog("✅ AcousticBrainz features: \"\(song.title)\"")
    return (index, abFeatures)
}

// ── Priority 3: tag estimation ── (was Priority 2, otherwise unchanged)
if index > 0 { ... }
```

**MBID lookup:** `listenBrainzService.resolveACRMBID(title:artist:)` — non-throwing, returns `String?`. Already live at line 50.

**AB features:** `acousticBrainzService.fetchFeatures(mbid:)` — non-throwing, returns `AudioFeatures?`. Returns nil if AB has no data for the MBID (all post-2022 tracks, and pre-2022 tracks not yet submitted to AB).

**Partial fields:** AB provides energy, valence, danceability, acousticness, instrumentalness, BPM, key, mode. Fields not measured by AB (liveness, spectralWarmth, tonalClarity, vocalPresence, reverbSpace) default to `0.0`. AB-returned `AudioFeatures` has `isEstimated = false` — Stage 2 skips these candidates, freeing librosa slots for modern tracks.

**Relationship to existing disabled AB code (lines 965–971):** That commented-out block is in `fetchAudioFeaturesWithFallback()` (the source song path). Component 2 adds AB enrichment in `enrichWithABFeatures()` Stage 1 (the candidate path). These are independent paths — leave the lines 965–971 comment as-is.

**Latency:** `resolveACRMBID` has an 8s timeout and runs concurrently across all candidates in the task group. For modern tracks, it returns nil quickly (ACR lookup is a single indexed GET, not a full search). The AB fetch only fires on MBID hit, so modern-track overhead is one MBID lookup per candidate.

---

## Component 3: Stage 2 Expansion 5 → 10

**Change:** Line 1411 — `.prefix(5)` → `.prefix(10)`.

```swift
// Before:
let librosaTargets = recommendations
    .prefix(5)

// After:
let librosaTargets = recommendations
    .prefix(10)
```

No other changes. Stage 2's chunking (groups of 2, concurrent) and cancellation guards are unchanged.

**Latency:** Worst case (10 slots all occupied, no AB hits): 5 chunks × ~2–3s = ~10–15s for Stage 2. This is the accepted quality trade-off for niche discovery, consistent with the Spec A latency acceptance for artist-similar fan-out. In practice, AB hits reduce Stage 2 demand for pre-2022 tracks, and Deezer provides preview URLs for tracks that previously had none — actual slot utilization will often be lower than 10.

---

## Files Changed

| File | Change |
|------|--------|
| `Simi/Simi/Services/RecommendationEngine.swift` | Add `acousticBrainzService` property + AB block in Stage 1 + Deezer `??` chain in `fillMissingPreviewURLs` + `prefix(10)` |
| `Simi/Simi/Services/AcousticBrainzService.swift` | **No changes** — fully implemented, just needs to be instantiated |
| `Simi/Simi/Services/ListenBrainzService.swift` | **No changes** — `resolveACRMBID` already live |
| `Simi/Simi/Services/DeezerService.swift` | **No changes** — `fetchPreviewURL` already live |

---

## Interfaces

**New property on `RecommendationEngine`:**
```swift
private let acousticBrainzService = AcousticBrainzService()
```

**Methods used (no signature changes):**
```swift
// ListenBrainzService — line 42
func resolveACRMBID(title: String, artist: String) async -> String?

// AcousticBrainzService — line 26
func fetchFeatures(mbid: String) async -> AudioFeatures?

// DeezerService — already called elsewhere
func fetchPreviewURL(title: String, artist: String) async -> String?
```

---

## Constraints

- No changes to `LastFMService.swift`, `DeezerService.swift`, `ListenBrainzService.swift`, or `AcousticBrainzService.swift`
- No changes to `mergeAndScore()`, `computeSimilarity()`, `enrichWithABFeatures()` scoring logic, or Stage 2 chunking
- The disabled AB code at lines 965–971 (`fetchAudioFeaturesWithFallback`) is left as-is — different code path
- SourceKit false positives at lines 33–52 are expected and ignorable; all Xcode builds succeed 0 errors/0 warnings
- `RecommendationEngine` is `@MainActor class` — new AB block inside `withTaskGroup.addTask` is fine (same pattern as existing async calls there)
- Each `async let` can only be awaited once — not applicable here (no `async let` added)
- AB features have `isEstimated = false` by default from `AcousticBrainzService.fetchFeatures` — verify this in implementation

---

## Success Criteria

1. Pre-2022 niche tracks with AB data receive `isEstimated = false` features from Stage 1 without a librosa call
2. Modern niche tracks without iTunes previews but with Deezer previews receive preview URLs and qualify for Stage 2
3. Stage 2 runs up to 10 librosa enrichments per search
4. Build: 0 errors, 0 warnings (SourceKit false positives excluded)
5. No regression: mainstream track searches return same quality or better (all three changes are additive — AB hits improve pre-2022 tracks, Deezer fills gaps, Stage 2 expansion only benefits when more slots are available)

---

## Out of Scope

- Proactive DCLAP catalog building (Spec C)
- Changing the 0.62 similarity threshold in `enrichWithABFeatures`
- Supabase write-back for AB features (could be added later; not in scope here)
- Rate-limit stagger for AB/MBID lookups (both services handle their own error paths)
