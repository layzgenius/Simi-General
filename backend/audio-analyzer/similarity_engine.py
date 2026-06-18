"""
similarity_engine.py
Simi — Weighted similarity scoring for audio features.

Mirrors computeSimilarity() in RecommendationEngine.swift exactly:
  Weights: valence 0.35, danceability 0.22, energy 0.17,
           mode 0.09, acousticness 0.06, vocalPresence 0.04,
           reverbSpace 0.04, tonalClarity 0.02, bpm 0.01
  Cross-archetype penalties (a), (b), (c) match the Swift implementation.

Returns the same MatchReason string literals as MatchReason.rawValue in Swift,
so the iOS app can decode them directly into the enum.
"""

from __future__ import annotations
from typing import TypedDict


class AudioFeaturesDict(TypedDict, total=False):
    bpm:              float
    energy:           float
    valence:          float
    valenceEssentia:  float
    danceability:     float
    acousticness:     float
    instrumentalness: float
    liveness:         float
    loudness:         float
    key:              int
    mode:             int
    isEstimated:      bool
    isKeyEstimated:   bool
    spectralWarmth:   float
    tonalClarity:     float
    vocalPresence:    float
    reverbSpace:      float
    grooveRatio:      float


# Raw values must match MatchReason.rawValue in Song.swift exactly.
class _R:
    BPM                 = "Similar BPM"
    ANTHEMIC            = "Anthemic"
    DANCE_FLOOR         = "Dance Floor"
    HIGH_INTENSITY      = "High Intensity"
    MELLOW_MATCH        = "Mellow Match"
    ENERGY              = "Similar Energy"
    DARK_MOOD           = "Dark Mood"
    UPBEAT_MOOD         = "Upbeat Mood"
    MOOD                = "Same Mood"
    GENRE               = "Same Genre"
    SUB_GENRE           = "Same Sub-Genre"
    ACOUSTICS           = "Acoustic Match"
    VIBE                = "Same Vibe"
    VOCAL_HEAVY         = "Vocal-heavy"
    INSTRUMENTAL_FEEL   = "Instrumental feel"
    SPACIOUS_PRODUCTION = "Spacious production"
    DRY_AND_TIGHT       = "Dry & tight"


class Genre(TypedDict, total=False):
    main: str
    sub:  str


class ExplanationRow(TypedDict):
    label:      str
    descriptor: str


class ExplanationResult(TypedDict):
    rows:             list[ExplanationRow]
    genreBridgeLabel: str | None


# (displayName, keywords) — matched in priority order
_GENRE_FAMILIES: dict[str, tuple[str, list[str]]] = {
    "blues":      ("Blues",      ["blues"]),
    "metal":      ("Metal",      ["metal", "thrash", "metalcore", "deathcore", "doom"]),
    "rock":       ("Rock",       ["hard rock", "punk", "grunge", "rock", "hardcore", "shoegaze", "post-rock"]),
    "hiphop":     ("Hip-Hop",    ["hip", "rap", "trap", "drill", "grime", "phonk"]),
    "rnb":        ("R&B",        ["r&b", "rnb", "soul", "funk", "gospel", "slow jam", "neo-soul"]),
    "jazz":       ("Jazz",       ["jazz"]),
    "classical":  ("Classical",  ["classical", "orchestral"]),
    "electronic": ("Electronic", ["electronic", "edm", "house", "techno", "trance", "drum and bass", "dubstep", "synthwave", "synth"]),
    "folk":       ("Folk",       ["folk", "acoustic", "country", "americana", "bluegrass", "singer-songwriter"]),
    "pop":        ("Pop",        ["pop"]),
}
_FAMILY_ORDER = ["blues", "metal", "rock", "hiphop", "rnb", "jazz", "classical", "electronic", "folk", "pop"]


def detect_genre_family(genres: list[Genre]) -> tuple[str, str] | None:
    """Returns (family_key, displayName) for the dominant genre family, or None."""
    names = [g.get("main", "").lower() for g in genres]
    for family_key in _FAMILY_ORDER:
        display, keywords = _GENRE_FAMILIES[family_key]
        if any(kw in name for name in names for kw in keywords):
            return family_key, display
    return None


def build_explanation(
    source: AudioFeaturesDict,
    target: AudioFeaturesDict,
    source_genres: list[Genre] | None = None,
    target_genre:  Genre | None = None,
) -> ExplanationResult:
    """
    Ports buildMatchExplanation() from RecommendationEngine.swift.
    Rows are only populated when audio features are measured (isEstimated=False)
    and the delta is within the threshold — identical gates to the iOS app.
    """
    rows: list[ExplanationRow] = []

    src_estimated = source.get("isEstimated", True)
    tgt_estimated = target.get("isEstimated", True)
    src_key_est   = source.get("isKeyEstimated", True)
    tgt_key_est   = target.get("isKeyEstimated", True)

    # Row 1: Emotional weight — valence (valenceEssentia preferred)
    src_v = source["valenceEssentia"] if source.get("valenceEssentia") is not None else source["valence"]
    tgt_v = target["valenceEssentia"] if target.get("valenceEssentia") is not None else target["valence"]
    if not src_estimated and not tgt_estimated and abs(src_v - tgt_v) < 0.20:
        avg = (src_v + tgt_v) / 2
        if avg < 0.35:
            desc = "Same melancholic weight"
        elif avg < 0.50:
            desc = "Same bittersweet edge"
        elif avg < 0.65:
            desc = "Same balanced mood"
        else:
            desc = "Same bright energy"
        rows.append({"label": "Emotional weight", "descriptor": desc})

    # Row 2: Intensity — energy
    if not src_estimated and not tgt_estimated and abs(source["energy"] - target["energy"]) < 0.20:
        avg = (source["energy"] + target["energy"]) / 2
        if avg < 0.35:
            desc = "Equally restrained"
        elif avg < 0.55:
            desc = "Equally measured"
        elif avg < 0.75:
            desc = "Equally driven"
        else:
            desc = "Equally intense"
        rows.append({"label": "Intensity", "descriptor": desc})

    # Row 3: Key — only when both measured (not C-Major placeholder)
    if not src_key_est and not tgt_key_est and source.get("mode") == target.get("mode"):
        mode = source.get("mode", 1)
        rows.append({"label": "Key", "descriptor": "Both major key" if mode == 1 else "Both minor key"})

    # Row 4: Groove feel — grooveRatio presence gates this row (librosa only)
    src_groove = source.get("grooveRatio")
    tgt_groove = target.get("grooveRatio")
    if src_groove is not None and tgt_groove is not None and abs(src_groove - tgt_groove) < 0.35:
        avg = (src_groove + tgt_groove) / 2
        if avg < 0.5:
            desc = "Smooth and flowing"
        elif avg < 0.9:
            desc = "Equally measured pulse"
        else:
            desc = "Equally syncopated"
        rows.append({"label": "Groove feel", "descriptor": desc})

    # Row 5: Sonic texture — spectralWarmth (librosa only, isEstimated gates)
    if not src_estimated and not tgt_estimated and abs(source.get("spectralWarmth", 0.5) - target.get("spectralWarmth", 0.5)) < 0.20:
        avg = (source.get("spectralWarmth", 0.5) + target.get("spectralWarmth", 0.5)) / 2
        if avg < 0.35:
            desc = "Both bright and airy"
        elif avg < 0.65:
            desc = "Similar tonal warmth"
        else:
            desc = "Both warm and full"
        rows.append({"label": "Sonic texture", "descriptor": desc})

    # Genre bridge
    genre_bridge: str | None = None
    if source_genres and target_genre:
        src_family = detect_genre_family(source_genres)
        tgt_family = detect_genre_family([target_genre])
        if src_family and tgt_family and src_family[0] != tgt_family[0]:
            genre_bridge = f"{src_family[1]} → {tgt_family[1]}"

    return {"rows": rows, "genreBridgeLabel": genre_bridge}


def build_embedding(features: AudioFeaturesDict) -> list[float]:
    """
    Returns the normalized 8-dim vector used for cosine similarity in the vector catalog.
    Dimension order must match the SQL embedding column in analyzed_songs and
    SupabaseCacheService.buildEmbedding(from:) in Swift.

      0  valence        0–1
      1  energy         0–1
      2  danceability   0–1
      3  acousticness   0–1
      4  mode           0.0 = minor, 1.0 = major
      5  bpm_norm       min(bpm / 200, 1.0)
      6  tonalClarity   0–1
      7  spectralWarmth 0–1
    """
    return [
        features["valence"],
        features["energy"],
        features["danceability"],
        features["acousticness"],
        float(features.get("mode", 1)),
        min(features["bpm"] / 200.0, 1.0),
        features.get("tonalClarity", 0.5),
        features.get("spectralWarmth", 0.5),
    ]


def compute_similarity(
    source: AudioFeaturesDict,
    target: AudioFeaturesDict,
) -> tuple[float, list[str]]:
    """
    Returns (score 0–1, reasons[:3]).
    Logic mirrors RecommendationEngine.computeSimilarity() in Swift.

    Weights (sum = 1.00):
      valence        0.35 — emotional colour (happy/dark/bittersweet)
      danceability   0.22 — groove/rhythm feel
      energy         0.17 — intensity
      mode           0.09 — major/minor signature
      acousticness   0.06 — sonic texture
      tonalClarity   0.02 — harmonic focus (melodic vs percussive)
      bpm            0.01 — tertiary; feel trumps tempo
      spectralWarmth 0.00 — disabled pending sub-bass RMS fix (stored, contributes nothing)
      vocalPresence  0.00 — disabled: 808 in y_harmonic inverts expected ordering (stored)
      reverbSpace    0.00 — disabled: HF noise floor in trap inverts expected ordering (stored)
    """
    total_score = 0.0
    reasons: list[str] = []

    # ── Valence — emotional colour (0.35) ─────────────────────────────
    valence_diff = abs(source["valence"] - target["valence"])
    total_score += (1.0 - valence_diff) * 0.35
    if valence_diff < 0.15:
        avg_v = (source["valence"] + target["valence"]) / 2
        if avg_v < 0.40:
            reasons.append(_R.DARK_MOOD)
        elif avg_v > 0.65:
            reasons.append(_R.UPBEAT_MOOD)
        else:
            reasons.append(_R.MOOD)

    # ── Energy — intensity of the feeling (0.17) ──────────────────────
    energy_diff = abs(source["energy"] - target["energy"])
    total_score += (1.0 - energy_diff) * 0.17
    if energy_diff < 0.15:
        avg_e = (source["energy"] + target["energy"]) / 2
        if avg_e > 0.65:
            src_low_dance  = source["danceability"] < 0.65
            tgt_low_dance  = target["danceability"] < 0.65
            src_high_dance = source["danceability"] > 0.72
            tgt_high_dance = target["danceability"] > 0.72
            if src_low_dance and tgt_low_dance:
                reasons.append(_R.ANTHEMIC)
            elif src_high_dance and tgt_high_dance:
                reasons.append(_R.DANCE_FLOOR)
            else:
                reasons.append(_R.HIGH_INTENSITY)
        elif avg_e < 0.45:
            reasons.append(_R.MELLOW_MATCH)
        else:
            reasons.append(_R.ENERGY)

    # ── Danceability — groove/rhythm feel (0.22) ──────────────────────
    dance_diff = abs(source["danceability"] - target["danceability"])
    total_score += (1.0 - dance_diff) * 0.22

    # Cross-archetype penalty (a): high-energy diverging danceability
    if source["energy"] > 0.60 and target["energy"] > 0.60 and dance_diff > 0.25:
        total_score = max(0.0, total_score - 0.05)

    # Cross-archetype penalty (b): slow-jam source vs club-heavy target
    if dance_diff > 0.12 and source["danceability"] < 0.60 and target["danceability"] > 0.65:
        total_score = max(0.0, total_score - 0.06)

    # Cross-archetype penalty (c): upward energy gap
    energy_gap = target["energy"] - source["energy"]
    if energy_gap > 0.14:
        gap_penalty = min(0.10, (energy_gap - 0.14) * 2.0)
        total_score = max(0.0, total_score - gap_penalty)

    # ── Mode — major/minor emotional signature (0.09) ─────────────────
    if not source.get("isKeyEstimated", True) and not target.get("isKeyEstimated", True):
        mode_score = 1.0 if source["mode"] == target["mode"] else 0.3
    else:
        mode_score = 0.5
    total_score += mode_score * 0.09

    # ── Acousticness — sonic texture (0.06) ───────────────────────────
    acoustic_diff = abs(source["acousticness"] - target["acousticness"])
    total_score += (1.0 - acoustic_diff) * 0.06
    if acoustic_diff < 0.2:
        reasons.append(_R.ACOUSTICS)

    # ── Spectral warmth — disabled (weight 0.00); stored but contributes nothing ──
    # Hardcoded to 0.5 on both sides; pending sub-bass RMS implementation.
    sw_diff = abs(source.get("spectralWarmth", 0.5) - target.get("spectralWarmth", 0.5))
    total_score += (1.0 - sw_diff) * 0.00

    # ── Tonal clarity — harmonic focus, melodic vs percussive (0.02) ──
    tc_diff = abs(source.get("tonalClarity", 0.5) - target.get("tonalClarity", 0.5))
    total_score += (1.0 - tc_diff) * 0.02

    # ── Vocal presence — disabled (weight 0.00); stored but contributes nothing ──
    # Calibration showed 808 sine waves stay in y_harmonic, inverting expected ordering.
    vp_diff = abs(source.get("vocalPresence", 0.5) - target.get("vocalPresence", 0.5))
    total_score += (1.0 - vp_diff) * 0.00

    # ── Reverb space — disabled (weight 0.00); stored but contributes nothing ──
    # Calibration showed HF noise floor in trap gives falsely high flatness.
    rs_diff = abs(source.get("reverbSpace", 0.5) - target.get("reverbSpace", 0.5))
    total_score += (1.0 - rs_diff) * 0.00

    # ── BPM — tertiary; emotional feel trumps tempo (0.01) ────────────
    bpm_diff = abs(source["bpm"] - target["bpm"])
    bpm_score = max(0.0, 1.0 - (bpm_diff / 60.0))
    total_score += bpm_score * 0.01
    if bpm_diff <= 15:
        reasons.append(_R.BPM)

    # Always lead with genre for measured (non-estimated) features
    reasons.insert(0, _R.GENRE)

    return round(total_score, 4), reasons[:3]
