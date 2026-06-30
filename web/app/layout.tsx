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

const navStyle: React.CSSProperties = {
  position: "sticky",
  top: 0,
  zIndex: 100,
  display: "flex",
  alignItems: "center",
  justifyContent: "space-between",
  padding: "20px 40px",
  background: "rgba(12,12,16,0.85)",
  backdropFilter: "blur(20px)",
  WebkitBackdropFilter: "blur(20px)",
  borderBottom: "1px solid var(--border)",
}

const logoStyle: React.CSSProperties = {
  fontSize: 22,
  fontWeight: 900,
  letterSpacing: "-0.5px",
  background: "linear-gradient(135deg, var(--primary), var(--accent))",
  WebkitBackgroundClip: "text",
  WebkitTextFillColor: "transparent",
  backgroundClip: "text",
}

const badgeStyle: React.CSSProperties = {
  fontSize: 12,
  fontWeight: 600,
  color: "var(--sub)",
  background: "var(--card)",
  border: "1px solid var(--border)",
  padding: "4px 12px",
  borderRadius: 100,
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <div className="blob blob-purple" style={{
          position: "fixed",
          borderRadius: "50%",
          filter: "blur(120px)",
          opacity: 0.18,
          pointerEvents: "none",
          zIndex: 0,
          width: 600,
          height: 600,
          background: "var(--primary)",
          top: -200,
          left: -150,
        }} />
        <div className="blob blob-cyan" style={{
          position: "fixed",
          borderRadius: "50%",
          filter: "blur(120px)",
          opacity: 0.18,
          pointerEvents: "none",
          zIndex: 0,
          width: 500,
          height: 500,
          background: "var(--accent)",
          bottom: -100,
          right: -100,
        }} />

        <nav style={navStyle}>
          <a href="/" style={logoStyle}>simi</a>
          <span style={badgeStyle}>Coming to iOS</span>
        </nav>

        <main style={{ position: "relative", zIndex: 1 }}>{children}</main>

        <footer style={{
          position: "relative",
          zIndex: 1,
          borderTop: "1px solid var(--border)",
          padding: "40px",
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          flexWrap: "wrap",
          gap: 16,
        }}>
          <span style={{
            fontSize: 18,
            fontWeight: 900,
            background: "linear-gradient(135deg, var(--primary), var(--accent))",
            WebkitBackgroundClip: "text",
            WebkitTextFillColor: "transparent",
            backgroundClip: "text",
          }}>simi</span>
          <span style={{ fontSize: 13, color: "var(--sub)" }}>Coming soon to iOS</span>
        </footer>

        <div style={{
          position: "relative",
          zIndex: 1,
          background: "var(--surface)",
          borderTop: "1px solid var(--border)",
          padding: "14px 40px",
          textAlign: "center",
          fontSize: 12,
          color: "#555570",
        }}>
          BPM and key data powered by{" "}
          <a href="https://getsongbpm.com" target="_blank" rel="noopener" style={{ color: "var(--sub)" }}>
            GetSongBPM.com
          </a>
        </div>
      </body>
    </html>
  )
}
