// VibeGraphView.swift
// Simi — Music Discovery App
//
// A scatter plot showing recommended songs plotted by:
//   X axis → Valence  (0 = dark/sad  →  1 = happy/upbeat)
//   Y axis → Energy   (0 = calm/soft →  1 = intense/loud)
//
// The source song (what the user searched for) is shown as a white-bordered dot labelled "YOU"
// so users can immediately see where their song sits relative to the recommendations.
// Tapping a recommendation dot highlights it (via onSelect callback).

import SwiftUI

struct VibeGraphView: View {

    let songs: [SimilarSong]
    var sourceFeatures: AudioFeatures? = nil   // The source/seed song features — plotted as "YOU"
    var sourceName: String = "YOU"             // Label shown on the source dot
    var onSelect: ((SimilarSong) -> Void)? = nil

    @State private var selectedSong: SimilarSong? = nil

    // Only songs with real audio features — what actually gets plotted
    var songsWithFeatures: [SimilarSong] {
        songs.filter { $0.audioFeatures != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Header ──
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vibe Map")
                        .font(.simiTitle)
                        .foregroundColor(.simiText)
                    Text("Energy vs. Mood")
                        .font(.simiCaption)
                        .foregroundColor(.simiSubtext)
                }
                Spacer()
                if selectedSong != nil {
                    Button("Clear") { withAnimation { selectedSong = nil } }
                        .font(.system(size: 13))
                        .foregroundColor(.simiSubtext)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Clear selected song")
                }
            }

            // ── Plot ──
            GeometryReader { geo in
                let plotWidth  = geo.size.width
                let plotHeight = geo.size.height

                ZStack {
                    // Background
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.simiSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.simiBorder, lineWidth: 1)
                        )

                    if songsWithFeatures.isEmpty && sourceFeatures == nil {
                        // ── Empty state — no audio data available ──
                        VStack(spacing: 10) {
                            Image(systemName: "waveform.slash")
                                .font(.system(size: 30))
                                .foregroundColor(.simiSubtext.opacity(0.4))
                                .accessibilityHidden(true)
                            Text("No audio data available")
                                .font(.simiHeadline)
                                .foregroundColor(.simiSubtext)
                            Text("Audio features couldn't be estimated for these songs.\nTry a more popular or widely-tagged track.")
                                .font(.simiMicro)
                                .foregroundColor(.simiSubtext.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("No audio data available. Audio features couldn't be estimated for these songs.")
                        .padding(20)
                    } else {
                        // ── Grid lines ──
                        gridLines(width: plotWidth, height: plotHeight)

                        // ── Quadrant labels ──
                        quadrantLabels(width: plotWidth, height: plotHeight)

                        // ── Axis labels ──
                        axisLabels(width: plotWidth, height: plotHeight)

                        // ── Recommendation dots ──
                        // Filled = real audio features
                        // Hollow ring = estimated from Last.fm tags (still meaningful, just approximate)
                        // Dots are visually 9-14pt but have a 44×44pt hit area via contentShape.
                        ForEach(songsWithFeatures) { song in
                            let x = dotX(song, in: plotWidth)
                            let y = dotY(song, in: plotHeight)
                            let isSelected = selectedSong?.id == song.id
                            let isEstimated = song.audioFeatures?.isEstimated ?? false

                            ZStack {
                                // 44×44 invisible tap region (accessibility & touch target)
                                Color.clear
                                    .frame(width: 44, height: 44)

                                // Glow for selected
                                if isSelected {
                                    Circle()
                                        .fill(dotColor(song).opacity(0.25))
                                        .frame(width: 28, height: 28)
                                }
                                if isEstimated {
                                    // Hollow ring — estimated from genre tags
                                    Circle()
                                        .strokeBorder(dotColor(song).opacity(0.7), lineWidth: 1.5)
                                        .frame(width: isSelected ? 14 : 9, height: isSelected ? 14 : 9)
                                } else {
                                    // Solid — measured features
                                    Circle()
                                        .fill(dotColor(song))
                                        .frame(width: isSelected ? 14 : 9, height: isSelected ? 14 : 9)
                                        .shadow(color: dotColor(song).opacity(0.5), radius: isSelected ? 6 : 2)
                                }
                            }
                            .contentShape(Rectangle())
                            .position(x: x, y: y)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    selectedSong = (selectedSong?.id == song.id) ? nil : song
                                }
                                onSelect?(song)
                            }
                            .accessibilityLabel("\(song.title) by \(song.artist), \(song.similarityLabel)")
                            .accessibilityHint("Tap to see details")
                            .accessibilityAddTraits(.isButton)
                        }

                        // ── Source song dot ("YOU") ──
                        // Plotted on top of recommendation dots so it's always visible.
                        // White fill + simiPrimary border makes it instantly distinct.
                        if let src = sourceFeatures {
                            let sx = sourceX(src, in: plotWidth)
                            let sy = sourceY(src, in: plotHeight)

                            // "YOU" label — floats just above the dot
                            Text(sourceName)
                                .font(.system(size: 9, weight: .black))
                                .foregroundColor(.simiPrimary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.simiPrimary.opacity(0.15))
                                .clipShape(Capsule())
                                .position(x: sx, y: sy - 18)

                            // Source dot: pulsing outer ring + white inner + accent border
                            ZStack {
                                Circle()
                                    .fill(Color.simiPrimary.opacity(0.18))
                                    .frame(width: 24, height: 24)
                                Circle()
                                    .fill(Color.simiCard)
                                    .frame(width: 14, height: 14)
                                Circle()
                                    .strokeBorder(Color.simiPrimary, lineWidth: 2.5)
                                    .frame(width: 14, height: 14)
                            }
                            .position(x: sx, y: sy)
                        }

                        // ── Selected song tooltip ──
                        if let selected = selectedSong,
                           songsWithFeatures.contains(where: { $0.id == selected.id }) {
                            let x = dotX(selected, in: plotWidth)
                            let y = dotY(selected, in: plotHeight)

                            tooltipView(song: selected, features: selected.audioFeatures)
                                .position(x: tooltipX(x, plotWidth: plotWidth),
                                          y: tooltipY(y, plotHeight: plotHeight))
                        }
                    }
                }
            }
            .frame(height: 280)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selectedSong?.id)

            // Legend
            HStack(spacing: 14) {
                // Source song marker — always shown when we have source features
                if sourceFeatures != nil {
                    HStack(spacing: 5) {
                        ZStack {
                            Circle().fill(Color.simiCard).frame(width: 8, height: 8)
                            Circle().strokeBorder(Color.simiPrimary, lineWidth: 1.5).frame(width: 8, height: 8)
                        }
                        Text("Your song").font(.simiMicro).foregroundColor(.simiSubtext)
                    }
                }
                // Estimated / measured split — only when both types exist
                if songsWithFeatures.contains(where: { $0.audioFeatures?.isEstimated == false }) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.simiAccent).frame(width: 7, height: 7)
                        Text("Measured").font(.simiMicro).foregroundColor(.simiSubtext)
                    }
                }
                if songsWithFeatures.contains(where: { $0.audioFeatures?.isEstimated == true }) {
                    HStack(spacing: 5) {
                        Circle().strokeBorder(Color.simiAccent.opacity(0.7), lineWidth: 1.5).frame(width: 7, height: 7)
                        Text("Est. from tags").font(.simiMicro).foregroundColor(.simiSubtext)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.simiCard)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.simiBorder, lineWidth: 1))
    }

    // ──────────────────────────────────────────────
    // MARK: - Sub-views
    // ──────────────────────────────────────────────

    @ViewBuilder
    func gridLines(width: CGFloat, height: CGFloat) -> some View {
        // Horizontal line at energy = 0.7 (matches vibeSummary "Intense" threshold)
        let energyY = (height - padding) - 0.7 * (height - padding * 2)
        Path { path in
            path.move(to: CGPoint(x: padding, y: energyY))
            path.addLine(to: CGPoint(x: width - padding, y: energyY))
        }
        .stroke(Color.simiBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // Vertical line at valence = 0.55 (matches vibeSummary high-energy valence threshold)
        let valenceX = padding + 0.55 * (width - padding * 2)
        Path { path in
            path.move(to: CGPoint(x: valenceX, y: padding))
            path.addLine(to: CGPoint(x: valenceX, y: height - padding))
        }
        .stroke(Color.simiBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    @ViewBuilder
    func quadrantLabels(width: CGFloat, height: CGFloat) -> some View {
        // Grid lines sit at valence=0.55 (x) and energy=0.7 (y).
        // Quadrant label positions are the midpoints of each quadrant region.
        let vx = padding + 0.55 * (width - padding * 2)   // vertical divider x
        let ey = (height - padding) - 0.7 * (height - padding * 2) // horizontal divider y

        // Top-right: Energetic & Upbeat  (valence > 0.55, energy > 0.7)
        Text("Energetic\n& Upbeat")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.simiGreen.opacity(0.6))
            .multilineTextAlignment(.center)
            .position(x: (vx + width - padding) / 2, y: (padding + ey) / 2)

        // Top-left: Intense & Dark  (valence < 0.55, energy > 0.7)
        Text("Intense\n& Dark")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.simiError.opacity(0.5))
            .multilineTextAlignment(.center)
            .position(x: (padding + vx) / 2, y: (padding + ey) / 2)

        // Bottom-right: Warm & Groovy / Chill & Happy  (valence > 0.55, energy < 0.7)
        Text("Warm &\nChill")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.simiAccent.opacity(0.5))
            .multilineTextAlignment(.center)
            .position(x: (vx + width - padding) / 2, y: (ey + height - padding) / 2)

        // Bottom-left: Melancholic & Calm / Moody & Driving  (valence < 0.55, energy < 0.7)
        Text("Melancholic\n& Calm")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.simiPrimary.opacity(0.5))
            .multilineTextAlignment(.center)
            .position(x: (padding + vx) / 2, y: (ey + height - padding) / 2)
    }

    @ViewBuilder
    func axisLabels(width: CGFloat, height: CGFloat) -> some View {
        // X axis: Dark ← → Upbeat
        Text("← Dark")
            .font(.system(size: 9))
            .foregroundColor(.simiSubtext)
            .position(x: padding + 20, y: height - 8)

        Text("Upbeat →")
            .font(.system(size: 9))
            .foregroundColor(.simiSubtext)
            .position(x: width - padding - 22, y: height - 8)

        // Y axis: Calm ↓ ↑ Intense
        Text("Calm")
            .font(.system(size: 9))
            .foregroundColor(.simiSubtext)
            .position(x: 18, y: height - padding - 4)

        Text("Intense")
            .font(.system(size: 9))
            .foregroundColor(.simiSubtext)
            .position(x: 22, y: padding + 4)
    }

    @ViewBuilder
    func tooltipView(song: SimilarSong, features: AudioFeatures?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(song.title)
                .font(.simiCaption.weight(.bold))
                .foregroundColor(.simiText)
                .lineLimit(1)
            Text(song.artist)
                .font(.simiMicro)
                .foregroundColor(.simiSubtext)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let features, features.bpm > 0 {
                    Text(features.bpmFormatted)
                    Text("·")
                }
                Text(song.similarityLabel)
            }
            .font(.simiMicro)
            .foregroundColor(.simiAccent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.simiCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.simiBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .frame(width: 160)
    }

    // ──────────────────────────────────────────────
    // MARK: - Geometry Helpers
    // ──────────────────────────────────────────────

    let padding: CGFloat = 24

    /// X position — plotted by valence (only called for songs with real features)
    func dotX(_ song: SimilarSong, in width: CGFloat) -> CGFloat {
        let valence = song.audioFeatures?.valence ?? 0.5
        return padding + CGFloat(valence) * (width - padding * 2)
    }

    /// Y position — plotted by energy, inverted (high energy = top of chart)
    func dotY(_ song: SimilarSong, in height: CGFloat) -> CGFloat {
        let energy = song.audioFeatures?.energy ?? 0.5
        return (height - padding) - CGFloat(energy) * (height - padding * 2)
    }

    /// X position for source song features (same axes as recommendation dots)
    func sourceX(_ features: AudioFeatures, in width: CGFloat) -> CGFloat {
        padding + CGFloat(features.valence) * (width - padding * 2)
    }

    /// Y position for source song features (energy, inverted)
    func sourceY(_ features: AudioFeatures, in height: CGFloat) -> CGFloat {
        (height - padding) - CGFloat(features.energy) * (height - padding * 2)
    }

    func tooltipX(_ dotX: CGFloat, plotWidth: CGFloat) -> CGFloat {
        if dotX > plotWidth * 0.6 { return dotX - 90 }
        return dotX + 90
    }

    func tooltipY(_ dotY: CGFloat, plotHeight: CGFloat) -> CGFloat {
        if dotY < 60 { return dotY + 50 }
        return dotY - 50
    }

    func dotColor(_ song: SimilarSong) -> Color {
        switch song.similarityScore {
        case 0.85...: return .simiGreen
        case 0.70...: return .simiAccent
        case 0.55...: return .simiPrimary
        default:      return .simiSubtext
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Preview
// ──────────────────────────────────────────────

#Preview {
    let sampleSongs: [SimilarSong] = [
        SimilarSong(id: "1", title: "Blinding Lights", artist: "The Weeknd",
                    albumArt: "", spotifyURL: "https://open.spotify.com", previewURL: nil,
                    genre: Genre(main: "Pop"), audioFeatures: AudioFeatures(bpm: 171, energy: 0.73, valence: 0.33, danceability: 0.51, acousticness: 0.0, instrumentalness: 0.0, liveness: 0.09, loudness: -4.2, key: 1, mode: 0),
                    similarityScore: 0.91, matchReasons: [.bpm, .energy]),
        SimilarSong(id: "2", title: "Sunflower", artist: "Post Malone",
                    albumArt: "", spotifyURL: "https://open.spotify.com", previewURL: nil,
                    genre: Genre(main: "Hip-Hop"), audioFeatures: AudioFeatures(bpm: 90, energy: 0.49, valence: 0.76, danceability: 0.76, acousticness: 0.16, instrumentalness: 0.0, liveness: 0.07, loudness: -6.8, key: 7, mode: 1),
                    similarityScore: 0.78, matchReasons: [.genre, .mood]),
        SimilarSong(id: "3", title: "Creepin'", artist: "Metro Boomin",
                    albumArt: "", spotifyURL: "https://open.spotify.com", previewURL: nil,
                    genre: Genre(main: "R&B"), audioFeatures: AudioFeatures(bpm: 95, energy: 0.41, valence: 0.18, danceability: 0.81, acousticness: 0.06, instrumentalness: 0.0, liveness: 0.08, loudness: -7.1, key: 9, mode: 0),
                    similarityScore: 0.65, matchReasons: [.mood, .acoustics]),
    ]

    VibeGraphView(songs: sampleSongs)
        .padding()
        .background(Color.simiBackground)
}
