#!/usr/bin/env python3
"""
Convert deam-msd-musicnn-2.pb (frozen TF1 graph) to ONNX.
Runs in Docker Stage 1 only — never at runtime.

Confirmed tensor names (from graph inspection on first run):
  input:  model/Placeholder:0  shape=(None, 200)  dtype=float32
  output: model/Identity:0     shape=(None, 2)
"""
import numpy as np
import tensorflow as tf
import tf2onnx
import onnxruntime as ort

PB_PATH   = "/models/deam-msd-musicnn-2.pb"
ONNX_PATH = "/models/deam.onnx"

INPUT_NAME  = "model/Placeholder:0"
OUTPUT_NAME = "model/Identity:0"

# Load frozen graph
graph_def = tf.compat.v1.GraphDef()
with open(PB_PATH, "rb") as f:
    graph_def.ParseFromString(f.read())

print(f"Converting: input={INPUT_NAME!r}  output={OUTPUT_NAME!r}")

# from_graph_def uses shape_override (not input_signature) for frozen graphs
tf2onnx.convert.from_graph_def(
    graph_def,
    input_names=[INPUT_NAME],
    output_names=[OUTPUT_NAME],
    shape_override={INPUT_NAME: [None, 200]},
    opset=13,
    output_path=ONNX_PATH,
)

# Validate
sess   = ort.InferenceSession(ONNX_PATH, providers=["CPUExecutionProvider"])
dummy  = np.random.randn(10, 200).astype(np.float32)
result = sess.run(None, {sess.get_inputs()[0].name: dummy})

assert result[0].shape == (10, 2), f"Unexpected output shape: {result[0].shape}"
print(f"✅ DEAM ONNX saved to {ONNX_PATH}")
print(f"   Output shape: {result[0].shape}  (n_frames × [arousal, valence])")
print(f"   Sample: arousal={result[0][0,0]:.3f}  valence={result[0][0,1]:.3f}")
