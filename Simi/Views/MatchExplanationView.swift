// MatchExplanationView.swift
// Simi — Music Discovery App
//
// Replaces AudioFeaturesGrid in the expanded SongCard section.
// Renders a pre-computed MatchExplanation as labeled rows of emotional descriptors.

import SwiftUI

struct MatchExplanationView: View {
    let explanation: MatchExplanation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            Text("Why this matches")
                .font(.simiMicro.weight(.semibold))
                .foregroundColor(.simiSubtext)
                .textCase(.uppercase)
                .tracking(1.2)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                ForEach(explanation.rows, id: \.label) { row in
                    HStack(alignment: .top) {
                        Text(row.label)
                            .font(.simiMicro)
                            .foregroundColor(.simiSubtext)
                            .frame(width: 110, alignment: .leading)
                        Text(row.descriptor)
                            .font(.simiCaption.weight(.semibold))
                            .foregroundColor(.simiText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(row.label): \(row.descriptor)")
                }

                if let bridge = explanation.genreBridgeLabel, !bridge.isEmpty {
                    HStack(alignment: .top) {
                        Text("Genre bridge")
                            .font(.simiMicro)
                            .foregroundColor(.simiAccent)
                            .frame(width: 110, alignment: .leading)
                        HStack(spacing: 4) {
                            Text(bridge)
                                .font(.simiCaption.weight(.semibold))
                                .foregroundColor(.simiAccent)
                            Text("🌉")
                                .font(.simiCaption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Genre bridge: \(bridge)")
                }
            }
        }
    }
}

#Preview("Full librosa") {
    MatchExplanationView(explanation: MatchExplanation(
        rows: [
            MatchExplanationRow(label: "Emotional weight", descriptor: "Same melancholic weight"),
            MatchExplanationRow(label: "Intensity",        descriptor: "Equally restrained"),
            MatchExplanationRow(label: "Key",              descriptor: "Both minor key"),
            MatchExplanationRow(label: "Groove feel",      descriptor: "Smooth and flowing"),
            MatchExplanationRow(label: "Sonic texture",    descriptor: "Similar tonal warmth"),
        ],
        genreBridgeLabel: "Jazz → Hip-Hop"
    ))
    .padding()
    .background(Color.simiBackground)
}

#Preview("Tag-estimated only") {
    MatchExplanationView(explanation: MatchExplanation(
        rows: [
            MatchExplanationRow(label: "Emotional weight", descriptor: "Same bittersweet edge"),
            MatchExplanationRow(label: "Intensity",        descriptor: "Equally driven"),
        ],
        genreBridgeLabel: nil
    ))
    .padding()
    .background(Color.simiBackground)
}
