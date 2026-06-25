# Feature Quality Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three independent, compounding improvements to `RecommendationEngine.swift` to maximize real measured audio features for niche candidates across both pre-2022 catalog and modern releases.

**Architecture:** Deezer preview fallback gives more candidates preview URLs (enabling librosa enrichment); AcousticBrainz enrichment provides real measured features for pre-2022 tracks in Stage 1 without consuming librosa slots; Stage 2 expansion from 5→10 absorbs the increased supply of eligible candidates from the first two changes.

**Tech Stack:** Swift 5, SwiftUI, `xcodebuild` for build verification (no XCTest target exists in this project — build success is the primary verification gate)

## Global Constraints

- Modify `Simi/Simi/Services/RecommendationEngine.swift` only — no changes to `AcousticBrainzService.swift`, `DeezerService.swift`, `ListenBrainzService.swift`, or any other service file
- No changes to `mergeAndScore()`, `computeSimilarity()`, `enrichWithABFeatures()` scoring logic, or Stage 2 chunking logic
- The disabled AB code at lines 965–971 in `fetchAudioFeaturesWithFallback()` (source song path) is left as-is — different code path, do not touch
- SourceKit false positives at lines 33–52 of `RecommendationEngine.swift` ("Cannot find type X in scope") are expected, always present, and ignorable — build still succeeds with 0 real errors / 0 warnings
- `RecommendationEngine` is `@MainActor class` — all new code runs inside existing `withTaskGroup.addTask` closures, which is correct
- `AcousticBrainzService.fetchFeatures(mbid:)` returns `AudioFeatures` with `isEstimated = false` by default (confirmed: `AudioFeatures.isEstimated: Bool = false` in `Song.swift` line 43) — no explicit flag-setting needed in the AB block
- Deezer fallback uses `var url = await iTunes...; if url == nil { url = await Deezer... }` — Swift's `??` operator uses `@autoclosure` which does not support `async`, so `await X ?? (await Y)` does not compile
- All commits go in the inner Swift repo at `Simi/` (not the outer docs repo at `Simi App/`)
- Build command: `cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && xcodebuild build -project Simi.xcodeproj -scheme Simi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
- Expected build output: `** BUILD SUCCEEDED **`

---

### Task 1: Deezer Preview Fallback

**Files:**
- Modify: `Simi/Simi/Services/RecommendationEngine.swift:1501–1502`

**Interfaces:**
- Consumes: `deezerService.fetchPreviewURL(title: String, artist: String) async -> String?` — already an instance property at line 48, non-throwing, returns `String?`
- Produces: nothing for downstream tasks — independent change

- [ ] **Step 1: Read lines 1498–1510 to confirm starting state**

Read `Simi/Simi/Services/RecommendationEngine.swift` lines 1498–1510. Confirm the task group closure reads:
```swift
        let updates: [(Int, String)] = await withTaskGroup(of: (Int, String?).self) { group in
            for item in needsURL {
                group.addTask {
                    let url = await self.itunesService.fetchPreviewURL(title: item.title, artist: item.artist)
                    return (item.index, url)
                }
            }
```
If you see this, proceed. If the code differs, stop and report before making any change.

- [ ] **Step 2: Add the Deezer fallback at lines 1501–1502**

Replace lines 1501–1502:
```swift
                    let url = await self.itunesService.fetchPreviewURL(title: item.title, artist: item.artist)
                    return (item.index, url)
```
With:
```swift
                    var url = await self.itunesService.fetchPreviewURL(title: item.title, artist: item.artist)
                    if url == nil {
                        url = await self.deezerService.fetchPreviewURL(title: item.title, artist: item.artist)
                    }
                    return (item.index, url)
```

Note: `await X ?? (await Y)` does not compile in Swift — `??` uses `@autoclosure` which cannot contain `await`. The `var url + if url == nil` pattern is the correct Swift idiom with identical short-circuit semantics. `deezerService` is already declared at line 48 — no new property needed.

- [ ] **Step 3: Build and verify**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && xcodebuild build -project Simi.xcodeproj -scheme Simi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

SourceKit warnings at lines 33–52 ("Cannot find type...") are expected and harmless — ignore them. Any other warning or error is real — fix before proceeding.

- [ ] **Step 4: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && git add Simi/Services/RecommendationEngine.swift && git commit -m "feat: add Deezer preview fallback in fillMissingPreviewURLs

iTunes-only lookup left niche candidates without preview URLs.
Deezer fallback fires on iTunes miss, enabling those candidates
for Stage 2 librosa enrichment."
```

---

### Task 2: AcousticBrainz Stage 1 Integration

**Files:**
- Modify: `Simi/Simi/Services/RecommendationEngine.swift:51` (replace comment with property declaration)
- Modify: `Simi/Simi/Services/RecommendationEngine.swift:1308–1310` (insert AB priority block + update comment)

**Interfaces:**
- Consumes: `listenBrainzService.resolveACRMBID(title: String, artist: String) async -> String?` — instance property at line 50, non-throwing
- Consumes: `acousticBrainzService.fetchFeatures(mbid: String) async -> AudioFeatures?` — new property added in Step 2 of this task, non-throwing
- Produces: nothing for Task 3 — independent change

- [ ] **Step 1: Read lines 46–57 to confirm starting state**

Read `Simi/Simi/Services/RecommendationEngine.swift` lines 46–57. Confirm:
- Line 50: `private let listenBrainzService = ListenBrainzService()`
- Line 51: `// acousticBrainzService removed — AB deprecated 2022, disabled in fetchAudioFeaturesWithFallback`
- Line 52: `private let itunesService       = iTunesService()`

If these match, proceed. If not, stop and report.

- [ ] **Step 2: Replace the removal comment at line 51 with the acousticBrainzService property**

Replace line 51:
```swift
    // acousticBrainzService removed — AB deprecated 2022, disabled in fetchAudioFeaturesWithFallback
```
With:
```swift
    private let acousticBrainzService = AcousticBrainzService()
```

`AcousticBrainzService` takes no init parameters. Its `fetchFeatures(mbid:)` returns `AudioFeatures` with `isEstimated = false` by default — no explicit flag-setting needed.

- [ ] **Step 3: Read lines 1302–1315 to confirm Stage 1 insertion point**

Read `Simi/Simi/Services/RecommendationEngine.swift` lines 1302–1315. Confirm you see:
```swift
                    // ── Priority 1: Supabase feature cache ──
                    // Songs analyzed in a previous session are stored here; skip Last.fm
                    // entirely for them. No stagger needed — cache hit is a single indexed read.
                    if let cached = await self.supabase.lookupFeatures(title: song.title, artist: song.artist) {
                        simiLog("✅ Supabase cache hit (enrichment): \"\(song.title)\"")
                        return (index, cached)
                    }

                    // ── Priority 2: tag estimation ──
```

If you see this, proceed.

- [ ] **Step 4: Insert the AB priority block and update the tag estimation comment**

After the closing `}` of the Supabase cache block (line 1308) and before the `// ── Priority 2: tag estimation ──` comment (line 1310), insert the following block. Also update the `Priority 2` comment to `Priority 3`:

The section from line 1308 to 1313 should become:
```swift
                    }

                    // ── Priority 2: AcousticBrainz (pre-2022 real measurements) ──
                    // MBID lookup short-circuits on miss for modern tracks (one fast indexed GET).
                    // AB fetch only fires on MBID hit. Returns isEstimated=false by default.
                    if let mbid = await self.listenBrainzService.resolveACRMBID(title: song.title, artist: song.artist),
                       let abFeatures = await self.acousticBrainzService.fetchFeatures(mbid: mbid) {
                        simiLog("✅ AcousticBrainz features: \"\(song.title)\"")
                        return (index, abFeatures)
                    }

                    // ── Priority 3: tag estimation ──
                    // Stagger requests to respect Last.fm rate limits.
                    // Capped at index 15 (300ms max) — was unbounded × 20ms (760ms for song 38).
                    if index > 0 {
```

- [ ] **Step 5: Build and verify**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && xcodebuild build -project Simi.xcodeproj -scheme Simi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

SourceKit false positives at lines 33–52 are expected and ignorable. Any other error or warning is real — fix before proceeding.

- [ ] **Step 6: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && git add Simi/Services/RecommendationEngine.swift && git commit -m "feat: add AcousticBrainz Stage 1 enrichment for pre-2022 candidates

Re-enables acousticBrainzService as Stage 1 Priority 2 in candidate
enrichment. Pre-2022 tracks with AB data get isEstimated=false features
without a librosa call, freeing Stage 2 slots for modern niche tracks.
Modern tracks pay one MBID lookup on miss then fall through to tag
estimation unchanged."
```

---

### Task 3: Stage 2 Expansion 5 → 10

**Files:**
- Modify: `Simi/Simi/Services/RecommendationEngine.swift:1411`

**Interfaces:**
- Consumes: nothing from earlier tasks — independent change
- Produces: nothing downstream

- [ ] **Step 1: Read lines 1409–1418 to confirm starting state and verify the isEstimated guard**

Read `Simi/Simi/Services/RecommendationEngine.swift` lines 1409–1418. Confirm you see:
```swift
        let librosaTargets = recommendations
            .prefix(5)
            .enumerated()
            .compactMap { (i, song) -> (index: Int, url: String)? in
                guard let url = song.previewURL,
                      song.audioFeatures?.isEstimated != false else { return nil }
                return (index: i, url: url)
            }
```

The `isEstimated != false` guard at line 1415 confirms that AB-enriched candidates (`isEstimated = false`) are automatically excluded from `librosaTargets` — they never consume Stage 2 librosa slots. This is the Stage 2 slot-freeing mechanic from the spec. Verify this guard is present before proceeding.

- [ ] **Step 2: Change `.prefix(5)` to `.prefix(10)` at line 1411**

Replace:
```swift
            .prefix(5)
```
With:
```swift
            .prefix(10)
```

No other changes to this function — chunking logic, concurrency guards, and cancellation checks are all unchanged.

- [ ] **Step 3: Build and verify**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && xcodebuild build -project Simi.xcodeproj -scheme Simi -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && git add Simi/Services/RecommendationEngine.swift && git commit -m "feat: expand Stage 2 librosa enrichment from 5 to 10 candidates

Doubles the candidates receiving real measured audio features via
librosa. AB-enriched candidates (isEstimated=false) are excluded by
the existing guard at line 1415, so their Stage 1 hits free slots
for modern niche tracks that gained preview URLs from the Deezer
fallback."
```
