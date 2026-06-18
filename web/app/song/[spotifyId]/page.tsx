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
          &ldquo;{vibe}&rdquo;
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
