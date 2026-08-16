import sys, os, numpy as np, pytest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from extract_features import build_feature_vector, detect_key_mode

def _synth(seed=42, duration_s=30):
    rng = np.random.default_rng(seed)
    return rng.standard_normal(22050 * duration_s).astype(np.float32) * 0.1, 22050

def test_feature_vector_shape():
    y, sr = _synth()
    feats = build_feature_vector(y, sr)
    assert len(feats) == 58, f"Expected 58, got {len(feats)}"

def test_feature_values_finite():
    y, sr = _synth(seed=1)
    feats = build_feature_vector(y, sr)
    arr = np.array(feats)
    assert np.all(np.isfinite(arr)), f"NaN/Inf in features: {arr}"

def test_mfcc_mean_l2_normalized():
    y, sr = _synth(seed=7)
    feats = build_feature_vector(y, sr)
    mfcc_mean = np.array(feats[0:20])
    norm = np.linalg.norm(mfcc_mean)
    assert abs(norm - 1.0) < 0.01, f"mfcc_mean L2 norm={norm:.4f}, expected ≈1.0"

def test_mfcc_std_l2_normalized():
    y, sr = _synth(seed=8)
    feats = build_feature_vector(y, sr)
    mfcc_std = np.array(feats[20:40])
    norm = np.linalg.norm(mfcc_std)
    assert abs(norm - 1.0) < 0.01, f"mfcc_std L2 norm={norm:.4f}, expected ≈1.0"

def test_chroma_sums_to_one():
    y, sr = _synth(seed=3)
    feats = build_feature_vector(y, sr)
    chroma = np.array(feats[40:52])
    total = chroma.sum()
    assert abs(total - 1.0) < 0.01, f"chroma sum={total:.4f}, expected ≈1.0"

def test_chroma_entropy_in_range():
    y, sr = _synth(seed=4)
    feats = build_feature_vector(y, sr)
    assert 0.0 <= feats[52] <= 1.0, f"chromaEntropy={feats[52]}"

def test_mode_binary():
    y, sr = _synth(seed=5)
    feats = build_feature_vector(y, sr)
    assert feats[53] in (0.0, 1.0), f"mode={feats[53]}, must be 0 or 1"

def test_mode_conf_in_range():
    y, sr = _synth(seed=6)
    feats = build_feature_vector(y, sr)
    assert 0.0 <= feats[54] <= 1.0, f"modeConf={feats[54]}"

def test_detect_key_mode_output():
    chroma = np.ones(12) / 12.0
    key, mode, conf = detect_key_mode(chroma)
    assert mode in (0, 1)
    assert 0.0 <= conf <= 1.0
    assert 0 <= key <= 11
