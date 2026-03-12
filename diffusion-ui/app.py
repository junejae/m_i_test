import base64
import io
import os
from typing import Any

import gradio as gr
import requests
from PIL import Image

API_URL = os.getenv("DIFFUSION_API_URL", "http://mig-diffusion-7:8000")
ROOT_PATH = os.getenv("DIFFUSION_UI_ROOT_PATH", "")
MODEL_NAME = os.getenv("DIFFUSION_MODEL_NAME", "runwayml/stable-diffusion-v1-5")
SERVER_PORT = int(os.getenv("DIFFUSION_UI_PORT", "7860"))
REQUEST_TIMEOUT = float(os.getenv("DIFFUSION_UI_TIMEOUT", "300"))


def health_text() -> str:
    try:
        response = requests.get(f"{API_URL}/health", timeout=10)
        response.raise_for_status()
        payload = response.json()
        return (
            f"status={payload.get('status')} | "
            f"model={payload.get('model')} | "
            f"device={payload.get('device')} | "
            f"startup_error={payload.get('startup_error')}"
        )
    except Exception as exc:  # noqa: BLE001
        return f"health check failed: {exc}"


def decode_image(payload: dict[str, Any]) -> Image.Image:
    image_b64 = payload["data"][0]["b64_json"]
    raw = base64.b64decode(image_b64)
    return Image.open(io.BytesIO(raw)).convert("RGB")


def generate_image(
    prompt: str,
    negative_prompt: str,
    width: int,
    height: int,
    steps: int,
    guidance: float,
    seed_text: str,
) -> tuple[Image.Image | None, str]:
    prompt = prompt.strip()
    if not prompt:
        return None, "prompt is required"

    payload: dict[str, Any] = {
        "prompt": prompt,
        "negative_prompt": negative_prompt.strip(),
        "width": int(width),
        "height": int(height),
        "num_inference_steps": int(steps),
        "guidance_scale": float(guidance),
        "num_images": 1,
    }
    if seed_text.strip():
        try:
            payload["seed"] = int(seed_text.strip())
        except ValueError:
            return None, "seed must be an integer"

    try:
        response = requests.post(
            f"{API_URL}/v1/images/generations",
            json=payload,
            timeout=REQUEST_TIMEOUT,
        )
        response.raise_for_status()
        result = response.json()
        image = decode_image(result)
        meta = (
            f"model={result.get('model', MODEL_NAME)} | "
            f"size={width}x{height} | "
            f"steps={steps} | guidance={guidance} | "
            f"seed={payload.get('seed', 'auto')}"
        )
        return image, meta
    except Exception as exc:  # noqa: BLE001
        return None, f"generation failed: {exc}"


with gr.Blocks(title="Diffusion Slot7 Test UI") as demo:
    gr.Markdown(
        """
        # Diffusion Slot7 Test UI
        Small Web UI for testing `mig-diffusion-7` through the internal API.
        """
    )
    health_box = gr.Textbox(label="Backend Health", value=health_text(), interactive=False)
    refresh_btn = gr.Button("Refresh Health")

    with gr.Row():
        with gr.Column(scale=2):
            prompt = gr.Textbox(
                label="Prompt",
                value="a small robot reading a book, clean illustration",
                lines=4,
            )
            negative_prompt = gr.Textbox(
                label="Negative Prompt",
                value="blurry, low-quality, distorted",
                lines=2,
            )
            with gr.Row():
                width = gr.Slider(label="Width", minimum=256, maximum=768, step=64, value=512)
                height = gr.Slider(label="Height", minimum=256, maximum=768, step=64, value=512)
            with gr.Row():
                steps = gr.Slider(label="Steps", minimum=1, maximum=50, step=1, value=20)
                guidance = gr.Slider(label="Guidance", minimum=0.0, maximum=20.0, step=0.5, value=7.5)
            seed = gr.Textbox(label="Seed (optional)", value="")
            submit = gr.Button("Generate", variant="primary")
        with gr.Column(scale=3):
            image_out = gr.Image(label="Generated Image", type="pil")
            meta_out = gr.Textbox(label="Result", interactive=False)

    refresh_btn.click(fn=health_text, outputs=health_box)
    submit.click(
        fn=generate_image,
        inputs=[prompt, negative_prompt, width, height, steps, guidance, seed],
        outputs=[image_out, meta_out],
    )


if __name__ == "__main__":
    demo.launch(server_name="0.0.0.0", server_port=SERVER_PORT, root_path=ROOT_PATH)
