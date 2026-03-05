#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${ROOT_DIR}/logs/slot6-guard"
PID_FILE="${STATE_DIR}/guard.pid"
OUT_FILE="${STATE_DIR}/guard.stdout.log"

mkdir -p "${STATE_DIR}"

if [[ -f "${PID_FILE}" ]]; then
  old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" >/dev/null 2>&1; then
    echo "slot6 guard already running (pid=${old_pid})"
    exit 0
  fi
fi

nohup "${ROOT_DIR}/scripts/guard_slot6_autorecover.sh" >> "${OUT_FILE}" 2>&1 &
new_pid="$!"
echo "${new_pid}" > "${PID_FILE}"
echo "slot6 guard started (pid=${new_pid})"
echo "logs:"
echo "  ${OUT_FILE}"
echo "  ${STATE_DIR}/guard.log"
