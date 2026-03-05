#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
STATE_DIR="${ROOT_DIR}/logs/slot6-guard"
RESTART_TS_FILE="${STATE_DIR}/restart_epochs.log"
GUARD_LOG_FILE="${STATE_DIR}/guard.log"

CHECK_INTERVAL="${CHECK_INTERVAL:-20}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-120}"
MAX_RESTARTS_PER_HOUR="${MAX_RESTARTS_PER_HOUR:-6}"
HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-3}"
RUN_ONCE="${RUN_ONCE:-0}"
USE_FORCE_RECREATE="${USE_FORCE_RECREATE:-0}"
LOG_ERROR_REGEX="${LOG_ERROR_REGEX:-EngineCore encountered an issue|Speech generation failed|RuntimeError: Worker failed|Process EngineCore_DPO}"

mkdir -p "${STATE_DIR}"
touch "${RESTART_TS_FILE}" "${GUARD_LOG_FILE}"

env_get() {
  local key="$1"
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo ""
    return
  fi
  local line
  line="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n1 || true)"
  if [[ -z "${line}" ]]; then
    echo ""
  else
    echo "${line#*=}"
  fi
}

PORT_6="${PORT_6:-$(env_get PORT_6)}"
PORT_6="${PORT_6:-8106}"

log() {
  local msg="$1"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "[${ts}] ${msg}" | tee -a "${GUARD_LOG_FILE}"
}

prune_restart_epochs() {
  local now cutoff
  now="$(date +%s)"
  cutoff=$((now - 3600))
  awk -v c="${cutoff}" '$1 >= c {print $1}' "${RESTART_TS_FILE}" > "${RESTART_TS_FILE}.tmp" || true
  mv "${RESTART_TS_FILE}.tmp" "${RESTART_TS_FILE}"
}

restart_count_last_hour() {
  prune_restart_epochs
  wc -l < "${RESTART_TS_FILE}" | tr -d ' '
}

mark_restart_now() {
  date +%s >> "${RESTART_TS_FILE}"
}

last_restart_epoch() {
  tail -n 1 "${RESTART_TS_FILE}" 2>/dev/null || true
}

can_restart_now() {
  local last now count
  now="$(date +%s)"
  last="$(last_restart_epoch)"
  if [[ -n "${last}" ]]; then
    if (( now - last < COOLDOWN_SECONDS )); then
      log "Skip restart: cooldown active (${now-last}s < ${COOLDOWN_SECONDS}s)"
      return 1
    fi
  fi
  count="$(restart_count_last_hour)"
  if (( count >= MAX_RESTARTS_PER_HOUR )); then
    log "Skip restart: reached MAX_RESTARTS_PER_HOUR=${MAX_RESTARTS_PER_HOUR}"
    return 1
  fi
  return 0
}

restart_slot6() {
  local reason="$1"
  if ! can_restart_now; then
    return
  fi

  log "Restarting mig-vllm-6 (reason=${reason})"
  if [[ "${USE_FORCE_RECREATE}" == "1" ]]; then
    docker compose up -d --force-recreate mig-vllm-6
  else
    docker compose restart mig-vllm-6 || docker compose up -d --force-recreate mig-vllm-6
  fi
  mark_restart_now
}

health_ok() {
  curl -fsS --max-time 4 "http://127.0.0.1:${PORT_6}/health" >/dev/null 2>&1
}

log "slot6 guard started (port=${PORT_6}, interval=${CHECK_INTERVAL}s, cooldown=${COOLDOWN_SECONDS}s, max_restarts_per_hour=${MAX_RESTARTS_PER_HOUR})"
log "error regex: ${LOG_ERROR_REGEX}"

last_log_since="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
consecutive_health_fail=0

while true; do
  sleep "${CHECK_INTERVAL}"
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # 1) Log-pattern detection in new window
  recent_logs="$(docker compose logs --no-color --since "${last_log_since}" mig-vllm-6 2>/dev/null || true)"
  last_log_since="${now_iso}"
  if [[ -n "${recent_logs}" ]] && echo "${recent_logs}" | grep -Eiq "${LOG_ERROR_REGEX}"; then
    restart_slot6 "log-pattern"
  fi

  # 2) Health fail streak detection
  if health_ok; then
    consecutive_health_fail=0
  else
    consecutive_health_fail=$((consecutive_health_fail + 1))
    log "slot6 health failed (${consecutive_health_fail}/${HEALTH_FAIL_THRESHOLD})"
    if (( consecutive_health_fail >= HEALTH_FAIL_THRESHOLD )); then
      restart_slot6 "health-fail-streak"
      consecutive_health_fail=0
    fi
  fi

  if [[ "${RUN_ONCE}" == "1" ]]; then
    log "RUN_ONCE=1, exiting after one cycle."
    break
  fi
done
