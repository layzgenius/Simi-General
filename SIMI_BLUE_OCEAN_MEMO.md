# MEMO: Simi Blue Ocean — What Spotify Can't Do & What We Build Next

**To:** Claude Code  
**From:** Strategic Research (June 17, 2026)  
**Re:** Confirmed Spotify gaps → Simi feature roadmap  
**Context:** Simi is an iOS SwiftUI music discovery app using librosa-based emotional imprint matching. Backend on Railway. Catalog via ListenBrainz + Supabase pgvector. This memo maps research-confirmed Spotify weaknesses to specific build tasks.

---

## Why This Matters

Spotify has 675M+ users and a $90B+ market cap. We are not trying to beat them at streaming. We are targeting the exact moments their system fails — and research confirms those moments are real, widespread, and growing.

A 2025 academic study confirmed that Spotify's algorithm increases "taste tautology" — users converge on narrower listening over time, not broader. 61% of users reported major dissatisfaction in a 2026 survey. The EU's Digital Services Act (2024) now legally requires explainability of recommendation algorithms. The window for a transparent, emotionally-intelligent discovery tool is open.

---

## The Eight Confirmed Gaps

### 1. History-Trapped Recommendations
**What research says:** Spotify's collaborative filtering cannot function without listening history. The "cold start problem" is a documented research challenge (ACM SIGKDD 2021, multiple follow-ups). Without sufficient data on a user, the algorithm defaults to popularity.

**Simi's counter:** One song. No account. No history. Immediate, high-quality results. This is architecturally impossible for Spotify to replicate without abandoning their core personalization model.

---

### 2. Filter Bubbles & Taste Homogenization
**What research says:** Academic research (Nature Scientific Reports 2024, ResearchGate 2025) confirms Spotify's algorithm "reinforces prior preferences and leads to filter bubbles with obvious cultural implications." The algorithm optimizes for stream count / retention, not discovery breadth. Users' taste **narrows** over time, not expands.

**Simi's counter:** We match the song, not the user. We have no bubble to reinforce. A classical listener who pastes Beethoven gets results Spotify would never surface. A hip-hop listener gets Jazz if the emotional fingerprint matches.

---

### 3. Genre-Locked Discovery
**What research says:** Collaborative filtering clusters users by genre behavioral patterns. Cross-genre bridges require audio-level emotional analysis — exactly what Spotify's user-behavior model cannot do structurally. Emerging research (GlobalMood benchmark, arxiv 2025) confirms cross-cultural and cross-genre emotional matching is an unsolved frontier in mainstream streaming.

**Simi's counter:** Our valence v4 + spectralWarmth + tonalClarity model doesn't know what genre a song belongs to — it only knows what it feels like. This dissolves genre boundaries by design.

---

### 4. Mood-Deaf / Moment-Blind
**What research says:** "Streaming platforms primarily rely on historical behavior rather than current emotional states." (MDPI 2025 mood-based discovery study). Spotify's AI Playlist accepts text but uses it as a vibe filter on their catalog, not as emotional fingerprint matching. Mood playlists are pre-curated, not dynamically matched.

**Simi's counter:** The song you paste IS the emotional state. You don't describe how you feel — you show us. That's the UX breakthrough Spotify hasn't cracked.

---

### 5. Opaque Recommendations (No Explainability)
**What research says:** "Music professionals rely on recommender systems while often lacking a clear vision of how these systems operate." (Music Tomorrow 2025 Fairness & Transparency review). The EU DSA (in force 2024) now requires Spotify to disclose "main parameters" that determine recommendations — regulatory pressure for a feature Spotify has never shipped.

**Simi's counter:** We can show exactly why a song matches. Valence distance, spectral warmth alignment, mode match, danceability delta — all computable, all explainable. This is a differentiator that also serves regulatory tailwinds.

---

### 6. Popularity Bias Against Obscure & Indie Tracks
**What research says:** Spotify's Discovery Mode is documented pay-to-play (royalty reduction in exchange for algorithmic promotion). The pro-rata royalty model creates feedback loops that amplify already-popular tracks. "The algorithm prioritizes familiarity" (Wiener Squad Media 2025). Indie artists are systematically disadvantaged.

**Simi's counter:** We score by emotional match, not by play count. A 2003 obscure Brazilian lo-fi track with a perfect emotional match surfaces exactly as high as a Billie Eilish record. This is also a compelling story for artists and for press.

---

### 7. Professional/Sync Licensing Has No Consumer-Grade Tool
**What research says:** 65% of music supervisors expected to use AI for music discovery by 2026. Current tools (Cyanite.ai, Harmix) are B2B/enterprise-priced and catalog-specific. Incomplete metadata causes 25-30% of missed sync opportunities. There is a 35% increase in sync placements for digital-first content 2024–2026 — a growing market with no accessible tool.

**Simi's counter:** We already do song-to-song emotional matching. Adding a "Professional" context (export, batch seeds, licensable-track flags) captures an underserved market that pays for tools and has a real workflow problem.

---

### 8. No Sharable Discovery Moment
**What research says:** Viral music discovery is social. Spotify's shareable outputs are playlist links and Wrapped. Neither communicates *why* a discovery was surprising or meaningful.

**Simi's counter:** "A 1974 Caetano Veloso track has the same emotional fingerprint as your favorite Kendrick Lamar song" is a story. It's shareable. It creates "aha" moments Spotify can't manufacture because they don't know the emotional connection — only the behavioral correlation.

---

## Build Tasks for Claude Code

These are ordered by impact. Each task maps to a confirmed Spotify gap.

---

### TASK 1 — "Why This Matches" Explainability Card
**Gap addressed:** Gap 5 (opaque recommendations)  
**What to build:** After each recommendation loads, show an expandable card beneath the song row displaying the emotional match breakdown. Use the already-computed similarity scores.

```
Display:
- Emotional match: [X]% overall
- Valence alignment: [descriptor] (e.g. "Same melancholic weight")
- Groove feel: [descriptor] (e.g. "Equally restrained")
- Sonic texture: [descriptor] (e.g. "Similar warmth")
- Mode: "Both minor key" or "Both major key"
- Genre bridge: [if genres differ, surface this — "Classical → Hip-Hop"]
```

Use the existing `computeSimilarity` output — these scores are already there. This is mostly a SwiftUI UI task with simple label logic.

**Files to touch:** `RecommendationEngine.swift`, new `MatchExplanationView.swift`

---

### TASK 2 — Genre Bridge Badge
**Gap addressed:** Gap 3 (genre-locked discovery), Gap 8 (sharable moments)  
**What to build:** When a recommended song's primary genre tag differs significantly from the seed song's genre tags, surface a "Genre Bridge" badge on the song row.

```
Logic: 
- Compare primary genre tag of seed vs. recommendation
- If they differ by ≥ 1 major genre category (e.g., "classical" vs "hip-hop"), show badge
- Badge text: "Genre Bridge 🌉" or just "Cross-genre match"
```

This makes the invisible visible — our biggest technical strength becomes the most obvious thing a user sees.

**Files to touch:** `SongRowView.swift`, `Song.swift` (add `genreBridgeLabel` computed property)

---

### TASK 3 — Emotional Profile Share Card
**Gap addressed:** Gap 8 (no sharable discovery moment), Gap 5 (explainability)  
**What to build:** A shareable image card (UIImage/SwiftUI → rendered image) a user can send to Messages/Instagram. Shows:

```
Layout:
- Simi wordmark
- "Emotional match found:"
- Seed song → Matched song (with album art both)
- 1-line reason: "Same melancholic weight, minor key, restrained groove"
- "Discovered on Simi"
```

Use SwiftUI's `ImageRenderer` to generate a PNG. This is the social growth vector — every share is a Simi advertisement with context.

**Files to touch:** New `ShareCardView.swift`, `ShareCardGenerator.swift`

---

### TASK 4 — Discovery Breadth Control ("Expand My World" slider)
**Gap addressed:** Gap 2 (filter bubbles), Gap 6 (popularity bias)  
**What to build:** A horizontal control in the search view with two modes:

```
[Close Match] ←——●——→ [Surprise Me]
```

- **Close Match:** Similarity threshold ≥ 0.85, surface highest-scoring results
- **Surprise Me:** Similarity threshold 0.65–0.85, inject randomness into candidate selection, specifically deprioritize tracks with >50M streams (surface obscure finds)

This directly counters Spotify's familiarity bias and gives users agency over their own discovery bubble.

**Files to touch:** `SearchView.swift`, `RecommendationEngine.swift` (add `discoveryMode` parameter to similarity scoring)

---

### TASK 5 — Zero-History Cold Start Onboarding Optimization
**Gap addressed:** Gap 1 (history-trapped)  
**What to build:** The first-launch experience should be a single, confident action with no preamble. Audit current onboarding flow and ensure:

```
- No "rate these songs" or taste quiz step
- No account creation required to get results
- First screen = paste or search a song, period
- Immediate results with no "loading your profile" language
- Onboarding copy: "Paste any song. We'll find its emotional kin."
```

If there's any language implying the app "learns" from you over time, remove it — that's Spotify's story, not ours.

**Files to touch:** `OnboardingView.swift` (or equivalent), `WelcomeView.swift`

---

### TASK 6 — "This Is a Cross-Genre Find" Empty State
**Gap addressed:** Gap 3 (genre-locked), Gap 8 (shareable moments)  
**What to build:** When the top results include ≥ 2 songs from a different genre than the seed, show a subtle banner at the top of results:

```
"We crossed genre lines to find these. Same feeling, different world."
```

Small copy moment that signals intentionality and differentiates from Spotify's genre-cluster recommendations.

**Files to touch:** `ResultsView.swift`

---

### TASK 7 — Professional / Export Mode (Sync Licensing MVP)
**Gap addressed:** Gap 7 (professional/sync gap)  
**What to build:** A "Pro" tab or share sheet option that exports search results as structured data for music supervisors and creators:

```
Export format (CSV or shareable link):
- Song title, Artist, Year
- Emotional match %
- Valence, Energy, Danceability scores
- BPM
- Genre tags
- Apple Music / Spotify link
```

Also: allow multiple seed songs in a session ("batch discovery") — supervisor can paste 3 reference tracks and get a unified pool of emotional matches.

**Files to touch:** New `ProExportService.swift`, `ProModeView.swift`, `SearchViewModel.swift` (support multiple seeds)

---

### TASK 8 — Web Landing Page with Emotional Profile Pages (AI SEO)
**Gap addressed:** Gap 5 explainability, AI SEO / blue ocean positioning  
**What to build:** A public-facing web presence (NextJS or simple static site) with:

**Page 1 — Homepage:**
```
Hero: "Find the emotional twin of any song."
Sub: "Not what you've listened to. What the song feels like."
CTA: [Download on App Store]
```

**Page 2 — Emotional Profile pages (dynamic, SEO-critical):**
For well-known songs, generate pages like `/song/bohemian-rhapsody` that show:
```
- Song name, artist
- Emotional fingerprint (valence, energy, danceability, mode, BPM)
- Vibe summary (e.g., "Theatrical, dynamic, emotionally complex")
- "Songs with the same emotional imprint" → 5 examples
```

These pages own AI search queries like "what songs feel like Bohemian Rhapsody" — currently uncontested space that no authoritative source fills.

**Stack:** NextJS or Astro, deployed on Vercel. Pull data from existing Railway API + Supabase catalog.

---

### TASK 9 — Explainability API Endpoint
**Gap addressed:** Gaps 5 + 7  
**What to build:** Add a `/explain` endpoint to the Railway backend:

```
POST /explain
Body: { seed_url: "...", match_url: "..." }
Response: {
  overall_score: 0.87,
  valence_delta: 0.04,
  valence_description: "Nearly identical emotional weight",
  energy_delta: 0.11,
  energy_description: "Slightly more driving",
  mode_match: true,
  mode_description: "Both minor key",
  genre_bridge: true,
  genre_bridge_label: "Soul → Electronic",
  summary: "Same melancholic groove, different sonic world"
}
```

This powers both the in-app explanation card (Task 1) and eventually a public developer API that music apps, sync platforms, and tools can integrate.

**Files to touch:** `main.py` (Railway), new `explain_endpoint.py`

---

## Priority Order Summary

| Priority | Task | Gap | Effort |
|----------|------|-----|--------|
| 🔴 P0 | Task 1 — Match Explanation Card | Explainability | Low (scores exist) |
| 🔴 P0 | Task 2 — Genre Bridge Badge | Cross-genre | Low (tag comparison) |
| 🔴 P0 | Task 5 — Cold Start Onboarding | Zero-history | Low (copy + UX) |
| 🟡 P1 | Task 3 — Share Card | Social growth | Medium |
| 🟡 P1 | Task 4 — Discovery Breadth Slider | Anti-bubble | Medium |
| 🟡 P1 | Task 6 — Cross-Genre Banner | Cross-genre UX | Low |
| 🟠 P2 | Task 7 — Pro/Export Mode | Sync licensing | High |
| 🟠 P2 | Task 8 — Web + Emotional Profile Pages | AI SEO | High |
| 🟠 P2 | Task 9 — Explain API Endpoint | B2B/API | Medium |

---

## The One-Sentence Positioning to Keep in Mind

**"Simi finds music by how it feels, not who you are."**

Every task above makes this more visible, more shareable, or more useful to a new audience. Spotify cannot replicate this without dismantling their personalization flywheel. That's the moat.

---

*Research sourced from: MIT Technology Review (2024), ResearchGate Spotify taste study (2025), Ohio University streaming algorithms study (2026), Music Tomorrow fairness review (2025), MDPI mood-based discovery (2025), ACM SIGKDD cold-start research, Nature Scientific Reports filter bubble study (2024), Headphonesty/Music Tomorrow algorithm analysis (2026).*
