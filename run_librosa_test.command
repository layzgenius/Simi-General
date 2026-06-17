#!/bin/bash
# Simi — librosa test runner (double-click me in Finder)
# Uses the project venv Python on your Mac to run the test.

cd "$(dirname "$0")"

VENV_PYTHON="backend/audio-analyzer/.venv/bin/python3"

if [ ! -f "$VENV_PYTHON" ]; then
  echo "ERROR: venv not found at $VENV_PYTHON"
  echo "Run: cd backend/audio-analyzer && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
  read -p "Press Enter to close..."
  exit 1
fi

echo ""
echo "Using Python: $($VENV_PYTHON --version)"
echo "Starting librosa test..."
echo ""

"$VENV_PYTHON" test_librosa.py

echo ""
read -p "Press Enter to close..."
