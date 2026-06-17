#!/bin/bash
# run_vibe_eval.command
# Simi — Vibe eval suite runner (double-click me in Finder)
#
# Runs test_vibe_eval.py against the live Railway backend.
# Requires internet access. No simulator needed.

cd "$(dirname "$0")"

VENV_PYTHON="backend/audio-analyzer/.venv/bin/python3"

if [ ! -f "$VENV_PYTHON" ]; then
  echo ""
  echo "ERROR: venv not found at $VENV_PYTHON"
  echo "Run: cd backend/audio-analyzer && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
  read -p "Press Enter to close..."
  exit 1
fi

echo ""
echo "Using Python: $($VENV_PYTHON --version)"
echo ""

"$VENV_PYTHON" test_vibe_eval.py

echo ""
read -p "Press Enter to close..."
