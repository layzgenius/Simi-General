// SimiApp.swift
// Simi — Music Discovery App
//
// This is the entry point of the app — the very first file Swift runs.
// It creates the RecommendationEngine once and passes it to all views.

import SwiftUI
import AVFoundation

@main
struct SimiApp: App {

    // @StateObject creates the engine once and keeps it alive for the app's lifetime.
    // Every view that uses @EnvironmentObject will share this same instance.
    @StateObject private var engine = RecommendationEngine()
    @Environment(\.scenePhase) private var scenePhase

    /// Persisted across launches — false until the user completes or skips onboarding.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    /// Set to true when the user dismisses onboarding so HomeView can auto-focus
    /// the URL field. Passed in via binding once Task 2 adds the parameter to HomeView.
    @State private var shouldFocusURLField = false

    init() {
        // Set once at launch so previews play through the speaker even in silent mode.
        // Calling setCategory repeatedly (per-play) is redundant and triggers a system
        // notification on iOS 16+ each time the app first accesses audio.
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
                    .onChange(of: scenePhase) { _, phase in
                        // Warm Railway on foreground — cold starts take up to ~20s, so use
                        // warmUp() (22s timeout) not isReachable() (3s) so the container is
                        // actually alive by the time the user's first search hits Stage 2.
                        if phase == .active {
                            Task { _ = await SimiAudioService.shared.warmUp() }
                        }
                    }

                if !hasSeenOnboarding {
                    OnboardingView(onDismiss: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            hasSeenOnboarding = true
                        }
                        // Trigger URL field focus after the overlay fades out.
                        // Task 2 will wire shouldFocusURLField into HomeView.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            shouldFocusURLField = true
                        }
                    })
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
        }
    }
}
