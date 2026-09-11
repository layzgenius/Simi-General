// MoodPadView.swift
// Simi — Music Discovery App
//
// 2D drag pad mapping valence (x) × arousal (y) to a point on the mood plane.
// Used in HomeView's "By Mood" search mode.

import SwiftUI

struct MoodPadView: View {
    @Binding var valence: Double   // 0 = dark/sad,  1 = bright/happy  (x-axis)
    @Binding var arousal: Double   // 0 = calm,      1 = energetic      (y-axis, up = high)

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                cornerLabels
                indicator(in: geo)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.simiBorder, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        valence = max(0, min(1, value.location.x / geo.size.width))
                        arousal = max(0, min(1, 1.0 - value.location.y / geo.size.height))
                    }
            )
            .accessibilityLabel("Mood selector. Current: \(accessibilityLabel)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: arousal = min(1.0, arousal + 0.1)
                case .decrement: arousal = max(0.0, arousal - 0.1)
                @unknown default: break
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Background Gradient
    // Valence: indigo (left, dark/sad) → amber (right, bright/happy)
    // Arousal: dark overlay at bottom (calm), lifts at top (energetic)
    // ──────────────────────────────────────────────

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: 0.63, saturation: 0.70, brightness: 0.55),
                    Color(hue: 0.10, saturation: 0.85, brightness: 0.90)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.white.opacity(0.08)],
                startPoint: .bottom,
                endPoint: .top
            )
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Corner Labels
    // ──────────────────────────────────────────────

    private var cornerLabels: some View {
        VStack {
            HStack {
                label("Dark &\nEnergetic")
                Spacer()
                label("Bright &\nEnergetic")
            }
            Spacer()
            HStack {
                label("Dark &\nCalm")
                Spacer()
                label("Bright &\nCalm")
            }
        }
        .padding(10)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }

    // ──────────────────────────────────────────────
    // MARK: - Indicator Dot
    // ──────────────────────────────────────────────

    private func indicator(in geo: GeometryProxy) -> some View {
        let x = valence * geo.size.width
        let y = (1.0 - arousal) * geo.size.height

        return ZStack {
            // Glow ring
            Circle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 44, height: 44)
                .blur(radius: 6)

            // Solid dot
            Circle()
                .fill(.white)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.6), lineWidth: 1.5)
                )
        }
        .position(x: x, y: y)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.7), value: valence)
        .animation(reduceMotion ? nil : .interactiveSpring(response: 0.25, dampingFraction: 0.7), value: arousal)
    }

    private var accessibilityLabel: String {
        let v = valence > 0.5 ? "Bright" : "Dark"
        let a = arousal > 0.5 ? "Energetic" : "Calm"
        return "\(v) and \(a)"
    }
}
