#!/usr/bin/env bash
set -euo pipefail

SCAN_INTERVAL_SECONDS="${SCAN_INTERVAL_SECONDS:-300}"

echo "[entrypoint] video-encode starting. Scanning every ${SCAN_INTERVAL_SECONDS}s."
echo "[entrypoint] JOBS=${JOBS:-default} HW_ACCEL_ORDER=${HW_ACCEL_ORDER:-nvenc,qsv,software}"
echo "[entrypoint] NVENC_GPU_IDS=${NVENC_GPU_IDS:-automatic} MAX_CONCURRENT_ENCODES=${MAX_CONCURRENT_ENCODES:-1}"
echo "[entrypoint] QSV_WORKERS=${QSV_WORKERS:-0}"
/app/scripts/list-nvidia-cards.sh || echo "[entrypoint] GPU inventory unavailable; continuing"

while true; do
    /app/scripts/encode.sh || echo "[entrypoint] encode.sh exited with an error, will retry next cycle"
    sleep "${SCAN_INTERVAL_SECONDS}"
done
