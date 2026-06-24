# Candidate Pool Expansion — Design Spec

**Goal:** Surface better niche music candidates by adding two always-on parallel sources — Last.fm artist-similar tracks and genre+mood compound tag queries — that run alongside the existing sources in both `findSimilarSongs` variants.

**Problem:** The current candidate pool is biased toward tracks with mainstream popularity signals. Last.fm `track.getSimilar` returns popular similar tracks but misses the deep catalog of artists that share sonic DNA. Tag queries use bare mood tags ("melancholic", "chill") that pull genre-agnostic mainstream hits. Result: niche listeners see familiar mainstream songs instead of genre-appropriate discoveries.

**Root cause (diagnosed):**
1. `fetchSimilarTracksWithFallback()` uses artist-similar as a FALLBACK — it only fires when `track.getSimilar` returns zero results. For mainstream-ish tracks, `track.getSimilar` always returns results, so the artist-similar path is never exercised.
2. `deriveAudioQueryTags()` returns 1–2 bare mood tags, guarded by `!features.isEstimated`. Compound queries like "late night soul" or "melancholic indie" would reach a different, more genre-specific slice of Last.fm's tag index.

**Solution:** Two targeted additions to `RecommendationEngine.swift` — always-on artist-similar candidates and compound tag queries.

---

## Architecture

### Source 1: Artist-Similar Always-On

New private method `fetchArtistSimilarCandidates(artist:)` added to `RecommendationEngine`.

**Logic:**
1. Call `lastFMService.fetchSimilarArtists(artist:)` — returns up to 10 similar artists.
2. Take the top 8 artists. For each, call `lastFMService.fetchArtistTopTracks(artist:)` concurrently via `withTaskGroup` — returns up to 5 tracks per artist.
3. Flatten, deduplicate by `"\(title)|\(artist)".lowercased()`, return up to ~40 candidates as `[(title: String, artist: String)]`.

Both `findSimilarSongs(for urlString:)` and `findSimilarSongs(title:artist:)` add:
```swift
async let artistSimilarTask = fetchArtistSimilarCandidates(artist: song.artist)
```
…in the parallel task block, then await it and include it in `expandedTracks` merge.

**Why always-on vs. fallback:** The fallback only runs when track.getSimilar returns zero results — which for niche tracks is rare enough that the artist-similar pool is never exercised for the tracks that would benefit most. Always-on means 40 genre-aligned candidates enter the pool on every search.

**Latency:** `fetchSimilarArtists` and `fetchArtistTopTracks` run concurrently alongside the existing tasks. The artist-similar fan-out (8 concurrent `fetchArtistTopTracks` calls) completes in ~300–500ms typical — within the window that Spotify/vector/DCLAP already occupy. Net additional latency: 0–200ms in the common case, ~1–2s in cold-network worst case (accepted by user as a quality trade-off).

### Source 2: Genre+Mood Compound Tags

`deriveAudioQueryTags()` is extended to accept a second parameter: the raw genre tags fetched earlier in the pipeline.

**Updated signature:**
```swift
private func deriveAudioQueryTags(
    from features: AudioFeatures,
    genreTags: [String] = []
) -> [String]
```

**Logic change:**
- Current behavior: returns 1–2 bare mood tags (e.g., `["melancholic", "chill"]`), guarded by `!features.isEstimated`.
- New behavior: if `genreTags` is non-empty, take the top genre tag and generate compound queries:
  - `"\(moodTag) \(genre)"` (e.g., "late night soul", "melancholic indie")
  - One compound per mood tag, up to 2 compounds
- Return up to 4 tags total: original bare tags + compounds
- Guard unchanged: no tags returned when `features.isEstimated`

**Example output for a niche soul track:**
- Before: `["late night", "melancholic"]`
- After: `["late night", "melancholic", "late night soul", "melancholic soul"]`

The compound tags reach a genre-specific slice of Last.fm's tag index, surfacing tracks that share both the mood and the genre — the exact space where niche discovery lives.

**Call sites:** Both `findSimilarSongs` variants already call `deriveAudioQueryTags`. Update both call sites to pass the genre tags that are already fetched earlier in the function.

---

## Files Changed

| File | Change |
|------|--------|
| `Simi/Simi/Services/RecommendationEngine.swift` | New `fetchArtistSimilarCandidates(artist:)` method + wire in both `findSimilarSongs` variants + `deriveAudioQueryTags` signature + compound tag logic |
| `Simi/Simi/Services/LastFMService.swift` | **No changes** — all needed methods already exist |

---

## Interfaces

**New method:**
```swift
private func fetchArtistSimilarCandidates(artist: String) async -> [(title: String, artist: String)]
```
- Calls `lastFMService.fetchSimilarArtists(artist:)` → top 8 results
- Fans out to `lastFMService.fetchArtistTopTracks(artist:)` concurrently
- Returns up to ~40 deduplicated candidates
- Returns `[]` on any error (never throws)

**Updated method:**
```swift
private func deriveAudioQueryTags(
    from features: AudioFeatures,
    genreTags: [String] = []
) -> [String]
```
- `genreTags`: the raw genre strings from `fetchGenresWithFallback()` (already in scope at call sites)
- Returns up to 4 tags (was 1–2): existing bare tags + compound genre+mood tags
- No change to the `features.isEstimated` guard

---

## Constraints

- No changes to `LastFMService.swift`
- No changes to `mergeAndScore()`, `enrichWithABFeatures()`, `computeSimilarity()`, or any scoring logic
- `SimilarSong` is a struct — all mutations via index reassignment (not in scope here)
- `RecommendationEngine` is `@MainActor class` — new methods implicitly on main actor; `withTaskGroup` inside the new method is fine
- SourceKit false positives ("Cannot find type X in scope") are expected and ignorable; all Xcode builds succeed 0 errors/0 warnings
- `fetchArtistTopTracks` does not throw — call directly, no `try?` needed
- `fetchSimilarArtists` does throw — wrap in `(try? await ...) ?? []`

---

## Success Criteria

1. On a niche track search, the results list includes tracks from sonically similar artists that would not appear via `track.getSimilar` alone
2. Compound tag queries produce results containing the genre token (e.g., a "melancholic indie" query returns indie tracks, not just mainstream melancholic pop)
3. Build: 0 errors, 0 warnings (SourceKit false positives expected and excluded)
4. No regression: mainstream track searches return the same quality or better results (artist-similar candidates enter the pool and are scored normally; low-scoring ones are filtered by the 0.62 threshold in `enrichWithABFeatures`)
5. Total search latency increases by no more than 2s in the median case

---

## Out of Scope (addressed in Spec B and Spec C)

- Deezer preview fallback for measured audio features (Spec B)
- AcousticBrainz as Stage 1 fallback (Spec B)
- Expanding Stage 2 librosa from top 5 → top 10 (Spec B)
- Proactive DCLAP catalog building (Spec C)
