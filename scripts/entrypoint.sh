#!/usr/bin/env bash
set -euo pipefail

SCAN_INTERVAL_SECONDS="${SCAN_INTERVAL_SECONDS:-300}"

echo "[entrypoint] video-encode starting. Scanning every ${SCAN_INTERVAL_SECONDS}s."
echo "[entrypoint] JOBS=${JOBS:-default} HW_ACCEL_ORDER=${HW_ACCEL_ORDER:-nvenc,qsv,software}"

while true; do
    /app/scripts/encode.sh || echo "[entrypoint] encode.sh exited with an error, will retry next cycle"
    sleep "${SCAN_INTERVAL_SECONDS}"
done
