#!/bin/bash
# test_railway_mp3.command
# Tests Railway /analyze with a plain public MP3 (not iTunes CDN)
# to distinguish: is the problem ffmpeg/librosa OR is Railway blocked from iTunes?

RAILWAY="https://simi-audio-analyzer-production.up.railway.app"

# Public domain 30s MP3 — Bach piece from Internet Archive, no CDN auth needed
PUBLIC_MP3="https://upload.wikimedia.org/wikipedia/commons/transcoded/b/b6/Johann_Sebastian_Bach_-_Orchestersuite_Nr._3_G-Dur_-_Air.ogg/Johann_Sebastian_Bach_-_Orchestersuite_Nr._3_G-Dur_-_Air.ogg.mp3"

echo ""
echo "============================================================"
echo "  Railway /analyze — MP3 isolation test"
echo "  (rules out iTunes CDN as the failure point)"
echo "============================================================"
echo ""
echo "  URL: $PUBLIC_MP3"
echo ""
echo "  Sending to Railway... (allow ~20s)"
echo ""

RESULT=$(curl -s --max-time 40 -X POST "$RAILWAY/analyze" \
  -H "Content-Type: application/json" \
  -d "{\"previewUrl\":\"$PUBLIC_MP3\"}")

echo "  Raw response:"
echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"

echo ""
if echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'bpm' in d else 1)" 2>/dev/null; then
  echo "  ✅  PASS — librosa IS working on Railway."
  echo "      The iTunes CDN is the problem (Railway's IP is blocked/redirected)."
  echo "      Fix: proxy the audio download through the iOS app, or use a different CDN."
else
  echo "  ❌  FAIL — librosa is not working on Railway even with a public MP3."
  echo "      This points to ffmpeg missing or a librosa install issue."
  echo "      Fix: redeploy Railway after confirming nixpacks.toml is applied."
fi
echo ""
echo "============================================================"
echo ""
read -p "Press Enter to close..."
