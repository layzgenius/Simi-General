# Candidate Pool Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two always-on parallel candidate sources — Last.fm artist-similar tracks and genre+mood compound tag queries — to surface niche music that the existing `track.getSimilar` and bare mood-tag paths miss.

**Architecture:** Single file change (`RecommendationEngine.swift`). Task 1 adds `fetchArtistSimilarCandidates(artist:)` — a new private method that fans out to similar artists' top tracks concurrently — and wires it into `expandedTracks` in both `findSimilarSongs` variants. Task 2 extends `deriveAudioQueryTags(from:genreTags:)` to generate compound genre+mood strings (e.g., "late night neo soul") by wrapping the existing mood logic in a closure, then appending compounds at the end; both call sites are updated to await `genres` before the audioTags computation so the genre context is available.

**Tech Stack:** Swift 5.9, SwiftUI, `@MainActor class`, `async let`, `withTaskGroup`, `LastFMService` (existing — no changes)

## Global Constraints

- Modify only `Simi/Simi/Services/RecommendationEngine.swift` — no changes to `LastFMService.swift` or any other file
- Do NOT modify `mergeAndScore()`, `enrichWithABFeatures()`, `computeSimilarity()`, or any scoring logic
- `RecommendationEngine` is `@MainActor class` — all new methods are implicitly on the main actor; `withTaskGroup` inside them is fine, no `nonisolated` or `Task.detached` needed
- `fetchSimilarArtists(artist:)` throws — wrap in `(try? await ...) ?? []`
- `fetchArtistTopTracks(artist:)` does NOT throw — call directly, no `try?`
- `Genre` struct: `main: String`, `sub: String?` — top genre label = `genreTags.first?.sub ?? genreTags.first?.main`
- SourceKit false positives ("Cannot find type X in scope") are expected and ignorable; all Xcode builds succeed 0 errors/0 warnings
- `SimilarSong` is a struct — all mutations via index reassignment (not in scope here)

---

### Task 1: `fetchArtistSimilarCandidates` + wiring in both `findSimilarSongs` variants

**Files:**
- Modify: `Simi/Simi/Services/RecommendationEngine.swift`

**Interfaces:**
- Consumes:
  - `lastFMService.fetchSimilarArtists(artist: String) async throws -> [String]` (returns artist name strings)
  - `lastFMService.fetchArtistTopTracks(artist: String) async -> [(title: String, artist: String)]`
  - `Self.mergeTracks(primary:secondary:) -> [(title: String, artist: String)]` (already exists)
- Produces:
  - `private func fetchArtistSimilarCandidates(artist: String) async -> [(title: String, artist: String)]`
  - `async let artistSimilarTask` wired in both `findSimilarSongs` variants
  - `artistSimilarCandidates` added to `expandedTracks` merge in both variants

- [ ] **Step 1: Add `fetchArtistSimilarCandidates` after `fetchListenBrainzTracks`**

In `RecommendationEngine.swift`, find the closing `}` of `fetchListenBrainzTracks` (currently at line ~139). Insert the new method immediately after it:

```swift
    /// Fetches top tracks from up to 8 artists similar to the given artist.
    /// Always-on parallel source — not a fallback. Returns up to ~40 deduplicated (title, artist) pairs.
    private func fetchArtistSimilarCandidates(artist: String) async -> [(title: String, artist: String)] {
        let similarArtists = (try? await lastFMService.fetchSimilarArtists(artist: artist)) ?? []
        guard !similarArtists.isEmpty else { return [] }
        var tracks: [(title: String, artist: String)] = []
        await withTaskGroup(of: [(title: String, artist: String)].self) { group in
            for similarArtist in similarArtists.prefix(8) {
                group.addTask {
                    await self.lastFMService.fetchArtistTopTracks(artist: similarArtist)
                }
            }
            for await artistTracks in group {
                tracks += artistTracks
            }
        }
        var seen = Set<String>()
        return tracks.filter { t in
            seen.insert("\(t.title)|\(t.artist)".lowercased()).inserted
        }
    }
```

- [ ] **Step 2: Wire `artistSimilarTask` into `findSimilarSongs(for urlString:)` — parallel block**

Find the initial `async let` block in `findSimilarSongs(for urlString:)` (currently lines ~249–253):

```swift
            async let featuresTask      = fetchAudioFeaturesWithFallback(song: song)
            async let tagsEarlyTask     = fetchRawTagsCached(song: song)
            async let genresTask        = fetchGenresWithFallback(title: song.title, artist: song.artist)
            async let similarTracksTask = fetchSimilarTracksWithCache(title: song.title, artist: song.artist)
            async let lbTask            = fetchListenBrainzTracks(title: song.title, artist: song.artist)
```

Replace with:

```swift
            async let featuresTask      = fetchAudioFeaturesWithFallback(song: song)
            async let tagsEarlyTask     = fetchRawTagsCached(song: song)
            async let genresTask        = fetchGenresWithFallback(title: song.title, artist: song.artist)
            async let similarTracksTask = fetchSimilarTracksWithCache(title: song.title, artist: song.artist)
            async let lbTask            = fetchListenBrainzTracks(title: song.title, artist: song.artist)
            async let artistSimilarTask = fetchArtistSimilarCandidates(artist: song.artist)
```

- [ ] **Step 3: Wire `artistSimilarTask` into `findSimilarSongs(for urlString:)` — Phase 2 + expandedTracks**

Find the Phase 2 block in the URL variant (currently lines ~325–342):

```swift
            // Phase 2: await remaining candidates
            let genres           = await genresTask
            let spotifyRecs      = (try? await spotifyRecsTask) ?? []
            let vectorCandidates = await vectorTask
            let dclapCandidates  = await dclapTask
            self.detectedGenres  = genres
            self.lastGenres      = genres

            let genreTagCandidates = await genreTagCandidatesTask
            let audioTagCandidates = await audioTagCandidatesTask.value
            let tagCandidates      = Self.mergeTracks(primary: genreTagCandidates, secondary: audioTagCandidates)
            let expandedTracks     = Self.mergeTracks(
                primary: Self.mergeTracks(primary: lastFMTracks, secondary: tagCandidates),
                secondary: Self.mergeTracks(
                    primary: Self.mergeTracks(primary: lbTracks, secondary: vectorCandidates),
                    secondary: dclapCandidates
                )
            )
```

Replace with:

```swift
            // Phase 2: await remaining candidates
            let genres               = await genresTask
            let spotifyRecs          = (try? await spotifyRecsTask) ?? []
            let vectorCandidates     = await vectorTask
            let dclapCandidates      = await dclapTask
            let artistSimilarCandidates = await artistSimilarTask
            self.detectedGenres  = genres
            self.lastGenres      = genres

            let genreTagCandidates = await genreTagCandidatesTask
            let audioTagCandidates = await audioTagCandidatesTask.value
            let tagCandidates      = Self.mergeTracks(primary: genreTagCandidates, secondary: audioTagCandidates)
            let expandedTracks     = Self.mergeTracks(
                primary: Self.mergeTracks(primary: lastFMTracks, secondary: tagCandidates),
                secondary: Self.mergeTracks(
                    primary: Self.mergeTracks(primary: lbTracks, secondary: vectorCandidates),
                    secondary: Self.mergeTracks(primary: dclapCandidates, secondary: artistSimilarCandidates)
                )
            )
```

- [ ] **Step 4: Wire `artistSimilarTask` into `findSimilarSongs(title:artist:)` — parallel block**

Find the initial `async let` block in `findSimilarSongs(title:artist:)` (currently lines ~469–473):

```swift
            async let featuresTask      = fetchAudioFeaturesWithFallback(song: song)
            async let tagsEarlyTask     = fetchRawTagsCached(song: song)
            async let genresTask        = fetchGenresWithFallback(title: song.title, artist: song.artist)
            async let similarTracksTask = fetchSimilarTracksWithCache(title: song.title, artist: song.artist)
            async let lbTask            = fetchListenBrainzTracks(title: song.title, artist: song.artist)
```

Replace with:

```swift
            async let featuresTask      = fetchAudioFeaturesWithFallback(song: song)
            async let tagsEarlyTask     = fetchRawTagsCached(song: song)
            async let genresTask        = fetchGenresWithFallback(title: song.title, artist: song.artist)
            async let similarTracksTask = fetchSimilarTracksWithCache(title: song.title, artist: song.artist)
            async let lbTask            = fetchListenBrainzTracks(title: song.title, artist: song.artist)
            async let artistSimilarTask = fetchArtistSimilarCandidates(artist: song.artist)
```

- [ ] **Step 5: Wire `artistSimilarTask` into `findSimilarSongs(title:artist:)` — Phase 2 + expandedTracks**

Find the Phase 2 block in the text-mode variant (currently lines ~540–557). Note: `dclapCandidates2` and `dclapTask2` (not `dclapCandidates`/`dclapTask`):

```swift
            // Phase 2: await remaining candidates
            let genres           = await genresTask
            let spotifyRecs      = (try? await spotifyRecsTask) ?? []
            let vectorCandidates = await vectorTask
            let dclapCandidates2 = await dclapTask2
            self.detectedGenres  = genres
            self.lastGenres      = genres

            let genreTagCandidates = await genreTagCandidatesTask
            let audioTagCandidates = await audioTagCandidatesTask.value
            let tagCandidates      = Self.mergeTracks(primary: genreTagCandidates, secondary: audioTagCandidates)
            let expandedTracks     = Self.mergeTracks(
                primary: Self.mergeTracks(primary: lastFMTracks, secondary: tagCandidates),
                secondary: Self.mergeTracks(
                    primary: Self.mergeTracks(primary: lbTracks, secondary: vectorCandidates),
                    secondary: dclapCandidates2
                )
            )
```

Replace with:

```swift
            // Phase 2: await remaining candidates
            let genres               = await genresTask
            let spotifyRecs          = (try? await spotifyRecsTask) ?? []
            let vectorCandidates     = await vectorTask
            let dclapCandidates2     = await dclapTask2
            let artistSimilarCandidates = await artistSimilarTask
            self.detectedGenres  = genres
            self.lastGenres      = genres

            let genreTagCandidates = await genreTagCandidatesTask
            let audioTagCandidates = await audioTagCandidatesTask.value
            let tagCandidates      = Self.mergeTracks(primary: genreTagCandidates, secondary: audioTagCandidates)
            let expandedTracks     = Self.mergeTracks(
                primary: Self.mergeTracks(primary: lastFMTracks, secondary: tagCandidates),
                secondary: Self.mergeTracks(
                    primary: Self.mergeTracks(primary: lbTracks, secondary: vectorCandidates),
                    secondary: Self.mergeTracks(primary: dclapCandidates2, secondary: artistSimilarCandidates)
                )
            )
```

- [ ] **Step 6: Build to verify 0 errors/0 warnings**

Build the Simi scheme:

```bash
xcodebuild -project "/Users/skips/Documents/Claude/Projects/Simi App/Simi/Simi.xcodeproj" \
  -scheme Simi \
  -destination "generic/platform=iOS Simulator" \
  build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED` with 0 errors, 0 warnings. SourceKit diagnostics ("Cannot find type X in scope") in the raw output are false positives — ignorable as long as `BUILD SUCCEEDED` appears.

- [ ] **Step 7: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi"
git add Simi/Services/RecommendationEngine.swift
git commit -m "feat: artist-similar always-on parallel candidate source"
```

---

### Task 2: `deriveAudioQueryTags` compound tags + call site updates

**Files:**
- Modify: `Simi/Simi/Services/RecommendationEngine.swift`

**Interfaces:**
- Consumes (from Task 1): `genres: [Genre]` — already awaited in Phase 2; this task moves that await earlier so it's available at the `deriveAudioQueryTags` call site
- Produces:
  - `private func deriveAudioQueryTags(from features: AudioFeatures, genreTags: [Genre] = []) -> [String]` — updated signature; default `[]` keeps the multi-seed path at line ~706 working without changes
  - Returns up to 4 tags: original bare tags + up to 2 compound genre+mood strings

- [ ] **Step 1: Replace `deriveAudioQueryTags` with the updated implementation**

Find the entire `deriveAudioQueryTags` function (lines ~2111–2173). Replace it with the complete updated version below. The only logic changes are: (a) the existing mood-branch tree is wrapped in `let baseTags: [String] = { ... }()` — its internal logic is preserved character-for-character; (b) compound tags are appended after:

```swift
    private func deriveAudioQueryTags(from features: AudioFeatures, genreTags: [Genre] = []) -> [String] {
        guard !features.isEstimated else { return [] }

        // Use VALENCE as the primary axis — it's derived from spectral brightness which
        // correctly captures dark/warm vs bright/intense emotional quality.
        // Audio RMS energy is NOT used here: it measures physical loudness, not emotional
        // intensity (e.g. Tiramisu has 0.82 RMS due to 808 bass but feels dreamy and dark).
        let baseTags: [String] = {
            let v = features.valence

            if v < 0.30 {
                // Major-key: low valence is a measurement artifact (slow tempo penalty, low spectral
                // brightness) not an emotional one — a major-key ballad is never genuinely "sad/dark".
                if features.mode == 1 {
                    if features.energy < 0.55 { return ["mellow"] }
                    if features.danceability > 0.40 { return ["groove"] }
                    return ["smooth"]
                }
                return ["sad", "dark"]                            // very dark: grief, heavy, bleak
            }
            // Major-key songs in the mid-dark valence range feel warm/mellow, not melancholic.
            // Low valence in a major-key song is often a measurement artifact (slow tempo, low
            // spectral brightness) rather than genuine sadness — e.g. DeBarge "I Like It":
            // librosa reads energy=0.47, valence=0.45 but the song is a warm groovy soul track.
            if v < 0.45 {
                if features.mode == 1 {
                    if features.energy < 0.55 { return ["mellow"] }
                    if features.danceability > 0.40 { return ["groove"] }
                    return ["smooth"]
                }
                return ["late night", "melancholic"]              // dark-warm: After Hours
            }
            if v < 0.55 {
                if features.mode == 1 {
                    if features.energy < 0.55 { return ["mellow"] }
                    if features.danceability > 0.40 { return ["groove"] }
                    return ["smooth"]
                }
                return ["melancholic"]                            // neutral-dark: introspective
            }
            if v < 0.65 {
                // High energy + low danceability = smooth/melodic trap (Tiramisu archetype)
                // Pulls R&B/melodic-trap candidates rather than bright indie/pop
                if features.energy > 0.60 && features.danceability < 0.62 { return ["smooth", "late night"] }
                return ["feel good"]                              // warm: genuinely danceable or low-energy
            }
            // v >= 0.65 — bright/warm spectrum. Gate on energy before calling it "upbeat":
            // e.g. Redbone (energy=0.44, valence=0.72) is warm & smooth — NOT hype pop/dance.
            if features.energy < 0.50 {
                // "feel good" requires upbeat tempo AND major key.
                // Minor key OR slow BPM → "late night" (Redbone: F minor, 86 BPM, valence=0.72)
                if features.mode == 0 || features.bpm < 100 {
                    return ["late night"]
                }
                if features.danceability > 0.50 { return ["feel good", "groove"] }
                return ["smooth", "feel good"]
            }
            if features.energy < 0.68 {
                // Mid energy + bright = feel-good but not hype
                if features.danceability > 0.65 { return ["feel good", "groove"] }
                return ["feel good"]
            }
            return ["upbeat", "energetic"]                        // genuinely bright AND energetic: pop, dance
        }()

        // Append genre+mood compound queries (e.g. "late night neo soul", "melancholic dream pop").
        // Compound tags target a genre-specific slice of Last.fm's tag index, reaching niche catalogs
        // that bare mood tags miss. Sub-genre beats main (e.g. "dream pop" > "indie pop").
        guard !baseTags.isEmpty,
              let genreLabel = genreTags.first?.sub ?? genreTags.first?.main,
              !genreLabel.isEmpty else {
            return baseTags
        }
        let compounds = baseTags.prefix(2).map { "\($0) \(genreLabel)" }
        return baseTags + compounds
    }
```

- [ ] **Step 2: Update `findSimilarSongs(for urlString:)` — await `genres` early and pass to call site**

In the URL variant, find the high-energy-markers + `audioTags` block (currently lines ~287–292). It currently looks like:

```swift
            let highEnergyMarkers1 = ["metal", "hard rock", "punk", "thrash", "hardcore", "grunge"]
            let genreSaysLoud1 = earlyTags.contains { tag in highEnergyMarkers1.contains { tag.lowercased().contains($0) } }
            let audioTags = (genreSaysLoud1 && sourceFeatures.energy < 0.45)
                ? []
                : deriveAudioQueryTags(from: sourceFeatures).filter { !$0.isEmpty }
```

Replace with (adds `genres` await here, passes it to `deriveAudioQueryTags`):

```swift
            let genres = await genresTask
            let highEnergyMarkers1 = ["metal", "hard rock", "punk", "thrash", "hardcore", "grunge"]
            let genreSaysLoud1 = earlyTags.contains { tag in highEnergyMarkers1.contains { tag.lowercased().contains($0) } }
            let audioTags = (genreSaysLoud1 && sourceFeatures.energy < 0.45)
                ? []
                : deriveAudioQueryTags(from: sourceFeatures, genreTags: genres).filter { !$0.isEmpty }
```

Then find the Phase 2 block where `genres` was previously awaited (now lines ~326–332 after Task 1's changes). It looks like:

```swift
            // Phase 2: await remaining candidates
            let genres               = await genresTask
            let spotifyRecs          = (try? await spotifyRecsTask) ?? []
            let vectorCandidates     = await vectorTask
            let dclapCandidates      = await dclapTask
            let artistSimilarCandidates = await artistSimilarTask
            self.detectedGenres  = genres
            self.lastGenres      = genres
```

Replace with (removes the `let genres = await genresTask` line — `genres` is already in scope from the earlier await):

```swift
            // Phase 2: await remaining candidates
            let spotifyRecs          = (try? await spotifyRecsTask) ?? []
            let vectorCandidates     = await vectorTask
            let dclapCandidates      = await dclapTask
            let artistSimilarCandidates = await artistSimilarTask
            self.detectedGenres  = genres
            self.lastGenres      = genres
```

- [ ] **Step 3: Update `findSimilarSongs(title:artist:)` — await `genres` early and pass to call site**

In the text-mode variant, find the high-energy-markers + `audioTags` block (currently lines ~504–508):

```swift
            let highEnergyMarkers2 = ["metal", "hard rock", "punk", "thrash", "hardcore", "grunge"]
            let genreSaysLoud2 = earlyTags.contains { tag in highEnergyMarkers2.contains { tag.lowercased().contains($0) } }
            let audioTags = (genreSaysLoud2 && sourceFeatures.energy < 0.45)
                ? []
                : deriveAudioQueryTags(from: sourceFeatures).filter { !$0.isEmpty }
```

Replace with:

```swift
            let genres = await genresTask
            let highEnergyMarkers2 = ["metal", "hard rock", "punk", "thrash", "hardcore", "grunge"]
            let genreSaysLoud2 = earlyTags.contains { tag in highEnergyMarkers2.contains { tag.lowercased().contains($0) } }
            let audioTags = (genreSaysLoud2 && sourceFeatures.energy < 0.45)
                ? []
                : deriveAudioQueryTags(from: sourceFeatures, genreTags: genres).filter { !$0.isEmpty }
```

Then find the Phase 2 block in the text-mode variant where `genres` was previously awaited (now lines ~541–547 after Task 1's changes):

```swift
            // Phase 2: await remaining candidates
            let genres               = await genresTask
            let spotifyRecs          = (try? await spotifyRecsTask) ?? []
            let vectorCandidates     = await vectorTask
            let dclapCandidates2     = await dclapTask2
            let artistSimilarCandidates = await artistSimilarTask
            self.detectedGenres  = genres
            self.lastGenres      = genres
```

Replace with:

```swift
            // Phase 2: await remaining candidates
            let spotifyRecs          = (try? await spotifyRecsTask) ?? []
            let vectorCandidates     = await vectorTask
            let dclapCandidates2     = await dclapTask2
            let artistSimilarCandidates = await artistSimilarTask
            self.detectedGenres  = genres
            self.lastGenres      = genres
```

- [ ] **Step 4: Build to verify 0 errors/0 warnings**

```bash
xcodebuild -project "/Users/skips/Documents/Claude/Projects/Simi App/Simi/Simi.xcodeproj" \
  -scheme Simi \
  -destination "generic/platform=iOS Simulator" \
  build 2>&1 | grep -E "error:|warning:|BUILD SUCCEEDED|BUILD FAILED"
```

Expected: `BUILD SUCCEEDED`, 0 errors, 0 warnings. SourceKit false positives in raw output are ignorable.

- [ ] **Step 5: Manual smoke test**

Run the app in the iOS Simulator. Trigger two searches:

1. **Niche track** (e.g., a deep-cut soul or jazz track not on mainstream charts). Verify:
   - Results include tracks from artists that are similar to the source artist but didn't appear in the previous track-only results
   - `simiLog` output (visible in Xcode console) shows `🎵 Audio-derived query tags:` including at least one compound like "melancholic soul" or "late night neo soul"

2. **Mainstream track** (e.g., a top-40 pop song). Verify:
   - Results quality is unchanged or better — artist-similar candidates enter the pool but low-scoring ones are filtered by the 0.62 threshold in `enrichWithABFeatures`
   - No crash, no blank results screen

3. Confirm search latency is not visibly worse than before (the pulsing dots loading UI provides user feedback; subjective check is sufficient here).

- [ ] **Step 6: Commit**

```bash
cd "/Users/skips/Documents/Claude/Projects/Simi App/Simi"
git add Simi/Services/RecommendationEngine.swift
git commit -m "feat: compound genre+mood tag queries in deriveAudioQueryTags"
```
