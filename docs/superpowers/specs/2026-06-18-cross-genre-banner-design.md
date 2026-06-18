# Design Spec: Cross-Genre Banner
**Date:** 2026-06-18
**Priority:** P1 (Blue Ocean Memo — Task 6)
**Gaps addressed:** Gap 3 — Genre-locked discovery (completes the cross-genre story)
**Effort:** Low (data already computed, single view addition)

---

## Problem

Tasks 1 and 2 (Match Explanation Card, Genre Bridge Badge) make cross-genre matches visible *per song*. But a user scanning 15 results doesn't see the pattern: "this set of results is special because it crossed genre lines at all." The individual badges are easy to miss when scrolling. A banner at the top of the list frames the entire result set and gives the user a reason to look more carefully.

---

## Goal

When ≥2 results in the current list have a genre bridge (i.e., `matchExplanation?.genreBridgeLabel` is non-nil and non-empty), show a single contextual banner at the top of the song list. The banner communicates the pattern, not each individual instance.

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Threshold | ≥2 results | 1 cross-genre match could be noise; 2+ signals Simi found a pattern worth surfacing |
| Placement | Top of list, above song cards | Frames the whole result set before the user scrolls |
| Data source | `engine.recommendations` (full list, not filtered/adjusted) | The banner is about the discovery, not the current filter state |
| Copy — primary | `"\(count) genre-crossing matches"` | Concrete count, clear meaning |
| Copy — secondary | `"Same feeling, different world"` | Positions the cross-genre find as a feature, not a coincidence |
| Dismiss | No | It's a fact about the result set, not a notification — no close button |
| View mode | List only | Banner is scoped to `listContent` — graph mode has its own visual language |
| Animation | `.transition(.opacity)` + `easeInOut(0.3)` | Matches how match reason chips appear; smooth, not jarring |
| Style | Accent-tinted card (`simiAccent.opacity(0.08)` bg, `simiAccent.opacity(0.25)` border) | Consistent with genre bridge badge and MatchExplanationView accent grammar |

---

## Architecture

### Modified files
- `Simi/Views/ResultsView.swift` — add `crossGenreCount` computed property, `crossGenreBanner` view builder, `CrossGenreBannerView` struct; wire banner into `listContent`

### What does NOT change
- `RecommendationEngine.swift` — no new data needed
- `Song.swift` — data comes from `song.matchExplanation?.genreBridgeLabel` already
- Any other file — purely display-layer change

---

## View Design

**Placement in list layout:**
1. Source Song Header / Blend Song Header (existing)
2. View Mode Toggle (existing)
3. Filter Bar (existing, conditional)
4. Mood Shift Sliders (existing)
5. **Cross-Genre Banner** ← new, conditional (≥2 bridges)
6. Song Cards (existing)
7. Attribution Footer (existing)

**Banner view:**
```swift
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

**Wiring in ResultsView:**
```swift
// Computed property on ResultsView
private var crossGenreCount: Int {
    engine.recommendations.filter {
        guard let label = $0.matchExplanation?.genreBridgeLabel else { return false }
        return !label.isEmpty
    }.count
}

// View builder on ResultsView
@ViewBuilder
private var crossGenreBanner: some View {
    if crossGenreCount >= 2 {
        CrossGenreBannerView(count: crossGenreCount)
            .padding(.horizontal, 20)
            .transition(.opacity)
    }
}

// In listContent(proxy:), inserted above the ForEach inside the else-branch VStack:
VStack(spacing: 12) {
    crossGenreBanner
    ForEach(Array(displayedRecommendations.enumerated()), id: \.element.id) { ... }
}
.padding(.bottom, 24)
.animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: filterSameKey)
.animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: crossGenreCount)
```

### Timing

`genreBridgeLabel` arrives with Stage 1 enrichment (~5s after initial display). Until then, `crossGenreCount` is 0 and the banner is absent. When the count crosses 2, the banner fades in via `.transition(.opacity)` driven by the `.animation(value: crossGenreCount)` on the VStack. No skeleton, no placeholder — honest UI only.

---

## Execution scope

Pure SwiftUI display-layer change. No backend, no model, no new files.

**Files to modify:** 1 (`ResultsView.swift`)
