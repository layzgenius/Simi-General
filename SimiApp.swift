// SimiApp.swift
// Simi — Music Discovery App
//
// This is the entry point of the app — the very first file Swift runs.
// It creates the RecommendationEngine once and passes it to all views.

import SwiftUI

@main
struct SimiApp: App {

    // @StateObject creates the engine once and keeps it alive for the app's lifetime.
    // Every view that uses @EnvironmentObject will share this same instance.
    @StateObject private var engine = RecommendationEngine()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(engine)   // Makes engine available to all child views
                .preferredColorScheme(.dark) // Simi is always dark mode
        }
    }
}
