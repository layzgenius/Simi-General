# Simi — Setup Guide

Get Simi running in Xcode in about 15 minutes.

---

## Step 1 — Create an Xcode Project

1. Open **Xcode** (download free from Mac App Store if needed)
2. Click **Create New Project**
3. Choose **iOS → App**
4. Fill in the fields:
   - **Product Name:** `Simi`
   - **Team:** Your Apple ID (sign in if prompted)
   - **Organization Identifier:** `com.yourname.simi` (e.g. `com.steven.simi`)
   - **Interface:** SwiftUI
   - **Language:** Swift
5. Choose a save location → **Create**

---

## Step 2 — Add the Simi Files

After Xcode creates the project, you'll see a default `ContentView.swift`.

**Delete the files Xcode created:**
- Right-click `ContentView.swift` → Delete → Move to Trash

**Add the Simi files:**
1. In the Project Navigator (left panel), right-click your project folder
2. Choose **Add Files to "Simi"...**
3. Add these files from the `Simi App` folder you have:
   - `SimiApp.swift`
   - `Models/Song.swift`
   - `Services/SpotifyService.swift`
   - `Services/LastFMService.swift`
   - `Services/URLParserService.swift`
   - `Services/RecommendationEngine.swift`
   - `Views/HomeView.swift`
   - `Views/ResultsView.swift`
   - `Views/SongCard.swift`

> 💡 **Tip:** Create Groups (like folders) in Xcode by right-clicking → New Group. Name them `Models`, `Services`, and `Views` to match the structure.

---

## Step 3 — Get Your API Keys

Simi needs three API keys to work. All three are free.

### Spotify API Key
1. Go to [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard)
2. Log in with your Spotify account (free account works)
3. Click **Create App**
   - App name: `Simi`
   - Redirect URI: `https://localhost` (required but not used)
4. Click **Settings** → copy your **Client ID** and **Client Secret**
5. Open `Services/SpotifyService.swift` and paste them:
   ```swift
   private let clientID     = "paste_your_client_id_here"
   private let clientSecret = "paste_your_client_secret_here"
   ```

### Last.fm API Key
1. Go to [last.fm/api/account/create](https://www.last.fm/api/account/create)
2. Fill in the form (app name: `Simi`, callback URL: leave blank)
3. Copy your **API Key**
4. Open `Services/LastFMService.swift` and paste it:
   ```swift
   private let apiKey = "paste_your_api_key_here"
   ```

### YouTube API (optional for now)
YouTube URL parsing works without an API key — we extract the video ID from the URL
and then search Spotify for the matching song. You can add full YouTube Data API
integration later.

---

## Step 4 — Run the App

1. In Xcode, select a simulator from the device menu at the top (e.g. **iPhone 16 Pro**)
2. Press **⌘R** (Command + R) or click the ▶ Play button
3. The app should build and launch in the simulator

If you see build errors, check:
- All files are added to the Xcode project (not just in Finder)
- Your Xcode is version 15 or later

---

## File Structure

```
Simi App/
├── SimiApp.swift               ← App entry point (runs first)
├── Models/
│   └── Song.swift              ← Data blueprints (Song, AudioFeatures, etc.)
├── Services/
│   ├── SpotifyService.swift    ← Spotify API (fetch songs, audio features, recs)
│   ├── LastFMService.swift     ← Last.fm API (genre tags, similar tracks)
│   ├── URLParserService.swift  ← Detects platform from pasted URL
│   └── RecommendationEngine.swift ← Brain — coordinates all services
└── Views/
    ├── HomeView.swift          ← Paste URL screen
    ├── ResultsView.swift       ← Similar songs list
    └── SongCard.swift          ← Individual song card component
```

---

## How It Works

```
User pastes URL
      ↓
URLParserService detects platform (Spotify/YouTube/SoundCloud)
      ↓
SpotifyService fetches song metadata + audio features (BPM, energy, mood)
      ↓
LastFMService fetches genre tags + similar tracks (runs in parallel)
      ↓
RecommendationEngine scores and ranks all results
      ↓
Results screen shows ranked similar songs with match %
```

---

## Next Features to Build

- [ ] **Vibe Graph** — visual plot of energy vs. valence (the "mood map")
- [ ] **History** — save past searches with Core Data
- [ ] **Apple Music / Tidal links** — open songs in other apps
- [ ] **Share sheet** — share a list of recommendations
- [ ] **SEO landing page** — for "songs like X" web traffic
- [ ] **App Store listing** — with the target keywords (songs like after dark, etc.)

---

## Questions?

If you hit a build error you can't figure out, copy the red error text and
share it — errors in Xcode are almost always fixable in one step.
