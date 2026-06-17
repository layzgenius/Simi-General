# Design Spec: Genre Bridge Badge
**Date:** 2026-06-17  
**Priority:** P0 (Blue Ocean Memo — Task 2)  
**Gaps addressed:** Gap 3 — Genre-locked discovery, Gap 8 — No sharable discovery moment  
**Effort:** Low (data already computed)

---

## Problem

Simi's biggest technical differentiator is cross-genre emotional matching — something Spotify's collaborative filtering cannot do structurally. But right now, a Jazz → Hip-Hop match looks identical to a Jazz → Jazz match on the results screen. The signal that makes the find remarkable is invisible.

---

## Goal

When a recommended song comes from a meaningfully different genre family than the seed, surface a visible badge on the collapsed song row. Make the cross-genre bridge the first thing a user sees, not something they have to tap to discover.

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Row placement | Own row below match reason chips | Genre bridge is a discovery insight, not a similarity metric — mixing it with "BPM" and "Vibe" flattens that distinction |
| Visual style | Accent capsule pill (same grammar as match reason chips) | Consistent with existing chip vocabulary; own row + accent color does enough to distinguish it categorically |
| Text | `"\(bridge) 🌉"` e.g. `"Jazz → Hip-Hop 🌉"` | Concrete, readable left-to-right, emoji provides quick scannability |
| Data source | `song.matchExplanation?.genreBridgeLabel` | Already computed in `buildMatchExplanation` — no new data work |
| When shown | Only when `genreBridgeLabel != nil` | No placeholder, no skeleton — honest UI only |
| Missing data | Row absent entirely | Avoids false signals for same-family or unknown-family matches |

---

## Architecture

### Modified files
- `Simi/Views/SongCard.swift` — add conditional genre bridge row between match reasons and expanded detail; update `#Preview` to show bridge

### What does NOT change
- `Song.swift` — `genreBridgeLabel` is already accessible via `song.matchExplanation?.genreBridgeLabel`
- `RecommendationEngine.swift` — `buildMatchExplanation` already populates `genreBridgeLabel`
- Supabase schema — purely display-layer change
- Backend / Railway — untouched

---

## View Design

**Card layout order (collapsed):**
1. Main row — rank, album art, title/artist, similarity %, platform links
2. Match reason chips — `"BPM"`, `"Vibe"`, etc. (existing, unchanged)
3. Genre bridge row — conditional, own row (new)
4. Expanded detail — `MatchExplanationView` or `AudioFeaturesGrid` (existing, unchanged)

**Genre bridge row:**
```swift
if let bridge = song.matchExplanation?.genreBridgeLabel {
    HStack {
        Text("\(bridge) 🌉")
            .font(.simiMicro.weight(.semibold))
            .foregroundColor(.simiAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.simiAccent.opacity(0.12))
            .clipShape(Capsule())
        Spacer()
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
    .transition(.opacity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Genre bridge: \(bridge)")
}
```

### Timing

`genreBridgeLabel` is populated as part of `matchExplanation`, which is set during Stage 1 enrichment (~5s after initial display). The badge appears at the same time as match reason chips — both arrive with the first enrichment pass. No badge is shown until there is something honest to show.

---

## Execution scope

Pure SwiftUI display-layer change. No backend changes, no model changes, no new files.

**Files to modify:** 1 (`SongCard.swift`)
