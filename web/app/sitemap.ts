import { MetadataRoute } from "next"
import { createClient } from "@/lib/supabase"

export const revalidate = 3600

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  let songs: { spotify_id: string }[] = []

  if (process.env.NEXT_PUBLIC_SUPABASE_URL && process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY) {
    const supabase = createClient()
    const { data } = await supabase
      .from("analyzed_songs")
      .select("spotify_id")
      .limit(5000)
    songs = data ?? []
  }

  const songUrls: MetadataRoute.Sitemap = songs.map((s: { spotify_id: string }) => ({
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
