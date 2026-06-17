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
import os

from fastapi import FastAPI, File, HTTPException, UploadFile
from pydantic import BaseModel, Field

from audio_analyzer import analyze_from_url, analyze_from_bytes, init_essentia, init_dclap, get_dclap_embedding
from similarity_engine import compute_similarity, AudioFeaturesDict, build_embedding

app = FastAPI(title="Simi Audio Analyzer", version="1.0.0")


@app.on_event("startup")
async def on_startup() -> None:
    import threading
    # DCLAP: warm in background so it's ready before first real request.
    # Essentia/TF2 is NOT started here — 400-600MB TF2 footprint risks OOM
    # on Railway's container limits. Essentia features stay disabled until
    # we profile actual memory headroom.
    threading.Thread(target=init_dclap, daemon=True).start()
    # Note: no self-ping keepalive needed — Railway's own load balancer health
    # probes (100.64.0.x) satisfy the inactivity timer. Self-pinging localhost
    # burns CPU credits without helping.


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
    # DCLAP neural embedding
    dclapEmbedding:        list[float] | None = None

    def to_dict(self) -> AudioFeaturesDict:
        return self.model_dump()   # type: ignore[return-value]


class AnalyzeRequest(BaseModel):
    previewUrl: str


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


# ─────────────────────────────────────────────
# Supabase helper — optional, only wired when env vars are present
# ─────────────────────────────────────────────

_SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
_SUPABASE_KEY = os.environ.get("SUPABASE_ANON_KEY", "")


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
# Routes
# ─────────────────────────────────────────────

@app.post("/analyze", response_model=AudioFeatures)
async def analyze(req: AnalyzeRequest) -> AudioFeatures:
    """
    Downloads the 30-second preview and extracts full audio features via librosa.
    Returns immediately with measured BPM, energy, valence, danceability,
    acousticness, instrumentalness, liveness, loudness, key, and mode.
    isEstimated=false (real FFT/chroma/MFCC analysis — not a tag guess),
    isKeyEstimated=false (Krumhansl-Schmuckler pitch class detection is real signal).
    """
    features = await analyze_from_url(req.previewUrl)
    if features is None:
        raise HTTPException(status_code=422, detail="Audio analysis failed — check the URL and ensure ffmpeg is installed for M4A support")

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
    )


@app.post("/analyze-bytes", response_model=AudioFeatures)
async def analyze_bytes_endpoint(file: UploadFile = File(...)) -> AudioFeatures:
    """
    Analyzes pre-downloaded audio bytes POSTed as multipart/form-data.
    iOS downloads the preview URL on-device (fast CDN routing) and sends
    the raw bytes here — eliminates server-side CDN download latency.
    """
    audio_bytes = await file.read()
    filename = file.filename or ""
    suffix = ".m4a" if filename.endswith(".m4a") else ".mp3"

    features = await analyze_from_bytes(audio_bytes, suffix)
    if features is None:
        raise HTTPException(status_code=422, detail="Audio analysis failed")

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
    )


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
    computes a DCLAP embedding, and upserts it into Supabase track_embeddings.
    Fire-and-forget from iOS — errors are logged but do not affect the caller.
    No-ops when DCLAP or Supabase is unavailable.
    """
    from audio_analyzer import _dclap_available
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
                emb = await loop.run_in_executor(None, get_dclap_embedding, tmp_path)
            finally:
                try:
                    _os.unlink(tmp_path)
                except OSError:
                    pass

            if emb is None:
                return False

            emb_str = "[" + ",".join(f"{v:.6f}" for v in emb) + "]"
            payload = {
                "spotify_id":   item.spotifyId,
                "title":        item.title,
                "artist":       item.artist,
                "embedding":    emb_str,
                "arousal":      item.arousal,
                "valence_deam": item.valenceDeam,
                "bpm":          item.bpm,
            }
            headers = {
                "Authorization": f"Bearer {_SUPABASE_KEY}",
                "apikey":         _SUPABASE_KEY,
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

    results = await asyncio.gather(*[embed_one(c) for c in req.candidates[:20]])
    return EmbedCandidatesResponse(embedded=sum(results))


@app.post("/vector-search", response_model=VectorSearchResponse)
async def vector_search(req: VectorSearchRequest) -> VectorSearchResponse:
    """
    Nearest-neighbour search over track_embeddings via Supabase find_similar_tracks RPC.
    Returns up to matchCount candidates sorted by cosine similarity descending.
    """
    if not _SUPABASE_URL or not _SUPABASE_KEY:
        return VectorSearchResponse(results=[])

    emb_str = "[" + ",".join(f"{v:.6f}" for v in req.embedding) + "]"
    headers = {
        "Authorization": f"Bearer {_SUPABASE_KEY}",
        "apikey":         _SUPABASE_KEY,
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


@app.get("/health")
async def health() -> dict[str, str]:
    from audio_analyzer import _essentia_available, _dclap_available
    vector_catalog = "supabase_configured" if (_SUPABASE_URL and _SUPABASE_KEY) else "supabase_not_configured"
    return {
        "status": "ok",
        "vector_catalog": vector_catalog,
        "essentia": "ready" if _essentia_available else "unavailable",
        "dclap": "ready" if _dclap_available else "unavailable",
    }
