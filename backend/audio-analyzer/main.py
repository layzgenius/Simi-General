"""
main.py
Simi Audio Analyzer — FastAPI microservice

Endpoints:
  POST /analyze        { "previewUrl": "https://..." }
                       → AudioFeatures JSON (camelCase, matches Swift Codable struct)

  POST /batch-analyze  { "urls": ["https://...", ...] }
                       → { "results": [AudioFeatures | null, ...] }

  POST /similarity     { "source": AudioFeatures, "target": AudioFeatures }
                       → { "score": 0.84, "reasons": ["Same Genre", "Dark Mood", "Similar BPM"] }

  POST /store-vector   { "spotifyId": "...", "title": "...", "artist": "...", "features": AudioFeatures }
                       → { "stored": true }  — writes embedding to Supabase analyzed_songs table

  GET  /health         → { "status": "ok" }

Start:
  uvicorn main:app --host 127.0.0.1 --port 8765 --reload
"""

from __future__ import annotations

import asyncio
import io
import json
import os
import sqlite3
import tarfile
import threading
import time
from pathlib import Path
from typing import Optional

from fastapi import BackgroundTasks, FastAPI, File, HTTPException, UploadFile
from pydantic import BaseModel, Field

from audio_analyzer import (
    analyze_from_url, analyze_from_bytes,
    init_dclap, get_dclap_embedding,
    init_musicnn_embedding, get_musicnn_embedding,
    init_msd_musicnn_onnx, init_deam_onnx,
)
from similarity_engine import compute_similarity, AudioFeaturesDict, build_embedding, build_explanation, Genre

app = FastAPI(title="Simi Audio Analyzer", version="1.0.0")

# ─────────────────────────────────────────────
# AcousticBrainz SQLite — loaded once at startup, queried per /ab-lookup request.
# Populated offline by import_acousticbrainz.py from the July 2022 frozen dump.
# The DB is optional: if the file doesn't exist the endpoint returns 404 gracefully.
# ─────────────────────────────────────────────
_AB_DB_PATH  = Path("data/acousticbrainz.db")
_ab_conn: sqlite3.Connection | None = None


def _init_ab_db() -> None:
    global _ab_conn
    if not _AB_DB_PATH.exists():
        return
    try:
        conn = sqlite3.connect(str(_AB_DB_PATH), check_same_thread=False)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA query_only=1")
        _ab_conn = conn
        count = conn.execute("SELECT COUNT(*) FROM acousticbrainz").fetchone()[0]
        print(f"[AB] SQLite ready — {count:,} tracks at {_AB_DB_PATH}")
    except Exception as e:
        print(f"[AB] SQLite init failed: {e}")


# ─────────────────────────────────────────────
# AcousticBrainz background importer
# Streams archives from MetaBrainz directly — no local download needed.
# ─────────────────────────────────────────────

_AB_ARCHIVE_URL = (
    "https://data.metabrainz.org/pub/musicbrainz/acousticbrainz/dumps/"
    "acousticbrainz-lowlevel-json-20220623/"
    "acousticbrainz-lowlevel-json-20220623-{n}.tar.zst"
)
_AB_TOTAL_ARCHIVES = 30

_AB_KEY_MAP = {
    "C": 0, "C#": 1, "Db": 1,
    "D": 2, "D#": 3, "Eb": 3,
    "E": 4,
    "F": 5, "F#": 6, "Gb": 6,
    "G": 7, "G#": 8, "Ab": 8,
    "A": 9, "A#": 10, "Bb": 10,
    "B": 11,
}

_import_state: dict = {
    "running":        False,
    "archive_index":  0,
    "rows_written":   0,
    "rows_skipped":   0,
    "error":          None,
    "started_at":     None,
    "finished_at":    None,
    "current_url":    None,
}


class _HttpxStreamReader(io.RawIOBase):
    """Wraps a synchronous httpx streaming response as a file-like object for zstd."""
    def __init__(self, response: "httpx.Response") -> None:
        self._iter = response.iter_bytes(chunk_size=65536)
        self._buf  = b""

    def read(self, n: int = -1) -> bytes:
        if n == -1:
            return b"".join(self._iter)
        while len(self._buf) < n:
            try:
                self._buf += next(self._iter)
            except StopIteration:
                break
        chunk, self._buf = self._buf[:n], self._buf[n:]
        return chunk

    def readable(self) -> bool:
        return True


def _ab_mbid_from_path(name: str) -> str | None:
    stem = Path(name).stem
    parts = stem.rsplit("-", 1)
    if len(parts) == 2 and parts[1].isdigit():
        return parts[0]
    return stem or None


def _ab_init_sqlite(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), check_same_thread=False)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS acousticbrainz (
            mbid         TEXT PRIMARY KEY,
            bpm          REAL NOT NULL,
            key          INTEGER NOT NULL,
            mode         INTEGER NOT NULL,
            energy       REAL NOT NULL,
            danceability REAL NOT NULL
        )
    """)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.commit()
    return conn


def _run_ab_import(start_from: int = 0) -> None:
    """Stream all AB archives from MetaBrainz and write to local SQLite. Background thread."""
    global _ab_conn
    import httpx
    try:
        import zstandard as zstd
    except ImportError:
        _import_state["error"] = "zstandard not installed — add it to requirements.txt"
        _import_state["running"] = False
        return

    _import_state.update({"running": True, "error": None, "started_at": time.time(), "finished_at": None})
    conn = _ab_init_sqlite(_AB_DB_PATH)
    BATCH = 5000

    try:
        for n in range(start_from, _AB_TOTAL_ARCHIVES):
            url = _AB_ARCHIVE_URL.format(n=n)
            _import_state["archive_index"] = n
            _import_state["current_url"]   = url
            print(f"[AB] Archive {n+1}/{_AB_TOTAL_ARCHIVES}: {url}")
            batch: list[tuple] = []

            with httpx.stream("GET", url, follow_redirects=True,
                              timeout=httpx.Timeout(60, read=900)) as resp:
                resp.raise_for_status()
                dctx = zstd.ZstdDecompressor()
                with dctx.stream_reader(_HttpxStreamReader(resp)) as zst:
                    with tarfile.open(fileobj=io.BufferedReader(zst), mode="r|") as tf:
                        for member in tf:
                            if not member.name.endswith(".json"):
                                continue
                            mbid = _ab_mbid_from_path(member.name)
                            if not mbid:
                                continue
                            try:
                                f = tf.extractfile(member)
                                if f is None:
                                    continue
                                ab = json.load(f)
                                bpm          = float(ab["rhythm"]["bpm"])
                                key_name     = ab["tonal"]["key_key"]
                                key_scale    = ab["tonal"]["key_scale"]
                                energy       = float(ab["lowlevel"]["average_loudness"])
                                danceability = float(ab["rhythm"]["danceability"])
                            except Exception:
                                _import_state["rows_skipped"] += 1
                                continue

                            key = _AB_KEY_MAP.get(key_name)
                            if key is None:
                                _import_state["rows_skipped"] += 1
                                continue

                            batch.append((
                                mbid,
                                round(bpm, 2),
                                key,
                                1 if key_scale == "major" else 0,
                                round(max(0.0, min(energy, 1.0)), 4),
                                round(min(danceability / 3.0, 1.0), 4),
                            ))

                            if len(batch) >= BATCH:
                                conn.executemany(
                                    "INSERT OR REPLACE INTO acousticbrainz"
                                    "(mbid,bpm,key,mode,energy,danceability) VALUES(?,?,?,?,?,?)",
                                    batch,
                                )
                                conn.commit()
                                _import_state["rows_written"] += len(batch)
                                batch.clear()

            if batch:
                conn.executemany(
                    "INSERT OR REPLACE INTO acousticbrainz"
                    "(mbid,bpm,key,mode,energy,danceability) VALUES(?,?,?,?,?,?)",
                    batch,
                )
                conn.commit()
                _import_state["rows_written"] += len(batch)

            print(f"[AB] Archive {n+1} done — {_import_state['rows_written']:,} total rows")

        _import_state["finished_at"] = time.time()
        print(f"[AB] Import complete — {_import_state['rows_written']:,} rows")

    except Exception as e:
        _import_state["error"] = str(e)
        print(f"[AB] Import error: {e}")
    finally:
        _import_state["running"] = False
        conn.close()
        _init_ab_db()   # reload read-only connection so /ab-lookup sees the new data


@app.on_event("startup")
async def on_startup() -> None:
    import threading
    # All three models warm in parallel background threads.
    # HF CPU Basic has 16GB RAM — TF2's 400-600MB footprint is fine here.
    threading.Thread(target=init_dclap, daemon=True).start()
    threading.Thread(target=init_musicnn_embedding, daemon=True).start()
    threading.Thread(target=init_msd_musicnn_onnx, daemon=True).start()
    threading.Thread(target=init_deam_onnx, daemon=True).start()
    threading.Thread(target=_init_ab_db, daemon=True).start()


# ─────────────────────────────────────────────
# Pydantic models — camelCase field names match Swift's Codable output exactly.
# ─────────────────────────────────────────────

class AudioFeatures(BaseModel):
    bpm:              float
    energy:           float
    valence:          float
    danceability:     float
    acousticness:     float
    instrumentalness: float
    liveness:         float
    loudness:         float
    key:              int
    mode:             int
    isEstimated:      bool  = True
    isKeyEstimated:   bool  = False
    spectralWarmth:   float = 0.5
    tonalClarity:     float = 0.5
    vocalPresence:    float = 0.5
    reverbSpace:      float = 0.5
    # Extended librosa features
    mfccMean:              list[float] | None = None
    mfccStd:               list[float] | None = None
    spectralContrast:      list[float] | None = None
    chroma:                list[float] | None = None
    chromaEntropy:         float | None = None
    zcr:                   float | None = None
    rolloff:               float | None = None
    onsetMean:             float | None = None
    onsetStd:              float | None = None
    grooveRatio:           float | None = None
    # Essentia DEAM
    arousal:               float | None = None
    valenceEssentia:       float | None = None
    # DCLAP neural embedding (512-dim)
    dclapEmbedding:        list[float] | None = None
    # MusiCNN timbral embedding (200-dim, Last.fm-supervised, best for recommendation ANN)
    musicnnEmbedding:      list[float] | None = None

    def to_dict(self) -> AudioFeaturesDict:
        return self.model_dump()   # type: ignore[return-value]


class AnalyzeRequest(BaseModel):
    previewUrl: str
    spotifyId:  str = ""   # when provided, enables Supabase cache lookup + storage


class BatchAnalyzeRequest(BaseModel):
    urls: list[str]


class SimilarityRequest(BaseModel):
    source: AudioFeatures
    target: AudioFeatures


class SimilarityResponse(BaseModel):
    score:   float
    reasons: list[str]


class StoreVectorRequest(BaseModel):
    spotifyId: str
    title:     str
    artist:    str
    features:  AudioFeatures


class StoreVectorResponse(BaseModel):
    stored: bool


class GenreItem(BaseModel):
    main: str
    sub:  str = ""


class ExplainRequest(BaseModel):
    source:       AudioFeatures
    target:       AudioFeatures
    sourceGenres: list[GenreItem] = []
    targetGenre:  Optional[GenreItem] = None


class ExplanationRowItem(BaseModel):
    label:      str
    descriptor: str


class ExplanationDetail(BaseModel):
    rows:             list[ExplanationRowItem]
    genreBridgeLabel: Optional[str] = None


class ExplainResponse(BaseModel):
    score:        float
    matchReasons: list[str]
    explanation:  ExplanationDetail


# ─────────────────────────────────────────────
# Supabase helper — optional, only wired when env vars are present
# ─────────────────────────────────────────────

_SUPABASE_URL          = os.environ.get("SUPABASE_URL", "")
_SUPABASE_KEY          = os.environ.get("SUPABASE_ANON_KEY", "")
_SUPABASE_SERVICE_KEY  = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
_LASTFM_PROXY_URL = "https://simi-token-proxy.lazyscholarph.workers.dev/lastfm"
_LASTFM_PROXY_KEY = "0db4b8d62e7b427fed685e73309d33d9473429b54f6854aed1287d3b2c2762a5"


async def _supabase_lookup_features(spotify_id: str) -> AudioFeatures | None:
    """Check analyzed_songs cache for a previously enriched result. ~50-100ms on hit."""
    if not _SUPABASE_URL or not _SUPABASE_KEY or not spotify_id:
        return None
    import httpx
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            r = await client.get(
                f"{_SUPABASE_URL}/rest/v1/analyzed_songs",
                params={"spotify_id": f"eq.{spotify_id}", "select": "features", "limit": "1"},
                headers={"apikey": _SUPABASE_KEY, "Authorization": f"Bearer {_SUPABASE_KEY}"},
            )
            rows = r.json()
            if rows and isinstance(rows, list) and rows[0].get("features"):
                cached = AudioFeatures(**rows[0]["features"])
                # Stale if neural embeddings are absent — re-analyze with current model
                if cached.dclapEmbedding is None:
                    return None
                return cached
    except Exception:
        pass
    return None


async def _supabase_store_features(spotify_id: str, title: str, artist: str, features: AudioFeatures) -> None:
    """Background task: store freshly analyzed features so the next call is instant."""
    if not _SUPABASE_URL or not _SUPABASE_KEY or not spotify_id:
        return
    import httpx
    emb = build_embedding(features.to_dict())
    emb_str = "[" + ",".join(f"{v:.6f}" for v in emb) + "]"
    payload = {
        "spotify_id": spotify_id,
        "title":      title,
        "artist":     artist,
        "embedding":  emb_str,
        "features":   features.model_dump(),
    }
    headers = {
        "Authorization": f"Bearer {_SUPABASE_KEY}",
        "apikey":         _SUPABASE_KEY,
        "Content-Type":   "application/json",
        "Prefer":         "resolution=merge-duplicates",
    }
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            await client.post(
                f"{_SUPABASE_URL}/rest/v1/analyzed_songs",
                params={"on_conflict": "spotify_id"},
                json=payload,
                headers=headers,
            )
    except Exception:
        pass


async def _supabase_upsert_vector(spotify_id: str, title: str, artist: str, features: AudioFeatures) -> bool:
    """Fire-and-forget upsert into analyzed_songs. Returns True on success."""
    if not _SUPABASE_URL or not _SUPABASE_KEY:
        return False
    import httpx
    emb = build_embedding(features.to_dict())
    emb_str = "[" + ",".join(f"{v:.6f}" for v in emb) + "]"
    payload = {
        "spotify_id": spotify_id,
        "title":      title,
        "artist":     artist,
        "embedding":  emb_str,
        "features":   features.model_dump(),
    }
    headers = {
        "Authorization": f"Bearer {_SUPABASE_KEY}",
        "apikey":         _SUPABASE_KEY,
        "Content-Type":   "application/json",
        "Prefer":         "resolution=merge-duplicates",
    }
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            r = await client.post(
                f"{_SUPABASE_URL}/rest/v1/analyzed_songs",
                params={"on_conflict": "spotify_id"},
                json=payload,
                headers=headers,
            )
            return r.status_code in (200, 201)
    except Exception:
        return False


# ─────────────────────────────────────────────
# Cascade prefetch — warms artist catalog after a successful analysis
# ─────────────────────────────────────────────

async def _warm_artist_catalog(artist: str, skip_title: str) -> None:
    """
    Background task: fetch the artist's top tracks from Last.fm, resolve
    iTunes preview URLs, and analyze any not already in Supabase.
    Fires after /analyze returns — never blocks the response.
    No-ops when LASTFM_API_KEY or SUPABASE_URL is absent.
    """
    if not _SUPABASE_URL or not _SUPABASE_KEY:
        return

    import httpx as _httpx

    # 1. Fetch top tracks via the Cloudflare Worker proxy (key lives there)
    try:
        async with _httpx.AsyncClient(timeout=8.0) as client:
            r = await client.get(
                _LASTFM_PROXY_URL,
                params={
                    "method": "artist.getTopTracks",
                    "artist": artist,
                    "format": "json",
                    "limit":  "5",
                },
                headers={"X-Proxy-Key": _LASTFM_PROXY_KEY},
            )
            r.raise_for_status()
            tracks = r.json().get("toptracks", {}).get("track", [])
    except Exception as e:
        print(f"⚠️  Last.fm top tracks failed for {artist!r}: {e}")
        return

    for track in tracks:
        title = track.get("name", "")
        if not title or title.lower() == skip_title.lower():
            continue

        # 2. Check Supabase — skip if already cached
        try:
            async with _httpx.AsyncClient(timeout=5.0) as client:
                r = await client.get(
                    f"{_SUPABASE_URL}/rest/v1/analyzed_songs",
                    params={"title": f"eq.{title}", "artist": f"eq.{artist}", "select": "title", "limit": "1"},
                    headers={"apikey": _SUPABASE_KEY, "Authorization": f"Bearer {_SUPABASE_KEY}"},
                )
                if r.json():
                    continue  # already cached
        except Exception:
            continue

        # 3. Resolve iTunes preview URL
        try:
            async with _httpx.AsyncClient(timeout=8.0) as client:
                r = await client.get(
                    "https://itunes.apple.com/search",
                    params={"term": f"{title} {artist}", "media": "music", "limit": "1"},
                )
                items = r.json().get("results", [])
                preview_url = items[0].get("previewUrl") if items else None
        except Exception:
            preview_url = None

        if not preview_url:
            continue

        # 4. Analyze and results are stored by the caller — we just compute
        try:
            from audio_analyzer import analyze_from_url as _analyze
            features = await _analyze(preview_url)
            if features is None:
                continue
            # Store in Supabase (no spotify_id available here — use title+artist key)
            from similarity_engine import build_embedding
            emb = build_embedding(features.__dict__)
            emb_str = "[" + ",".join(f"{v:.6f}" for v in emb) + "]"
            payload = {"title": title, "artist": artist, "embedding": emb_str,
                       "features": features.__dict__}
            async with _httpx.AsyncClient(timeout=5.0) as client:
                await client.post(
                    f"{_SUPABASE_URL}/rest/v1/analyzed_songs",
                    json=payload,
                    headers={
                        "apikey": _SUPABASE_KEY,
                        "Authorization": f"Bearer {_SUPABASE_KEY}",
                        "Content-Type": "application/json",
                        "Prefer": "resolution=merge-duplicates",
                    },
                )
            print(f"✅ Prefetch cached: {title} by {artist}")
        except Exception as e:
            print(f"⚠️  Prefetch failed for {title!r}: {e}")


# ─────────────────────────────────────────────
# Routes
# ─────────────────────────────────────────────

@app.post("/analyze", response_model=AudioFeatures)
async def analyze(req: AnalyzeRequest, background_tasks: BackgroundTasks,
                  artist: str = "", title: str = "") -> AudioFeatures:
    """
    Downloads the first 15 seconds of the preview and extracts full audio features.
    Returns immediately with measured BPM, energy, valence, danceability,
    acousticness, instrumentalness, liveness, loudness, key, and mode.
    isEstimated=false (real FFT/chroma/MFCC analysis — not a tag guess),
    isKeyEstimated=false (Krumhansl-Schmuckler pitch class detection is real signal).
    Pass artist + title query params to trigger cascade prefetch of artist's catalog.
    """
    # Cache hit — return enriched features instantly (~50-100ms)
    if req.spotifyId:
        cached = await _supabase_lookup_features(req.spotifyId)
        if cached is not None:
            return cached

    features = await analyze_from_url(req.previewUrl)
    if features is None:
        raise HTTPException(status_code=422, detail="Audio analysis failed — check the URL and ensure ffmpeg is installed for M4A support")

    if artist:
        background_tasks.add_task(_warm_artist_catalog, artist, title)

    # Cache miss — store enriched result so next call is instant
    if req.spotifyId:
        background_tasks.add_task(_supabase_store_features, req.spotifyId, title, artist, AudioFeatures(
            bpm=features.bpm, energy=features.energy, valence=features.valence,
            danceability=features.danceability, acousticness=features.acousticness,
            instrumentalness=features.instrumentalness, liveness=features.liveness,
            loudness=features.loudness, key=features.key, mode=features.mode,
            isEstimated=features.is_estimated, isKeyEstimated=features.is_key_estimated,
            spectralWarmth=features.spectral_warmth, tonalClarity=features.tonal_clarity,
            vocalPresence=features.vocal_presence, reverbSpace=features.reverb_space,
            mfccMean=features.mfcc_mean, mfccStd=features.mfcc_std,
            spectralContrast=features.spectral_contrast_bands, chroma=features.chroma_cqt_mean,
            chromaEntropy=features.chroma_entropy, zcr=features.zcr_mean,
            rolloff=features.rolloff_norm, onsetMean=features.onset_mean,
            onsetStd=features.onset_std, grooveRatio=features.groove_ratio,
            arousal=features.arousal, valenceEssentia=features.valence_essentia,
            dclapEmbedding=features.dclap_embedding, musicnnEmbedding=features.musicnn_embedding,
        ))

    return AudioFeatures(
        bpm=features.bpm,
        energy=features.energy,
        valence=features.valence,
        danceability=features.danceability,
        acousticness=features.acousticness,
        instrumentalness=features.instrumentalness,
        liveness=features.liveness,
        loudness=features.loudness,
        key=features.key,
        mode=features.mode,
        isEstimated=features.is_estimated,
        isKeyEstimated=features.is_key_estimated,
        spectralWarmth=features.spectral_warmth,
        tonalClarity=features.tonal_clarity,
        vocalPresence=features.vocal_presence,
        reverbSpace=features.reverb_space,
        mfccMean=features.mfcc_mean,
        mfccStd=features.mfcc_std,
        spectralContrast=features.spectral_contrast_bands,
        chroma=features.chroma_cqt_mean,
        chromaEntropy=features.chroma_entropy,
        zcr=features.zcr_mean,
        rolloff=features.rolloff_norm,
        onsetMean=features.onset_mean,
        onsetStd=features.onset_std,
        grooveRatio=features.groove_ratio,
        arousal=features.arousal,
        valenceEssentia=features.valence_essentia,
        dclapEmbedding=features.dclap_embedding,
        musicnnEmbedding=features.musicnn_embedding,
    )


@app.post("/analyze-bytes", response_model=AudioFeatures)
async def analyze_bytes_endpoint(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
    spotify_id: str = "",
    artist: str = "",
    title: str = "",
) -> AudioFeatures:
    """
    Analyzes pre-downloaded audio bytes POSTed as multipart/form-data.
    iOS downloads the preview URL on-device (fast CDN routing) and sends
    the raw bytes here — eliminates server-side CDN download latency.
    Pass spotify_id to enable Supabase cache lookup (instant on repeat plays).
    Pass artist + title query params to trigger cascade prefetch of artist's catalog.
    """
    # Cache hit — return enriched features instantly
    if spotify_id:
        cached = await _supabase_lookup_features(spotify_id)
        if cached is not None:
            return cached

    audio_bytes = await file.read()
    filename = file.filename or ""
    suffix = ".m4a" if filename.endswith(".m4a") else ".mp3"

    features = await analyze_from_bytes(audio_bytes, suffix)
    if features is None:
        raise HTTPException(status_code=422, detail="Audio analysis failed")

    result = AudioFeatures(
        bpm=features.bpm,
        energy=features.energy,
        valence=features.valence,
        danceability=features.danceability,
        acousticness=features.acousticness,
        instrumentalness=features.instrumentalness,
        liveness=features.liveness,
        loudness=features.loudness,
        key=features.key,
        mode=features.mode,
        isEstimated=features.is_estimated,
        isKeyEstimated=features.is_key_estimated,
        spectralWarmth=features.spectral_warmth,
        tonalClarity=features.tonal_clarity,
        vocalPresence=features.vocal_presence,
        reverbSpace=features.reverb_space,
        mfccMean=features.mfcc_mean,
        mfccStd=features.mfcc_std,
        spectralContrast=features.spectral_contrast_bands,
        chroma=features.chroma_cqt_mean,
        chromaEntropy=features.chroma_entropy,
        zcr=features.zcr_mean,
        rolloff=features.rolloff_norm,
        onsetMean=features.onset_mean,
        onsetStd=features.onset_std,
        grooveRatio=features.groove_ratio,
        arousal=features.arousal,
        valenceEssentia=features.valence_essentia,
        dclapEmbedding=features.dclap_embedding,
        musicnnEmbedding=features.musicnn_embedding,
    )

    if artist:
        background_tasks.add_task(_warm_artist_catalog, artist, title)

    # Cache miss — store so next call is instant
    if spotify_id:
        background_tasks.add_task(_supabase_store_features, spotify_id, title, artist, result)

    return result


@app.post("/batch-analyze")
async def batch_analyze(req: BatchAnalyzeRequest) -> dict:
    """
    Analyzes up to 20 preview URLs concurrently.
    Returns { "results": [AudioFeatures | null, ...] } — one entry per input URL, in order.
    Null means download or analysis failed for that URL.
    Server-side semaphore caps at 6 concurrent librosa workers to stay within Railway budget.
    """
    sem = asyncio.Semaphore(8)

    async def limited_analyze(url: str) -> AudioFeatures | None:
        async with sem:
            features = await analyze_from_url(url)
            if features is None:
                return None
            return AudioFeatures(
                bpm=features.bpm,
                energy=features.energy,
                valence=features.valence,
                danceability=features.danceability,
                acousticness=features.acousticness,
                instrumentalness=features.instrumentalness,
                liveness=features.liveness,
                loudness=features.loudness,
                key=features.key,
                mode=features.mode,
                isEstimated=features.is_estimated,
                isKeyEstimated=features.is_key_estimated,
                spectralWarmth=features.spectral_warmth,
                tonalClarity=features.tonal_clarity,
                vocalPresence=features.vocal_presence,
                reverbSpace=features.reverb_space,
                mfccMean=features.mfcc_mean,
                mfccStd=features.mfcc_std,
                spectralContrast=features.spectral_contrast_bands,
                chroma=features.chroma_cqt_mean,
                chromaEntropy=features.chroma_entropy,
                zcr=features.zcr_mean,
                rolloff=features.rolloff_norm,
                onsetMean=features.onset_mean,
                onsetStd=features.onset_std,
                grooveRatio=features.groove_ratio,
                arousal=features.arousal,
                valenceEssentia=features.valence_essentia,
                dclapEmbedding=features.dclap_embedding,
                musicnnEmbedding=features.musicnn_embedding,
            )

    results = await asyncio.gather(*[limited_analyze(url) for url in req.urls[:20]])
    return {"results": [r.model_dump() if r else None for r in results]}


@app.post("/similarity", response_model=SimilarityResponse)
async def similarity(req: SimilarityRequest) -> SimilarityResponse:
    """
    Computes weighted emotional similarity between two AudioFeatures objects.
    Mirrors RecommendationEngine.computeSimilarity() in Swift exactly.
    Returns MatchReason.rawValue strings the iOS app can decode directly.
    """
    score, reasons = compute_similarity(req.source.to_dict(), req.target.to_dict())
    return SimilarityResponse(score=score, reasons=reasons)


@app.post("/explain", response_model=ExplainResponse)
async def explain(req: ExplainRequest) -> ExplainResponse:
    """
    Returns similarity score, match reasons, and a structured human-readable
    explanation for why two songs match emotionally.

    Mirrors buildMatchExplanation() in RecommendationEngine.swift.
    Rows are only populated when the audio features are measured (isEstimated=False)
    and the delta is within the threshold — same gates as the iOS app.

    sourceGenres / targetGenre are optional — omit them when genre metadata is
    unavailable and the genreBridgeLabel field will be null.
    """
    score, reasons = compute_similarity(req.source.to_dict(), req.target.to_dict())

    src_genres: Optional[list[Genre]] = (
        [{"main": g.main, "sub": g.sub} for g in req.sourceGenres] or None
    )
    tgt_genre: Optional[Genre] = (
        {"main": req.targetGenre.main, "sub": req.targetGenre.sub}
        if req.targetGenre else None
    )

    explanation = build_explanation(
        source=req.source.to_dict(),
        target=req.target.to_dict(),
        source_genres=src_genres,
        target_genre=tgt_genre,
    )

    return ExplainResponse(
        score=score,
        matchReasons=reasons,
        explanation=ExplanationDetail(
            rows=[
                ExplanationRowItem(label=r["label"], descriptor=r["descriptor"])
                for r in explanation["rows"]
            ],
            genreBridgeLabel=explanation["genreBridgeLabel"],
        ),
    )


@app.post("/store-vector", response_model=StoreVectorResponse)
async def store_vector(req: StoreVectorRequest) -> StoreVectorResponse:
    """
    Writes a song's 8-dim audio feature embedding to the Supabase analyzed_songs table.
    Upserts on spotify_id — re-analyzing a song updates its stored vector.
    No-ops silently when SUPABASE_URL / SUPABASE_ANON_KEY env vars are absent.
    """
    stored = await _supabase_upsert_vector(req.spotifyId, req.title, req.artist, req.features)
    return StoreVectorResponse(stored=stored)


# ─────────────────────────────────────────────
# DCLAP embed-candidates and vector-search endpoints
# ─────────────────────────────────────────────

class EmbedCandidateItem(BaseModel):
    spotifyId:  str
    title:      str
    artist:     str
    previewUrl: str
    arousal:    float | None = None
    valenceDeam: float | None = None
    bpm:        float | None = None


class EmbedCandidatesRequest(BaseModel):
    candidates: list[EmbedCandidateItem]


class EmbedCandidatesResponse(BaseModel):
    embedded: int   # number of candidates successfully embedded and stored


class VectorSearchRequest(BaseModel):
    embedding:   list[float]   # 512-dim DCLAP query vector
    matchCount:  int = 20


class VectorSearchResult(BaseModel):
    spotifyId:   str
    title:       str
    artist:      str
    similarity:  float
    arousal:     float | None = None
    valenceDeam: float | None = None
    bpm:         float | None = None


class VectorSearchResponse(BaseModel):
    results: list[VectorSearchResult]


@app.post("/embed-candidates", response_model=EmbedCandidatesResponse)
async def embed_candidates(req: EmbedCandidatesRequest) -> EmbedCandidatesResponse:
    """
    Background catalog builder: downloads preview audio for each candidate,
    computes DCLAP (512-dim) and MusiCNN (200-dim) embeddings, and upserts
    both into Supabase track_embeddings.
    Fire-and-forget from iOS — errors are logged but do not affect the caller.
    No-ops when DCLAP or Supabase is unavailable. MusiCNN is stored when available.
    """
    from audio_analyzer import _dclap_available, _musicnn_embed_available
    if not _dclap_available or not _SUPABASE_URL or not _SUPABASE_KEY:
        return EmbedCandidatesResponse(embedded=0)

    import httpx as _httpx

    sem = asyncio.Semaphore(4)

    async def embed_one(item: EmbedCandidateItem) -> bool:
        async with sem:
            # Download preview audio
            try:
                async with _httpx.AsyncClient(
                    timeout=15.0,
                    follow_redirects=True,
                    headers={"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"},
                ) as client:
                    resp = await client.get(item.previewUrl)
                    resp.raise_for_status()
                    audio_bytes = resp.content
            except Exception:
                return False

            import tempfile, os as _os
            suffix = ".m4a" if "m4a" in item.previewUrl.lower() else ".mp3"
            with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
                tmp.write(audio_bytes)
                tmp_path = tmp.name

            try:
                loop = asyncio.get_event_loop()
                # Run DCLAP and MusiCNN concurrently — both read the same temp file
                if _musicnn_embed_available:
                    dclap_emb, musicnn_emb = await asyncio.gather(
                        loop.run_in_executor(None, get_dclap_embedding, tmp_path),
                        loop.run_in_executor(None, get_musicnn_embedding, tmp_path),
                    )
                else:
                    dclap_emb = await loop.run_in_executor(None, get_dclap_embedding, tmp_path)
                    musicnn_emb = None
            finally:
                try:
                    _os.unlink(tmp_path)
                except OSError:
                    pass

            if dclap_emb is None:
                return False

            emb_str = "[" + ",".join(f"{v:.6f}" for v in dclap_emb) + "]"
            payload = {
                "spotify_id":        item.spotifyId,
                "title":             item.title,
                "artist":            item.artist,
                "embedding":         emb_str,
                "arousal":           item.arousal,
                "valence_deam":      item.valenceDeam,
                "bpm":               item.bpm,
            }
            if musicnn_emb is not None:
                payload["musicnn_embedding"] = "[" + ",".join(f"{v:.6f}" for v in musicnn_emb) + "]"

            write_key = _SUPABASE_SERVICE_KEY or _SUPABASE_KEY
            headers = {
                "Authorization": f"Bearer {write_key}",
                "apikey":         write_key,
                "Content-Type":   "application/json",
                "Prefer":         "resolution=merge-duplicates",
            }
            try:
                async with _httpx.AsyncClient(timeout=8) as client:
                    r = await client.post(
                        f"{_SUPABASE_URL}/rest/v1/track_embeddings",
                        params={"on_conflict": "spotify_id"},
                        json=payload,
                        headers=headers,
                    )
                    return r.status_code in (200, 201)
            except Exception:
                return False

    results = await asyncio.gather(*[embed_one(c) for c in req.candidates[:25]])
    return EmbedCandidatesResponse(embedded=sum(results))


@app.post("/vector-search", response_model=VectorSearchResponse)
async def vector_search(req: VectorSearchRequest) -> VectorSearchResponse:
    """
    Nearest-neighbour search over track_embeddings via Supabase find_similar_tracks RPC.
    Returns up to matchCount candidates sorted by cosine similarity descending.
    """
    _key = _SUPABASE_KEY or _SUPABASE_SERVICE_KEY
    if not _SUPABASE_URL or not _key:
        return VectorSearchResponse(results=[])

    emb_str = "[" + ",".join(f"{v:.6f}" for v in req.embedding) + "]"
    headers = {
        "Authorization": f"Bearer {_key}",
        "apikey":         _key,
        "Content-Type":   "application/json",
    }
    payload = {
        "query_embedding": emb_str,
        "match_count":     req.matchCount,
    }
    import httpx as _httpx
    try:
        async with _httpx.AsyncClient(timeout=8) as client:
            r = await client.post(
                f"{_SUPABASE_URL}/rest/v1/rpc/find_similar_tracks",
                json=payload,
                headers=headers,
            )
            r.raise_for_status()
            rows = r.json()
    except Exception as e:
        print(f"⚠️  vector-search Supabase call failed: {e}")
        return VectorSearchResponse(results=[])

    results = [
        VectorSearchResult(
            spotifyId=row["spotify_id"],
            title=row["title"],
            artist=row["artist"],
            similarity=float(row["similarity"]),
            arousal=row.get("arousal"),
            valenceDeam=row.get("valence_deam"),
            bpm=row.get("bpm"),
        )
        for row in (rows or [])
    ]
    return VectorSearchResponse(results=results)


class MusicnnVectorSearchRequest(BaseModel):
    embedding:  list[float]   # 200-dim MusiCNN query vector
    matchCount: int = 20


@app.post("/musicnn-vector-search", response_model=VectorSearchResponse)
async def musicnn_vector_search(req: MusicnnVectorSearchRequest) -> VectorSearchResponse:
    """
    Nearest-neighbour search over track_embeddings.musicnn_embedding via
    the find_similar_tracks_musicnn Supabase RPC (200-dim cosine similarity).
    Returns up to matchCount candidates sorted by similarity descending.
    """
    _key = _SUPABASE_KEY or _SUPABASE_SERVICE_KEY
    if not _SUPABASE_URL or not _key:
        return VectorSearchResponse(results=[])

    emb_str = "[" + ",".join(f"{v:.6f}" for v in req.embedding) + "]"
    headers = {
        "Authorization": f"Bearer {_key}",
        "apikey":         _key,
        "Content-Type":   "application/json",
    }
    payload = {
        "query_embedding": emb_str,
        "match_count":     req.matchCount,
    }
    import httpx as _httpx
    try:
        async with _httpx.AsyncClient(timeout=8) as client:
            r = await client.post(
                f"{_SUPABASE_URL}/rest/v1/rpc/find_similar_tracks_musicnn",
                json=payload,
                headers=headers,
            )
            r.raise_for_status()
            rows = r.json()
    except Exception as e:
        print(f"⚠️  musicnn-vector-search Supabase call failed: {e}")
        return VectorSearchResponse(results=[])

    results = [
        VectorSearchResult(
            spotifyId=row["spotify_id"],
            title=row["title"],
            artist=row["artist"],
            similarity=float(row["similarity"]),
            arousal=row.get("arousal"),
            valenceDeam=row.get("valence_deam"),
            bpm=row.get("bpm"),
        )
        for row in (rows or [])
    ]
    return VectorSearchResponse(results=results)


@app.post("/admin/import-ab")
async def start_ab_import(token: str, start_from: int = 0) -> dict:
    """
    Trigger the AcousticBrainz import on the Space itself.
    Protected by ADMIN_TOKEN env var set in HF Space secrets.
    Use start_from=N to resume from a specific archive (0-29) after a failure.
    """
    admin_token = os.environ.get("ADMIN_TOKEN", "")
    if not admin_token or token != admin_token:
        raise HTTPException(status_code=403, detail="Invalid token")
    if _import_state["running"]:
        return {"status": "already_running", **_import_state}
    threading.Thread(target=_run_ab_import, args=(start_from,), daemon=True).start()
    return {"status": "started", "total_archives": _AB_TOTAL_ARCHIVES}


@app.get("/admin/import-ab/status")
async def ab_import_status() -> dict:
    """Check progress of a running or completed AcousticBrainz import."""
    elapsed = None
    if _import_state["started_at"]:
        end = _import_state["finished_at"] or time.time()
        elapsed = round(end - _import_state["started_at"])
    return {**_import_state, "elapsed_seconds": elapsed}


@app.get("/ab-lookup")
async def ab_lookup(mbid: str) -> dict:
    """
    Look up AcousticBrainz features for a MusicBrainz Recording ID.
    Returns bpm/key/mode/energy/danceability or 404 on miss.
    """
    if not mbid:
        raise HTTPException(status_code=400, detail="mbid required")
    if _ab_conn is None:
        raise HTTPException(status_code=503, detail="AcousticBrainz DB not loaded")
    row = _ab_conn.execute(
        "SELECT bpm, key, mode, energy, danceability FROM acousticbrainz WHERE mbid = ?",
        (mbid,),
    ).fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="MBID not found")
    bpm, key, mode, energy, danceability = row
    return {
        "mbid":        mbid,
        "bpm":         bpm,
        "key":         key,
        "mode":        mode,
        "energy":      energy,
        "danceability": danceability,
    }


@app.get("/health")
async def health() -> dict[str, str]:
    from audio_analyzer import (
        _dclap_available, _musicnn_embed_available,
        _msd_musicnn_available, _deam_onnx_available,
    )
    vector_catalog = "supabase_configured" if (_SUPABASE_URL and _SUPABASE_KEY) else "supabase_not_configured"
    if _ab_conn is not None:
        try:
            ab_count = _ab_conn.execute("SELECT COUNT(*) FROM acousticbrainz").fetchone()[0]
            ab_status = f"ready ({ab_count:,} tracks)"
        except Exception:
            ab_status = "error"
    elif _AB_DB_PATH.exists():
        ab_status = "loading"
    else:
        ab_status = "db_not_found"
    return {
        "status": "ok",
        "vector_catalog": vector_catalog,
        "dclap": "ready" if _dclap_available else "unavailable",
        "musicnn": "ready" if _musicnn_embed_available else "unavailable",
        "msd_musicnn": "ready" if _msd_musicnn_available else "unavailable",
        "deam": "ready" if _deam_onnx_available else "unavailable",
        "acousticbrainz": ab_status,
    }
