#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

URL="$(docker compose logs --no-color edge-tunnel 2>/dev/null | grep -Eo 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' | tail -n 1 || true)"

if [[ -z "$URL" ]]; then
  echo "No tunnel URL found. Is edge-tunnel running?"
  echo "Run: ./scripts/start_public_tunnel.sh"
  exit 1
fi

echo "$URL"
