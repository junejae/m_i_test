#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
NOW="$(date +%Y%m%d-%H%M%S)"
LOG_ROOT="${SMOKE_LOG_ROOT:-${ROOT_DIR}/logs}"
OUT_DIR="${SMOKE_OUT_DIR:-${LOG_ROOT}/smoke-test-${NOW}}"
RUN_START_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STRICT_LOG_SCAN="${STRICT_LOG_SCAN:-1}"
mkdir -p "${OUT_DIR}"
mkdir -p "${OUT_DIR}/requests" "${OUT_DIR}/responses" "${OUT_DIR}/headers" "${OUT_DIR}/docker"

SUMMARY_FILE="${OUT_DIR}/summary.txt"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

PORT_1="${PORT_1:-8101}"
PORT_2="${PORT_2:-8102}"
PORT_3="${PORT_3:-8103}"
PORT_4="${PORT_4:-8104}"
PORT_5="${PORT_5:-8105}"
PORT_6="${PORT_6:-8106}"

MODEL_1_NAME="${SERVED_MODEL_NAME_1:-gemma3-4b-it}"
MODEL_2_NAME="${SERVED_MODEL_NAME_2:-qwen3-vl-8b-instruct}"
MODEL_3_NAME="${SERVED_MODEL_NAME_3:-bge-m3-ko}"
MODEL_4_NAME="${SERVED_MODEL_NAME_4:-ko-reranker}"
MODEL_6_NAME="${SERVED_MODEL_NAME_6:-qwen3-tts-12hz-1.7b-base}"
ASR_MODEL_NAME="${ASR_MODEL_5:-large-v3}"

PASS_COUNT=0
FAIL_COUNT=0

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

print_ok() {
  echo "[PASS] $1"
  echo "[PASS] $1" >> "${SUMMARY_FILE}"
  PASS_COUNT=$((PASS_COUNT + 1))
}

print_fail() {
  echo "[FAIL] $1"
  echo "[FAIL] $1" >> "${SUMMARY_FILE}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

json_has_key() {
  local file="$1"
  local key="$2"
  python3 - "$file" "$key" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
try:
    data = json.loads(path.read_text())
except Exception:
    print("0")
    raise SystemExit(0)

def has_key(obj, target):
    if isinstance(obj, dict):
        if target in obj:
            return True
        return any(has_key(v, target) for v in obj.values())
    if isinstance(obj, list):
        return any(has_key(v, target) for v in obj)
    return False

print("1" if has_key(data, key) else "0")
PY
}

run_json_test() {
  local name="$1"
  local url="$2"
  local payload="$3"
  local expect_key="$4"
  local out_file="${OUT_DIR}/responses/${name}.json"
  local code

  printf "%s\n" "${payload}" > "${OUT_DIR}/requests/${name}.json"
  code="$(curl -sS -o "${out_file}" -w "%{http_code}" \
    -D "${OUT_DIR}/headers/${name}.hdr" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${url}" || true)"

  if [[ "${code}" != "200" ]]; then
    print_fail "${name} (HTTP ${code})"
    sed -n '1,6p' "${out_file}" 2>/dev/null || true
    return
  fi

  if [[ "$(json_has_key "${out_file}" "${expect_key}")" == "1" ]]; then
    print_ok "${name}"
  else
    print_fail "${name} (missing key: ${expect_key})"
    sed -n '1,6p' "${out_file}" 2>/dev/null || true
  fi
}

echo "== Smoke test start =="
echo "Output dir: ${OUT_DIR}"
echo "Output dir: ${OUT_DIR}" > "${SUMMARY_FILE}"
echo "Run started at (UTC): ${RUN_START_ISO}" | tee -a "${SUMMARY_FILE}" >/dev/null

run_json_test \
  "slot1-chat" \
  "http://127.0.0.1:${PORT_1}/v1/chat/completions" \
  "{\"model\":\"${MODEL_1_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"테스트 응답 한 줄만 줘.\"}],\"max_tokens\":32}" \
  "choices"

run_json_test \
  "slot2-vl-chat" \
  "http://127.0.0.1:${PORT_2}/v1/chat/completions" \
  "{\"model\":\"${MODEL_2_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"텍스트만으로 헬스체크 응답해줘.\"}],\"max_tokens\":32}" \
  "choices"

run_json_test \
  "slot3-embeddings" \
  "http://127.0.0.1:${PORT_3}/v1/embeddings" \
  "{\"model\":\"${MODEL_3_NAME}\",\"input\":[\"임베딩 테스트 문장\"]}" \
  "embedding"

# Reranker endpoint support differs by runtime. Try rerank first, then fallback to /v1/models.
R4_REQ="${OUT_DIR}/requests/slot4-rerank.json"
R4_OUT="${OUT_DIR}/responses/slot4-rerank.json"
printf "%s\n" "{\"model\":\"${MODEL_4_NAME}\",\"query\":\"대한민국 수도는?\",\"documents\":[\"서울\",\"부산\"]}" > "${R4_REQ}"
R4_CODE="$(curl -sS -o "${R4_OUT}" -w "%{http_code}" \
  -D "${OUT_DIR}/headers/slot4-rerank.hdr" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_4_NAME}\",\"query\":\"대한민국 수도는?\",\"documents\":[\"서울\",\"부산\"]}" \
  "http://127.0.0.1:${PORT_4}/v1/rerank" || true)"
if [[ "${R4_CODE}" == "200" ]] && [[ "$(json_has_key "${R4_OUT}" "results")" == "1" ]]; then
  print_ok "slot4-rerank"
else
  run_json_test \
    "slot4-models-fallback" \
    "http://127.0.0.1:${PORT_4}/v1/models" \
    "{}" \
    "data"
fi

# Generate 1-second silent wav for ASR endpoint check.
ASR_WAV="${TMP_DIR}/asr_test.wav"
python3 - "${ASR_WAV}" <<'PY'
import struct
import wave
import sys

out = sys.argv[1]
with wave.open(out, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(16000)
    frames = b"".join(struct.pack("<h", 0) for _ in range(16000))
    w.writeframes(frames)
PY

ASR_OUT="${OUT_DIR}/responses/slot5-asr.json"
ASR_CODE="$(curl -sS -o "${ASR_OUT}" -w "%{http_code}" \
  -D "${OUT_DIR}/headers/slot5-asr.hdr" \
  -X POST "http://127.0.0.1:${PORT_5}/v1/audio/transcriptions" \
  -F "file=@${ASR_WAV}" \
  -F "model=${ASR_MODEL_NAME}" \
  -F "language=ko" || true)"
if [[ "${ASR_CODE}" == "200" ]] && [[ "$(json_has_key "${ASR_OUT}" "text")" == "1" ]]; then
  print_ok "slot5-asr"
else
  print_fail "slot5-asr (HTTP ${ASR_CODE})"
  sed -n '1,8p' "${ASR_OUT}" 2>/dev/null || true
fi

# TTS endpoint: expect audio bytes on success.
TTS_REQ="${OUT_DIR}/requests/slot6-tts.json"
python3 - "${MODEL_6_NAME}" "${TTS_REQ}" <<'PY'
import base64
import io
import json
import struct
import sys
import wave

model = sys.argv[1]
out_path = sys.argv[2]
model_l = model.lower()

payload = {
    "model": model,
    "input": "테스트 음성입니다.",
    "response_format": "wav",
}

if "base" in model_l:
    # Base variant expects voice cloning inputs.
    wav_buf = io.BytesIO()
    with wave.open(wav_buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        frames = b"".join(struct.pack("<h", 0) for _ in range(16000))
        w.writeframes(frames)
    b64_wav = base64.b64encode(wav_buf.getvalue()).decode("ascii")
    payload.update(
        {
            "task_type": "Base",
            "ref_audio": f"data:audio/wav;base64,{b64_wav}",
            "ref_text": "테스트 음성 참조 문장입니다.",
        }
    )
elif "voicedesign" in model_l:
    payload.update(
        {
            "task_type": "VoiceDesign",
            "instructions": "맑고 차분한 한국어 여성 목소리",
            "language": "Korean",
        }
    )
else:
    payload.update(
        {
            "task_type": "CustomVoice",
            "voice": "sohee",
            "language": "Korean",
        }
    )

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False)
PY
TTS_OUT="${OUT_DIR}/responses/slot6-tts.bin"
TTS_HDR="${OUT_DIR}/headers/slot6-tts.hdr"
TTS_CODE="$(curl -sS -o "${TTS_OUT}" -D "${TTS_HDR}" -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d @"${TTS_REQ}" \
  "http://127.0.0.1:${PORT_6}/v1/audio/speech" || true)"
if [[ "${TTS_CODE}" == "200" ]]; then
  if [[ -s "${TTS_OUT}" ]]; then
    print_ok "slot6-tts"
  else
    print_fail "slot6-tts (empty body)"
  fi
else
  print_fail "slot6-tts (HTTP ${TTS_CODE})"
  sed -n '1,10p' "${TTS_HDR}" 2>/dev/null || true
fi

SERVICES=(mig-vllm-1 mig-vllm-2 mig-vllm-3 mig-vllm-4 mig-asr-5 mig-vllm-6)
for svc in "${SERVICES[@]}"; do
  docker compose logs --since "${RUN_START_ISO}" "${svc}" > "${OUT_DIR}/docker/${svc}.log" 2>&1 || true
done

if [[ "${STRICT_LOG_SCAN}" == "1" ]]; then
  ERROR_REGEX='(Traceback|ERROR|Error response from daemon|exited with code|engine core initialization failed|ValidationError|RuntimeError)'
  for svc in "${SERVICES[@]}"; do
    log_file="${OUT_DIR}/docker/${svc}.log"
    if [[ -f "${log_file}" ]] && grep -Eiq "${ERROR_REGEX}" "${log_file}"; then
      print_fail "${svc}-runtime-log"
      {
        echo "--- ${svc} matched error patterns ---"
        grep -Ein "${ERROR_REGEX}" "${log_file}" | head -n 20
      } >> "${SUMMARY_FILE}"
    else
      print_ok "${svc}-runtime-log"
    fi
  done
fi

echo
echo "== Result =="
echo "PASS: ${PASS_COUNT}"
echo "FAIL: ${FAIL_COUNT}"
{
  echo
  echo "== Result =="
  echo "PASS: ${PASS_COUNT}"
  echo "FAIL: ${FAIL_COUNT}"
  echo
  echo "Saved files:"
  echo "- ${OUT_DIR}/summary.txt"
  echo "- ${OUT_DIR}/requests/"
  echo "- ${OUT_DIR}/responses/"
  echo "- ${OUT_DIR}/headers/"
  echo "- ${OUT_DIR}/docker/*.log"
} >> "${SUMMARY_FILE}"

echo
echo "Saved files:"
echo "- ${OUT_DIR}/summary.txt"
echo "- ${OUT_DIR}/requests/"
echo "- ${OUT_DIR}/responses/"
echo "- ${OUT_DIR}/headers/"
echo "- ${OUT_DIR}/docker/*.log"

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  exit 1
fi
