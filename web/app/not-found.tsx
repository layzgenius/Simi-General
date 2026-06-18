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
