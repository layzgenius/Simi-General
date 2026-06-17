// HomeView.swift
// Simi — Music Discovery App
//
// The first screen the user sees.
// Two search modes: paste a URL, or type a song title + artist.
// Below the search field: recent search history with re-run buttons.

import SwiftUI

// ──────────────────────────────────────────────
// MARK: - Search Mode
// ──────────────────────────────────────────────

enum SearchMode: String, CaseIterable {
    case url  = "Paste Link"
    case text = "Search by Name"
}

// ──────────────────────────────────────────────
// MARK: - HomeView
// ──────────────────────────────────────────────

struct HomeView: View {

    @EnvironmentObject var engine: RecommendationEngine

    // Search mode toggle
    @State private var searchMode: SearchMode = .url

    // URL paste mode
    @State private var pastedURL: String = ""

    // Text search mode
    @State private var songTitle:  String = ""
    @State private var artistName: String = ""

    // Navigation
    @State private var navigateToResults = false
    @State private var showHistory       = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.simiBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {

                        // ── Logo ──
                        logoSection

                        // ── Mode Toggle ──
                        modePicker

                        // ── Search Input ──
                        Group {
                            if searchMode == .url {
                                urlInputSection
                            } else {
                                textSearchSection
                            }
                        }
                        .padding(.horizontal, 24)

                        // ── Find Button ──
                        findButton
                            .padding(.horizontal, 24)

                        // ── Error ──
                        if let error = engine.errorMessage {
                            Text(error)
                                .font(.system(size: 13))
                                .foregroundColor(.simiError)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                                .transition(.opacity)
                        }

                        // ── Recent Searches ──
                        if !engine.history.entries.isEmpty {
                            recentSearchesSection
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 20)
                }
            }
            .navigationBarHidden(true)
            .onChange(of: engine.recommendations.count) {
                if !engine.recommendations.isEmpty { navigateToResults = true }
            }
            .navigationDestination(isPresented: $navigateToResults) {
                ResultsView()
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Logo Section
    // ──────────────────────────────────────────────

    var logoSection: some View {
        VStack(spacing: 6) {
            Text("simi")
                .font(.system(size: 52, weight: .black, design: .rounded))
                .foregroundStyle(LinearGradient.simiBrand)

            Text("find songs that feel the same")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundColor(.simiSubtext)
        }
        .padding(.top, 16)
    }

    // ──────────────────────────────────────────────
    // MARK: - Mode Picker
    // ──────────────────────────────────────────────

    var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(SearchMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        searchMode = mode
                        engine.errorMessage = nil
                    }
                }) {
                    Text(mode.rawValue)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(searchMode == mode ? .white : .simiSubtext)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            searchMode == mode
                                ? LinearGradient.simiBrand
                                : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(4)
        .background(Color.simiSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
    }

    // ──────────────────────────────────────────────
    // MARK: - URL Paste Input
    // ──────────────────────────────────────────────

    var urlInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("paste a song link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.simiSubtext)
                .textCase(.uppercase)
                .tracking(1.2)

            HStack(spacing: 12) {
                platformIcon(for: URLSource.detect(from: pastedURL))

                TextField("", text: $pastedURL,
                          prompt: Text("open.spotify.com/track/...")
                              .foregroundColor(.simiSubtext.opacity(0.5)))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.simiText)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { startSearch() }

                if pastedURL.isEmpty {
                    Button(action: pasteFromClipboard) {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.simiAccent)
                            .font(.system(size: 17))
                    }
                } else {
                    Button(action: { pastedURL = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.simiSubtext)
                            .font(.system(size: 17))
                    }
                }
            }
            .padding(14)
            .background(Color.simiSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        URLSource.detect(from: pastedURL) == .unknown
                            ? Color.simiBorder
                            : Color.simiAccent.opacity(0.5),
                        lineWidth: 1.5
                    )
            )

            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.simiAccent)
                Text("Spotify · YouTube · SoundCloud")
                    .font(.system(size: 12))
                    .foregroundColor(.simiSubtext)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Text Search Input
    // ──────────────────────────────────────────────

    var textSearchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("search by name")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.simiSubtext)
                .textCase(.uppercase)
                .tracking(1.2)

            // Song title field
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .foregroundColor(.simiAccent)
                    .font(.system(size: 17))
                    .frame(width: 22)

                TextField("", text: $songTitle,
                          prompt: Text("Song title")
                              .foregroundColor(.simiSubtext.opacity(0.5)))
                    .font(.system(size: 15, design: .rounded))
                    .foregroundColor(.simiText)
                    .autocapitalization(.words)
                    .submitLabel(.next)

                if !songTitle.isEmpty {
                    Button(action: { songTitle = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.simiSubtext)
                            .font(.system(size: 17))
                    }
                }
            }
            .padding(14)
            .background(Color.simiSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(!songTitle.isEmpty ? Color.simiAccent.opacity(0.5) : Color.simiBorder, lineWidth: 1.5)
            )

            // Artist field
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .foregroundColor(.simiPrimary)
                    .font(.system(size: 15))
                    .frame(width: 22)

                TextField("", text: $artistName,
                          prompt: Text("Artist name (optional)")
                              .foregroundColor(.simiSubtext.opacity(0.5)))
                    .font(.system(size: 15, design: .rounded))
                    .foregroundColor(.simiText)
                    .autocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit { startSearch() }

                if !artistName.isEmpty {
                    Button(action: { artistName = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.simiSubtext)
                            .font(.system(size: 17))
                    }
                }
            }
            .padding(14)
            .background(Color.simiSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(!artistName.isEmpty ? Color.simiPrimary.opacity(0.5) : Color.simiBorder, lineWidth: 1.5)
            )

            Text("Works like searching: \"songs like After Dark\" or \"songs like Cigarettes After Sex\"")
                .font(.system(size: 12))
                .foregroundColor(.simiSubtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Find Button
    // ──────────────────────────────────────────────

    var findButton: some View {
        Button(action: startSearch) {
            HStack(spacing: 10) {
                if engine.isLoading {
                    ProgressView().tint(.white).scaleEffect(0.85)
                    Text("Finding songs…")
                } else {
                    Image(systemName: "waveform.badge.magnifyingglass")
                    Text("Find Similar Songs")
                }
            }
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                isSearchReady
                    ? LinearGradient.simiBrand
                    : LinearGradient(colors: [Color.simiSubtext.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .simiPrimary.opacity(isSearchReady ? 0.35 : 0), radius: 12, y: 4)
        }
        .disabled(!isSearchReady || engine.isLoading)
        .animation(.easeInOut(duration: 0.2), value: isSearchReady)
    }

    // ──────────────────────────────────────────────
    // MARK: - Recent Searches
    // ──────────────────────────────────────────────

    var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.simiText)

                Spacer()

                Button("Clear") {
                    engine.history.clearAll()
                }
                .font(.system(size: 13))
                .foregroundColor(.simiSubtext)
            }
            .padding(.horizontal, 24)

            VStack(spacing: 8) {
                ForEach(engine.history.entries.prefix(5)) { entry in
                    HistoryRow(entry: entry, manager: engine.history) {
                        // Re-run this search
                        Task {
                            await engine.findSimilarSongs(for: entry.queryString)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────

    var isSearchReady: Bool {
        switch searchMode {
        case .url:  return !pastedURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .text: return !songTitle.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func startSearch() {
        guard isSearchReady else { return }
        Task {
            switch searchMode {
            case .url:
                await engine.findSimilarSongs(for: pastedURL)
            case .text:
                await engine.findSimilarSongs(title: songTitle, artist: artistName)
            }
        }
    }

    func pasteFromClipboard() {
        if let str = UIPasteboard.general.string {
            pastedURL = str
        }
    }

    @ViewBuilder
    func platformIcon(for source: URLSource) -> some View {
        switch source {
        case .spotify:
            Image(systemName: "music.note")
                .foregroundColor(.green)
                .font(.system(size: 17, weight: .medium))
        case .youtube:
            Image(systemName: "play.rectangle.fill")
                .foregroundColor(.red)
                .font(.system(size: 17, weight: .medium))
        case .soundcloud:
            Image(systemName: "cloud.fill")
                .foregroundColor(.orange)
                .font(.system(size: 17, weight: .medium))
        case .unknown:
            Image(systemName: "link")
                .foregroundColor(.simiSubtext)
                .font(.system(size: 17, weight: .medium))
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - History Row
// One past search with a re-run button and swipe-to-delete
// ──────────────────────────────────────────────

struct HistoryRow: View {
    let entry: HistoryEntry
    let manager: SearchHistoryManager
    let onRerun: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Album art thumbnail
            AsyncImage(url: URL(string: entry.song.albumArt)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.simiSurface
                    .overlay(Image(systemName: "music.note")
                        .foregroundColor(.simiSubtext).font(.system(size: 12)))
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.song.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.simiText)
                    .lineLimit(1)

                Text(entry.song.artist)
                    .font(.system(size: 12))
                    .foregroundColor(.simiSubtext)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(manager.relativeDate(for: entry))
                    .font(.system(size: 11))
                    .foregroundColor(.simiSubtext)

                Button(action: onRerun) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.simiAccent)
                        .padding(6)
                        .background(Color.simiAccent.opacity(0.12))
                        .clipShape(Circle())
                }
            }
        }
        .padding(12)
        .background(Color.simiCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.simiBorder, lineWidth: 1))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                manager.remove(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(RecommendationEngine())
}
