FROM python:3.11-slim

RUN apt-get update && apt-get install -y \
    ffmpeg \
    libsndfile1 \
    wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN pip install --no-cache-dir \
      --extra-index-url https://essentia.upf.edu/python-extras/ \
      'essentia-tensorflow==2.1b6.dev1110' || \
    echo "⚠️  essentia-tensorflow unavailable — arousal/valence disabled"

COPY . .

# Download models at startup so Railway's build network doesn't block them.
CMD ["sh", "-c", "\
  mkdir -p /app/models && \
  if [ ! -f /app/models/msd-musicnn-1.pb ]; then \
    wget -q -O /app/models/msd-musicnn-1.pb \
      https://essentia.upf.edu/models/feature-extractors/musicnn/msd-musicnn-1.pb || true; \
  fi && \
  if [ ! -f /app/models/deam-msd-musicnn-2.pb ]; then \
    wget -q -O /app/models/deam-msd-musicnn-2.pb \
      https://essentia.upf.edu/models/classification-heads/deam/deam-msd-musicnn-2.pb || true; \
  fi && \
  if [ ! -f /app/models/model_epoch_36.onnx ]; then \
    wget -q -O /app/models/model_epoch_36.onnx \
      https://github.com/NeptuneHub/AudioMuse-AI-DCLAP/releases/download/v1/model_epoch_36.onnx || true; \
  fi && \
  if [ ! -f /app/models/model_epoch_36.onnx.data ]; then \
    wget -q -O /app/models/model_epoch_36.onnx.data \
      https://github.com/NeptuneHub/AudioMuse-AI-DCLAP/releases/download/v1/model_epoch_36.onnx.data || true; \
  fi && \
  uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"]
