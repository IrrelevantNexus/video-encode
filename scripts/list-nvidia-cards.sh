#!/usr/bin/env bash
set -uo pipefail

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "[gpu] WARNING: nvidia-smi is unavailable; cannot list visible NVIDIA GPUs" >&2
    exit 127
fi

echo "[gpu] NVIDIA GPUs visible inside the container:"
nvidia-smi --query-gpu=index,name,uuid,pci.bus_id --format=csv || {
    status=$?
    echo "[gpu] WARNING: failed to query visible NVIDIA GPUs" >&2
    exit "$status"
}
