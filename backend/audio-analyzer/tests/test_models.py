import sys, os, numpy as np, pytest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from train_valence_model import train_model, evaluate_model

def _synthetic(n=300, n_feat=58, seed=42):
    rng = np.random.default_rng(seed)
    X   = rng.standard_normal((n, n_feat)).astype(np.float32)
    # Weak but nonzero signal so R² > -inf
    y_v = np.clip(0.5 + 0.4 * X[:, 0] + 0.05 * rng.standard_normal(n), 0, 1).astype(np.float32)
    y_a = np.clip(0.5 + 0.4 * X[:, 5] + 0.05 * rng.standard_normal(n), 0, 1).astype(np.float32)
    return X, y_v, y_a

def test_train_model_prediction_shape():
    X, y_v, _ = _synthetic()
    pipe  = train_model(X[:240], y_v[:240])
    preds = pipe.predict(X[240:])
    assert preds.shape == (60,)

def test_train_model_predictions_finite():
    X, y_v, _ = _synthetic(seed=1)
    pipe  = train_model(X[:240], y_v[:240])
    preds = pipe.predict(X[240:])
    assert np.all(np.isfinite(preds))

def test_evaluate_model_keys():
    X, y_v, _ = _synthetic(seed=2)
    pipe    = train_model(X[:240], y_v[:240])
    metrics = evaluate_model(pipe, X[240:], y_v[240:])
    assert "r2"   in metrics
    assert "rmse" in metrics

def test_evaluate_model_r2_positive_on_signal():
    """With 4:1 train:test and a real signal, R² should be positive."""
    X, y_v, _ = _synthetic(n=500, seed=3)
    pipe    = train_model(X[:400], y_v[:400])
    metrics = evaluate_model(pipe, X[400:], y_v[400:])
    assert metrics["r2"] > 0.0, f"R²={metrics['r2']:.3f} — model performs worse than mean"
