# m_i_test

H100 2-GPU host template for MIG-based multi-inference with Docker Compose.

This template assumes:
- `GPU 0`: already used by another workload (for example an existing full-GPU vLLM server)
- `GPU 1`: partitioned with MIG, then each MIG slice runs one independent vLLM server container
- `mig-vllm-1`: `google/gemma-3-4b-it` (text-focused config)
- `mig-vllm-2`: `Qwen/Qwen3-VL-8B-Instruct` (vision-language config)
- `mig-vllm-3`: `dragonkue/BGE-m3-ko` (embedding-focused config)
- `mig-vllm-4`: `Dongjin-kr/ko-reranker` (reranker-focused config)
- `mig-asr-5`: `openai/whisper-large-v3` (ASR-focused config, non-vLLM)

## Prerequisites

- NVIDIA driver + CUDA stack with H100 MIG support
- Docker Engine + Compose plugin
- NVIDIA Container Toolkit configured for Docker

If Docker reports `unknown or invalid runtime name: nvidia`, run:

```bash
cd /Users/junejae/workspace/m_i_test && chmod +x scripts/*.sh && sudo ./scripts/install_nvidia_container_toolkit.sh
```

This installer uses `systemctl reload docker` by default (to avoid restarting running containers).
If reload fails and you explicitly allow restart:

```bash
cd /Users/junejae/workspace/m_i_test && sudo ALLOW_DOCKER_RESTART=1 ./scripts/install_nvidia_container_toolkit.sh
```

## One-command bootstrap (for TUI/no copy-paste)

```bash
cd /Users/junejae/workspace/m_i_test && chmod +x scripts/*.sh && MIG_TARGET_GPU_INDEX=1 ./scripts/bootstrap_gpu1_mig_stack.sh
```

Optional MIG instance auto-create example:

```bash
cd /Users/junejae/workspace/m_i_test && chmod +x scripts/*.sh && MIG_TARGET_GPU_INDEX=1 MIG_CREATE_ARGS='19,19' ./scripts/bootstrap_gpu1_mig_stack.sh
```

If MIG is already created and `nvidia-smi` reports client-in-use errors during prepare, skip prepare and reuse existing MIG layout:

```bash
cd /Users/junejae/workspace/m_i_test && chmod +x scripts/*.sh && MIG_TARGET_GPU_INDEX=1 RUN_MIG_PREPARE=0 ./scripts/bootstrap_gpu1_mig_stack.sh
```

## Repartition GPU1 to 7x MIG slices

```bash
cd /Users/junejae/workspace/m_i_test
chmod +x scripts/*.sh
MIG_TARGET_GPU_INDEX=1 MIG_ONE_G_PROFILE_ID=19 ./scripts/mig_repartition_gpu1_to_7x1g.sh
```

Then run:

```bash
MIG_TARGET_GPU_INDEX=1 RUN_MIG_PREPARE=0 ./scripts/bootstrap_gpu1_mig_stack.sh
```

## 1) Prepare MIG on GPU 1 only

```bash
cp .env.example .env
chmod +x scripts/*.sh
MIG_TARGET_GPU_INDEX=1 ./scripts/mig_prepare_gpu1.sh
```

Optional auto-create (example only, profile ids vary by driver/GPU firmware):

```bash
MIG_TARGET_GPU_INDEX=1 MIG_CREATE_ARGS='19,19' ./scripts/mig_prepare_gpu1.sh
```

## 2) Fill MIG UUIDs in `.env`

```bash
MIG_TARGET_GPU_INDEX=1 ./scripts/print_mig_uuid_env.sh
```

Copy output values into `.env` for `MIG_UUID_1` ~ `MIG_UUID_5`.

## 3) Start inference services

```bash
docker compose up -d
```

If you hit `Engine core initialization failed`, reduce memory pressure in `.env` first:

```bash
MAX_MODEL_LEN_1=1024
MAX_MODEL_LEN_2=1024
MAX_NUM_SEQS_1=1
MAX_NUM_SEQS_2=1
MAX_NUM_BATCHED_TOKENS_1=512
MAX_NUM_BATCHED_TOKENS_2=512
GPU_MEMORY_UTILIZATION_1=0.9
GPU_MEMORY_UTILIZATION_2=0.9
VLLM_EXTRA_ARGS_1=--swap-space 8 --enforce-eager
VLLM_EXTRA_ARGS_2=--swap-space 24 --cpu-offload-gb 12 --enforce-eager
```

Then recreate:

```bash
docker compose up -d --force-recreate
```

For `Qwen/Qwen3-VL-8B-Instruct` specifically, this profile is safer on small MIG slices:

```bash
MAX_MODEL_LEN_2=768
MAX_NUM_SEQS_2=1
MAX_NUM_BATCHED_TOKENS_2=256
GPU_MEMORY_UTILIZATION_2=0.9
VLLM_EXTRA_ARGS_2=--swap-space 24 --cpu-offload-gb 12 --enforce-eager
MM_IMAGE_LIMIT_2=1
```

For `dragonkue/BGE-m3-ko` specifically, this profile is a good starting point:

```bash
MAX_MODEL_LEN_3=512
MAX_NUM_SEQS_3=4
MAX_NUM_BATCHED_TOKENS_3=512
GPU_MEMORY_UTILIZATION_3=0.9
VLLM_EXTRA_ARGS_3=--swap-space 8
```

For `Dongjin-kr/ko-reranker` specifically, this profile is a good starting point:

```bash
MAX_MODEL_LEN_4=512
MAX_NUM_SEQS_4=4
MAX_NUM_BATCHED_TOKENS_4=512
GPU_MEMORY_UTILIZATION_4=0.9
VLLM_EXTRA_ARGS_4=--swap-space 8
```

For `openai/whisper-large-v3` specifically, this ASR profile is a good starting point:

```bash
ASR_DEVICE_5=cuda
ASR_COMPUTE_TYPE_5=float16
ASR_BEAM_SIZE_5=1
ASR_LANGUAGE_5=ko
```

Endpoints:
- `http://localhost:${PORT_1:-8101}/v1`
- `http://localhost:${PORT_2:-8102}/v1`
- `http://localhost:${PORT_3:-8103}/v1`
- `http://localhost:${PORT_4:-8104}/v1`
- `http://localhost:${PORT_5:-8105}/v1`

Health checks:

```bash
curl -fsS http://localhost:${PORT_1:-8101}/health
curl -fsS http://localhost:${PORT_2:-8102}/health
curl -fsS http://localhost:${PORT_3:-8103}/health
curl -fsS http://localhost:${PORT_4:-8104}/health
curl -fsS http://localhost:${PORT_5:-8105}/health
```

## 4) Quick test requests

Gemma 3 (text):

```bash
curl -sS http://localhost:${PORT_1:-8101}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma3-4b-it",
    "messages": [{"role": "user", "content": "한 줄로 자기소개 해줘."}]
  }'
```

Qwen3-VL (image + text):

```bash
curl -sS http://localhost:${PORT_2:-8102}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-vl-8b-instruct",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "이미지에서 보이는 장면을 2문장으로 설명해줘."},
        {"type": "image_url", "image_url": {"url": "https://picsum.photos/640/360"}}
      ]
    }]
  }'
```

BGE-m3-ko (embeddings):

```bash
curl -sS http://localhost:${PORT_3:-8103}/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bge-m3-ko",
    "input": ["안녕하세요", "벡터 검색 테스트 문장입니다."]
  }'
```

ko-reranker (candidate scoring/compat check):

```bash
curl -sS http://localhost:${PORT_4:-8104}/v1/models
```

whisper-large-v3 (transcription):

```bash
curl -sS http://localhost:${PORT_5:-8105}/v1/audio/transcriptions \
  -F "file=@/absolute/path/sample.wav" \
  -F "model=openai/whisper-large-v3" \
  -F "language=ko"
```

## Notes

- This stack does not allocate or touch `GPU 0`.
- `mig-vllm-1` to `mig-vllm-4` use `--tensor-parallel-size 1` for MIG-isolated inference.
- `gemma-3-4b-it` 사용 전 Hugging Face에서 모델 사용 약관 동의가 필요할 수 있습니다.
- `HUGGING_FACE_HUB_TOKEN`을 `.env`에 설정해야 private/gated 모델 pull이 가능합니다.
- If MIG layout changes or host reboots, MIG UUIDs can change. Re-run UUID extraction and update `.env`.
