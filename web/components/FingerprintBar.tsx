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
