# Genre Bridge Badge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a conditionally-rendered accent capsule row below match reason chips on each `SongCard`, showing the genre bridge label (e.g. "Jazz → Hip-Hop 🌉") when the seed and recommendation come from different genre families.

**Architecture:** Single addition to `SongCard.swift` — a conditional `if let bridge` block inserted between the match reasons section and the expanded detail section. Data is already available via `song.matchExplanation?.genreBridgeLabel` (populated by `buildMatchExplanation` at Stage 1 enrichment). No model changes, no new files.

**Tech Stack:** SwiftUI, iOS. All git commits go to the inner Xcode repo at `/Users/skips/Documents/Claude/Projects/Simi App/Simi/`.

## Global Constraints

- Only `Simi/Simi/Views/SongCard.swift` is modified — no other files
- Badge text format: `"\(bridge) 🌉"` — e.g. `"Jazz → Hip-Hop 🌉"`
- Visual style: `.simiMicro.weight(.semibold)` / `.simiAccent` / `.simiAccent.opacity(0.12)` background / `.clipShape(Capsule())`
- Own row, leading-aligned, below match reasons and above expanded detail
- Accessible: `.accessibilityElement(children: .combine)` + `.accessibilityLabel("Genre bridge: \(bridge)")`
- `AudioFeaturesGrid` is NOT modified or deleted
- `Song.swift` is NOT modified — data comes from `song.matchExplanation?.genreBridgeLabel`

---

### Task 1: Add genre bridge row to SongCard

**Files:**
- Modify: `Simi/Simi/Views/SongCard.swift` (after line 234, before the `// ── Expanded Detail ──` comment)

**Interfaces:**
- Consumes: `song.matchExplanation?.genreBridgeLabel: String?` — already present on `SimilarSong` via the `MatchExplanation` struct added in the Match Explanation Card feature

- [ ] **Step 1: Insert the genre bridge row**

Open `Simi/Simi/Views/SongCard.swift`. Find this block (ends around line 234):

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

            // ── Expanded Detail ──
```

Insert the genre bridge block between the closing `}` of the match reasons section and the `// ── Expanded Detail ──` comment:

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

            // ── Genre bridge ──
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

            // ── Expanded Detail ──
```

- [ ] **Step 2: Update the `#Preview` to show the badge**

In the same file, find the `#Preview` block near the bottom. The `sampleSong` currently has:

```swift
        matchExplanation: MatchExplanation(
            rows: [
                MatchExplanationRow(label: "Emotional weight", descriptor: "Same bright energy"),
                MatchExplanationRow(label: "Intensity",        descriptor: "Equally driven"),
                MatchExplanationRow(label: "Key",              descriptor: "Both major key"),
            ],
            genreBridgeLabel: nil
        )
```

Change `genreBridgeLabel: nil` to `genreBridgeLabel: "Pop → Jazz"`:

```swift
        matchExplanation: MatchExplanation(
            rows: [
                MatchExplanationRow(label: "Emotional weight", descriptor: "Same bright energy"),
                MatchExplanationRow(label: "Intensity",        descriptor: "Equally driven"),
                MatchExplanationRow(label: "Key",              descriptor: "Both major key"),
            ],
            genreBridgeLabel: "Pop → Jazz"
        )
```

- [ ] **Step 3: Build to verify no compiler errors**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi"
xcodebuild -project Simi.xcodeproj -scheme Simi \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  build 2>&1 | grep -E "error:|warning:|BUILD"
```

Expected: `BUILD SUCCEEDED` with no errors. Open the Xcode canvas on `SongCard.swift` — the preview should show `"Pop → Jazz 🌉"` as an accent capsule row beneath the match reason chips.

- [ ] **Step 4: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi"
git add "Simi/Views/SongCard.swift"
git commit -m "feat: add genre bridge badge row to SongCard"
```

---

## Self-Review

| Spec requirement | Covered by |
|------------------|------------|
| Own row below match reason chips | Task 1 Step 1 — inserted after closing `}` of match reasons block |
| Accent capsule pill style | Task 1 Step 1 — `.simiAccent` / `.simiAccent.opacity(0.12)` / `Capsule()` |
| Text format `"\(bridge) 🌉"` | Task 1 Step 1 — `Text("\(bridge) 🌉")` |
| Leading-aligned | Task 1 Step 1 — `HStack { ... Spacer() }` |
| Conditional on `genreBridgeLabel != nil` | Task 1 Step 1 — `if let bridge = song.matchExplanation?.genreBridgeLabel` |
| Accessible label | Task 1 Step 1 — `.accessibilityElement(children: .combine)` + `.accessibilityLabel("Genre bridge: \(bridge)")` |
| Preview shows badge | Task 1 Step 2 — `genreBridgeLabel: "Pop → Jazz"` |
| No `Song.swift` changes | Confirmed — not in any task |
| No `AudioFeaturesGrid` changes | Confirmed — not in any task |
