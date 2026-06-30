"""
audio_analyzer.py
Simi — On-device equivalent audio analysis.

Extracts the same features AudioFeatures.swift expects:
  bpm, energy, valence, danceability, acousticness,
  instrumentalness, liveness, loudness, key, mode

All features are in the same 0.0–1.0 ranges (or specific units) as
the Spotify audio-features schema that Simi's iOS app already understands.

Pipeline for URL/bytes inputs (the hot path):
  1. ffmpeg pipe-decode: audio bytes → float32 PCM numpy array, no disk write
  2. _analyze_pcm: feature extraction directly on the array
  audioFlux is used for MFCC if installed (3–8× faster than librosa on Linux x86_64).
  librosa stays for HPSS, tonnetz, beat-track — audioFlux has no equivalents.
"""

from __future__ import annotations

import asyncio
import os
import tempfile
import threading
import urllib.request
import warnings
import numpy as np
import librosa
import httpx
from dataclasses import dataclass

try:
    import audioflux as af
    _AUDIOFLUX_AVAILABLE = True
except ImportError:
    _AUDIOFLUX_AVAILABLE = False

# Suppress librosa/soundfile fallback noise. PySoundFile can't decode MP3/M4A
# (libsndfile has no MP3 codec), so librosa always falls back to audioread for
# those formats. This is expected; the warnings add no actionable signal.
warnings.filterwarnings("ignore", message="PySoundFile failed", category=UserWarning)
warnings.filterwarnings("ignore", category=FutureWarning, module="librosa")


# ─────────────────────────────────────────────
# Krumhansl-Schmuckler key profiles
# Used to detect musical key + major/minor from chroma
# ─────────────────────────────────────────────
MAJOR_PROFILE = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                           2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
MINOR_PROFILE = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                           2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


@dataclass
class AudioFeatures:
    bpm:              float   # Beats per minute
    energy:           float   # 0–1  RMS-derived intensity
    valence:          float   # 0–1  estimated mood positivity
    danceability:     float   # 0–1  rhythm regularity × tempo sweet spot
    acousticness:     float   # 0–1  absence of electronic harshness
    instrumentalness: float   # 0–1  low vocal presence estimate
    liveness:         float   # 0–1  live recording probability (heuristic)
    loudness:         float   # dBFS, typically −60 to 0
    key:              int     # 0=C … 11=B
    mode:             int     # 1=major, 0=minor
    spectral_warmth:  float = 0.0  # hardcoded 0.5 — broken formula, see TODO
    tonal_clarity:    float = 0.0  # 0–1  harmonic focus (RMS magnitude of tonnetz)
    vocal_presence:   float = 0.5  # disabled — hardcoded 0.5
    reverb_space:     float = 0.5  # disabled — hardcoded 0.5
    is_estimated:     bool = True
    is_key_estimated: bool = False
    # Extended librosa features (None when not computed)
    mfcc_mean:               list | None = None   # 20 MFCC coefficient means
    mfcc_std:                list | None = None   # 20 MFCC coefficient stds
    spectral_contrast_bands: list | None = None   # 7-band spectral contrast means
    chroma_cqt_mean:         list | None = None   # 12-bin chroma CQT means
    chroma_entropy:          float | None = None  # normalized chroma entropy [0,1]
    zcr_mean:                float | None = None  # zero-crossing rate mean
    rolloff_norm:            float | None = None  # spectral rolloff / Nyquist [0,1]
    onset_mean:              float | None = None  # onset strength mean
    onset_std:               float | None = None  # onset strength std
    groove_ratio:            float | None = None  # onset_std / onset_mean — syncopation proxy (funky ~0.8–1.8, smooth ~0.3–0.7)
    # Essentia DEAM arousal/valence (None when essentia unavailable)
    arousal:                 float | None = None  # DEAM arousal [0,1]
    valence_essentia:        float | None = None  # DEAM valence [0,1]
    # DCLAP neural embedding (None when onnxruntime unavailable)
    dclap_embedding:         list | None = None   # 512-dim L2-normalised float32 vector


# ─────────────────────────────────────────────
# Essentia DEAM arousal/valence
# Models are downloaded once at startup and kept in memory.
# ─────────────────────────────────────────────

_ESSENTIA_MODELS_DIR = "/app/models"
_MUSICNN_URL = "https://essentia.upf.edu/models/feature-extractors/msd-musicnn/msd-musicnn-1.pb"
_DEAM_URL    = "https://essentia.upf.edu/models/classification-heads/deam/deam-msd-musicnn-2.pb"

_essentia_available: bool = False
_essentia_lock             = threading.Lock()
_musicnn_model             = None
_deam_model                = None


def _download_essentia_models() -> bool:
    os.makedirs(_ESSENTIA_MODELS_DIR, exist_ok=True)
    mp = os.path.join(_ESSENTIA_MODELS_DIR, "msd-musicnn-1.pb")
    dp = os.path.join(_ESSENTIA_MODELS_DIR, "deam-msd-musicnn-2.pb")
    try:
        if not os.path.exists(mp):
            print("⬇️  Downloading MusiCNN backbone (~100 MB)…")
            urllib.request.urlretrieve(_MUSICNN_URL, mp)
        if not os.path.exists(dp):
            print("⬇️  Downloading DEAM prediction head…")
            urllib.request.urlretrieve(_DEAM_URL, dp)
        return True
    except Exception as e:
        print(f"⚠️  Essentia model download failed: {e}")
        return False


def init_essentia() -> None:
    """
    Call once at app startup (from main.py on_startup).
    Downloads models if needed, loads them into memory, sets _essentia_available.
    """
    global _essentia_available, _musicnn_model, _deam_model
    with _essentia_lock:
        if _essentia_available:
            return
        try:
            import essentia.standard  # noqa: F401 — probe import
        except ImportError:
            print("⚠️  essentia-tensorflow not installed — DEAM disabled")
            return
        if not _download_essentia_models():
            return
        try:
            import essentia.standard as es
            mp = os.path.join(_ESSENTIA_MODELS_DIR, "msd-musicnn-1.pb")
            dp = os.path.join(_ESSENTIA_MODELS_DIR, "deam-msd-musicnn-2.pb")
            _musicnn_model = es.TensorflowPredictMusiCNN(
                graphFilename=mp, output="model/dense/BiasAdd"
            )
            _deam_model = es.TensorflowPredict2D(
                graphFilename=dp, output="model/Identity"
            )
            _essentia_available = True
            print("✅ Essentia DEAM ready")
        except Exception as e:
            print(f"⚠️  Essentia model load failed: {e}")


def extract_arousal_valence(audio_path: str) -> tuple[float, float] | None:
    """Run DEAM on a local file. Returns (arousal, valence) ∈ [0,1] or None."""
    if not _essentia_available:
        return None
    try:
        import essentia.standard as es
        audio_16k   = es.MonoLoader(filename=audio_path, sampleRate=16000, resampleQuality=4)()
        embeddings  = _musicnn_model(audio_16k)
        predictions = _deam_model(embeddings)
        mean_pred   = np.array(predictions).mean(axis=0)
        # DEAM outputs on 1–9 scale; normalize to [0,1]
        arousal     = float(np.clip((mean_pred[0] - 1.0) / 8.0, 0.0, 1.0))
        val_ess     = float(np.clip((mean_pred[1] - 1.0) / 8.0, 0.0, 1.0))
        return arousal, val_ess
    except Exception as e:
        print(f"⚠️  Essentia prediction failed: {e}")
        return None


# ─────────────────────────────────────────────
# DCLAP — 7M-param distilled CLAP ONNX model (512-dim emotional embeddings)
# Loaded once at startup alongside Essentia. Baked into /app/models/ in Docker.
# ─────────────────────────────────────────────

_DCLAP_MODEL_PATH = "/app/models/model_epoch_36.onnx"

_dclap_available: bool = False
_dclap_lock             = threading.Lock()
_dclap_session          = None   # onnxruntime.InferenceSession


def init_dclap() -> None:
    """
    Call once at app startup (from main.py on_startup).
    Loads the DCLAP ONNX session into memory and sets _dclap_available.
    """
    global _dclap_available, _dclap_session
    with _dclap_lock:
        if _dclap_available:
            return
        if not os.path.exists(_DCLAP_MODEL_PATH):
            print(f"⚠️  DCLAP model not found at {_DCLAP_MODEL_PATH} — embedding disabled")
            return
        try:
            import onnxruntime as ort
            _dclap_session = ort.InferenceSession(
                _DCLAP_MODEL_PATH,
                providers=["CPUExecutionProvider"],
            )
            _dclap_available = True
            print("✅ DCLAP ONNX session ready")
        except Exception as e:
            print(f"⚠️  DCLAP model load failed: {e}")


def get_dclap_embedding(audio_path: str) -> list[float] | None:
    """
    Compute a 512-dim DCLAP embedding for an audio file.

    Preprocessing (matches DCLAP training pipeline):
      - Load at 48 kHz mono
      - Clip to [-1, 1], quantise to int16 and back to float32
      - Split into 10 s chunks (480 000 samples) with 50 % overlap (240 000 stride)
      - Log-mel spectrogram: n_fft=2048, hop=480, n_mels=128, fmin=0, fmax=14000
      - Feed each chunk as shape (1, 1, 128, time_frames) to the "mel_spectrogram" input
      - Average embeddings across all chunks, then L2-normalise

    Returns a list of 512 floats, or None on any failure.
    """
    if not _dclap_available:
        return None
    try:
        y, sr = librosa.load(audio_path, sr=48000, mono=True)
        # Int16 quantisation — matches the DCLAP training pre-processing
        y = np.clip(y, -1.0, 1.0)
        y = (y * 32767).astype(np.int16).astype(np.float32) / 32767.0

        chunk_size  = 480_000   # 10 s at 48 kHz
        hop_size    = 240_000   # 50 % overlap
        embeddings  = []

        for start in range(0, max(1, len(y) - chunk_size + 1), hop_size):
            chunk = y[start : start + chunk_size]
            if len(chunk) < chunk_size:
                chunk = np.pad(chunk, (0, chunk_size - len(chunk)))

            mel = librosa.feature.melspectrogram(
                y=chunk, sr=sr,
                n_fft=2048, hop_length=480, n_mels=128,
                fmin=0, fmax=14000,
            )
            log_mel = librosa.power_to_db(mel, ref=np.max)
            # shape → (1, 1, 128, time_frames)
            inp = log_mel[np.newaxis, np.newaxis, :, :].astype(np.float32)
            out = _dclap_session.run(None, {"mel_spectrogram": inp})
            embeddings.append(out[0].squeeze())

        if not embeddings:
            return None

        mean_emb = np.mean(embeddings, axis=0)
        norm = np.linalg.norm(mean_emb)
        if norm < 1e-8:
            return None
        normalised = (mean_emb / norm).astype(np.float32)
        return [round(float(v), 6) for v in normalised]
    except Exception as e:
        print(f"⚠️  DCLAP embedding failed: {e}")
        return None


# ─────────────────────────────────────────────
# Key detection — chroma ensemble + confidence threshold
# ─────────────────────────────────────────────

def detect_key(y: np.ndarray, sr: int, bpm: float = 120.0,
               energy: float = 0.5, danceability: float = 0.5,
               acousticness: float = 0.5) -> tuple[int, int]:
    """
    Returns (key 0–11, mode 0=minor/1=major, ks_margin).

    Bias logic:
    - warm = energy > 0.20 AND danceability > 0.35 AND bpm > 60
      → +0.08 toward major (handles funk/soul at low volume like Outstanding).
      Energy threshold lowered from 0.30 so quiet soul ballads (energy≈0.25)
      still get the bias; bad guy's KS minor advantage (>0.11) easily clears it.
    - very_quiet_acoustic = acousticness > 0.80 AND energy < 0.50
      → +0.30 toward minor (raises the threshold for calling something major).
      Motion Picture Soundtrack: KS margin=+0.179 major, but threshold becomes
      0.22 so it correctly falls into minor.
    """
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
    mean_chroma = chroma.mean(axis=1)

    major_scores = []
    minor_scores = []
    for shift in range(12):
        rotated = np.roll(mean_chroma, -shift)
        major_scores.append(float(np.corrcoef(rotated, MAJOR_PROFILE)[0, 1]))
        minor_scores.append(float(np.corrcoef(rotated, MINOR_PROFILE)[0, 1]))

    best_major_key   = int(np.argmax(major_scores))
    best_minor_key   = int(np.argmax(minor_scores))
    best_major_score = max(major_scores)
    best_minor_score = max(minor_scores)

    margin = best_major_score - best_minor_score

    warm               = (energy > 0.20 and danceability > 0.35 and bpm > 60)
    very_quiet_acoustic = (acousticness > 0.80 and energy < 0.50)
    bias      = 0.08 if warm else 0.0
    anti_bias = 0.30 if very_quiet_acoustic else 0.0

    threshold = -bias + anti_bias   # major if margin >= threshold
    if margin >= threshold:
        return best_major_key, 1
    else:
        return best_minor_key, 0


# ─────────────────────────────────────────────
# BPM octave correction
# ─────────────────────────────────────────────

def _correct_bpm(y: np.ndarray, sr: int, bpm: float, energy: float = 0.5) -> float:
    """
    BPM octave correction.

    1. bpm > 165 → halve (Redbone 172.3 → 86.15).
    2a. 75 < bpm < 95 AND energy > 0.65 → double (Blinding Lights 86.1 → 172.2).
        High-energy songs at this BPM are almost always half-time detections; the
        kick/snare alternation fools beat_track but the song feels like 170+ BPM.
    2b. bpm < 95 → onset density check → double if ratio ≈ 2x
        (Outstanding 49.7 → 99.4).
    """
    if bpm > 165:
        while bpm > 165:
            c = bpm * 0.5
            if c < 40:
                break
            bpm = c
        return bpm

    elif bpm < 95:
        # 2a: energy-gated fast doubling — catches compressed synth-pop at half-time
        if 75 < bpm and energy > 0.65:
            c = bpm * 2.0
            if c <= 220:
                return c

        # 2b: onset density check for lower BPM (e.g. Outstanding ~50 → 99)
        onset_times = librosa.onset.onset_detect(
            y=y, sr=sr, units='time', delta=0.07, wait=6,
        )
        if len(onset_times) >= 8:
            duration_sec = len(y) / sr
            onset_density = len(onset_times) / duration_sec * 60.0
            ratio = onset_density / bpm
            if 1.75 <= ratio <= 2.30:
                c = bpm * 2.0
                if c <= 220:
                    return c

    return bpm


# ─────────────────────────────────────────────
# Feature extraction helpers
# ─────────────────────────────────────────────

def _rms_energy(y: np.ndarray) -> float:
    """
    Tanh-based energy normalization — avoids the hard-clip ceiling that made
    heavily compressed trap/hip-hop all land at 1.00.

    Expected output ranges (divisor=0.40):
      acoustic guitar (mean_rms ≈ 0.05–0.10) → ~0.12–0.24
      live rock / pop  (mean_rms ≈ 0.15–0.25) → ~0.36–0.53
      compressed hip-hop/trap (mean_rms ≈ 0.30–0.45) → ~0.64–0.80
      heavily limited trap  (mean_rms ≈ 0.50–0.65) → ~0.84–0.92
      (tanh asymptotes to 1.0; nothing hard-clips at 1.00)

    Direct NumPy replaces librosa.feature.rms — ~40× faster per research §2.4.
    Global sqrt(mean(y²)) is equivalent to the mean of per-frame RMS for the
    15-second clips we work with.
    """
    mean_rms = float(np.sqrt(np.mean(y ** 2)))
    return float(np.tanh(mean_rms / 0.40))


def _loudness_dbfs(y: np.ndarray) -> float:
    rms = float(np.sqrt(np.mean(y ** 2)))
    if rms < 1e-10:
        return -60.0
    return float(np.clip(20 * np.log10(rms), -60.0, 0.0))


def _danceability(y: np.ndarray, sr: int, bpm: float) -> float:
    """
    Combines:
      - Tempo sweet spot (90–130 BPM scores highest)
      - Beat strength regularity (how steady the rhythm is)
    """
    onset_env = librosa.onset.onset_strength(y=y, sr=sr)
    ac = librosa.autocorrelate(onset_env, max_size=sr // 2)
    ac = librosa.util.normalize(ac)
    regularity = float(np.clip(ac[1:].mean() * 2.5, 0.0, 1.0))
    tempo_score = float(np.exp(-((bpm - 120) ** 2) / (2 * 30 ** 2)))
    return float(np.clip(0.6 * regularity + 0.4 * tempo_score, 0.0, 1.0))


def _acousticness(y: np.ndarray, sr: int) -> float:
    """
    High acousticness = low high-frequency content + low spectral flatness.
    Electronic/distorted sounds have high spectral flatness and harsh highs.
    """
    flatness = float(librosa.feature.spectral_flatness(y=y)[0].mean())
    rolloff = librosa.feature.spectral_rolloff(y=y, sr=sr, roll_percent=0.85)
    mean_rolloff = float(rolloff[0].mean())
    rolloff_score = float(np.clip(1.0 - (mean_rolloff / (sr / 2.2)), 0.0, 1.0))
    return float(np.clip((1.0 - flatness * 3.0) * 0.5 + rolloff_score * 0.5, 0.0, 1.0))


def _instrumentalness(y: np.ndarray, sr: int) -> float:
    """
    Estimates absence of vocals using MFCC variance.
    Vocals occupy specific MFCC bands (2–6) with characteristic variance patterns.
    High variance in those bands → likely has vocals → low instrumentalness.
    Uses audioFlux for MFCC if available (3–8× faster), falls back to librosa.
    """
    if _AUDIOFLUX_AVAILABLE:
        try:
            mfcc_obj = af.MFCC(num=13, samplate=sr)
            mfcc, _ = mfcc_obj.mfcc(y)
            # audioFlux returns (n_frames, n_mfcc); normalize to (n_mfcc, n_frames)
            if mfcc.ndim == 2 and mfcc.shape[0] != 13:
                mfcc = mfcc.T
        except Exception:
            mfcc = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
    else:
        mfcc = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
    vocal_variance = float(mfcc[2:7].var(axis=1).mean())
    return float(np.clip(1.0 - vocal_variance / 5.0, 0.0, 1.0))


def _liveness(y: np.ndarray, sr: int) -> float:
    """
    Live recordings have more reverb tail and irregular low-frequency noise.
    Uses zero-crossing rate variance as a loose proxy.
    """
    zcr = librosa.feature.zero_crossing_rate(y)[0]
    variance = float(np.var(zcr))
    return float(np.clip(variance * 500.0, 0.0, 1.0))


def _valence(y: np.ndarray, sr: int, mode: int, bpm: float, energy: float,
             danceability: float, acousticness: float = 0.5,
             y_harmonic: np.ndarray | None = None,
             sc: np.ndarray | None = None,
             tn: np.ndarray | None = None) -> float:
    """
    Valence (mood positivity) estimation — v4.

    Components:
      - mode_score:       major/minor polarity (reduced weight; minor ≠ always dark)
      - tonal_brightness: tonnetz fifth + major-third cos projections — continuous
                          harmonic brightness vs the binary mode signal
      - sc_brightness:    spectral contrast upper bands (bands 3-5, ~1600-12800 Hz)
                          on the HARMONIC component — more stable than centroid;
                          measures peak/valley difference (vivid vs muddy)
      - tempo_score:      mode-split tempo contribution
      - energy:           global intensity
      - harmonic_ratio:   harmonic energy / total energy — melodic songs score higher
                          than purely percussive trap; separates Tiramisu from HUMBLE.
      - groove correction: minor-key groovy songs (+0.12)
      - warm ballad correction: slow major-key songs (+0.08)
      - high-energy fast minor correction: energetic synth-pop (+0.05)

    v4 changes vs v3:
      - Accepts optional pre-computed y_harmonic, sc, tn to avoid redundant HPSS/SC/TN
        work when analyze_from_url already computed them for the new features
      - Replaces centroid brightness with sc_brightness (upper spectral contrast bands)
      - Adds tonal_brightness from tonnetz (0.10 weight)
      - Reduces mode_score weight 0.35 → 0.25
      - Weights: mode 0.25, tonal_brightness 0.10, sc_brightness 0.20,
                 tempo 0.15, energy 0.15, harmonic_ratio 0.15
    """
    if y_harmonic is None:
        y_harmonic, _ = librosa.effects.hpss(y)
    if sc is None:
        sc = librosa.feature.spectral_contrast(y=y_harmonic, sr=sr, n_bands=6)
    if tn is None:
        tn = librosa.feature.tonnetz(y=y_harmonic, sr=sr)

    mode_score = 0.65 if mode == 1 else 0.35

    sc_brightness = float(np.clip(sc[3:6].mean() / 25.0, 0.0, 1.0))

    tonal_raw = float((tn[0] + tn[4]).mean() / 2.0)
    tonal_brightness = float(np.clip((tonal_raw + 0.3) / 0.6, 0.0, 1.0))

    harmonic_power = float(np.mean(y_harmonic ** 2))
    total_power    = float(np.mean(y ** 2))
    if total_power > 1e-10:
        harmonic_ratio = float(np.clip(harmonic_power / total_power * 2.5, 0.0, 1.0))
    else:
        harmonic_ratio = 0.5

    if mode == 1:
        tempo_score = float(np.clip((bpm - 40) / 160.0, 0.0, 1.0))
    else:
        tempo_score = float(np.clip((bpm - 60) / 140.0, 0.0, 1.0))

    valence = (0.25 * mode_score +
               0.10 * tonal_brightness +
               0.20 * sc_brightness +
               0.15 * tempo_score +
               0.15 * energy +
               0.15 * harmonic_ratio)

    # ── Groove correction ────────────────────────────────────────────
    # Groovy minor-key songs that feel positive (Get Lucky, Murder on the Dancefloor).
    # acousticness < 0.80 prevents sparse acoustic tracks (Motion Picture Soundtrack,
    # acousticness=0.88) from triggering this even when their beat is very regular.
    # energy > 0.50: Get Lucky measures 0.5493 post-tanh; 0.55 threshold was too tight.
    if danceability > 0.70 and energy > 0.50 and bpm > 100 and acousticness < 0.80:
        valence += 0.12

    # ── Warm ballad correction ────────────────────────────────────────
    if mode == 1 and bpm < 100 and energy < 0.60 and danceability > 0.35:
        valence += 0.08

    # ── High-energy fast minor correction ────────────────────────────
    # Energetic synth-pop / new-wave minor-key songs (Blinding Lights, F minor)
    # feel much more positive than their KS minor score suggests.
    if mode == 0 and energy > 0.65 and bpm > 150:
        valence += 0.05

    # ── Aggressive fast major penalty ────────────────────────────────
    # Fast major-key songs with high energy but low danceability are often
    # aggressive anthems (HUMBLE. — C# major, 152 BPM, energy=0.67, dance=0.54),
    # not joyful pop. The mode+tempo formula over-scores these as happy.
    if mode == 1 and energy > 0.60 and danceability < 0.65 and bpm > 140:
        valence -= 0.12

    # ── Low-energy minor cap ──────────────────────────────────────────
    # Minor-key songs with low energy are emotionally dark even when sc_brightness
    # and harmonic_ratio are high (strings, piano, sparse electronics all score
    # bright on spectral features despite melancholic content). Cap prevents
    # false-positive valence for dark songs (bad guy, Motion Picture Soundtrack).
    # Blinding Lights is safe: mode=0 but energy=0.70 ≥ 0.50 → not capped.
    if mode == 0 and energy < 0.50:
        valence = min(valence, 0.45)

    return float(np.clip(valence, 0.0, 1.0))


# ─────────────────────────────────────────────
# Extended librosa feature extraction
# ─────────────────────────────────────────────

def _extract_extended(y: np.ndarray, sr: int,
                      sc: np.ndarray) -> dict:
    """
    Compute extended librosa features. `sc` is the pre-computed spectral contrast
    array (shape 7×frames) from y_harmonic — reused to avoid redundant HPSS.

    Returns a dict ready to splat into AudioFeatures fields.
    """
    # MFCCs (20 coefficients) — audioFlux if available (3–8× faster), else librosa
    if _AUDIOFLUX_AVAILABLE:
        try:
            mfcc_obj  = af.MFCC(num=20, samplate=sr)
            mfcc_all, _ = mfcc_obj.mfcc(y)
            if mfcc_all.ndim == 2 and mfcc_all.shape[0] != 20:
                mfcc_all = mfcc_all.T  # normalize to (n_mfcc, n_frames)
        except Exception:
            mfcc_all = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=20)
    else:
        mfcc_all = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=20)
    mfcc_mean    = [round(float(v), 4) for v in mfcc_all.mean(axis=1)]
    mfcc_std     = [round(float(v), 4) for v in mfcc_all.std(axis=1)]

    # Spectral contrast — reuse pre-computed sc (7 bands × frames)
    sc_means     = [round(float(v), 4) for v in sc.mean(axis=1)]

    # Chroma CQT
    chroma_arr   = librosa.feature.chroma_cqt(y=y, sr=sr)
    chroma_means = [round(float(v), 4) for v in chroma_arr.mean(axis=1)]
    chroma_probs = chroma_arr.mean(axis=1)
    chroma_probs = chroma_probs / (chroma_probs.sum() + 1e-10)
    chroma_ent   = float(-np.sum(chroma_probs * np.log2(chroma_probs + 1e-10)))
    chroma_ent_n = round(chroma_ent / np.log2(12), 4)  # normalize to [0,1]

    # Zero-crossing rate
    zcr_val      = round(float(librosa.feature.zero_crossing_rate(y)[0].mean()), 6)

    # Spectral rolloff — normalized to Nyquist
    rolloff_raw  = float(librosa.feature.spectral_rolloff(y=y, sr=sr, roll_percent=0.85)[0].mean())
    rolloff_val  = round(float(np.clip(rolloff_raw / (sr / 2), 0.0, 1.0)), 4)

    # Onset strength
    onset_env    = librosa.onset.onset_strength(y=y, sr=sr)
    onset_m      = round(float(onset_env.mean()), 4)
    onset_s      = round(float(onset_env.std()), 4)
    _eps = 1e-8
    groove_r     = round(float(onset_env.std() / (onset_env.mean() + _eps)), 4) if len(onset_env) > 0 else None

    return dict(
        mfcc_mean               = mfcc_mean,
        mfcc_std                = mfcc_std,
        spectral_contrast_bands = sc_means,
        chroma_cqt_mean         = chroma_means,
        chroma_entropy          = chroma_ent_n,
        zcr_mean                = zcr_val,
        rolloff_norm            = rolloff_val,
        onset_mean              = onset_m,
        onset_std               = onset_s,
        groove_ratio            = groove_r,
    )


# ─────────────────────────────────────────────
# ffmpeg pipe decoder + PCM analysis
# ─────────────────────────────────────────────

_FFMPEG_SR = 22050  # target sample rate matching librosa.load default

async def _decode_via_ffmpeg(audio_bytes: bytes) -> tuple[np.ndarray, int] | None:
    """
    Decode audio bytes to float32 PCM via ffmpeg subprocess pipe.
    No temp file — bytes go to stdin, PCM comes from stdout.
    ffmpeg is pre-installed in the Railway Dockerfile.
    Eliminates both the disk write and the librosa/audioread MP3 fallback path.
    """
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-i", "pipe:0",
        "-f", "f32le",             # float32 little-endian PCM output
        "-ar", str(_FFMPEG_SR),    # resample to 22050 Hz
        "-ac", "1",                # mono
        "pipe:1",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    stdout, _ = await proc.communicate(input=audio_bytes)
    if proc.returncode != 0 or not stdout:
        return None
    # .copy() makes the buffer writable — required by librosa ops (beat_track, hpss)
    y = np.frombuffer(stdout, dtype=np.float32).copy()
    return y, _FFMPEG_SR


def _analyze_pcm(y: np.ndarray, sr: int) -> AudioFeatures | None:
    """
    Extract AudioFeatures from a pre-decoded float32 PCM array.
    Called by analyze_from_url and analyze_from_bytes via the ffmpeg pipe path.
    Essentia/DCLAP are skipped (no file path) — both are disabled on Railway
    anyway due to the TF2 memory footprint.
    """
    try:
        half         = len(y) // 2
        energy       = max(_rms_energy(y[:half]),   _rms_energy(y[half:]))
        loudness     = max(_loudness_dbfs(y[:half]), _loudness_dbfs(y[half:]))
        acousticness = _acousticness(y, sr)

        bpm_arr, _ = librosa.beat.beat_track(y=y, sr=sr)
        raw_bpm = float(bpm_arr) if np.isscalar(bpm_arr) else float(bpm_arr[0])
        bpm = _correct_bpm(y, sr, raw_bpm, energy)

        dance     = _danceability(y, sr, bpm)
        key, mode = detect_key(y, sr, bpm, energy, dance, acousticness)

        y_harmonic, _ = librosa.effects.hpss(y)
        sc = librosa.feature.spectral_contrast(y=y_harmonic, sr=sr, n_bands=6)
        tn = librosa.feature.tonnetz(y=y_harmonic, sr=sr)
        tonal_clarity = float(np.clip(np.sqrt((tn ** 2).mean()) / 0.35, 0.0, 1.0))

        ext = _extract_extended(y, sr, sc)

        return AudioFeatures(
            bpm=round(bpm, 2),
            energy=round(energy, 4),
            valence=round(_valence(y, sr, mode, bpm, energy, dance, acousticness,
                                   y_harmonic=y_harmonic, sc=sc, tn=tn), 4),
            danceability=round(dance, 4),
            acousticness=round(acousticness, 4),
            instrumentalness=round(_instrumentalness(y, sr), 4),
            liveness=round(_liveness(y, sr), 4),
            loudness=round(loudness, 2),
            key=key,
            mode=mode,
            spectral_warmth=0.5,
            tonal_clarity=round(tonal_clarity, 4),
            vocal_presence=0.5,
            reverb_space=0.5,
            is_estimated=False,
            is_key_estimated=False,
            **ext,
            arousal=None,
            valence_essentia=None,
            dclap_embedding=None,
        )
    except Exception as e:
        print(f"❌ _analyze_pcm failed: {e}")
        return None


# ─────────────────────────────────────────────
# Main analysis function
# ─────────────────────────────────────────────

async def analyze_from_url(preview_url: str) -> AudioFeatures | None:
    """
    Download the first 15 seconds of an iTunes/Deezer preview and extract
    a full AudioFeatures struct compatible with Simi's iOS models.

    Hot path: HTTP Range request (240KB instead of 480KB) → ffmpeg pipe decode
    → _analyze_pcm (no disk write, no audioread MP3 fallback).
    Falls back to temp file + analyze_from_file if ffmpeg pipe fails.
    """
    # 128kbps MP3: ~16KB/s → 15s ≈ 240KB. Range is a hint; some CDNs round up.
    _PARTIAL_BYTES = 240_000
    try:
        async with httpx.AsyncClient(
            timeout=15.0,
            follow_redirects=True,
            headers={
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Range": f"bytes=0-{_PARTIAL_BYTES}",
            },
        ) as client:
            resp = await client.get(preview_url)
            # 206 Partial Content = range request honoured; 200 = full file (CDN ignored Range)
            if resp.status_code not in (200, 206):
                resp.raise_for_status()
            audio_bytes = resp.content
    except Exception as e:
        print(f"❌ Download failed for {preview_url!r}: {e}")
        return None

    # Hot path: ffmpeg pipe → no disk write
    pcm = await _decode_via_ffmpeg(audio_bytes)
    if pcm is not None:
        y, sr = pcm
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, _analyze_pcm, y, sr)

    # Fallback: temp file → analyze_from_file (handles edge-case audio formats)
    print(f"⚠️  ffmpeg pipe failed for {preview_url!r}, falling back to temp file")
    suffix = ".m4a" if "m4a" in preview_url.lower() else ".mp3"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(audio_bytes)
        tmp_path = tmp.name
    loop = asyncio.get_running_loop()
    try:
        return await loop.run_in_executor(None, analyze_from_file, tmp_path)
    except Exception as e:
        print(f"❌ analyze_from_url fallback failed: {e}")
        return None
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


async def analyze_from_bytes(audio_bytes: bytes, suffix: str) -> AudioFeatures | None:
    """
    Analyze pre-downloaded audio bytes — skips the CDN download step.
    iOS downloads the preview on-device and POSTs raw bytes here via /analyze-bytes.

    Hot path: ffmpeg pipe decode → _analyze_pcm (no disk write).
    Falls back to temp file + analyze_from_file if ffmpeg pipe fails.
    """
    # Hot path: ffmpeg pipe → no disk write
    pcm = await _decode_via_ffmpeg(audio_bytes)
    if pcm is not None:
        y, sr = pcm
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, _analyze_pcm, y, sr)

    # Fallback: temp file (handles edge-case audio formats ffmpeg can't pipe)
    print("⚠️  ffmpeg pipe failed for bytes input, falling back to temp file")
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(audio_bytes)
        tmp_path = tmp.name
    loop = asyncio.get_running_loop()
    try:
        return await loop.run_in_executor(None, analyze_from_file, tmp_path)
    except Exception as e:
        print(f"❌ analyze_from_bytes fallback failed: {e}")
        return None
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def analyze_from_file(path: str) -> AudioFeatures | None:
    """Synchronous version for testing with a local file."""
    try:
        y, sr = librosa.load(path, sr=22050, mono=True, duration=30.0)
    except Exception as e:
        print(f"❌ Load failed: {e}")
        return None

    half         = len(y) // 2
    energy       = max(_rms_energy(y[:half]),    _rms_energy(y[half:]))
    loudness     = max(_loudness_dbfs(y[:half]),  _loudness_dbfs(y[half:]))
    acousticness = _acousticness(y, sr)

    bpm_arr, _ = librosa.beat.beat_track(y=y, sr=sr)
    raw_bpm = float(bpm_arr) if np.isscalar(bpm_arr) else float(bpm_arr[0])
    bpm = _correct_bpm(y, sr, raw_bpm, energy)

    dance    = _danceability(y, sr, bpm)
    key, mode = detect_key(y, sr, bpm, energy, dance, acousticness)

    y_harmonic, _ = librosa.effects.hpss(y)
    sc = librosa.feature.spectral_contrast(y=y_harmonic, sr=sr, n_bands=6)
    tn = librosa.feature.tonnetz(y=y_harmonic, sr=sr)
    spectral_warmth = 0.5
    tonal_clarity   = float(np.clip(np.sqrt((tn ** 2).mean()) / 0.35, 0.0, 1.0))
    vocal_presence  = 0.5
    reverb_space    = 0.5

    ext = _extract_extended(y, sr, sc)

    # Essentia + DCLAP both available for local files — pass the original path
    av        = extract_arousal_valence(path)
    dclap_emb = get_dclap_embedding(path)
    arousal_val = round(av[0], 4) if av else None
    val_ess_val = round(av[1], 4) if av else None

    return AudioFeatures(
        bpm=round(bpm, 2),
        energy=round(energy, 4),
        valence=round(_valence(y, sr, mode, bpm, energy, dance, acousticness,
                               y_harmonic=y_harmonic, sc=sc, tn=tn), 4),
        danceability=round(dance, 4),
        acousticness=round(acousticness, 4),
        instrumentalness=round(_instrumentalness(y, sr), 4),
        liveness=round(_liveness(y, sr), 4),
        loudness=round(loudness, 2),
        key=key,
        mode=mode,
        spectral_warmth=round(spectral_warmth, 4),
        tonal_clarity=round(tonal_clarity, 4),
        vocal_presence=round(vocal_presence, 4),
        reverb_space=round(reverb_space, 4),
        is_estimated=False,
        is_key_estimated=False,
        **ext,
        arousal=arousal_val,
        valence_essentia=val_ess_val,
        dclap_embedding=dclap_emb,
    )
