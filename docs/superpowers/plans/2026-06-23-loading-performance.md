# Loading Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut real latency 1–3s via early Supabase pre-fetch for Last.fm/ListenBrainz candidates and make the loading state feel alive with on-brand messages + pulsing teal dots.

**Architecture:** Two independent changes — pipeline timing in `RecommendationEngine.swift` and visual polish in `ResultsView.swift`. Task 1 restructures the await order in both `findSimilarSongs` functions to fire Supabase lookups for early candidates while Spotify/vector/DCLAP are still in flight, feeding results into `prefetchCandidateFeatures()` via a new `prewarmedCache` parameter. Task 2 adds `PulsingDotsView` + loading message with fade transition to the skeleton section of `ResultsView`.

**Tech Stack:** Swift 5.9, SwiftUI, `withTaskGroup`, `Task { }` detached tasks, `Timer.publish`, `@Environment(\.accessibilityReduceMotion)`

## Global Constraints

- No changes outside `RecommendationEngine.swift` and `ResultsView.swift`
- `SimilarSong` is a struct — all mutations via `firstIndex(where:) + index reassignment`
- `RecommendationEngine` is `@MainActor class` — all methods implicitly on main actor
- SourceKit false positives ("Cannot find type X in scope") are known and expected — ignore them; all Xcode builds succeed 0 errors/0 warnings
- `accessibilityReduceMotion` must be respected: no animation when true (static dots at 0.6 opacity, instant message swap)
- Do NOT change `mergeAndScore`, `embedCandidatesInBackground`, or any function not listed in Files Changed
- All 4 loading messages must be updated in BOTH `findSimilarSongs(for urlString:)` AND `findSimilarSongs(title:artist:)`
- Timeout: change `10_000_000_000` → `7_000_000_000` nanoseconds (not seconds — `Task.sleep(nanoseconds:)`)
- `earlyLookupTask` cache key format: `"\(track.title)|\(track.artist)".lowercased()`

---

### Task 1: Early Supabase Pre-Fetch + Loading Messages

**Files:**
- Modify: `Simi/Simi/Services/RecommendationEngine.swift`

**Interfaces:**
- Consumes: existing `supabase.lookupFeatures(title:artist:)` → `AudioFeatures?`
- Produces:
  - `prefetchCandidateFeatures(candidates:sourceFeatures:genres:seedFeatures:prewarmedCache:)` — adds `prewarmedCache: [String: AudioFeatures] = [:]` param
  - `runPrefetchEnrichment(candidates:sourceFeatures:genres:seedFeatures:prewarmedCache:)` — same new param

**What this task changes:**

1. **Restructure await order in `findSimilarSongs(for urlString:)`** (lines 302–307): split the group await into two phases — await `lastFMTracks` + `lbTracks` first, fire `earlyLookupTask`, then await `spotifyRecs/vectorCandidates/dclapCandidates`.

2. **Same restructure in `findSimilarSongs(title:artist:)`** (lines 493–498 of that function).

3. **Add `prewarmedCache` param to `prefetchCandidateFeatures()` and `runPrefetchEnrichment()`**, with cache check before Supabase lookup in `runPrefetchEnrichment`.

4. **Timeout: 10s → 7s** in `prefetchCandidateFeatures`.

5. **4 loading message string replacements** in each function (8 total).

---

- [ ] **Step 1: Update `findSimilarSongs(for urlString:)` — restructure awaits + add early lookup task**

In `RecommendationEngine.swift`, find the block at approximately lines 302–342 that currently awaits all candidates together then calls `prefetchCandidateFeatures`. Replace with:

```swift
// Phase 1: await early candidates (Last.fm + ListenBrainz arrive first)
let lastFMTracks     = await similarTracksTask
let lbTracks         = await lbTask

// Early Supabase pre-fetch — runs while Spotify/vector/DCLAP are still in flight.
// Results passed to prefetchCandidateFeatures() as prewarmedCache to skip duplicate lookups.
let earlyLookupTask = Task<[String: AudioFeatures], Never> {
    var cache: [String: AudioFeatures] = [:]
    await withTaskGroup(of: (String, AudioFeatures?).self) { group in
        for track in (lastFMTracks + lbTracks).prefix(20) {
            group.addTask {
                let key = "\(track.title)|\(track.artist)".lowercased()
                let features = await self.supabase.lookupFeatures(title: track.title, artist: track.artist)
                return (key, features)
            }
        }
        for await (key, features) in group {
            if let features { cache[key] = features }
        }
    }
    return cache
}

// Phase 2: await remaining candidates
let genres           = await genresTask
let spotifyRecs      = (try? await spotifyRecsTask) ?? []
let vectorCandidates = await vectorTask
let dclapCandidates  = await dclapTask
self.detectedGenres  = genres
self.lastGenres      = genres
```

The variable names `lastFMTracks`, `lbTracks`, `genres`, `spotifyRecs`, `vectorCandidates`, `dclapCandidates` replace the old awaits at lines ~302–308. The rest of the function (mergeAndScore call, guard, loadingMessage, prefetchCandidateFeatures call) stays the same except:

- Pass `prewarmedCache: await earlyLookupTask.value` to `prefetchCandidateFeatures`:
```swift
let earlyCache = await earlyLookupTask.value
let enriched = await prefetchCandidateFeatures(
    candidates: merged,
    sourceFeatures: sourceFeatures,
    genres: genres,
    prewarmedCache: earlyCache
)
```

- [ ] **Step 2: Update loading messages in `findSimilarSongs(for urlString:)`**

Four replacements (exact strings — replace only the string literal, not surrounding code):

```swift
// Line ~225:
loadingMessage = "Finding song…"
// → stays the same: "Finding song…" was already the first message

// Actually these are the NEW messages per spec:
// Line ~225: "Finding song…"      → "Reading the song…"
// Line ~246: "Analyzing audio…"   → "Analyzing the feeling…"
// Line ~282: "Finding similar songs…" → "Searching for its emotional kin…"
// Line ~337: "Almost ready…"      → "Putting it together…"
```

Exact replacements:
- `loadingMessage = "Finding song…"` → `loadingMessage = "Reading the song…"` (line ~225)
- `loadingMessage = "Analyzing audio…"` → `loadingMessage = "Analyzing the feeling…"` (line ~246)
- `loadingMessage = "Finding similar songs…"` → `loadingMessage = "Searching for its emotional kin…"` (line ~282)
- `loadingMessage = "Almost ready…"` → `loadingMessage = "Putting it together…"` (line ~337)

- [ ] **Step 3: Update `findSimilarSongs(title:artist:)` — same restructure**

In `findSimilarSongs(title:artist:)`, find the equivalent block (approximately lines 493–532). Apply the same restructuring: split into Phase 1 (await `lastFMTracks` + `lbTracks`), fire `earlyLookupTask`, Phase 2 (await `genres`, `spotifyRecs`, `vectorCandidates`, `dclapCandidates2`).

Note: the variable in the text mode function is `dclapCandidates2` (not `dclapCandidates`). Keep the existing name.

Same loading message replacements (lines ~431, ~443, ~475, ~528):
- `loadingMessage = "Finding song…"` → `loadingMessage = "Reading the song…"` (line ~431)
- `loadingMessage = "Analyzing audio…"` → `loadingMessage = "Analyzing the feeling…"` (line ~443)
- `loadingMessage = "Finding similar songs…"` → `loadingMessage = "Searching for its emotional kin…"` (line ~475)
- `loadingMessage = "Almost ready…"` → `loadingMessage = "Putting it together…"` (line ~528)

Same `prefetchCandidateFeatures` call update with `prewarmedCache`:
```swift
let earlyCache = await earlyLookupTask.value
let enriched = await prefetchCandidateFeatures(
    candidates: merged,
    sourceFeatures: sourceFeatures,
    genres: genres,
    prewarmedCache: earlyCache
)
```

- [ ] **Step 4: Add `prewarmedCache` parameter to `prefetchCandidateFeatures()`**

Update the signature at line ~1554:

```swift
private func prefetchCandidateFeatures(
    candidates: [SimilarSong],
    sourceFeatures: AudioFeatures,
    genres: [Genre],
    seedFeatures: [AudioFeatures] = [],
    prewarmedCache: [String: AudioFeatures] = [:]
) async -> [SimilarSong] {
```

Update the inner call to `runPrefetchEnrichment` to pass it through:

```swift
group.addTask {
    await self.runPrefetchEnrichment(
        candidates: candidates,
        sourceFeatures: sourceFeatures,
        genres: genres,
        seedFeatures: seedFeatures,
        prewarmedCache: prewarmedCache
    )
}
```

- [ ] **Step 5: Change timeout from 10s to 7s**

In `prefetchCandidateFeatures`, at line ~1575:

```swift
// Before:
try? await Task.sleep(nanoseconds: 10_000_000_000)
// After:
try? await Task.sleep(nanoseconds: 7_000_000_000)
```

Also update the comment at line ~1552 from "10-second timeout" to "7-second timeout":
```swift
/// Runs as two racing tasks: the enrichment work vs. a 7-second timeout.
/// Whichever finishes first wins — skeletons never persist past 7s.
```

- [ ] **Step 6: Add `prewarmedCache` parameter to `runPrefetchEnrichment()` and use it**

Update the signature at line ~1586:

```swift
private func runPrefetchEnrichment(
    candidates: [SimilarSong],
    sourceFeatures: AudioFeatures,
    genres: [Genre],
    seedFeatures: [AudioFeatures],
    prewarmedCache: [String: AudioFeatures] = [:]
) async -> [SimilarSong] {
```

Inside `runPrefetchEnrichment`, in the `withTaskGroup` where each candidate fires a task, add a cache check BEFORE the `supabase.lookupFeatures` call. Currently at line ~1600:

```swift
// Before:
group.addTask {
    if let cached = await self.supabase.lookupFeatures(title: song.title, artist: song.artist) {
        return (index, cached)
    }
    // ... Last.fm fallback
}

// After:
group.addTask {
    let cacheKey = "\(song.title)|\(song.artist)".lowercased()
    if let prewarmed = prewarmedCache[cacheKey] {
        return (index, prewarmed)
    }
    if let cached = await self.supabase.lookupFeatures(title: song.title, artist: song.artist) {
        return (index, cached)
    }
    // ... Last.fm fallback (unchanged)
}
```

- [ ] **Step 7: Build in Xcode to verify 0 errors/0 warnings**

Use Xcode or `xcodebuild` to build the Simi scheme. SourceKit false positives ("Cannot find type X in scope") in diagnostic output are expected and ignorable. The build must report 0 build errors and 0 warnings.

- [ ] **Step 8: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi"
git add Simi/Services/RecommendationEngine.swift
git commit -m "perf: early Supabase pre-fetch + 7s timeout + on-brand loading messages"
```

---

### Task 2: PulsingDotsView + Loading Message Fade in ResultsView

**Files:**
- Modify: `Simi/Simi/Views/ResultsView.swift`

**Interfaces:**
- Consumes (from Task 1): `engine.loadingMessage` — now emits on-brand strings ("Reading the song…", "Analyzing the feeling…", "Searching for its emotional kin…", "Putting it together…")
- Consumes: `engine.isLoading`, `engine.recommendations` (already used in `listContent`)
- Produces: `PulsingDotsView` private struct (used only inside `listContent`)

**What this task changes:**

1. Add `PulsingDotsView` private struct to `ResultsView.swift`.
2. In the skeleton section of `listContent(proxy:)` — wrap skeleton cards + dots in a `VStack`, add `PulsingDotsView` below the cards, and add `Text(engine.loadingMessage)` with `.id`/`.transition`/`.animation` above or below the dots.

---

- [ ] **Step 1: Add `PulsingDotsView` private struct**

At the bottom of `ResultsView.swift` (after the last `}` that closes `ResultsView`), add:

```swift
// MARK: - Pulsing Dots

private struct PulsingDotsView: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var animate = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.simiAccent)
                    .frame(width: 8, height: 8)
                    .opacity(reduceMotion ? 0.6 : (animate ? 1.0 : 0.3))
                    .animation(
                        reduceMotion ? nil : Animation
                            .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
        .onDisappear { animate = false }
    }
}
```

- [ ] **Step 2: Update `listContent(proxy:)` skeleton section**

The current skeleton section at lines ~715–724:

```swift
if engine.isLoading && engine.recommendations.isEmpty {
    VStack(spacing: 12) {
        ForEach(0..<4, id: \.self) { _ in
            SkeletonCard()
                .padding(.horizontal, 20)
        }
    }
    .padding(.bottom, 24)
}
```

Replace with:

```swift
if engine.isLoading && engine.recommendations.isEmpty {
    VStack(spacing: 12) {
        ForEach(0..<4, id: \.self) { _ in
            SkeletonCard()
                .padding(.horizontal, 20)
        }
        PulsingDotsView()
            .padding(.top, 12)
        Text(engine.loadingMessage)
            .font(.simiMicro)
            .foregroundColor(.simiSubtext)
            .id(engine.loadingMessage)
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: engine.loadingMessage)
            .padding(.top, 4)
    }
    .padding(.bottom, 24)
}
```

Note: `reduceMotion` is already a property on `ResultsView` at line 31 — no new declaration needed.

- [ ] **Step 3: Build in Xcode to verify 0 errors/0 warnings**

Build the Simi scheme. SourceKit false positives are expected and ignorable.

- [ ] **Step 4: Manual smoke test**

Run the app in the simulator. Trigger a search. Verify:
1. Three teal dots pulse in sequence below the skeleton cards while loading
2. Loading messages appear below the dots and cross-fade between stages (not instant snap)
3. When `accessibilityReduceMotion` is ON (Settings → Accessibility → Motion → Reduce Motion), dots are static at ~60% opacity and messages swap instantly with no fade

- [ ] **Step 5: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi"
git add Simi/Views/ResultsView.swift
git commit -m "feat: pulsing dots + loading message fade in ResultsView skeleton"
```
