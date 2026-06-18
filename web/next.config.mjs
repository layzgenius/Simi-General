/** @type {import('next').NextConfig} */
const nextConfig = {
  images: {
    remotePatterns: [
      { protocol: "https", hostname: "i.scdn.co" },         // Spotify album art CDN
      { protocol: "https", hostname: "mosaic.scdn.co" },
      { protocol: "https", hostname: "*.supabase.co" },
    ],
  },
}

export default nextConfig;
