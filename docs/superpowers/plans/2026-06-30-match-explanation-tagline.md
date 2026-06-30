# Match Explanation Tagline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-line tagline of emotional descriptors to the collapsed `SongCard` so users see why a track matched without tapping.

**Architecture:** Insert ~14 lines of SwiftUI directly above the genre bridge chip block in `SongCard.body`. The block reads `song.matchExplanation.rows`, joins the first two descriptors with `" · "`, and renders them in `.simiSubtext` color. It is hidden when the card is expanded so it doesn't duplicate the full `MatchExplanationView` table. No new types, no new files, no engine changes.

**Tech Stack:** Swift 5, SwiftUI, `xcodebuild` for build verification (no XCTest target — build success is the primary verification gate)

## Global Constraints

- Modify `Simi/Simi/Views/SongCard.swift` only — no changes to `MatchExplanationView.swift`, `RecommendationEngine.swift`, `Song.swift`, or any service file
- No new files created
- No changes to `MatchExplanation` / `MatchExplanationRow` structs
- No changes to the genre bridge chip block — it stays exactly as-is
- SourceKit false positives at lines 33–51 of `RecommendationEngine.swift` are unrelated and ignorable
- All commits go in the inner Swift repo at `Simi/` (not the outer docs repo at `Simi App/`)
- Build command: `cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && xcodebuild build -project Simi.xcodeproj -scheme Simi -destination 'platform=iOS Simulator,name=iPhone 17e' 2>&1 | tail -5`
- Expected build output: `** BUILD SUCCEEDED **`

---

### Task 1: Insert the Explanation Tagline

**Files:**
- Modify: `Simi/Simi/Views/SongCard.swift` at lines 280–281 (insertion point)

**Interfaces:**
- Consumes: `song.matchExplanation: MatchExplanation?` — optional, already on `SimilarSong`
- Consumes: `matchExplanation.rows: [MatchExplanationRow]` — each has `.descriptor: String`
- Consumes: `isExpanded: Bool` — `@State` property already in `SongCard`
- Produces: nothing for downstream — self-contained view-only change

- [ ] **Step 1: Read lines 261–300 to confirm starting state**

Read `Simi/Simi/Views/SongCard.swift` lines 261–300. You must see this structure:

```swift
            // ── Match reason chips — full-width row so they never get squished ──
            if !song.matchReasons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(song.matchReasons.prefix(2), id: \.rawValue) { reason in
                        Text(reason.rawValue)
                            ...
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                ...
            }

            // ── Genre bridge ──
            if let bridge = song.matchExplanation?.genreBridgeLabel, !bridge.isEmpty {
```

Confirm the `// ── Genre bridge ──` comment is directly after the match reason chips closing `}`. If the structure differs, stop and report before making any change.

- [ ] **Step 2: Insert the tagline block above the genre bridge comment**

Insert the following block between the closing `}` of the match reason chips section and the `// ── Genre bridge ──` comment. The result should read:

```swift
            // ── Match reason chips — full-width row so they never get squished ──
            if !song.matchReasons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(song.matchReasons.prefix(2), id: \.rawValue) { reason in
                        Text(reason.rawValue)
                            .font(.simiMicro)
                            .lineLimit(1)
                            .foregroundColor(.simiAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.simiAccent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }

            // ── Match explanation tagline (collapsed-only teaser) ──
            if !isExpanded,
               let explanation = song.matchExplanation,
               !explanation.rows.isEmpty {
                Text(explanation.rows.prefix(2).map(\.descriptor).joined(separator: " · "))
                    .font(.simiMicro)
                    .foregroundColor(.simiSubtext)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }

            // ── Genre bridge ──
            if let bridge = song.matchExplanation?.genreBridgeLabel, !bridge.isEmpty {
```

The exact text to replace is the blank line + `// ── Genre bridge ──` comment that currently sits at line 280–281. Replace those two lines with the new tagline block followed by a blank line and then `// ── Genre bridge ──`.

Use the Edit tool with `old_string`:
```
            // ── Genre bridge ──
```
and `new_string`:
```
            // ── Match explanation tagline (collapsed-only teaser) ──
            if !isExpanded,
               let explanation = song.matchExplanation,
               !explanation.rows.isEmpty {
                Text(explanation.rows.prefix(2).map(\.descriptor).joined(separator: " · "))
                    .font(.simiMicro)
                    .foregroundColor(.simiSubtext)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }

            // ── Genre bridge ──
```

- [ ] **Step 3: Build and verify**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && xcodebuild build -project Simi.xcodeproj -scheme Simi -destination 'platform=iOS Simulator,name=iPhone 17e' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

Any error other than SourceKit false positives (which say "Cannot find type X in scope" and appear only in `RecommendationEngine.swift`) is real — fix before proceeding.

- [ ] **Step 4: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi" && git add Simi/Views/SongCard.swift && git commit -m "feat: surface match explanation tagline on collapsed SongCard

Emotional descriptors (e.g. 'Same melancholic weight · Equally restrained')
now appear below the match reason chips on the collapsed card without
requiring the user to tap. Tagline is hidden when expanded — the full
MatchExplanationView table takes over. Cards with no explanation rows
show no tagline and no layout shift."
```
