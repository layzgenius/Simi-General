// VibeGraphView.swift
// Simi — Music Discovery App
//
// A scatter plot showing recommended songs plotted by:
//   X axis → Valence  (0 = dark/sad  →  1 = happy/upbeat)
//   Y axis → Energy   (0 = calm/soft →  1 = intense/loud)
//
// Only songs with real AcousticBrainz audio features are plotted.
// If no songs have features (e.g. obscure artists), a clean empty state is shown.
// Tapping a dot scrolls to that song card (via onSelect callback).

import SwiftUI

struct VibeGraphView: View {

    let songs: [SimilarSong]
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
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.simiText)
                    Text("Energy vs. Mood")
                        .font(.system(size: 12))
                        .foregroundColor(.simiSubtext)
                }
                Spacer()
                if selectedSong != nil {
                    Button("Clear") { withAnimation { selectedSong = nil } }
                        .font(.system(size: 13))
                        .foregroundColor(.simiSubtext)
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

                    if songsWithFeatures.isEmpty {
                        // ── Empty state — no audio data available ──
                        VStack(spacing: 10) {
                            Image(systemName: "waveform.slash")
                                .font(.system(size: 30))
                                .foregroundColor(.simiSubtext.opacity(0.4))
                            Text("No audio data for these songs")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.simiSubtext)
                            Text("AcousticBrainz doesn't have fingerprints\nfor this artist yet. Try a more popular track.")
                                .font(.system(size: 11))
                                .foregroundColor(.simiSubtext.opacity(0.6))
                                .multilineTextAlignment(.center)
                        }
                        .padding(20)
                    } else {
                        // ── Grid lines ──
                        gridLines(width: plotWidth, height: plotHeight)

                        // ── Quadrant labels ──
                        quadrantLabels(width: plotWidth, height: plotHeight)

                        // ── Axis labels ──
                        axisLabels(width: plotWidth, height: plotHeight)

                        // ── Song dots ──
                        // Filled = real AcousticBrainz data
                        // Hollow ring = estimated from Last.fm tags (still meaningful, just approximate)
                        ForEach(songsWithFeatures) { song in
                            let x = dotX(song, in: plotWidth)
                            let y = dotY(song, in: plotHeight)
                            let isSelected = selectedSong?.id == song.id
                            let isEstimated = song.audioFeatures?.isEstimated ?? false

                            ZStack {
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
                                    // Solid — measured by AcousticBrainz
                                    Circle()
                                        .fill(dotColor(song))
                                        .frame(width: isSelected ? 14 : 9, height: isSelected ? 14 : 9)
                                        .shadow(color: dotColor(song).opacity(0.5), radius: isSelected ? 6 : 2)
                                }
                            }
                            .position(x: x, y: y)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    selectedSong = (selectedSong?.id == song.id) ? nil : song
                                }
                                onSelect?(song)
                            }
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

            // Legend — only shown when there's a mix of real and estimated dots
            if songsWithFeatures.contains(where: { $0.audioFeatures?.isEstimated == false }),
               songsWithFeatures.contains(where: { $0.audioFeatures?.isEstimated == true }) {
                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.simiAccent).frame(width: 7, height: 7)
                        Text("Measured").font(.system(size: 10)).foregroundColor(.simiSubtext)
                    }
                    HStack(spacing: 5) {
                        Circle().strokeBorder(Color.simiAccent.opacity(0.7), lineWidth: 1.5).frame(width: 7, height: 7)
                        Text("Est. from tags").font(.system(size: 10)).foregroundColor(.simiSubtext)
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
        // Horizontal midline (energy = 0.5)
        Path { path in
            path.move(to: CGPoint(x: padding, y: height / 2))
            path.addLine(to: CGPoint(x: width - padding, y: height / 2))
        }
        .stroke(Color.simiBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // Vertical midline (valence = 0.5)
        Path { path in
            path.move(to: CGPoint(x: width / 2, y: padding))
            path.addLine(to: CGPoint(x: width / 2, y: height - padding))
        }
        .stroke(Color.simiBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    @ViewBuilder
    func quadrantLabels(width: CGFloat, height: CGFloat) -> some View {
        let half = 0.25 as CGFloat

        // Top-right: Energetic & Upbeat
        Text("Energetic\n& Upbeat")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.simiGreen.opacity(0.6))
            .multilineTextAlignment(.center)
            .position(x: width * 0.75, y: height * 0.2)

        // Top-left: Intense & Dark
        Text("Intense\n& Dark")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.simiError.opacity(0.5))
            .multilineTextAlignment(.center)
            .position(x: width * 0.25, y: height * 0.2)

        // Bottom-right: Chill & Happy
        Text("Chill\n& Happy")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.simiAccent.opacity(0.5))
            .multilineTextAlignment(.center)
            .position(x: width * 0.75, y: height * 0.8)

        // Bottom-left: Melancholic
        Text("Melancholic\n& Calm")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.simiPrimary.opacity(0.5))
            .multilineTextAlignment(.center)
            .position(x: width * 0.25, y: height * 0.8)
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
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.simiText)
                .lineLimit(1)
            Text(song.artist)
                .font(.system(size: 10))
                .foregroundColor(.simiSubtext)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let features, features.bpm > 0 {
                    Text(features.bpmFormatted)
                    Text("·")
                }
                Text(song.similarityLabel)
            }
            .font(.system(size: 10))
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
