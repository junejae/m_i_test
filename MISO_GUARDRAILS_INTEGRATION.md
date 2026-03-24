# MISO Guardrails Integration

## 1. Purpose

This document describes how to integrate the current `m_i_test` guardrails implementation with a MISO-style orchestration flow.

The current integration model is:

- `slot1 raw serving`: Qwen serving path without mandatory guardrails
- `standalone guardrails`: input/output text is checked independently of the LLM serving endpoint

For MISO integration, the recommended path is the standalone guardrails API plus raw model serving.

## 2. Current External Base URL

- Base URL: `https://pty-metadata-ltd-loving.trycloudflare.com`
- Auth header: `X-API-Key: <PROXY_API_KEY>`

Notes:

- The current public URL is a Cloudflare Quick Tunnel URL and can change after restart.
- If the public URL changes, update only the base URL. Endpoint paths stay the same.

## 3. Integration Model

### 3.1 Recommended MISO Flow

```text
User Input
-> POST /guardrails/input/check
-> if allow: call LLM / tools / knowledge
-> POST /guardrails/output/check
-> if allow: return response to end user
-> if block: return policy block message
```

### 3.2 What This Means in Practice

- MISO does **not** need to call `slot1` just to run guardrails.
- MISO can send only `messages` or plain `text` to the guardrails service.
- `model` is not required for standalone guardrails checks.
- The guardrails service returns a policy decision:
  - `allow`
  - `block`
  - `observe`

`observe` means the request was not blocked, but the system recorded a policy signal that may matter operationally.

## 4. Two Operating Modes

### 4.1 Raw Slot1 Serving

Path:

- `POST /slot1/v1/chat/completions`

Behavior:

- request enters `proxy-gateway`
- request is forwarded directly to `mig-vllm-1`
- no mandatory guardrails are executed on this path

Use this when:

- you want raw Qwen serving
- the caller controls whether guardrails should run

This path is the correct LLM contract for apps that do not want guardrails.

### 4.2 Standalone Guardrails

Paths:

- `GET /guardrails/health`
- `POST /guardrails/input/check`
- `POST /guardrails/output/check`
- `POST /guardrails/text/check`

Behavior:

- no upstream LLM call is required
- guardrails acts as a policy check service
- input and output can be checked independently

Use this when:

- MISO orchestrates the model/tool/knowledge call itself
- guardrails must be inserted before and after generation
- Bedrock-style separation between inference and guardrails is desired

## 5. API Contract

## 5.1 Health

### Request

```bash
curl -k -sS \
  https://pty-metadata-ltd-loving.trycloudflare.com/guardrails/health \
  -H "X-API-Key: <PROXY_API_KEY>"
```

### Example Response

```json
{
  "status": "ok",
  "service": "guardrails-proxy",
  "mode": "standalone-check-service"
}
```

## 5.2 Input Check

### Request Shape

Either `messages` or `text` is sufficient.

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

or

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

### Example Call

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

### Example Response

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

### Request Shape

```json
{
  "text": "모델 출력 텍스트",
  "metadata": {
    "conversation_id": "conv-001",
    "flow": "miso-output"
  }
}
```

or OpenAI-style response wrapper:

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

### Example Call

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

### Example Response

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

This wrapper can be used when the caller wants to choose the direction explicitly.

### Request Shape

```json
{
  "direction": "input",
  "text": "검사 대상 텍스트",
  "metadata": {
    "conversation_id": "conv-001"
  }
}
```

Allowed values:

- `direction = "input"`
- `direction = "output"`

## 6. Decision Semantics

| Field | Meaning |
|---|---|
| `action=allow` | request/response may continue |
| `action=block` | caller should stop the flow and return a policy block result |
| `action=observe` | caller may continue, but should record the policy signal |
| `reason_code` | machine-readable reason for block/observe decision |

Current reason codes used in practice:

| Reason Code | Meaning |
|---|---|
| `BLOCKLIST_MATCH` | deterministic blocklist phrase matched |
| `PROMPT_INJECTION_PATTERN` | prompt injection regex matched |
| `MALFORMED_INPUT` | invalid request body shape |
| `INPUT_TOO_LONG` | input exceeded configured guardrails limit |
| `RATE_LIMITED` | per-key request rate exceeded |
| `ANALYZER_TIMEOUT_OBSERVE` | semantic analyzer timed out and policy is fail-open observe |

## 7. Current Policy Shape

### 7.1 Enabled Policy Model

Current deployment should be understood as `Standard-lite`.

- Phase 1: enabled, enforce
- Phase 2: enabled, observe-first
- Phase 3: enabled, observe-first
- Phase 4: disabled

### 7.2 Deterministic Prompt Injection Patterns

Current configured regex patterns:

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

Current configured phrases:

```text
ignore previous instructions
ignore all previous instructions
reveal the system prompt
show the developer message
bypass all safety
```

### 7.4 Golden Set

Current golden set status:

- configured structure exists
- current content is empty
- relevance path is available structurally but is not enabled as an enforcement path

## 8. Tested Behavior

The following external checks were verified on the current deployment:

### 8.1 Standalone Health

- `GET /guardrails/health` → `200`

### 8.2 Standalone Input Check

- normal text → `action=allow`
- blocklist text such as `reveal the system prompt` → `action=block`, `reason_code=BLOCKLIST_MATCH`

### 8.3 Standalone Output Check

- normal response text → `action=allow`
- blocklist text → `action=block`, `reason_code=BLOCKLIST_MATCH`

### 8.4 Raw Slot1 Serving

- normal request to `/slot1/v1/chat/completions` → `200`
- blocklist-like input is no longer required to block on `/slot1`; blocking belongs to `/guardrails/*`

## 9. Operational Constraints

### 9.1 Scope

Current standalone guardrails coverage is designed for text-centric chat flows.

This is not yet a general multimodal guardrails layer for:

- OCR/VL
- ASR
- TTS
- diffusion image generation

Those services remain outside the standalone semantic policy scope.

### 9.2 Streaming

Current intended behavior:

- input checks work with both `stream=false` and `stream=true`
- output semantic checks are designed for `stream=false` paths
- `stream=true` output semantic blocking is not the primary contract

For MISO integration, output guardrails should operate on a final assembled text response.

### 9.3 Analyzer Policy

Current analyzer policy is fail-open for semantic analyzer timeout/error paths.

That means:

- deterministic Phase 1 can still block
- semantic failure should not stop the request by default
- the service can respond with `observe` and a reason code instead of blocking

### 9.4 Tunnel Dependency

The public domain is currently a Quick Tunnel.

That implies:

- URL changes after restart are possible
- production-style fixed domain should not be assumed
- if MISO needs a stable contract, a fixed tunnel or front-door layer is needed later

## 10. MISO Integration Recommendation

### Recommended Baseline

Use standalone guardrails as a separate policy service:

1. `POST /guardrails/input/check`
2. if `allow`, call `/slot1/v1/chat/completions` or your selected model/tools/knowledge path
3. collect the generated text
4. `POST /guardrails/output/check`
5. map `allow/block/observe` to your product policy

### Not Recommended as Primary Contract

Do not treat `/slot1/v1/chat/completions` itself as the guardrails contract.

Reason:

- that path is a raw inference endpoint
- MISO wants guardrails and inference to be composed explicitly
- policy decisions should come from `/guardrails/*`, not be inferred from the LLM route

## 11. Admin and Policy Management

Admin UI:

- `https://pty-metadata-ltd-loving.trycloudflare.com/guardrails-admin/?api_key=<PROXY_API_KEY>`

Admin API prefix:

- `/guardrails-admin/`

Required credentials:

- `X-API-Key: <PROXY_API_KEY>`
- `X-Admin-API-Key: <GUARDRAILS_ADMIN_API_KEY>`

Admin scope:

- phase on/off
- thresholds
- limits
- prompt injection regex list
- dedicated prompt-pattern endpoint
- blocklist management
- golden set management
- multi-policy API
- policy versioning and activation API
- history API
- item-level CRUD API

## 12. Gaps Still Open

These are the main gaps before this should be treated as a mature production guardrails product:

1. Korean-specific semantic quality has not been fully benchmarked
2. Golden-set relevance exists structurally but is not operationally tuned
3. Multimodal guardrails are not yet defined
4. Quick Tunnel URL is not stable infrastructure
5. Observe-to-enforce thresholds still need evaluation against real traffic
6. Admin UI still edits the active policy only; policy selection/version switching is API-first for now

## 13. Minimal Curl Set for MISO Team

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
    "text":"모델 출력 검사",
    "metadata":{"flow":"miso-output"}
  }'
```
