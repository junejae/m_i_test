#!/usr/bin/env bash
set -euo pipefail

TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX:-1}"
ONE_G_PROFILE_ID="${MIG_ONE_G_PROFILE_ID:-19}"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi not found" >&2
  exit 1
fi

echo "[1/6] GPU inventory"
nvidia-smi -L

echo "[2/6] Enable MIG mode on GPU ${TARGET_GPU_INDEX}"
sudo nvidia-smi -i "${TARGET_GPU_INDEX}" -mig 1

echo "[3/6] Available MIG profiles on GPU ${TARGET_GPU_INDEX}"
nvidia-smi mig -i "${TARGET_GPU_INDEX}" -lgip

echo "[4/6] Delete existing MIG compute and GPU instances on GPU ${TARGET_GPU_INDEX}"
sudo nvidia-smi mig -i "${TARGET_GPU_INDEX}" -dci || true
sudo nvidia-smi mig -i "${TARGET_GPU_INDEX}" -dgi || true

echo "[5/6] Create 7x 1g profile instances using profile id ${ONE_G_PROFILE_ID}"
sudo nvidia-smi mig -i "${TARGET_GPU_INDEX}" -cgi \
  "${ONE_G_PROFILE_ID},${ONE_G_PROFILE_ID},${ONE_G_PROFILE_ID},${ONE_G_PROFILE_ID},${ONE_G_PROFILE_ID},${ONE_G_PROFILE_ID},${ONE_G_PROFILE_ID}" -C

echo "[6/6] Final MIG devices"
nvidia-smi -L

echo
echo "Next steps:"
echo "  1) MIG_TARGET_GPU_INDEX=${TARGET_GPU_INDEX} ./scripts/print_mig_uuid_env.sh"
echo "  2) Update .env MIG_UUID_1..MIG_UUID_3 (or use bootstrap script)."
