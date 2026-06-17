// Theme.swift
// Simi — Music Discovery App
//
// Single source of truth for all colors, fonts, and visual constants.
// Import nothing extra — these are SwiftUI Color extensions, available everywhere.

import SwiftUI

// ──────────────────────────────────────────────
// MARK: - Color Palette
// ──────────────────────────────────────────────

extension Color {
    // Backgrounds
    static let simiBackground = Color(hex: "#0c0c10") // True near-black with a blue tint
    static let simiSurface    = Color(hex: "#14141c") // Slightly lighter — for input fields
    static let simiCard       = Color(hex: "#1a1a26") // Card surface
    static let simiBorder     = Color(hex: "#2a2a3a") // Subtle borders and dividers

    // Brand
    static let simiPrimary    = Color(hex: "#7c5dfa") // Purple — buttons, highlights
    static let simiAccent     = Color(hex: "#38c0fa") // Cyan-blue — secondary accent

    // Semantic
    static let simiGreen      = Color(hex: "#3ddc84") // Success / high match
    static let simiYellow     = Color(hex: "#f5c518") // Warning / medium match
    static let simiError      = Color(hex: "#f55a5a") // Error states

    // Text
    static let simiText       = Color(hex: "#eeeef5") // Primary text (near-white with blue tint)
    static let simiSubtext    = Color(hex: "#8888aa") // Secondary / muted text

    // Convenience initializer from hex string — e.g. Color(hex: "#7c5dfa")
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xff) / 255
        let g = Double((int >>  8) & 0xff) / 255
        let b = Double( int        & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// ──────────────────────────────────────────────
// MARK: - Gradient Helpers
// ──────────────────────────────────────────────

extension LinearGradient {
    /// The signature Simi purple→cyan gradient used on buttons and the logo
    static let simiBrand = LinearGradient(
        colors: [.simiPrimary, .simiAccent],
        startPoint: .leading,
        endPoint: .trailing
    )
}

// ──────────────────────────────────────────────
// MARK: - Reusable View Modifiers
// ──────────────────────────────────────────────

/// Applies Simi's standard card styling (dark surface, rounded, border)
struct SimiCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.simiCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.simiBorder, lineWidth: 1)
            )
    }
}

extension View {
    func simiCardStyle() -> some View {
        modifier(SimiCardStyle())
    }
}
