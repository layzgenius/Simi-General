// HomeView.swift
// Simi — Music Discovery App
//
// The first screen the user sees.
// Two search modes: paste a URL, or type a song title + artist.
// Below the search field: recent search history with re-run buttons.

import SwiftUI
import Combine

// ──────────────────────────────────────────────
// MARK: - Search Mode
// ──────────────────────────────────────────────

enum SearchMode: String, CaseIterable {
    case url  = "Paste Link"
    case text = "Search by Name"
}

// ──────────────────────────────────────────────
// MARK: - Song Seed (multi-song input model)
// ──────────────────────────────────────────────

struct SongSeed: Identifiable {
    let id = UUID()
    var title:  String = ""
    var artist: String = ""
}

// ──────────────────────────────────────────────
// MARK: - HomeView
// ──────────────────────────────────────────────

struct HomeView: View {

    @EnvironmentObject var engine: RecommendationEngine
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @State private var searchMode: SearchMode = .url
    @State private var pastedURLs: [String] = [""]   // multi-URL blend support
    @State private var seeds: [SongSeed] = [SongSeed()]
    @State private var navigateToResults = false
    @State private var showClearConfirm  = false

    // Focus + cycling placeholder state
    @FocusState private var urlFieldFocused: Bool
    @State private var placeholderIndex = 0
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    // Binding from SimiApp — set to true after onboarding dismissal to auto-focus URL field
    var shouldFocusURL: Binding<Bool>

    private let maxSeeds = 5

    // Cycling placeholder text for the URL input field
    private var urlPlaceholder: String {
        let options = [
            "Paste a Spotify, Apple Music, or YouTube link…",
            "Try: open.spotify.com/track/…",
            "Any song link works — we'll handle the rest"
        ]
        return options[placeholderIndex % options.count]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.simiBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {

                        logoSection

                        modePicker

                        chipsRow
                            .padding(.horizontal, 24)

                        Group {
                            if searchMode == .url {
                                urlInputSection
                            } else {
                                textSearchSection
                            }
                        }
                        .padding(.horizontal, 24)

                        findButton
                            .padding(.horizontal, 24)

                        if let error = engine.errorMessage {
                            errorBanner(message: error)
                                .padding(.horizontal, 24)
                        }

                        if let info = engine.infoMessage {
                            infoBanner(message: info)
                                .padding(.horizontal, 24)
                        }

                        if !engine.history.entries.isEmpty {
                            recentSearchesSection
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 20)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: engine.sourceSong) { _, song in
                if song != nil {
                    navigateToResults = true
                }
            }
            // Auto-focus URL field after onboarding dismissal
            .onChange(of: shouldFocusURL.wrappedValue) { _, newValue in
                if newValue {
                    urlFieldFocused = true
                    shouldFocusURL.wrappedValue = false
                }
            }
            // Cycle placeholder text every 3s when URL field is empty and unfocused
            .onReceive(timer) { _ in
                guard pastedURLs[0].isEmpty && !urlFieldFocused else { return }
                placeholderIndex = (placeholderIndex + 1) % 3
            }
            // Reset placeholder index when URL field is cleared
            .onChange(of: pastedURLs[0]) { _, newValue in
                if newValue.isEmpty { placeholderIndex = 0 }
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
                .font(.simiDisplay)
                .foregroundStyle(LinearGradient.simiBrand)
                .accessibilityLabel("Simi")

            Text("Paste any song. We'll find its emotional kin.")
                .font(.simiBody.weight(.medium))
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
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        searchMode = mode
                        engine.errorMessage = nil
                        engine.infoMessage  = nil
                    }
                }) {
                    Text(mode.rawValue)
                        .font(.simiBody.weight(.semibold))
                        .foregroundColor(searchMode == mode ? .white : .simiText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            searchMode == mode
                                ? LinearGradient.simiBrand
                                : LinearGradient(colors: [Color.simiBackground.opacity(0.5)], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.simiBorder, lineWidth: searchMode == mode ? 0 : 1)
                        )
                }
                .accessibilityAddTraits(searchMode == mode ? [.isSelected] : [])
            }
        }
        .padding(4)
        .background(Color.simiSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
        .accessibilityLabel("Search mode selector")
    }

    // ──────────────────────────────────────────────
    // MARK: - Example Song Chips
    // ──────────────────────────────────────────────

    private var chipsRow: some View {
        let songs: [(label: String, url: String, title: String, artist: String)] = [
            ("Creep — Radiohead",
             "https://open.spotify.com/track/70LcF31zb1H0PyJoS1Sx1r",
             "Creep", "Radiohead"),
            ("Blinding Lights — The Weeknd",
             "https://open.spotify.com/track/0VjIjW4GlUZAMYd2vXMi3b",
             "Blinding Lights", "The Weeknd"),
            ("Clair de Lune — Debussy",
             "https://open.spotify.com/track/3dkGuBqchfMzRxNM2mVmNm",
             "Clair de Lune", "Debussy"),
            ("Redbone — Childish Gambino",
             "https://open.spotify.com/track/0wXuerDYiBnERgIpbb3JBR",
             "Redbone", "Childish Gambino"),
            ("Let It Happen — Tame Impala",
             "https://open.spotify.com/track/2X485T9Z5Ly0xyaghN73ed",
             "Let It Happen", "Tame Impala")
        ]

        return VStack(alignment: .leading, spacing: 8) {
            Text("Try one of these →")
                .font(.simiMicro)
                .foregroundColor(.simiSubtext)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(songs, id: \.label) { song in
                        Button(action: {
                            if searchMode == .url {
                                pastedURLs[0] = song.url
                                startSearch()
                            } else {
                                seeds[0].title = song.title
                                seeds[0].artist = song.artist
                                urlFieldFocused = true
                            }
                        }) {
                            Text(song.label)
                                .font(.simiMicro)
                                .foregroundColor(.simiAccent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .overlay(
                                    Capsule()
                                        .stroke(Color.simiAccent, lineWidth: 1)
                                )
                        }
                        .accessibilityLabel("Try \(song.label)")
                        .disabled(engine.isLoading)
                    }
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - URL Paste Input (multi-URL blend)
    // ──────────────────────────────────────────────

    var urlInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("paste a song link")
                    .font(.simiMicro.weight(.semibold))
                    .foregroundColor(.simiSubtext)
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .accessibilityHidden(true)
                Spacer()
                if pastedURLs.count > 1 {
                    Text("\(pastedURLs.count) songs")
                        .font(.simiCaption)
                        .foregroundColor(.simiAccent)
                }
            }

            ForEach(pastedURLs.indices, id: \.self) { i in
                urlRow(index: i)
            }

            // Add another link button — up to 5
            if pastedURLs.count < maxSeeds {
                Button(action: {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                        pastedURLs.append("")
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .accessibilityHidden(true)
                        Text("Add another link")
                            .font(.simiBody.weight(.semibold))
                        Spacer()
                        Text("\(pastedURLs.count)/\(maxSeeds)")
                            .font(.simiCaption)
                            .foregroundColor(.simiSubtext)
                    }
                    .foregroundColor(.simiAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.simiAccent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                Color.simiAccent.opacity(0.25),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                            )
                    )
                }
                .accessibilityLabel("Add another link. \(pastedURLs.count) of \(maxSeeds) used")
            }

            // Platform hint
            let anyRecognised = pastedURLs.contains { URLSource.detect(from: $0) != .unknown }
            if anyRecognised {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.simiGreen)
                        .accessibilityHidden(true)
                    Text(pastedURLs.count > 1 ? "Links recognized — blending vibes" : "\(URLSource.detect(from: pastedURLs[0]).rawValue) link recognized")
                        .font(.simiCaption)
                        .foregroundColor(.simiGreen)
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.simiAccent)
                        .accessibilityHidden(true)
                    Text("Spotify · YouTube · SoundCloud")
                        .font(.simiCaption)
                        .foregroundColor(.simiSubtext)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: pastedURLs.count)
    }

    @ViewBuilder
    func urlRow(index: Int) -> some View {
        HStack(spacing: 12) {
            platformIcon(for: URLSource.detect(from: pastedURLs[index]))
                .accessibilityHidden(true)

            TextField("", text: Binding(
                get: { pastedURLs[index] },
                set: { pastedURLs[index] = $0 }
            ), prompt: Text(index == 0 ? urlPlaceholder : "open.spotify.com/track/…")
                .foregroundColor(.simiSubtext.opacity(0.5)))
                .font(Font.system(size: 14, design: .monospaced))
                .foregroundColor(.simiText)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { startSearch() }
                .focused($urlFieldFocused)
                .accessibilityLabel(pastedURLs.count > 1 ? "Song link \(index + 1)" : "Song link")

            if pastedURLs[index].isEmpty {
                Button(action: { pasteFromClipboard(into: index) }) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.simiAccent)
                        .font(.system(size: 17))
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Paste link from clipboard")
            } else {
                Button(action: { pastedURLs[index] = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.simiSubtext)
                        .font(.system(size: 17))
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Clear link")
            }

            // Remove row button (only when more than 1 URL)
            if pastedURLs.count > 1 {
                Button(action: { removeURL(at: index) }) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.simiError.opacity(0.7))
                        .font(.system(size: 16))
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Remove link \(index + 1)")
            }
        }
        .padding(14)
        .background(Color.simiSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    URLSource.detect(from: pastedURLs[index]) == .unknown
                        ? Color.simiBorder
                        : Color.simiAccent.opacity(0.5),
                    lineWidth: 1.5
                )
        )
        .transition(.asymmetric(
            insertion: reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity),
            removal:   reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity)
        ))
    }

    // ──────────────────────────────────────────────
    // MARK: - Text Search Input (multi-seed)
    // ──────────────────────────────────────────────

    var textSearchSection: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack {
                Text("search by name")
                    .font(.simiMicro.weight(.semibold))
                    .foregroundColor(.simiSubtext)
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .accessibilityHidden(true)
                Spacer()
                if seeds.count > 1 {
                    Text("\(seeds.count) songs")
                        .font(.simiCaption)
                        .foregroundColor(.simiAccent)
                }
            }

            ForEach(Array(seeds.enumerated()), id: \.element.id) { index, seed in
                seedCard(index: index, seedID: seed.id)
            }

            if seeds.count < maxSeeds {
                Button(action: {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                        seeds.append(SongSeed())
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .accessibilityHidden(true)
                        Text("Add another song")
                            .font(.simiBody.weight(.semibold))
                        Spacer()
                        Text("\(seeds.count)/\(maxSeeds)")
                            .font(.simiCaption)
                            .foregroundColor(.simiSubtext)
                    }
                    .foregroundColor(.simiAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.simiAccent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                Color.simiAccent.opacity(0.25),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])
                            )
                    )
                }
                .accessibilityLabel("Add another song. \(seeds.count) of \(maxSeeds) used")
            }

            if seeds.count == 1 && seeds[0].title.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("e.g.")
                        .font(.simiCaption.weight(.semibold))
                        .foregroundColor(.simiSubtext)
                    HStack(spacing: 6) {
                        Text("After Dark").font(.simiCaption.weight(.medium)).foregroundColor(.simiText)
                        Text("·").foregroundColor(.simiSubtext)
                        Text("Mr. Kitty").font(.simiCaption).foregroundColor(.simiSubtext)
                    }
                    HStack(spacing: 6) {
                        Text("Apocalypse").font(.simiCaption.weight(.medium)).foregroundColor(.simiText)
                        Text("·").foregroundColor(.simiSubtext)
                        Text("Cigarettes After Sex").font(.simiCaption).foregroundColor(.simiSubtext)
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Individual Seed Card
    // ──────────────────────────────────────────────

    @ViewBuilder
    func seedCard(index: Int, seedID: UUID) -> some View {
        VStack(spacing: 0) {

            // Title row
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .foregroundColor(.simiAccent)
                    .font(.system(size: 16))
                    .frame(width: 20)
                    .accessibilityHidden(true)

                TextField("", text: Binding(
                    get: { seeds[index].title },
                    set: { seeds[index].title = $0 }
                ), prompt: Text("e.g. Clair de Lune")
                    .foregroundColor(.simiSubtext.opacity(0.5)))
                    .font(.simiHeadline)
                    .foregroundColor(.simiText)
                    .autocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .accessibilityLabel(seeds.count > 1 ? "Song title, seed \(index + 1)" : "Song title")

                if !seeds[index].title.isEmpty {
                    Button(action: { seeds[index].title = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.simiSubtext.opacity(0.6))
                            .font(.system(size: 16))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Clear song title")
                }

                if seeds.count > 1 {
                    Button(action: {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                            seeds.removeAll { $0.id == seedID }
                        }
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundColor(.simiError.opacity(0.7))
                            .font(.system(size: 16))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Remove song \(index + 1)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .background(Color.simiBorder)
                .padding(.horizontal, 14)

            // Artist row
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .foregroundColor(.simiAccent)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .accessibilityHidden(true)

                TextField("", text: Binding(
                    get: { seeds[index].artist },
                    set: { seeds[index].artist = $0 }
                ), prompt: Text("e.g. Debussy")
                    .foregroundColor(.simiSubtext.opacity(0.5)))
                    .font(.simiHeadline)
                    .foregroundColor(.simiText)
                    .autocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(index == seeds.count - 1 ? .search : .next)
                    .onSubmit { if index == seeds.count - 1 { startSearch() } }
                    .accessibilityLabel(seeds.count > 1 ? "Artist name, seed \(index + 1), optional" : "Artist name, optional")

                if !seeds[index].artist.isEmpty {
                    Button(action: { seeds[index].artist = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.simiSubtext.opacity(0.6))
                            .font(.system(size: 16))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Clear artist name")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(Color.simiSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    seeds[index].title.isEmpty ? Color.simiBorder : Color.simiAccent.opacity(0.5),
                    lineWidth: 1.5
                )
        )
        .transition(.asymmetric(
            insertion: reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity),
            removal:   reduceMotion ? .opacity : .scale(scale: 0.95).combined(with: .opacity)
        ))
    }

    // ──────────────────────────────────────────────
    // MARK: - Find Button
    // ──────────────────────────────────────────────

    var findButton: some View {
        Button(action: startSearch) {
            HStack(spacing: 10) {
                if engine.isLoading {
                    ProgressView().tint(.white).scaleEffect(0.85)
                    Text(engine.loadingMessage)
                } else {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .accessibilityHidden(true)
                    Text(searchMode == .text && seeds.count > 1
                         ? "Blend \(seeds.count) Songs"
                         : searchMode == .url && pastedURLs.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count > 1
                             ? "Blend \(pastedURLs.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count) Songs"
                             : "Find Similar Songs")
                }
            }
            .font(.simiHeadline.weight(.semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                isSearchReady
                    ? LinearGradient.simiBrand
                    : LinearGradient(
                        colors: [Color.simiPrimary.opacity(0.35), Color.simiAccent.opacity(0.35)],
                        startPoint: .leading, endPoint: .trailing
                      )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .simiPrimary.opacity(isSearchReady ? 0.35 : 0), radius: 12, y: 4)
        }
        .disabled(!isSearchReady || engine.isLoading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isSearchReady)
        .accessibilityLabel(engine.isLoading
            ? engine.loadingMessage
            : searchMode == .text && seeds.count > 1
                ? "Blend \(seeds.count) songs"
                : "Find similar songs")
        .accessibilityHint(isSearchReady ? "" : "Enter a song first")
    }

    // ──────────────────────────────────────────────
    // MARK: - Error Banner
    // ──────────────────────────────────────────────

    func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.simiError)
                .font(.system(size: 15))
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.simiCaption)
                    .foregroundColor(.simiError)
                    .multilineTextAlignment(.leading)
                Text("Try a different link, or switch to Search by Name.")
                    .font(.simiMicro)
                    .foregroundColor(.simiSubtext)
            }
            Spacer()
            Button(action: { engine.errorMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.simiSubtext)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .background(Color.simiError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.simiError.opacity(0.2), lineWidth: 1))
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
    }

    // ──────────────────────────────────────────────
    // MARK: - Info Banner
    // ──────────────────────────────────────────────

    func infoBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.simiYellow)
                .font(.system(size: 15))
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(message)
                .font(.simiCaption)
                .foregroundColor(.simiText.opacity(0.85))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: { engine.infoMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.simiSubtext)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Dismiss info")
        }
        .padding(12)
        .background(Color.simiYellow.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.simiYellow.opacity(0.25), lineWidth: 1))
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
    }

    // ──────────────────────────────────────────────
    // MARK: - Recent Searches
    // ──────────────────────────────────────────────

    var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent")
                    .font(.simiCaption.weight(.semibold))
                    .foregroundColor(.simiSubtext)
                    .textCase(.uppercase)
                    .tracking(1.2)

                Spacer()

                Button("Clear") {
                    showClearConfirm = true
                }
                .font(.simiCaption)
                .foregroundColor(.simiSubtext)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Clear all recent searches")
                .confirmationDialog(
                    "Clear all recent searches?",
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Clear All", role: .destructive) { engine.history.clearAll() }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .padding(.horizontal, 24)

            VStack(spacing: 8) {
                ForEach(engine.history.entries.prefix(5)) { entry in
                    HistoryRow(entry: entry, manager: engine.history) {
                        Task {
                            // Re-run via the original path — URL searches use the URL,
                            // text searches use title + artist. queryString preserves this.
                            let query = entry.queryString
                            let source = URLSource.detect(from: query)
                            if source != .unknown {
                                await engine.findSimilarSongs(for: query)
                            } else {
                                await engine.findSimilarSongs(title: entry.song.title,
                                                              artist: entry.song.artist)
                            }
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
        case .url:  return pastedURLs.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        case .text: return seeds.contains { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    func startSearch() {
        guard isSearchReady else { return }
        Task {
            switch searchMode {
            case .url:
                let validURLs = pastedURLs.map { $0.trimmingCharacters(in: .whitespaces) }
                                          .filter { !$0.isEmpty }
                await engine.findSimilarSongs(for: validURLs)
            case .text:
                let validSeeds = seeds
                    .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { (title: $0.title.trimmingCharacters(in: .whitespaces),
                            artist: $0.artist.trimmingCharacters(in: .whitespaces)) }
                await engine.findSimilarSongs(seeds: validSeeds)
            }
        }
    }

    func pasteFromClipboard(into index: Int = 0) {
        if let str = UIPasteboard.general.string {
            pastedURLs[index] = str
        }
    }

    func removeURL(at index: Int) {
        let animation: Animation? = reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)
        withAnimation(animation) {
            _ = pastedURLs.remove(at: index)
        }
    }

    @ViewBuilder
    func platformIcon(for source: URLSource) -> some View {
        switch source {
        case .spotify:
            Image(systemName: "music.note")
                .foregroundColor(.simiSpotifyGreen)
                .font(.system(size: 17, weight: .medium))
        case .youtube:
            Image(systemName: "play.rectangle.fill")
                .foregroundColor(.simiYouTubeRed)
                .font(.system(size: 17, weight: .medium))
        case .soundcloud:
            Image(systemName: "cloud.fill")
                .foregroundColor(.simiYellow)
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
// ──────────────────────────────────────────────

struct HistoryRow: View {
    let entry: HistoryEntry
    let manager: SearchHistoryManager
    let onRerun: () -> Void

    var body: some View {
        Button(action: onRerun) {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: entry.song.albumArt)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.simiSurface
                        .overlay(Image(systemName: "music.note")
                            .foregroundColor(.simiSubtext).font(.system(size: 12)))
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.song.title)
                        .font(.simiBody.weight(.semibold))
                        .foregroundColor(.simiText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text(entry.song.artist)
                        .font(.simiCaption)
                        .foregroundColor(.simiSubtext)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    if let features = entry.song.audioFeatures {
                        Text(features.vibeSummary)
                            .font(.simiMicro)
                            .foregroundColor(.simiAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.simiAccent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(manager.relativeDate(for: entry))
                        .font(.simiMicro)
                        .foregroundColor(.simiSubtext)

                    // Visual affordance — not a separate tap target (whole row is the button)
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.simiAccent)
                        .padding(6)
                        .background(Color.simiAccent.opacity(0.12))
                        .clipShape(Circle())
                }
            }
            .padding(12)
            .background(Color.simiCard)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.simiBorder, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(SimiPressStyle())
        .accessibilityLabel("Re-run search for \(entry.song.title) by \(entry.song.artist)")
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
    HomeView(shouldFocusURL: .constant(false))
        .environmentObject(RecommendationEngine())
        .preferredColorScheme(.dark)
}
