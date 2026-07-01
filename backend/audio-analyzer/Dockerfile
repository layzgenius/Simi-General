# ── Stage 1: Convert DEAM .pb → ONNX ─────────────────────────────────────────
# Isolated TF 2.12 environment. Only artifact that survives: /models/deam.onnx
# ──────────────────────────────────────────────────────────────────────────────
FROM python:3.10-slim AS deam-converter

RUN apt-get update && apt-get install -y wget && rm -rf /var/lib/apt/lists/*

# TF 2.12 is the last release with numpy<1.24 support — needed for essentia's .pb format.
# tf2onnx and onnxruntime are only here for conversion + validation; not in the runtime image.
RUN pip install --no-cache-dir \
      'numpy==1.23.5' \
      'tensorflow-cpu==2.12.0' \
      'tf2onnx>=1.14' \
      'onnxruntime'

RUN mkdir -p /models && \
    wget -q -O /models/deam-msd-musicnn-2.pb \
      https://essentia.upf.edu/models/classification-heads/deam/deam-msd-musicnn-2.pb

COPY convert_deam.py /convert_deam.py
RUN python /convert_deam.py


# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM python:3.10-slim

RUN apt-get update && apt-get install -y \
    ffmpeg \
    libsndfile1 \
    wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# tensorflow-cpu: required by musicnn at import time
RUN pip install --no-cache-dir tensorflow-cpu

# musicnn: install without deps — uses tensorflow-cpu above
RUN pip install --no-cache-dir musicnn==0.1.0 --no-deps

# Bake models into image at build time — no download on cold start.
# DCLAP ONNX (512-dim) baked here; DEAM ONNX copied from Stage 1 below.
RUN mkdir -p /app/models && \
    wget -q -O /app/models/model_epoch_36.onnx \
      https://github.com/NeptuneHub/AudioMuse-AI-DCLAP/releases/download/v1/model_epoch_36.onnx && \
    wget -q -O /app/models/model_epoch_36.onnx.data \
      https://github.com/NeptuneHub/AudioMuse-AI-DCLAP/releases/download/v1/model_epoch_36.onnx.data

# DEAM ONNX converted in Stage 1 — no TF needed at runtime
COPY --from=deam-converter /models/deam.onnx /app/models/deam.onnx

COPY . .

EXPOSE 7860

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "7860"]
