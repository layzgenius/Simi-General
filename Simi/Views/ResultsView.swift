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
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // Mood Shift Sliders — seeded from source song, adjusted live by user
    @State private var targetEnergy: Double   = 0.5
    @State private var targetValence: Double  = 0.5
    @State private var slidersActive: Bool    = false  // true once user has dragged
    @State private var slidersExpanded: Bool  = false  // collapsed by default

    // Same Key filter
    @State private var filterSameKey: Bool = false

    // True only when Spotify's audio-features endpoint provided a real musical key.
    // Tag estimation and audio preview analysis never detect pitch — they always fall back
    // to key=0/mode=1 (C Major) as a placeholder. isKeyEstimated=false means Spotify measured it.
    private var hasReliableSourceKey: Bool {
        guard let f = engine.sourceSong?.audioFeatures else { return false }
        return !f.isKeyEstimated
    }

    private var sourceKey: (key: Int, mode: Int)? {
        guard hasReliableSourceKey, let f = engine.sourceSong?.audioFeatures else { return nil }
        return (key: f.key, mode: f.mode)
    }

    private var sourceKeyName: String {
        engine.sourceSong?.audioFeatures?.keyName ?? "?"
    }

    private var crossGenreCount: Int {
        engine.recommendations.filter {
            guard let label = $0.matchExplanation?.genreBridgeLabel else { return false }
            return !label.isEmpty
        }.count
    }

    @ViewBuilder
    private var crossGenreBanner: some View {
        if crossGenreCount >= 2 {
            CrossGenreBannerView(count: crossGenreCount)
                .padding(.horizontal, 20)
                .transition(.opacity)
        }
    }

    // Re-ranked recommendations based on slider proximity.
    // Always applies when sliders are expanded — slidersActive is UI-only (dot, reset, border).
    var adjustedRecommendations: [SimilarSong] {
        guard slidersExpanded else { return engine.recommendations }
        return engine.recommendations.sorted {
            proximityScore($0) > proximityScore($1)
        }
    }

    // How close is a song to the current slider targets? 0.0–1.0, higher = closer
    func proximityScore(_ song: SimilarSong) -> Double {
        guard let f = song.audioFeatures else { return song.similarityScore }
        let energyDelta  = abs(f.energy  - targetEnergy)
        let valenceDelta = abs(f.valence - targetValence)
        let proximity = 1.0 - ((energyDelta + valenceDelta) / 2.0)
        // Blend 60% proximity to sliders + 40% original similarity so good matches stay near top
        return proximity * 0.6 + song.similarityScore * 0.4
    }

    // Final list shown in the UI: slider-adjusted → key-filtered
    var displayedRecommendations: [SimilarSong] {
        guard filterSameKey, let (key, mode) = sourceKey else {
            return adjustedRecommendations
        }
        return adjustedRecommendations.filter { song in
            // Only filter songs where the key is known (not estimated).
            // isKeyEstimated=false means the key came from Spotify or GetSongBPM.
            // Songs with no key data pass false so we don't hide what we can't measure.
            guard let f = song.audioFeatures, !f.isKeyEstimated else { return false }
            return f.key == key && f.mode == mode
        }
    }

    func resetSliders() {
        let features = engine.sourceSong?.audioFeatures
        targetEnergy  = features?.energy  ?? 0.5
        targetValence = features?.valence ?? 0.5
        slidersActive = false
    }

    var body: some View {
        ZStack {
            Color.simiBackground.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {

                        // ── Source Song Header ──
                        if engine.blendedSongs.count > 1 {
                            BlendSongHeader(songs: engine.blendedSongs, genres: engine.detectedGenres)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                                .padding(.bottom, 20)
                        } else if let song = engine.sourceSong {
                            SourceSongHeader(song: song, genres: engine.detectedGenres)
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                                .padding(.bottom, 20)
                        }

                        // ── View Mode Toggle ──
                        viewToggle
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)

                        // ── Filter Bar (list mode + reliable key only) ──
                        if viewMode == .list && hasReliableSourceKey {
                            filterBar
                                .padding(.bottom, 4)
                        }

                        // ── Mood Shift Sliders (list mode only) ──
                        if viewMode == .list {
                            moodSliderPanel
                                .padding(.horizontal, 20)
                                .padding(.bottom, 16)
                        }

                        // ── Content ──
                        if viewMode == .list {
                            listContent(proxy: proxy)
                        } else {
                            graphContent
                        }

                        attributionFooter
                            .padding(.horizontal, 20)
                            .padding(.bottom, 32)
                    }
                }
            }
        }
        .onAppear { resetSliders(); filterSameKey = false }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: {
                    engine.reset()
                    dismiss()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .accessibilityHidden(true)
                        Text("New Search")
                    }
                    .font(.simiBody.weight(.medium))
                    .foregroundColor(.simiAccent)
                }
                .accessibilityLabel("New Search")
                .accessibilityHint("Returns to the search screen")
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    Image(systemName: engine.isLoading ? "waveform" : "music.note")
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text(engine.isLoading ? "Finding…" : "\(engine.recommendations.count) found")
                        .font(.simiCaption.weight(.medium))
                }
                .foregroundColor(.simiSubtext)
                .accessibilityLabel(engine.isLoading ? "Finding songs" : "\(engine.recommendations.count) songs found")
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Filter Bar
    // ──────────────────────────────────────────────

    var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // ── Same Key chip ──
                let matchCount = adjustedRecommendations.filter { song in
                    guard let f = song.audioFeatures, !f.isKeyEstimated,
                          let (key, mode) = sourceKey else { return false }
                    return f.key == key && f.mode == mode
                }.count

                FilterChip(
                    icon: "music.quarternote.3",
                    label: filterSameKey ? sourceKeyName : "Same Key",
                    badge: filterSameKey ? nil : (matchCount > 0 ? "\(matchCount)" : nil),
                    isActive: filterSameKey,
                    reduceMotion: reduceMotion
                ) {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) {
                        filterSameKey.toggle()
                    }
                }
                .accessibilityLabel(filterSameKey
                    ? "Remove same key filter, \(sourceKeyName)"
                    : "Filter by same key (\(sourceKeyName))")
                .accessibilityHint(filterSameKey
                    ? "Shows all songs"
                    : "Shows only songs in \(sourceKeyName)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Key Filter Empty State
    // ──────────────────────────────────────────────

    var keyFilterEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.quarternote.3")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(.simiSubtext.opacity(0.45))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("No songs found in \(sourceKeyName)")
                    .font(.simiHeadline)
                    .foregroundColor(.simiText)
                Text("None of the discovered songs share this key. Remove the filter to see all results.")
                    .font(.simiCaption)
                    .foregroundColor(.simiSubtext)
                    .multilineTextAlignment(.center)
            }

            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                    filterSameKey = false
                }
            } label: {
                Text("Show all results")
                    .font(.simiBody.weight(.semibold))
                    .foregroundColor(.simiAccent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show all results")
            .accessibilityHint("Removes the same key filter")
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    // ──────────────────────────────────────────────
    // MARK: - Mood Shift Sliders
    // ──────────────────────────────────────────────

    var moodSliderPanel: some View {
        VStack(spacing: 0) {

            // ── Tappable header — always visible ──
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                    slidersExpanded.toggle()
                    // Collapse resets active state so dot indicator clears
                    if !slidersExpanded { slidersActive = false; resetSliders() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(slidersActive ? .simiAccent : .simiSubtext)
                        .accessibilityHidden(true)
                    Text("Mood Shift")
                        .font(.simiCaption.weight(.semibold))
                        .foregroundColor(slidersActive ? .simiAccent : .simiSubtext)

                    // Active dot — shows when user has moved a slider
                    if slidersActive {
                        Circle()
                            .fill(Color.simiAccent)
                            .frame(width: 5, height: 5)
                            .transition(.scale.combined(with: .opacity))
                    }

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.simiSubtext)
                        .rotationEffect(.degrees(slidersExpanded ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: slidersExpanded)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(slidersExpanded ? "Collapse Mood Shift" : "Expand Mood Shift")
            .accessibilityHint("Drag sliders to re-rank results by energy and mood")

            // ── Expandable slider body ──
            if slidersExpanded {
                VStack(spacing: 10) {
                    Divider()
                        .background(Color.simiBorder)
                        .padding(.horizontal, 14)

                    // Energy slider
                    VStack(spacing: 4) {
                        HStack {
                            Text("Energy")
                                .font(.simiMicro)
                                .foregroundColor(.simiSubtext)
                            Spacer()
                            Text(energyLabel)
                                .font(.simiMicro.weight(.semibold))
                                .foregroundColor(.simiText)
                                .animation(nil, value: targetEnergy)
                        }
                        Slider(value: $targetEnergy, in: 0...1)
                        .tint(.simiAccent)
                        .accessibilityLabel("Energy slider")
                        .accessibilityValue(energyLabel)
                        .onChange(of: targetEnergy) { _, _ in slidersActive = true }
                    }
                    .padding(.horizontal, 14)

                    // Mood (valence) slider
                    VStack(spacing: 4) {
                        HStack {
                            Text("Mood")
                                .font(.simiMicro)
                                .foregroundColor(.simiSubtext)
                            Spacer()
                            Text(valenceLabel)
                                .font(.simiMicro.weight(.semibold))
                                .foregroundColor(.simiText)
                                .animation(nil, value: targetValence)
                        }
                        Slider(value: $targetValence, in: 0...1)
                        .tint(valenceColor)
                        .accessibilityLabel("Mood slider")
                        .accessibilityValue(valenceLabel)
                        .onChange(of: targetValence) { _, _ in slidersActive = true }
                    }
                    .padding(.horizontal, 14)

                    // Reset button — always visible when expanded; dims until sliders are moved
                    Button("Reset to original") {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                            resetSliders()
                        }
                    }
                    .font(.simiMicro.weight(.semibold))
                    .foregroundColor(slidersActive ? .simiAccent : .simiSubtext.opacity(0.4))
                    .disabled(!slidersActive)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Reset sliders to original song values")
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: slidersActive)
                }
                .padding(.bottom, 12)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.simiCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(
            slidersActive ? Color.simiAccent.opacity(0.5) : Color.simiBorder,
            lineWidth: 1
        ))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: slidersActive)
    }

    private var energyLabel: String {
        switch targetEnergy {
        case 0..<0.25: return "Very calm"
        case 0.25..<0.45: return "Chill"
        case 0.45..<0.65: return "Moderate"
        case 0.65..<0.82: return "Energetic"
        default:           return "Intense"
        }
    }

    private var valenceLabel: String {
        switch targetValence {
        case 0..<0.25: return "Very dark"
        case 0.25..<0.45: return "Melancholic"
        case 0.45..<0.60: return "Neutral"
        case 0.60..<0.78: return "Upbeat"
        default:           return "Joyful"
        }
    }

    private var valenceColor: Color {
        switch targetValence {
        case 0..<0.35: return .simiPrimary
        case 0.35..<0.6: return .simiAccent
        default:          return .simiGreen
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - View Toggle
    // ──────────────────────────────────────────────

    var viewToggle: some View {
        HStack(spacing: 0) {
            ForEach(ResultsViewMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        viewMode = mode
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: mode == .list ? "list.bullet" : "chart.dots.scatter")
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(mode.rawValue)
                            .font(.simiBody.weight(.semibold))
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
                .accessibilityAddTraits(viewMode == mode ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Color.simiSurface)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .accessibilityLabel("View mode")
    }

    // ──────────────────────────────────────────────
    // MARK: - List Content
    // ──────────────────────────────────────────────

    @ViewBuilder
    func listContent(proxy: ScrollViewProxy) -> some View {
        if displayedRecommendations.isEmpty && filterSameKey {
            keyFilterEmptyState
        } else {
            VStack(spacing: 12) {
                crossGenreBanner
                ForEach(Array(displayedRecommendations.enumerated()), id: \.element.id) { index, song in
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
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: filterSameKey)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: crossGenreCount)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Graph Content
    // ──────────────────────────────────────────────

    var graphContent: some View {
        VStack(spacing: 12) {
            VibeGraphView(
                songs: engine.recommendations,
                // Source features live on sourceSong.audioFeatures for both single and blend modes
                // (blend stores the averaged features there). sourceName shows context.
                sourceFeatures: engine.sourceSong?.audioFeatures,
                sourceName: engine.blendedSongs.count > 1 ? "BLEND" : "YOU"
            ) { selected in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    highlightedSongID = selected.id
                    viewMode = .list
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    highlightedSongID = nil
                }
            }
            .padding(.horizontal, 20)

            HStack(spacing: 6) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
                Text("Tap a dot to jump to that song")
                    .font(.simiCaption)
            }
            .foregroundColor(.simiSubtext)
            .padding(.bottom, 8)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Attribution Footer
    // Required by Spotify and Last.fm developer terms
    // ──────────────────────────────────────────────

    var attributionFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 10))
                .accessibilityHidden(true)
            Text("Powered by Last.fm · Analysis by Simi")
                .font(.simiMicro)
        }
        .foregroundColor(.simiSubtext.opacity(0.65))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Music discovery powered by Last.fm, analysis by Simi")
    }
}

// ──────────────────────────────────────────────
// MARK: - Blend Song Header
// Shows all songs when the user blended multiple seeds
// ──────────────────────────────────────────────

struct BlendSongHeader: View {
    let songs: [Song]
    let genres: [Genre]

    var body: some View {
        VStack(spacing: 0) {
            Text("you blended")
                .font(.simiMicro.weight(.semibold))
                .foregroundColor(.simiSubtext)
                .textCase(.uppercase)
                .tracking(1.2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: song.albumArt)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.simiCard
                                .overlay(Image(systemName: "music.note").foregroundColor(.simiSubtext))
                        }
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title)
                                .font(.simiBody.weight(.semibold))
                                .foregroundColor(.simiText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Text(song.artist)
                                .font(.simiCaption)
                                .foregroundColor(.simiSubtext)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 10)

                    // Divider between songs, but not after the last one
                    if index < songs.count - 1 {
                        Rectangle()
                            .fill(Color.simiBorder)
                            .frame(height: 0.5)
                            .padding(.leading, 58)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
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
// MARK: - Source Song Header
// ──────────────────────────────────────────────

struct SourceSongHeader: View {
    let song: Song
    let genres: [Genre]

    var body: some View {
        VStack(spacing: 0) {
            Text("finding songs that feel like")
                .font(.simiMicro.weight(.semibold))
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
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(song.title)
                        .font(.simiTitle)
                        .foregroundColor(.simiText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)

                    Text(song.artist)
                        .font(.simiBody)
                        .foregroundColor(.simiSubtext)
                        .minimumScaleFactor(0.85)

                    HStack(spacing: 8) {
                        if let features = song.audioFeatures {
                            if features.bpm > 0 {
                                Badge(text: features.bpmFormatted, color: .simiPrimary)
                            }
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
                .font(.simiHeadline)
                .foregroundColor(.white)
            if let sub = genre.sub {
                Text(sub)
                    .font(.simiMicro)
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
            .font(.simiMicro.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

// ──────────────────────────────────────────────
// MARK: - Filter Chip
// A reusable pill chip for the filter bar.
// Active state uses the brand gradient; inactive uses card surface.
// ──────────────────────────────────────────────

struct FilterChip: View {
    let icon: String
    let label: String
    var badge: String? = nil     // Optional count badge (inactive only)
    let isActive: Bool
    var reduceMotion: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)

                Text(label)
                    .font(.simiMicro.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.interpolate)

                // Badge: song count when inactive, dismiss X when active
                if isActive {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .accessibilityHidden(true)
                        .transition(.scale.combined(with: .opacity))
                } else if let badge {
                    Text(badge)
                        .font(.simiMicro.weight(.bold))
                        .foregroundColor(.simiAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.simiAccent.opacity(0.15))
                        .clipShape(Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundColor(isActive ? .white : .simiSubtext)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if isActive {
                    Capsule().fill(LinearGradient.simiBrand)
                } else {
                    Capsule().fill(Color.simiCard)
                }
            }
            .overlay {
                if !isActive {
                    Capsule().stroke(Color.simiBorder, lineWidth: 1)
                }
            }
        }
        .buttonStyle(SimiPressStyle())
        // Expand hit area to 44pt minimum without changing visual size
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isActive)
    }
}

// ──────────────────────────────────────────────
// MARK: - Cross-Genre Banner
// Shown at the top of the list when ≥2 results cross genre families.
// ──────────────────────────────────────────────

struct CrossGenreBannerView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("🌉")
                .font(.system(size: 22))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) genre-crossing matches")
                    .font(.simiBody.weight(.semibold))
                    .foregroundColor(.simiText)
                Text("Same feeling, different world")
                    .font(.simiCaption)
                    .foregroundColor(.simiSubtext)
            }

            Spacer()
        }
        .padding(14)
        .background(Color.simiAccent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.simiAccent.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) genre-crossing matches. Same feeling, different world.")
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
