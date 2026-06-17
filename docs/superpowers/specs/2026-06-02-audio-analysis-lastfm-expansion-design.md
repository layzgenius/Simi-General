# Design: On-Device Audio Analysis + Last.fm Expansion
**Date:** 2026-06-02
**Project:** Simi App
**Status:** Approved

## Problem

The real gap in recommendation quality is energy/valence for songs AcousticBrainz doesn't have: new releases and niche artists. Tag estimation (`estimateFeaturesFromTags`) fills this gap but approximates — it can only tell you the genre archetype, not the actual feel of a specific song. A brand-new pop release with no Last.fm plays gets the generic "pop" energy/valence bucket (0.65/0.68) regardless of whether it's actually a dark ballad or a club banger.

## Goals

1. Provide real measured energy/valence for any song that has a 30s preview clip, with zero new API dependencies.
2. Improve the quality of Last.fm-driven candidates for songs that ARE tagged, by expanding emotional query coverage.
3. Cache audio analysis results so repeated searches are instant.
4. Fix three housekeeping issues (preview duration, duplicate assets, MB defensive rate limit).

## Scope

Three independent changes:

1. **`PreviewAudioAnalyzer`** — new service, native AVFoundation + Accelerate
2. **Last.fm emotional tag expansion** — expand `selectEmotionalQueries` in `LastFMService`
3. **Housekeeping trio** — preview to 30s, assets cleanup, MB sleep

---

## Change 1: PreviewAudioAnalyzer

### New file: `Services/PreviewAudioAnalyzer.swift`

A single-purpose service that downloads a 30s preview clip and extracts two audio measurements.

**Measurements:**
- **RMS energy** — root mean square of PCM sample amplitudes. 0.0 (silent) to 1.0 (clipping). Maps directly to `AudioFeatures.energy`. Reliable and well-understood.
- **Spectral centroid** — weighted mean frequency from FFT via `vDSP_sve` / `vDSP_dotpr`. Normalized to 0–1 over a 0–8000 Hz window (the perceptually relevant band for brightness). Bright/trebly → high value, dark/bass-heavy → low value. Used as a valence proxy.

**Interface:**
```swift
struct AudioMeasurements {
    let energy: Double          // 0–1, RMS-derived
    let spectralBrightness: Double  // 0–1, spectral centroid normalized
}

actor PreviewAudioAnalyzer {
    func analyze(previewURL: String) async -> AudioMeasurements?
}
```

Actor isolation ensures only one analysis runs at a time (avoids parallel AVAudioEngine instances competing for resources). This is safe because audio analysis only runs for the source song in `fetchAudioFeaturesWithFallback` — never in the parallel enrichment loop — so the serialization is never a bottleneck.

**Implementation steps:**
1. Download preview to a temp file using `URLSession.shared.download(from:)`
2. Open with `AVAudioFile`, read all frames into `AVAudioPCMBuffer`
3. RMS: compute `vDSP_rmsqv` over the float channel data
4. FFT: `vDSP_DFT_Execute` over a 4096-point window, compute magnitude spectrum, then spectral centroid = `Σ(freq[i] * mag[i]) / Σ(mag[i])`
5. Compute bin frequencies as `binIndex * (sampleRate / fftSize)` using the actual sample rate from `AVAudioFile.fileFormat.sampleRate` — do NOT assume 44100 Hz. Spotify previews are typically 44100 Hz but the buffer could be 22050 Hz or 48000 Hz on some devices or downloads. The 500–8000 Hz normalization band is a frequency range (not sample-rate-dependent) and stays correct regardless, but the bin→Hz mapping must use the real rate.
6. Normalize spectral centroid: map the centroid frequency to 0–1 over the perceptual band 500–8000 Hz (where musical brightness/darkness distinction lives). Centroid ≤ 500 Hz → 0.0, centroid ≥ 8000 Hz → 1.0, linear interpolation between. Clamp result to 0–1.
6. Clean up temp file
7. Return `AudioMeasurements` or `nil` on any failure (timeout, decode error, etc.)

**Timeout:** 8 seconds for download (same as MusicBrainz). If the preview can't be fetched in 8 seconds, return nil and fall through to tag estimation — never block the recommendation pipeline.

### Integration into `fetchAudioFeaturesWithFallback`

Slots as **step 1.5** — after Spotify fails, before tag estimation:

```
Step 0: Supabase cache lookup (existing)
Step 1: Spotify audio features (existing, usually fails without Extended Quota)
Step 1.5: Preview audio analysis (NEW)
    → if previewURL exists: analyze, cache result, use measurements
Step 2: GetSongBPM / Deezer for BPM (existing)
Step 3: Tag estimation for danceability, acousticness (existing)
Step 4: Merge audio measurements with tag features (NEW)
Step 5: BPM-only fallback (existing)
Step 6: Neutral defaults (existing)
```

**Merging audio + tag features (step 4):**

When both audio analysis and tag estimation succeed:
- `energy` → audio RMS (authoritative, replaces tag estimate)
- `valence` → blend: `(audioSpectralBrightness * 0.4) + (tagValence * 0.6)`. Tags carry genre context (a jazz song's spectral brightness may be high but its valence is typically mid-low). The blend acknowledges both signals.
- `danceability`, `acousticness`, `bpm` → tag estimation + BPM chain (unchanged)
- `isEstimated` → `false` when audio analysis ran (the key dimensions are now measured)

When audio analysis succeeds but tag estimation returns nil (no tags at all — the new release case):
- `energy` → audio RMS
- `valence` → audio spectral brightness directly (no tag data to blend with)
- `danceability` → 0.5 neutral (no signal)
- `bpm` → GetSongBPM / Deezer chain
- `isEstimated` → `false`

### Caching

The existing `SupabaseCacheService.storeFeatures` already takes a `source` parameter and applies TTL per source. Two changes:

1. **Add TTL case** in `storeFeatures`:
```swift
case "preview_audio": ttlDays = 14
```
Rationale: more accurate than `tag_estimated` (7 days) but songs don't get remastered often — 14 days is safe. Less than `spotify` (30 days) since it's still a 30s-clip approximation.

2. **Call storeFeatures after successful analysis** (fire-and-forget `Task {}`):
```swift
Task { await supabase.storeFeatures(title: song.title, artist: song.artist, features: merged, source: "preview_audio") }
```

The existing `lookupFeatures` at step 0 already checks all sources by TTL, so a cached `preview_audio` result is returned instantly on the second search — the analyzer never runs twice for the same song.

---

## Change 2: Last.fm Emotional Tag Expansion

### File: `Services/LastFMService.swift` — `selectEmotionalQueries`

**Expand `directQueryable`** from ~33 entries to ~55, adding:
```
// Electronic
"techno", "trance", "drum and bass", "dubstep", "hyperpop", "breakcore",
"synthwave", "synth-pop", "future bass", "hardstyle",

// Hip-hop subgenres
"trap", "drill", "uk drill", "phonk", "grime", "boom bap", "cloud rap",
"punk rap", "alternative hip hop",

// Rock subgenres
"punk", "metal", "grunge", "shoegaze", "post-rock", "emo", "darkwave",
"indie rock", "alt-rock", "classic rock",

// Dance / soul
"disco", "house", "gospel", "motown", "reggae", "afrobeats",

// Pop subgenres
"indie pop", "electropop", "k-pop", "j-pop",
```

**Raise the query cap** from 3 to 5. Three was too conservative — it misses the second and third subgenre tags that differentiate songs within a broad genre. Five still bounds the tag.getTopTracks API calls to a manageable parallel batch.

**Expand `mappedQueries`** (broad/mood tags → specific Last.fm queries):
```swift
"aggressive":  "metal",
"heavy":       "metal",
"dark":        "darkwave",
"melancholic": "melancholic",    // already exists — keep
"sad":         "melancholic",    // already exists — keep
"chill":       "lo-fi",          // change from "chillhop" — lo-fi has broader Last.fm coverage
"party":       "club",
"workout":     "drum and bass",
"summer":      "indie pop",
"electronic":  "synthwave",      // catch-all electronic → synthwave is the richest tag
```

---

## Change 3: Housekeeping Trio

### 3a. Preview clip duration: 10s → 30s

**File:** `Views/SongCard.swift`, line 85

```swift
// Before
previewPlayer.play(song: song, duration: 10)

// After
previewPlayer.play(song: song, duration: 30)
```

30 seconds is the full iTunes/Spotify preview clip. 10 seconds cuts off before most songs hit their hook.

### 3b. Assets.xcassets cleanup

**Problem:** Swift source files (`.swift`) were accidentally added as Custom Data Set assets inside `Assets.xcassets`. This creates a parallel set of stale file copies that Xcode may include in the app bundle as raw data, bloating the binary and causing confusion.

**Files to remove from the asset catalog** (not from the project — the real source files live in the standard directories):
```
Assets.xcassets/Theme.dataset/
Assets.xcassets/SimiApp.dataset/
Assets.xcassets/Models/Song.dataset/
Assets.xcassets/Views/ResultsView.dataset/
Assets.xcassets/Views/VibeGraphView.dataset/
Assets.xcassets/Views/HomeView.dataset/
Assets.xcassets/Views/SongCard.dataset/
Assets.xcassets/Services/SpotifyService.dataset/
Assets.xcassets/Services/URLParserService.dataset/
Assets.xcassets/Services/LastFMService.dataset/
Assets.xcassets/Services/SearchHistoryManager.dataset/
Assets.xcassets/Services/RecommendationEngine.dataset/
Assets.xcassets/SETUP.dataset/
```

**Action:** Delete these `.dataset` folders from the filesystem. The real `.swift` source files in `Services/` and `Views/` are unaffected.

### 3c. MusicBrainz defensive sleep

**File:** `Services/MusicBrainzService.swift`

MusicBrainz asks for ~1 req/sec. Currently MB is only called once per search (for the source song as a last resort in `fetchAudioFeaturesWithFallback`), so there's no loop violation today. Add a pre-request sleep as a defensive guard for future code that may call MB in a batch:

```swift
// In MusicBrainzService.fetchRawTags, before the URLRequest:
try? await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1s — MB rate limit
```

Add the same guard to `findMBID`. This is a no-op for single calls (they're rare and latency is already dominated by network round-trip) but prevents accidental rate-limit violations if a future feature calls MB in a loop.

---

## Data Flow After All Changes

```
User searches song
    ↓
Step 0: Supabase cache (returns immediately if previously analyzed)
    ↓ miss
Step 1: Spotify audio features (usually fails)
    ↓ fail
Step 1.5: PreviewAudioAnalyzer
    → Downloads 30s preview clip
    → Computes RMS energy + spectral centroid
    → Returns AudioMeasurements or nil
    ↓
Step 2: GetSongBPM → Deezer (BPM only)
    ↓
Step 3: Tag estimation (Last.fm → MusicBrainz fallback)
    → 5 emotional queries (was 3) → larger candidate pool
    ↓
Step 4: Merge
    → energy: audio RMS (if available) else tag estimate
    → valence: 0.4×audio + 0.6×tag (if both) | audio only | tag only | 0.5 neutral
    → danceability: tag estimate
    → bpm: GetSongBPM/Deezer/tag estimate
    ↓
Step 5: Cache result with source="preview_audio" (TTL 14 days)
    ↓
Recommendations scored and displayed
```

---

## Files Changed

| File | Change |
|------|--------|
| `Services/PreviewAudioAnalyzer.swift` | New file |
| `Services/RecommendationEngine.swift` | Add analyzer call + merge logic in `fetchAudioFeaturesWithFallback` |
| `Services/SupabaseCacheService.swift` | Add `preview_audio` TTL case |
| `Services/LastFMService.swift` | Expand `directQueryable`, raise cap 3→5, expand `mappedQueries` |
| `Services/MusicBrainzService.swift` | Add 1.1s defensive sleep |
| `Views/SongCard.swift` | Preview duration 10s → 30s |
| `Assets.xcassets/*.dataset/` | Delete 13 `.dataset` folders |

---

## What This Does Not Change

- The scoring algorithm (`computeSimilarity`, `computeSimilarityMultiSeed`) — no changes
- The enrichment loop (`enrichWithABFeatures`) — tag estimation still runs for recommended songs in the background; audio analysis only runs for the source song in the main feature-fetch path
- The Supabase schema — `audio_features_cache` already exists, no migration needed
- Any UI other than the preview clip duration

## Testing

- Build and run — no new API keys needed
- Search a recent chart hit (should have previewURL, likely no AcousticBrainz data) → verify console prints `🎵 Audio analysis:` with non-neutral energy/valence values
- Search the same song again → verify `✅ Supabase feature cache hit` prints (not a second analysis)
- Search a niche/unsigned artist → verify analyzer runs or gracefully falls through to tag estimation
- Play a preview from SongCard — verify it plays for 30 seconds before stopping
- Check that vibe labels on analyzed songs are more specific than "Warm & Groovy" for clearly dark/heavy songs
