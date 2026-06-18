# Cross-Genre Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a conditional banner at the top of the results list that shows "N genre-crossing matches 🌉" when ≥2 recommendations have a genre bridge label.

**Architecture:** Single addition to `ResultsView.swift` — a `crossGenreCount` computed property, a `crossGenreBanner` view builder, and a `CrossGenreBannerView` struct, wired into the existing `listContent(proxy:)` method. Data already available via `song.matchExplanation?.genreBridgeLabel`; no model changes.

**Tech Stack:** SwiftUI, iOS. All git commits go to the inner Xcode repo at `/Users/skips/Documents/Claude/Projects/Simi App/Simi/`.

## Global Constraints

- Only `Simi/Simi/Views/ResultsView.swift` is modified — no other files
- Threshold: banner appears when `crossGenreCount >= 2` (count of recommendations where `genreBridgeLabel` is non-nil AND non-empty)
- Data source: `engine.recommendations` (full list — not `displayedRecommendations` which is filtered/adjusted)
- Placement: top of `listContent`, above the song cards `ForEach`, below the mood slider panel
- List mode only: banner is inside `listContent(proxy:)` — not shown in graph mode
- Copy: primary `"\(count) genre-crossing matches"`, secondary `"Same feeling, different world"`
- Style: `simiAccent.opacity(0.08)` background, `simiAccent.opacity(0.25)` border, `RoundedRectangle(cornerRadius: 14)`
- Animation: `.transition(.opacity)` + `.animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: crossGenreCount)` on the containing VStack
- No dismiss button — banner is a fact about the result set, not a notification
- Accessible: `.accessibilityElement(children: .combine)` + `.accessibilityLabel("\(count) genre-crossing matches. Same feeling, different world.")`
- SourceKit IDE errors ("Cannot find type X in scope") are always indexing lag — `xcodebuild BUILD SUCCEEDED` is authoritative

---

### Task 1: Add cross-genre banner to ResultsView

**Files:**
- Modify: `Simi/Simi/Views/ResultsView.swift`
  - Add `crossGenreCount` computed property (~line 91, after `sourceKeyName`)
  - Add `crossGenreBanner` view builder (after `crossGenreCount`)
  - Wire `crossGenreBanner` into `listContent(proxy:)` (inside the else-branch VStack, before `ForEach`)
  - Add second `.animation` modifier to the VStack in `listContent`
  - Add `CrossGenreBannerView` struct (after the `FilterChip` struct, before `#Preview`)

**Interfaces:**
- Consumes: `engine.recommendations: [SimilarSong]` (already `@EnvironmentObject` on `ResultsView`)
- Consumes: `song.matchExplanation?.genreBridgeLabel: String?` on each `SimilarSong`
- Consumes: `reduceMotion: Bool` (already `@Environment` on `ResultsView`)

- [ ] **Step 1: Add `crossGenreCount` computed property to `ResultsView`**

Open `Simi/Simi/Views/ResultsView.swift`. Find this block (around line 55–57):

```swift
    private var sourceKeyName: String {
        engine.sourceSong?.audioFeatures?.keyName ?? "?"
    }
```

Insert immediately after the closing `}`:

```swift
    private var crossGenreCount: Int {
        engine.recommendations.filter {
            guard let label = $0.matchExplanation?.genreBridgeLabel else { return false }
            return !label.isEmpty
        }.count
    }
```

- [ ] **Step 2: Add `crossGenreBanner` view builder to `ResultsView`**

In the same file, find the `// ── Re-ranked recommendations based on slider proximity.` comment block (around line 59). Insert the `crossGenreBanner` property immediately after `crossGenreCount` (still before the slider proximity code):

```swift
    @ViewBuilder
    private var crossGenreBanner: some View {
        if crossGenreCount >= 2 {
            CrossGenreBannerView(count: crossGenreCount)
                .padding(.horizontal, 20)
                .transition(.opacity)
        }
    }
```

- [ ] **Step 3: Wire the banner into `listContent(proxy:)` and add animation**

Find the `listContent(proxy:)` method. Its `else` branch currently reads:

```swift
        } else {
            VStack(spacing: 12) {
                ForEach(Array(displayedRecommendations.enumerated()), id: \.element.id) { index, song in
                    SongCard(song: song, rank: index + 1)
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
        }
```

Replace it with (adds `crossGenreBanner` at the top of the VStack and a second `.animation` modifier):

```swift
        } else {
            VStack(spacing: 12) {
                crossGenreBanner
                ForEach(Array(displayedRecommendations.enumerated()), id: \.element.id) { index, song in
                    SongCard(song: song, rank: index + 1)
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: crossGenreCount)
        }
```

- [ ] **Step 4: Add `CrossGenreBannerView` struct**

Find the `// ── Filter Chip` comment block (around line 732). Insert the new struct immediately before it (after `// ── Badge` struct):

```swift
// ──────────────────────────────────────────────
// MARK: - Cross-Genre Banner
// Shown at the top of the list when ≥2 results cross genre families.
// ──────────────────────────────────────────────

struct CrossGenreBannerView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("🌉")
                .font(.system(size: 22))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) genre-crossing matches")
                    .font(.simiBody.weight(.semibold))
                    .foregroundColor(.simiText)
                Text("Same feeling, different world")
                    .font(.simiCaption)
                    .foregroundColor(.simiSubtext)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.simiAccent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.simiAccent.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) genre-crossing matches. Same feeling, different world.")
    }
}
```

- [ ] **Step 5: Build to verify no compiler errors**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi"
xcodebuild -project Simi.xcodeproj -scheme Simi \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  build 2>&1 | grep -E "error:|warning:|BUILD"
```

Expected: `BUILD SUCCEEDED` with no errors. (SourceKit IDE warnings in Xcode are indexing lag — ignore them; only `xcodebuild` output is authoritative.)

- [ ] **Step 6: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi"
git add "Simi/Views/ResultsView.swift"
git commit -m "feat: add cross-genre banner to results list"
```

---

## Self-Review

| Spec requirement | Covered by |
|------------------|------------|
| Banner when ≥2 bridges | Task 1 Step 3 — `if crossGenreCount >= 2` |
| Data from `engine.recommendations` (not filtered) | Task 1 Step 1 — `crossGenreCount` reads `engine.recommendations` |
| Primary copy `"\(count) genre-crossing matches"` | Task 1 Step 4 — `CrossGenreBannerView` |
| Secondary copy `"Same feeling, different world"` | Task 1 Step 4 — `CrossGenreBannerView` |
| Accent-tinted style | Task 1 Step 4 — `simiAccent.opacity(0.08)` bg, `simiAccent.opacity(0.25)` border |
| List mode only | Task 1 Step 3 — inside `listContent(proxy:)` |
| Placement above song cards | Task 1 Step 3 — `crossGenreBanner` before `ForEach` |
| `.transition(.opacity)` | Task 1 Step 2 — on `CrossGenreBannerView` in view builder |
| `.animation(value: crossGenreCount)` | Task 1 Step 3 — second `.animation` on the VStack |
| No dismiss button | Task 1 Step 4 — `CrossGenreBannerView` has no close button |
| Accessible | Task 1 Step 4 — `.accessibilityElement(children: .combine)` + `.accessibilityLabel` |
| No other files modified | Confirmed — only `ResultsView.swift` |
