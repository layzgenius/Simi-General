#!/usr/bin/env python3
"""
Convert deam-msd-musicnn-2.pb (frozen TF1 graph) to ONNX.
Runs in Docker Stage 1 (Python 3.10, TF 2.12, numpy 1.23) — never at runtime.

Pipeline this enables (TF-free at runtime):
  audio → musicnn MSD_musicnn → 200-dim embeddings → DEAM ONNX head → arousal, valence
"""
import sys
import numpy as np
import tensorflow as tf
import tf2onnx
import onnxruntime as ort

PB_PATH   = "/models/deam-msd-musicnn-2.pb"
ONNX_PATH = "/models/deam.onnx"

# ── Load frozen graph ─────────────────────────────────────────────────────────
graph_def = tf.compat.v1.GraphDef()
with open(PB_PATH, "rb") as f:
    graph_def.ParseFromString(f.read())

# ── Inspect: find input placeholder and output tensor ────────────────────────
with tf.compat.v1.Graph().as_default() as g:
    tf.import_graph_def(graph_def, name="")
    ops = g.get_operations()

    placeholders = [op for op in ops if op.type == "Placeholder"]
    print("Placeholder tensors (input candidates):")
    for p in placeholders:
        for out in p.outputs:
            print(f"  {out.name}  shape={out.shape}  dtype={out.dtype}")

    print("\nLast 8 ops (output candidates):")
    for op in ops[-8:]:
        for out in op.outputs:
            print(f"  {op.type}: {out.name}  shape={out.shape}")

if not placeholders:
    print("ERROR: no Placeholder ops found in graph — cannot convert", file=sys.stderr)
    sys.exit(1)

input_name  = placeholders[0].outputs[0].name   # e.g. "model/Placeholder:0"
output_name = "model/Identity:0"                 # as used by Essentia TensorflowPredict2D

print(f"\nUsing: input={input_name!r}  output={output_name!r}")

# ── Convert to ONNX ───────────────────────────────────────────────────────────
# DEAM head input: batch of 200-dim MSD-MusiCNN embeddings (n_frames × 200)
input_spec = (
    tf.TensorSpec((None, 200), tf.float32, name=input_name.replace(":0", "")),
)

try:
    tf2onnx.convert.from_graph_def(
        graph_def,
        input_names=[input_name],
        output_names=[output_name],
        input_signature=input_spec,
        opset=13,
        output_path=ONNX_PATH,
    )
except Exception as e:
    # If "model/Identity:0" isn't found, try the last op's output
    print(f"First attempt failed ({e}), retrying with auto-detected output...")
    with tf.compat.v1.Graph().as_default() as g:
        tf.import_graph_def(graph_def, name="")
        last_output = g.get_operations()[-1].outputs[0].name
    print(f"  Using output={last_output!r}")
    tf2onnx.convert.from_graph_def(
        graph_def,
        input_names=[input_name],
        output_names=[last_output],
        input_signature=input_spec,
        opset=13,
        output_path=ONNX_PATH,
    )

# ── Validate ──────────────────────────────────────────────────────────────────
sess   = ort.InferenceSession(ONNX_PATH, providers=["CPUExecutionProvider"])
dummy  = np.random.randn(10, 200).astype(np.float32)   # 10 frames, 200-dim
result = sess.run(None, {sess.get_inputs()[0].name: dummy})

assert result[0].shape == (10, 2), f"Unexpected output shape: {result[0].shape}"
print(f"\n✅ DEAM ONNX saved to {ONNX_PATH}")
print(f"   Output shape: {result[0].shape}  (n_frames × [arousal, valence])")
print(f"   Sample frame: arousal={result[0][0, 0]:.3f}  valence={result[0][0, 1]:.3f}")
