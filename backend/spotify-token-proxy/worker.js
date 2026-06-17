/**
 * Simi — Cloudflare Worker
 *
 * Routes:
 *   GET /spotify-token   → vends Spotify access tokens to the iOS app (with in-memory caching)
 *   GET /health          → returns cache status
 *   GET /privacy         → serves the app's privacy policy (required by Spotify ToS + App Store)
 *
 * Secrets (set in Cloudflare dashboard → Worker Settings → Variables):
 *   SPOTIFY_CLIENT_ID, SPOTIFY_CLIENT_SECRET, PROXY_API_KEY
 */

// In-memory token cache — survives across requests within the same Worker instance.
// Cloudflare spins up multiple isolates, so this doesn't guarantee zero Spotify calls,
// but in practice it dramatically reduces them for active traffic.
const tokenCache = { token: null, expiresAt: 0 };

addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});

async function handleRequest(request) {
  const url = new URL(request.url);

  // CORS preflight
  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  if (url.pathname === '/spotify-token') {
    return handleTokenRequest(request);
  }

  if (url.pathname === '/health') {
    return respond({ status: 'ok', cached: hasCachedToken() }, 200);
  }

  if (url.pathname === '/privacy') {
    return servePrivacyPolicy();
  }

  return new Response('Not found', { status: 404 });
}

// ── Token Proxy ──────────────────────────────────────────────────────────────

async function handleTokenRequest(request) {
  if (request.method !== 'GET') {
    return respond({ error: 'Method not allowed' }, 405);
  }

  const appKey = request.headers.get('X-App-Key');
  if (!appKey || appKey !== PROXY_API_KEY) {
    return respond({ error: 'Unauthorized' }, 401);
  }

  // Serve cached token if still valid (with 60s safety buffer)
  if (hasCachedToken()) {
    return respond({
      access_token: tokenCache.token,
      expires_in: Math.floor((tokenCache.expiresAt - Date.now()) / 1000),
    }, 200);
  }

  try {
    const credentials = btoa(SPOTIFY_CLIENT_ID + ':' + SPOTIFY_CLIENT_SECRET);
    const spotifyRes = await fetch('https://accounts.spotify.com/api/token', {
      method: 'POST',
      headers: {
        'Authorization': 'Basic ' + credentials,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'grant_type=client_credentials',
    });

    if (!spotifyRes.ok) {
      return respond({ error: 'Failed to authenticate with Spotify' }, 502);
    }

    const data = await spotifyRes.json();

    // Cache the token with a 60s safety buffer before its real expiry
    tokenCache.token = data.access_token;
    tokenCache.expiresAt = Date.now() + (data.expires_in - 60) * 1000;

    return respond({ access_token: data.access_token, expires_in: data.expires_in }, 200);

  } catch (err) {
    return respond({ error: 'Internal server error' }, 500);
  }
}

function hasCachedToken() {
  return tokenCache.token !== null && Date.now() < tokenCache.expiresAt;
}

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'X-App-Key',
  };
}

function respond(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders() },
  });
}

// ── Privacy Policy ───────────────────────────────────────────────────────────

function servePrivacyPolicy() {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Simi — Privacy Policy</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
           max-width: 680px; margin: 60px auto; padding: 0 24px;
           color: #1a1a2e; line-height: 1.7; }
    h1 { font-size: 2rem; margin-bottom: 4px; }
    h2 { font-size: 1.1rem; margin-top: 2rem; color: #333; }
    p, li { font-size: 0.95rem; color: #444; }
    a { color: #7c5dfa; }
    .updated { font-size: 0.85rem; color: #888; margin-bottom: 2rem; }
  </style>
</head>
<body>

<h1>Privacy Policy</h1>
<p class="updated">Last updated: June 1, 2026</p>

<p>Simi ("the app") is a music discovery app that finds songs that feel similar
to ones you love. This policy explains what data the app collects, how it is
used, and your rights.</p>

<h2>1. Data We Collect</h2>
<p>Simi collects the following data to provide its core functionality:</p>
<ul>
  <li><strong>Song links and search queries</strong> — URLs or song titles you
      enter to find similar music. These are sent to third-party APIs
      (Spotify, Last.fm, YouTube) to retrieve song information and
      recommendations.</li>
  <li><strong>Search history</strong> — stored locally on your device only.
      It is never uploaded to our servers.</li>
</ul>
<p>Simi does <strong>not</strong> collect your name, email address, location,
contacts, or any other personal information. The app does not require an
account or login.</p>

<h2>2. Third-Party Services</h2>
<p>Simi uses the following third-party services to deliver results. Each has
its own privacy policy:</p>
<ul>
  <li><strong>Spotify</strong> — song metadata, audio features, and
      recommendations.
      <a href="https://www.spotify.com/privacy" target="_blank">Spotify Privacy Policy</a></li>
  <li><strong>Last.fm</strong> — similar track recommendations and genre tags.
      <a href="https://www.last.fm/legal/privacy" target="_blank">Last.fm Privacy Policy</a></li>
  <li><strong>YouTube</strong> — video metadata via the oEmbed API (no account
      access).
      <a href="https://policies.google.com/privacy" target="_blank">Google Privacy Policy</a></li>
  <li><strong>iTunes / Apple Music</strong> — song search and genre metadata.
      <a href="https://www.apple.com/legal/privacy/" target="_blank">Apple Privacy Policy</a></li>
</ul>
<p>When you search for a song, the title and/or URL is sent to these services
to retrieve music data. No additional personal data is included in these
requests.</p>

<h2>3. Data Storage</h2>
<p>Your search history is stored locally on your device using iOS secure
storage. It is not transmitted to us or any third party. You can delete it at
any time using the "Clear" button in the app.</p>

<h2>4. Data Sharing</h2>
<p>We do not sell, rent, or share your data with any third party beyond the
API requests described above, which are necessary to provide the app's core
functionality.</p>

<h2>5. Children's Privacy</h2>
<p>Simi is not directed at children under 13. We do not knowingly collect data
from children.</p>

<h2>6. Changes to This Policy</h2>
<p>If this policy changes materially, we will update the "Last updated" date
at the top. Continued use of the app after changes constitutes acceptance of
the updated policy.</p>

<h2>7. Contact</h2>
<p>Questions about this policy? Email us at
<a href="mailto:batboyskip@gmail.com">batboyskip@gmail.com</a>.</p>

</body>
</html>`;

  return new Response(html, {
    status: 200,
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  });
}
