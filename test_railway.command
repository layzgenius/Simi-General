#!/bin/bash
# test_railway.command
# Verifies the deployed Railway backend (librosa) responds exactly as the iOS app expects.
# Double-click to run.

RAILWAY="https://simi-audio-analyzer-production.up.railway.app"

echo ""
echo "============================================================"
echo "  SIMI — Railway + librosa end-to-end verification"
echo "  (same calls the iOS app makes via SimiAudioService.swift)"
echo "============================================================"

# ── 1. Health check ──────────────────────────────────────────────────
echo ""
echo "[1/4] Health check:  GET $RAILWAY/health"
HEALTH=$(curl -s --max-time 5 "$RAILWAY/health")
echo "      Response: $HEALTH"
if [[ "$HEALTH" != *"ok"* ]]; then
  echo "  FAIL: backend not reachable"
  read -p "Press Enter to close..."; exit 1
fi
echo "      OK"

# ── 2. Fetch a live iTunes preview URL ───────────────────────────────
echo ""
echo "[2/4] Fetching fresh iTunes preview URL for 'bad guy'..."
ITUNES_JSON=$(curl -s --max-time 10 \
  "https://itunes.apple.com/search?term=billie+eilish+bad+guy&media=music&limit=3&entity=song")
PREVIEW_URL=$(echo "$ITUNES_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('results', []):
    p = t.get('previewUrl', '')
    if p:
        print(p)
        break
" 2>/dev/null)

if [[ -z "$PREVIEW_URL" ]]; then
  echo "  FAIL: could not fetch iTunes preview URL"
  read -p "Press Enter to close..."; exit 1
fi
echo "      OK: ${PREVIEW_URL:0:80}..."

# ── 3. /analyze with fresh URL ────────────────────────────────────────
echo ""
echo "[3/4] Analyze:  POST $RAILWAY/analyze"
echo "      (downloading iTunes preview + running librosa — allow ~15s)"

ANALYZE=$(curl -s --max-time 35 -X POST "$RAILWAY/analyze" \
  -H "Content-Type: application/json" \
  -d "{\"previewUrl\":\"$PREVIEW_URL\"}")

echo ""
echo "      Raw JSON:"
echo "$ANALYZE" | python3 -m json.tool 2>/dev/null || echo "$ANALYZE"

# Verify all AudioFeatures fields present
REQUIRED="bpm energy valence danceability acousticness instrumentalness liveness loudness key mode"
echo ""
echo "      Field check (must match AudioFeatures.swift Codable struct):"
ALL_OK=true
for field in $REQUIRED; do
  if echo "$ANALYZE" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if '$field' in d else 1)" 2>/dev/null; then
    val=$(echo "$ANALYZE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field','?'))" 2>/dev/null)
    echo "        ✅  $field = $val"
  else
    echo "        ❌  $field — MISSING"
    ALL_OK=false
  fi
done

# ── 4. /similarity sanity check ───────────────────────────────────────
echo ""
echo "[4/4] Similarity endpoint:  POST $RAILWAY/similarity"
SIM=$(curl -s --max-time 10 -X POST "$RAILWAY/similarity" \
  -H "Content-Type: application/json" \
  -d '{
    "source": {"bpm":135,"energy":0.71,"valence":0.37,"danceability":0.35,"acousticness":0.67,"instrumentalness":0.0,"liveness":1.0,"loudness":-12.0,"key":9,"mode":0,"isEstimated":true,"isKeyEstimated":false},
    "target": {"bpm":117,"energy":0.71,"valence":0.52,"danceability":0.72,"acousticness":0.67,"instrumentalness":0.0,"liveness":1.0,"loudness":-12.0,"key":6,"mode":0,"isEstimated":true,"isKeyEstimated":false}
  }')
echo "      Response: $SIM"

echo ""
echo "============================================================"
if $ALL_OK; then
  echo "  PASS — librosa is live on Railway."
  echo "  Every Xcode build will receive full AudioFeatures"
  echo "  from iTunes 30s previews with zero Spotify dependency."
else
  echo "  FAIL — /analyze did not return full AudioFeatures."
  echo "  Detail: $ANALYZE"
fi
echo "============================================================"
echo ""
read -p "Press Enter to close..."
