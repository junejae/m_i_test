#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_ROOT="${SMOKE_LOG_ROOT:-${ROOT_DIR}/logs}"
TARGET_DIR="${1:-}"
DOCKER_TAIL_LINES="${DOCKER_TAIL_LINES:-80}"

# TUI-friendly default: pipe output to pager so arrow-key scrolling works.
if [[ -t 1 && "${NO_PAGER:-0}" != "1" ]]; then
  if command -v less >/dev/null 2>&1; then
    exec > >(less -R -X)
  fi
fi

if [[ -z "${TARGET_DIR}" ]]; then
  TARGET_DIR="$(ls -1dt "${LOG_ROOT}"/smoke-test-* 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "${TARGET_DIR}" || ! -d "${TARGET_DIR}" ]]; then
  echo "No smoke test result directory found." >&2
  echo "Run: ./scripts/smoke_test_all_services.sh" >&2
  exit 1
fi

section() {
  echo
  echo "=================================================="
  echo "$1"
  echo "=================================================="
}

echo "Result dir: ${TARGET_DIR}"

if [[ -f "${TARGET_DIR}/summary.txt" ]]; then
  section "SUMMARY"
  cat "${TARGET_DIR}/summary.txt"
fi

section "REQUESTS"
for f in "${TARGET_DIR}"/requests/*; do
  [[ -e "$f" ]] || continue
  echo
  echo "--- $(basename "$f") ---"
  cat "$f"
done

section "RESPONSES"
for f in "${TARGET_DIR}"/responses/*.json; do
  [[ -e "$f" ]] || continue
  echo
  echo "--- $(basename "$f") ---"
  cat "$f"
done

if [[ -f "${TARGET_DIR}/responses/slot6-tts.bin" ]]; then
  section "TTS BINARY (slot6-tts.bin)"
  if command -v xxd >/dev/null 2>&1; then
    xxd -l 256 "${TARGET_DIR}/responses/slot6-tts.bin"
  else
    od -An -tx1 -N 256 "${TARGET_DIR}/responses/slot6-tts.bin"
  fi
fi

section "HEADERS"
for f in "${TARGET_DIR}"/headers/*.hdr; do
  [[ -e "$f" ]] || continue
  echo
  echo "--- $(basename "$f") ---"
  cat "$f"
done

section "DOCKER LOGS (tail ${DOCKER_TAIL_LINES})"
for f in "${TARGET_DIR}"/docker/*.log; do
  [[ -e "$f" ]] || continue
  echo
  echo "--- $(basename "$f") ---"
  tail -n "${DOCKER_TAIL_LINES}" "$f"
done
