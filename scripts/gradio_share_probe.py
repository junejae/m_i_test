#!/usr/bin/env python3
"""Launch a tiny Gradio app with share=True and probe the public URL."""

from __future__ import annotations

import json
import ssl
import sys
import time
import urllib.error
import urllib.request

import gradio as gr


def _echo(text: str) -> str:
    return text


def _probe(url: str, timeout_seconds: int = 10) -> tuple[bool, str]:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout_seconds, context=ctx) as res:
            status = getattr(res, "status", 0)
            ok = 200 <= int(status) < 500
            return ok, f"http_status={status}"
    except urllib.error.HTTPError as exc:
        return True, f"http_error_status={exc.code}"
    except Exception as exc:  # noqa: BLE001
        return False, f"{type(exc).__name__}: {exc}"


def main() -> int:
    with gr.Blocks(title="gradio-share-probe") as demo:
        gr.Markdown("# Gradio Share Probe")
        txt = gr.Textbox(label="Input")
        out = gr.Textbox(label="Output")
        txt.submit(_echo, inputs=txt, outputs=out)

    launch_result = demo.launch(
        server_name="0.0.0.0",
        server_port=7860,
        share=True,
        prevent_thread_lock=True,
        quiet=True,
    )
    _, local_url, share_url = launch_result

    print(f"LOCAL_URL={local_url}", flush=True)
    print(f"SHARE_URL={share_url}", flush=True)

    ok = False
    reason = "share url was not issued"
    if share_url:
        # Tunnel bootstrap can take a few seconds.
        time.sleep(5)
        ok, reason = _probe(share_url)

    result = {"ok": ok, "reason": reason, "local_url": local_url, "share_url": share_url}
    print("PROBE_RESULT_JSON=" + json.dumps(result, ensure_ascii=True), flush=True)

    demo.close()
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
