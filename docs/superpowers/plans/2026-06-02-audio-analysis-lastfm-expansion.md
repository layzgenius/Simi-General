# Audio Analysis + Last.fm Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add on-device audio analysis from 30s preview clips for real energy/valence measurements on new releases and niche artists, expand Last.fm emotional tag coverage, and apply three housekeeping fixes.

**Architecture:** A new `PreviewAudioAnalyzer` actor downloads each song's `previewURL`, mixes down to mono, and extracts RMS energy + spectral centroid via native Accelerate vDSP — no external dependencies. It slots into `RecommendationEngine.fetchAudioFeaturesWithFallback` as step 1.5 (after Spotify fails, before tag estimation). Audio-measured features cache in the existing Supabase `audio_features_cache` table with `source: "preview_audio"` and a 14-day TTL, so repeat searches are instant. The Last.fm expansion requires no new infrastructure — only changes to `selectEmotionalQueries` in `LastFMService`.

**Tech Stack:** Swift, AVFoundation, Accelerate (vDSP), Supabase (existing REST cache), Last.fm API (existing)

---

## File Map

| File | Action | What changes |
|------|--------|--------------|
| `Simi/Simi/Services/PreviewAudioAnalyzer.swift` | **Create** | New actor: download + RMS + spectral centroid |
| `Simi/Simi/Services/RecommendationEngine.swift` | **Modify** | Add analyzer to services block; insert step 1.5 + merge logic in `fetchAudioFeaturesWithFallback` |
| `Simi/Simi/Services/SupabaseCacheService.swift` | **Modify** | Add `preview_audio: 14 days` TTL case in `storeFeatures` |
| `Simi/Simi/Services/LastFMService.swift` | **Modify** | Expand `directQueryable` (33→55 tags), raise cap 3→5, expand `mappedQueries` |
| `Simi/Simi/Services/MusicBrainzService.swift` | **Modify** | Add 1.1s defensive sleep before each request |
| `Simi/Simi/Views/SongCard.swift` | **Modify** | Preview duration 10s → 30s (one line) |
| `Simi/Simi/Assets.xcassets/*.dataset/` | **Delete** | Remove 13 accidental Swift source data assets |

---

## Task 1: Housekeeping (preview duration, MB sleep, assets cleanup)

These three changes are independent and carry zero risk. Do them first so they're out of the way.

**Files:**
- Modify: `Simi/Simi/Views/SongCard.swift` line 85
- Modify: `Simi/Simi/Services/MusicBrainzService.swift` — `findMBID` and `fetchRawTags`
- Delete: `Simi/Simi/Assets.xcassets/` — 13 `.dataset` subfolders

---

- [ ] **Step 1.1 — Extend preview clip to 30 seconds**

Open `Simi/Simi/Views/SongCard.swift`. Find line 85 (inside the album-art `Button` action):

```swift
// Before
previewPlayer.play(song: song, duration: 10)

// After
previewPlayer.play(song: song, duration: 30)
```

---

- [ ] **Step 1.2 — Add MusicBrainz rate-limit sleep**

Open `Simi/Simi/Services/MusicBrainzService.swift`.

In `findMBID`, add the sleep just before `var request = URLRequest(url: url)` (currently around line 32):
```swift
// MusicBrainz asks for ~1 req/sec
try? await Task.sleep(nanoseconds: 1_100_000_000)
var request = URLRequest(url: url)
```

In `fetchRawTags`, add the same sleep just before `var request = URLRequest(url: url)` (currently around line 68):
```swift
// MusicBrainz asks for ~1 req/sec
try? await Task.sleep(nanoseconds: 1_100_000_000)
var request = URLRequest(url: url)
```

---

- [ ] **Step 1.3 — Delete accidental Swift dataset folders from Assets**

These `.dataset` folders contain copies of Swift source files accidentally added as Custom Data Set assets. They bloat the bundle and are stale. The real source files in `Services/` and `Views/` are unaffected.

Run from the project root (`/Users/skips/Documents/Claude/Projects/Simi App`):
```bash
rm -rf "Simi/Simi/Assets.xcassets/Theme.dataset"
rm -rf "Simi/Simi/Assets.xcassets/SimiApp.dataset"
rm -rf "Simi/Simi/Assets.xcassets/Models"
rm -rf "Simi/Simi/Assets.xcassets/Views"
rm -rf "Simi/Simi/Assets.xcassets/Services"
rm -rf "Simi/Simi/Assets.xcassets/SETUP.dataset"
rm -rf "Simi/Simi/Assets.xcassets/Simi"
rm -rf "Simi/Simi/Assets.xcassets/research"
```

---

- [ ] **Step 1.4 — Build and verify**

In Xcode: **Product → Build (⌘B)**. Expected: clean build, zero errors. The deleted asset datasets are not source files — Xcode does not need them.

---

- [ ] **Step 1.5 — Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App"
git add Simi/Simi/Views/SongCard.swift \
        Simi/Simi/Services/MusicBrainzService.swift \
        "Simi/Simi/Assets.xcassets"
git commit -m "housekeeping: preview clip 30s, MB rate-limit sleep, remove accidental Swift assets"
```

---

## Task 2: Supabase — add preview_audio TTL case

One-line change so the cache knows how long to keep audio-analyzed features.

**Files:**
- Modify: `Simi/Simi/Services/SupabaseCacheService.swift` — `storeFeatures` method (~line 107)

---

- [ ] **Step 2.1 — Add the TTL case**

Open `Simi/Simi/Services/SupabaseCacheService.swift`. Find the `ttlDays` switch in `storeFeatures`:

```swift
// Before
let ttlDays: Int
switch source {
case "spotify":       ttlDays = 30
case "tag_estimated": ttlDays = 7
default:              ttlDays = 3   // bpm_only or unknown
}

// After
let ttlDays: Int
switch source {
case "spotify":        ttlDays = 30
case "preview_audio":  ttlDays = 14  // real measurement, but a 30s clip approximation — shorter than Spotify
case "tag_estimated":  ttlDays = 7
default:               ttlDays = 3   // bpm_only or unknown
}
```

---

- [ ] **Step 2.2 — Build and verify**

In Xcode: **Product → Build (⌘B)**. Expected: clean build.

---

- [ ] **Step 2.3 — Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App"
git add Simi/Simi/Services/SupabaseCacheService.swift
git commit -m "feat: add preview_audio 14-day TTL to Supabase audio features cache"
```

---

## Task 3: Last.fm emotional tag expansion

Expand `selectEmotionalQueries` from ~33 to ~55 recognizable subgenre tags, raise the query cap from 3 to 5, and add 6 new mood-tag mappings.

**Files:**
- Modify: `Simi/Simi/Services/LastFMService.swift` — `selectEmotionalQueries` method (~line 319)

---

- [ ] **Step 3.1 — Replace selectEmotionalQueries**

Open `Simi/Simi/Services/LastFMService.swift`. Find `selectEmotionalQueries`. Replace the entire method body (the `directQueryable`, `mappedQueries`, and loop) with:

```swift
private func selectEmotionalQueries(from rawTags: [String]) -> [String] {
    let directQueryable: Set<String> = [
        // Slow / romantic R&B
        "slow jam", "slow jams", "quiet storm", "neo-soul", "neo soul",
        // Indie / dream / bedroom
        "dream pop", "bedroom pop", "indie folk", "shoegaze", "chillwave", "indie pop",
        // Electronic chill
        "lo-fi", "lofi", "ambient", "chillhop", "vaporwave",
        // Electronic energetic
        "hyperpop", "future bass", "techno", "trance", "drum and bass",
        "dubstep", "breakcore", "hardstyle", "synthwave", "synth-pop",
        "house", "electropop",
        // Rock / alt / dark
        "post-rock", "post-punk", "emo", "darkwave", "math rock",
        "punk", "metal", "grunge", "indie rock", "alt-rock", "classic rock",
        // Soul / vintage / world
        "funk", "soul", "disco", "motown", "gospel", "bossa nova", "afrobeats", "reggae",
        // Hip-hop subgenres
        "boom bap", "cloud rap", "trap", "drill", "uk drill", "phonk",
        "grime", "alternative hip hop", "punk rap",
        // Acoustic / singer-songwriter
        "folk", "acoustic", "singer-songwriter",
        // Jazz / blues
        "jazz", "blues",
        // Global pop
        "k-pop", "j-pop",
    ]

    let mappedQueries: [String: String] = [
        // Existing
        "romantic":   "slow jam",
        "sensual":    "slow jam",
        "seductive":  "slow jam",
        "bedroom":    "bedroom pop",
        "chill":      "lo-fi",
        "chill out":  "lo-fi",
        "chillout":   "lo-fi",
        "melancholic": "melancholic",
        "sad":        "melancholic",
        "dark":       "darkwave",
        // New
        "aggressive": "metal",
        "heavy":      "metal",
        "party":      "disco",
        "workout":    "drum and bass",
        "summer":     "indie pop",
        "electronic": "synthwave",
    ]

    var queries: [String] = []
    var seen = Set<String>()
    for tag in rawTags {
        let q: String?
        if directQueryable.contains(tag) {
            q = tag
        } else {
            q = mappedQueries[tag]
        }
        guard let q, seen.insert(q).inserted else { continue }
        queries.append(q)
        if queries.count >= 5 { break }  // raised from 3 → 5
    }
    return queries
}
```

---

- [ ] **Step 3.2 — Build and verify**

In Xcode: **Product → Build (⌘B)**. Expected: clean build.

---

- [ ] **Step 3.3 — Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App"
git add Simi/Simi/Services/LastFMService.swift
git commit -m "feat: expand Last.fm emotional tag queries — 33→55 tags, cap 3→5, 6 new mood mappings"
```

---

## Task 4: Create PreviewAudioAnalyzer

New service file. Uses only AVFoundation (decode MP3) and Accelerate (vDSP FFT). No new package dependencies.

**Files:**
- Create: `Simi/Simi/Services/PreviewAudioAnalyzer.swift`

---

- [ ] **Step 4.1 — Create the file**

Create `/Users/skips/Documents/Claude/Projects/Simi App/Simi/Simi/Services/PreviewAudioAnalyzer.swift`:

```swift
// PreviewAudioAnalyzer.swift
// Simi — Music Discovery App
//
// Downloads a 30s preview clip and extracts two audio measurements using only
// native iOS frameworks — no external dependencies.
//
// RMS energy  → AudioFeatures.energy (reliable, maps to perceived loudness/intensity)
// Spectral centroid normalized to 500–8000 Hz → valence proxy
//   (bright/trebly = high, dark/bass-heavy = low)

import Foundation
import AVFoundation
import Accelerate

struct AudioMeasurements {
    let energy: Double              // 0–1, from RMS amplitude
    let spectralBrightness: Double  // 0–1, spectral centroid normalized to 500–8000 Hz band
}

actor PreviewAudioAnalyzer {

    static let shared = PreviewAudioAnalyzer()

    private let fftSize = 4096

    // Separate session with 8s timeout so a slow or missing preview never stalls the
    // main recommendation pipeline. Failures fall through to tag estimation.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 8
        cfg.timeoutIntervalForResource = 12
        return URLSession(configuration: cfg)
    }()

    // ──────────────────────────────────────────────
    // MARK: - Public API
    // ──────────────────────────────────────────────

    /// Downloads and analyzes a 30s preview clip. Returns nil on any failure.
    func analyze(previewURL urlString: String) async -> AudioMeasurements? {
        guard let url = URL(string: urlString) else { return nil }

        guard let (localURL, _) = try? await session.download(from: url) else {
            print("⚠️ AudioAnalyzer: download failed for preview")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: localURL) }

        guard let audioFile = try? AVAudioFile(forReading: localURL) else {
            print("⚠️ AudioAnalyzer: cannot open downloaded audio file")
            return nil
        }

        // AVAudioFile.processingFormat is always non-interleaved 32-bit float at the file's
        // native sample rate. It decodes MP3/AAC automatically — no manual codec needed.
        let sampleRate  = audioFile.fileFormat.sampleRate
        let frameCount  = AVAudioFrameCount(min(audioFile.length, Int64(sampleRate * 31)))  // cap at ~30s

        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount),
              (try? audioFile.read(into: buffer)) != nil,
              buffer.frameLength > 0,
              let channelData = buffer.floatChannelData else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        let sampleCount  = Int(buffer.frameLength)

        // Mix all channels down to mono by averaging
        var mono = [Float](repeating: 0, count: sampleCount)
        for c in 0..<channelCount {
            let ch = channelData[c]
            for i in 0..<sampleCount { mono[i] += ch[i] }
        }
        if channelCount > 1 {
            var scale = Float(1.0 / Double(channelCount))
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(sampleCount))
        }

        // ── RMS Energy ──
        // vDSP_rmsqv computes sqrt(mean(x²)) — the standard RMS formula.
        // Loud pop/rock peaks at ~0.3–0.5 RMS; quiet ambient is ~0.05–0.15.
        // Mapping 0–0.5 → 0–1 and clamping produces an intuitive 0–1 energy scale.
        var rms: Float = 0
        vDSP_rmsqv(mono, 1, &rms, vDSP_Length(sampleCount))
        let energy = Double(min(rms / 0.5, 1.0))

        // ── Spectral Brightness ──
        let brightness = computeSpectralBrightness(
            samples: mono, sampleCount: sampleCount, sampleRate: sampleRate
        )

        print("🎵 Audio analysis: energy=\(String(format: "%.2f", energy)) brightness=\(String(format: "%.2f", brightness))")
        return AudioMeasurements(energy: energy, spectralBrightness: brightness)
    }

    // ──────────────────────────────────────────────
    // MARK: - Spectral Analysis
    // ──────────────────────────────────────────────

    private func computeSpectralBrightness(
        samples: [Float],
        sampleCount: Int,
        sampleRate: Double
    ) -> Double {
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return 0.5 }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hann window reduces spectral leakage so centroid readings are stable
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Average the centroid across ~16 evenly spaced windows.
        // One window is a snapshot; averaging across the clip gives a representative reading.
        let stride = max(fftSize, sampleCount / 16)
        var centroids: [Double] = []
        var offset = 0
        while offset + fftSize <= sampleCount {
            if let c = spectralCentroid(
                at: offset, in: samples,
                window: window, fftSetup: fftSetup, log2n: log2n, sampleRate: sampleRate
            ) {
                centroids.append(c)
            }
            offset += stride
        }

        guard !centroids.isEmpty else { return 0.5 }
        let avgCentroid = centroids.reduce(0, +) / Double(centroids.count)

        // Normalize over the perceptual brightness band 500–8000 Hz.
        // Centroid ≤ 500 Hz → 0.0 (very dark/bass-heavy), ≥ 8000 Hz → 1.0 (very bright/trebly).
        // This range is a frequency measure — it's correct regardless of sample rate.
        let normalized = (avgCentroid - 500.0) / (8000.0 - 500.0)
        return max(0.0, min(1.0, normalized))
    }

    /// Spectral centroid for one FFT window. Returns nil for silent frames.
    private func spectralCentroid(
        at offset: Int,
        in samples: [Float],
        window: [Float],
        fftSetup: FFTSetup,
        log2n: vDSP_Length,
        sampleRate: Double
    ) -> Double? {
        // Extract frame and apply Hann window
        var frame = Array(samples[offset..<(offset + fftSize)])
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(fftSize))

        // Pack real samples into split complex for vDSP_fft_zrip.
        // Reinterprets the Float array as DSPComplex pairs: frame[2n] → realp[n], frame[2n+1] → imagp[n].
        var realParts = [Float](repeating: 0, count: fftSize / 2)
        var imagParts = [Float](repeating: 0, count: fftSize / 2)
        var splitComplex = DSPSplitComplex(realp: &realParts, imagp: &imagParts)
        frame.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                vDSP_ctoz($0, 1, &splitComplex, 1, vDSP_Length(fftSize / 2))
            }
        }

        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        // Magnitude spectrum
        var mags = [Float](repeating: 0, count: fftSize / 2)
        vDSP_zvabs(&splitComplex, 1, &mags, 1, vDSP_Length(fftSize / 2))

        // Spectral centroid = Σ(freq_i × mag_i) / Σ(mag_i)
        // freq_i = i × (sampleRate / fftSize) — uses actual sample rate from AVAudioFile,
        // NOT a hardcoded 44100. Correct for 22050, 44100, 48000 Hz files.
        let binHz = sampleRate / Double(fftSize)
        var weightedSum = 0.0, totalMag = 0.0
        for i in 0..<(fftSize / 2) {
            let m = Double(mags[i])
            weightedSum += Double(i) * binHz * m
            totalMag    += m
        }
        return totalMag > 0 ? weightedSum / totalMag : nil
    }
}
```

---

- [ ] **Step 4.2 — Add the file to the Xcode project**

In Xcode's Project Navigator: right-click the **Services** group → **Add Files to "Simi"** → select `PreviewAudioAnalyzer.swift` → ensure "Simi" target checkbox is ticked → **Add**.

If `Accelerate.framework` isn't already linked: go to the target's **Build Phases → Link Binary With Libraries** → click **+** → add `Accelerate.framework`.

---

- [ ] **Step 4.3 — Build**

In Xcode: **Product → Build (⌘B)**. Expected: clean build. If you see `cannot find type 'DSPComplex'` or `use of undeclared 'vDSP_fft_zrip'`: confirm Accelerate.framework is linked (Step 4.2).

---

- [ ] **Step 4.4 — Smoke-test the analyzer in isolation**

Temporarily add this call in `RecommendationEngine.findSimilarSongs(for:)`, right after `self.sourceSong = song` (single-URL path, around line 175):

```swift
// TEMP smoke test — remove before Task 5
if let previewURLString = song.previewURL {
    let m = await PreviewAudioAnalyzer.shared.analyze(previewURL: previewURLString)
    print("🧪 Smoke: energy=\(m?.energy as Any) brightness=\(m?.spectralBrightness as Any)")
}
```

Run on device or simulator. Search for any recent pop track. Verify the console prints something like:
```
🎵 Audio analysis: energy=0.43 brightness=0.61
🧪 Smoke: energy=Optional(0.43) brightness=Optional(0.61)
```

Then **remove the smoke test** before proceeding.

---

- [ ] **Step 4.5 — Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App"
git add Simi/Simi/Services/PreviewAudioAnalyzer.swift
git commit -m "feat: add PreviewAudioAnalyzer — RMS energy + spectral centroid via AVFoundation + Accelerate"
```

---

## Task 5: Integrate PreviewAudioAnalyzer into RecommendationEngine

Wire the analyzer into `fetchAudioFeaturesWithFallback` as step 1.5. Add merge logic so audio measurements override or blend with tag-estimated values. Cache with `source: "preview_audio"`.

**Files:**
- Modify: `Simi/Simi/Services/RecommendationEngine.swift`

---

- [ ] **Step 5.1 — Add the analyzer instance to the services block**

In `RecommendationEngine.swift`, find the `// MARK: - Services` section (around line 44). Add:

```swift
private let previewAnalyzer  = PreviewAudioAnalyzer.shared
```

Place it below the existing `private let itunesService` line so the ordering stays logical.

---

- [ ] **Step 5.2 — Insert step 1.5: audio analysis**

In `fetchAudioFeaturesWithFallback`, find the disabled AcousticBrainz comment block (around line 631–638):

```swift
// 2. AcousticBrainz — DISABLED (deprecated 2022, adds 2-4s latency for sparse coverage)
//    Re-enable if Spotify Extended Quota Mode is granted and AB coverage improves.
// if let mbid = await musicBrainzService.findMBID(title: song.title, artist: song.artist),
// ...
```

Insert the following block immediately **after** that comment block and **before** the `// 3. BPM` line:

```swift
// 2. Preview audio analysis — real RMS energy + spectral brightness from the 30s clip.
//    Runs before tag estimation so new releases with zero Last.fm coverage get measured
//    values instead of neutral 0.5/0.5 defaults. Falls through gracefully on any error.
var audioMeasurements: AudioMeasurements? = nil
if let previewURLString = song.previewURL {
    print("🎵 Analyzing preview audio for \(song.title)…")
    audioMeasurements = await previewAnalyzer.analyze(previewURL: previewURLString)
}
```

---

- [ ] **Step 5.3 — Merge audio measurements with tag-estimated features**

In `fetchAudioFeaturesWithFallback`, find the tag-estimation success block (around line 684):

```swift
if let estimated = await estimateFeaturesFromTags(rawTags, bpm: bpm) {
    print("🏷️ Tag-estimated features for source \"\(song.title)\": \(rawTags.prefix(3).joined(separator: ", "))")
    Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: estimated, source: "tag_estimated") }
    return estimated
}
```

Replace it with:

```swift
if let estimated = await estimateFeaturesFromTags(rawTags, bpm: bpm) {
    print("🏷️ Tag-estimated features for source \"\(song.title)\": \(rawTags.prefix(3).joined(separator: ", "))")

    if let audio = audioMeasurements {
        // Audio energy is authoritative — RMS is reliable regardless of genre.
        // Valence: blend audio spectral brightness (0.4) with tag valence (0.6).
        // Tags carry genre context (e.g. jazz centroid can be mid-high but valence is lower)
        // that pure frequency analysis misses.
        let blendedValence = audio.spectralBrightness * 0.4 + estimated.valence * 0.6
        let merged = AudioFeatures(
            bpm:              estimated.bpm,
            energy:           audio.energy,
            valence:          blendedValence,
            danceability:     estimated.danceability,   // tags handle this better than audio alone
            acousticness:     estimated.acousticness,
            instrumentalness: estimated.instrumentalness,
            liveness:         estimated.liveness,
            loudness:         estimated.loudness,
            key:              estimated.key,
            mode:             estimated.mode,
            isEstimated:      false                     // key dimensions are now measured
        )
        print("🎵 Merged audio+tag features for \"\(song.title)\"")
        Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: merged, source: "preview_audio") }
        return merged
    }

    Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: estimated, source: "tag_estimated") }
    return estimated
}

// Tag estimation found nothing — use audio measurements alone if available.
// This covers the key case: a new release with no Last.fm play history.
if let audio = audioMeasurements {
    print("🎵 Audio-only features for \"\(song.title)\" (no tag data)")
    let audioOnly = AudioFeatures(
        bpm:              bpm,                         // 0 if all BPM sources also failed
        energy:           audio.energy,
        valence:          audio.spectralBrightness,    // no tag context to blend with
        danceability:     0.5,                         // no signal — neutral placeholder
        acousticness:     0.0,
        instrumentalness: 0.0,
        liveness:         0.0,
        loudness:         -10.0,
        key:              0,
        mode:             1,
        isEstimated:      false                        // energy + valence are measured
    )
    Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: audioOnly, source: "preview_audio") }
    return audioOnly
}
```

> **Note:** This replacement goes between the tag-estimation block and the existing `// 5. BPM only` block. The BPM-only and neutral-defaults blocks below remain unchanged — they handle the case where audio analysis also failed or returned nil.

---

- [ ] **Step 5.4 — Build**

In Xcode: **Product → Build (⌘B)**. Expected: clean build. Swift should resolve `AudioMeasurements` and `PreviewAudioAnalyzer` from Task 4.

---

- [ ] **Step 5.5 — Manual test: new release**

Run on device or simulator. Search for any song released in the past 3 months (likely has no AcousticBrainz data, may have sparse Last.fm tags). Watch the console. Expected sequence:

```
⚠️ Spotify unavailable — fetching BPM for [song]
🎵 Analyzing preview audio for [song]…
🎵 Audio analysis: energy=0.XX brightness=0.XX
✅ GetSongBPM XX: [song]
🏷️ Tag-estimated features for source "[song]": ...
🎵 Merged audio+tag features for "[song]"
```

Verify the vibe label on the source song reflects reality (a loud, dark track should show "Intense & Dark", not "Warm & Groovy").

---

- [ ] **Step 5.6 — Manual test: cache hit on repeat search**

Search the same song again immediately. Expected: the console shows `✅ Supabase feature cache hit: "[song]"` and nothing from the audio analyzer. The analyzer must not run a second time for the same song.

---

- [ ] **Step 5.7 — Manual test: song without a preview URL**

Some tracks (niche artists, regional releases) have `previewURL = nil`. Search one. Expected: the `if let previewURLString = song.previewURL` guard fires, `audioMeasurements` stays nil, and the rest of the feature-fetch chain runs as before. No crash, no behavior change.

---

- [ ] **Step 5.8 — Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App"
git add Simi/Simi/Services/RecommendationEngine.swift
git commit -m "feat: integrate PreviewAudioAnalyzer as step 1.5 in feature-fetch chain — audio+tag merge with Supabase caching"
```

---

## Done

All five tasks complete. The feature-fetch priority chain now reads:

```
Step 0  Supabase cache lookup                       (existing — returns early for any cached source)
Step 1  Spotify audio features                      (existing — usually unavailable without quota)
Step 2  Preview audio analysis              ← NEW   (real energy + spectral brightness)
Step 3  GetSongBPM → Deezer BPM                    (existing)
Step 4  Last.fm/MusicBrainz tag estimation          (existing — now with 5 emotional queries, cap raised)
Step 4b Merge audio + tag features          ← NEW   (audio energy authoritative; valence 40/60 blend)
Step 4c Audio-only path                     ← NEW   (no tags? use audio measurements directly)
Step 5  BPM-only fallback                           (existing)
Step 6  Neutral defaults 0.5/0.5                    (existing — only if all sources fail)
```
