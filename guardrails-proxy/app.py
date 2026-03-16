import asyncio
import json
import logging
import os
import re
import time
import unicodedata
import uuid
from collections import Counter, defaultdict, deque
from dataclasses import dataclass, field
from pathlib import Path
from threading import Lock
from typing import Any, Optional

import httpx
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, Response, StreamingResponse

try:
    import ahocorasick  # type: ignore
except ImportError:  # pragma: no cover
    ahocorasick = None

try:
    from presidio_analyzer import AnalyzerEngine, Pattern, PatternRecognizer, RecognizerRegistry  # type: ignore
except ImportError:  # pragma: no cover
    AnalyzerEngine = None
    Pattern = None
    PatternRecognizer = None
    RecognizerRegistry = None

try:
    from detoxify import Detoxify  # type: ignore
except ImportError:  # pragma: no cover
    Detoxify = None

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("guardrails-proxy")

MUTABLE_SETTING_FIELDS = {
    "analyzer_timeout_seconds",
    "phase1_enabled",
    "phase2_enabled",
    "phase3_enabled",
    "phase4_enabled",
    "phase2_mode",
    "phase3_mode",
    "fail_open_on_analyzer_timeout",
    "output_semantic_non_stream_only",
    "relevance_enabled",
    "toxicity_enabled",
    "pii_enabled",
    "max_input_chars",
    "max_stream_input_chars",
    "max_tool_count",
    "max_message_count",
    "max_non_stream_output_chars",
    "rate_limit_window_seconds",
    "rate_limit_max_requests",
    "output_blocklist_enforce",
    "toxicity_safe_threshold",
    "toxicity_danger_threshold",
    "relevance_safe_threshold",
}


@dataclass
class GuardrailsSettings:
    upstream_base_url: str = os.getenv("GUARDRAILS_UPSTREAM_BASE_URL", "http://mig-vllm-1:8000")
    embeddings_base_url: str = os.getenv("GUARDRAILS_EMBEDDINGS_BASE_URL", "http://mig-vllm-3:8000")
    served_model_name: str = os.getenv("GUARDRAILS_SERVED_MODEL_NAME", os.getenv("SERVED_MODEL_NAME_1", "qwen3.5-4b"))
    request_timeout_seconds: float = float(os.getenv("GUARDRAILS_REQUEST_TIMEOUT_SECONDS", "300"))
    analyzer_timeout_seconds: float = float(os.getenv("GUARDRAILS_ANALYZER_TIMEOUT_SECONDS", "1.5"))
    phase1_enabled: bool = os.getenv("GUARDRAILS_PHASE1_ENABLED", "1") == "1"
    phase2_enabled: bool = os.getenv("GUARDRAILS_PHASE2_ENABLED", "1") == "1"
    phase3_enabled: bool = os.getenv("GUARDRAILS_PHASE3_ENABLED", "1") == "1"
    phase4_enabled: bool = os.getenv("GUARDRAILS_PHASE4_ENABLED", "0") == "1"
    phase2_mode: str = os.getenv("GUARDRAILS_PHASE2_MODE", "observe")
    phase3_mode: str = os.getenv("GUARDRAILS_PHASE3_MODE", "observe")
    fail_open_on_analyzer_timeout: bool = os.getenv("GUARDRAILS_FAIL_OPEN_ON_ANALYZER_TIMEOUT", "1") == "1"
    output_semantic_non_stream_only: bool = os.getenv("GUARDRAILS_OUTPUT_SEMANTIC_NON_STREAM_ONLY", "1") == "1"
    relevance_enabled: bool = os.getenv("GUARDRAILS_RELEVANCE_ENABLED", "0") == "1"
    toxicity_enabled: bool = os.getenv("GUARDRAILS_TOXICITY_ENABLED", "1") == "1"
    pii_enabled: bool = os.getenv("GUARDRAILS_PII_ENABLED", "1") == "1"
    blocklist_path: str = os.getenv("GUARDRAILS_BLOCKLIST_PATH", "/app/config/blocklist.txt")
    config_path: str = os.getenv("GUARDRAILS_CONFIG_PATH", "/app/config/policy.json")
    golden_set_path: str = os.getenv("GUARDRAILS_GOLDEN_SET_PATH", "/app/config/golden_set.json")
    max_input_chars: int = int(os.getenv("GUARDRAILS_MAX_INPUT_CHARS", "12000"))
    max_stream_input_chars: int = int(os.getenv("GUARDRAILS_MAX_STREAM_INPUT_CHARS", "6000"))
    max_tool_count: int = int(os.getenv("GUARDRAILS_MAX_TOOL_COUNT", "8"))
    max_message_count: int = int(os.getenv("GUARDRAILS_MAX_MESSAGE_COUNT", "64"))
    max_non_stream_output_chars: int = int(os.getenv("GUARDRAILS_MAX_NON_STREAM_OUTPUT_CHARS", "12000"))
    rate_limit_window_seconds: int = int(os.getenv("GUARDRAILS_RATE_LIMIT_WINDOW_SECONDS", "60"))
    rate_limit_max_requests: int = int(os.getenv("GUARDRAILS_RATE_LIMIT_MAX_REQUESTS", "30"))
    output_blocklist_enforce: bool = os.getenv("GUARDRAILS_OUTPUT_BLOCKLIST_ENFORCE", "1") == "1"
    toxicity_safe_threshold: float = float(os.getenv("GUARDRAILS_TOXICITY_SAFE_THRESHOLD", "0.3"))
    toxicity_danger_threshold: float = float(os.getenv("GUARDRAILS_TOXICITY_DANGER_THRESHOLD", "0.7"))
    relevance_safe_threshold: float = float(os.getenv("GUARDRAILS_RELEVANCE_SAFE_THRESHOLD", "0.5"))
    metrics_enabled: bool = os.getenv("GUARDRAILS_METRICS_ENABLED", "1") == "1"
    admin_api_key: str = os.getenv("GUARDRAILS_ADMIN_API_KEY", "")
    admin_ui_enabled: bool = os.getenv("GUARDRAILS_ADMIN_UI_ENABLED", "1") == "1"

    def admin_settings_payload(self) -> dict[str, Any]:
        return {field_name: getattr(self, field_name) for field_name in sorted(MUTABLE_SETTING_FIELDS)}


@dataclass
class MetricsStore:
    request_count: int = 0
    blocked_count: Counter = field(default_factory=Counter)
    phase_hits: Counter = field(default_factory=Counter)
    final_actions: Counter = field(default_factory=Counter)
    gray_count: int = 0
    analyzer_timeouts: int = 0
    analyzer_latency_ms_sum: Counter = field(default_factory=Counter)
    analyzer_latency_ms_count: Counter = field(default_factory=Counter)
    rate_limit_hits: int = 0
    lock: Lock = field(default_factory=Lock)

    def inc_request(self) -> None:
        with self.lock:
            self.request_count += 1

    def inc_block(self, reason_code: str) -> None:
        with self.lock:
            self.blocked_count[reason_code] += 1

    def inc_phase(self, phase: str) -> None:
        with self.lock:
            self.phase_hits[phase] += 1

    def inc_action(self, action: str) -> None:
        with self.lock:
            self.final_actions[action] += 1
            if action == "gray":
                self.gray_count += 1

    def inc_timeout(self) -> None:
        with self.lock:
            self.analyzer_timeouts += 1

    def observe_latency(self, name: str, latency_ms: float) -> None:
        with self.lock:
            self.analyzer_latency_ms_sum[name] += latency_ms
            self.analyzer_latency_ms_count[name] += 1

    def inc_rate_limit(self) -> None:
        with self.lock:
            self.rate_limit_hits += 1

    def render_prometheus(self) -> str:
        lines = [
            "# TYPE guardrails_requests_total counter",
            f"guardrails_requests_total {self.request_count}",
            "# TYPE guardrails_blocks_total counter",
        ]
        for reason, count in sorted(self.blocked_count.items()):
            lines.append(f'guardrails_blocks_total{{reason="{reason}"}} {count}')
        lines.extend([
            "# TYPE guardrails_phase_hits_total counter",
        ])
        for phase, count in sorted(self.phase_hits.items()):
            lines.append(f'guardrails_phase_hits_total{{phase="{phase}"}} {count}')
        lines.extend([
            "# TYPE guardrails_final_actions_total counter",
        ])
        for action, count in sorted(self.final_actions.items()):
            lines.append(f'guardrails_final_actions_total{{action="{action}"}} {count}')
        lines.extend([
            "# TYPE guardrails_analyzer_timeouts_total counter",
            f"guardrails_analyzer_timeouts_total {self.analyzer_timeouts}",
            "# TYPE guardrails_rate_limit_hits_total counter",
            f"guardrails_rate_limit_hits_total {self.rate_limit_hits}",
            "# TYPE guardrails_analyzer_latency_ms_avg gauge",
        ])
        for name, total in sorted(self.analyzer_latency_ms_sum.items()):
            count = self.analyzer_latency_ms_count.get(name, 0)
            avg = total / count if count else 0.0
            lines.append(f'guardrails_analyzer_latency_ms_avg{{analyzer="{name}"}} {avg:.3f}')
        return "\n".join(lines) + "\n"


class BlocklistMatcher:
    def __init__(self, terms: list[str]) -> None:
        self.terms = [term.strip() for term in terms if term.strip()]
        self.automaton: Any = None
        if ahocorasick is not None:
            automaton = ahocorasick.Automaton()
            for idx, term in enumerate(self.terms):
                automaton.add_word(term.casefold(), (idx, term))
            automaton.make_automaton()
            self.automaton = automaton

    def find_matches(self, text: str) -> list[str]:
        haystack = text.casefold()
        if self.automaton is not None:
            return sorted({term for _, (_, term) in self.automaton.iter(haystack)})
        return [term for term in self.terms if term.casefold() in haystack]


class PiiAnalyzer:
    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled and AnalyzerEngine is not None and RecognizerRegistry is not None
        self.engine: Optional[Any] = None
        self.init_error: Optional[str] = None
        if not self.enabled:
            return
        try:
            registry = RecognizerRegistry(supported_languages=["ko", "en"])
            if PatternRecognizer is not None and Pattern is not None:
                registry.add_recognizer(
                    PatternRecognizer(
                        supported_entity="KR_PHONE_NUMBER",
                        patterns=[Pattern(name="kr_phone", regex=r"(?:\+82[- ]?)?0?1[0-9][- ]?\d{3,4}[- ]?\d{4}", score=0.7)],
                        supported_language="ko",
                    )
                )
                registry.add_recognizer(
                    PatternRecognizer(
                        supported_entity="KR_RRN",
                        patterns=[Pattern(name="kr_rrn", regex=r"\b\d{6}-?[1-4]\d{6}\b", score=0.85)],
                        supported_language="ko",
                    )
                )
                registry.add_recognizer(
                    PatternRecognizer(
                        supported_entity="EMAIL_ADDRESS",
                        patterns=[Pattern(name="email", regex=r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", score=0.75)],
                        supported_language="ko",
                    )
                )
            self.engine = AnalyzerEngine(
                registry=registry,
                supported_languages=["ko", "en"],
                nlp_engine=None,
            )
        except Exception as exc:  # pragma: no cover
            self.init_error = str(exc)
            self.engine = None

    def analyze(self, text: str) -> dict[str, Any]:
        if not self.enabled:
            return {"enabled": False, "results": [], "error": self.init_error}
        if self.engine is None:
            return {"enabled": False, "results": [], "error": self.init_error or "engine_unavailable"}
        language = "ko" if re.search(r"[가-힣]", text) else "en"
        results = self.engine.analyze(text=text, language=language)
        serialized = [
            {
                "entity_type": result.entity_type,
                "start": result.start,
                "end": result.end,
                "score": float(result.score),
            }
            for result in results
        ]
        return {"enabled": True, "results": serialized, "error": None}


class ToxicityAnalyzer:
    def __init__(self, enabled: bool) -> None:
        self.enabled = enabled and Detoxify is not None
        self.model: Optional[Any] = None
        self.init_error: Optional[str] = None

    def _ensure_model(self) -> None:
        if not self.enabled or self.model is not None:
            return
        try:
            self.model = Detoxify("multilingual")
        except Exception as exc:  # pragma: no cover
            self.init_error = str(exc)
            self.enabled = False
            self.model = None

    def analyze(self, text: str) -> dict[str, Any]:
        if not self.enabled:
            return {"enabled": False, "scores": {}, "score": 0.0, "error": self.init_error}
        self._ensure_model()
        if self.model is None:
            return {"enabled": False, "scores": {}, "score": 0.0, "error": self.init_error or "model_unavailable"}
        scores = self.model.predict(text)
        score = max(float(v) for v in scores.values()) if scores else 0.0
        return {"enabled": True, "scores": {k: float(v) for k, v in scores.items()}, "score": score, "error": None}


class RelevanceAnalyzer:
    def __init__(self, settings: GuardrailsSettings, golden_set: list[dict[str, Any]]) -> None:
        self.settings = settings
        self.enabled = settings.relevance_enabled
        self.golden_set = golden_set

    async def analyze(self, client: httpx.AsyncClient, text: str) -> dict[str, Any]:
        if not self.enabled:
            return {"enabled": False, "score": None, "error": None, "matched_label": None}
        if not self.golden_set:
            return {"enabled": False, "score": None, "error": "golden_set_empty", "matched_label": None}

        payload = {
            "model": os.getenv("SERVED_MODEL_NAME_3", "bge-m3-ko"),
            "input": [item["text"] for item in self.golden_set] + [text],
        }
        response = await client.post(f"{self.settings.embeddings_base_url}/v1/embeddings", json=payload)
        response.raise_for_status()
        body = response.json()
        vectors = [row["embedding"] for row in body.get("data", [])]
        if len(vectors) != len(self.golden_set) + 1:
            return {"enabled": True, "score": None, "error": "embedding_shape_mismatch", "matched_label": None}
        target = vectors[-1]
        best_label = None
        best_score = -1.0
        for idx, candidate in enumerate(vectors[:-1]):
            score = cosine_similarity(candidate, target)
            if score > best_score:
                best_score = score
                best_label = self.golden_set[idx].get("label", f"golden_{idx}")
        return {"enabled": True, "score": best_score, "error": None, "matched_label": best_label}


class GuardrailsRuntime:
    def __init__(self, settings: GuardrailsSettings) -> None:
        self.settings = settings
        self.config = self._load_json(settings.config_path, fallback={})
        self.golden_set = self._load_json(settings.golden_set_path, fallback=[])
        terms = read_lines(settings.blocklist_path)
        if not terms:
            terms = ["ignore previous instructions", "system prompt", "developer message"]
        self.blocklist = BlocklistMatcher(terms)
        self.prompt_injection_patterns = [
            re.compile(pattern, re.IGNORECASE)
            for pattern in self.config.get(
                "prompt_injection_patterns",
                [
                    r"ignore\s+(all\s+)?previous\s+instructions",
                    r"reveal\s+(the\s+)?system\s+prompt",
                    r"show\s+(the\s+)?developer\s+message",
                    r"bypass\s+(all\s+)?safety",
                ],
            )
        ]
        self.pii_analyzer = PiiAnalyzer(settings.pii_enabled)
        self.toxicity_analyzer = ToxicityAnalyzer(settings.toxicity_enabled)
        self.metrics = MetricsStore()
        self.rate_limit_hits: dict[str, deque[float]] = defaultdict(deque)
        self.rate_limit_lock = Lock()

    def _load_json(self, path_str: str, fallback: Any) -> Any:
        path = Path(path_str)
        if not path.exists():
            return fallback
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:  # pragma: no cover
            logger.warning("Failed to load JSON config %s: %s", path, exc)
            return fallback


def load_json_file(path_str: str, fallback: Any) -> Any:
    path = Path(path_str)
    if not path.exists():
        return fallback
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # pragma: no cover
        logger.warning("Failed to load JSON file %s: %s", path, exc)
        return fallback


def write_json_file(path_str: str, payload: Any) -> None:
    path = Path(path_str)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_lines_file(path_str: str, values: list[str]) -> None:
    path = Path(path_str)
    path.parent.mkdir(parents=True, exist_ok=True)
    normalized = [value.strip() for value in values if value.strip()]
    path.write_text("\n".join(normalized) + ("\n" if normalized else ""), encoding="utf-8")


def build_settings_from_sources(base_settings: Optional[GuardrailsSettings] = None) -> GuardrailsSettings:
    base_settings = base_settings or GuardrailsSettings()
    policy = load_json_file(base_settings.config_path, {})
    overrides = policy.get("settings_overrides", {}) if isinstance(policy, dict) else {}
    merged = {}
    for field_name in GuardrailsSettings.__dataclass_fields__:
        merged[field_name] = getattr(base_settings, field_name)
    for field_name, value in overrides.items():
        if field_name in MUTABLE_SETTING_FIELDS:
            merged[field_name] = coerce_setting_value(field_name, value, merged[field_name])
    return GuardrailsSettings(**merged)


def coerce_setting_value(field_name: str, value: Any, current_value: Any) -> Any:
    if isinstance(current_value, bool):
        if not isinstance(value, bool):
            raise ValueError(f"{field_name} must be a boolean")
        return value
    if isinstance(current_value, int) and not isinstance(current_value, bool):
        if not isinstance(value, int):
            raise ValueError(f"{field_name} must be an integer")
        return value
    if isinstance(current_value, float):
        if not isinstance(value, (int, float)):
            raise ValueError(f"{field_name} must be numeric")
        return float(value)
    if isinstance(current_value, str):
        if not isinstance(value, str):
            raise ValueError(f"{field_name} must be a string")
        return value
    raise ValueError(f"{field_name} has unsupported type")


def read_lines(path_str: str) -> list[str]:
    path = Path(path_str)
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.strip().startswith("#")]


def cosine_similarity(lhs: list[float], rhs: list[float]) -> float:
    numerator = sum(a * b for a, b in zip(lhs, rhs))
    lhs_norm = sum(a * a for a in lhs) ** 0.5
    rhs_norm = sum(b * b for b in rhs) ** 0.5
    if lhs_norm == 0 or rhs_norm == 0:
        return 0.0
    return numerator / (lhs_norm * rhs_norm)


app = FastAPI(title="Guardrails Proxy", version="0.1.0")
app.state.test_transport = None
app.state.http_client = None
app.state.settings = build_settings_from_sources()
app.state.runtime = GuardrailsRuntime(app.state.settings)


@app.on_event("startup")
async def startup() -> None:
    await reload_runtime_state()


@app.on_event("shutdown")
async def shutdown() -> None:
    client: Optional[httpx.AsyncClient] = app.state.http_client
    if client is not None:
        await client.aclose()


def get_settings() -> GuardrailsSettings:
    return getattr(app.state, "settings")


def get_runtime() -> GuardrailsRuntime:
    return getattr(app.state, "runtime")


async def reload_runtime_state() -> None:
    old_client: Optional[httpx.AsyncClient] = getattr(app.state, "http_client", None)
    if old_client is not None:
        await old_client.aclose()
    current_settings: Optional[GuardrailsSettings] = getattr(app.state, "settings", None)
    settings = build_settings_from_sources(current_settings)
    app.state.settings = settings
    app.state.runtime = GuardrailsRuntime(settings)
    app.state.http_client = build_http_client()


@app.get("/health")
async def health() -> dict[str, Any]:
    settings = get_settings()
    upstream_ok = False
    error = None
    try:
        client = get_http_client()
        response = await client.get(f"{settings.upstream_base_url}/health")
        upstream_ok = response.status_code == 200
    except Exception as exc:  # pragma: no cover
        error = str(exc)
    return {
        "status": "ok" if upstream_ok else "degraded",
        "upstream_ok": upstream_ok,
        "upstream": settings.upstream_base_url,
        "phase1_enabled": settings.phase1_enabled,
        "phase2_enabled": settings.phase2_enabled,
        "phase3_enabled": settings.phase3_enabled,
        "phase4_enabled": settings.phase4_enabled,
        "relevance_enabled": settings.relevance_enabled,
        "error": error,
    }


@app.get("/metrics")
async def metrics() -> PlainTextResponse:
    return PlainTextResponse(get_runtime().metrics.render_prometheus(), media_type="text/plain; version=0.0.4")


@app.get("/admin", response_class=HTMLResponse)
async def admin_ui(request: Request) -> HTMLResponse:
    settings = get_settings()
    if not settings.admin_ui_enabled:
        raise HTTPException(status_code=404, detail="Admin UI disabled")
    base_path = request.headers.get("X-Forwarded-Prefix", "").strip() or request.url.path.rstrip("/")
    proxy_api_key = request.query_params.get("api_key", "")
    return HTMLResponse(render_admin_html(base_path=base_path, proxy_api_key=proxy_api_key))


@app.get("/admin/config")
async def admin_get_config(request: Request) -> JSONResponse:
    require_admin_api_key(request)
    return JSONResponse(content=serialize_admin_config())


@app.put("/admin/config")
async def admin_put_config(request: Request) -> JSONResponse:
    require_admin_api_key(request)
    payload = await parse_admin_json(request)
    settings_payload = payload.get("settings", {})
    policy_payload = payload.get("policy", {})
    if not isinstance(settings_payload, dict) or not isinstance(policy_payload, dict):
        raise HTTPException(status_code=400, detail="settings and policy must be JSON objects")

    current_settings = get_settings()
    validated_settings = {}
    for field_name, value in settings_payload.items():
        if field_name not in MUTABLE_SETTING_FIELDS:
            raise HTTPException(status_code=400, detail=f"Unsupported setting field: {field_name}")
        validated_settings[field_name] = coerce_setting_value(field_name, value, getattr(current_settings, field_name))

    persisted_policy = dict(policy_payload)
    persisted_policy["settings_overrides"] = validated_settings
    write_json_file(current_settings.config_path, persisted_policy)
    await reload_runtime_state()
    return JSONResponse(content=serialize_admin_config())


@app.get("/admin/blocklist")
async def admin_get_blocklist(request: Request) -> JSONResponse:
    require_admin_api_key(request)
    settings = get_settings()
    return JSONResponse(content={"terms": read_lines(settings.blocklist_path)})


@app.put("/admin/blocklist")
async def admin_put_blocklist(request: Request) -> JSONResponse:
    require_admin_api_key(request)
    payload = await parse_admin_json(request)
    terms = payload.get("terms", [])
    if not isinstance(terms, list) or any(not isinstance(term, str) for term in terms):
        raise HTTPException(status_code=400, detail="terms must be an array of strings")
    settings = get_settings()
    write_lines_file(settings.blocklist_path, terms)
    await reload_runtime_state()
    return JSONResponse(content={"terms": read_lines(get_settings().blocklist_path)})


@app.get("/admin/golden-set")
async def admin_get_golden_set(request: Request) -> JSONResponse:
    require_admin_api_key(request)
    settings = get_settings()
    return JSONResponse(content={"items": load_json_file(settings.golden_set_path, [])})


@app.put("/admin/golden-set")
async def admin_put_golden_set(request: Request) -> JSONResponse:
    require_admin_api_key(request)
    payload = await parse_admin_json(request)
    items = payload.get("items", [])
    if not isinstance(items, list):
        raise HTTPException(status_code=400, detail="items must be an array")
    settings = get_settings()
    write_json_file(settings.golden_set_path, items)
    await reload_runtime_state()
    return JSONResponse(content={"items": load_json_file(get_settings().golden_set_path, [])})


@app.post("/admin/reload")
async def admin_reload(request: Request) -> JSONResponse:
    require_admin_api_key(request)
    await reload_runtime_state()
    return JSONResponse(content={"status": "reloaded", **serialize_admin_config()})


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
async def proxy(path: str, request: Request) -> Response:
    runtime = get_runtime()
    runtime.metrics.inc_request()
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    method = request.method.upper()
    query = request.url.query
    target_path = f"/{path}"
    if query:
        target_path = f"{target_path}?{query}"

    if path == "health":
        return await passthrough_request(request, target_path)

    if method == "POST" and path == "v1/chat/completions":
        return await handle_chat_completions(request, target_path, request_id)

    return await passthrough_request(request, target_path)


async def handle_chat_completions(request: Request, target_path: str, request_id: str) -> Response:
    runtime = get_runtime()
    started_at = time.perf_counter()
    try:
        payload = await request.json()
    except Exception:
        return blocked_response("MALFORMED_INPUT", request_id, 400, detail="Request body must be valid JSON")

    if not isinstance(payload, dict):
        return blocked_response("MALFORMED_INPUT", request_id, 400, detail="Request payload must be a JSON object")

    stream = bool(payload.get("stream", False))
    text_segments: list[str] = []
    try:
        normalized_payload = normalize_chat_payload(payload, text_segments)
    except ValueError as exc:
        return blocked_response("MALFORMED_INPUT", request_id, 400, detail=str(exc))

    input_text = "\n".join(segment for segment in text_segments if segment).strip()
    client_host = request.client.host if request.client else "anonymous"
    rate_key = request.headers.get("x-api-key") or client_host
    phase1_result = run_phase1_input_checks(normalized_payload, input_text, stream, rate_key)
    audit = {
        "request_id": request_id,
        "slot": "slot1",
        "path": target_path,
        "stream": stream,
        "phase1": phase1_result,
        "phase2": {},
        "phase3": {},
        "final_action": "pass",
        "reason_code": None,
        "upstream_latency_ms": None,
        "guardrails_latency_ms": None,
    }
    runtime.metrics.inc_phase("phase1")

    if phase1_result["action"] == "block":
        audit["final_action"] = "block"
        audit["reason_code"] = phase1_result["reason_code"]
        runtime.metrics.inc_block(phase1_result["reason_code"])
        runtime.metrics.inc_action("block")
        log_audit(audit)
        return blocked_response(phase1_result["reason_code"], request_id, 400, detail=phase1_result["detail"])

    phase2_result = await run_phase2_input_checks(input_text, request_id)
    audit["phase2"] = phase2_result
    runtime.metrics.inc_phase("phase2")

    phase3_result = run_phase3_decision(phase2_result)
    audit["phase3"] = phase3_result
    runtime.metrics.inc_phase("phase3")
    runtime.metrics.inc_action(phase3_result["action"])

    if stream:
        response = await stream_upstream_response(request, normalized_payload, target_path, request_id, audit, started_at)
        return response

    response = await non_stream_upstream_response(request, normalized_payload, target_path, request_id, audit, started_at)
    return response


async def passthrough_request(request: Request, target_path: str) -> Response:
    settings = get_settings()
    body = await request.body()
    response = await get_http_client().request(
        request.method,
        f"{settings.upstream_base_url}{target_path}",
        headers=filtered_headers(request.headers),
        content=body,
    )
    return Response(
        content=response.content,
        status_code=response.status_code,
        headers=filtered_response_headers(response.headers),
        media_type=response.headers.get("content-type"),
    )


async def stream_upstream_response(
    request: Request,
    payload: dict[str, Any],
    target_path: str,
    request_id: str,
    audit: dict[str, Any],
    started_at: float,
) -> Response:
    settings = get_settings()
    client = get_http_client()
    stream_context = client.stream(
        request.method,
        f"{settings.upstream_base_url}{target_path}",
        headers=filtered_headers(request.headers),
        json=payload,
    )
    upstream_response = await stream_context.__aenter__()

    async def body_iter() -> Any:
        try:
            async for chunk in upstream_response.aiter_raw():
                yield chunk
        finally:
            await stream_context.__aexit__(None, None, None)

    audit["upstream_latency_ms"] = round((time.perf_counter() - started_at) * 1000, 3)
    audit["guardrails_latency_ms"] = audit["upstream_latency_ms"]
    log_audit(audit)
    return StreamingResponse(
        body_iter(),
        status_code=upstream_response.status_code,
        headers=filtered_response_headers(upstream_response.headers),
        media_type=upstream_response.headers.get("content-type"),
    )


async def non_stream_upstream_response(
    request: Request,
    payload: dict[str, Any],
    target_path: str,
    request_id: str,
    audit: dict[str, Any],
    started_at: float,
) -> Response:
    settings = get_settings()
    runtime = get_runtime()
    upstream_started = time.perf_counter()
    upstream_response = await get_http_client().request(
        request.method,
        f"{settings.upstream_base_url}{target_path}",
        headers=filtered_headers(request.headers),
        json=payload,
    )
    audit["upstream_latency_ms"] = round((time.perf_counter() - upstream_started) * 1000, 3)

    content = upstream_response.content
    if (
        upstream_response.status_code == 200
        and settings.output_semantic_non_stream_only
        and upstream_response.headers.get("content-type", "").startswith("application/json")
    ):
        output_result = await run_output_checks(content, request_id)
        audit["output"] = output_result
        if output_result.get("action") == "block":
            audit["final_action"] = "block"
            audit["reason_code"] = output_result["reason_code"]
            runtime.metrics.inc_block(output_result["reason_code"])
            runtime.metrics.inc_action("block")
            audit["guardrails_latency_ms"] = round((time.perf_counter() - started_at) * 1000, 3)
            log_audit(audit)
            return blocked_response(output_result["reason_code"], request_id, 400, detail=output_result["detail"])

    audit["guardrails_latency_ms"] = round((time.perf_counter() - started_at) * 1000, 3)
    log_audit(audit)
    return Response(
        content=content,
        status_code=upstream_response.status_code,
        headers=filtered_response_headers(upstream_response.headers),
        media_type=upstream_response.headers.get("content-type"),
    )


def normalize_chat_payload(payload: dict[str, Any], text_segments: list[str]) -> dict[str, Any]:
    settings = get_settings()
    messages = payload.get("messages")
    if not isinstance(messages, list) or not messages:
        raise ValueError("messages must be a non-empty array")
    if len(messages) > settings.max_message_count:
        raise ValueError(f"messages exceeds max count {settings.max_message_count}")

    normalized_messages = []
    for message in messages:
        if not isinstance(message, dict):
            raise ValueError("each message must be an object")
        content = message.get("content")
        normalized_message = dict(message)
        if isinstance(content, str):
            normalized_content = normalize_text(content)
            text_segments.append(normalized_content)
            normalized_message["content"] = normalized_content
        elif isinstance(content, list):
            normalized_parts = []
            for item in content:
                if isinstance(item, dict) and item.get("type") == "text":
                    text_value = normalize_text(str(item.get("text", "")))
                    text_segments.append(text_value)
                    normalized_parts.append({**item, "text": text_value})
                else:
                    normalized_parts.append(item)
            normalized_message["content"] = normalized_parts
        elif content is None:
            normalized_message["content"] = ""
        else:
            raise ValueError("message content must be string or array")
        normalized_messages.append(normalized_message)

    normalized_payload = dict(payload)
    normalized_payload["messages"] = normalized_messages
    if "tools" in normalized_payload:
        tools = normalized_payload["tools"]
        if not isinstance(tools, list):
            raise ValueError("tools must be an array")
        if len(tools) > settings.max_tool_count:
            raise ValueError(f"tools exceeds max count {settings.max_tool_count}")
    return normalized_payload


async def run_phase2_input_checks(text: str, request_id: str) -> dict[str, Any]:
    settings = get_settings()
    runtime = get_runtime()
    if not settings.phase2_enabled or not text.strip():
        return {"mode": settings.phase2_mode, "pii": {}, "toxicity": {}, "relevance": {}, "timeouts": [], "errors": []}

    async def run_with_timeout(name: str, coro: Any) -> tuple[str, Any]:
        start = time.perf_counter()
        try:
            result = await asyncio.wait_for(coro, timeout=settings.analyzer_timeout_seconds)
            runtime.metrics.observe_latency(name, (time.perf_counter() - start) * 1000)
            return name, result
        except asyncio.TimeoutError:
            runtime.metrics.inc_timeout()
            runtime.metrics.observe_latency(name, (time.perf_counter() - start) * 1000)
            return name, {"enabled": False, "error": "timeout"}
        except Exception as exc:  # pragma: no cover
            runtime.metrics.observe_latency(name, (time.perf_counter() - start) * 1000)
            return name, {"enabled": False, "error": str(exc)}

    client = get_http_client()
    relevance_analyzer = RelevanceAnalyzer(settings, runtime.golden_set)
    tasks = [
        run_with_timeout("pii", asyncio.to_thread(runtime.pii_analyzer.analyze, text)),
        run_with_timeout("toxicity", asyncio.to_thread(runtime.toxicity_analyzer.analyze, text)),
        run_with_timeout("relevance", relevance_analyzer.analyze(client, text)),
    ]
    results = dict(await asyncio.gather(*tasks))
    timeouts = [name for name, data in results.items() if data.get("error") == "timeout"]
    errors = [{"analyzer": name, "error": data.get("error")} for name, data in results.items() if data.get("error") and data.get("error") != "timeout"]
    if timeouts:
        logger.warning("Analyzer timeout observed for request_id=%s analyzers=%s", request_id, ",".join(timeouts))
    return {
        "mode": settings.phase2_mode,
        "pii": results.get("pii", {}),
        "toxicity": results.get("toxicity", {}),
        "relevance": results.get("relevance", {}),
        "timeouts": timeouts,
        "errors": errors,
    }


async def run_output_checks(content: bytes, request_id: str) -> dict[str, Any]:
    settings = get_settings()
    runtime = get_runtime()
    try:
        payload = json.loads(content)
    except Exception:
        return {"action": "pass", "detail": "non_json_output", "reason_code": None}
    output_text = extract_assistant_text(payload)
    if not output_text:
        return {"action": "pass", "detail": "no_text_output", "reason_code": None}
    if len(output_text) > settings.max_non_stream_output_chars:
        return {"action": "block", "detail": "Output exceeded non-stream character limit", "reason_code": "OUTPUT_TOO_LONG"}
    matches = runtime.blocklist.find_matches(output_text)
    if matches and settings.output_blocklist_enforce:
        return {"action": "block", "detail": f"Output matched blocklist terms: {', '.join(matches[:5])}", "reason_code": "BLOCKLIST_MATCH"}
    phase2 = await run_phase2_input_checks(output_text, request_id)
    phase3 = run_phase3_decision(phase2)
    return {
        "action": "pass",
        "detail": "output_observe_only",
        "reason_code": None,
        "phase2": phase2,
        "phase3": phase3,
    }


def run_phase1_input_checks(payload: dict[str, Any], input_text: str, stream: bool, rate_key: str) -> dict[str, Any]:
    settings = get_settings()
    runtime = get_runtime()
    if not settings.phase1_enabled:
        return {"action": "pass", "reason_code": None, "detail": "phase1_disabled"}
    if is_rate_limited(rate_key):
        runtime.metrics.inc_rate_limit()
        return {"action": "block", "reason_code": "RATE_LIMITED", "detail": "Too many requests for the current API key window"}
    limit = settings.max_stream_input_chars if stream else settings.max_input_chars
    if len(input_text) > limit:
        return {"action": "block", "reason_code": "INPUT_TOO_LONG", "detail": f"Input exceeded max chars {limit}"}
    matches = runtime.blocklist.find_matches(input_text)
    if matches:
        return {"action": "block", "reason_code": "BLOCKLIST_MATCH", "detail": f"Input matched blocklist terms: {', '.join(matches[:5])}"}
    for pattern in runtime.prompt_injection_patterns:
        if pattern.search(input_text):
            return {"action": "block", "reason_code": "PROMPT_INJECTION_PATTERN", "detail": f"Input matched pattern {pattern.pattern}"}
    if payload.get("stream") and payload.get("tools") and len(payload.get("tools", [])) > max(1, settings.max_tool_count // 2):
        return {"action": "block", "reason_code": "STREAM_TOOL_LIMIT", "detail": "Streaming requests allow fewer tools"}
    return {"action": "pass", "reason_code": None, "detail": "phase1_pass"}


def is_rate_limited(rate_key: str) -> bool:
    settings = get_settings()
    runtime = get_runtime()
    now = time.time()
    window = settings.rate_limit_window_seconds
    with runtime.rate_limit_lock:
        hits = runtime.rate_limit_hits[rate_key]
        while hits and now - hits[0] > window:
            hits.popleft()
        if len(hits) >= settings.rate_limit_max_requests:
            return True
        hits.append(now)
    return False


def run_phase3_decision(phase2_result: dict[str, Any]) -> dict[str, Any]:
    settings = get_settings()
    if not settings.phase3_enabled:
        return {"action": "pass", "decision": "phase3_disabled", "reason_code": None}
    pii_results = phase2_result.get("pii", {}).get("results", [])
    toxicity_score = float(phase2_result.get("toxicity", {}).get("score") or 0.0)
    relevance_score = phase2_result.get("relevance", {}).get("score")

    if pii_results:
        return {"action": "gray", "decision": "pii_detected", "reason_code": "PII_DETECTED"}
    if toxicity_score >= settings.toxicity_danger_threshold:
        return {"action": "gray", "decision": "toxicity_high", "reason_code": "TOXICITY_HIGH"}
    if relevance_score is not None and relevance_score < settings.relevance_safe_threshold:
        return {"action": "gray", "decision": "relevance_low", "reason_code": "RELEVANCE_LOW"}
    if toxicity_score <= settings.toxicity_safe_threshold:
        return {"action": "pass", "decision": "safe", "reason_code": None}
    return {"action": "gray", "decision": "review", "reason_code": "GRAY_ZONE"}


def extract_assistant_text(payload: Any) -> str:
    if not isinstance(payload, dict):
        return ""
    pieces: list[str] = []
    for choice in payload.get("choices", []):
        message = choice.get("message", {})
        content = message.get("content")
        if isinstance(content, str):
            pieces.append(content)
        elif isinstance(content, list):
            for item in content:
                if isinstance(item, dict) and item.get("type") == "text":
                    pieces.append(str(item.get("text", "")))
    return "\n".join(piece for piece in pieces if piece).strip()


def filtered_headers(headers: Any) -> dict[str, str]:
    excluded = {"host", "content-length"}
    return {key: value for key, value in headers.items() if key.lower() not in excluded}


def filtered_response_headers(headers: Any) -> dict[str, str]:
    excluded = {"content-length", "transfer-encoding", "connection", "content-encoding"}
    return {key: value for key, value in headers.items() if key.lower() not in excluded}


def require_admin_api_key(request: Request) -> None:
    settings = get_settings()
    expected = settings.admin_api_key.strip()
    if not expected:
        raise HTTPException(status_code=503, detail="Admin API key is not configured")
    actual = request.headers.get("X-Admin-API-Key", "").strip()
    if actual != expected:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid admin API key")


async def parse_admin_json(request: Request) -> dict[str, Any]:
    try:
        payload = await request.json()
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Request body must be valid JSON") from exc
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="Request payload must be a JSON object")
    return payload


def serialize_admin_config() -> dict[str, Any]:
    settings = get_settings()
    runtime = get_runtime()
    policy = dict(runtime.config)
    policy.pop("settings_overrides", None)
    return {
        "settings": settings.admin_settings_payload(),
        "policy": policy,
    }


def render_admin_html(base_path: str, proxy_api_key: str) -> str:
    safe_base_path = json.dumps(base_path or "/admin")
    safe_proxy_api_key = json.dumps(proxy_api_key or "")
    html = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Guardrails Admin</title>
  <style>
    body { font-family: sans-serif; margin: 24px; max-width: 1100px; }
    textarea { width: 100%; min-height: 180px; font-family: monospace; }
    input[type=password] { width: 360px; }
    .row { margin-bottom: 20px; }
    .actions { display: flex; gap: 12px; flex-wrap: wrap; margin: 12px 0; }
    .status { white-space: pre-wrap; padding: 12px; background: #f5f5f5; border: 1px solid #ddd; }
  </style>
</head>
<body>
  <h1>Guardrails Admin</h1>
  <p>Read/write operations call the authenticated admin API. Enter <code>X-Admin-API-Key</code> below.</p>
  <div class="row">
    <label>Proxy API Key <input id="proxy-key" type="password" placeholder="X-API-Key"></label>
  </div>
  <div class="row">
    <label>Admin API Key <input id="admin-key" type="password" placeholder="X-Admin-API-Key"></label>
  </div>
  <div class="actions">
    <button onclick="loadAll()">Load</button>
    <button onclick="saveConfig()">Save Config</button>
    <button onclick="saveBlocklist()">Save Blocklist</button>
    <button onclick="saveGoldenSet()">Save Golden Set</button>
    <button onclick="reloadRuntime()">Reload Runtime</button>
  </div>
  <div class="row">
    <h2>Config</h2>
    <textarea id="config-editor"></textarea>
  </div>
  <div class="row">
    <h2>Blocklist</h2>
    <textarea id="blocklist-editor"></textarea>
  </div>
  <div class="row">
    <h2>Golden Set</h2>
    <textarea id="golden-set-editor"></textarea>
  </div>
  <div class="row">
    <h2>Status</h2>
    <div id="status" class="status">Idle</div>
  </div>
  <script>
    const adminBasePath = __ADMIN_BASE_PATH__;
    const initialProxyApiKey = __INITIAL_PROXY_API_KEY__;
    document.getElementById("proxy-key").value = initialProxyApiKey;

    function endpoint(path) {{
      const prefix = adminBasePath.endsWith('/') ? adminBasePath : `${{adminBasePath}}/`;
      return `${{prefix}}${{path}}`;
    }}
    function adminHeaders() {
      return {
        "Content-Type": "application/json",
        "X-Admin-API-Key": document.getElementById("admin-key").value,
        "X-API-Key": document.getElementById("proxy-key").value
      };
    }
    function setStatus(message) {
      document.getElementById("status").textContent = message;
    }
    async function fetchJson(url, options) {
      const response = await fetch(url, options);
      const text = await response.text();
      let body = {};
      try { body = text ? JSON.parse(text) : {}; } catch (_) { body = { raw: text }; }
      if (!response.ok) {
        throw new Error(`${response.status} ${response.statusText}\\n${JSON.stringify(body, null, 2)}`);
      }
      return body;
    }
    async function loadAll() {
      try {
        const [config, blocklist, goldenSet] = await Promise.all([
          fetchJson(endpoint('config'), { headers: adminHeaders() }),
          fetchJson(endpoint('blocklist'), { headers: adminHeaders() }),
          fetchJson(endpoint('golden-set'), { headers: adminHeaders() })
        ]);
        document.getElementById('config-editor').value = JSON.stringify(config, null, 2);
        document.getElementById('blocklist-editor').value = (blocklist.terms || []).join('\\n');
        document.getElementById('golden-set-editor').value = JSON.stringify(goldenSet.items || [], null, 2);
        setStatus('Loaded config, blocklist, and golden set.');
      } catch (error) {
        setStatus(String(error));
      }
    }
    async function saveConfig() {
      try {
        const payload = JSON.parse(document.getElementById('config-editor').value);
        const response = await fetchJson(endpoint('config'), {
          method: 'PUT',
          headers: adminHeaders(),
          body: JSON.stringify(payload)
        });
        document.getElementById('config-editor').value = JSON.stringify(response, null, 2);
        setStatus('Config saved.');
      } catch (error) {
        setStatus(String(error));
      }
    }
    async function saveBlocklist() {
      try {
        const terms = document.getElementById('blocklist-editor').value
          .split('\\n')
          .map((line) => line.trim())
          .filter(Boolean);
        const response = await fetchJson(endpoint('blocklist'), {
          method: 'PUT',
          headers: adminHeaders(),
          body: JSON.stringify({ terms })
        });
        document.getElementById('blocklist-editor').value = (response.terms || []).join('\\n');
        setStatus('Blocklist saved.');
      } catch (error) {
        setStatus(String(error));
      }
    }
    async function saveGoldenSet() {
      try {
        const items = JSON.parse(document.getElementById('golden-set-editor').value);
        const response = await fetchJson(endpoint('golden-set'), {
          method: 'PUT',
          headers: adminHeaders(),
          body: JSON.stringify({ items })
        });
        document.getElementById('golden-set-editor').value = JSON.stringify(response.items || [], null, 2);
        setStatus('Golden set saved.');
      } catch (error) {
        setStatus(String(error));
      }
    }
    async function reloadRuntime() {
      try {
        const response = await fetchJson(endpoint('reload'), {
          method: 'POST',
          headers: adminHeaders()
        });
        document.getElementById('config-editor').value = JSON.stringify(response, null, 2);
        setStatus('Runtime reloaded.');
      } catch (error) {
        setStatus(String(error));
      }
    }
  </script>
</body>
</html>"""
    return html.replace("__ADMIN_BASE_PATH__", safe_base_path).replace("__INITIAL_PROXY_API_KEY__", safe_proxy_api_key)


def blocked_response(reason_code: str, request_id: str, status_code: int, detail: str) -> JSONResponse:
    payload = {
        "error": {
            "message": f"Blocked by guardrails: {detail}",
            "type": "invalid_request_error",
            "code": reason_code,
            "param": None,
        },
        "request_id": request_id,
    }
    return JSONResponse(status_code=status_code, content=payload, headers={"x-guardrails-reason-code": reason_code})


def normalize_text(text: str) -> str:
    return unicodedata.normalize("NFC", text).strip()


def build_http_client() -> httpx.AsyncClient:
    transport = getattr(app.state, "test_transport", None)
    return httpx.AsyncClient(timeout=get_settings().request_timeout_seconds, transport=transport)


def get_http_client() -> httpx.AsyncClient:
    client = getattr(app.state, "http_client", None)
    if client is None:
        client = build_http_client()
        app.state.http_client = client
    return client


def log_audit(audit: dict[str, Any]) -> None:
    logger.info("guardrails_audit %s", json.dumps(audit, ensure_ascii=False, default=str))
