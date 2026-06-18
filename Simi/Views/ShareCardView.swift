// ShareCardView.swift
// Simi — Music Discovery App
//
// Renders a static share card image for a matched song.
// Used with ImageRenderer to produce a UIImage for the system share sheet.

import SwiftUI

// ──────────────────────────────────────────────
// MARK: - Share Card View
// ──────────────────────────────────────────────

struct ShareCardView: View {
    let song: SimilarSong
    let sourceSong: Song?
    let matchArtwork: UIImage?
    let seedArtwork: UIImage?

    private var descriptor: String {
        song.matchExplanation?.rows.first?.descriptor ?? "Similar emotional feel"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Album art with gradient overlay ──
            ZStack(alignment: .bottom) {
                Group {
                    if let art = matchArtwork {
                        Image(uiImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.simiSurface
                    }
                }
                .frame(width: 390, height: 260)
                .clipped()

                LinearGradient(
                    colors: [.clear, Color.simiBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
            }
            .frame(width: 390, height: 260)

            // ── Text section ──
            VStack(alignment: .leading, spacing: 6) {
                Text(song.title)
                    .font(.simiBody.weight(.bold))
                    .foregroundColor(.simiText)
                    .lineLimit(2)

                Text(song.artist)
                    .font(.simiBody)
                    .foregroundColor(.simiSubtext)
                    .lineLimit(1)

                Spacer().frame(height: 4)

                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.simiSubtext.opacity(0.2))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(
                                    colors: [.simiPrimary, .simiAccent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: geo.size.width * song.similarityScore)
                        }
                    }
                    .frame(width: 60, height: 4)

                    Text(song.similarityLabel)
                        .font(.simiMicro.weight(.bold))
                        .foregroundColor(.simiAccent)
                }

                Spacer().frame(height: 2)

                Text("\"\(descriptor)\"")
                    .font(.simiCaption.italic())
                    .foregroundColor(.simiText)
                    .lineLimit(2)

                Spacer().frame(height: 8)

                Divider()
                    .background(Color.simiBorder)

                Spacer().frame(height: 6)

                HStack {
                    if let seed = sourceSong {
                        Text("From: \(seed.title) · \(seed.artist)")
                            .font(.simiMicro)
                            .foregroundColor(.simiSubtext)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("simi")
                        .font(.simiCaption.weight(.bold))
                        .foregroundColor(.simiAccent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Spacer()
        }
        .frame(width: 390, height: 560)
        .background(Color.simiBackground)
    }

    // ──────────────────────────────────────────────
    // MARK: - Artwork fetch
    // ──────────────────────────────────────────────

    static func fetchArtwork(_ urlString: String) async -> UIImage? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}

// ──────────────────────────────────────────────
// MARK: - Activity Sheet
// ──────────────────────────────────────────────

struct ActivitySheetView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// ──────────────────────────────────────────────
// MARK: - Preview
// ──────────────────────────────────────────────

#Preview {
    ShareCardView(
        song: SimilarSong(
            id: "preview",
            title: "Midnight Rain",
            artist: "Taylor Swift",
            albumArt: "",
            spotifyURL: "https://open.spotify.com",
            previewURL: nil,
            genre: Genre(main: "Pop", sub: "Indie Pop"),
            audioFeatures: AudioFeatures(
                bpm: 118, energy: 0.72, valence: 0.64,
                danceability: 0.68, acousticness: 0.12,
                instrumentalness: 0.0, liveness: 0.11,
                loudness: -5.4, key: 5, mode: 1
            ),
            similarityScore: 0.87,
            matchReasons: [.vibe],
            matchExplanation: MatchExplanation(
                rows: [MatchExplanationRow(label: "Emotional weight", descriptor: "Same melancholic weight")],
                genreBridgeLabel: nil
            )
        ),
        sourceSong: nil,
        matchArtwork: nil,
        seedArtwork: nil
    )
}
