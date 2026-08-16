import os, sys, numpy as np, pytest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

ML_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "ml"))
VAL_PKG = os.path.join(ML_DIR, "SimiValenceRegressor.mlpackage")
ARO_PKG = os.path.join(ML_DIR, "SimiArousalRegressor.mlpackage")
VAL_JOB = os.path.join(ML_DIR, "valence_pipeline.joblib")

models_exist  = pytest.mark.skipif(not os.path.isdir(VAL_PKG), reason="run convert_to_coreml.py first")
joblibs_exist = pytest.mark.skipif(not os.path.isfile(VAL_JOB), reason="run train_valence_model.py first")


@models_exist
def test_both_mlpackages_exist():
    assert os.path.isdir(VAL_PKG), f"Missing {VAL_PKG}"
    assert os.path.isdir(ARO_PKG), f"Missing {ARO_PKG}"


@models_exist
def test_combined_size_under_5mb():
    total = 0
    for pkg in (VAL_PKG, ARO_PKG):
        for dp, _, files in os.walk(pkg):
            for f in files:
                total += os.path.getsize(os.path.join(dp, f))
    assert total < 5 * 1024 * 1024, f"Combined size {total/1024:.0f}KB exceeds 5MB"


@models_exist
@joblibs_exist
def test_coreml_matches_sklearn_within_tolerance():
    """CoreML and sklearn must agree within 1% on the same input."""
    import coremltools as ct, joblib
    cml = ct.models.MLModel(VAL_PKG)
    skl = joblib.load(VAL_JOB)
    rng = np.random.default_rng(99)
    for _ in range(5):
        row = rng.standard_normal(58)
        sk_pred  = float(np.clip(skl.predict([row])[0], 0, 1))
        ct_out   = cml.predict({"features": row})
        ct_pred  = float(list(ct_out.values())[0])
        assert abs(sk_pred - ct_pred) < 0.01, \
            f"sklearn={sk_pred:.4f} CoreML={ct_pred:.4f} — mismatch exceeds 1%"


@models_exist
def test_output_feature_name_is_valence():
    import coremltools as ct
    cml  = ct.models.MLModel(VAL_PKG)
    spec = cml.get_spec()
    names = [o.name for o in spec.description.output]
    assert "valence" in names, f"Output names: {names}. Update Swift featureValue(for:) key."
