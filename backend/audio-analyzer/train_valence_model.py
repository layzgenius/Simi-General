"""
Train sklearn GradientBoostingRegressor pipelines for DEAM valence + arousal.

Usage:
  python train_valence_model.py --features ml/deam_features.npz --output-dir ml/

Output:
  ml/valence_pipeline.joblib   — sklearn Pipeline (StandardScaler + GBM)
  ml/arousal_pipeline.joblib   — sklearn Pipeline (StandardScaler + GBM)

Why sklearn GBM instead of XGBoost:
  coremltools.converters.sklearn.convert() has native support for GBM Pipelines.
  XGBoost requires an ONNX intermediate step. R² is equivalent on ~1800 clips.
"""
import argparse, os
import numpy as np, pandas as pd, joblib
from sklearn.ensemble import GradientBoostingRegressor
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from sklearn.metrics import r2_score, mean_squared_error


def train_model(X_train: np.ndarray, y_train: np.ndarray) -> Pipeline:
    """Fit a StandardScaler + GradientBoostingRegressor pipeline.

    n_iter_no_change provides early stopping to prevent overfit on small datasets.
    StandardScaler is bundled into the pipeline so coremltools converts both together.
    """
    pipeline = Pipeline([
        ("scaler", StandardScaler()),
        ("gbm", GradientBoostingRegressor(
            n_estimators=500,
            max_depth=4,
            learning_rate=0.05,
            subsample=0.8,
            min_samples_leaf=5,
            n_iter_no_change=30,
            validation_fraction=0.1,
            random_state=42,
        ))
    ])
    pipeline.fit(X_train, y_train)
    return pipeline


def evaluate_model(pipeline: Pipeline, X_val: np.ndarray, y_val: np.ndarray) -> dict:
    """Evaluate on held-out data. Clips predictions to [0,1] before scoring."""
    preds = np.clip(pipeline.predict(X_val), 0.0, 1.0)
    return {
        "r2":   float(r2_score(y_val, preds)),
        "rmse": float(np.sqrt(mean_squared_error(y_val, preds))),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--features",    default="ml/deam_features.npz")
    parser.add_argument("--output-dir",  default="ml")
    args = parser.parse_args()

    data   = np.load(args.features)
    X      = data["X"]
    y_v    = data["y_valence"]
    y_a    = data["y_arousal"]
    print(f"Dataset: {X.shape[0]} clips × {X.shape[1]} features")
    print(f"Valence: [{y_v.min():.2f}, {y_v.max():.2f}]  mean={y_v.mean():.2f}")
    print(f"Arousal: [{y_a.min():.2f}, {y_a.max():.2f}]  mean={y_a.mean():.2f}")

    # 80/20 stratified split by valence quartile
    strat = pd.qcut(y_v, 4, labels=False)
    X_tr, X_val, yv_tr, yv_val, ya_tr, ya_val = train_test_split(
        X, y_v, y_a, test_size=0.2, stratify=strat, random_state=42
    )

    for name, y_tr, y_val_arr in [("valence", yv_tr, yv_val),
                                   ("arousal",  ya_tr, ya_val)]:
        print(f"\nTraining {name}...")
        pipeline = train_model(X_tr, y_tr)
        metrics  = evaluate_model(pipeline, X_val, y_val_arr)
        print(f"  R²={metrics['r2']:.3f}  RMSE={metrics['rmse']:.3f}", end="")
        if metrics["r2"] < 0.5:
            print("  ⚠️  below 0.50 target — try max_depth=5 or learning_rate=0.1")
        else:
            print("  ✅")
        out = os.path.join(args.output_dir, f"{name}_pipeline.joblib")
        joblib.dump(pipeline, out)
        print(f"  Saved → {out}")


if __name__ == "__main__":
    main()
