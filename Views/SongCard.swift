// SongCard.swift
// Simi — Music Discovery App
//
// Each recommended song appears as one of these cards in the results list.
// It shows the album art, title, artist, similarity %, match reasons,
// and a button to open the song on Spotify.

import SwiftUI

struct SongCard: View {

    let song: SimilarSong
    let rank: Int

    @State private var isExpanded = false  // Tap to expand for more detail

    var body: some View {
        VStack(spacing: 0) {

            // ── Main Row ──
            HStack(spacing: 14) {

                // Rank number
                Text("\(rank)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.simiSubtext)
                    .frame(width: 20)

                // Album art
                AsyncImage(url: URL(string: song.albumArt)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.simiCard
                        .overlay(Image(systemName: "music.note")
                            .foregroundColor(.simiSubtext)
                            .font(.system(size: 14)))
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Title + artist + match badges
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.simiText)
                        .lineLimit(1)

                    Text(song.artist)
                        .font(.system(size: 13))
                        .foregroundColor(.simiSubtext)
                        .lineLimit(1)

                    // Match reason pills
                    HStack(spacing: 6) {
                        ForEach(song.matchReasons.prefix(2), id: \.rawValue) { reason in
                            Text(reason.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.simiAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.simiAccent.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                // Similarity % + expand chevron
                VStack(alignment: .trailing, spacing: 4) {
                    // Similarity percentage
                    Text(song.similarityLabel)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(similarityColor(song.similarityScore))

                    // Similarity bar
                    SimilarityBar(score: song.similarityScore)
                        .frame(width: 44, height: 4)

                    // Platform links row
                    HStack(spacing: 8) {
                        // Spotify
                        Link(destination: URL(string: song.spotifyURL)!) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 16))
                                .foregroundColor(.green.opacity(0.9))
                        }
                        // Apple Music search
                        Link(destination: appleMusicURL(for: song)) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 15))
                                .foregroundColor(.pink.opacity(0.85))
                        }
                        // YouTube search
                        Link(destination: youtubeURL(for: song)) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 15))
                                .foregroundColor(.red.opacity(0.85))
                        }
                    }
                }
            }
            .padding(14)

            // ── Expanded Detail (tap to reveal) ──
            if isExpanded, let features = song.audioFeatures {
                Divider()
                    .background(Color.simiBorder)
                    .padding(.horizontal, 14)

                AudioFeaturesGrid(features: features)
                    .padding(14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.simiCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.simiBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Platform URL Builders
    // ──────────────────────────────────────────────

    func appleMusicURL(for song: SimilarSong) -> URL {
        let query = "\(song.title) \(song.artist)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://music.apple.com/search?term=\(query)")!
    }

    func youtubeURL(for song: SimilarSong) -> URL {
        let query = "\(song.title) \(song.artist)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.youtube.com/results?search_query=\(query)")!
    }

    // Color changes based on how good the match is
    func similarityColor(_ score: Double) -> Color {
        switch score {
        case 0.85...: return .simiGreen   // #3ddc84
        case 0.70...: return .simiAccent  // #38c0fa
        case 0.55...: return .simiPrimary // #7c5dfa
        default:      return .simiSubtext  // #8888aa
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Similarity Bar
// A small progress-bar-style indicator
// ──────────────────────────────────────────────

struct SimilarityBar: View {
    let score: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.simiSubtext.opacity(0.2))

                // Filled portion
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [.simiPrimary, .simiAccent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * score)
            }
        }
    }
}

// ──────────────────────────────────────────────
// MARK: - Audio Features Grid
// Shown when the user taps a card to expand it
// ──────────────────────────────────────────────

struct AudioFeaturesGrid: View {
    let features: AudioFeatures

    let items: [(label: String, value: String, icon: String)] = []

    var featureItems: [(label: String, value: String, icon: String)] {
        [
            ("BPM",          features.bpmFormatted,                  "metronome"),
            ("Energy",       percentLabel(features.energy),           "bolt.fill"),
            ("Mood",         percentLabel(features.valence),          "face.smiling"),
            ("Danceability", percentLabel(features.danceability),     "figure.dance"),
            ("Acoustic",     percentLabel(features.acousticness),     "guitars"),
            ("Key",          features.keyName,                       "music.quarternote.3"),
        ]
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(featureItems, id: \.label) { item in
                VStack(spacing: 4) {
                    Image(systemName: item.icon)
                        .font(.system(size: 14))
                        .foregroundColor(.simiAccent)
                    Text(item.value)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.simiText)
                    Text(item.label)
                        .font(.system(size: 10))
                        .foregroundColor(.simiSubtext)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.simiSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
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
