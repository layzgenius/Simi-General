# Simi Discovery Pipeline: New Candidate Sources for Emotional Imprint Matching
**Date:** 2026-06-08  
**Research mode:** Standard (6 phases + focused yield analysis)  
**Question:** What candidate sources beyond Last.fm co-listening and Spotify related-artist recs can feed emotionally-accurate music recommendations? Which free source gives maximum yield?

---

## Executive Summary

**Winner: AcousticBrainz similarity with the `moods` metric.** It returns up to 1,000 mood-similar recordings per query, is completely free with no auth required, covers 1.67M tracks from Essentia audio analysis, and uses high-level ML-estimated emotional vectors (happy/sad/relaxed/aggressive) — audio-derived emotional similarity directly aligned with Simi's design goal. No other free source approaches this in candidate volume or emotional signal quality.

**Second: Apple MusicKit editorial playlists.** Free for iOS developers (Apple Developer Program already required for the app), full Apple Music catalog, human-curated vibe collections. Best used as a fallback when AcousticBrainz returns no result for a seed song (post-2022 releases, niche catalog).

Spotify's recommendations endpoint was deprecated November 27, 2024 and is no longer accessible. Reddit API now requires explicit pre-approval. Last.fm `track.getSimilar` is already integrated but remains a co-listening graph.

---

## The Core Problem

The current architecture pulls candidates from two sources:
1. **Spotify related-artist recommendations** → tracks from artists Spotify considers similar
2. **Last.fm similar tracks + tag-seeded searches** → co-listening graph + genre tag queries

Both share the same flaw: they are **popularity-weighted, genre-adjacent, co-listening graphs**. They answer "what do people who listen to X also listen to?" — not "what sounds and feels like X?" A crate-digger with taste approaches these differently. They'd ask about production era, vocal character, reverb depth, emotional arc — none of which lives in a co-listening graph.

**Spotify is now dead as a candidate source.** Audio features (`target_valence`, `target_energy`, `target_danceability`) and the recommendations endpoint were deprecated November 27, 2024. Apps that had quota extensions in flight on that date keep access; everyone else gets 403s. This confirms Simi's pivot to librosa was correct timing.

---

## Source Rankings: Free × Yield

### 🥇 AcousticBrainz — Maximum free yield

**What it is:** A frozen (2022) but fully live read-only API with Essentia-computed audio features for 1.67M MusicBrainz-indexed recordings. The similarity endpoint uses Annoy approximate nearest neighbors to return audio-similar tracks.

**The moods metric:** AcousticBrainz's `moods` similarity metric computes vectors from Essentia's high-level ML mood classifiers (happy/sad/relaxed/aggressive). Two songs scoring similarly on these mood dimensions are emotionally similar by audio signal — not by co-listening. This is the only free API that offers mood-vector-based candidate discovery.

**Yield numbers (confirmed from API docs):**
- `GET /api/v1/similarity/moods/?recording_ids={mbid}&n_neighbours=200` → up to **200 mood-similar recordings** per query
- Maximum allowed: `n_neighbours` up to **1,000** per single MBID lookup
- `threshold` param (0–1): set to 0.5 to cut noise and reduce downstream scoring burden
- `remove_dups=all`: de-duplicate same artist across submissions

**For Simi, use a two-pass combination:**
1. `moods` metric → 100 neighbors (emotional classification match)
2. `mfccs` metric → 100 neighbors (timbral/texture match)
3. Intersect: songs appearing in both lists = emotionally + timbrally similar
4. Take top 20–30 from intersection as AcousticBrainz candidates

**Integration sketch:**
```
seed: "Tiramisu" by Don Toliver
→ GET musicbrainz.org/ws/2/recording?query=tiramisu+don+toliver&fmt=json
→ extract MBID: "abc123..."
→ GET acousticbrainz.org/api/v1/similarity/moods/?recording_ids=abc123&n_neighbours=100
→ GET acousticbrainz.org/api/v1/similarity/mfccs/?recording_ids=abc123&n_neighbours=100
→ intersect MBID lists
→ GET musicbrainz.org/ws/2/recording/{mbid} for each → get track + artist name
→ search Apple Music API for iTunes preview URL
→ merge into candidate pool
```

**Rate limits:**
- AcousticBrainz: **10 requests / 10 seconds** (1/sec sustained)
- MusicBrainz: **1 request / second** (non-commercial, free)
- Both use response headers for limit communication; check X-RateLimit-Remaining

**Limitations:**
- Catalog **frozen at 2022** — no new releases since then. Searching for a 2024 song will return no MBID match and the pipeline falls through to MusicKit.
- 1.67M recordings vs. Apple Music's ~100M. Hit rate estimated 60–80% for mainstream catalog; lower for niche/recent.
- Two-hop lookup adds latency: MusicBrainz (name → MBID) + AcousticBrainz (MBID → similar) + MusicBrainz (each similar MBID → name) + Apple Music search. Should run in parallel with existing Last.fm candidate fetch.
- AcousticBrainz is community-maintained with no guarantee of uptime continuity (frozen 2022 suggests potential eventual shutdown).

**Cost:** Zero. No auth required for read endpoints.

---

### 🥈 Apple MusicKit Editorial Playlists — Best human-curated free source

**What it is:** Apple's MusicKit framework (native iOS) exposes editorial playlist search, genre-filtered charts, and mood-themed collections. These are human-curated by Apple Music's editorial team — not algorithmic.

**Why it complements AcousticBrainz:**
- Fills the post-2022 gap: AcousticBrainz has no new releases; MusicKit has everything Apple Music has
- Human-curated "Late Night R&B" or "Bedroom Pop Essentials" playlists are curated by people thinking in terms of vibe and scene
- Every returned track has an iTunes preview URL natively — no search-and-match step

**Yield numbers:**
- Editorial playlists typically 15–40 tracks each
- Can query 2–3 matching playlists per seed → 30–120 candidates
- 20 req/sec rate limit
- No per-day quota limits documented for standard app usage

**Integration sketch:**
```swift
// Map Simi tags to editorial playlist keywords
let keywords = deriveEditorialKeywords(from: seedSong) // "melodic trap" → "melodic r&b late night"
let playlists = try await MusicCatalogSearchRequest(term: keywords, types: [Playlist.self])
let tracks = playlists.flatMap { playlist in playlist.tracks?.prefix(15) ?? [] }
// All tracks already have appleMusic.url and previewAssets
```

**Cost:** Zero (Apple Developer Program is $99/yr already required to ship the app).

---

### ⚠️ Last.fm (already integrated, co-listening limitation acknowledged)

**What it is:** `track.getSimilar` — already in Simi's pipeline. Returns similar tracks by listening co-occurrence. No auth required, no documented hard rate limit (practical: ~4 req/sec safe).

**Methods available beyond getSimilar:**
- `tag.getTopTracks` — up to 50 tracks per tag per page. Currently used for tag-seeded discovery.
- `tag.getSimilar` — expand seed tags to semantically-adjacent tags, then fetch their top tracks. This is **underutilized in Simi** and could increase candidate diversity at zero cost.
- `artist.getSimilar` — 250 similar artists, then fetch their top tracks via `artist.getTopTracks`. Higher volume than track-level similarity.

**Verdict:** Still valuable for breadth. The structural co-listening limitation is real but it generates many candidates cheaply. Keep as primary breadth source; use AcousticBrainz for emotional depth.

---

### 🚫 Spotify Recommendations — Dead

Deprecated **November 27, 2024**. `GET /recommendations` with `target_valence`, `target_energy`, `seed_genres` — all return 403. No replacement. This source should be removed from Simi's architecture if any remnants exist.

---

### 🚫 Reddit r/ifyoulikeblank — Gated

As of **November 2025**, Reddit requires explicit pre-approval for all API access including personal/hobby projects. The free tier (100 QPM when approved) is fine, but the approval gate makes this non-trivial to integrate quickly. The data quality is excellent — human taste reasoning with emotional language — but it's a future source, not a Round 8 candidate.

---

### ❓ Musicovery — Unverifiable

API documentation URL (musicovery.com/api/V6/doc/documentation.php) is JavaScript-rendered and returned empty. Cannot verify free tier limits, catalog size, or registration process without manual browser testing. The B2B-facing landing page suggests it's designed for music services companies, not indie app developers. Treat as unknown until tested manually.

---

## Final Comparison Table

| Source | Emotional signal | Free yield / query | Catalog scope | Status |
|---|---|---|---|---|
| **AcousticBrainz moods** | ⭐⭐⭐ Mood vectors (audio ML) | Up to 1,000 | 1.67M (frozen 2022) | ✅ Free, active |
| **AcousticBrainz mfccs** | ⭐⭐ Timbral/texture | Up to 1,000 | Same | ✅ Free, active |
| **Apple MusicKit editorial** | ⭐⭐ Human-curated vibe | 30–120 / session | ~100M | ✅ Free (dev program) |
| **Last.fm similar** *(current)* | ⭐ Co-listening graph | ~100–200 | Large | ✅ Already integrated |
| **Last.fm tag.getSimilar** | ⭐ Co-listening | 50 per expanded tag | Large | ✅ Underutilized |
| **Spotify recommendations** | N/A | 0 | N/A | ❌ Deprecated Nov 2024 |
| **Reddit r/ifyoulikeblank** | ⭐⭐⭐ Human taste reasoning | Build required | Artist-level | ⚠️ Pre-approval required |
| **Musicovery** | ⭐⭐ Valence/arousal | Unknown | Unknown | ❓ Unverifiable |
| **Cyanite.ai** | ⭐⭐⭐ Deep AI emotional | Small free tier | High | 💰 B2B pricing |

---

## Recommended Implementation Order

**Round 8 — AcousticBrainz moods pipeline (maximum emotional yield)**

Wire a new candidate source: MusicBrainz MBID lookup → AcousticBrainz `moods` similarity (n=100) + `mfccs` similarity (n=100) → intersect → MusicBrainz name lookup → Apple Music search → merge into pool. Run in parallel with existing Last.fm fetch. This is the highest-leverage change to candidate quality possible with zero cost.

Specific API calls:
```
# Step 1: MBID lookup (1 req to MusicBrainz)
GET https://musicbrainz.org/ws/2/recording?query={artist}+{title}&limit=5&fmt=json
→ take top result MBID

# Step 2: Similarity (2 req to AcousticBrainz, parallelizable)
GET https://acousticbrainz.org/api/v1/similarity/moods/?recording_ids={mbid}&n_neighbours=100&threshold=0.6&remove_dups=all
GET https://acousticbrainz.org/api/v1/similarity/mfccs/?recording_ids={mbid}&n_neighbours=100&threshold=0.6&remove_dups=all

# Step 3: Name lookups (up to 20 req to MusicBrainz, rate-limited)
GET https://musicbrainz.org/ws/2/recording/{mbid}?fmt=json
→ extract title + artist-credit[0].name

# Step 4: Apple Music search (up to 20 req, parallelizable with existing pattern)
# Same pattern as current related-artist track lookup
```

Estimated effort: ~2 sessions.

**Round 9 — Apple MusicKit editorial injection**

Add a MusicKit editorial playlist search path, seeded by `deriveAudioQueryTags` output. Use as fallback when AcousticBrainz returns no MBID match. Estimated effort: ~1 session.

**Future — Reddit community graph**

After rounds 8+9, if emotional precision is still lacking, file for Reddit API access and build an r/ifyoulikeblank artist-level lookup graph. This solves niche/underground discovery that audio databases can't cover.

---

## What This Doesn't Solve

Even with new sources, Simi can only recommend songs it can play previews of. AcousticBrainz MBID results that don't match any Apple Music catalog entry are dead ends. The Apple Music search-and-match step (artist + title → iTunes preview URL) will drop some candidates — estimated 20–40% loss for older/niche catalog. This is unavoidable without a streaming partnership.

The deeper gap — underground music only on Bandcamp or SoundCloud — is a product architecture question beyond candidate pipeline scope.

---

## Sources

- [AcousticBrainz Web API — similarity endpoint](https://acousticbrainz.readthedocs.io/api.html)
- [AcousticBrainz Recording Similarity — metrics](https://acousticbrainz.readthedocs.io/similarity.html)
- [Acoustic similarity in AcousticBrainz — MetaBrainz Blog](https://blog.metabrainz.org/2021/09/01/acoustic-similarity-in-acousticbrainz/)
- [AcousticBrainz coverage: 1.67M unique recordings](https://musicbrainz.org/doc/AcousticBrainz)
- [Spotify audio features deprecated — FreqBlog](https://freqblog.com/blog/spotify-audio-features-replacement-2026/)
- [Spotify deprecation Nov 27, 2024 — Community thread](https://community.spotify.com/t5/Spotify-for-Developers/Changes-to-Web-API/td-p/6540414/page/6)
- [Apple MusicKit — Apple Developer](https://developer.apple.com/musickit/)
- [Apple Music API — rate limits + catalog](https://developer.apple.com/documentation/applemusicapi/)
- [Reddit API pre-approval requirement Nov 2025](https://replydaddy.com/blog/reddit-api-pre-approval-2025-personal-projects-crackdown)
- [MusicBrainz API — rate limiting](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting)
- [Last.fm track.getSimilar](https://www.last.fm/api/show/track.getSimilar)
