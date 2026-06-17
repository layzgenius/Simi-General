#!/usr/bin/env python3
"""
test_vibe_eval.py
Simi — Vibe evaluation suite against the live Railway backend.

Fetches fresh iTunes 30s previews, sends them to Railway /analyze,
and validates the returned AudioFeatures against hand-tuned expected
ranges for a representative set of genre-spanning golden songs.

Run:
    python3 test_vibe_eval.py
    (or double-click run_vibe_eval.command)

No requests / httpx — only stdlib urllib.
"""

from __future__ import annotations

import json
import sys
import time
import urllib.request
import urllib.parse

RAILWAY_URL = "https://simi-audio-analyzer-production.up.railway.app/analyze"
ITUNES_URL  = "https://itunes.apple.com/search"

# How close to a threshold counts as a ⚠️  WARN instead of a hard ❌ FAIL.
# Integer features (mode, key) are excluded — those are always hard pass/fail.
WARN_MARGIN: dict[str, float] = {
    "valence":          0.05,
    "energy":           0.05,
    "danceability":     0.05,
    "acousticness":     0.05,
    "instrumentalness": 0.05,
    "liveness":         0.05,
    "bpm":              5.0,
}

# ──────────────────────────────────────────────────────────────────────
# GOLDEN TEST SUITE
#
# assertions: list of (feature, op, *values)
#   op ">=", "<=", "==" : single-threshold check
#   op "in"             : range check, pass (min, max) as values
#
# must_not: list of (feature, op, value)
#   Condition that must NOT evaluate to True.
# ──────────────────────────────────────────────────────────────────────
GOLDEN_TESTS: list[dict] = [
    {
        "title":        "Get Lucky",
        "artist":       "Daft Punk",
        "genre_label":  "Groovy Minor",
        "assertions": [
            ("valence",      ">=", 0.52),
            # mode NOT asserted — Get Lucky is genuinely Dorian/A-minor;
            # groove correction handles valence regardless of mode detection.
            ("danceability", ">=", 0.65),
            ("bpm",          "in", 110, 130),
        ],
        "must_not": [
            ("valence", "<", 0.45),           # groove correction should prevent this
        ],
    },
    {
        "title":        "bad guy",
        "artist":       "Billie Eilish",
        "genre_label":  "Dark Pop",
        "assertions": [
            ("valence", "<=", 0.45),
            ("energy",  "<=", 0.55),
            ("mode",    "==", 0),
        ],
        "must_not": [
            ("valence", ">", 0.55),
        ],
    },
    {
        "title":        "HUMBLE.",
        "artist":       "Kendrick Lamar",
        "genre_label":  "Hard Trap",
        "assertions": [
            ("energy", ">=", 0.70),
            ("bpm",    "in", 140, 165),
        ],
        "must_not": [
            ("valence", ">", 0.68),           # should not outscore Tiramisu on valence
        ],
    },
    {
        "title":        "Tiramisu",
        "artist":       "Don Toliver",
        "genre_label":  "Melodic Trap / Contemporary R&B",
        "assertions": [
            ("bpm",          "in", 120, 150),
            ("danceability", ">=", 0.50),
        ],
        "must_not": [
            ("energy", ">", 0.95),            # tanh fix should prevent energy=1.00
        ],
    },
    {
        "title":        "Outstanding",
        "artist":       "The Gap Band",
        "genre_label":  "Warm Funk Ballad",
        "assertions": [
            ("mode",    "==", 1),
            ("valence", ">=", 0.48),
            ("bpm",     "in", 85, 115),
        ],
        "must_not": [
            ("valence", "<", 0.40),           # warm ballad correction should prevent this
        ],
    },
    {
        "title":        "Motion Picture Soundtrack",
        "artist":       "Radiohead",
        "genre_label":  "Melancholic Slow",
        "assertions": [
            ("valence", "<=", 0.45),
            ("mode",    "==", 0),
            ("energy",  "<=", 0.40),
        ],
        "must_not": [
            ("valence", ">", 0.55),           # should not get warm ballad bonus (minor key)
        ],
    },
    {
        "title":        "Blinding Lights",
        "artist":       "The Weeknd",
        "genre_label":  "Energetic Synth Pop",
        "assertions": [
            ("energy",  ">=", 0.65),
            ("valence", ">=", 0.55),
            ("bpm",     "in", 165, 185),
        ],
        "must_not": [],
    },
    {
        "title":        "Redbone",
        "artist":       "Childish Gambino",
        "genre_label":  "Slow Funk / Neo-Soul",
        "assertions": [
            ("mode",         "==", 1),
            ("valence",      ">=", 0.48),
            ("danceability", ">=", 0.50),
            ("bpm",          "in", 80, 110),
        ],
        "must_not": [
            ("valence", "<", 0.42),           # warm ballad correction should apply
        ],
    },
    {
        "title":        "Murder on the Dancefloor",
        "artist":       "Sophie Ellis-Bextor",
        "genre_label":  "Dance Pop / Disco",
        "assertions": [
            ("valence",      ">=", 0.60),
            ("danceability", ">=", 0.60),
            ("energy",       ">=", 0.55),
        ],
        "must_not": [],
    },
    {
        "title":          "4 AM",
        "artist":         "Jeremih",
        "genre_label":    "Late Night R&B",
        "fallback_title":  "Don't Tell 'Em",
        "fallback_artist": "Jeremih",
        "assertions": [
            ("energy", "<=", 0.75),
            ("bpm",    "in", 75, 120),
        ],
        "must_not": [
            ("energy", ">", 0.92),            # should not hit the old clip ceiling
        ],
    },
]


# ──────────────────────────────────────────────────────────────────────
# Assertion helpers
# ──────────────────────────────────────────────────────────────────────

def _passes(op: str, actual: float, *threshold: float) -> bool:
    if op == ">=": return actual >= threshold[0]
    if op == "<=": return actual <= threshold[0]
    if op == ">":  return actual >  threshold[0]
    if op == "<":  return actual <  threshold[0]
    if op == "==": return int(actual) == int(threshold[0])
    if op == "in": return threshold[0] <= actual <= threshold[1]
    raise ValueError(f"Unknown op: {op!r}")


def _is_warn(op: str, feature: str, actual: float, *threshold: float) -> bool:
    """True when the assertion failed but the miss is within warning margin."""
    margin = WARN_MARGIN.get(feature, 0.0)
    if margin == 0.0:
        return False
    if op == ">=": return actual < threshold[0] and actual >= threshold[0] - margin
    if op == "<=": return actual > threshold[0] and actual <= threshold[0] + margin
    if op == "in":
        lo, hi = threshold[0], threshold[1]
        return (actual < lo and actual >= lo - margin) or \
               (actual > hi and actual <= hi + margin)
    return False


def _fmt_actual(feature: str, value: float) -> str:
    if feature == "mode":
        return f"{int(value)} ({'major' if int(value) == 1 else 'minor'})"
    if feature in ("key",):
        return str(int(value))
    if feature == "bpm":
        return f"{value:.1f}"
    return f"{value:.4f}"


def _fmt_expected(op: str, *values: float) -> str:
    if op == "in":  return f"{values[0]}–{values[1]}"
    if op == "==":
        if len(values) == 1 and values[0] in (0, 1):
            return f"== {int(values[0])} ({'major' if int(values[0]) == 1 else 'minor'})"
        return f"== {values[0]}"
    return f"{op} {values[0]}"


# ──────────────────────────────────────────────────────────────────────
# Network helpers
# ──────────────────────────────────────────────────────────────────────

def _opener() -> urllib.request.OpenerDirector:
    """Returns a urllib opener that bypasses any proxy env vars (sandbox-safe)."""
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def fetch_preview_url(title: str, artist: str) -> str | None:
    """Searches iTunes for the song and returns a 30s preview URL, or None."""
    params = urllib.parse.urlencode({
        "term": f"{title} {artist}", "media": "music",
        "limit": 5, "entity": "song",
    })
    try:
        with _opener().open(f"{ITUNES_URL}?{params}", timeout=10) as resp:
            data = json.loads(resp.read())
    except Exception as exc:
        print(f"  iTunes search error: {exc}")
        return None

    for track in data.get("results", []):
        url = track.get("previewUrl")
        if url:
            return url
    return None


def analyze_via_railway(preview_url: str, timeout: int = 55) -> dict | None:
    """POSTs previewUrl to Railway /analyze and returns the parsed JSON dict."""
    payload = json.dumps({"previewUrl": preview_url}).encode()
    req = urllib.request.Request(
        RAILWAY_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with _opener().open(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception as exc:
        print(f"  Railway error: {exc}")
        return None


# ──────────────────────────────────────────────────────────────────────
# Per-song test runner
# ──────────────────────────────────────────────────────────────────────

def run_test(test: dict, idx: int, total: int) -> tuple[int, int, int]:
    """
    Fetches, analyzes, asserts.
    Returns (passes, fails, warns).
    """
    title  = test["title"]
    artist = test["artist"]
    label  = test["genre_label"]

    header = f"── [{idx}/{total}] {title} — {artist} ({label})"
    print(f"\n{header}")
    print("─" * min(len(header), 72))

    # ── iTunes preview URL ──────────────────────────────────────────
    preview_url = fetch_preview_url(title, artist)
    if not preview_url and "fallback_title" in test:
        fb_title  = test["fallback_title"]
        fb_artist = test["fallback_artist"]
        print(f"  ⚠️  No preview for '{title}' — trying fallback '{fb_title}'")
        preview_url = fetch_preview_url(fb_title, fb_artist)

    if not preview_url:
        print("  ❌  SKIP — no iTunes preview URL found")
        return 0, 1, 0

    # ── Railway /analyze ────────────────────────────────────────────
    print(f"  → Sending to Railway /analyze  (allow up to 55s)…")
    t0 = time.time()
    features = analyze_via_railway(preview_url)
    elapsed = time.time() - t0

    if features is None:
        print("  ❌  SKIP — Railway did not respond")
        return 0, 1, 0
    if "error" in features:
        print(f"  ❌  SKIP — Railway error: {features['error']}")
        return 0, 1, 0

    print(f"  ✓ analysis done in {elapsed:.1f}s")

    passes = fails = warns = 0

    # ── Assertions ──────────────────────────────────────────────────
    for assertion in test["assertions"]:
        feature, op, *values = assertion
        actual = features.get(feature)

        if actual is None:
            print(f"  ❌  {feature} — missing from Railway response")
            fails += 1
            continue

        actual_f = float(actual)
        threshold = tuple(float(v) for v in values)
        ok   = _passes(op, actual_f, *threshold)
        warn = (not ok) and _is_warn(op, feature, actual_f, *threshold)

        sym = "✅" if ok else ("⚠️ " if warn else "❌")
        print(f"  {sym} {feature}={_fmt_actual(feature, actual_f)}  "
              f"(expected {_fmt_expected(op, *threshold)})")

        if ok:   passes += 1
        elif warn: warns += 1
        else:    fails  += 1

    # ── Must-not checks ─────────────────────────────────────────────
    for mn in test.get("must_not", []):
        feature, op, *values = mn
        actual = features.get(feature)

        if actual is None:
            continue

        actual_f  = float(actual)
        threshold = tuple(float(v) for v in values)
        violated  = _passes(op, actual_f, *threshold)
        cond_str  = f"{feature} {op} {values[0]}"

        if not violated:
            print(f"  ✅  must_not {cond_str} → {_fmt_actual(feature, actual_f)} is safe")
            passes += 1
        else:
            print(f"  ❌  must_not {cond_str} → {_fmt_actual(feature, actual_f)} VIOLATED")
            fails += 1

    return passes, fails, warns


# ──────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────

def main() -> None:
    total_songs = len(GOLDEN_TESTS)

    print()
    print("=" * 62)
    print("  SIMI — Vibe Eval Suite  (live Railway backend)")
    print(f"  {total_songs} golden songs · fresh iTunes previews · no simulator needed")
    print("=" * 62)

    song_passes:  list[str] = []  # fully clean
    song_warns:   list[str] = []  # at least one warn, no fails
    song_fails:   list[str] = []  # at least one fail

    grand_passes = grand_fails = grand_warns = 0

    for i, test in enumerate(GOLDEN_TESTS, start=1):
        if i > 1:
            time.sleep(2)   # avoid cold-start pile-up on Railway

        p, f, w = run_test(test, i, total_songs)
        grand_passes += p
        grand_fails  += f
        grand_warns  += w

        song_label = f"{test['title']} — {test['artist']}"
        if f > 0:
            song_fails.append(song_label)
        elif w > 0:
            song_warns.append(song_label)
        else:
            song_passes.append(song_label)

    # ── Summary ─────────────────────────────────────────────────────
    clean_count = len(song_passes)
    fail_count  = len(song_fails)
    warn_count  = len(song_warns)
    total_checks = grand_passes + grand_fails + grand_warns

    print()
    print("─" * 62)
    print("  SUMMARY")
    print("─" * 62)
    print(f"  Songs:   {clean_count} fully passed · {warn_count} warnings · {fail_count} failed  (of {total_songs})")
    print(f"  Checks:  {grand_passes} passed · {grand_warns} warned · {grand_fails} failed  (of {total_checks})")

    if song_fails:
        print(f"\n  ❌  Failed songs:")
        for s in song_fails:
            print(f"       {s}")

    if song_warns:
        print(f"\n  ⚠️   Warning songs:")
        for s in song_warns:
            print(f"       {s}")

    if not song_fails and not song_warns:
        print("\n  🎉  All assertions passed.")

    print()
    sys.exit(1 if song_fails else 0)


if __name__ == "__main__":
    main()
