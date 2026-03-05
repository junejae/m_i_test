#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
OUT_DIR="${ROOT_DIR}/logs/slot6-debug-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${OUT_DIR}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

env_get() {
  local key="$1"
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
MODEL_6_NAME="${SERVED_MODEL_NAME_6:-$(env_get SERVED_MODEL_NAME_6)}"
MODEL_6_NAME="${MODEL_6_NAME:-qwen3-tts-12hz-1.7b-base}"
ENV_PROXY_API_KEY="$(env_get PROXY_API_KEY)"
BASE_URL="${1:-http://127.0.0.1:${PORT_6}}"
API_KEY_HEADER=()
if [[ -n "${ENV_PROXY_API_KEY:-}" ]] && [[ "${BASE_URL}" == https://* ]]; then
  API_KEY_HEADER=(-H "X-API-Key: ${ENV_PROXY_API_KEY}")
fi

echo "BASE_URL=${BASE_URL}"
echo "OUT_DIR=${OUT_DIR}"

curl -sS "${BASE_URL}/v1/models" "${API_KEY_HEADER[@]}" > "${OUT_DIR}/models.json" || true

# Build a model-compatible request.
# qwen3-tts-*-Base requires task_type=Base with ref_audio/ref_text.
python3 - "${MODEL_6_NAME}" "${OUT_DIR}/speech_request.json" <<'PY'
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
    "input": "안녕하세요. 슬롯6 TTS 디버그 테스트입니다.",
    "response_format": "wav",
}

if "base" in model_l:
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
            "x_vector_only_mode": True,
            "language": "Korean",
        }
    )
else:
    payload.update(
        {
            "task_type": "CustomVoice",
            "voice": "Chelsie",
        }
    )

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False)
PY

HTTP_CODE="$(curl -sS -o "${OUT_DIR}/speech_response.bin" -w "%{http_code}" \
  -H "Content-Type: application/json" \
  "${API_KEY_HEADER[@]}" \
  -d @"${OUT_DIR}/speech_request.json" \
  "${BASE_URL}/v1/audio/speech" || true)"

echo "HTTP_CODE=${HTTP_CODE}" | tee "${OUT_DIR}/result.txt"
echo "First bytes:" | tee -a "${OUT_DIR}/result.txt"
xxd -l 16 "${OUT_DIR}/speech_response.bin" | tee -a "${OUT_DIR}/result.txt" || true

if python3 - "${OUT_DIR}/speech_response.bin" <<'PY'
import json
import sys
from pathlib import Path

p = Path(sys.argv[1])
b = p.read_bytes()
try:
    o = json.loads(b.decode("utf-8"))
except Exception:
    raise SystemExit(1)

print(json.dumps(o, ensure_ascii=False, indent=2))
raise SystemExit(0)
PY
then
  echo "Detected JSON payload (likely error). See ${OUT_DIR}/speech_response.bin"
else
  echo "Non-JSON payload (likely audio). Saved: ${OUT_DIR}/speech_response.bin"
fi
