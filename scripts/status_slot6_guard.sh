#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/logs/slot6-guard"
PID_FILE="${STATE_DIR}/guard.pid"

if [[ ! -f "${PID_FILE}" ]]; then
  echo "slot6 guard: stopped"
  exit 0
fi

pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
if [[ -z "${pid}" ]]; then
  echo "slot6 guard: stopped (empty pid file)"
  exit 0
fi

if kill -0 "${pid}" >/dev/null 2>&1; then
  echo "slot6 guard: running (pid=${pid})"
  echo "log files:"
  echo "  ${STATE_DIR}/guard.log"
  echo "  ${STATE_DIR}/guard.stdout.log"
else
  echo "slot6 guard: stopped (stale pid=${pid})"
fi
