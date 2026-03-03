#!/usr/bin/env bash
set -euo pipefail

if ! command -v uv >/dev/null 2>&1; then
  echo "uv not found. Install first: curl -LsSf https://astral.sh/uv/install.sh | sh"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HOLD_SECONDS="${HOLD_SECONDS:-300}"

echo "[1/2] Launch Gradio with share=True and probe URL"
uv run --with gradio python3 scripts/gradio_share_probe.py --hold-seconds "$HOLD_SECONDS"

echo "[2/2] Done"
