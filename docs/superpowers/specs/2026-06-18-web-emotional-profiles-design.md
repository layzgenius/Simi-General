# Design Spec: Web + Emotional Profile Pages
**Date:** 2026-06-18
**Priority:** P2 (Blue Ocean Memo — Task 8)
**Gaps addressed:** Gap 5 (explainability), AI SEO / blue ocean positioning
**Effort:** High

---

## Problem

There is no public web presence for Simi. Crucially, the AI SEO opportunity — search queries like "what songs feel like Bohemian Rhapsody" — is completely uncontested. No authoritative source answers these questions. Simi has the data (emotional fingerprints for analyzed songs in Supabase) and the reasoning (the match explanation system from Task 1) to own this space.

---

## Goal

A Next.js site deployed on Vercel at the `simi.app` domain with two page types:

1. **Homepage (`/`)** — hero copy, brief how-it-works, App Store CTA
2. **Emotional Profile pages (`/song/[spotifyId]`)** — per-song pages showing emotional fingerprint, vibe summary, and 5 similar tracks from the catalog

These profile pages target AI search queries like "songs that feel like X" — currently unowned, high-intent, zero competition from Spotify/Apple.

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Framework | Next.js 14 App Router + TypeScript | ISR for profile pages; Vercel first-class integration |
| Styling | Tailwind CSS | Fast, no CSS file management, consistent with modern stacks |
| Profile URL | `/song/[spotifyId]` | Stable (no slug collision risk), easy to link from app |
| Data source | Supabase JS client (server components) | Direct DB access in RSC — no intermediate API |
| Similar tracks | Supabase `find_similar_tracks` RPC | Already wired in backend; returns 5 nearest by embedding |
| Vibe summary | Rule-based from features | No LLM calls; deterministic; ~4 descriptors joined |
| ISR revalidation | 3600s (1 hour) | Profile pages are stable; don't need real-time |
| Homepage | Simple hero + 3 feature pills + App Store CTA | YAGNI — the profile pages are the SEO-critical surface |
| Project location | `web/` in outer repo | Separate from existing static prototypes in `landing/` |
| Sitemap | Auto-generated from `analyzed_songs` catalog | Helps search engines discover all profile pages |

---

## Supabase Schema (read-only, no changes)

Table: `analyzed_songs`
- `spotify_id: text` (PK)
- `title: text`
- `artist: text`
- `embedding: vector(8)`
- `features: jsonb` — all AudioFeatures fields (bpm, energy, valence, danceability, acousticness, instrumentalness, liveness, loudness, key, mode, isEstimated, isKeyEstimated, spectralWarmth, grooveRatio, ...)

RPC: `find_similar_tracks(query_embedding: text, match_count: int)` — returns similar rows by cosine similarity

---

## Vibe Summary Logic

Deterministic, rule-based, 3–5 descriptors joined by ", ":

```typescript
export function generateVibe(f: AudioFeatures): string {
  const terms: string[] = []

  // Valence — emotional colour
  if (f.valence < 0.35)      terms.push("melancholic")
  else if (f.valence < 0.55) terms.push("bittersweet")
  else if (f.valence < 0.70) terms.push("balanced")
  else                        terms.push("uplifting")

  // Energy — intensity
  if (f.energy < 0.35)      terms.push("gentle")
  else if (f.energy < 0.55) terms.push("measured")
  else if (f.energy < 0.75) terms.push("driven")
  else                       terms.push("intense")

  // Texture modifiers
  if (f.acousticness > 0.60)       terms.push("acoustic")
  if (f.instrumentalness > 0.50)   terms.push("instrumental")
  if (f.danceability > 0.72)       terms.push("groove-heavy")
  if (f.mode === 0)                 terms.push("minor key")
  else                              terms.push("major key")

  return terms.slice(0, 4).join(", ")
}
```

---

## Valence/Energy Descriptor Labels (for fingerprint bars)

Used in the emotional fingerprint section (shown next to each bar):

```typescript
export function valenceLabel(v: number): string {
  if (v < 0.35) return "Melancholic"
  if (v < 0.55) return "Bittersweet"
  if (v < 0.70) return "Balanced"
  return "Uplifting"
}

export function energyLabel(e: number): string {
  if (e < 0.35) return "Gentle"
  if (e < 0.55) return "Measured"
  if (e < 0.75) return "Driven"
  return "Intense"
}

export function danceLabel(d: number): string {
  if (d < 0.40) return "Rhythmically restrained"
  if (d < 0.65) return "Moderately groovy"
  return "Highly danceable"
}

export function acousticLabel(a: number): string {
  if (a < 0.30) return "Produced"
  if (a < 0.60) return "Mixed"
  return "Acoustic"
}
```

---

## Color Palette

Dark, consistent with the iOS app's simiBackground (#0D0D0F approx):

```css
:root {
  --bg:      #0E0E12;
  --surface: #161620;
  --card:    #1C1C28;
  --border:  #2A2A38;
  --accent:  #8B5CF6;   /* simiAccent purple */
  --text:    #F0F0F6;
  --sub:     #8888A0;
}
```

---

## Page Designs

### Homepage (`/`)

```
nav: [simi wordmark]                    [App Store ↗]

HERO
────
"Find the emotional twin of any song."
Not what you've listened to. What the song feels like.
[Download on App Store]  [See an example →]

HOW IT WORKS (3 pills)
────────────────────────
🎵 Paste any Spotify URL
🧠 Simi reads the emotion
🎯 Match by feeling, not algorithm

FOOTER
──────
© 2026 Simi  ·  Privacy  ·  [App Store]
```

### Profile page (`/song/[spotifyId]`)

```
HEADER
──────
◀ simi                         [↗ Find songs like this]

SONG CARD
─────────
[Album art 80×80] Song Title
                  Artist
                  Genre · BPM bpm

EMOTIONAL FINGERPRINT
──────────────────────
Valence      ████████░░  0.78  Uplifting
Energy       ██████░░░░  0.61  Driven
Danceability ███░░░░░░░  0.38  Rhythmically restrained
Acousticness ██████████  0.91  Acoustic
Mode                          Major key

VIBE
────
"uplifting, driven, acoustic, major key"

SIMILAR TRACKS (up to 5)
────────────────────────
[SongCard] Title — Artist  (N% match)
[SongCard] …

FOOTER CTA
──────────
Find your own match →  [Download Simi]
```

---

## SEO Metadata

Per profile page:
- **`<title>`**: `"Song Title" by Artist — Emotional Profile | Simi`
- **`<meta description>`**: `The emotional fingerprint of Song Title by Artist: [vibe]. Discover songs that feel the same.`
- **Open Graph**: title, description, `og:image` pointing to album art URL
- **JSON-LD** (MusicRecording schema):
  ```json
  {
    "@context": "https://schema.org",
    "@type": "MusicRecording",
    "name": "Song Title",
    "byArtist": { "@type": "MusicGroup", "name": "Artist" }
  }
  ```
- **Canonical**: `https://simi.app/song/[spotifyId]`

---

## File Structure

```
web/
├── app/
│   ├── layout.tsx              — root layout (font, global styles, nav)
│   ├── globals.css             — Tailwind base + CSS variables
│   ├── page.tsx                — homepage
│   ├── song/
│   │   └── [spotifyId]/
│   │       └── page.tsx        — profile page (ISR, revalidate: 3600)
│   └── sitemap.ts              — dynamic sitemap from Supabase
├── lib/
│   ├── supabase.ts             — createClient() helper
│   └── vibe.ts                 — generateVibe(), *Label() helpers, AudioFeatures type
├── components/
│   ├── FingerprintBar.tsx      — single labeled progress bar
│   └── SimilarSongCard.tsx     — compact song card for similar tracks
├── public/
│   └── (static assets if needed)
├── next.config.ts
├── tailwind.config.ts
├── tsconfig.json
├── .env.local.example          — documents required env vars
└── package.json
```

---

## Environment Variables

```
NEXT_PUBLIC_SUPABASE_URL=https://xxx.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...
```

Same values as `SUPABASE_URL` / `SUPABASE_ANON_KEY` in the Railway backend.

---

## Vercel Deployment

No `vercel.json` needed — Vercel auto-detects Next.js from `package.json`. The site deploys from the `web/` directory using Vercel's root directory setting.

---

## Execution Scope

New directory `web/` only. No changes to:
- iOS app
- Backend (`main.py`, `similarity_engine.py`)
- Existing `landing/` directory
- Supabase schema

**Not in scope for this task:**
- App Store badge images / official artwork
- Blog or editorial pages
- Auth or user accounts
- Actual `simi.app` domain DNS setup (deployment to Vercel happens, domain points there separately)
