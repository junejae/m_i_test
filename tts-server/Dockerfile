FROM vllm/vllm-openai:latest

# Qwen3-TTS support can lag in pinned transformer builds inside base images.
RUN python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel \
    && python3 -m pip install --no-cache-dir \
        "huggingface_hub>=0.31.2" \
        "accelerate>=1.7.0" \
        "tokenizers>=0.21.1" \
        "safetensors>=0.5.3" \
    && python3 -m pip install --no-cache-dir "git+https://github.com/huggingface/transformers.git"
