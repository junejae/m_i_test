#!/usr/bin/env bash
set -euo pipefail

TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX:-1}"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi not found" >&2
  exit 1
fi

echo "[1/5] GPU inventory"
nvidia-smi -L

echo "[2/5] Enabling MIG mode on GPU ${TARGET_GPU_INDEX} only"
sudo nvidia-smi -i "${TARGET_GPU_INDEX}" -mig 1

echo "[3/5] Available GPU instance profiles on GPU ${TARGET_GPU_INDEX}"
nvidia-smi mig -i "${TARGET_GPU_INDEX}" -lgip

echo "[4/5] Optional instance creation"
if [[ -n "${MIG_CREATE_ARGS:-}" ]]; then
  echo "Creating instances with: -cgi ${MIG_CREATE_ARGS} -C"
  sudo nvidia-smi mig -i "${TARGET_GPU_INDEX}" -cgi "${MIG_CREATE_ARGS}" -C
else
  cat <<'EOF'
Skip creation (MIG_CREATE_ARGS is empty).
If you want auto-create, run again with an explicit profile list.
Example:
  MIG_TARGET_GPU_INDEX=1 MIG_CREATE_ARGS='19,19' ./scripts/mig_prepare_gpu1.sh
EOF
fi

echo "[5/5] Current MIG devices"
nvidia-smi -L

echo
echo "Next: copy MIG UUIDs from GPU ${TARGET_GPU_INDEX} into .env (MIG_UUID_1, MIG_UUID_2)."
