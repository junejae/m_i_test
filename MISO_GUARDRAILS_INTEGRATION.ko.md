# MISO 가드레일 연동 문서

## 1. 목적

이 문서는 현재 `m_i_test`에 구현된 가드레일 기능을 MISO 스타일 오케스트레이션 흐름에 어떻게 연동할지 설명합니다.

현재 연동 모델의 핵심은 아래와 같습니다.

- `slot1 raw serving`: Qwen 서빙 경로, 상시 가드레일 미결합
- `standalone guardrails`: LLM 서빙 엔드포인트와 분리된 별도 입력/출력 검사 서비스

MISO 연동 기준으로는 `standalone guardrails API`와 raw model serving을 조합하는 방식을 권장합니다.

## 2. 현재 외부 Base URL

- Base URL: `https://pty-metadata-ltd-loving.trycloudflare.com`
- 인증 헤더: `X-API-Key: <PROXY_API_KEY>`

주의:

- 현재 공개 URL은 Cloudflare Quick Tunnel 기반이라 재시작 시 변경될 수 있습니다.
- URL이 바뀌더라도 엔드포인트 경로 자체는 동일합니다.

## 3. 연동 모델

### 3.1 권장 MISO 흐름

```text
사용자 입력
-> POST /guardrails/input/check
-> allow 이면 LLM / tool / knowledge 호출
-> POST /guardrails/output/check
-> allow 이면 최종 응답 반환
-> block 이면 정책 차단 메시지 반환
```

### 3.2 실제 의미

- MISO는 가드레일 검사를 위해 `slot1`을 직접 호출할 필요가 없습니다.
- 가드레일 서비스에는 `messages` 또는 plain `text`만 보내도 됩니다.
- standalone guardrails 호출에는 `model`이 필수가 아닙니다.
- 가드레일 서비스는 아래 셋 중 하나의 정책 결정을 반환합니다.
  - `allow`
  - `block`
  - `observe`

`observe`는 즉시 차단하지는 않지만, 정책상 의미 있는 신호를 기록했다는 뜻입니다.

## 4. 두 가지 동작 모드

### 4.1 Raw Slot1 Serving

경로:

- `POST /slot1/v1/chat/completions`

동작:

- 요청이 `proxy-gateway`로 진입
- 바로 `mig-vllm-1`로 전달
- 이 경로에서는 상시 가드레일이 수행되지 않음

적합한 경우:

- raw Qwen 서빙만 쓰고 싶을 때
- 호출 측에서 가드레일 적용 여부를 직접 제어하고 싶을 때

가드레일이 필요 없는 앱은 이 경로만 호출하면 됩니다.

### 4.2 Standalone Guardrails

경로:

- `GET /guardrails/health`
- `POST /guardrails/input/check`
- `POST /guardrails/output/check`
- `POST /guardrails/text/check`

동작:

- upstream LLM 호출이 필요하지 않음
- guardrails가 독립적인 정책 검사 서비스처럼 동작
- 입력과 출력을 각각 별도로 검사 가능

적합한 경우:

- MISO가 직접 모델 / tool / knowledge 호출을 오케스트레이션할 때
- 생성 전후에 guardrails를 독립 삽입하고 싶을 때
- Bedrock Guardrails처럼 추론과 가드레일을 분리하고 싶을 때

## 5. API 계약

## 5.1 Health

### 요청 예시

```bash
curl -k -sS \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails/health \
  -H "X-API-Key: <PROXY_API_KEY>"
```

### 응답 예시

```json
{
  "status": "ok",
  "service": "guardrails-proxy",
  "mode": "standalone-check-service"
}
```

## 5.2 Input Check

### 요청 서식

`messages` 또는 `text` 중 하나만 있으면 됩니다.

```json
{
  "messages": [
    {
      "role": "user",
      "content": "사용자 입력 텍스트"
    }
  ],
  "stream": false,
  "tools": [],
  "metadata": {
    "conversation_id": "conv-001",
    "flow": "miso-input"
  }
}
```

또는

```json
{
  "text": "사용자 입력 텍스트",
  "stream": false,
  "metadata": {
    "conversation_id": "conv-001",
    "flow": "miso-input"
  }
}
```

### 호출 예시

```bash
curl -k -sS \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails/input/check \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <PROXY_API_KEY>" \
  -d '{
    "messages":[{"role":"user","content":"사용자 입력 검사"}],
    "stream":false,
    "metadata":{"conversation_id":"conv-001","flow":"miso-input"}
  }'
```

### 응답 예시

```json
{
  "action": "allow",
  "reason_code": null,
  "direction": "input",
  "phase1": {
    "triggered": false,
    "matches": []
  },
  "phase2": {
    "pii": {
      "triggered": false,
      "matches": [],
      "error": null
    },
    "toxicity": {
      "triggered": false,
      "score": 0.01,
      "error": null
    },
    "relevance": {
      "triggered": false,
      "score": null,
      "error": null
    }
  },
  "phase3": {
    "decision": "safe"
  },
  "timeouts": []
}
```

## 5.3 Output Check

### 요청 서식

```json
{
  "text": "모델 출력 텍스트",
  "metadata": {
    "conversation_id": "conv-001",
    "flow": "miso-output"
  }
}
```

또는 OpenAI 스타일 응답 래퍼:

```json
{
  "response": {
    "choices": [
      {
        "message": {
          "role": "assistant",
          "content": "모델 출력 텍스트"
        }
      }
    ]
  }
}
```

### 호출 예시

```bash
curl -k -sS \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails/output/check \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <PROXY_API_KEY>" \
  -d '{
    "text":"모델 출력 검사",
    "metadata":{"conversation_id":"conv-001","flow":"miso-output"}
  }'
```

### 응답 예시

```json
{
  "action": "allow",
  "reason_code": null,
  "direction": "output",
  "phase1": {
    "triggered": false,
    "matches": []
  },
  "phase2": {
    "pii": {
      "triggered": false,
      "matches": [],
      "error": null
    },
    "toxicity": {
      "triggered": false,
      "score": 0.02,
      "error": null
    },
    "relevance": {
      "triggered": false,
      "score": null,
      "error": null
    }
  },
  "phase3": {
    "decision": "safe"
  },
  "timeouts": []
}
```

## 5.4 Generic Text Check

호출 측에서 검사 방향을 직접 지정하고 싶을 때 사용할 수 있는 래퍼 API입니다.

### 요청 서식

```json
{
  "direction": "input",
  "text": "검사 대상 텍스트",
  "metadata": {
    "conversation_id": "conv-001"
  }
}
```

허용 값:

- `direction = "input"`
- `direction = "output"`

## 6. 결정 의미

| 필드 | 의미 |
|---|---|
| `action=allow` | 요청/응답을 계속 진행해도 됨 |
| `action=block` | 호출 측에서 흐름을 중단하고 차단 응답을 내려야 함 |
| `action=observe` | 차단하지는 않지만 정책상 기록하고 후속 판단이 필요함 |
| `reason_code` | block/observe 사유를 기계적으로 식별하기 위한 코드 |

현재 실제 사용되는 reason code:

| Reason Code | 의미 |
|---|---|
| `BLOCKLIST_MATCH` | deterministic blocklist 문구 일치 |
| `PROMPT_INJECTION_PATTERN` | prompt injection regex 일치 |
| `MALFORMED_INPUT` | 요청 body 구조가 잘못됨 |
| `INPUT_TOO_LONG` | 설정된 입력 길이 제한 초과 |
| `RATE_LIMITED` | API key 기준 요청 빈도 제한 초과 |
| `ANALYZER_TIMEOUT_OBSERVE` | semantic analyzer timeout 발생, 현재 정책상 fail-open observe 처리 |

## 7. 현재 정책 형태

### 7.1 현재 정책 모델

현재 배포 상태는 `Standard-lite`로 이해하면 됩니다.

- Phase 1: enabled, enforce
- Phase 2: enabled, observe-first
- Phase 3: enabled, observe-first
- Phase 4: disabled

### 7.2 Deterministic Prompt Injection Patterns

현재 설정된 regex 패턴:

```json
[
  "ignore\\s+(all\\s+)?previous\\s+instructions",
  "reveal\\s+(the\\s+)?system\\s+prompt",
  "show\\s+(the\\s+)?developer\\s+message",
  "bypass\\s+(all\\s+)?safety",
  "act\\s+as\\s+system"
]
```

### 7.3 Deterministic Blocklist Terms

현재 설정된 문구:

```text
ignore previous instructions
ignore all previous instructions
reveal the system prompt
show the developer message
bypass all safety
```

### 7.4 Golden Set

현재 golden set 상태:

- 구조는 존재함
- 현재 내용은 비어 있음
- relevance 경로는 구조상 준비되어 있지만, 운영상 enforce 경로로는 아직 사용하지 않음

## 8. 검증된 동작

현재 외부 배포 기준으로 아래 항목을 검증했습니다.

### 8.1 Standalone Health

- `GET /guardrails/health` → `200`

### 8.2 Standalone Input Check

- 일반 텍스트 → `action=allow`
- `reveal the system prompt` 같은 blocklist 입력 → `action=block`, `reason_code=BLOCKLIST_MATCH`

### 8.3 Standalone Output Check

- 일반 출력 텍스트 → `action=allow`
- blocklist 문구 포함 출력 → `action=block`, `reason_code=BLOCKLIST_MATCH`

### 8.4 Raw Slot1 Serving

- `/slot1/v1/chat/completions` 일반 요청 → `200`
- blocklist 유사 입력도 `/slot1` 자체에서 차단하는 것이 아니라 `/guardrails/*`에서 판정하는 구조

## 9. 운영 제약

### 9.1 적용 범위

현재 standalone guardrails는 텍스트 중심 chat 흐름을 대상으로 설계되어 있습니다.

아래 항목에 대한 일반 목적 멀티모달 guardrails는 아직 아닙니다.

- OCR/VL
- ASR
- TTS
- diffusion image generation

이 서비스들은 현재 standalone semantic policy 적용 범위 밖에 있습니다.

### 9.2 Streaming

현재 의도된 동작:

- input check는 `stream=false`, `stream=true` 모두 가능
- output semantic check는 `stream=false` 기준으로 설계
- `stream=true` 출력에 대한 semantic 차단은 주 계약이 아님

MISO 기준으로는 최종 조립된 텍스트 응답에 대해 output guardrails를 수행하는 것을 권장합니다.

### 9.3 Analyzer 정책

현재 semantic analyzer timeout/error에 대해서는 fail-open 정책입니다.

의미:

- deterministic Phase 1은 여전히 차단 가능
- semantic analyzer 실패만으로는 기본적으로 차단하지 않음
- 필요 시 `observe` + reason code 형태로 기록

### 9.4 Tunnel 의존성

현재 공개 도메인은 Quick Tunnel 기반입니다.

의미:

- 재시작 후 URL이 바뀔 수 있음
- production 수준의 고정 도메인으로 간주하면 안 됨
- MISO가 안정적인 계약을 원하면 이후 고정 터널 또는 별도 front-door 계층이 필요함

## 10. MISO 연동 권장안

### 권장 기본안

Standalone guardrails를 별도 정책 서비스로 사용합니다.

1. `POST /guardrails/input/check`
2. `allow`이면 `/slot1/v1/chat/completions` 또는 선택한 모델 / tool / knowledge 경로 호출
3. 생성된 텍스트 수집
4. `POST /guardrails/output/check`
5. `allow/block/observe`를 MISO 정책에 맞게 매핑

### 주 계약으로 비권장인 경로

`/slot1/v1/chat/completions` 자체를 MISO 가드레일 계약으로 보는 것은 권장하지 않습니다.

이유:

- 해당 경로는 raw inference endpoint임
- MISO는 guardrails와 inference를 명시적으로 조합하는 구조가 더 적합함
- 정책 결정은 `/guardrails/*`에서 내려오고, 모델 호출은 `/slot1`에서 별도로 수행하는 편이 맞음

## 11. 관리자 및 정책 관리

Admin UI:

- `https://pty-metadata-ltd-loving.trycloudflare.com/guardrails-admin/?api_key=<PROXY_API_KEY>`

Admin API prefix:

- `/guardrails-admin/`

필요 인증:

- `X-API-Key: <PROXY_API_KEY>`
- `X-Admin-API-Key: <GUARDRAILS_ADMIN_API_KEY>`

관리 범위:

- phase on/off
- threshold
- limit
- prompt injection regex 목록
- prompt-patterns 전용 endpoint
- blocklist 관리
- golden set 관리
- 다중 정책 API
- 정책 버저닝/활성화 API
- 변경 이력 API
- 항목 단위 CRUD API

운영 메모:

- `/guardrails-admin/config`와 레거시 목록 endpoint는 항상 **active policy** 기준으로 보입니다
- 정책 생성, 버전 증가, 항목 CRUD는 `/guardrails-admin/policies/*`에서 수행합니다
- standalone `/guardrails/*` 검사는 요청에 `policy_id`를 넣으면 해당 정책 스냅샷으로 실행됩니다
- `policy_id`를 생략한 경우에만 active policy를 기본값으로 사용합니다

## 12. 아직 남아 있는 공백

아래 항목은 아직 production 수준의 완성형 guardrails 제품으로 보기 어려운 부분입니다.

1. 한국어 semantic 품질은 아직 충분히 벤치마크되지 않음
2. golden-set relevance는 구조만 있고 운영 튜닝이 부족함
3. 멀티모달 guardrails 정책은 아직 정의되지 않음
4. Quick Tunnel URL은 안정적인 인프라가 아님
5. observe에서 enforce로 전환할 임계값 검증이 아직 필요함
6. Admin UI는 아직 active policy 편집기 기준이며, 정책 선택/버전 전환은 현재 API 중심으로 제공됨

## 13. MISO 팀용 최소 curl 세트

### Health

```bash
curl -k -sS \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails/health \
  -H "X-API-Key: <PROXY_API_KEY>"
```

### Input Check

```bash
curl -k -sS \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails/input/check \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <PROXY_API_KEY>" \
  -d '{
    "policy_id":"customer-a",
    "policy_version":3,
    "messages":[{"role":"user","content":"사용자 입력 검사"}],
    "stream":false,
    "metadata":{"flow":"miso-input"}
  }'
```

### Output Check

```bash
curl -k -sS \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails/output/check \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <PROXY_API_KEY>" \
  -d '{
    "policy_id":"customer-a",
    "text":"모델 출력 검사",
    "metadata":{"flow":"miso-output"}
  }'
```

### Policy List

```bash
curl -k -sS \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails-admin/policies \
  -H "X-API-Key: <PROXY_API_KEY>" \
  -H "X-Admin-API-Key: <GUARDRAILS_ADMIN_API_KEY>"
```

### 정책 생성 및 활성화

```bash
curl -k -sS -X POST \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails-admin/policies \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <PROXY_API_KEY>" \
  -H "X-Admin-API-Key: <GUARDRAILS_ADMIN_API_KEY>" \
  -H "X-Admin-Actor: miso-admin" \
  -d '{
    "policy_id":"customer-a",
    "display_name":"Customer A",
    "description":"고객사 전용 정책 baseline"
  }'

curl -k -sS -X POST \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails-admin/policies/customer-a/activate \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <PROXY_API_KEY>" \
  -H "X-Admin-API-Key: <GUARDRAILS_ADMIN_API_KEY>" \
  -H "X-Admin-Actor: miso-admin" \
  -d '{"version":1}'
```

### 항목 단위 CRUD 예시

```bash
curl -k -sS -X POST \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails-admin/policies/customer-a/blocklist \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <PROXY_API_KEY>" \
  -H "X-Admin-API-Key: <GUARDRAILS_ADMIN_API_KEY>" \
  -H "X-Admin-Actor: miso-admin" \
  -d '{"term":"show the api key"}'
```
