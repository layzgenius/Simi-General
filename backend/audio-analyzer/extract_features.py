"""
DEAM feature extraction — produces 58-float vectors matching SonicDNA's on-device computation.

Feature order (must match Swift ValenceArousalPredictor.predict input exactly):
  [0:20]  mfccMean      L2-normalized MFCC coefficient means
  [20:40] mfccStd       L2-normalized MFCC coefficient stds
  [40:52] chroma        12-bin normalized chroma mean (sums to 1)
  [52]    chromaEntropy Shannon entropy / log(12)
  [53]    mode          0=minor, 1=major
  [54]    modeConf      Krumhansl-Schmuckler correlation confidence [0,1]
  [55]    energy        Raw RMS mean (StandardScaler in Pipeline normalizes this)
  [56]    spectralWarmth Fraction of energy below 2kHz
  [57]    tonalClarity  mode_conf * 0.70 + (1 - spectral_flatness) * 0.30
"""
import os, glob
import numpy as np
import librosa
import scipy.stats
import pandas as pd
from pathlib import Path
from scipy.fftpack import dct

# Krumhansl-Schmuckler profiles — matches SonicDNA's findKey() Pearson correlation
_KS_MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53,
                       2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
_KS_MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09,
                       2.52, 5.19, 2.39, 3.66, 2.29, 2.88])

N_MFCC    = 20
N_CHROMA  = 12
N_FEATURES = N_MFCC * 2 + N_CHROMA + 6  # 58


def detect_key_mode(chroma_mean: np.ndarray) -> tuple:
    """Krumhansl-Schmuckler key detection via Pearson correlation.

    Returns (key: 0-11, mode: 0=minor/1=major, confidence: 0-1).
    Mirrors SonicDNA's findKey(chroma:) implementation, including the
    margin-based confidence formula (bestCorr - max(0, secondBest)) / 0.15.
    """
    best_key, best_mode, best_corr = 0, 1, -2.0
    second_best = -2.0
    for key in range(12):
        for profile, mode_idx in [(_KS_MAJOR, 1), (_KS_MINOR, 0)]:
            rotated = np.roll(profile, key)
            corr_matrix = np.corrcoef(chroma_mean, rotated)
            corr = float(corr_matrix[0, 1]) if corr_matrix.shape == (2, 2) else -2.0
            if corr > best_corr:
                second_best = best_corr
                best_corr, best_key, best_mode = corr, key, mode_idx
            elif corr > second_best:
                second_best = corr
    margin = best_corr - max(0.0, second_best)
    confidence = float(np.clip(margin / 0.15, 0.0, 1.0))
    return best_key, best_mode, confidence


def build_feature_vector(y: np.ndarray, sr: int) -> list:
    """Extract 58-float feature vector from a mono audio array.

    All features mirror what SonicDNA computes in LocalAudioAnalyzer.analyzeAudio().
    The StandardScaler in the trained Pipeline handles per-feature normalization —
    raw values are fine except MFCCs which must be L2-normalized to match SonicDNA.
    """
    # ── MFCCs: compute mel log energy, take mean/std across frames, DCT once, L2-normalize ──
    # Matches Swift: accumulate melLogEnergy per frame, DCT the mean/std vectors, l2Normalize.
    # htk=True  → HTK mel scale (matches Swift buildMelFilterbank)
    # norm=None → no Slaney area normalization (matches Swift raw triangular weights)
    mel_spec = librosa.feature.melspectrogram(
        y=y, sr=sr, n_mels=128, n_fft=2048, hop_length=512, htk=True, norm=None
    )
    mel_log  = librosa.power_to_db(mel_spec)                 # (128, n_frames), dB log scale
    mel_mean = mel_log.mean(axis=1)                          # (128,) — mean across frames
    mel_std  = mel_log.std(axis=1)                           # (128,) — std across frames

    mfcc_mean = dct(mel_mean, type=2, norm='ortho')[:N_MFCC]  # first 20 DCT coefficients
    mfcc_std  = dct(mel_std,  type=2, norm='ortho')[:N_MFCC]
    # L2-normalize the summary vectors — matches SonicDNA's final l2Normalize(dctII(...))
    nm = np.linalg.norm(mfcc_mean); mfcc_mean = mfcc_mean / nm if nm > 1e-8 else mfcc_mean
    ns = np.linalg.norm(mfcc_std);  mfcc_std  = mfcc_std  / ns if ns > 1e-8 else mfcc_std

    # ── Chroma: STFT-based, accumulate raw magnitudes across frames, normalize once ──
    # Matches Swift: sum each frequency bin into its nearest pitch class, normalize to sum=1.
    # norm=None → no per-frame normalization (matches Swift raw accumulation then single norm)
    chroma_frames = librosa.feature.chroma_stft(
        y=y, sr=sr, n_fft=2048, hop_length=512, norm=None
    )                                                        # (12, n_frames)
    chroma_sum  = chroma_frames.sum(axis=1)                  # (12,) — sum across frames
    cs = chroma_sum.sum()
    chroma_mean = chroma_sum / cs if cs > 1e-8 else np.ones(12) / 12.0

    # ── Chroma entropy: Shannon entropy normalized by max (log 12) ──────────────
    chroma_entropy = float(scipy.stats.entropy(chroma_mean + 1e-10) / np.log(12))

    # ── Key / mode / confidence ─────────────────────────────────────────────────
    _, mode, mode_conf = detect_key_mode(chroma_mean)

    # ── Energy: raw RMS mean (scaler normalizes) ────────────────────────────────
    rms    = librosa.feature.rms(y=y, frame_length=2048, hop_length=512)
    energy = float(rms.mean())

    # ── Spectral warmth: fraction of STFT energy below 2kHz ────────────────────
    stft  = np.abs(librosa.stft(y, n_fft=2048, hop_length=512))
    freqs = librosa.fft_frequencies(sr=sr, n_fft=2048)
    warm  = stft[freqs <= 2000.0].mean()
    total = stft.mean()
    spectral_warmth = float(warm / total) if total > 1e-8 else 0.5

    # ── Tonal clarity: matches SonicDNA's formula exactly ──────────────────────
    # SonicDNA: tonalClarity = modeConf * 0.70 + (1 - avgFlatness) * 0.30
    # avgFlatness = spectral flatness (Wiener entropy): ~0=tonal, ~1=noisy
    flatness = float(librosa.feature.spectral_flatness(y=y).mean())
    tonal_clarity = float(np.clip(mode_conf * 0.70 + (1.0 - flatness) * 0.30, 0.0, 1.0))

    return (
        list(mfcc_mean)
        + list(mfcc_std)
        + list(chroma_mean)
        + [chroma_entropy, float(mode), mode_conf, energy, spectral_warmth, tonal_clarity]
    )


def load_deam_annotations(deam_root: str) -> pd.DataFrame:
    """Load per-song valence + arousal from DEAM annotation CSVs.

    Actual DEAM 2018 layout (from DEAM_Annotations.zip):
      annotations/annotations averaged per song/song_level/
        static_annotations_averaged_songs_1_2000.csv
        static_annotations_averaged_songs_2000_2058.csv
      Columns: song_id, valence_mean, valence_std, arousal_mean, arousal_std
      Scale: SAM 1-9. Normalize to [0,1] via (value - 1) / 8.

    The rest of the code only needs [song_id, valence, arousal].
    """
    song_level_dir = os.path.join(deam_root, "annotations",
                                  "annotations averaged per song", "song_level")
    parts = []
    for fname in ("static_annotations_averaged_songs_1_2000.csv",
                  "static_annotations_averaged_songs_2000_2058.csv"):
        path = os.path.join(song_level_dir, fname)
        if os.path.exists(path):
            parts.append(pd.read_csv(path).rename(columns=str.strip))
    if not parts:
        raise FileNotFoundError(f"No annotation CSVs found in {song_level_dir}")
    df = pd.concat(parts, ignore_index=True)
    df["song_id"] = df["song_id"].astype(int)
    df["valence"] = (df["valence_mean"].astype(float) - 1.0) / 8.0
    df["arousal"] = (df["arousal_mean"].astype(float) - 1.0) / 8.0
    return df[["song_id", "valence", "arousal"]]


def extract_deam_dataset(deam_root: str, output_path: str, max_clips: int = None):
    """Extract features for all DEAM clips and save to .npz.

    Args:
        deam_root:   Path to extracted DEAM download (contains DEAM_audio/ + annotations/)
        output_path: Destination .npz path (e.g. 'ml/deam_features.npz')
        max_clips:   Cap for quick testing; None = all
    """
    annotations = load_deam_annotations(deam_root)
    audio_dir   = os.path.join(deam_root, "DEAM_audio")
    audio_index = {
        int(Path(p).stem): p
        for p in glob.glob(os.path.join(audio_dir, "*.mp3"))
    }

    X, y_v, y_a = [], [], []
    rows = list(annotations.iterrows())
    if max_clips:
        rows = rows[:max_clips]

    for i, (_, row) in enumerate(rows):
        sid = int(row["song_id"])
        if sid not in audio_index:
            print(f"  skip {sid}: no audio file")
            continue
        try:
            y, sr = librosa.load(audio_index[sid], sr=22050, duration=30.0)
            X.append(build_feature_vector(y, sr))
            y_v.append(float(row["valence"]))
            y_a.append(float(row["arousal"]))
        except Exception as exc:
            print(f"  skip {sid}: {exc}")
        if (i + 1) % 100 == 0:
            print(f"  {i+1}/{len(rows)} ({len(X)} succeeded)")

    X_arr = np.array(X, dtype=np.float32)
    np.savez(output_path,
             X=X_arr,
             y_valence=np.array(y_v, dtype=np.float32),
             y_arousal=np.array(y_a, dtype=np.float32))
    print(f"Saved {len(X)} clips -> {output_path}  X shape={X_arr.shape}")


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--deam-root", default="ml/deam")
    p.add_argument("--output",    default="ml/deam_features.npz")
    p.add_argument("--max-clips", type=int, default=None)
    args = p.parse_args()
    extract_deam_dataset(args.deam_root, args.output, args.max_clips)
