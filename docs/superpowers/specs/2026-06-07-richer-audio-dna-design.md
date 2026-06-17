# Richer Audio DNA — Recommendation Accuracy Improvements (A+B)

**Date:** 2026-06-07  
**Status:** Approved, ready for implementation

## Problem

Simi's most common failure mode is **wrong emotional tone** in recommendations — a song that is technically genre-adjacent but feels emotionally wrong. The root causes are:

1. **Valence formula weakness**: `_valence()` uses spectral centroid brightness (pulled down by bass transients) and a binary mode score (0.65 major / 0.35 minor). This binary misses the continuous harmonic brightness within major/minor — a triumphant major anthem feels different from a gentle major ballad at the same mode.

2. **Missing timbral dimensions**: The 6-feature similarity space (valence, energy, danceability, mode, acousticness, bpm) has no dimension for bass warmth/fullness or harmonic focus. Two songs can score 0.82 on all axes and still feel emotionally wrong because their timbral texture is completely different.

## Approach: A+B

### Part B — Improved `_valence()` Formula

Replace centroid-based brightness with **spectral contrast brightness** (upper bands: presence/air ~2-8kHz on harmonic signal). Add **tonal brightness** from tonnetz as a new 0.10-weight continuous signal capturing harmonic brightness direction. Reduce binary mode weight from 0.35 → 0.25.

**New formula** (weights sum to 1.00):
```
valence = 0.25 × mode_score
        + 0.10 × tonal_brightness   # from tonnetz: directional harmonic brightness
        + 0.20 × sc_brightness      # from spectral contrast upper bands
        + 0.15 × tempo_score        # unchanged
        + 0.15 × energy             # unchanged
        + 0.15 × harmonic_ratio     # unchanged
```

**`sc_brightness`** — `librosa.feature.spectral_contrast(y=y_harmonic, n_bands=6)` upper 3 bands (bands 4-6, ~2-8kHz). Normalize: `float(np.clip(sc[4:7].mean() / 25.0, 0.0, 1.0))`. High = vivid, present-sounding; low = muddy or ambient.

**`tonal_brightness`** — `librosa.feature.tonnetz(y=y_harmonic)` dimensions [0] (fifth) and [2] (major third). Mean of these two dimensions, normalized: `float(np.clip((tonal_raw + 0.3) / 0.6, 0.0, 1.0))` where `tonal_raw = float(tn[[0, 2]].mean())`. High = harmony pulls toward bright/major space; low = dark/minor space.

Groove corrections (+0.12 groovy minor, +0.08 warm ballad, +0.05 high-energy minor) remain unchanged initially. Re-evaluated after deploy.

### Part A — Two New `AudioFeatures` Fields

**`spectralWarmth`** — Mean spectral contrast of LOWER bands (bands 0-2, ~0-2kHz) on harmonic signal. Captures bass fullness and body: thick warm soul/R&B scores high, thin acoustic scores low. Orthogonal to sc_brightness (upper bands) used in valence.

Formula: `float(np.clip(sc[0:3].mean() / 20.0, 0.0, 1.0))`

**`tonalClarity`** — RMS magnitude across all 6 tonnetz dimensions. Captures harmonic focus: melodic trap (Tiramisu) scores high, hard percussive trap (HUMBLE.) scores lower. This discriminates two songs with similar valence/energy that feel different because one is melody-driven and the other is beat-driven.

Formula: `float(np.clip(np.sqrt(np.mean(tn ** 2, axis=1).mean()) / 0.35, 0.0, 1.0))`

### Updated Similarity Weights

Both `similarity_engine.py` (Python) and `RecommendationEngine.computeSimilarity()` (Swift) must stay identical.

| Feature | Old weight | New weight | Rationale |
|---|---|---|---|
| valence | 0.40 | 0.38 | Slightly reduced — tonal features cover similar ground |
| danceability | 0.22 | 0.22 | Unchanged — critical groove discriminator |
| energy | 0.18 | 0.17 | Slightly reduced |
| mode | 0.10 | 0.09 | Slightly reduced |
| acousticness | 0.07 | 0.06 | Slightly reduced |
| **spectralWarmth** | — | **0.04** | New: bass texture |
| **tonalClarity** | — | **0.03** | New: harmonic focus |
| bpm | 0.03 | 0.01 | Reduced — least informative |
| **Total** | **1.00** | **1.00** | ✓ |

## Files Changed

1. **`backend/audio-analyzer/audio_analyzer.py`**
   - `AudioFeatures` dataclass: add `spectral_warmth: float = 0.0` and `tonal_clarity: float = 0.0`
   - `_valence()`: add spectral contrast + tonnetz calculations; update formula
   - `analyze_from_url()` + `analyze_from_file()`: populate new fields

2. **`backend/audio-analyzer/main.py`**
   - `AudioFeatures` Pydantic model: add `spectral_warmth` and `tonal_clarity` (with defaults so old iOS clients still work)
   - `/analyze` and `/batch-analyze` response fields automatically included

3. **`backend/audio-analyzer/similarity_engine.py`**
   - `AudioFeaturesDict`: add `spectral_warmth` and `tonal_clarity` keys
   - `compute_similarity()`: new weight table + spectralWarmth + tonalClarity scoring terms

4. **`Simi/Simi/Models/Song.swift` — `AudioFeatures` struct**
   - Add `var spectralWarmth: Double = 0.0` and `var tonalClarity: Double = 0.0`

5. **`Simi/Simi/Services/SimiAudioService.swift`**
   - Pydantic response decoding: new optional fields (defaults handle missing data from old cached responses)

6. **`Simi/Simi/Services/RecommendationEngine.swift` — `computeSimilarity()`**
   - Updated weight constants
   - Add `spectralWarmth` and `tonalClarity` scoring terms

## Testing

- `test_vibe_eval.py` must pass: 10 golden songs, 0 failures (warnings OK)
- Threshold: all songs that currently pass must still pass; none regress to failures
- Deploy to Railway, run eval against live endpoint

## Out of Scope

- Candidate pool changes (tag discovery improvements)
- User feedback loop
- Changing groove correction thresholds (evaluate post-deploy)
