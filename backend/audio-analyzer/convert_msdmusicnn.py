#!/usr/bin/env python3
"""
Convert msd-musicnn-1.pb (frozen TF1 graph) to ONNX.
Runs in Docker Stage 1 only — never at runtime.

This model is the Essentia MSD-MusiCNN backbone used as input to the DEAM
arousal/valence head. Converting it to ONNX lets us run the full pipeline
at runtime without TensorFlow:
  audio → mel patches → msd-musicnn ONNX → 200-dim embeddings → DEAM ONNX → arousal, valence

Input/output tensor names are auto-detected by graph inspection and printed
so they can be hardcoded in future runs if needed.
"""
import sys
import numpy as np
import tensorflow as tf
import tf2onnx
import onnxruntime as ort

PB_PATH   = "/models/msd-musicnn-1.pb"
ONNX_PATH = "/models/msd-musicnn.onnx"

# Load frozen graph
graph_def = tf.compat.v1.GraphDef()
with open(PB_PATH, "rb") as f:
    graph_def.ParseFromString(f.read())

# Inspect: find input placeholder and output tensor
with tf.compat.v1.Graph().as_default() as g:
    tf.import_graph_def(graph_def, name="")
    ops = g.get_operations()

    placeholders = [op for op in ops if op.type == "Placeholder"]
    print("Placeholder tensors (input candidates):")
    for p in placeholders:
        for out in p.outputs:
            print(f"  {out.name}  shape={out.shape}  dtype={out.dtype}")

    print("\nLast 10 ops (output candidates):")
    for op in ops[-10:]:
        for out in op.outputs:
            print(f"  {op.type}: {out.name}  shape={out.shape}")

if not placeholders:
    print("ERROR: no Placeholder ops found in graph", file=sys.stderr)
    sys.exit(1)

input_tensor = placeholders[0].outputs[0]
input_name   = input_tensor.name
input_shape  = [d.value for d in input_tensor.shape.dims] if input_tensor.shape.dims else []

# Replace None/unknown dims — musicnn patches are (batch, time_frames, mel_bins) = (None, 187, 96)
# If shape is fully unknown, default to this.
if not input_shape or all(d is None for d in input_shape):
    input_shape = [None, 187, 96]
else:
    input_shape = [None if d is None else d for d in input_shape]

print(f"\nUsing input shape override: {input_shape}")

# Try known output tensor names for musicnn models
output_name = None
with tf.compat.v1.Graph().as_default() as g:
    tf.import_graph_def(graph_def, name="")
    all_tensor_names = {
        out.name
        for op in g.get_operations()
        for out in op.outputs
    }
    for candidate in [
        "model/dense/BiasAdd:0",
        "model/dense_1/BiasAdd:0",
        "model/Identity:0",
        "model/Sigmoid:0",
    ]:
        if candidate in all_tensor_names:
            output_name = candidate
            break

if output_name is None:
    with tf.compat.v1.Graph().as_default() as g:
        tf.import_graph_def(graph_def, name="")
        output_name = g.get_operations()[-1].outputs[0].name
    print(f"Auto-detected output (last op): {output_name!r}")

print(f"\nConverting: input={input_name!r} shape={input_shape}  output={output_name!r}")

tf2onnx.convert.from_graph_def(
    graph_def,
    input_names=[input_name],
    output_names=[output_name],
    shape_override={input_name: input_shape},
    opset=13,
    output_path=ONNX_PATH,
)

# Validate — use shape from ONNX input (may differ from shape_override after conversion)
sess = ort.InferenceSession(ONNX_PATH, providers=["CPUExecutionProvider"])
inp  = sess.get_inputs()[0]
print(f"\nONNX input : {inp.name}  shape={inp.shape}")
print(f"ONNX output: {sess.get_outputs()[0].name}  shape={sess.get_outputs()[0].shape}")

# Build a dummy batch matching the ONNX input shape
dummy_dims = [d if isinstance(d, int) and d > 0 else 4 for d in inp.shape]
dummy = np.random.randn(*dummy_dims).astype(np.float32)
result = sess.run(None, {inp.name: dummy})

print(f"\n✅ MSD-MusiCNN ONNX saved to {ONNX_PATH}")
print(f"   Input shape:  {dummy.shape}")
print(f"   Output shape: {result[0].shape}  (expected n_patches × 200)")
