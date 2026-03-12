#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import io
from typing import Any

import gradio as gr
import requests
from PIL import Image


def make_client(base_url: str, api_key: str, timeout: float) -> tuple[str, dict[str, str], float]:
    normalized = base_url.rstrip("/")
    headers = {}
    if api_key:
      headers["X-API-Key"] = api_key
    return normalized, headers, timeout


def health(base_url: str, api_key: str, timeout: float) -> str:
    url, headers, timeout_value = make_client(base_url, api_key, timeout)
    try:
        response = requests.get(f"{url}/slot7/health", headers=headers, timeout=10, verify=False)
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


def generate(
    base_url: str,
    api_key: str,
    timeout: float,
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

    url, headers, timeout_value = make_client(base_url, api_key, timeout)
    try:
        response = requests.post(
            f"{url}/slot7/v1/images/generations",
            headers=headers,
            json=payload,
            timeout=timeout_value,
            verify=False,
        )
        response.raise_for_status()
        body = response.json()
        image_b64 = body["data"][0]["b64_json"]
        image = Image.open(io.BytesIO(base64.b64decode(image_b64))).convert("RGB")
        return image, (
            f"http=200 | model={body.get('model')} | "
            f"size={width}x{height} | steps={steps} | "
            f"guidance={guidance} | seed={payload.get('seed', 'auto')}"
        )
    except Exception as exc:  # noqa: BLE001
        return None, f"generation failed: {exc}"


def build_demo(default_base_url: str, default_api_key: str, timeout: float) -> gr.Blocks:
    with gr.Blocks(title="Remote Diffusion Slot7 Tester") as demo:
        gr.Markdown(
            """
            # Remote Diffusion Slot7 Tester
            Local Gradio UI that calls the remote `/slot7` diffusion endpoint.
            """
        )

        with gr.Row():
            base_url = gr.Textbox(label="Base URL", value=default_base_url)
            api_key = gr.Textbox(label="X-API-Key", value=default_api_key, type="password")
        with gr.Row():
            refresh_btn = gr.Button("Refresh Health")
            health_box = gr.Textbox(label="Backend Health", value="", interactive=False)

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

        refresh_btn.click(fn=health, inputs=[base_url, api_key, gr.State(timeout)], outputs=health_box)
        submit.click(
            fn=generate,
            inputs=[base_url, api_key, gr.State(timeout), prompt, negative_prompt, width, height, steps, guidance, seed],
            outputs=[image_out, meta_out],
        )
        demo.load(fn=health, inputs=[base_url, api_key, gr.State(timeout)], outputs=health_box)
    return demo


def main() -> None:
    parser = argparse.ArgumentParser(description="Run local Gradio for remote diffusion slot7 testing.")
    parser.add_argument("--base-url", default="https://pty-metadata-ltd-loving.trycloudflare.com")
    parser.add_argument("--api-key", default="")
    parser.add_argument("--server-port", type=int, default=7868)
    parser.add_argument("--timeout", type=float, default=300.0)
    args = parser.parse_args()

    demo = build_demo(args.base_url, args.api_key, args.timeout)
    demo.launch(server_name="127.0.0.1", server_port=args.server_port)


if __name__ == "__main__":
    main()
