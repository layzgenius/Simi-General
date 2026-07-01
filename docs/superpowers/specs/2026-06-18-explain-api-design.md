# Design Spec: /explain API Endpoint
**Date:** 2026-06-18
**Priority:** P2 (Blue Ocean Memo — Task 9)
**Gaps addressed:** Gap 9 — No B2B/API story
**Effort:** Medium

---

## Problem

Simi's match reasoning lives entirely inside the iOS app. Developers who want to embed Simi's emotional matching logic in their own tools (sync licensing dashboards, playlist tools, music data pipelines) have no way to get the human-readable explanation for why two songs match. The existing `/similarity` endpoint returns a score and match reasons but no structured explanation.

---

## Goal

Add a `POST /explain` endpoint to the FastAPI backend that accepts two songs' audio features (and optional genre metadata) and returns:
- The similarity score
- Match reasons (existing)
- Structured explanation rows (the same rows `MatchExplanationView` renders in iOS)
- Genre bridge label (when genres cross families)

This is a faithful Python port of `buildMatchExplanation()` from `RecommendationEngine.swift` — same thresholds, same labels, same logic.

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Port target | Python function `build_explanation()` in `similarity_engine.py` | Keeps explanation logic alongside similarity logic; same file that `compute_similarity()` lives in |
| Genre input | Optional `sourceGenres: list[Genre]` + `targetGenre: Genre \| None` on request | Mirrors Swift signature; omit when caller doesn't have genre data |
| Genre bridge | Only when both families are known and differ | Matches Swift behavior exactly |
| Row gates | `isEstimated: bool` gates rows 1, 2, 5; `isKeyEstimated: bool` gates row 3; `grooveRatio` presence gates row 4 | Identical to Swift: only show rows we can back up with real data |
| Valence source | `valenceEssentia` if present, else `valence` | Mirrors Swift's `source.valenceEssentia ?? source.valence` |
| Endpoint path | `POST /explain` | Parallel to `/similarity`; clear B2B intent |

---

## Architecture

### Modified files
- Modify: `backend/audio-analyzer/similarity_engine.py` — add `build_explanation()` + `detect_genre_family()` + `Genre` TypedDict
- Modify: `backend/audio-analyzer/main.py` — add `ExplainRequest`, `ExplainResponse`, `ExplanationRow`, `ExplanationResult` Pydantic models + `POST /explain` route

### What does NOT change
- iOS app — no changes
- `/similarity`, `/analyze`, `/batch-analyze`, or any other route
- Supabase schema

---

## Python Implementation

### `Genre` TypedDict and family detection (similarity_engine.py)

```python
class Genre(TypedDict, total=False):
    main: str
    sub:  str

_GENRE_FAMILIES: dict[str, tuple[str, list[str]]] = {
    # (displayName, keywords) — priority order: blues > metal > rock > hiphop > rnb > jazz > classical > electronic > folk > pop
    "blues":      ("Blues",      ["blues"]),
    "metal":      ("Metal",      ["metal", "thrash", "metalcore", "deathcore", "doom"]),
    "rock":       ("Rock",       ["hard rock", "punk", "grunge", "rock", "hardcore", "shoegaze", "post-rock"]),
    "hiphop":     ("Hip-Hop",    ["hip", "rap", "trap", "drill", "grime", "phonk"]),
    "rnb":        ("R&B",        ["r&b", "rnb", "soul", "funk", "gospel", "slow jam", "neo-soul"]),
    "jazz":       ("Jazz",       ["jazz"]),
    "classical":  ("Classical",  ["classical", "orchestral"]),
    "electronic": ("Electronic", ["electronic", "edm", "house", "techno", "trance", "drum and bass", "dubstep", "synthwave", "synth"]),
    "folk":       ("Folk",       ["folk", "acoustic", "country", "americana", "bluegrass", "singer-songwriter"]),
    "pop":        ("Pop",        ["pop"]),
}
_FAMILY_ORDER = ["blues", "metal", "rock", "hiphop", "rnb", "jazz", "classical", "electronic", "folk", "pop"]

def detect_genre_family(genres: list[Genre]) -> tuple[str, str] | None:
    """Returns (family_key, displayName) for the dominant genre family, or None if unknown."""
    names = [g.get("main", "").lower() for g in genres]
    for family_key in _FAMILY_ORDER:
        _, keywords = _GENRE_FAMILIES[family_key]
        if any(kw in name for name in names for kw in keywords):
            display, _ = _GENRE_FAMILIES[family_key]
            return family_key, display
    return None
```

### `build_explanation()` (similarity_engine.py)

Ports `buildMatchExplanation()` from Swift exactly:

```python
class ExplanationRow(TypedDict):
    label:      str
    descriptor: str

class ExplanationResult(TypedDict):
    rows:            list[ExplanationRow]
    genreBridgeLabel: str | None

def build_explanation(
    source: AudioFeaturesDict,
    target: AudioFeaturesDict,
    source_genres: list[Genre] | None = None,
    target_genre:  Genre | None = None,
) -> ExplanationResult:
    rows: list[ExplanationRow] = []

    src_estimated = source.get("isEstimated", True)
    tgt_estimated = target.get("isEstimated", True)
    src_key_est   = source.get("isKeyEstimated", True)
    tgt_key_est   = target.get("isKeyEstimated", True)

    # Row 1: Emotional weight — valence
    src_v = source.get("valenceEssentia") or source["valence"]
    tgt_v = target.get("valenceEssentia") or target["valence"]
    if not src_estimated and not tgt_estimated and abs(src_v - tgt_v) < 0.20:
        avg = (src_v + tgt_v) / 2
        if avg < 0.35:
            desc = "Same melancholic weight"
        elif avg < 0.50:
            desc = "Same bittersweet edge"
        elif avg < 0.65:
            desc = "Same balanced mood"
        else:
            desc = "Same bright energy"
        rows.append({"label": "Emotional weight", "descriptor": desc})

    # Row 2: Intensity — energy
    if not src_estimated and not tgt_estimated and abs(source["energy"] - target["energy"]) < 0.20:
        avg = (source["energy"] + target["energy"]) / 2
        if avg < 0.35:
            desc = "Equally restrained"
        elif avg < 0.55:
            desc = "Equally measured"
        elif avg < 0.75:
            desc = "Equally driven"
        else:
            desc = "Equally intense"
        rows.append({"label": "Intensity", "descriptor": desc})

    # Row 3: Key — only when both measured (not C-Major placeholder)
    if not src_key_est and not tgt_key_est and source.get("mode") == target.get("mode"):
        mode = source.get("mode", 1)
        rows.append({"label": "Key", "descriptor": "Both major key" if mode == 1 else "Both minor key"})

    # Row 4: Groove feel — librosa only (grooveRatio present)
    src_groove = source.get("grooveRatio")
    tgt_groove = target.get("grooveRatio")
    if src_groove is not None and tgt_groove is not None and abs(src_groove - tgt_groove) < 0.35:
        avg = (src_groove + tgt_groove) / 2
        if avg < 0.5:
            desc = "Smooth and flowing"
        elif avg < 0.9:
            desc = "Equally measured pulse"
        else:
            desc = "Equally syncopated"
        rows.append({"label": "Groove feel", "descriptor": desc})

    # Row 5: Sonic texture — spectralWarmth, librosa only
    if not src_estimated and not tgt_estimated and abs(source.get("spectralWarmth", 0.5) - target.get("spectralWarmth", 0.5)) < 0.20:
        avg = (source.get("spectralWarmth", 0.5) + target.get("spectralWarmth", 0.5)) / 2
        if avg < 0.35:
            desc = "Both bright and airy"
        elif avg < 0.65:
            desc = "Similar tonal warmth"
        else:
            desc = "Both warm and full"
        rows.append({"label": "Sonic texture", "descriptor": desc})

    # Genre bridge
    genre_bridge: str | None = None
    if source_genres and target_genre:
        src_family = detect_genre_family(source_genres)
        tgt_family = detect_genre_family([target_genre])
        if src_family and tgt_family and src_family[0] != tgt_family[0]:
            genre_bridge = f"{src_family[1]} → {tgt_family[1]}"

    return {"rows": rows, "genreBridgeLabel": genre_bridge}
```

---

## Endpoint (main.py)

### Pydantic models

```python
class GenreItem(BaseModel):
    main: str
    sub:  str = ""

class ExplainRequest(BaseModel):
    source:       AudioFeatures
    target:       AudioFeatures
    sourceGenres: list[GenreItem] = []
    targetGenre:  GenreItem | None = None

class ExplanationRowItem(BaseModel):
    label:      str
    descriptor: str

class ExplanationDetail(BaseModel):
    rows:             list[ExplanationRowItem]
    genreBridgeLabel: str | None

class ExplainResponse(BaseModel):
    score:        float
    matchReasons: list[str]
    explanation:  ExplanationDetail
```

### Route

```python
@app.post("/explain", response_model=ExplainResponse)
async def explain(req: ExplainRequest) -> ExplainResponse:
    """
    Returns similarity score, match reasons, and a structured human-readable
    explanation for why two songs match emotionally.

    Mirrors buildMatchExplanation() in RecommendationEngine.swift.
    Rows are only populated when the audio features are measured (isEstimated=false)
    and the delta is within the threshold — same gates as the iOS app.

    sourceGenres / targetGenre are optional — omit them when genre metadata is
    unavailable and the genreBridgeLabel field will be null.
    """
    score, reasons = compute_similarity(req.source.to_dict(), req.target.to_dict())

    src_genres = [{"main": g.main, "sub": g.sub} for g in req.sourceGenres]
    tgt_genre  = {"main": req.targetGenre.main, "sub": req.targetGenre.sub} if req.targetGenre else None

    explanation = build_explanation(
        source=req.source.to_dict(),
        target=req.target.to_dict(),
        source_genres=src_genres or None,
        target_genre=tgt_genre,
    )

    return ExplainResponse(
        score=score,
        matchReasons=reasons,
        explanation=ExplanationDetail(
            rows=[ExplanationRowItem(label=r["label"], descriptor=r["descriptor"]) for r in explanation["rows"]],
            genreBridgeLabel=explanation["genreBridgeLabel"],
        ),
    )
```

---

## Example request / response

```
POST https://layzskolah-simi-audio-analyzer.hf.space/explain
Content-Type: application/json

{
  "source": { "bpm": 92, "energy": 0.41, "valence": 0.28, "danceability": 0.44,
              "acousticness": 0.62, "instrumentalness": 0.01, "liveness": 0.09,
              "loudness": -9.1, "key": 9, "mode": 0,
              "isEstimated": false, "isKeyEstimated": false,
              "spectralWarmth": 0.38, "grooveRatio": 0.62 },
  "target": { "bpm": 88, "energy": 0.38, "valence": 0.31, "danceability": 0.49,
              "acousticness": 0.55, "instrumentalness": 0.0,  "liveness": 0.11,
              "loudness": -10.2, "key": 11, "mode": 0,
              "isEstimated": false, "isKeyEstimated": false,
              "spectralWarmth": 0.42, "grooveRatio": 0.58 },
  "sourceGenres": [{ "main": "Jazz", "sub": "Contemporary Jazz" }],
  "targetGenre":  { "main": "Hip-Hop", "sub": "Lo-fi" }
}
```

```json
{
  "score": 0.84,
  "matchReasons": ["Dark Mood", "Acoustic Match", "Same Genre"],
  "explanation": {
    "rows": [
      { "label": "Emotional weight", "descriptor": "Same melancholic weight" },
      { "label": "Intensity",        "descriptor": "Equally restrained" },
      { "label": "Key",              "descriptor": "Both minor key" },
      { "label": "Groove feel",      "descriptor": "Equally measured pulse" },
      { "label": "Sonic texture",    "descriptor": "Similar tonal warmth" }
    ],
    "genreBridgeLabel": "Jazz → Hip-Hop"
  }
}
```

---

## Execution scope

Two backend files only. No iOS changes. No Supabase schema changes. No new dependencies (all imports already in the file).
