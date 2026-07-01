FROM python:3.10-slim

RUN apt-get update && apt-get install -y \
    ffmpeg \
    libsndfile1 \
    wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# essentia-tensorflow: wheels exist for Python 3.10 but not 3.11.
# Brings TF2 as a dependency — musicnn uses this TF, no separate tensorflow-cpu needed.
RUN pip install --no-cache-dir \
      --extra-index-url https://essentia.upf.edu/python-extras/ \
      'essentia-tensorflow==2.1b6.dev1110'

# musicnn: install without deps — uses the TF2 that essentia-tensorflow installed above.
RUN pip install --no-cache-dir musicnn==0.1.0 --no-deps

# Bake all models into the image at build time.
# They survive container restarts (no download on cold start) and only
# re-download when this Dockerfile layer changes.
RUN mkdir -p /app/models && \
    wget -q -O /app/models/msd-musicnn-1.pb \
      https://essentia.upf.edu/models/feature-extractors/musicnn/msd-musicnn-1.pb && \
    wget -q -O /app/models/deam-msd-musicnn-2.pb \
      https://essentia.upf.edu/models/classification-heads/deam/deam-msd-musicnn-2.pb && \
    wget -q -O /app/models/model_epoch_36.onnx \
      https://github.com/NeptuneHub/AudioMuse-AI-DCLAP/releases/download/v1/model_epoch_36.onnx && \
    wget -q -O /app/models/model_epoch_36.onnx.data \
      https://github.com/NeptuneHub/AudioMuse-AI-DCLAP/releases/download/v1/model_epoch_36.onnx.data

COPY . .

EXPOSE 7860

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "7860"]
