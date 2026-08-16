"""
Convert trained sklearn Pipelines to CoreML .mlpackage.
Run after train_valence_model.py.

Usage:
  python convert_to_coreml.py --model-dir ml/ --output-dir ml/
"""
import argparse, os, sys
import numpy as np, joblib

# coremltools warns that sklearn 1.6.1 exceeds its tested ceiling (1.5.1)
# and sets _HAS_SKLEARN=False, which disables the sklearn conversion API.
# Patch the flag before importing the converter — the GBM/StandardScaler
# serialisation format is stable across this minor version bump.
import coremltools._deps as _ct_deps
_ct_deps._HAS_SKLEARN = True  # noqa: SLF001

import coremltools as ct
from coremltools.converters.sklearn import convert as sklearn_convert
from coremltools.models import datatypes

N_FEATURES = 58


def convert_pipeline(pipeline, out_name: str, out_dir: str, label: str) -> ct.models.MLModel:
    """Convert sklearn Pipeline to CoreML .mlpackage with output named `label`.

    Args:
        pipeline:  Fitted sklearn Pipeline (StandardScaler + GBM).
        out_name:  Filename stem, e.g. "SimiValenceRegressor".
        out_dir:   Directory to write the .mlpackage into.
        label:     Output feature name ("valence" or "arousal").

    Returns:
        The saved MLModel instance.
    """
    print(f"Converting {out_name}...")

    # Pass label as output_feature_names string so the converter names the
    # output correctly at construction time.  The converter treats a string
    # as the prediction output name for regressors.
    cml = sklearn_convert(
        pipeline,
        input_features=[("features", datatypes.Array(N_FEATURES))],
        output_feature_names=label,
    )

    # Defensive rename: if the converter chose a different name, update the
    # top-level description AND any inner pipeline output that references it.
    spec = cml.get_spec()
    current_name = spec.description.output[0].name
    if current_name != label:
        # Update the pipeline spec's sub-model output references
        if spec.HasField("pipeline"):
            for step in spec.pipeline.models:
                for out in step.description.output:
                    if out.name == current_name:
                        out.name = label
        spec.description.output[0].name = label
        cml = ct.models.MLModel(spec)

    cml.author = "Simi"
    cml.version = "1.0"
    cml.short_description = f"DEAM {label} regressor (sklearn GBM, 58-feat SonicDNA vector)"

    out_path = os.path.join(out_dir, f"{out_name}.mlpackage")
    cml.save(out_path)

    total = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, files in os.walk(out_path)
        for f in files
    )
    print(f"  Saved: {out_path}  ({total / 1024:.0f} KB)")

    # Smoke test — reload from disk and run one prediction
    cml_reloaded = ct.models.MLModel(out_path)
    result = cml_reloaded.predict({"features": np.zeros(N_FEATURES, dtype=np.float64)})
    print(f"  Smoke test {label}=0 input -> {result}")

    return cml_reloaded


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert DEAM-trained sklearn Pipelines to CoreML .mlpackage files."
    )
    parser.add_argument("--model-dir", default="ml",
                        help="Directory containing *_pipeline.joblib files (default: ml)")
    parser.add_argument("--output-dir", default="ml",
                        help="Directory to write .mlpackage files into (default: ml)")
    args = parser.parse_args()

    for label in ("valence", "arousal"):
        job_path = os.path.join(args.model_dir, f"{label}_pipeline.joblib")
        if not os.path.isfile(job_path):
            print(f"ERROR: {job_path} not found — run train_valence_model.py first")
            sys.exit(1)
        pipeline = joblib.load(job_path)
        name = f"Simi{label.capitalize()}Regressor"
        convert_pipeline(pipeline, name, args.output_dir, label)

    print("\nBoth models converted.")
    print("Next: add SimiValenceRegressor.mlpackage and SimiArousalRegressor.mlpackage to Xcode target.")


if __name__ == "__main__":
    main()
