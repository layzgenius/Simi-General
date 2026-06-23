# Loading Performance & Perceived Speed
**Date:** 2026-06-23
**Scope:** Cut real latency from the enrichment pipeline + make the loading state feel purposeful and alive.

---

## Overview

Two interlocking improvements:

1. **Pipeline optimization** — start Supabase cache lookups for early candidates while Spotify recs + vector search are still in flight, so `prefetchCandidateFeatures()` has less work to do when it runs. Tighten the fallback timeout from 10s to 7s.
2. **Perceived performance** — on-brand loading messages that fade between states, and three pulsing teal dots under the skeleton cards so the screen feels alive during the wait.

Together these target both actual latency (1–3s reduction on cold Supabase cache) and perceived latency (the wait feels purposeful, not frozen).

---

## Section 1: Pipeline Optimization

### Problem
`prefetchCandidateFeatures()` runs after `mergeAndScore()` — meaning Supabase enrichment only starts once ALL candidates are gathered. The 3–5s window while Spotify recs + vector search + DCLAP are in flight is completely idle from an enrichment perspective. Last.fm tracks and ListenBrainz tracks arrive first (1–2s) but their Supabase lookups don't start until several seconds later.

### Fix: Early Supabase Pre-Fetch

**In `findSimilarSongs(for urlString:)` and `findSimilarSongs(title:artist:)` in `RecommendationEngine.swift`:**

After `lastFMTracks` and `lbTracks` are awaited (while `spotifyRecsTask`, `vectorTask`, and `dclapTask` are still in flight), fire a detached `Task` that performs Supabase lookups for the early candidates:

```swift
// Early Supabase pre-fetch — runs while Spotify/vector candidates are still in flight.
// Results stored in a shared dict passed to prefetchCandidateFeatures() later.
var earlyFeatureCache: [String: AudioFeatures] = [:]
let earlyLookupTask = Task {
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
```

After all candidates are gathered and `mergeAndScore()` runs, await the early lookup result and pass it into `prefetchCandidateFeatures()` as initial warm cache:

```swift
let earlyCache = await earlyLookupTask.value
let enriched = await prefetchCandidateFeatures(
    candidates: merged,
    sourceFeatures: sourceFeatures,
    genres: genres,
    prewarmedCache: earlyCache
)
```

`prefetchCandidateFeatures()` gains a `prewarmedCache: [String: AudioFeatures] = [:]` parameter. Before doing any Supabase lookup for a candidate, it checks the prewarmed cache first:

```swift
let cacheKey = "\(candidate.title)|\(candidate.artist)".lowercased()
if let cached = prewarmedCache[cacheKey] {
    // use cached features directly, skip Supabase lookup
}
```

### Timeout Reduction

Change the race timeout inside `prefetchCandidateFeatures()` from 10 seconds to 7 seconds:

```swift
// was: try await Task.sleep(for: .seconds(10))
try await Task.sleep(for: .seconds(7))
```

7s is the realistic ceiling with early pre-warming active. The 10s ceiling was conservative for cold-cache scenarios that the pre-warming now addresses.

### Expected Impact
- Cold Supabase cache: 1–3s reduction (early candidates already enriched when `prefetchCandidateFeatures()` runs)
- Warm Supabase cache: negligible change (already fast)
- Worst case: 7s fallback instead of 10s — results reveal slightly earlier with best-effort features

### Files Changed
- `Simi/Services/RecommendationEngine.swift`
  - Add `earlyLookupTask` after `lastFMTracks` + `lbTracks` are available in both `findSimilarSongs(for urlString:)` and `findSimilarSongs(title:artist:)`
  - Add `prewarmedCache: [String: AudioFeatures] = [:]` parameter to `prefetchCandidateFeatures()`
  - Check prewarmed cache before Supabase lookup inside `prefetchCandidateFeatures()`
  - Change timeout from 10s to 7s

---

## Section 2: Perceived Performance

### Loading Messages

Replace generic loading messages with on-brand copy in `RecommendationEngine.swift`. Messages narrate what Simi is actually doing:

| Location in code | Current | New |
|-----------------|---------|-----|
| Start of URL resolution | `"Finding song…"` | `"Reading the song…"` |
| After source song resolved | `"Analyzing audio…"` | `"Analyzing the feeling…"` |
| Before candidate fetch | `"Finding similar songs…"` | `"Searching for its emotional kin…"` |
| Before `prefetchCandidateFeatures` | `"Almost ready…"` | `"Putting it together…"` |

### Message Fade Transition

In `ResultsView.swift`, the `loadingMessage` text gets a cross-fade when it changes:

```swift
Text(engine.loadingMessage)
    .id(engine.loadingMessage)  // forces SwiftUI to re-render on change
    .transition(.opacity)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: engine.loadingMessage)
```

`accessibilityReduceMotion`: when true, message snaps to new value with no animation.

### Pulsing Dots

Three pulsing dots shown below the skeleton cards while `engine.isLoading && engine.recommendations.isEmpty`.

**Placement:** In `listContent()` in `ResultsView.swift`, add below the `ForEach` of skeleton cards:

```swift
if engine.isLoading && engine.recommendations.isEmpty {
    VStack(spacing: 12) {
        ForEach(0..<4, id: \.self) { _ in
            SkeletonCard().padding(.horizontal, 20)
        }
        PulsingDotsView()
            .padding(.top, 12)
    }
}
```

**`PulsingDotsView`** (new private struct in `ResultsView.swift`):

```swift
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

- Dot size: 8pt diameter
- Color: `Color.simiAccent` (teal)
- Opacity range: 0.3 → 1.0, easeInOut, 0.4s per cycle, repeating
- Stagger: 0.2s delay between dots (dot 0, dot 1, dot 2)
- `reduceMotion`: static dots at 0.6 opacity, no animation
- `onDisappear` resets `animate` to false so re-entry is clean on a new search

### Files Changed
- `Simi/Services/RecommendationEngine.swift` — 4 `loadingMessage` string replacements
- `Simi/Views/ResultsView.swift` — `PulsingDotsView` struct, loading message fade, dots placement in `listContent()`

---

## Files Changed (complete)

| File | Change |
|------|--------|
| `Simi/Services/RecommendationEngine.swift` | Early Supabase pre-fetch, `prefetchCandidateFeatures()` prewarmed cache param, 10s→7s timeout, 4 loading message updates |
| `Simi/Views/ResultsView.swift` | `PulsingDotsView` struct, message fade transition, dots below skeleton cards |

---

## Success Criteria

1. Cold Supabase cache: results appear in 5–7s instead of 7–10s
2. Fallback timeout is 7s (not 10s) — skeletons never persist past 7s
3. Loading messages cross-fade smoothly between each stage; no snap
4. Three teal dots pulse in sequence under skeleton cards during loading
5. `accessibilityReduceMotion` suppresses all animations (static dots, instant message swap)
6. No re-sort or position change after first render (unchanged from Session Quality Redesign)
7. Warm Supabase cache path is unaffected — no regression for returning users
