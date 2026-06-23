# Session Quality Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate re-sort jitter after enrichment, give estimated songs emotional language, and add a 3-state feedback loop — all in one coordinated pass.

**Architecture:** Run `prefetchCandidateFeatures()` (Supabase + tag estimation for all candidates) before setting `isLoading = false`, so results reveal fully-scored. Remove both `.sort` calls from `enrichWithABFeatures()` — Railway runs in background and updates features only, never position. Loosen `buildMatchExplanation()` gates so estimated songs get softer emotional descriptors. Add `FeedbackRow` with session-only state stored on `SimilarSong`.

**Tech Stack:** Swift / SwiftUI, `@Published` + `@MainActor`, structured concurrency (`withTaskGroup`, `async let`), `EnvironmentObject`.

## Global Constraints

- `SimilarSong` is a struct — all mutations on `recommendations` must use index-based reassignment (`recommendations[idx].field = value`), never direct property mutation on a value copy
- No Supabase writes for feedback state — session-only in memory
- No re-sort after `self.recommendations` is set for the first time — positions are frozen on first render
- `SkeletonCard` height must match a real `SongCard` including `FeedbackRow` — measure by mirroring the VStack structure, not by guessing
- `prefetchCandidateFeatures()` max-wait is 10 seconds — skeletons never persist past that regardless of upstream slowness
- Last.fm stagger: indices 0–15 get 20ms delay per index (max 300ms), indices 16+ fire simultaneously with no additional delay
- Never add `recommendations.sort` back anywhere in the loading/enrichment pipeline

---

## File Map

| File | Changes |
|------|---------|
| `Simi/Models/Song.swift` | Add `FeedbackState` enum; add `feedbackState` property to `SimilarSong` |
| `Simi/Services/RecommendationEngine.swift` | Add `prefetchCandidateFeatures()`, `setFeedback()`, loosen `buildMatchExplanation()` gates (valence + energy rows), remove both `.sort` calls from `enrichWithABFeatures()` |
| `Simi/Views/SongCard.swift` | Add `@EnvironmentObject var engine`, add `FeedbackRow` subview, add teal left-border for `fits`, add 50% opacity for `miss` |
| `Simi/Views/ResultsView.swift` | Add `SkeletonCard` view (FeedbackRow-height-aware), show skeletons while `engine.isLoading && engine.recommendations.isEmpty`, stagger reveal animation |
| `Simi/Views/HomeView.swift` | Navigate to ResultsView as soon as `engine.sourceSong` is non-nil (was: wait for `isLoading == false`) |

---

### Task 1: Data Model — FeedbackState + setFeedback

**Files:**
- Modify: `Simi/Models/Song.swift:302` (end of `SimilarSong` struct, before closing `}`)
- Modify: `Simi/Services/RecommendationEngine.swift` (add `setFeedback` to the engine's public API)

**Interfaces:**
- Produces: `FeedbackState` enum (`.fits`, `.close`, `.miss`) used by Tasks 5
- Produces: `SimilarSong.feedbackState: FeedbackState?` read by `SongCard` in Task 5
- Produces: `engine.setFeedback(songID:state:)` called by `SongCard` in Task 5

- [ ] **Step 1: Add `FeedbackState` enum and `feedbackState` property to `Song.swift`**

In `Song.swift`, add after the `matchExplanation` property (around line 290) inside the `SimilarSong` struct:

```swift
    // Feedback state — session-only, not persisted to Supabase.
    // Set via engine.setFeedback(songID:state:) — never mutate directly (struct value copy).
    var feedbackState: FeedbackState? = nil
```

And add the enum BEFORE `SimilarSong` (after `Genre` at line 268):

```swift
// MARK: - FeedbackState
enum FeedbackState: String, Codable {
    case fits, close, miss
}
```

- [ ] **Step 2: Verify `SimilarSong` still synthesizes `Codable` correctly**

`FeedbackState: String, Codable` is a raw-value enum — it synthesizes `Codable` automatically. `SimilarSong` already conforms to `Codable` and has other optional properties with defaults, so adding `feedbackState: FeedbackState? = nil` will not break existing JSON decode/encode. No action needed.

- [ ] **Step 3: Add `setFeedback(songID:state:)` to `RecommendationEngine.swift`**

Find the end of the `reset()` function (around line 2484) and add before the closing `}` of the class:

```swift
    // ──────────────────────────────────────────────
    // MARK: - Feedback
    // ──────────────────────────────────────────────

    /// Updates the feedback state for a single recommendation.
    /// Uses index-based reassignment because SimilarSong is a struct — direct property
    /// mutation on an array element would create a copy and leave @Published unchanged.
    func setFeedback(songID: String, state: FeedbackState?) {
        guard let idx = recommendations.firstIndex(where: { $0.id == songID }) else { return }
        recommendations[idx].feedbackState = state
    }
```

- [ ] **Step 4: Build and confirm no compile errors**

Open Xcode (or use `xcodebuild`). Confirm the project builds clean. No new tests needed for this pure data model step — the interaction will be tested visually in Task 5.

- [ ] **Step 5: Commit**

```bash
git add "Simi/Simi/Models/Song.swift" "Simi/Simi/Services/RecommendationEngine.swift"
git commit -m "feat: add FeedbackState enum and setFeedback to recommendation engine"
```

---

### Task 2: prefetchCandidateFeatures + remove re-sorts

**Files:**
- Modify: `Simi/Services/RecommendationEngine.swift`
  - Add `prefetchCandidateFeatures()` (new private function)
  - Insert call in all three `findSimilarSongs` entry points
  - Remove `recommendations.sort` at line 1275 (Stage 1 sort after tag enrichment)
  - Remove `recommendations.sort` at line 1363 (Stage 2 sort after Railway librosa)

**Interfaces:**
- Consumes: `SimilarSong` array from `mergeAndScore()`, `computeSimilarity()`, `computeSimilarityMultiSeed()`, `estimateFeaturesFromTags()`, `buildMatchExplanation()`, `centroid(of:)` — all already on the engine
- Produces: enriched `[SimilarSong]` where every song has `audioFeatures`, `similarityScore`, `matchReasons`, `matchExplanation` populated before `isLoading = false`

- [ ] **Step 1: Add `prefetchCandidateFeatures()` to `RecommendationEngine.swift`**

Add this function after `mergeAndScore()` (after line 1508, before `applyArtistDiversity`):

```swift
    // ──────────────────────────────────────────────
    // MARK: - Pre-render Enrichment
    // ──────────────────────────────────────────────

    /// Enriches all candidates with Supabase cache + Last.fm tag estimation before first render.
    /// Runs as two racing tasks: the enrichment work vs. a 10-second timeout.
    /// Whichever finishes first wins — skeletons never persist past 10s.
    private func prefetchCandidateFeatures(
        candidates: [SimilarSong],
        sourceFeatures: AudioFeatures,
        genres: [Genre],
        seedFeatures: [AudioFeatures] = []
    ) async -> [SimilarSong] {
        guard !candidates.isEmpty else { return candidates }

        // Race: enrichment vs. 10s timeout. Returns unenriched candidates on timeout.
        return await withTaskGroup(of: [SimilarSong].self) { group in
            // Task A: do the actual enrichment
            group.addTask {
                await self.runPrefetchEnrichment(
                    candidates: candidates,
                    sourceFeatures: sourceFeatures,
                    genres: genres,
                    seedFeatures: seedFeatures
                )
            }
            // Task B: 10-second timeout fallback
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                simiLog("⚠️ prefetchCandidateFeatures timed out — revealing with best-effort features")
                return candidates
            }
            // First to finish wins; cancel the other
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func runPrefetchEnrichment(
        candidates: [SimilarSong],
        sourceFeatures: AudioFeatures,
        genres: [Genre],
        seedFeatures: [AudioFeatures]
    ) async -> [SimilarSong] {
        var result = candidates

        // Collect (index, features) for all candidates in parallel.
        // Priority 1: Supabase cache (instant, no rate-limit concern).
        // Priority 2: Last.fm tag estimation for cache misses (staggered 20ms, capped at index 15).
        let fetched: [(Int, AudioFeatures?)] = await withTaskGroup(of: (Int, AudioFeatures?).self) { group in
            for (index, song) in candidates.enumerated() {
                group.addTask {
                    if let cached = await self.supabase.lookupFeatures(title: song.title, artist: song.artist) {
                        return (index, cached)
                    }
                    // Stagger: indices 0–15 get 20ms delay each (max 300ms).
                    // Indices 16+ fire immediately — they don't wait longer.
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(min(index, 15)) * 20_000_000)
                    }
                    let tags = await self.lastFMService.fetchRawTags(title: song.title, artist: song.artist)
                    let estimated = await self.estimateFeaturesFromTags(tags)
                    return (index, estimated)
                }
            }
            var updates: [(Int, AudioFeatures?)] = []
            for await update in group { updates.append(update) }
            return updates
        }

        let explanationSource = seedFeatures.count > 1 ? centroid(of: seedFeatures) : sourceFeatures

        for (idx, features) in fetched {
            guard let features, idx < result.count else { continue }
            let (score, reasons) = seedFeatures.count > 1
                ? computeSimilarityMultiSeed(seeds: seedFeatures, target: features, genres: genres)
                : computeSimilarity(source: sourceFeatures, target: features, genres: genres)
            result[idx].audioFeatures    = features
            result[idx].similarityScore  = score
            result[idx].matchReasons     = reasons
            result[idx].matchExplanation = buildMatchExplanation(
                source: explanationSource,
                target: features,
                sourceGenres: genres,
                targetGenre: result[idx].genre
            )
        }

        return result.sorted { $0.similarityScore > $1.similarityScore }
    }
```

- [ ] **Step 2: Wire `prefetchCandidateFeatures()` into the URL-based entry point**

In `findSimilarSongs(for urlString:)`, find this block (around lines 325–344):

```swift
            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: expandedTracks,
                sourceSong: song,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prefetchedFeatures: [:]
            )

            guard !merged.isEmpty else {
                errorMessage = "Couldn't find similar songs for this track. Try searching by name instead."
                isLoading = false
                return
            }

            self.recommendations = merged
```

Replace with:

```swift
            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: expandedTracks,
                sourceSong: song,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prefetchedFeatures: [:]
            )

            guard !merged.isEmpty else {
                errorMessage = "Couldn't find similar songs for this track. Try searching by name instead."
                isLoading = false
                return
            }

            loadingMessage = "Almost ready…"
            let enriched = await prefetchCandidateFeatures(
                candidates: merged,
                sourceFeatures: sourceFeatures,
                genres: genres
            )
            self.recommendations = enriched
```

- [ ] **Step 3: Wire into the text-search entry point**

In `findSimilarSongs(title:artist:)`, find the equivalent block (around lines 510–525):

```swift
            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: expandedTracks,
                sourceSong: song,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prefetchedFeatures: [:]
            )

            guard !merged.isEmpty else {
                errorMessage = "Couldn't find similar songs for this track. Try a different song."
                isLoading = false
                return
            }

            self.recommendations = merged
```

Replace with:

```swift
            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs,
                lastFMTracks: expandedTracks,
                sourceSong: song,
                sourceFeatures: sourceFeatures,
                genres: genres,
                prefetchedFeatures: [:]
            )

            guard !merged.isEmpty else {
                errorMessage = "Couldn't find similar songs for this track. Try a different song."
                isLoading = false
                return
            }

            loadingMessage = "Almost ready…"
            let enriched = await prefetchCandidateFeatures(
                candidates: merged,
                sourceFeatures: sourceFeatures,
                genres: genres
            )
            self.recommendations = enriched
```

- [ ] **Step 4: Wire into the multi-seed entry point**

In `findSimilarSongs(seeds:)`, find the block (around lines 674–683):

```swift
            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs.filter { !seedIDSet.contains($0.id) },
                lastFMTracks: expandedTracks,
                sourceSong: resolvedSongs.first!,
                sourceFeatures: blended,
                genres: mergedGenres,
                excludeIDs: seedIDSet,
                seedFeatures: allFeatures
            )
            self.recommendations = merged
```

Replace with:

```swift
            let merged = try await mergeAndScore(
                spotifyRecs: spotifyRecs.filter { !seedIDSet.contains($0.id) },
                lastFMTracks: expandedTracks,
                sourceSong: resolvedSongs.first!,
                sourceFeatures: blended,
                genres: mergedGenres,
                excludeIDs: seedIDSet,
                seedFeatures: allFeatures
            )

            loadingMessage = "Almost ready…"
            let enriched = await prefetchCandidateFeatures(
                candidates: merged,
                sourceFeatures: blended,
                genres: mergedGenres,
                seedFeatures: allFeatures
            )
            self.recommendations = enriched
```

- [ ] **Step 5: Remove Stage 1 sort from `enrichWithABFeatures()`**

Find line 1274–1276 (the sort after tag enrichment):

```swift
        if enrichedCount > 0 {
            recommendations.sort { $0.similarityScore > $1.similarityScore }
        }
```

Replace with:

```swift
        if enrichedCount > 0 {
            simiLog("✅ Background tag enrichment updated \(enrichedCount) songs (positions frozen)")
        }
```

- [ ] **Step 6: Remove Stage 2 sort from `enrichWithABFeatures()`**

Find line 1361–1363 (the sort after Railway librosa succeeds):

```swift
        if librosaSucceeded > 0 {
            simiLog("✅ Librosa Stage 2 done: \(librosaSucceeded)/\(librosaTargets.count) songs upgraded")
            recommendations.sort { $0.similarityScore > $1.similarityScore }
        } else {
```

Replace with:

```swift
        if librosaSucceeded > 0 {
            simiLog("✅ Librosa Stage 2 done: \(librosaSucceeded)/\(librosaTargets.count) songs upgraded (positions frozen)")
        } else {
```

- [ ] **Step 7: Build and verify no compile errors**

Build the project. Watch the Xcode console: search for a song and confirm the log sequence shows "Almost ready…" before `isLoading = false`. Confirm there is NO `recommendations.sort` in `enrichWithABFeatures()` output after the first render.

- [ ] **Step 8: Manual smoke test — no re-sort**

Search for any song. Watch the results list. Confirm:
- Cards appear once (no second-render shuffle)
- The order after first reveal does not change, even after 15–40s

- [ ] **Step 9: Commit**

```bash
git add "Simi/Simi/Services/RecommendationEngine.swift"
git commit -m "feat: prefetch candidate features before first render, remove re-sort from enrichment"
```

---

### Task 3: Emotional Language for Estimated Songs

**Files:**
- Modify: `Simi/Services/RecommendationEngine.swift` — `buildMatchExplanation()` at line 1036

**Interfaces:**
- Consumes: `AudioFeatures.isEstimated: Bool` (already present on `AudioFeatures`)
- Produces: updated `MatchExplanation` rows with softer descriptors when either song is estimated

- [ ] **Step 1: Replace the valence row gate in `buildMatchExplanation()`**

Find lines 1047–1058 (the valence / emotional weight row):

```swift
        // Row 1: Emotional weight — valence (prefer DEAM-regressed value, consistent with computeSimilarity)
        let srcValence = source.valenceEssentia ?? source.valence
        let tgtValence = target.valenceEssentia ?? target.valence
        if !source.isEstimated && !target.isEstimated,
           abs(srcValence - tgtValence) < 0.20 {
            let avg = (srcValence + tgtValence) / 2
            let descriptor: String
            switch avg {
            case ..<0.35:        descriptor = "Same melancholic weight"
            case 0.35..<0.50:    descriptor = "Same bittersweet edge"
            case 0.50..<0.65:    descriptor = "Same balanced mood"
            default:             descriptor = "Same bright energy"
            }
            rows.append(MatchExplanationRow(label: "Emotional weight", descriptor: descriptor))
        }
```

Replace with:

```swift
        // Row 1: Emotional weight — valence (prefer DEAM-regressed value, consistent with computeSimilarity)
        // Gate: threshold unchanged (0.20), but isEstimated check removed — estimated songs show
        // softer descriptors instead of nothing.
        let srcValence = source.valenceEssentia ?? source.valence
        let tgtValence = target.valenceEssentia ?? target.valence
        let isEitherEstimated = source.isEstimated || target.isEstimated
        if abs(srcValence - tgtValence) < 0.20 {
            let avg = (srcValence + tgtValence) / 2
            let descriptor: String
            if isEitherEstimated {
                switch avg {
                case ..<0.35:        descriptor = "Similar emotional feel"
                case 0.35..<0.50:    descriptor = "Similar bittersweet range"
                case 0.50..<0.65:    descriptor = "Similar balanced mood"
                default:             descriptor = "Similar warmth"
                }
            } else {
                switch avg {
                case ..<0.35:        descriptor = "Same melancholic weight"
                case 0.35..<0.50:    descriptor = "Same bittersweet edge"
                case 0.50..<0.65:    descriptor = "Same balanced mood"
                default:             descriptor = "Same bright energy"
                }
            }
            rows.append(MatchExplanationRow(label: "Emotional weight", descriptor: descriptor))
        }
```

- [ ] **Step 2: Replace the energy row gate in `buildMatchExplanation()`**

Find lines 1061–1072 (the energy / intensity row):

```swift
        // Row 2: Intensity — energy
        if !source.isEstimated && !target.isEstimated,
           abs(source.energy - target.energy) < 0.20 {
            let avg = (source.energy + target.energy) / 2
            let descriptor: String
            switch avg {
            case ..<0.35:        descriptor = "Equally restrained"
            case 0.35..<0.55:    descriptor = "Equally measured"
            case 0.55..<0.75:    descriptor = "Equally driven"
            default:             descriptor = "Equally intense"
            }
            rows.append(MatchExplanationRow(label: "Intensity", descriptor: descriptor))
        }
```

Replace with:

```swift
        // Row 2: Intensity — energy
        // isEstimated check removed — softer descriptors for estimated songs.
        if abs(source.energy - target.energy) < 0.20 {
            let avg = (source.energy + target.energy) / 2
            let descriptor: String
            if isEitherEstimated {
                switch avg {
                case ..<0.35:        descriptor = "Roughly as restrained"
                case 0.35..<0.55:    descriptor = "Roughly as measured"
                case 0.55..<0.75:    descriptor = "Roughly as driven"
                default:             descriptor = "Roughly as intense"
                }
            } else {
                switch avg {
                case ..<0.35:        descriptor = "Equally restrained"
                case 0.35..<0.55:    descriptor = "Equally measured"
                case 0.55..<0.75:    descriptor = "Equally driven"
                default:             descriptor = "Equally intense"
                }
            }
            rows.append(MatchExplanationRow(label: "Intensity", descriptor: descriptor))
        }
```

Note: `isEitherEstimated` was declared in Row 1. If Row 1 code is added first this is already in scope. The Key (Row 3), Groove (Row 4), and Sonic texture (Row 5) rows are **unchanged** — their existing `isEstimated` / `isKeyEstimated` guards remain.

- [ ] **Step 3: Build and verify**

Build the project. Search for a song where `isEstimated == true` (any song that wasn't in Spotify audio features — most Last.fm candidates). Expand a result card and confirm the expanded detail shows "Similar emotional feel" / "Roughly as driven" style descriptors instead of the raw `AudioFeaturesGrid` percentages.

- [ ] **Step 4: Commit**

```bash
git add "Simi/Simi/Services/RecommendationEngine.swift"
git commit -m "feat: show softer emotional descriptors for estimated songs in match explanation"
```

---

### Task 4: SkeletonCard + Stagger Reveal in ResultsView

**Files:**
- Modify: `Simi/Views/ResultsView.swift`
  - Add `SkeletonCard` struct (after the existing `ResultsView` closing `}`)
  - Modify `listContent(proxy:)` to show skeletons while `engine.isLoading && engine.recommendations.isEmpty`
  - Add `@State private var cardAppeared: [Bool] = []` to `ResultsView`
  - Add `onChange(of: engine.recommendations.count)` to trigger stagger animation

**Interfaces:**
- Consumes: `engine.isLoading: Bool`, `engine.recommendations: [SimilarSong]`, `engine.sourceSong: Song?`
- Produces: skeleton cards shown while loading; stagger animation on first reveal

- [ ] **Step 1: Add `SkeletonCard` struct to `ResultsView.swift`**

After the closing `}` of the `ResultsView` struct (search for the struct following `SongCard` call — around line 1089 of the original file), add:

```swift
// ──────────────────────────────────────────────
// MARK: - SkeletonCard
// Pulsing placeholder shown while candidates are being fetched + enriched.
// Height mirrors SongCard: main row + platform row + FeedbackRow + chip row.
// ──────────────────────────────────────────────

struct SkeletonCard: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {

            // Main row — rank + art + title lines + score bar
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .frame(width: 20, height: 12)
                RoundedRectangle(cornerRadius: 10)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 4)
                        .frame(width: 100, height: 11)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4).frame(width: 48, height: 12)
                    RoundedRectangle(cornerRadius: 2).frame(width: 44, height: 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 4)

            // Platform links row — 4 icon placeholders
            HStack(spacing: 0) {
                Spacer().frame(width: 68)
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6)
                        .frame(width: 24, height: 24)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)

            // FeedbackRow skeleton — 3 pill placeholders (must match FeedbackRow height)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().frame(width: 52, height: 28)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // Match chip placeholder
            HStack(spacing: 6) {
                Capsule().frame(width: 80, height: 22)
                Capsule().frame(width: 64, height: 22)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .foregroundColor(Color.simiSurface)
        .background(Color.simiCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.simiBorder, lineWidth: 1))
        .opacity(pulse ? 0.55 : 0.30)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
```

- [ ] **Step 2: Add stagger state to `ResultsView`**

In `ResultsView`, add a state property after the existing `@State` declarations (around line 50):

```swift
    @State private var cardAppeared: [Bool] = []
```

- [ ] **Step 3: Add the stagger trigger to `ResultsView.body`**

In `ResultsView`, find where `scrollView` is returned in `body` (or the `ScrollView` block). Add an `onChange` modifier to trigger the stagger when recommendations first arrive. This goes on the outermost view in `body` (the `NavigationStack` or `ZStack`):

```swift
.onChange(of: engine.recommendations.count) { _, count in
    guard count > 0, cardAppeared.isEmpty else { return }
    cardAppeared = Array(repeating: false, count: count)
    for i in 0..<count {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                guard i < cardAppeared.count else { return }
                cardAppeared[i] = true
            }
        }
    }
}
```

Also add a reset when a new search starts (recommendations goes from non-empty back to empty):

```swift
.onChange(of: engine.isLoading) { _, loading in
    if loading { cardAppeared = [] }
}
```

- [ ] **Step 4: Update `listContent(proxy:)` to show skeletons and stagger cards**

Find `func listContent(proxy: ScrollViewProxy)` (around line 694). The `else` branch that currently renders cards:

```swift
        } else {
            VStack(spacing: 12) {
                Group { crossGenreBanner }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: crossGenreCount >= 2)
                ForEach(Array(displayedRecommendations.enumerated()), id: \.element.id) { index, song in
                    SongCard(song: song, rank: index + 1, sourceSong: engine.sourceSong)
                        .id(song.id)
                        .padding(.horizontal, 20)
                        .overlay(
                            // Highlight ring when jumped to from the graph
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.simiAccent, lineWidth: 2)
                                .padding(.horizontal, 20)
                                .opacity(highlightedSongID == song.id ? 1 : 0)
                                .animation(.easeInOut(duration: 0.4), value: highlightedSongID)
                                .allowsHitTesting(false)
                        )
                }
            }
            .padding(.bottom, 24)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: filterSameKey)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: breadthBucket)
        }
```

Replace the entire `func listContent(proxy:)` with:

```swift
    @ViewBuilder
    func listContent(proxy: ScrollViewProxy) -> some View {
        if engine.isLoading && engine.recommendations.isEmpty {
            // Skeleton cards while prefetchCandidateFeatures() runs
            VStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    SkeletonCard()
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 24)
        } else if displayedRecommendations.isEmpty && breadthBucket == 0 {
            closeMatchEmptyState
        } else if displayedRecommendations.isEmpty && breadthBucket == 2 {
            surpriseMeEmptyState
        } else if displayedRecommendations.isEmpty && filterSameKey {
            keyFilterEmptyState
        } else {
            VStack(spacing: 12) {
                Group { crossGenreBanner }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: crossGenreCount >= 2)
                ForEach(Array(displayedRecommendations.enumerated()), id: \.element.id) { index, song in
                    let appeared = cardAppeared.indices.contains(index) && cardAppeared[index]
                    SongCard(song: song, rank: index + 1, sourceSong: engine.sourceSong)
                        .id(song.id)
                        .padding(.horizontal, 20)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.simiAccent, lineWidth: 2)
                                .padding(.horizontal, 20)
                                .opacity(highlightedSongID == song.id ? 1 : 0)
                                .animation(.easeInOut(duration: 0.4), value: highlightedSongID)
                                .allowsHitTesting(false)
                        )
                }
            }
            .padding(.bottom, 24)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: filterSameKey)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: breadthBucket)
        }
    }
```

- [ ] **Step 5: Build and verify skeleton + stagger behavior**

Run the app. Search for a song. Confirm:
1. ResultsView opens immediately showing 4 pulsing skeleton cards
2. After 6–10s, skeleton cards disappear and result cards animate in one-by-one with ~80ms between each
3. Cards do not re-sort after reveal

- [ ] **Step 6: Commit**

```bash
git add "Simi/Simi/Views/ResultsView.swift"
git commit -m "feat: skeleton cards while loading, stagger reveal animation on first render"
```

---

### Task 5: FeedbackRow in SongCard

**Files:**
- Modify: `Simi/Views/SongCard.swift`
  - Add `@EnvironmentObject var engine: RecommendationEngine`
  - Add `FeedbackRow` struct (private sub-view)
  - Insert `FeedbackRow(song: song)` after the platform links row
  - Add teal 3px left border for `fits` state
  - Add 50% opacity for `miss` state

**Interfaces:**
- Consumes: `song.feedbackState: FeedbackState?` (from Task 1), `engine.setFeedback(songID:state:)` (from Task 1)
- Produces: visible pill UI for every card; feedback state persists until app foreground session ends

- [ ] **Step 1: Add `@EnvironmentObject var engine` to `SongCard`**

In `SongCard` (line 57–68), add the environment object property after the existing `let`/`@State` declarations:

```swift
    @EnvironmentObject private var engine: RecommendationEngine
```

- [ ] **Step 2: Add `FeedbackRow` struct at the bottom of `SongCard.swift`**

After the last struct in the file (below `WaveformBars` or `SimilarityBar`), add:

```swift
// ──────────────────────────────────────────────
// MARK: - FeedbackRow
// Three pill buttons: Fits / Close / Miss. Always visible below platform links.
// Tapping the active pill returns to neutral (toggles off).
// ──────────────────────────────────────────────

struct FeedbackRow: View {
    let song: SimilarSong
    @EnvironmentObject private var engine: RecommendationEngine

    private func pillColor(_ state: FeedbackState) -> Color {
        switch state {
        case .fits:  return .simiAccent
        case .close: return Color.orange
        case .miss:  return .simiSubtext
        }
    }

    private func pillLabel(_ state: FeedbackState) -> String {
        switch state {
        case .fits:  return song.feedbackState == .fits  ? "Fits ✓"  : "Fits"
        case .close: return song.feedbackState == .close ? "Close ~"  : "Close"
        case .miss:  return song.feedbackState == .miss  ? "Miss ✗"  : "Miss"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach([FeedbackState.fits, .close, .miss], id: \.self) { state in
                let isActive = song.feedbackState == state
                Button {
                    engine.setFeedback(songID: song.id, state: isActive ? nil : state)
                } label: {
                    Text(pillLabel(state))
                        .font(.simiMicro)
                        .foregroundColor(isActive ? .white : pillColor(state))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            isActive
                                ? pillColor(state)
                                : pillColor(state).opacity(0.08)
                        )
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(pillColor(state), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.15), value: song.feedbackState)
                .accessibilityLabel("Mark as \(state.rawValue)")
                .accessibilityValue(isActive ? "selected" : "")
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
```

- [ ] **Step 3: Insert `FeedbackRow` into `SongCard.body` after platform links**

In `SongCard.body`, find the platform links HStack's closing modifiers (around line 254):

```swift
            .padding(.horizontal, 14)
            .padding(.bottom, song.matchReasons.isEmpty && (song.matchExplanation?.genreBridgeLabel ?? "").isEmpty ? 6 : 0)

            // ── Match reason chips — full-width row so they never get squished ──
            if !song.matchReasons.isEmpty {
```

Replace the padding line and add FeedbackRow before the chips:

```swift
            .padding(.horizontal, 14)
            .padding(.bottom, 0)

            FeedbackRow(song: song)

            // ── Match reason chips — full-width row so they never get squished ──
            if !song.matchReasons.isEmpty {
```

- [ ] **Step 4: Add teal left-border for `fits` and 50% opacity for `miss`**

Find the modifiers at the end of `SongCard.body` (around lines 317–320):

```swift
        .background(Color.simiCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.simiBorder, lineWidth: 1))
```

Replace with:

```swift
        .opacity(song.feedbackState == .miss ? 0.5 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: song.feedbackState)
        .background(Color.simiCard)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.simiAccent)
                .frame(width: 3)
                .opacity(song.feedbackState == .fits ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: song.feedbackState)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.simiBorder, lineWidth: 1))
```

- [ ] **Step 5: Build and verify FeedbackRow behavior**

Run the app and search for a song. For each result card:
- Confirm three pill buttons appear below the platform links row
- Tap "Fits" → pill fills teal, a 3px teal bar appears on the card's left edge
- Tap "Fits" again → returns to neutral
- Tap "Close" → pill fills orange
- Tap "Miss" → pill fills muted, entire card body dims to ~50% opacity
- Confirm cards do NOT reorder when any feedback is tapped
- Expand a "miss" card — expanded section should also dim (it's inside the dimmed container)

- [ ] **Step 6: Commit**

```bash
git add "Simi/Simi/Views/SongCard.swift"
git commit -m "feat: FeedbackRow with Fits/Close/Miss pills, teal border for fits, dim for miss"
```

---

### Task 6: Source Card Early Reveal in HomeView

**Files:**
- Modify: `Simi/Views/HomeView.swift`
  - Change navigation trigger from `isLoading == false` to `sourceSong != nil`

**Interfaces:**
- Consumes: `engine.sourceSong: Song?` (becomes non-nil after URL resolve, before enrichment completes)
- Produces: navigation to ResultsView happens while loading — ResultsView's skeleton cards handle the in-progress state

- [ ] **Step 1: Replace the navigation trigger in `HomeView`**

Find lines 90–93 in `HomeView.body`:

```swift
            .onChange(of: engine.isLoading) { _, isLoading in
                if !isLoading && !engine.recommendations.isEmpty {
                    navigateToResults = true
                }
            }
```

Replace with:

```swift
            .onChange(of: engine.sourceSong) { _, song in
                if song != nil {
                    navigateToResults = true
                }
            }
```

The `navigateToResults` binding is set to `false` by SwiftUI automatically when the user pops back from ResultsView, so no manual reset is needed.

- [ ] **Step 2: Build and verify early navigation**

Run the app. Paste a Spotify URL and tap Find. Confirm:
1. The navigation to ResultsView begins as soon as the source song resolves (~1–2s), not at the end of enrichment
2. ResultsView immediately shows 4 skeleton cards (engine.isLoading is true, recommendations is empty)
3. After prefetch completes, skeleton cards animate out and result cards animate in with stagger

- [ ] **Step 3: Verify back-button behavior**

While results are loading (skeletons visible), press the back button. Confirm:
- Returns to HomeView
- `navigateToResults` resets to false (SwiftUI does this automatically)
- Can start a new search without issues

- [ ] **Step 4: Commit**

```bash
git add "Simi/Simi/Views/HomeView.swift"
git commit -m "feat: navigate to results as soon as source song resolves, show skeletons while loading"
```

---

## Self-Review Against Spec

**Spec coverage:**
- ✅ Section 1 (Loading & Enrichment Redesign): `prefetchCandidateFeatures()` added (Task 2), both sorts removed (Task 2), skeleton cards (Task 4), stagger animation (Task 4), source card early reveal (Task 6)
- ✅ Section 2 (Emotional Language for Estimated Songs): valence + energy rows loosened with two-tier descriptors (Task 3); key/groove/texture rows unchanged
- ✅ Section 3 (3-State Feedback Loop): `FeedbackState` enum + `feedbackState` property (Task 1), `setFeedback()` on engine (Task 1), `FeedbackRow` UI (Task 5), no re-sort on feedback (enforced by removing all sorts in Task 2)

**Constraint checks:**
- ✅ Struct mutation: `setFeedback()` uses `recommendations[idx].feedbackState = state` via `firstIndex`
- ✅ Skeleton height: includes FeedbackRow placeholder row
- ✅ 10s timeout: racing tasks pattern in `prefetchCandidateFeatures()`
- ✅ Last.fm stagger: `min(index, 15) * 20ms` in `runPrefetchEnrichment()`
- ✅ No re-sort: both Stage 1 and Stage 2 `.sort` calls removed

**No placeholders:** All steps contain actual code.
