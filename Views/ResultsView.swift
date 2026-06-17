// ResultsView.swift
// Simi — Music Discovery App
//
// The results screen — shown after the user searches for a song.
// Two view modes toggled at the top:
//   • List   — ranked song cards with match reasons
//   • Graph  — Vibe Map scatter plot (energy vs. valence)

import SwiftUI

// ──────────────────────────────────────────────
// MARK: - Results View Mode
// ──────────────────────────────────────────────

enum ResultsViewMode: String, CaseIterable {
    case list  = "List"
    case graph = "Vibe Map"
}

// ──────────────────────────────────────────────
// MARK: - ResultsView
// ──────────────────────────────────────────────

struct ResultsView: View {

    @EnvironmentObject var engine: RecommendationEngine
    @Environment(\.dismiss) var dismiss

    @State private var viewMode: ResultsViewMode = .list
    @State private var highlightedSongID: String? = nil

    var body: some View {
        ZStack {
            Color.simiBackground.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {

                        // ── Source Song Header ──
                        if let song = engine.sourceSong {
                            SourceSongHeader(song: song, genres: engine.detectedGenres)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                                .padding(.bottom, 20)
                        }

                        // ── View Mode Toggle ──
                        viewToggle
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)

                        // ── Content ──
                        if viewMode == .list {
                            listContent(proxy: proxy)
                        } else {
                            graphContent
                        }

                        Spacer(minLength: 40)
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    engine.reset()
                    dismiss()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("New Search")
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.simiAccent)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.system(size: 13))
                    Text("\(engine.recommendations.count) found")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(.simiSubtext)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - View Toggle
    // ──────────────────────────────────────────────

    var viewToggle: some View {
        HStack(spacing: 0) {
            ForEach(ResultsViewMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewMode = mode
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: mode == .list ? "list.bullet" : "chart.dots.scatter")
                            .font(.system(size: 13, weight: .semibold))
                        Text(mode.rawValue)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(viewMode == mode ? .white : .simiSubtext)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        viewMode == mode
                            ? LinearGradient.simiBrand
                            : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                }
            }
        }
        .padding(4)
        .background(Color.simiSurface)
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    // ──────────────────────────────────────────────
    // MARK: - List Content
    // ──────────────────────────────────────────────

    @ViewBuilder
    func listContent(proxy: ScrollViewProxy) -> some View {
        LazyVStack(spacing: 12) {
            ForEach(Array(engine.recommendations.enumerated()), id: \.element.id) { index, song in
                SongCard(song: song, rank: index + 1)
                    .id(song.id)
                    .padding(.horizontal, 20)
                    .overlay(
                        // Highlight ring when jumped to from the graph
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.simiAccent, lineWidth: 2)
                            .padding(.horizontal, 20)
                            .opacity(highlightedSongID == song.id ? 1 : 0)
                            .animation(.easeInOut(duration: 0.4), value: highlightedSongID)
                            .allowsHitTesting(false)
                    )
            }
        }
        .padding(.bottom, 24)
    }

    // ──────────────────────────────────────────────
    // MARK: - Graph Content
    // ──────────────────────────────────────────────

    var graphContent: some View {
        VStack(spacing: 12) {
            VibeGraphView(songs: engine.recommendations) { selected in
                // When user taps a dot, switch to list and scroll to that card
                withAnimation {
                    highlightedSongID = selected.id
                    viewMode = .list
                }
                // Clear highlight after a moment
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    highlightedSongID = nil
                }
            }
            .padding(.horizontal, 20)

            // Hint
            HStack(spacing: 6) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 12))
                Text("Tap a dot to jump to that song")
                    .font(.system(size: 12))
            }
            .foregroundColor(.simiSubtext)
            .padding(.bottom, 8)
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Source Song Header
// ──────────────────────────────────────────────

struct SourceSongHeader: View {
    let song: Song
    let genres: [Genre]

    var body: some View {
        VStack(spacing: 0) {
            Text("you searched for")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.simiSubtext)
                .textCase(.uppercase)
                .tracking(1.2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)

            HStack(spacing: 16) {
                AsyncImage(url: URL(string: song.albumArt)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.simiCard
                        .overlay(Image(systemName: "music.note").foregroundColor(.simiSubtext))
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 5) {
                    Text(song.title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.simiText)
                        .lineLimit(2)

                    Text(song.artist)
                        .font(.system(size: 14))
                        .foregroundColor(.simiSubtext)

                    HStack(spacing: 8) {
                        if let features = song.audioFeatures, features.bpm > 0 {
                            Badge(text: features.bpmFormatted, color: .simiPrimary)
                            Badge(text: features.vibeSummary, color: .simiAccent)
                        }
                    }
                }

                Spacer()
            }
            .padding(14)
            .background(Color.simiCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.simiBorder, lineWidth: 1))

            if !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(genres) { genre in
                            GenreTag(genre: genre)
                        }
                    }
                    .padding(.top, 10)
                }
            }
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Genre Tag
// ──────────────────────────────────────────────

struct GenreTag: View {
    let genre: Genre

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(genre.main)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            if let sub = genre.sub {
                Text(sub)
                    .font(.system(size: 11))
                    .foregroundColor(.simiSubtext)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.simiCard)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.simiBorder, lineWidth: 1))
    }
}

// ──────────────────────────────────────────────
// MARK: - Badge
// ──────────────────────────────────────────────

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

// ──────────────────────────────────────────────
// MARK: - Preview
// ──────────────────────────────────────────────

#Preview {
    NavigationStack {
        ResultsView()
            .environmentObject(RecommendationEngine())
    }
}
