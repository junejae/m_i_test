import base64
import io
import os
import time
from contextlib import suppress
from typing import Optional

import torch
from diffusers import StableDiffusionPipeline
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

app = FastAPI(title="Diffusion Server", version="1.0.0")

MODEL_ID = os.getenv("DIFFUSION_MODEL_ID", "runwayml/stable-diffusion-v1-5")
DEVICE = os.getenv("DIFFUSION_DEVICE", "cuda")
DTYPE = os.getenv("DIFFUSION_DTYPE", "float16")
DEFAULT_HEIGHT = int(os.getenv("DIFFUSION_DEFAULT_HEIGHT", "512"))
DEFAULT_WIDTH = int(os.getenv("DIFFUSION_DEFAULT_WIDTH", "512"))
DEFAULT_STEPS = int(os.getenv("DIFFUSION_DEFAULT_STEPS", "20"))
DEFAULT_GUIDANCE = float(os.getenv("DIFFUSION_DEFAULT_GUIDANCE", "7.5"))
NEGATIVE_PROMPT = os.getenv("DIFFUSION_NEGATIVE_PROMPT", "")
ENABLE_CPU_OFFLOAD = os.getenv("DIFFUSION_ENABLE_CPU_OFFLOAD", "0") == "1"

pipeline: Optional[StableDiffusionPipeline] = None
startup_error: Optional[str] = None


class ImageGenerationRequest(BaseModel):
    prompt: str = Field(min_length=1, max_length=2000)
    negative_prompt: Optional[str] = Field(default=None, max_length=2000)
    height: int = Field(default=DEFAULT_HEIGHT, ge=256, le=768)
    width: int = Field(default=DEFAULT_WIDTH, ge=256, le=768)
    num_inference_steps: int = Field(default=DEFAULT_STEPS, ge=1, le=50)
    guidance_scale: float = Field(default=DEFAULT_GUIDANCE, ge=0.0, le=20.0)
    num_images: int = Field(default=1, ge=1, le=2)
    seed: Optional[int] = None
    response_format: str = Field(default="b64_json", pattern="^(b64_json)$")


def _torch_dtype() -> torch.dtype:
    return torch.float16 if DTYPE == "float16" else torch.bfloat16


@app.on_event("startup")
def startup() -> None:
    global pipeline
    global startup_error

    try:
        pipeline = StableDiffusionPipeline.from_pretrained(
            MODEL_ID,
            torch_dtype=_torch_dtype(),
            safety_checker=None,
            feature_extractor=None,
            requires_safety_checker=False,
        )
        pipeline.set_progress_bar_config(disable=True)
        pipeline.enable_attention_slicing()
        with suppress(Exception):
            pipeline.enable_vae_slicing()
        if DEVICE == "cuda" and ENABLE_CPU_OFFLOAD:
            pipeline.enable_model_cpu_offload()
        else:
            pipeline = pipeline.to(DEVICE)
        startup_error = None
    except Exception as exc:  # noqa: BLE001
        startup_error = str(exc)
        pipeline = None


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok" if pipeline is not None else "error",
        "model": MODEL_ID,
        "device": DEVICE,
        "startup_error": startup_error,
    }


@app.get("/v1/models")
def models() -> dict:
    return {
        "object": "list",
        "data": [
            {
                "id": MODEL_ID,
                "object": "model",
                "owned_by": "diffusers",
            }
        ],
    }


@app.post("/v1/images/generations")
def image_generations(req: ImageGenerationRequest) -> dict:
    if pipeline is None:
        raise HTTPException(status_code=503, detail=f"Model not ready: {startup_error or 'unknown'}")

    generator = None
    if req.seed is not None:
        generator = torch.Generator(device=DEVICE).manual_seed(req.seed)

    started_at = int(time.time())
    result = pipeline(
        prompt=req.prompt,
        negative_prompt=req.negative_prompt if req.negative_prompt is not None else NEGATIVE_PROMPT,
        height=req.height,
        width=req.width,
        num_inference_steps=req.num_inference_steps,
        guidance_scale=req.guidance_scale,
        num_images_per_prompt=req.num_images,
        generator=generator,
    )

    data = []
    for image in result.images:
        buf = io.BytesIO()
        image.save(buf, format="PNG")
        data.append({"b64_json": base64.b64encode(buf.getvalue()).decode("ascii")})

    return {
        "created": started_at,
        "data": data,
        "model": MODEL_ID,
    }
