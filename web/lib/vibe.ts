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
