#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PID_FILE="${ROOT_DIR}/logs/slot6-guard/guard.pid"

if [[ ! -f "${PID_FILE}" ]]; then
  echo "slot6 guard is not running (no pid file)."
  exit 0
fi

pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
if [[ -z "${pid}" ]]; then
  rm -f "${PID_FILE}"
  echo "slot6 guard pid file was empty; cleaned."
  exit 0
fi

if kill -0 "${pid}" >/dev/null 2>&1; then
  kill "${pid}"
  echo "slot6 guard stopped (pid=${pid})"
else
  echo "slot6 guard process not found (pid=${pid}); cleaning pid file."
fi

rm -f "${PID_FILE}"
