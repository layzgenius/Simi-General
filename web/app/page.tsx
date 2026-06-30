export default function HomePage() {
  return (
    <>
      {/* ── Hero ── */}
      <section style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        textAlign: "center",
        padding: "120px 24px 100px",
        maxWidth: 800,
        margin: "0 auto",
      }}>
        <div style={{
          display: "inline-flex",
          alignItems: "center",
          gap: 8,
          fontSize: 13,
          fontWeight: 600,
          color: "var(--accent)",
          background: "rgba(56,192,250,0.1)",
          border: "1px solid rgba(56,192,250,0.25)",
          padding: "6px 16px",
          borderRadius: 100,
          marginBottom: 32,
          letterSpacing: "0.04em",
          textTransform: "uppercase",
        }}>
          <span style={{ width: 6, height: 6, background: "var(--accent)", borderRadius: "50%", display: "inline-block" }} />
          Music Discovery, Reimagined
        </div>

        <h1 style={{
          fontSize: "clamp(42px, 8vw, 80px)",
          fontWeight: 900,
          lineHeight: 1.05,
          letterSpacing: "-2px",
          marginBottom: 24,
        }}>
          Find songs that{" "}
          <br />
          <span style={{
            background: "linear-gradient(135deg, var(--primary) 30%, var(--accent))",
            WebkitBackgroundClip: "text",
            WebkitTextFillColor: "transparent",
            backgroundClip: "text",
          }}>
            feel like yours
          </span>
        </h1>

        <p style={{
          fontSize: "clamp(17px, 2.5vw, 21px)",
          color: "var(--sub)",
          maxWidth: 560,
          marginBottom: 48,
          lineHeight: 1.65,
        }}>
          Simi isn&apos;t looking for similar songs.
          <br />
          It&apos;s looking for the same{" "}
          <strong style={{ color: "var(--text)", fontWeight: 600 }}>emotional imprint</strong>
          {" "}— the feeling that makes a song yours.
        </p>

        <div style={{ display: "flex", gap: 16, flexWrap: "wrap", justifyContent: "center" }}>
          <a href="#how" style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 8,
            background: "var(--primary)",
            color: "#fff",
            fontSize: 16,
            fontWeight: 700,
            padding: "16px 32px",
            borderRadius: 14,
            boxShadow: "0 0 40px rgba(124,93,250,0.4)",
            transition: "transform 0.15s, box-shadow 0.15s",
          }}>
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
              <circle cx="8" cy="8" r="7" stroke="white" strokeWidth="1.5" />
              <path d="M6 5.5L11 8L6 10.5V5.5Z" fill="white" />
            </svg>
            See how it works
          </a>
          <a href="#about" style={{
            display: "inline-flex",
            alignItems: "center",
            background: "transparent",
            color: "var(--sub)",
            fontSize: 16,
            fontWeight: 600,
            padding: "16px 28px",
            borderRadius: 14,
            border: "1px solid var(--border)",
          }}>
            About Simi
          </a>
        </div>

        {/* App mockup */}
        <div style={{ position: "relative", margin: "80px auto 0", maxWidth: 340, width: "100%" }}>
          <div style={{
            background: "var(--card)",
            border: "1px solid var(--border)",
            borderRadius: 32,
            padding: "28px 24px",
            boxShadow: "0 40px 120px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.04)",
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 20 }}>
              <div style={{
                flex: 1,
                background: "var(--surface)",
                border: "1px solid var(--border)",
                borderRadius: 12,
                padding: "10px 14px",
                fontSize: 13,
                color: "var(--sub)",
                fontFamily: "inherit",
              }}>
                open.spotify.com/track/…
              </div>
              <div style={{
                background: "var(--primary)",
                color: "#fff",
                borderRadius: 10,
                padding: "10px 14px",
                fontSize: 13,
                fontWeight: 700,
              }}>
                Go
              </div>
            </div>

            {[
              { gradient: "135deg,#2d1b69,#7c5dfa", title: "Nights", artist: "Frank Ocean", score: "97%" },
              { gradient: "135deg,#0d3349,#38c0fa", title: "Slide", artist: "Calvin Harris", score: "91%" },
              { gradient: "135deg,#2a1a3e,#9b6dfa", title: "Location", artist: "Khalid", score: "88%" },
            ].map(({ gradient, title, artist, score }) => (
              <div key={title} style={{
                display: "flex",
                alignItems: "center",
                gap: 12,
                padding: 12,
                background: "var(--surface)",
                borderRadius: 14,
                marginBottom: 10,
                border: "1px solid var(--border)",
              }}>
                <div style={{
                  width: 42, height: 42,
                  borderRadius: 8,
                  flexShrink: 0,
                  background: `linear-gradient(${gradient})`,
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  fontSize: 20,
                }}>🎵</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 13, fontWeight: 600, color: "var(--text)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{title}</div>
                  <div style={{ fontSize: 11, color: "var(--sub)" }}>{artist}</div>
                </div>
                <div style={{ fontSize: 12, fontWeight: 700, color: "var(--green)", flexShrink: 0 }}>{score}</div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── How it works ── */}
      <section id="how" style={{ maxWidth: 960, margin: "0 auto", padding: "100px 24px" }}>
        <div style={{ fontSize: 12, fontWeight: 700, letterSpacing: "0.12em", textTransform: "uppercase", color: "var(--primary)", marginBottom: 16 }}>
          How it works
        </div>
        <div style={{ fontSize: "clamp(28px, 4vw, 42px)", fontWeight: 900, letterSpacing: "-1px", lineHeight: 1.1, marginBottom: 60 }}>
          Three steps to<br />your next favourite song
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(240px, 1fr))", gap: 24 }}>
          {[
            { num: "Step 01", icon: "🔗", title: "Paste a song", body: "Drop in a Spotify, Apple Music, or YouTube link — or just search by name. Up to five songs at once for blended recommendations." },
            { num: "Step 02", icon: "🧬", title: "Simi reads the feel", body: "We analyse valence, energy, danceability, tonal texture, and tempo to build an emotional fingerprint of your song." },
            { num: "Step 03", icon: "✨", title: "Discover what fits", body: "Ranked results across genres and eras — music that shares your song's emotional DNA, not just its genre or tempo." },
          ].map(({ num, icon, title, body }) => (
            <div key={title} style={{
              background: "var(--card)",
              border: "1px solid var(--border)",
              borderRadius: 20,
              padding: "32px 28px",
              position: "relative",
              overflow: "hidden",
            }}>
              <div style={{ fontSize: 11, fontWeight: 700, letterSpacing: "0.1em", color: "var(--primary)", textTransform: "uppercase", marginBottom: 16 }}>{num}</div>
              <div style={{ fontSize: 32, marginBottom: 16, display: "block" }}>{icon}</div>
              <h3 style={{ fontSize: 18, fontWeight: 700, marginBottom: 10, letterSpacing: "-0.3px" }}>{title}</h3>
              <p style={{ fontSize: 14, color: "var(--sub)", lineHeight: 1.65 }}>{body}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ── Philosophy ── */}
      <div id="about" style={{ background: "var(--card)", borderTop: "1px solid var(--border)", borderBottom: "1px solid var(--border)" }}>
        <div style={{ maxWidth: 720, margin: "0 auto", padding: "100px 24px", textAlign: "center" }}>
          <div style={{ fontSize: 12, fontWeight: 700, letterSpacing: "0.12em", textTransform: "uppercase", color: "var(--primary)", marginBottom: 16 }}>
            Our philosophy
          </div>
          <blockquote style={{ fontSize: "clamp(22px, 3.5vw, 34px)", fontWeight: 700, lineHeight: 1.35, letterSpacing: "-0.5px", color: "var(--text)", marginBottom: 24 }}>
            &ldquo;Not a streaming app.
            <br />
            A{" "}
            <span style={{
              background: "linear-gradient(135deg, var(--primary), var(--accent))",
              WebkitBackgroundClip: "text",
              WebkitTextFillColor: "transparent",
              backgroundClip: "text",
            }}>
              discovery tool
            </span>
            .&rdquo;
          </blockquote>
          <p style={{ fontSize: 16, color: "var(--sub)", maxWidth: 480, margin: "0 auto" }}>
            You&apos;re not searching for songs that sound the same.
            You&apos;re searching for songs that <em>feel</em> the same —
            the emotional weight, the texture, the mood at 2am or in the car on a long drive.
            That&apos;s what Simi finds.
          </p>
        </div>
      </div>

      {/* ── Features ── */}
      <section style={{ maxWidth: 960, margin: "0 auto", padding: "100px 24px" }}>
        <div style={{ fontSize: 12, fontWeight: 700, letterSpacing: "0.12em", textTransform: "uppercase", color: "var(--primary)", marginBottom: 16 }}>
          Features
        </div>
        <div style={{ fontSize: "clamp(28px, 4vw, 42px)", fontWeight: 900, letterSpacing: "-1px", lineHeight: 1.1, marginBottom: 60 }}>
          Built different
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: 16 }}>
          {[
            { icon: "🎨", title: "Emotional matching", body: "Valence, energy, and tonal warmth — not just genre tags." },
            { icon: "🔀", title: "Multi-seed blending", body: "Paste up to 5 songs and find their shared emotional centre." },
            { icon: "🌍", title: "Cross-era results", body: "Recommendations span decades — from Motown to this year's bedroom pop." },
            { icon: "🔒", title: "Privacy-first", body: "No account required. No listening history stored. Just discovery." },
          ].map(({ icon, title, body }) => (
            <div key={title} style={{
              background: "var(--surface)",
              border: "1px solid var(--border)",
              borderRadius: 16,
              padding: "24px 20px",
            }}>
              <div style={{ fontSize: 24, marginBottom: 12, display: "block" }}>{icon}</div>
              <h4 style={{ fontSize: 15, fontWeight: 700, marginBottom: 6 }}>{title}</h4>
              <p style={{ fontSize: 13, color: "var(--sub)", lineHeight: 1.55 }}>{body}</p>
            </div>
          ))}
        </div>
      </section>
    </>
  )
}
