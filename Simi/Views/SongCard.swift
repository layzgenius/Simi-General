// SongCard.swift
// Simi — Music Discovery App
//
// Each recommended song appears as one of these cards in the results list.
// It shows the album art, title, artist, similarity %, match reasons,
// and buttons to open the song on Spotify / Apple Music / YouTube.

import SwiftUI
import AVFoundation
import Combine

// ──────────────────────────────────────────────
// MARK: - Shared Preview Player
// One global player so only one song previews at a time.
// ──────────────────────────────────────────────

class PreviewPlayer: ObservableObject {
    static let shared = PreviewPlayer()
    private var player: AVPlayer?
    private var stopTask: Task<Void, Never>?

    @Published var playingSongID: String? = nil

    func play(song: SimilarSong, duration: Double = 5) {
        guard let urlString = song.previewURL, let url = URL(string: urlString) else { return }

        // Stop whatever is playing
        stop()

        // Ensure audio plays through speaker even in silent mode
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        player = AVPlayer(url: url)
        player?.play()
        playingSongID = song.id

        // Auto-stop after `duration` seconds
        stopTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled {
                await MainActor.run { self.stop() }
            }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.pause()
        player = nil
        playingSongID = nil
    }
}

struct SongCard: View {

    let song: SimilarSong
    let rank: Int

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @ObservedObject private var previewPlayer = PreviewPlayer.shared

    private var isPlaying: Bool { previewPlayer.playingSongID == song.id }
    private var hasPreview: Bool { song.previewURL != nil }

    var body: some View {
        VStack(spacing: 0) {

            // ── Main row ──
            HStack(spacing: 12) {

                // Rank
                Text("\(rank)")
                    .font(Font.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.simiSubtext)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                // Album art — own button so preview tap doesn't conflict with expand
                Button {
                    guard hasPreview else { return }
                    if isPlaying { previewPlayer.stop() }
                    else { previewPlayer.play(song: song, duration: 30) }
                } label: {
                    ZStack {
                        AsyncImage(url: URL(string: song.albumArt)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.simiCard
                                .overlay(Image(systemName: "music.note")
                                    .foregroundColor(.simiSubtext)
                                    .font(.system(size: 14)))
                        }

                        // Overlay — always visible hint when preview available
                        if hasPreview {
                            Color.black.opacity(isPlaying ? 0.55 : 0.18)
                                .animation(.easeInOut(duration: 0.2), value: isPlaying)

                            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                .font(.system(size: isPlaying ? 16 : 11, weight: .bold))
                                .foregroundColor(.white)
                                .opacity(isPlaying ? 1.0 : 0.75)
                                .animation(.easeInOut(duration: 0.2), value: isPlaying)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!hasPreview)
                .accessibilityLabel(isPlaying
                    ? "Stop preview of \(song.title)"
                    : hasPreview
                        ? "Preview \(song.title)"
                        : "\(song.title) album art")
                .accessibilityHint(hasPreview && !isPlaying ? "Plays a short preview" : "")

                // Title + artist — tap to expand details
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title)
                            .font(.simiHeadline)
                            .foregroundColor(.simiText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Text(song.artist)
                            .font(.simiCaption)
                            .foregroundColor(.simiSubtext)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded
                    ? "Collapse details for \(song.title) by \(song.artist)"
                    : "\(song.title) by \(song.artist), \(song.similarityLabel)"
                      + (song.matchReasons.isEmpty ? "" : ", "
                         + song.matchReasons.prefix(2).map(\.rawValue).joined(separator: ", ")))
                .accessibilityHint(isExpanded ? "Tap to collapse" : "Tap to see audio features")

                // RIGHT: similarity % + bar + platform links
                VStack(alignment: .trailing, spacing: 4) {
                    // Playing indicator replaces similarity label while previewing
                    if isPlaying {
                        WaveformBars(reduceMotion: reduceMotion)
                    } else {
                        Text(song.similarityLabel)
                            .font(.simiMicro.weight(.bold))
                            .foregroundColor(similarityColor(song.similarityScore))
                    }

                    SimilarityBar(score: song.similarityScore)
                        .frame(width: 44, height: 4)
                        .accessibilityHidden(true)

                    HStack(spacing: 2) {
                        // Spotify
                        if let spotifyURL = URL(string: song.spotifyURL) {
                            Link(destination: spotifyURL) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.simiSpotifyGreen)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Open on Spotify")
                        }

                        // Apple Music
                        Link(destination: appleMusicURL(for: song)) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.simiAppleMusicPink)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Search on Apple Music")

                        // YouTube
                        Link(destination: youtubeURL(for: song)) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.simiYouTubeRed)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Search on YouTube")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, song.matchReasons.isEmpty ? 14 : 8)

            // ── Match reason chips — full-width row so they never get squished ──
            if !song.matchReasons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(song.matchReasons.prefix(2), id: \.rawValue) { reason in
                        Text(reason.rawValue)
                            .font(.simiMicro)
                            .lineLimit(1)
                            .foregroundColor(.simiAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.simiAccent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }

            // ── Expanded Detail ──
            if isExpanded, let features = song.audioFeatures {
                Divider()
                    .background(Color.simiBorder)
                    .padding(.horizontal, 14)

                AudioFeaturesGrid(features: features)
                    .padding(14)
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.simiCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.simiBorder, lineWidth: 1))
    }

    // ──────────────────────────────────────────────
    // MARK: - Platform URL Builders
    // ──────────────────────────────────────────────

    func appleMusicURL(for song: SimilarSong) -> URL {
        let query = "\(song.title) \(song.artist)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://music.apple.com/search?term=\(query)")
            ?? URL(string: "https://music.apple.com")!
    }

    func youtubeURL(for song: SimilarSong) -> URL {
        let query = "\(song.title) \(song.artist)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.youtube.com/results?search_query=\(query)")
            ?? URL(string: "https://www.youtube.com")!
    }

    func similarityColor(_ score: Double) -> Color {
        switch score {
        case 0.85...: return .simiGreen
        case 0.70...: return .simiAccent
        case 0.55...: return .simiPrimary
        default:      return .simiSubtext
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Waveform Bars (preview playing indicator)
// ──────────────────────────────────────────────

struct WaveformBars: View {
    var reduceMotion: Bool = false
    @State private var phase = false

    // Scale factors per bar relative to their natural height.
    // Using scaleEffect(y:) instead of animating frame height avoids layout thrashing.
    private let scaleFactors: [CGFloat] = [0.5, 1.0, 0.67]
    private let barHeight: CGFloat = 12

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.simiAccent)
                    .frame(width: 3, height: barHeight)
                    .scaleEffect(y: phase ? 1.0 : scaleFactors[i], anchor: .center)
                    .animation(
                        reduceMotion ? nil :
                            .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .frame(height: barHeight)
        .onAppear { phase = true }
        .onDisappear { phase = false }
    }
}

// ──────────────────────────────────────────────
// MARK: - Similarity Bar
// ──────────────────────────────────────────────

struct SimilarityBar: View {
    let score: Double
    @State private var animatedScore: Double = 0

    var body: some View {
        ZStack(alignment: .leading) {
            // Track
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.simiSubtext.opacity(0.2))

            // Fill — uses scaleEffect(x:anchor:.leading) instead of animating frame width
            // to avoid layout thrashing (scaleEffect runs on the compositor thread).
            RoundedRectangle(cornerRadius: 2)
                .fill(LinearGradient(
                    colors: [.simiPrimary, .simiAccent],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .scaleEffect(x: animatedScore, anchor: .leading)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05)) {
                animatedScore = score
            }
        }
        .onChange(of: score) { _, newScore in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                animatedScore = newScore
            }
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Audio Features Grid
// ──────────────────────────────────────────────

struct AudioFeaturesGrid: View {
    let features: AudioFeatures

    var featureItems: [(label: String, value: String, icon: String)] {
        var items: [(label: String, value: String, icon: String)] = [
            ("BPM",          features.bpmFormatted,             "metronome"),
            ("Energy",       percentLabel(features.energy),      "bolt.fill"),
            ("Mood",         percentLabel(features.valence),     "face.smiling"),
            ("Danceability", percentLabel(features.danceability), "figure.dance"),
            ("Acoustic",     percentLabel(features.acousticness), "guitars"),
        ]
        // Key requires real audio analysis — hide it when features are estimated from tags
        if !features.isEstimated {
            items.append(("Key", features.keyName, "music.quarternote.3"))
        }
        return items
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 12
        ) {
            ForEach(featureItems, id: \.label) { item in
                VStack(spacing: 4) {
                    Image(systemName: item.icon)
                        .font(.system(size: 14))
                        .foregroundColor(.simiAccent)
                        .accessibilityHidden(true)
                    Text(item.value)
                        .font(.simiCaption.weight(.semibold))
                        .foregroundColor(.simiText)
                    Text(item.label)
                        .font(.simiMicro)
                        .foregroundColor(.simiSubtext)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.simiSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.label): \(item.value)")
            }
        }
    }

    func percentLabel(_ value: Double) -> String {
        "\(Int(value * 100))%"
    }
}

#Preview {
    let sampleSong = SimilarSong(
        id: "1",
        title: "Midnight Rain",
        artist: "Taylor Swift",
        albumArt: "",
        spotifyURL: "https://open.spotify.com",
        previewURL: nil,
        genre: Genre(main: "Pop", sub: "Indie Pop"),
        audioFeatures: AudioFeatures(
            bpm: 118,
            energy: 0.72,
            valence: 0.64,
            danceability: 0.68,
            acousticness: 0.12,
            instrumentalness: 0.0,
            liveness: 0.11,
            loudness: -5.4,
            key: 5,
            mode: 1
        ),
        similarityScore: 0.87,
        matchReasons: [.genre, .bpm, .vibe]
    )

    VStack {
        SongCard(song: sampleSong, rank: 1)
    }
    .padding()
    .background(Color.simiBackground)
}
