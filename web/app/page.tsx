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
          Not what you&apos;ve listened to. What the song <em>feels</em> like.
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
