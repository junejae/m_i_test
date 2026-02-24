#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer currently supports Ubuntu/Debian (apt-get) only." >&2
  exit 1
fi

echo "[1/7] Install prerequisites"
apt-get update
apt-get install -y curl gpg ca-certificates

echo "[2/7] Configure NVIDIA libnvidia-container repository"
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list

echo "[3/7] Install NVIDIA Container Toolkit"
apt-get update
apt-get install -y nvidia-container-toolkit

echo "[4/7] Configure Docker runtime"
nvidia-ctk runtime configure --runtime=docker

echo "[5/7] Restart Docker"
systemctl restart docker

echo "[6/7] Validate toolkit and runtime"
nvidia-ctk --version
docker info | grep -i runtimes || true

echo "[7/7] Done"
echo "If 'nvidia' is listed in Docker runtimes, you can run:"
echo "  docker compose up -d"
