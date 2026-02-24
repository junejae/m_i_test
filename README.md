# m_i_test

H100 2-GPU host template for MIG-based multi-inference with Docker Compose.

This template assumes:
- `GPU 0`: already used by another workload (for example an existing full-GPU vLLM server)
- `GPU 1`: partitioned with MIG, then each MIG slice runs one independent vLLM server container

## Prerequisites

- NVIDIA driver + CUDA stack with H100 MIG support
- Docker Engine + Compose plugin
- NVIDIA Container Toolkit configured for Docker

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

Copy output values into `.env` for `MIG_UUID_1`, `MIG_UUID_2`.

## 3) Start inference services

```bash
docker compose up -d
```

Endpoints:
- `http://localhost:${PORT_1:-8101}/v1`
- `http://localhost:${PORT_2:-8102}/v1`

Health checks:

```bash
curl -fsS http://localhost:${PORT_1:-8101}/health
curl -fsS http://localhost:${PORT_2:-8102}/health
```

## Notes

- This stack does not allocate or touch `GPU 0`.
- Each vLLM service uses `--tensor-parallel-size 1` for MIG-isolated inference.
- If MIG layout changes or host reboots, MIG UUIDs can change. Re-run UUID extraction and update `.env`.
