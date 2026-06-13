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

    // Platform brand colors — used for Spotify/YouTube/Apple Music icons
    static let simiSpotifyGreen    = Color(hex: "#1DB954")
    static let simiYouTubeRed      = Color(hex: "#FF3040")
    static let simiAppleMusicPink  = Color(hex: "#FA2D5A")

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
// MARK: - Typography Scale
// ──────────────────────────────────────────────
// Six steps cover everything in the app. Use these instead of
// ad-hoc .system(size:) calls so the scale stays consistent.

extension Font {
    /// 52pt — app logo only
    static let simiDisplay  = Font.system(size: 52, weight: .black,    design: .rounded)
    /// 18pt — screen titles, source song title
    static let simiTitle    = Font.system(size: 18, weight: .bold,     design: .rounded)
    /// 15pt — card song titles, section headings, button labels
    static let simiHeadline = Font.system(size: 15, weight: .semibold, design: .rounded)
    /// 14pt — body copy, input text, list items
    static let simiBody     = Font.system(size: 14,                    design: .rounded)
    /// 12pt — secondary labels, timestamps, section caps
    static let simiCaption  = Font.system(size: 12, weight: .medium, design: .rounded)
    /// 11pt — badges, micro-labels, match reason chips
    static let simiMicro    = Font.system(size: 11, weight: .medium, design: .rounded)
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

// ──────────────────────────────────────────────
// MARK: - Press Feedback Button Style
// ──────────────────────────────────────────────

/// Subtle scale + opacity press feedback — apply to tappable cards and rows.
struct SimiPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
