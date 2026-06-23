# Cold Start Onboarding
**Date:** 2026-06-23
**Scope:** First-launch walkthrough + guided search for new users with no history.

---

## Overview

Simi currently has no onboarding. New users land on `HomeView` cold — no context, no guidance, empty history. This spec adds two interlocking pieces:

1. **Walkthrough** — a 3-card swipeable carousel shown once on first launch, explaining what Simi is and how it works before the user touches the search field
2. **Guided First Search** — example song chips + cycling placeholder text on `HomeView` that persists beyond first launch, making the input immediately legible to any new user

These are complementary, not redundant: the walkthrough provides the *why*, the guided search provides the *how*.

---

## Section 1: Architecture

### Approach
`SimiApp.swift` owns the onboarding gate. An `@AppStorage("hasSeenOnboarding")` bool (default `false`) controls whether `OnboardingView` overlays `HomeView`. When the user finishes or skips, the flag flips to `true` and the overlay fades out permanently.

### Why this approach
- `OnboardingView` is fully self-contained — it takes an `onDismiss: () -> Void` closure and knows nothing about `HomeView`
- `HomeView` stays clean — no onboarding state leaks in
- Standard iOS one-time overlay pattern; easy to test independently

### Files Changed

| File | Change |
|------|--------|
| `Simi/SimiApp.swift` | Add `@AppStorage("hasSeenOnboarding")`, wrap `HomeView` in ZStack with `OnboardingView` overlay |
| `Simi/Views/OnboardingView.swift` | New file — 3-card TabView carousel, skip button, CTA |
| `Simi/Views/HomeView.swift` | Add example chips row + cycling placeholder text |

---

## Section 2: OnboardingView

### Structure
- Full-screen `Color.simiBackground.ignoresSafeArea()` background — matches app dark theme
- `TabView(selection:)` with `.tabViewStyle(.page(indexDisplayMode: .always))` — native swipe, page dots
- 3 `OnboardingCard` views inside the TabView
- "Skip" button: top-right, `.simiSubtext` color, calls `onDismiss()` on any card
- Page dots visible on Cards 1–2; hidden on Card 3 (replaced by CTA button)
- "Start Discovering →" button on Card 3 only: filled teal, calls `onDismiss()`
- Entrance animation: `.transition(.opacity)` with `withAnimation(.easeInOut(duration: 0.3))` on the ZStack overlay
- `accessibilityReduceMotion` respected — animation skipped when enabled

### `OnboardingCard` subview
Each card is a `VStack(spacing: 24)` centered vertically:
- Visual element (top)
- Headline: `.simiTitle` font weight, white
- Subtext: `.simiBody`, `.simiSubtext` color, multiline, center-aligned, max width 300pt

### Card Content

**Card 1 — Emotional hook**
- Visual: Large gradient "simi" wordmark (same as `HomeView` `logoSection`)
- Headline: "Music has a feeling."
- Subtext: "Not a genre. Not an algorithm. A feeling. Simi finds songs that share the same emotional weight as the one you love."

**Card 2 — How it works**
- Visual: Static mockup of the URL input field with a Spotify link pasted in — a `RoundedRectangle` card showing `"open.spotify.com/track/…"` in `.simiSubtext`, matching the real input's styling
- Headline: "Paste a song. That's it."
- Subtext: "Drop any Spotify, Apple Music, or YouTube link. Simi analyzes the emotional fingerprint — energy, mood, texture — and finds its musical kin across every genre."

**Card 3 — What you get**
- Visual: Static mockup of 2 result cards with match explanation chips (e.g. "Same melancholic weight", "Equally restrained") — simplified `VStack` using the app's card background color and `.simiMicro` font chips
- Headline: "Discovery that feels right."
- Subtext: "Every result shows you *why* it matches — same melancholic weight, same restrained energy, same bittersweet edge. No black box."

### Dismissal
`onDismiss()` is called by both Skip and the Card 3 CTA. In `SimiApp`, this sets `hasSeenOnboarding = true`, which removes the ZStack overlay. The `OnboardingView` is never shown again.

---

## Section 3: HomeView Guided Search

### Example Chips Row

**Placement:** Between `modePicker` and the URL/text input section.

**Label:** `Text("Try one of these →")` in `.simiMicro` font, `.simiSubtext` color, left-aligned.

**Chips:** Horizontal `ScrollView(.horizontal, showsIndicators: false)` containing an `HStack(spacing: 8)` of tappable pill buttons.

**Five example songs:**

| Display label | Spotify URL (URL mode auto-fill) | Title / Artist (text mode auto-fill) |
|--------------|----------------------------------|--------------------------------------|
| Creep — Radiohead | `https://open.spotify.com/track/70LcF31zb1H0PyJoS1Sx1r` | "Creep" / "Radiohead" |
| Blinding Lights — The Weeknd | `https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b` | "Blinding Lights" / "The Weeknd" |
| Clair de Lune — Debussy | `https://open.spotify.com/track/3dkGuBqchfMzRxNM2mVmNm` | "Clair de Lune" / "Debussy" |
| Redbone — Childish Gambino | `https://open.spotify.com/track/0wXuerDYiBnERgIpbb3JBR` | "Redbone" / "Childish Gambino" |
| Motion Picture Soundtrack — Radiohead | `https://open.spotify.com/track/1yrwQoPuqxONQ7E5hFEDml` | "Motion Picture Soundtrack" / "Radiohead" |

**Chip tap behavior:**
- URL mode: fills `pastedURLs[0]` with the Spotify URL and immediately calls `startSearch()` (same as tapping Find)
- Text mode: fills `seeds[0].title` and `seeds[0].artist`, focuses the title field — does NOT auto-trigger search, letting the user confirm first

**Chip appearance:** `.simiMicro` font, `.simiAccent` teal text, 1pt teal border, transparent background, padding `6×12`, `Capsule` shape — matches `FeedbackRow` pill style for visual consistency.

### Cycling Placeholder Text

**URL input field only.** The `TextField` placeholder cycles through 3 strings every 3 seconds:
1. `"Paste a Spotify, Apple Music, or YouTube link…"`
2. `"Try: open.spotify.com/track/…"`
3. `"Any song link works — we'll handle the rest"`

**Timer behavior:**
- Starts when the field is empty and not focused
- Pauses (stays on current string) when the field is focused or non-empty
- Resets to index 0 when the field is cleared

**Implementation:** `@State private var placeholderIndex = 0` + a `Timer.publish(every: 3, on: .main, in: .common)` attached with `.onReceive`. The timer publisher is only active when `pastedURLs[0].isEmpty && !urlFieldFocused`.

**Text mode fields:** Static placeholders only:
- Title field: `"e.g. Clair de Lune"`
- Artist field: `"e.g. Debussy"`

---

## Success Criteria

1. A new user (no history, first launch) sees the walkthrough carousel before the search screen
2. Skip button works on any card; "Start Discovering →" works on Card 3
3. Walkthrough never appears again after first dismissal
4. Example chips auto-fill correctly in both URL mode (triggers search) and text mode (fills fields only)
5. Cycling placeholder cycles on a 3-second timer, pauses when focused or non-empty, resets on clear
6. `accessibilityReduceMotion` suppresses the overlay entrance animation
7. No visual regression on `HomeView` for returning users (walkthrough gone, chips still present)
