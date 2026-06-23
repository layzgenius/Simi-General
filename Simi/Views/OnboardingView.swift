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
