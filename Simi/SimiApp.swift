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
            HomeView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    // Warm Railway on foreground so the first /batch-analyze after a cold
                    // sleep doesn't burn the full 90s timeout. /health is ~50ms, costs nothing.
                    if phase == .active {
                        Task { _ = await SimiAudioService.shared.isReachable() }
                    }
                }
        }
    }
}
