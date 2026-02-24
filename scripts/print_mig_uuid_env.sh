#!/usr/bin/env bash
set -euo pipefail

TARGET_GPU_INDEX="${MIG_TARGET_GPU_INDEX:-1}"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi not found" >&2
  exit 1
fi

awk_script='
  /^GPU [0-9]+:/ {
    current_gpu=$2
    sub(/:/,"",current_gpu)
    next
  }
  /MIG-/ && current_gpu == target {
    match($0, /MIG-[A-Za-z0-9-]+/)
    if (RSTART > 0) {
      uuids[++count] = substr($0, RSTART, RLENGTH)
    }
  }
  END {
    if (count == 0) {
      print "No MIG UUID found on GPU " target > "/dev/stderr"
      exit 1
    }
    for (i = 1; i <= count; i++) {
      printf("MIG_UUID_%d=%s\n", i, uuids[i])
    }
  }
'

nvidia-smi -L | awk -v target="${TARGET_GPU_INDEX}" "${awk_script}"
