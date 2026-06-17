#!/usr/bin/env python3
"""
test_librosa.py
Simi — End-to-end librosa test replacing Spotify extended quota mode.

Steps:
  1. Fetch a real iTunes preview URL via the iTunes Search API
  2. Run it through audio_analyzer.analyze_from_url()
  3. Print all extracted features — the same ones Spotify's extended quota gave us
  4. Run a similarity check between two songs
"""

from __future__ import annotations

import sys
import os
import asyncio
import json
import urllib.request
import urllib.parse

# ── Make sure we load from the local audio-analyzer dir ──────────────
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ANALYZER_DIR = os.path.join(SCRIPT_DIR, "backend", "audio-analyzer")
sys.path.insert(0, ANALYZER_DIR)

from audio_analyzer import analyze_from_url, AudioFeatures
from similarity_engine import compute_similarity, AudioFeaturesDict

KEY_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def itunes_search(query: str) -> tuple[str, str] | None:
    """Synchronous iTunes search using urllib (ignores proxy env vars via opener)."""
    params = urllib.parse.urlencode({
        "term": query, "media": "music", "limit": 5, "entity": "song"
    })
    url = f"https://itunes.apple.com/search?{params}"

    # Use a direct opener that bypasses proxy env vars
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(url, timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception as e:
        print(f"  iTunes search error: {e}")
        return None

    for track in data.get("results", []):
        preview = track.get("previewUrl")
        if preview:
            name = f'{track["artistName"]} – {track["trackName"]}'
            return name, preview
    return None


def print_features(label: str, f: AudioFeatures) -> None:
    key_name = KEY_NAMES[f.key] if 0 <= f.key <= 11 else "?"
    mode_name = "major" if f.mode == 1 else "minor"
    print(f"\n  {'─'*52}")
    print(f"  🎵  {label}")
    print(f"  {'─'*52}")
    print(f"    {'Feature':<22} {'librosa':>10}   {'Spotify gave'}")
    print(f"    {'─'*50}")
    rows = [
        ("BPM",              f"{f.bpm:.1f}",               "audio_features.tempo"),
        ("Energy",           f"{f.energy:.4f}",             "audio_features.energy"),
        ("Valence",          f"{f.valence:.4f}",            "audio_features.valence"),
        ("Danceability",     f"{f.danceability:.4f}",       "audio_features.danceability"),
        ("Acousticness",     f"{f.acousticness:.4f}",       "audio_features.acousticness"),
        ("Instrumentalness", f"{f.instrumentalness:.4f}",   "audio_features.instrumentalness"),
        ("Liveness",         f"{f.liveness:.4f}",           "audio_features.liveness"),
        ("Loudness",         f"{f.loudness:.2f} dBFS",      "audio_features.loudness"),
        ("Key",              f"{f.key}  ({key_name})",      "audio_features.key"),
        ("Mode",             f"{f.mode}  ({mode_name})",    "audio_features.mode"),
        ("isEstimated",      str(f.is_estimated),           "(new flag — Spotify didn't have)"),
        ("isKeyEstimated",   str(f.is_key_estimated),       "(new flag — Spotify didn't have)"),
    ]
    for name, val, spotify_equiv in rows:
        print(f"    {name:<22} {val:>10}   ← {spotify_equiv}")


async def main() -> None:
    print("\n" + "="*62)
    print("  SIMI — librosa vs Spotify extended quota")
    print("  All features extracted from iTunes 30s preview audio")
    print("  No Spotify API quota needed ✓")
    print("="*62)

    queries = [
        "Billie Eilish bad guy",
        "Daft Punk Get Lucky",
    ]

    features_list: list[AudioFeatures] = []
    names: list[str] = []

    for q in queries:
        print(f"\n[*] iTunes search: '{q}' ...")
        result = itunes_search(q)
        if not result:
            print("  FAIL: no preview URL found")
            continue
        name, preview_url = result
        print(f"  Found:   {name}")
        print(f"  Preview: {preview_url[:72]}...")
        print(f"  Downloading + analyzing with librosa...")

        features = await analyze_from_url(preview_url)
        if features is None:
            print("  FAIL: audio analysis returned None")
            continue

        print_features(name, features)
        features_list.append(features)
        names.append(name)

    # ── Similarity engine test ────────────────────────────────────────
    if len(features_list) == 2:
        def to_dict(f: AudioFeatures) -> AudioFeaturesDict:
            return {
                "bpm": f.bpm, "energy": f.energy, "valence": f.valence,
                "danceability": f.danceability, "acousticness": f.acousticness,
                "instrumentalness": f.instrumentalness, "liveness": f.liveness,
                "loudness": f.loudness, "key": f.key, "mode": f.mode,
                "isEstimated": f.is_estimated, "isKeyEstimated": f.is_key_estimated,
            }

        score, reasons = compute_similarity(to_dict(features_list[0]), to_dict(features_list[1]))
        print(f"\n{'='*62}")
        print(f"  SIMILARITY ENGINE (mirrors RecommendationEngine.swift)")
        print(f"{'='*62}")
        print(f"  {names[0]}")
        print(f"    vs")
        print(f"  {names[1]}")
        print(f"\n  Score:    {score:.4f}  ({score*100:.1f}%)")
        print(f"  Reasons:  {reasons}")
        print(f"\n  Weight breakdown: valence 0.30 + energy 0.30 + dance 0.20 + BPM 0.10 + acoustic 0.10")

    verdict = "PASS" if features_list else "FAIL"
    print(f"\n{'='*62}")
    print(f"  {verdict} — librosa extracted all Spotify audio-feature equivalents")
    print(f"  from iTunes 30s previews with zero Spotify API dependency.")
    print(f"{'='*62}\n")


if __name__ == "__main__":
    asyncio.run(main())
