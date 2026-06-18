import Foundation

struct ProExportService {

    // MARK: - CSV

    static func csv(seed: Song, results: [SimilarSong]) -> (filename: String, data: Data) {
        var lines: [String] = []

        let header = [
            "Title", "Artist", "Genre", "Sub-Genre",
            "Similarity %", "BPM", "Valence", "Energy",
            "Danceability", "Acousticness", "Match Reasons", "Spotify URL",
        ].joined(separator: ",")
        lines.append(header)

        for song in results {
            let af = song.audioFeatures
            let row = [
                escaped(song.title),
                escaped(song.artist),
                escaped(song.genre.main),
                escaped(song.genre.sub ?? ""),
                "\(Int((song.similarityScore * 100).rounded()))",
                af.map { "\(Int($0.bpm.rounded()))" } ?? "",
                af.map { String(format: "%.2f", $0.valence) }      ?? "",
                af.map { String(format: "%.2f", $0.energy) }       ?? "",
                af.map { String(format: "%.2f", $0.danceability) } ?? "",
                af.map { String(format: "%.2f", $0.acousticness) } ?? "",
                escaped(song.matchReasons.map { $0.rawValue }.joined(separator: " · ")),
                escaped(song.spotifyURL),
            ].joined(separator: ",")
            lines.append(row)
        }

        let csvString = lines.joined(separator: "\n")
        let data = Data(csvString.utf8)
        let filename = "simi-export-\(dateStamp()).csv"
        return (filename, data)
    }

    // MARK: - JSON

    static func json(seed: Song, results: [SimilarSong]) -> (filename: String, data: Data) {
        let seedDict: [String: Any] = [
            "title":      seed.title,
            "artist":     seed.artist,
            "spotifyURL": seed.spotifyURL,
        ]

        let resultDicts: [[String: Any]] = results.map { song in
            let af = song.audioFeatures
            var d: [String: Any] = [
                "title":             song.title,
                "artist":            song.artist,
                "genre":             song.genre.main,
                "subGenre":          song.genre.sub ?? NSNull(),
                "similarityPercent": Int((song.similarityScore * 100).rounded()),
                "matchReasons":      song.matchReasons.map { $0.rawValue },
                "spotifyURL":        song.spotifyURL,
            ]
            if let af {
                d["bpm"]          = Int(af.bpm.rounded())
                d["valence"]      = af.valence
                d["energy"]       = af.energy
                d["danceability"] = af.danceability
                d["acousticness"] = af.acousticness
            } else {
                d["bpm"]          = NSNull()
                d["valence"]      = NSNull()
                d["energy"]       = NSNull()
                d["danceability"] = NSNull()
                d["acousticness"] = NSNull()
            }
            return d
        }

        let root: [String: Any] = [
            "seed":        seedDict,
            "exportedAt":  ISO8601DateFormatter().string(from: Date()),
            "resultCount": results.count,
            "results":     resultDicts,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let filename = "simi-export-\(dateStamp()).json"
        return (filename, data)
    }

    // MARK: - Helpers

    private static func escaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
