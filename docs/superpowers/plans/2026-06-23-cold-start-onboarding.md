# Cold Start Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a one-time 3-card onboarding carousel shown on first launch, plus persistent example song chips and cycling placeholder text to guide new users into their first search.

**Architecture:** `SimiApp.swift` owns the `@AppStorage("hasSeenOnboarding")` gate and renders `OnboardingView` as a ZStack overlay on top of `HomeView`. `OnboardingView` is self-contained and calls `onDismiss()` on skip or completion, which flips the flag and auto-focuses the URL input. `HomeView` gains a chips row and cycling placeholder that persist for all users.

**Tech Stack:** SwiftUI, `@AppStorage`, `@FocusState`, `@Binding`, `TabView` with `.page` style, `Timer.publish`

## Global Constraints

- `OnboardingView` must not import or reference `HomeView` — it only calls the `onDismiss: () -> Void` closure
- Page dots use `.tabViewStyle(.page(indexDisplayMode: selectedPage == 2 ? .never : .always))` — dynamic, not `.always`
- Card 2 URL mockup must be a decorative `RoundedRectangle`, NOT a `TextField` — non-interactive and non-focusable
- Timer always runs with `.autoconnect()`; guard inside `.onReceive` skips increment (never conditionally connect/disconnect)
- Chips are `.disabled(engine.isLoading)` — disabled during active search
- `accessibilityReduceMotion` suppresses the ZStack overlay entrance animation
- Onboarding shown exactly once — `@AppStorage("hasSeenOnboarding")` gate, never reset
- Auto-focus URL field after dismissal via 0.35s delay using `@FocusState` + `@Binding` trigger chain
- All Swift files commit to the inner repo at `Simi/` (not the outer `Simi App/` repo)

---

### Task 1: OnboardingView + SimiApp gate

**Files:**
- Create: `Simi/Simi/Views/OnboardingView.swift`
- Modify: `Simi/Simi/SimiApp.swift`

**Interfaces:**
- Produces: `OnboardingView(onDismiss: () -> Void)` — called by `SimiApp`
- Produces: `SimiApp` passes `shouldFocusURL: $shouldFocusURLField` binding into `HomeView` — Task 2 consumes this

**Context:** The app currently launches straight into `HomeView` with no first-run check. `SimiApp.swift` is at `Simi/Simi/SimiApp.swift`. `HomeView.swift` is at `Simi/Simi/Views/HomeView.swift`. The design system has `Color.simiBackground`, `Color.simiAccent`, `Color.simiSubtext`, `Color.simiCard`, `Font.simiDisplay`, `Font.simiTitle`, `Font.simiBody`, `Font.simiMicro`, `Font.simiCaption`, `LinearGradient.simiBrand`. All are defined in `Simi/Simi/Theme.swift`.

- [ ] **Step 1: Create `OnboardingView.swift` with full structure**

Create `Simi/Simi/Views/OnboardingView.swift` with this complete implementation:

```swift
// OnboardingView.swift
// Simi — Music Discovery App
//
// Shown once on first launch. Self-contained — knows nothing about HomeView.
// Calls onDismiss() on skip or CTA tap; SimiApp sets hasSeenOnboarding = true.

import SwiftUI

struct OnboardingView: View {
    let onDismiss: () -> Void

    @State private var selectedPage = 0
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.simiBackground.ignoresSafeArea()

            TabView(selection: $selectedPage) {
                OnboardingCard(
                    visual: AnyView(simiWordmark),
                    headline: "Music has a feeling.",
                    subtext: "Not a genre. Not an algorithm. A feeling. Simi finds songs that share the same emotional weight as the one you love."
                )
                .tag(0)

                OnboardingCard(
                    visual: AnyView(urlMockup),
                    headline: "Paste a song. That's it.",
                    subtext: "Drop any Spotify, Apple Music, or YouTube link. Simi analyzes the emotional fingerprint — energy, mood, texture — and finds its musical kin across every genre."
                )
                .tag(1)

                OnboardingCard(
                    visual: AnyView(resultsMockup),
                    headline: "Discovery that feels right.",
                    subtext: "Every result shows you why it matches — same melancholic weight, same restrained energy, same bittersweet edge. No black box.",
                    showCTA: true,
                    onCTA: onDismiss
                )
                .tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: selectedPage == 2 ? .never : .always))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: selectedPage)

            // Skip button — visible on all cards
            Button(action: onDismiss) {
                Text("Skip")
                    .font(.simiBody.weight(.medium))
                    .foregroundColor(.simiSubtext)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .accessibilityLabel("Skip onboarding")
        }
    }

    // MARK: - Visuals

    private var simiWordmark: some View {
        Text("simi")
            .font(.simiDisplay)
            .foregroundStyle(LinearGradient.simiBrand)
            .accessibilityLabel("Simi")
    }

    // Decorative, non-interactive mockup of the URL input field
    private var urlMockup: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .foregroundColor(.simiSubtext)
                .font(.system(size: 14))
            Text("open.spotify.com/track/…")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.simiSubtext.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.simiCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.simiSubtext.opacity(0.2), lineWidth: 1)
        )
        .frame(maxWidth: 300)
        .allowsHitTesting(false) // purely decorative
        .accessibilityHidden(true)
    }

    // Static mockup of 2 result cards with match explanation chips
    private var resultsMockup: some View {
        VStack(spacing: 8) {
            ForEach([
                ("Fake Plastic Trees", "Radiohead", ["Same melancholic weight", "Equally restrained"]),
                ("Holocene", "Bon Iver", ["Same bittersweet edge", "Equally measured"])
            ], id: \.0) { title, artist, chips in
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.simiBody.weight(.semibold))
                        .foregroundColor(.white)
                    Text(artist)
                        .font(.simiCaption)
                        .foregroundColor(.simiSubtext)
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.simiMicro)
                                .foregroundColor(.simiAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.simiAccent.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: 300, alignment: .leading)
                .background(Color.simiCard)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - OnboardingCard

private struct OnboardingCard: View {
    let visual: AnyView
    let headline: String
    let subtext: String
    var showCTA: Bool = false
    var onCTA: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            visual
                .frame(height: 160)

            VStack(spacing: 16) {
                Text(headline)
                    .font(.simiTitle.weight(.bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(subtext)
                    .font(.simiBody)
                    .foregroundColor(.simiSubtext)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if showCTA {
                Button(action: { onCTA?() }) {
                    Text("Start Discovering →")
                        .font(.simiHeadline.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: 280)
                        .padding(.vertical, 16)
                        .background(LinearGradient.simiBrand)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel("Start discovering music")
            }

            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

#Preview {
    OnboardingView(onDismiss: {})
        .preferredColorScheme(.dark)
}
```

- [ ] **Step 2: Update `SimiApp.swift` with gate + overlay + auto-focus trigger**

Read `Simi/Simi/SimiApp.swift` first, then replace the `body` property and add the new state properties:

```swift
import SwiftUI
import AVFoundation

@main
struct SimiApp: App {

    @StateObject private var engine = RecommendationEngine()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var shouldFocusURLField = false

    init() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                HomeView(shouldFocusURL: $shouldFocusURLField)
                    .environmentObject(engine)
                    .preferredColorScheme(.dark)

                if !hasSeenOnboarding {
                    OnboardingView(onDismiss: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            hasSeenOnboarding = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            shouldFocusURLField = true
                        }
                    })
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { _ = await SimiAudioService.shared.warmUp() }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build the app in Xcode**

Open `Simi/Simi.xcodeproj` in Xcode and build (`Cmd+B`). Expected: 0 errors, 0 warnings. SourceKit IDE diagnostics ("Cannot find type X in scope") are known false positives in this project — ignore them; only actual build errors matter.

- [ ] **Step 4: Manually verify onboarding appears on first launch**

In Xcode Simulator (iPhone 17, iOS 18+):
- Delete the app from the simulator to clear `@AppStorage`
- Build and run (`Cmd+R`)
- Expected: `OnboardingView` appears over `HomeView` with 3 swipeable cards
- Swipe through all 3 cards — verify page dots visible on cards 1 and 2, hidden on card 3
- Verify "Start Discovering →" CTA button visible only on card 3
- Verify Skip button visible in top-right on all cards
- Tap Skip on card 1 — verify overlay fades out and URL field auto-focuses
- Delete app, reinstall — tap through to card 3 and tap CTA — verify same result
- Relaunch without deleting — verify onboarding does NOT appear again

- [ ] **Step 5: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi"
git add Simi/Views/OnboardingView.swift Simi/SimiApp.swift
git commit -m "feat: add first-launch onboarding carousel with 3 cards and auto-focus"
```

---

### Task 2: HomeView guided search — chips + cycling placeholder

**Files:**
- Modify: `Simi/Simi/Views/HomeView.swift`

**Interfaces:**
- Consumes: `shouldFocusURL: Binding<Bool>` from `SimiApp` (Task 1)
- Consumes: `engine.isLoading: Bool` for chip disabled state
- Produces: `HomeView(shouldFocusURL: Binding<Bool>)` — updated initializer signature

**Context:** `HomeView` currently has no parameters (no `init`). It uses `@EnvironmentObject var engine: RecommendationEngine`. The `urlRow(index:)` function builds each URL text field. `pastedURLs` is `@State private var pastedURLs: [String] = [""]`. `seeds` is `@State private var seeds: [SongSeed] = [SongSeed()]`. The `startSearch()` function is already defined and triggers the search. `searchMode` is `@State private var searchMode: SearchMode = .url`.

The body `VStack(spacing: 28)` currently contains in order: `logoSection`, `modePicker`, `Group { urlInputSection / textSearchSection }`, `findButton`, error/info banners, `recentSearchesSection`. The chips row goes between `modePicker` and the `Group`.

- [ ] **Step 1: Add `@FocusState`, `@Binding`, and timer state to `HomeView`**

Read `Simi/Simi/Views/HomeView.swift` in full. Then add these properties to `HomeView`:

```swift
// Add after the existing @State properties (around line 41):
@FocusState private var urlFieldFocused: Bool
@State private var placeholderIndex = 0
private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

// Add this binding parameter — HomeView needs an explicit init now:
var shouldFocusURL: Binding<Bool>

// Add this computed property for cycling placeholder strings:
private var urlPlaceholder: String {
    let options = [
        "Paste a Spotify, Apple Music, or YouTube link…",
        "Try: open.spotify.com/track/…",
        "Any song link works — we'll handle the rest"
    ]
    return options[placeholderIndex % options.count]
}
```

Note: `HomeView` currently has no explicit `init`. Adding the `shouldFocusURL: Binding<Bool>` parameter changes its initializer — `SimiApp` already passes `$shouldFocusURLField` (from Task 1). The `#Preview` at the bottom of `HomeView.swift` needs to be updated to pass `.constant(false)`:

```swift
#Preview {
    HomeView(shouldFocusURL: .constant(false))
        .environmentObject(RecommendationEngine())
        .preferredColorScheme(.dark)
}
```

- [ ] **Step 2: Add `onChange` for auto-focus trigger and timer guard**

Add these modifiers to the outermost `NavigationStack` in `HomeView.body` (after the existing `.onChange(of: engine.sourceSong)` modifier):

```swift
// Auto-focus URL field after onboarding dismissal
.onChange(of: shouldFocusURL.wrappedValue) { _, newValue in
    if newValue {
        urlFieldFocused = true
        shouldFocusURL.wrappedValue = false
    }
}
// Cycle placeholder text every 3s when URL field is empty and unfocused
.onReceive(timer) { _ in
    guard pastedURLs[0].isEmpty && !urlFieldFocused else { return }
    placeholderIndex = (placeholderIndex + 1) % 3
}
// Reset placeholder index when URL field is cleared
.onChange(of: pastedURLs[0]) { _, newValue in
    if newValue.isEmpty { placeholderIndex = 0 }
}
```

- [ ] **Step 3: Wire `@FocusState` to the first URL text field**

In `urlRow(index:)`, update the `TextField` to add `.focused($urlFieldFocused)` when `index == 0`:

Find the `TextField("", text: Binding(...), prompt: ...)` in `urlRow(index:)`. Replace the prompt with the cycling placeholder for index 0, and add focus binding:

```swift
TextField("", text: Binding(
    get: { pastedURLs[index] },
    set: { pastedURLs[index] = $0 }
), prompt: Text(index == 0 ? urlPlaceholder : "open.spotify.com/track/…")
    .foregroundColor(.simiSubtext.opacity(0.5)))
    .font(Font.system(size: 14, design: .monospaced))
    .foregroundColor(.simiText)
    .autocapitalization(.none)
    .autocorrectionDisabled()
    .submitLabel(.search)
    .onSubmit { startSearch() }
    .focused($urlFieldFocused)  // only meaningful for index 0; harmless for others
    .accessibilityLabel(pastedURLs.count > 1 ? "Song link \(index + 1)" : "Song link")
```

Also update text mode static placeholders in `textSearchSection` — find the title and artist `TextField` views and set their prompts to:
- Title field: `Text("e.g. Clair de Lune").foregroundColor(.simiSubtext.opacity(0.5))`
- Artist field: `Text("e.g. Debussy").foregroundColor(.simiSubtext.opacity(0.5))`

- [ ] **Step 4: Add `chipsRow` computed property**

Add this computed property to `HomeView`:

```swift
private var chipsRow: some View {
    let songs: [(label: String, url: String, title: String, artist: String)] = [
        ("Creep — Radiohead",
         "https://open.spotify.com/track/70LcF31zb1H0PyJoS1Sx1r",
         "Creep", "Radiohead"),
        ("Blinding Lights — The Weeknd",
         "https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b",
         "Blinding Lights", "The Weeknd"),
        ("Clair de Lune — Debussy",
         "https://open.spotify.com/track/3dkGuBqchfMzRxNM2mVmNm",
         "Clair de Lune", "Debussy"),
        ("Redbone — Childish Gambino",
         "https://open.spotify.com/track/0wXuerDYiBnERgIpbb3JBR",
         "Redbone", "Childish Gambino"),
        ("Let It Happen — Tame Impala",
         "https://open.spotify.com/track/2X485T9Z5Ly0xyaghN73ed",
         "Let It Happen", "Tame Impala")
    ]

    return VStack(alignment: .leading, spacing: 8) {
        Text("Try one of these →")
            .font(.simiMicro)
            .foregroundColor(.simiSubtext)

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(songs, id: \.label) { song in
                    Button(action: {
                        if searchMode == .url {
                            pastedURLs[0] = song.url
                            startSearch()
                        } else {
                            seeds[0].title = song.title
                            seeds[0].artist = song.artist
                            urlFieldFocused = true
                        }
                    }) {
                        Text(song.label)
                            .font(.simiMicro)
                            .foregroundColor(.simiAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .overlay(
                                Capsule()
                                    .stroke(Color.simiAccent, lineWidth: 1)
                            )
                    }
                    .accessibilityLabel("Try \(song.label)")
                    .disabled(engine.isLoading)
                }
            }
        }
    }
}
```

- [ ] **Step 5: Insert `chipsRow` into `HomeView.body`**

In the `VStack(spacing: 28)` inside `HomeView.body`, add `chipsRow` between `modePicker` and the `Group` block:

```swift
VStack(spacing: 28) {
    logoSection
    modePicker
    chipsRow              // ← ADD THIS
        .padding(.horizontal, 24)
    Group {
        if searchMode == .url {
            urlInputSection
        } else {
            textSearchSection
        }
    }
    .padding(.horizontal, 24)
    // ... rest unchanged
}
```

- [ ] **Step 6: Build and verify in Xcode**

Build (`Cmd+B`). Expected: 0 errors. Then run in Simulator:

- Verify chip row appears below the mode picker on HomeView
- URL mode: tap "Creep — Radiohead" chip — URL field fills with `https://open.spotify.com/track/70LcF31zb1H0PyJoS1Sx1r` and search begins
- Text mode: tap any chip — title and artist fill, no search triggered
- Verify cycling placeholder rotates every 3s in URL mode when field is empty and unfocused
- Verify placeholder pauses when URL field is focused
- Verify chips are not tappable while `engine.isLoading` is true (tap during an active search — nothing happens)
- Verify returning users (hasSeenOnboarding = true) see chips without onboarding overlay

**Success Criteria check:**
1. ✅ New user sees walkthrough before HomeView
2. ✅ Skip works on any card; CTA works on card 3
3. ✅ Walkthrough never appears again after dismissal
4. ✅ Chips auto-fill in URL mode (triggers search) and text mode (fills fields only)
5. ✅ Cycling placeholder cycles 3s, pauses when focused/non-empty, resets on clear
6. ✅ `accessibilityReduceMotion` suppresses entrance animation
7. ✅ Returning users see HomeView normally (no walkthrough, chips present)
8. ✅ Chips disabled during active search

- [ ] **Step 7: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi"
git add Simi/Views/HomeView.swift
git commit -m "feat: add example chips and cycling placeholder to HomeView"
```
