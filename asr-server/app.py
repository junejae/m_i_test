import os
import tempfile
from typing import Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from faster_whisper import WhisperModel

app = FastAPI(title="ASR Server", version="1.0.0")

MODEL_ID = os.getenv("ASR_MODEL_ID", "openai/whisper-large-v3")
DEVICE = os.getenv("ASR_DEVICE", "cuda")
COMPUTE_TYPE = os.getenv("ASR_COMPUTE_TYPE", "float16")
DEFAULT_LANGUAGE = os.getenv("ASR_LANGUAGE", "ko")
DEFAULT_BEAM_SIZE = int(os.getenv("ASR_BEAM_SIZE", "1"))

model: Optional[WhisperModel] = None


@app.on_event("startup")
def startup() -> None:
    global model
    model = WhisperModel(MODEL_ID, device=DEVICE, compute_type=COMPUTE_TYPE)


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "model": MODEL_ID}


@app.post("/v1/audio/transcriptions")
async def transcriptions(
    file: UploadFile = File(...),
    model_name: Optional[str] = Form(default=None, alias="model"),
    language: Optional[str] = Form(default=None),
    prompt: Optional[str] = Form(default=None),
    response_format: str = Form(default="json"),
) -> dict:
    if model is None:
        raise HTTPException(status_code=503, detail="Model not ready")

    suffix = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp_path = tmp.name
        tmp.write(await file.read())

    try:
        segments, info = model.transcribe(
            tmp_path,
            language=language or DEFAULT_LANGUAGE,
            initial_prompt=prompt,
            beam_size=DEFAULT_BEAM_SIZE,
            vad_filter=True,
        )
        text = "".join(seg.text for seg in segments).strip()
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass

    if response_format == "text":
        return {"text": text}

    return {
        "task": "transcribe",
        "language": info.language,
        "duration": info.duration,
        "text": text,
        "model": model_name or MODEL_ID,
    }
