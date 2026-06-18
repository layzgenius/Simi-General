# Web + Emotional Profile Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Next.js site with a homepage and per-song emotional profile pages (`/song/[spotifyId]`) that pull from the Supabase `analyzed_songs` catalog — targeting AI search queries like "songs that feel like X."

**Architecture:** Next.js 14 App Router with TypeScript and Tailwind CSS in `web/`. Server components query Supabase directly. ISR (revalidate: 3600) for profile pages. A `lib/vibe.ts` module handles all rule-based descriptor generation.

**Tech Stack:** Next.js 14, TypeScript, Tailwind CSS 3, `@supabase/supabase-js`

## Global Constraints

- Project lives in `web/` inside the outer repo at `/Users/skips/Documents/Claude/Projects/Simi App/`
- Commits go to the outer repo (`git -C "/Users/skips/Documents/Claude/Projects/Simi App/"`)
- No changes to iOS app, backend, existing `landing/` directory, or Supabase schema
- Dark theme throughout — CSS variables: `--bg: #0E0E12`, `--surface: #161620`, `--card: #1C1C28`, `--border: #2A2A38`, `--accent: #8B5CF6`, `--text: #F0F0F6`, `--sub: #8888A0`
- Homepage hero copy exact: `"Find the emotional twin of any song."` / `"Not what you've listened to. What the song feels like."`
- Profile URL: `/song/[spotifyId]`
- Profile page ISR: `export const revalidate = 3600`
- Supabase table: `analyzed_songs` with columns `spotify_id`, `title`, `artist`, `embedding`, `features` (jsonb)
- Supabase RPC: `find_similar_tracks(query_embedding, match_count)` — returns similar rows
- `generateVibe()` must use exact thresholds from spec; vibe string is 3–4 terms joined by `", "`
- Build command: `cd web && npm run build` — must succeed with zero errors

---

### Task 1: Project scaffold + homepage

**Files:**
- Create: `web/package.json`
- Create: `web/next.config.ts`
- Create: `web/tailwind.config.ts`
- Create: `web/tsconfig.json`
- Create: `web/app/globals.css`
- Create: `web/app/layout.tsx`
- Create: `web/app/page.tsx`
- Create: `web/.env.local.example`

**Interfaces:**
- Produces: A Next.js app that builds (`npm run build` in `web/`) and renders the homepage at `/`

- [ ] **Step 1: Scaffold the project**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App" && \
  npx create-next-app@14 web \
    --typescript \
    --tailwind \
    --app \
    --no-src-dir \
    --import-alias "@/*" \
    --no-git \
    --no-eslint
  ```

  If `create-next-app` prompts interactively, use: `--yes` flag or answer all defaults.

- [ ] **Step 2: Add the Supabase client dependency**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App/web" && npm install @supabase/supabase-js
  ```

- [ ] **Step 3: Write `web/.env.local.example`**

  ```
  NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
  NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
  ```

- [ ] **Step 4: Write `web/app/globals.css`**

  Replace the generated globals.css entirely:

  ```css
  @tailwind base;
  @tailwind components;
  @tailwind utilities;

  :root {
    --bg:      #0E0E12;
    --surface: #161620;
    --card:    #1C1C28;
    --border:  #2A2A38;
    --accent:  #8B5CF6;
    --text:    #F0F0F6;
    --sub:     #8888A0;
  }

  body {
    background-color: var(--bg);
    color: var(--text);
    font-family: system-ui, -apple-system, sans-serif;
  }

  a { color: inherit; text-decoration: none; }
  ```

- [ ] **Step 5: Write `web/app/layout.tsx`**

  ```tsx
  import type { Metadata } from "next"
  import "./globals.css"

  export const metadata: Metadata = {
    title: "Simi — Find songs that feel the same",
    description: "Find the emotional twin of any song. Not what you've listened to — what the song feels like.",
    openGraph: {
      title: "Simi — Find songs that feel the same",
      description: "Find the emotional twin of any song.",
      type: "website",
    },
  }

  export default function RootLayout({ children }: { children: React.ReactNode }) {
    return (
      <html lang="en">
        <body>
          <nav style={{
            position: "fixed", top: 0, left: 0, right: 0, zIndex: 100,
            display: "flex", alignItems: "center", justifyContent: "space-between",
            padding: "20px 40px",
            background: "rgba(14,14,18,0.85)",
            backdropFilter: "blur(16px)",
            borderBottom: "1px solid var(--border)",
          }}>
            <a href="/" style={{ fontWeight: 700, fontSize: "1.25rem", color: "var(--text)" }}>
              simi
            </a>
            <a
              href="https://apps.apple.com/app/simi"
              target="_blank"
              rel="noopener noreferrer"
              style={{
                background: "var(--accent)",
                color: "#fff",
                padding: "8px 18px",
                borderRadius: 20,
                fontSize: "0.875rem",
                fontWeight: 600,
              }}
            >
              App Store ↗
            </a>
          </nav>
          <main style={{ paddingTop: 80 }}>{children}</main>
          <footer style={{
            textAlign: "center",
            padding: "40px 24px",
            color: "var(--sub)",
            fontSize: "0.875rem",
            borderTop: "1px solid var(--border)",
          }}>
            © 2026 Simi
          </footer>
        </body>
      </html>
    )
  }
  ```

- [ ] **Step 6: Write `web/app/page.tsx`**

  ```tsx
  export default function HomePage() {
    return (
      <div style={{ maxWidth: 720, margin: "0 auto", padding: "80px 24px 60px" }}>
        {/* Hero */}
        <section style={{ textAlign: "center", marginBottom: 80 }}>
          <p style={{
            display: "inline-block",
            background: "rgba(139,92,246,0.12)",
            color: "var(--accent)",
            padding: "6px 16px",
            borderRadius: 20,
            fontSize: "0.875rem",
            fontWeight: 500,
            marginBottom: 24,
          }}>
            Music Discovery, Redesigned
          </p>
          <h1 style={{
            fontSize: "clamp(2rem, 6vw, 3.25rem)",
            fontWeight: 800,
            lineHeight: 1.15,
            color: "var(--text)",
            marginBottom: 20,
          }}>
            Find the emotional twin<br />of any song.
          </h1>
          <p style={{
            fontSize: "1.125rem",
            color: "var(--sub)",
            lineHeight: 1.7,
            marginBottom: 36,
          }}>
            Not what you've listened to. What the song <em>feels</em> like.
          </p>
          <a
            href="https://apps.apple.com/app/simi"
            target="_blank"
            rel="noopener noreferrer"
            style={{
              display: "inline-block",
              background: "var(--accent)",
              color: "#fff",
              padding: "14px 32px",
              borderRadius: 28,
              fontSize: "1rem",
              fontWeight: 600,
              letterSpacing: "0.01em",
            }}
          >
            Download on App Store
          </a>
        </section>

        {/* How it works */}
        <section>
          <div style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))",
            gap: 16,
          }}>
            {[
              { emoji: "🎵", title: "Paste any Spotify URL", sub: "From a song you love" },
              { emoji: "🧠", title: "Simi reads the emotion", sub: "Valence, energy, groove, texture" },
              { emoji: "🎯", title: "Match by feeling", sub: "Not algorithm, not playlist" },
            ].map(({ emoji, title, sub }) => (
              <div key={title} style={{
                background: "var(--card)",
                border: "1px solid var(--border)",
                borderRadius: 16,
                padding: "20px 18px",
              }}>
                <div style={{ fontSize: "1.5rem", marginBottom: 10 }}>{emoji}</div>
                <div style={{ fontWeight: 600, color: "var(--text)", marginBottom: 4, fontSize: "0.9375rem" }}>{title}</div>
                <div style={{ color: "var(--sub)", fontSize: "0.875rem" }}>{sub}</div>
              </div>
            ))}
          </div>
        </section>
      </div>
    )
  }
  ```

- [ ] **Step 7: Build to verify no errors**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App/web" && npm run build
  ```
  Expected: `✓ Compiled successfully` and no TypeScript errors.

- [ ] **Step 8: Commit**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App" && \
  git add web/ && \
  git commit -m "feat(web): scaffold Next.js site with homepage"
  ```

---

### Task 2: Supabase integration + profile pages

**Files:**
- Create: `web/lib/supabase.ts`
- Create: `web/lib/vibe.ts`
- Create: `web/components/FingerprintBar.tsx`
- Create: `web/components/SimilarSongCard.tsx`
- Create: `web/app/song/[spotifyId]/page.tsx`

**Interfaces:**
- Consumes from Task 1: the Next.js app structure, Tailwind, CSS variables
- Consumes from Supabase: `analyzed_songs` table + `find_similar_tracks` RPC
- Produces:
  - `createClient()` — returns a Supabase browser client
  - `generateVibe(f: AudioFeatures): string`
  - `valenceLabel(v: number): string`, `energyLabel(e: number): string`, `danceLabel(d: number): string`, `acousticLabel(a: number): string`
  - `FingerprintBar` component
  - `SimilarSongCard` component
  - `/song/[spotifyId]` profile page with ISR

- [ ] **Step 1: Write `web/lib/supabase.ts`**

  ```typescript
  import { createClient as createSupabaseClient } from "@supabase/supabase-js"

  export function createClient() {
    return createSupabaseClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
    )
  }
  ```

- [ ] **Step 2: Write `web/lib/vibe.ts`**

  ```typescript
  export interface AudioFeatures {
    bpm: number
    energy: number
    valence: number
    danceability: number
    acousticness: number
    instrumentalness: number
    liveness: number
    loudness: number
    key: number
    mode: number
    isEstimated?: boolean
    isKeyEstimated?: boolean
    spectralWarmth?: number
    grooveRatio?: number
    [key: string]: unknown
  }

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

    // Texture modifiers (up to 2 more)
    if (f.acousticness > 0.60)     terms.push("acoustic")
    if (f.instrumentalness > 0.50) terms.push("instrumental")
    if (f.danceability > 0.72)     terms.push("groove-heavy")
    terms.push(f.mode === 0 ? "minor key" : "major key")

    return terms.slice(0, 4).join(", ")
  }

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

- [ ] **Step 3: Write `web/components/FingerprintBar.tsx`**

  ```tsx
  interface Props {
    label: string
    value: number        // 0–1
    descriptor: string
    color?: string
  }

  export default function FingerprintBar({ label, value, descriptor, color = "#8B5CF6" }: Props) {
    const pct = Math.round(value * 100)
    return (
      <div style={{ marginBottom: 14 }}>
        <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 6, fontSize: "0.875rem" }}>
          <span style={{ color: "var(--sub)", fontWeight: 500 }}>{label}</span>
          <span style={{ color: "var(--sub)" }}>{descriptor}</span>
        </div>
        <div style={{
          height: 6,
          background: "var(--border)",
          borderRadius: 3,
          overflow: "hidden",
        }}>
          <div style={{
            height: "100%",
            width: `${pct}%`,
            background: color,
            borderRadius: 3,
            transition: "width 0.3s ease",
          }} />
        </div>
      </div>
    )
  }
  ```

- [ ] **Step 4: Write `web/components/SimilarSongCard.tsx`**

  ```tsx
  interface Props {
    spotifyId: string
    title: string
    artist: string
    similarity?: number    // 0–1, optional
  }

  export default function SimilarSongCard({ spotifyId, title, artist, similarity }: Props) {
    return (
      <a
        href={`/song/${spotifyId}`}
        style={{
          display: "flex",
          alignItems: "center",
          gap: 14,
          padding: "14px 16px",
          background: "var(--card)",
          border: "1px solid var(--border)",
          borderRadius: 12,
          textDecoration: "none",
          transition: "border-color 0.15s",
        }}
      >
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{
            fontWeight: 600,
            color: "var(--text)",
            fontSize: "0.9375rem",
            whiteSpace: "nowrap",
            overflow: "hidden",
            textOverflow: "ellipsis",
          }}>{title}</div>
          <div style={{ color: "var(--sub)", fontSize: "0.875rem" }}>{artist}</div>
        </div>
        {similarity !== undefined && (
          <div style={{
            flexShrink: 0,
            background: "rgba(139,92,246,0.12)",
            color: "var(--accent)",
            borderRadius: 20,
            padding: "4px 10px",
            fontSize: "0.8125rem",
            fontWeight: 500,
          }}>
            {Math.round(similarity * 100)}%
          </div>
        )}
      </a>
    )
  }
  ```

- [ ] **Step 5: Write `web/app/song/[spotifyId]/page.tsx`**

  ```tsx
  import { notFound } from "next/navigation"
  import type { Metadata } from "next"
  import { createClient } from "@/lib/supabase"
  import { generateVibe, valenceLabel, energyLabel, danceLabel, acousticLabel, type AudioFeatures } from "@/lib/vibe"
  import FingerprintBar from "@/components/FingerprintBar"
  import SimilarSongCard from "@/components/SimilarSongCard"

  export const revalidate = 3600

  interface PageProps {
    params: Promise<{ spotifyId: string }>
  }

  export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
    const { spotifyId } = await params
    const supabase = createClient()
    const { data } = await supabase
      .from("analyzed_songs")
      .select("title, artist, features")
      .eq("spotify_id", spotifyId)
      .single()

    if (!data) return { title: "Song not found | Simi" }

    const f = data.features as AudioFeatures
    const vibe = generateVibe(f)

    return {
      title: `"${data.title}" by ${data.artist} — Emotional Profile | Simi`,
      description: `The emotional fingerprint of ${data.title} by ${data.artist}: ${vibe}. Discover songs that feel the same.`,
      openGraph: {
        title: `"${data.title}" — Emotional Profile | Simi`,
        description: `${vibe}. Find songs that feel like ${data.title}.`,
      },
    }
  }

  export default async function SongProfilePage({ params }: PageProps) {
    const { spotifyId } = await params
    const supabase = createClient()

    // Fetch the song
    const { data: song } = await supabase
      .from("analyzed_songs")
      .select("spotify_id, title, artist, embedding, features")
      .eq("spotify_id", spotifyId)
      .single()

    if (!song) notFound()

    const f = song.features as AudioFeatures
    const vibe = generateVibe(f)

    // Find similar tracks via RPC
    const embeddingStr = Array.isArray(song.embedding)
      ? JSON.stringify(song.embedding)
      : song.embedding

    const { data: similar = [] } = await supabase.rpc("find_similar_tracks", {
      query_embedding: embeddingStr,
      match_count: 6,
    })

    // Exclude the song itself, take top 5
    const similarSongs = (similar ?? [])
      .filter((s: { spotify_id: string }) => s.spotify_id !== spotifyId)
      .slice(0, 5)

    const jsonLd = {
      "@context": "https://schema.org",
      "@type": "MusicRecording",
      name: song.title,
      byArtist: { "@type": "MusicGroup", name: song.artist },
    }

    return (
      <div style={{ maxWidth: 640, margin: "0 auto", padding: "40px 24px 80px" }}>
        {/* JSON-LD */}
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />

        {/* Song header */}
        <div style={{
          background: "var(--card)",
          border: "1px solid var(--border)",
          borderRadius: 16,
          padding: 20,
          marginBottom: 28,
          display: "flex",
          alignItems: "center",
          gap: 16,
        }}>
          <div style={{ flex: 1 }}>
            <div style={{ fontWeight: 700, fontSize: "1.25rem", color: "var(--text)", marginBottom: 4 }}>
              {song.title}
            </div>
            <div style={{ color: "var(--sub)", fontSize: "0.9375rem" }}>{song.artist}</div>
            <div style={{ color: "var(--sub)", fontSize: "0.8125rem", marginTop: 6 }}>
              {Math.round(f.bpm)} BPM · {f.mode === 0 ? "Minor" : "Major"} key
            </div>
          </div>
          <a
            href={`https://open.spotify.com/track/${spotifyId}`}
            target="_blank"
            rel="noopener noreferrer"
            style={{
              flexShrink: 0,
              background: "#1DB954",
              color: "#fff",
              borderRadius: 20,
              padding: "8px 16px",
              fontSize: "0.8125rem",
              fontWeight: 600,
            }}
          >
            ↗ Spotify
          </a>
        </div>

        {/* Emotional fingerprint */}
        <section style={{ marginBottom: 28 }}>
          <h2 style={{ fontSize: "0.75rem", fontWeight: 600, color: "var(--sub)", letterSpacing: "0.08em", textTransform: "uppercase", marginBottom: 16 }}>
            Emotional Fingerprint
          </h2>
          <div style={{
            background: "var(--card)",
            border: "1px solid var(--border)",
            borderRadius: 16,
            padding: 20,
          }}>
            <FingerprintBar label="Valence"      value={f.valence}      descriptor={valenceLabel(f.valence)} />
            <FingerprintBar label="Energy"       value={f.energy}       descriptor={energyLabel(f.energy)} />
            <FingerprintBar label="Danceability" value={f.danceability} descriptor={danceLabel(f.danceability)} />
            <FingerprintBar label="Acousticness" value={f.acousticness} descriptor={acousticLabel(f.acousticness)} color="#06B6D4" />
          </div>
        </section>

        {/* Vibe */}
        <section style={{ marginBottom: 28 }}>
          <h2 style={{ fontSize: "0.75rem", fontWeight: 600, color: "var(--sub)", letterSpacing: "0.08em", textTransform: "uppercase", marginBottom: 12 }}>
            Vibe
          </h2>
          <p style={{
            background: "var(--card)",
            border: "1px solid var(--border)",
            borderRadius: 12,
            padding: "14px 18px",
            color: "var(--text)",
            fontStyle: "italic",
            fontSize: "1rem",
          }}>
            "{vibe}"
          </p>
        </section>

        {/* Similar tracks */}
        {similarSongs.length > 0 && (
          <section style={{ marginBottom: 40 }}>
            <h2 style={{ fontSize: "0.75rem", fontWeight: 600, color: "var(--sub)", letterSpacing: "0.08em", textTransform: "uppercase", marginBottom: 12 }}>
              Songs with the Same Emotional Imprint
            </h2>
            <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              {similarSongs.map((s: { spotify_id: string; title: string; artist: string; similarity?: number }) => (
                <SimilarSongCard
                  key={s.spotify_id}
                  spotifyId={s.spotify_id}
                  title={s.title}
                  artist={s.artist}
                  similarity={s.similarity}
                />
              ))}
            </div>
          </section>
        )}

        {/* CTA */}
        <div style={{
          background: "rgba(139,92,246,0.08)",
          border: "1px solid rgba(139,92,246,0.25)",
          borderRadius: 16,
          padding: "24px 20px",
          textAlign: "center",
        }}>
          <p style={{ color: "var(--text)", fontWeight: 600, marginBottom: 4 }}>Find your own match</p>
          <p style={{ color: "var(--sub)", fontSize: "0.875rem", marginBottom: 16 }}>
            Paste any Spotify URL — Simi finds the emotional twin.
          </p>
          <a
            href="https://apps.apple.com/app/simi"
            target="_blank"
            rel="noopener noreferrer"
            style={{
              display: "inline-block",
              background: "var(--accent)",
              color: "#fff",
              padding: "12px 28px",
              borderRadius: 24,
              fontWeight: 600,
              fontSize: "0.9375rem",
            }}
          >
            Download Simi ↗
          </a>
        </div>
      </div>
    )
  }
  ```

- [ ] **Step 6: Build to verify**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App/web" && npm run build
  ```
  Expected: Build succeeds. The profile page will show `notFound()` at runtime when Supabase returns no data (expected without real credentials).

- [ ] **Step 7: Commit**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App" && \
  git add web/ && \
  git commit -m "feat(web): add Supabase integration, vibe generator, and song profile pages"
  ```

---

### Task 3: Sitemap + not-found page + final polish

**Files:**
- Create: `web/app/sitemap.ts`
- Create: `web/app/not-found.tsx`
- Modify: `web/next.config.ts` — add image domain config for Supabase

**Interfaces:**
- Consumes from Task 1 + 2: the working Next.js app
- Produces:
  - Auto-generated sitemap at `/sitemap.xml` listing all profile pages from `analyzed_songs`
  - Custom 404 page when a Spotify ID isn't in the catalog
  - `next.config.ts` with image domains configured

- [ ] **Step 1: Write `web/app/sitemap.ts`**

  ```typescript
  import { MetadataRoute } from "next"
  import { createClient } from "@/lib/supabase"

  export const revalidate = 3600

  export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
    const supabase = createClient()

    const { data: songs = [] } = await supabase
      .from("analyzed_songs")
      .select("spotify_id")
      .limit(5000)

    const songUrls: MetadataRoute.Sitemap = (songs ?? []).map((s: { spotify_id: string }) => ({
      url: `https://simi.app/song/${s.spotify_id}`,
      lastModified: new Date(),
      changeFrequency: "weekly" as const,
      priority: 0.8,
    }))

    return [
      {
        url: "https://simi.app",
        lastModified: new Date(),
        changeFrequency: "monthly" as const,
        priority: 1.0,
      },
      ...songUrls,
    ]
  }
  ```

- [ ] **Step 2: Write `web/app/not-found.tsx`**

  ```tsx
  import Link from "next/link"

  export default function NotFound() {
    return (
      <div style={{
        maxWidth: 480,
        margin: "80px auto",
        padding: "0 24px",
        textAlign: "center",
      }}>
        <div style={{ fontSize: "3rem", marginBottom: 16 }}>🎵</div>
        <h1 style={{ fontSize: "1.5rem", fontWeight: 700, color: "var(--text)", marginBottom: 8 }}>
          Song not found
        </h1>
        <p style={{ color: "var(--sub)", marginBottom: 28 }}>
          This song hasn't been analyzed yet. Paste its Spotify URL in the Simi app to build its emotional profile.
        </p>
        <Link
          href="/"
          style={{
            display: "inline-block",
            background: "var(--accent)",
            color: "#fff",
            padding: "12px 28px",
            borderRadius: 24,
            fontWeight: 600,
            textDecoration: "none",
          }}
        >
          Back to Simi
        </Link>
      </div>
    )
  }
  ```

- [ ] **Step 3: Update `web/next.config.ts` to allow external images**

  Replace the default config with:

  ```typescript
  import type { NextConfig } from "next"

  const nextConfig: NextConfig = {
    images: {
      remotePatterns: [
        { protocol: "https", hostname: "i.scdn.co" },         // Spotify album art CDN
        { protocol: "https", hostname: "mosaic.scdn.co" },
        { protocol: "https", hostname: "*.supabase.co" },
      ],
    },
  }

  export default nextConfig
  ```

- [ ] **Step 4: Build to verify**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App/web" && npm run build
  ```
  Expected: `✓ Compiled successfully` — no TypeScript or build errors.

- [ ] **Step 5: Commit**

  ```bash
  cd "/Users/skips/Documents/Claude/Projects/Simi App" && \
  git add web/ && \
  git commit -m "feat(web): add sitemap, 404 page, and image domain config"
  ```
