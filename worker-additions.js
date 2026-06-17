// ─────────────────────────────────────────────────────────────────────────────
// Simi — Cloudflare Worker route additions
//
// Paste these routes into your existing simi-token-proxy Worker, inside the
// fetch handler, BEFORE the Spotify token route. The secrets are stored as
// Worker environment variables (Settings → Variables and Secrets → Add):
//
//   GETSONGBPM_KEY   →  your GetSongBPM API key
//   LASTFM_KEY       →  your Last.fm API key
//   PROXY_API_KEY    →  the existing proxy auth key (already set)
//
// After deploying, update APIKeys.swift (already done — see that file).
// ─────────────────────────────────────────────────────────────────────────────

export default {
  async fetch(request, env) {
    const url     = new URL(request.url)
    const path    = url.pathname
    const params  = url.searchParams

    // ── Auth: every route requires the proxy key header ──────────────────────
    // Reuse the same PROXY_API_KEY you already use for the Spotify route.
    const incomingKey = request.headers.get('X-Proxy-Key')
    if (incomingKey !== env.PROXY_API_KEY) {
      return new Response('Unauthorized', { status: 401 })
    }

    // ── /getsongbpm ──────────────────────────────────────────────────────────
    // Forwards to https://api.getsongbpm.com/search/
    // App sends: ?type=song&lookup=TITLE+ARTIST
    // Worker adds: &api_key=GETSONGBPM_KEY
    if (path === '/getsongbpm') {
      const target = new URL('https://api.getsongbpm.com/search/')
      for (const [key, value] of params.entries()) {
        if (key !== 'api_key') target.searchParams.set(key, value)
      }
      target.searchParams.set('api_key', env.GETSONGBPM_KEY)

      const upstream = await fetch(target.toString(), {
        headers: { 'User-Agent': 'Simi/1.0' },
        cf: { cacheTtl: 86400, cacheEverything: true }   // cache BPM results 24h
      })
      return new Response(upstream.body, {
        status:  upstream.status,
        headers: { 'Content-Type': 'application/json' }
      })
    }

    // ── /lastfm ──────────────────────────────────────────────────────────────
    // Forwards to https://ws.audioscrobbler.com/2.0/
    // App sends: ?method=track.getTopTags&track=...&artist=...&format=json&...
    // Worker adds: &api_key=LASTFM_KEY
    if (path === '/lastfm') {
      const target = new URL('https://ws.audioscrobbler.com/2.0/')
      for (const [key, value] of params.entries()) {
        if (key !== 'api_key') target.searchParams.set(key, value)
      }
      target.searchParams.set('api_key', env.LASTFM_KEY)

      const upstream = await fetch(target.toString(), {
        cf: { cacheTtl: 43200, cacheEverything: true }   // cache tag results 12h
      })
      return new Response(upstream.body, {
        status:  upstream.status,
        headers: { 'Content-Type': 'application/json' }
      })
    }

    // ── /spotify-token (existing route — leave this unchanged) ───────────────
    // ... your existing Spotify token logic stays here ...

    return new Response('Not found', { status: 404 })
  }
}
