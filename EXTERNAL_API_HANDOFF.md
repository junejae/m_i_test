# External API Handoff (m_i_test)

## 1) Public Endpoint

- Base URL: `https://higher-finds-vic-instances.trycloudflare.com`
- 방식: Cloudflare Quick Tunnel
- 주의: Quick Tunnel URL은 재시작 시 변경될 수 있음

최신 URL 확인:

```bash
cd /Users/junejae/workspace/m_i_test
./scripts/show_public_tunnel_url.sh
```

## 2) Auth

| 항목 | 값 |
|---|---|
| 공통 헤더 | `X-API-Key: <PROXY_API_KEY>` |
| JSON API 헤더 | `Content-Type: application/json` |

보안 주의:
- API 키는 문서에 평문 기록 금지
- 키 전달은 별도 보안 채널 사용

## 3) Slot Map

| Slot | 용도 | 모델 | 기본 엔드포인트 |
|---|---|---|---|
| Slot1 | Chat LLM + Tool Calling | `qwen3.5-4b` | `/slot1/v1/chat/completions` |
| Slot2 | OCR/Vision | `qwen3-vl-8b-instruct` | `/slot2/v1/chat/completions` |
| Slot3 | Embeddings | `bge-m3-ko` | `/slot3/v1/embeddings` |
| Slot4 | Reranker | `ko-reranker` | `/slot4/v1/rerank` |
| Slot5 | ASR | `large-v3` | `/slot5/v1/audio/transcriptions` |
| Slot6 | TTS | `qwen3-tts-12hz-1.7b-base` | `/slot6/v1/audio/speech` |
| Slot7 | Diffusion Image Generation | `runwayml/stable-diffusion-v1-5` | `/slot7/v1/images/generations` |

Guardrails note:
- Slot1 external requests now pass through `guardrails-proxy`
- `POST /slot1/v1/chat/completions` can return guardrail block responses before the model server is called
- `GET /slot1/health` still bypasses guardrails

## 4) Parameter List (요청 파라미터)

### 4.1 Chat (`POST /slot1|2/v1/chat/completions`)

| 구분 | 파라미터 | 타입 | 비고 |
|---|---|---|---|
| 필수 | `model` | string | 서빙 모델명 |
| 필수 | `messages` | array | 대화 메시지 |
| 선택 | `max_tokens` | int | 출력 토큰 상한 |
| 선택 | `temperature` | float | 샘플링 온도 |
| 선택 | `top_p` | float | nucleus sampling |
| 선택 | `stop` | string/array | 중단 시퀀스 |
| 선택 | `stream` | bool | 스트리밍 여부 |
| 선택 | `presence_penalty` | float | 반복 억제 |
| 선택 | `frequency_penalty` | float | 빈도 패널티 |
| 선택 | `tools` | array | function tool schema 목록 |
| 선택 | `tool_choice` | string/object | `auto`, `none`, `required` 또는 특정 함수 지정 |

`messages` 구조:
- 텍스트 전용: `{"role":"user","content":"..."}`
- 멀티모달(OCR/VL):
  - 텍스트 파트: `{"type":"text","text":"..."}`
  - 이미지 파트: `{"type":"image_url","image_url":{"url":"..."}}`

Slot1 주의:
- slot1은 `Qwen/Qwen3.5-4B` 기반이며 tool calling 기본 활성화 상태
- 서버 측 기본 플래그:
  - `--reasoning-parser qwen3`
  - `--enable-auto-tool-choice`
  - `--tool-call-parser qwen3_coder`
- external slot1 경로는 가드레일 미들웨어를 먼저 통과함
- `stream=false`만 output semantic 검사 대상이고, `stream=true`는 deterministic input 검사만 적용

### 4.2 Embeddings (`POST /slot3/v1/embeddings`)

| 구분 | 파라미터 | 타입 | 비고 |
|---|---|---|---|
| 필수 | `model` | string | 서빙 모델명 |
| 필수 | `input` | string/array | 단일/배열 입력 |
| 선택 | `encoding_format` | string | 예: `float` |
| 선택 | `dimensions` | int | 모델 지원 시 |

### 4.3 Reranker (`POST /slot4/v1/rerank`)

| 구분 | 파라미터 | 타입 | 비고 |
|---|---|---|---|
| 필수 | `model` | string | 서빙 모델명 |
| 필수 | `query` | string | 질의문 |
| 필수 | `documents` | array[string] | 후보 문서 |
| 선택 | `top_n` | int | 상위 N개 |
| 선택 | `return_documents` | bool | 런타임별 상이 |

### 4.4 ASR (`POST /slot5/v1/audio/transcriptions`, multipart/form-data)

| 구분 | 파라미터 | 타입 | 비고 |
|---|---|---|---|
| 필수 | `file` | file | 오디오 파일 |
| 필수 | `model` | string | 예: `large-v3` |
| 선택 | `language` | string | 예: `ko` |
| 선택 | `prompt` | string | 힌트 문장 |
| 선택 | `response_format` | string | 예: `json` |
| 선택 | `temperature` | float | 디코딩 제어 |

### 4.5 TTS (`POST /slot6/v1/audio/speech`)

| 구분 | 파라미터 | 타입 | 비고 |
|---|---|---|---|
| 필수 | `model` | string | TTS 모델명 |
| 필수 | `input` | string | 합성할 텍스트 |
| 필수 | `response_format` | string | `wav` 권장 |
| Base 모델 필수 | `task_type` | string | `Base` |
| Base 모델 필수 | `ref_audio` | string | `data:audio/wav;base64,...` |
| Base 모델 필수 | `ref_text` | string | 참조 오디오 텍스트 |
| 선택 | `language` | string | 예: `Korean` |
| 선택 | `x_vector_only_mode` | bool | 음성 특성 모드 |

중요 제약:
- `task_type=CustomVoice`는 현재 Base 모델에서 실패

### 4.6 Diffusion (`POST /slot7/v1/images/generations`)

| 구분 | 파라미터 | 타입 | 비고 |
|---|---|---|---|
| 필수 | `prompt` | string | 생성 프롬프트 |
| 선택 | `negative_prompt` | string | 제외할 특성 |
| 선택 | `width` | int | 권장 `512`, 범위 `256~768` |
| 선택 | `height` | int | 권장 `512`, 범위 `256~768` |
| 선택 | `num_inference_steps` | int | 권장 `20`, 범위 `1~50` |
| 선택 | `guidance_scale` | float | 권장 `7.5`, 범위 `0~20` |
| 선택 | `num_images` | int | 현재 권장 `1`, 최대 `2` |
| 선택 | `seed` | int | 재현용 시드 |
| 선택 | `response_format` | string | 현재 `b64_json`만 지원 |

## 5) Response Field Spec (응답 필드)

### 5.1 Chat Completion

| 필드 | 타입 | 설명 |
|---|---|---|
| `id` | string | 요청 식별자 |
| `object` | string | `chat.completion` |
| `created` | int | unix timestamp |
| `model` | string | 모델명 |
| `choices[].index` | int | 후보 인덱스 |
| `choices[].message.role` | string | 보통 `assistant` |
| `choices[].message.content` | string | 생성 텍스트 |
| `choices[].message.tool_calls[]` | array | tool calling 결과 |
| `choices[].message.tool_calls[].function.name` | string | 호출 함수명 |
| `choices[].message.tool_calls[].function.arguments` | string(JSON) | 함수 인자 |
| `choices[].message.reasoning` | string/null | reasoning parser 활성화 시 포함될 수 있음 |
| `choices[].finish_reason` | string | 종료 사유 |
| `usage.prompt_tokens` | int | 입력 토큰 |
| `usage.completion_tokens` | int | 출력 토큰 |
| `usage.total_tokens` | int | 합계 토큰 |

### 5.2 Embeddings

| 필드 | 타입 | 설명 |
|---|---|---|
| `object` | string | `list` |
| `model` | string | 모델명 |
| `data[].object` | string | `embedding` |
| `data[].index` | int | 입력 인덱스 |
| `data[].embedding` | array[float] | 벡터 |
| `usage.*` | object | 토큰 사용량 |

### 5.3 Rerank

| 필드 | 타입 | 설명 |
|---|---|---|
| `id` | string | 요청 ID |
| `model` | string | 모델명 |
| `results[].index` | int | 문서 인덱스 |
| `results[].relevance_score` | float | 관련도 점수 |
| `results[].document.text` | string | 문서 텍스트 |
| `usage.*` | object | 토큰 사용량 |

### 5.4 ASR

| 필드 | 타입 | 설명 |
|---|---|---|
| `task` | string | 예: `transcribe` |
| `language` | string | 인식 언어 |
| `duration` | float | 오디오 길이(초) |
| `text` | string | 인식 결과 텍스트 |
| `model` | string | 모델명 |

### 5.5 TTS

성공:
- 바이너리 오디오 바디 (WAV 권장)
- WAV 시그니처: 바디 시작 바이트 `RIFF`

실패(중요):
- HTTP 200이어도 JSON 에러 바디가 올 수 있음

| 필드 | 타입 | 설명 |
|---|---|---|
| `error.message` | string | 에러 상세 |
| `error.type` | string | 에러 타입 |
| `error.code` | int/string | 에러 코드 |

### 5.6 Diffusion

| 필드 | 타입 | 설명 |
|---|---|---|
| `created` | int | unix timestamp |
| `model` | string | 모델명 |
| `data[].b64_json` | string | base64 인코딩 PNG |

## 6) Error List (수집된 오류 유형)

### 6.1 인증/접근

| 코드/패턴 | 원인 | 조치 |
|---|---|---|
| `401 Unauthorized` | `X-API-Key` 누락/오류 | 키 확인 및 재전송 |

### 6.2 OCR/VL (slot2)

| 코드/패턴 | 대표 메시지 | 원인 | 조치 |
|---|---|---|---|
| `400 BadRequestError` | `decoder prompt ... longer than maximum model length` | 이미지 토큰 과다 | 리사이즈 후 재전송 |
| `500 InternalServerError` | `403 Forbidden` / `404 Not Found` | 외부 URL fetch 실패 | 접근 가능한 URL 또는 data URL 사용 |

### 6.3 TTS (slot6)

| 코드/패턴 | 대표 메시지 | 원인 | 조치 |
|---|---|---|---|
| `400 BadRequestError` | `Base task requires 'ref_audio'` | Base 필수 파라미터 누락 | `task_type=Base`, `ref_audio`, `ref_text` 추가 |
| `400 BadRequestError` | `does not support generate_custom_voice` | Base 모델에 `CustomVoice` 사용 | `task_type=Base`로 변경 |
| `200 + error JSON` | `EngineCore encountered an issue` | 내부 엔진 오류 | payload 내 `error` 검사, 재기동/튜닝 |
| `502 Bad Gateway` | nginx 502 | upstream 비정상/재시작 중 | slot6 상태/로그 확인 후 재기동 |

### 6.4 ASR (slot5)

| 코드/패턴 | 원인 | 조치 |
|---|---|---|
| `500 Internal Server Error` | 파일 포맷/파라미터 문제 가능 | WAV 입력으로 재검증 |

### 6.5 Chat/Tool Calling (slot1)

| 코드/패턴 | 대표 메시지 | 원인 | 조치 |
|---|---|---|---|
| `400 invalid_request_error` | `Blocked by guardrails: ...` | deterministic blocklist / malformed input / prompt injection / rate limit | `error.code` 확인 후 요청 수정 |
| `400 invalid_request_error` | `... code=BLOCKLIST_MATCH` | 차단어 매칭 | 프롬프트 수정 |
| `400 invalid_request_error` | `... code=PROMPT_INJECTION_PATTERN` | 프롬프트 인젝션 규칙 매칭 | 시스템 탈출 지시 제거 |
| `400 invalid_request_error` | `... code=INPUT_TOO_LONG` | Guardrails 입력 길이 초과 | 입력 축소 또는 chunking |
| `400 invalid_request_error` | `... code=RATE_LIMITED` | API key 기준 단기 burst 초과 | 잠시 후 재시도 |
| `400 Bad Request` | tool schema validation error | `tools[].function.parameters` 구조 오류 | JSON Schema 구조 재검증 |
| `200 + empty tool_calls` | 함수 호출이 안 나옴 | `tool_choice` 누락 또는 프롬프트 불충분 | `tool_choice=required` 또는 명시적 지시 사용 |
| `200 + reasoning field visible` | 응답 본문에 reasoning 포함 | server-side reasoning parser 활성화 | downstream 파서에서 무시 또는 별도 처리 |

### 6.6 Diffusion (slot7)

| 코드/패턴 | 대표 메시지 | 원인 | 조치 |
|---|---|---|---|
| `503 Service Unavailable` | `Model not ready: ...` | 모델 로드 실패/초기화 중 | `/slot7/health` 확인 후 재시도 |
| `422 Unprocessable Entity` | pydantic validation error | width/height/steps 범위 오류 | 허용 범위로 조정 |
| `500 Internal Server Error` | CUDA / pipeline runtime error | VRAM 부족 또는 모델 런타임 이슈 | 해상도/steps 축소, 서버 로그 확인 |

## 7) Slot2 OCR Example (권장)

`MAX_MODEL_LEN_2=768` 제약을 피하기 위해 리사이즈 + data URL 사용.

```bash
BASE="https://higher-finds-vic-instances.trycloudflare.com"
KEY="<PROXY_API_KEY>"
IMG_URL="https://huggingface.co/datasets/huggingface/documentation-images/resolve/main/blog/112_document_ai/donut.png"

curl -L -sS "$IMG_URL" -o /tmp/ocr_src.png
ffmpeg -y -i /tmp/ocr_src.png -vf scale=320:-1 /tmp/ocr_small.png >/dev/null 2>&1
B64=$(base64 < /tmp/ocr_small.png | tr -d '\n')

curl -sS "$BASE/slot2/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $KEY" \
  -d "{
    \"model\": \"qwen3-vl-8b-instruct\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\", \"text\": \"이미지 OCR 결과를 핵심 필드 중심으로 요약해줘.\"},
        {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/png;base64,$B64\"}}
      ]
    }],
    \"max_tokens\": 180
  }"
```

## 8) Health Check

```bash
BASE="https://higher-finds-vic-instances.trycloudflare.com"
KEY="<PROXY_API_KEY>"

for s in 1 2 3 4 5 6 7; do
  curl -sS -o /dev/null -w "slot${s} health: %{http_code}\n" \
    "$BASE/slot${s}/health" \
    -H "X-API-Key: $KEY"
done
```

## 9) Slot1 Tool Calling Example

```bash
BASE="https://higher-finds-vic-instances.trycloudflare.com"
KEY="<PROXY_API_KEY>"

curl -sS "$BASE/slot1/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $KEY" \
  -d '{
    "model": "qwen3.5-4b",
    "messages": [
      {"role": "user", "content": "서울 날씨를 조회하고 요약해줘."}
    ],
    "tools": [
      {
        "type": "function",
        "function": {
          "name": "get_weather",
          "description": "Return current weather by city name",
          "parameters": {
            "type": "object",
            "properties": {
              "city": {"type": "string"}
            },
            "required": ["city"]
          }
        }
      }
    ],
    "tool_choice": "required",
    "max_tokens": 256
  }'
```

성공 시 확인 포인트:
- `choices[0].message.tool_calls[0].function.name == "get_weather"`
- `choices[0].message.tool_calls[0].function.arguments`에 `서울` 포함

## 10) Slot7 Diffusion Example

```bash
BASE="https://higher-finds-vic-instances.trycloudflare.com"
KEY="<PROXY_API_KEY>"

curl -sS "$BASE/slot7/v1/images/generations" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $KEY" \
  -d '{
    "prompt": "a small robot reading a book, clean illustration",
    "negative_prompt": "blurry, low-quality, distorted",
    "width": 512,
    "height": 512,
    "num_inference_steps": 20,
    "guidance_scale": 7.5,
    "num_images": 1
  }'
```

성공 시 확인 포인트:
- `data[0].b64_json` 존재
- base64 decode 후 PNG 열기 가능
## 11) 운영 체크리스트

1. tunnel URL 유효성 확인
2. API key 유효성 확인
3. `slot*/health` 200 확인
4. slot1은 tool calling 응답에서 `tool_calls` 파싱 확인
5. slot2 OCR은 리사이즈 이미지로 테스트
6. slot6 TTS는 `task_type=Base` 규격 유지
7. TTS는 HTTP 코드 + JSON error 여부 + WAV 시그니처를 함께 점검
8. slot7 diffusion은 우선 `512x512`, `20 steps`, `num_images=1`로 검증
