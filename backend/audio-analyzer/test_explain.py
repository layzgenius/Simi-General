import sys, os
sys.path.insert(0, os.path.dirname(__file__))

import pytest
from similarity_engine import detect_genre_family, build_explanation

# ── detect_genre_family ───────────────────────────────────────────────

def test_detect_genre_family_jazz():
    assert detect_genre_family([{"main": "Jazz", "sub": "Contemporary Jazz"}]) == ("jazz", "Jazz")

def test_detect_genre_family_hiphop():
    assert detect_genre_family([{"main": "Hip-Hop", "sub": "Lo-fi"}]) == ("hiphop", "Hip-Hop")

def test_detect_genre_family_hiphop_via_rap():
    assert detect_genre_family([{"main": "rap", "sub": ""}]) == ("hiphop", "Hip-Hop")

def test_detect_genre_family_electronic():
    assert detect_genre_family([{"main": "House", "sub": "Deep House"}]) == ("electronic", "Electronic")

def test_detect_genre_family_metal_priority_over_rock():
    # "hard rock" matches rock; "thrash metal" matches metal — metal has higher priority
    assert detect_genre_family([{"main": "thrash metal", "sub": ""}]) == ("metal", "Metal")

def test_detect_genre_family_unknown():
    assert detect_genre_family([{"main": "Unknown Genre XYZ", "sub": ""}]) is None

def test_detect_genre_family_empty():
    assert detect_genre_family([]) is None

# ── build_explanation ─────────────────────────────────────────────────

# Fixtures: both measured, same minor key, close valence/energy/groove/warmth
_SOURCE = {
    "bpm": 92, "energy": 0.41, "valence": 0.28, "danceability": 0.44,
    "acousticness": 0.62, "instrumentalness": 0.01, "liveness": 0.09,
    "loudness": -9.1, "key": 9, "mode": 0,
    "isEstimated": False, "isKeyEstimated": False,
    "spectralWarmth": 0.38, "grooveRatio": 0.62,
}
_TARGET = {
    "bpm": 88, "energy": 0.38, "valence": 0.31, "danceability": 0.49,
    "acousticness": 0.55, "instrumentalness": 0.0, "liveness": 0.11,
    "loudness": -10.2, "key": 11, "mode": 0,
    "isEstimated": False, "isKeyEstimated": False,
    "spectralWarmth": 0.42, "grooveRatio": 0.58,
}

def test_build_explanation_rows_all_five():
    result = build_explanation(_SOURCE, _TARGET)
    labels = [r["label"] for r in result["rows"]]
    assert "Emotional weight" in labels
    assert "Intensity"        in labels
    assert "Key"              in labels
    assert "Groove feel"      in labels
    assert "Sonic texture"    in labels

def test_build_explanation_descriptors():
    result = build_explanation(_SOURCE, _TARGET)
    by_label = {r["label"]: r["descriptor"] for r in result["rows"]}
    assert by_label["Emotional weight"] == "Same melancholic weight"  # avg≈0.295 < 0.35
    # energy avg = (0.41+0.38)/2 = 0.395 — that's ≥ 0.35 and < 0.55 so "Equally measured"
    assert by_label["Intensity"]        == "Equally measured"
    assert by_label["Key"]              == "Both minor key"
    # grooveRatio avg = (0.62+0.58)/2 = 0.60 → >= 0.5, < 0.9 → "Equally measured pulse"
    assert by_label["Groove feel"]      == "Equally measured pulse"
    # spectralWarmth avg = (0.38+0.42)/2 = 0.40 → >= 0.35, < 0.65 → "Similar tonal warmth"
    assert by_label["Sonic texture"]    == "Similar tonal warmth"

def test_build_explanation_no_genre_bridge_when_omitted():
    result = build_explanation(_SOURCE, _TARGET)
    assert result["genreBridgeLabel"] is None

def test_build_explanation_genre_bridge():
    result = build_explanation(
        _SOURCE, _TARGET,
        source_genres=[{"main": "Jazz", "sub": "Contemporary Jazz"}],
        target_genre={"main": "Hip-Hop", "sub": "Lo-fi"},
    )
    assert result["genreBridgeLabel"] == "Jazz → Hip-Hop"

def test_build_explanation_no_bridge_same_family():
    result = build_explanation(
        _SOURCE, _TARGET,
        source_genres=[{"main": "Hip-Hop", "sub": "Boom Bap"}],
        target_genre={"main": "Rap", "sub": ""},
    )
    # Both map to hiphop family → no bridge
    assert result["genreBridgeLabel"] is None

def test_build_explanation_skip_rows_when_estimated():
    src = dict(_SOURCE, isEstimated=True)
    tgt = dict(_TARGET, isEstimated=True)
    result = build_explanation(src, tgt)
    labels = [r["label"] for r in result["rows"]]
    # Rows 1, 2, 5 require isEstimated=False on both → all suppressed
    assert "Emotional weight" not in labels
    assert "Intensity"        not in labels
    assert "Sonic texture"    not in labels

def test_build_explanation_skip_key_when_key_estimated():
    src = dict(_SOURCE, isKeyEstimated=True)
    tgt = dict(_TARGET)
    result = build_explanation(src, tgt)
    labels = [r["label"] for r in result["rows"]]
    assert "Key" not in labels

def test_build_explanation_skip_groove_when_no_groove_ratio():
    src = {k: v for k, v in _SOURCE.items() if k != "grooveRatio"}
    tgt = {k: v for k, v in _TARGET.items() if k != "grooveRatio"}
    result = build_explanation(src, tgt)
    labels = [r["label"] for r in result["rows"]]
    assert "Groove feel" not in labels

def test_build_explanation_valence_essentia_used_over_valence():
    # valenceEssentia=0.70 → avg with tgt 0.70 is 0.70 → "Same bright energy"
    src = dict(_SOURCE, valenceEssentia=0.70, valence=0.20)
    tgt = dict(_TARGET, valenceEssentia=0.72, valence=0.20)
    result = build_explanation(src, tgt)
    by_label = {r["label"]: r["descriptor"] for r in result["rows"]}
    assert by_label.get("Emotional weight") == "Same bright energy"

def test_build_explanation_valence_essentia_zero_not_ignored():
    # valenceEssentia=0.0 is a valid measured value (very melancholic)
    # The None-check must NOT fall back to valence=0.90 (which would give "Same bright energy")
    src = dict(_SOURCE, valenceEssentia=0.0, valence=0.90, isEstimated=False)
    tgt = dict(_TARGET, valenceEssentia=0.0, valence=0.90, isEstimated=False)
    result = build_explanation(src, tgt)
    by_label = {r["label"]: r["descriptor"] for r in result["rows"]}
    # avg valenceEssentia = 0.0 → "Same melancholic weight" (not "Same bright energy")
    assert by_label.get("Emotional weight") == "Same melancholic weight"

def test_build_explanation_major_key():
    src = dict(_SOURCE, mode=1)
    tgt = dict(_TARGET, mode=1)
    result = build_explanation(src, tgt)
    by_label = {r["label"]: r["descriptor"] for r in result["rows"]}
    assert by_label.get("Key") == "Both major key"
