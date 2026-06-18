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
