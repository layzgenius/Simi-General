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
