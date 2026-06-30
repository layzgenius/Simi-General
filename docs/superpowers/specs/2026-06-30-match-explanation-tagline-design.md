# Match Explanation Tagline — Design Spec

**Goal:** Surface the match explanation on the collapsed `SongCard` so users see Simi's core explainability advantage without tapping.

**Problem:** `MatchExplanationView`, `buildMatchExplanation()`, and the `MatchExplanation` structs are fully implemented. The emotional descriptors ("Same melancholic weight", "Equally restrained") appear in the expanded card state. But users browsing results see only abstract match reason chips ("genre", "bpm", "vibe") — the human-readable reasoning is invisible unless they tap each card individually. Simi's Blue Ocean position is "opacity is Spotify's problem; transparency is ours" — hiding the explanation contradicts this.

**Root cause:** `MatchExplanationView` is placed inside the `if isExpanded` block in `SongCard.swift`. Nothing in the collapsed card surfaces `matchExplanation.rows`.

**Solution:** Add a single tagline text line to the always-visible portion of `SongCard`, between the match reason chips and the genre bridge chip. Show top 1–2 descriptors; hide it when the card is expanded (the full table takes over).

---

## Architecture

Single file change: `Simi/Simi/Views/SongCard.swift`.

No model changes. No new files. No changes to `MatchExplanationView.swift`, `RecommendationEngine.swift`, or `Song.swift`.

---

## Component: Explanation Tagline

**Insertion point:** `SongCard.body`, between the match reason chips block (currently ends around line 279) and the genre bridge chip block (currently starts around line 282).

**Content:**
```swift
explanation.rows.prefix(2).map(\.descriptor).joined(separator: " · ")
```

Example output: `"Same melancholic weight · Equally restrained"`

**Visibility guard:** Only rendered when all three conditions are true:
1. `!isExpanded` — hidden when card is expanded (full table takes over)
2. `song.matchExplanation != nil` — no tagline when explanation was never computed
3. `!explanation.rows.isEmpty` — no tagline when no dimensions matched closely enough

**Style:**
- Font: `.simiMicro`
- Color: `.simiSubtext`
- `lineLimit(1)` with `minimumScaleFactor(0.85)` — long descriptors shrink slightly before truncating
- `frame(maxWidth: .infinity, alignment: .leading)` — left-aligned, full width
- `padding(.horizontal, 14)` — matches surrounding rows
- `padding(.bottom, 10)` — slightly tighter than the chip rows (12pt) since it's a text line
- `.transition(.opacity)` — fades out when user taps to expand
- `.accessibilityHidden(true)` — redundant with expanded view's accessibility labels; VoiceOver reads the full table when expanded

**Card anatomy after change (collapsed state):**
```
rank │ album art │ title / artist            │ similarity %
     │           │ [Spotify] [AM] [YT] [Share]│
     │           │ [Fits]  [Close]  [Miss]    │
genre • bpm                                        ← existing match reason chips
Same melancholic weight · Equally restrained       ← NEW tagline
Jazz → Hip-Hop 🌉                                  ← existing genre bridge chip (if present)
```

**Card anatomy after change (expanded state):**
```
rank │ album art │ title / artist            │ similarity %
     │           │ [Spotify] [AM] [YT] [Share]│
     │           │ [Fits]  [Close]  [Miss]    │
genre • bpm                                        ← existing chips
Jazz → Hip-Hop 🌉                                  ← existing genre bridge chip (if present)
──────────────────────────────────────────────
Why this matches
  Emotional weight   Same melancholic weight        ← existing MatchExplanationView (unchanged)
  Intensity          Equally restrained
  Key                Both minor key
  ...
```

Note: tagline is absent when expanded — no duplication with the full table.

---

## Edge Cases

| Condition | Behavior |
|-----------|----------|
| `matchExplanation` is nil (song not yet enriched) | No tagline rendered — no layout shift |
| `explanation.rows.isEmpty` (no dimensions close enough) | No tagline — `genreBridgeLabel` may still show as a chip |
| Exactly 1 row | Shows single descriptor: `"Same melancholic weight"` |
| 2+ rows | Shows first two: `"Same melancholic weight · Equally restrained"` |
| Very long descriptors | `minimumScaleFactor(0.85)` shrinks; `lineLimit(1)` truncates at edge |
| Tag-estimated songs (all descriptors are "Roughly as..." or "Similar...") | Tagline still shows — softer descriptors are still meaningful to users |
| Card is expanded | Tagline removed via `!isExpanded` guard; full `MatchExplanationView` shows instead |

---

## Constraints

- No changes to `MatchExplanationView.swift` — it renders correctly in the expanded state, unchanged
- No changes to `buildMatchExplanation()` in `RecommendationEngine.swift`
- No changes to `MatchExplanation` or `MatchExplanationRow` structs in `Song.swift`
- No changes to the genre bridge chip block — it stays as-is, after the new tagline
- The tagline is `accessibilityHidden(true)` — screen readers use the expanded view's labeled rows instead
- Build verification: `xcodebuild build` with 0 errors / 0 warnings (SourceKit false positives at lines 33–51 expected and ignorable)

---

## Files Changed

| File | Change |
|------|--------|
| `Simi/Simi/Views/SongCard.swift` | Add tagline block (~12 lines) between match reason chips and genre bridge chip |

---

## Success Criteria

1. Browsing results without tapping any card, the user sees at least 1 emotional descriptor beneath the match reason chips for any song that has `matchExplanation.rows` populated
2. When the card is expanded, the tagline is absent — the full `MatchExplanationView` table is the only explanation surface
3. Cards where `matchExplanation` is nil or has zero rows show no tagline and no empty gap
4. Build: 0 errors, 0 warnings
5. No regression: expanded state, genre bridge chip, match reason chips, and all platform link buttons are visually and functionally unchanged
