# Simi Vibe / Emotional Imprint — Test Session 2026-05-28

## Core Design Principle (confirmed this session)
> "People don't want the same vibe — they want the same emotional imprint."

A recommendation is right when it *feels* the same, not when the numbers match.
Two songs can share BPM and genre and leave completely different emotional marks.
Two songs can differ by 75 BPM and feel identical because the defiance, weight, or warmth is the same.

---

## Issues Found & Fixed

### 1. Deezer Early Return — Killed Vibe Classification
**Bug:** `fetchAudioFeaturesWithFallback` returned immediately when Deezer found a BPM,
with neutral `energy: 0.5, valence: 0.5`. This meant songs like Doorman (punk, mosh-pit energy)
were labelled "Melancholic & Calm" because the energy never got estimated from genre tags.

**Fix:** Deezer BPM is now stored but the function continues to tag estimation.
The Deezer BPM overrides the genre-estimated tempo, but energy/valence come from tags.

**Result for Doorman by slowthai:**
- Before: BPM 175 / "Melancholic & Calm" (energy 0.5, valence 0.5) ❌
- After:  BPM 175 / "Intense & Dark" (energy ~0.78 from punk/grime tags, valence ~0.43) ✓

---

### 2. Similarity Weights — BPM Was Dominating Over Emotional Imprint
**Bug:** BPM had a 25% weight with a ±15 tolerance window.
A 75 BPM gap (e.g. Doorman at 175 vs. dark trap at 100) scored 0% on BPM,
wiping out 25% of the total score even when energy and valence were identical.

**Old weights:**
- BPM: 25% (too high, too tight)
- Energy: 25%
- Valence: 20%
- Danceability: 15%
- Acousticness: 15%

**New weights (emotional imprint first):**
- Valence: 35% — the emotional color. Dark/bittersweet/joyful. This IS the imprint.
- Energy: 30% — the intensity. Mosh-pit vs. bedroom.
- Danceability: 15% — physical/outward expression vs. introspective.
- BPM: 10% — secondary, tolerance widened to ±40 so cross-genre emotional matches work.
- Acousticness: 10% — sonic texture, not feel.

**Score example — Doorman vs. dark rock song 75 BPM apart, same emotional imprint:**
- Before: ~66% (BPM drag pulling it down)
- After:  ~80% (emotional similarity dominates)

---

### 3. Vibe Label Threshold — Trap Songs Mislabelled as "Energetic & Upbeat"
**Bug:** `valence > 0.5` was the "upbeat" threshold. AcousticBrainz/Deezer often measures
trap/hype tracks with valence 0.52–0.58 because the "hype energy" reads as positive,
even when the emotional tone is dark and aggressive.

**Fix:** Raised threshold to `valence > 0.6`. Songs between 0.5–0.6 valence now
correctly read as "Intense & Dark" when energy is high.

---

### 4. Missing Genres in Tag Map
**Bug:** UK genres (grime, uk hip hop, uk rap, uk drill), punk rap, rap rock, and
alternative hip hop had no entries in the tag estimation map. Songs tagged with these
fell through to default neutral features.

**Fix:** Added all missing genres with appropriate energy/valence/danceability values:
- grime: energy 0.78, valence 0.42 (high energy, dark)
- uk drill: energy 0.74, valence 0.35 (very dark)
- punk rap: energy 0.82, valence 0.42 (high energy, defiant)
- rap rock: energy 0.80, valence 0.45
- alternative hip hop: energy 0.60, valence 0.42

---

## Test Case Results (code-level trace)

| Song | Expected Imprint | Before | After |
|------|-----------------|--------|-------|
| Doorman — slowthai | Intense & Dark, high energy | Melancholic & Calm ❌ | Intense & Dark ✓ |
| Ghostface Killers — 21 Savage | Intense & Dark | Energetic & Upbeat ❌ | Intense & Dark ✓ |
| Outstanding — The Gap Band | Warm, groovy | Correct (soul tags work) ✓ | Same ✓ |

---

## Remaining Watch Items
- AcousticBrainz coverage is sparse for niche/newer artists — tag estimation is doing heavy lifting
- Spotify audio features (restricted) would give ground truth; push for Extended Quota Mode
- Songs with no Last.fm tags AND no Deezer BPM still fall to neutral defaults — consider a MusicBrainz genre lookup as additional fallback
