#!/usr/bin/env bash
# Triggers a targeted Plex "partial scan" of the folder containing a newly written file,
# so Plex picks up the replacement quickly instead of waiting for its own scheduled scan.
#
# Usage: notify_plex.sh /container/path/to/output/folder
set -euo pipefail

FOLDER="${1:-}"

if [[ -z "${PLEX_URL:-}" || -z "${PLEX_TOKEN:-}" || -z "${PLEX_SECTION_ID:-}" ]]; then
    echo "[notify_plex] PLEX_URL / PLEX_TOKEN / PLEX_SECTION_ID not fully configured, skipping Plex notification"
    exit 0
fi

if [[ -z "${FOLDER}" ]]; then
    echo "[notify_plex] no folder given, skipping"
    exit 0
fi

# Translate the container-side path to the path Plex itself sees, if they differ
# (e.g. this container mounts /output but Plex sees /data/media/tv on its own host/container).
PLEX_PATH="${FOLDER}"
if [[ -n "${PLEX_PATH_MAP_FROM:-}" && -n "${PLEX_PATH_MAP_TO:-}" ]]; then
    PLEX_PATH="${FOLDER/${PLEX_PATH_MAP_FROM}/${PLEX_PATH_MAP_TO}}"
    echo "[notify_plex] mapped path: ${FOLDER} -> ${PLEX_PATH}"
fi

urlencode() {
    local raw="$1" out="" c
    for (( i=0; i<${#raw}; i++ )); do
        c="${raw:i:1}"
        case "$c" in
            [a-zA-Z0-9._~/]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

ENCODED_PATH=$(urlencode "$PLEX_PATH")

URL="${PLEX_URL%/}/library/sections/${PLEX_SECTION_ID}/refresh?path=${ENCODED_PATH}&X-Plex-Token=${PLEX_TOKEN}"

echo "[notify_plex] requesting partial scan of: ${PLEX_PATH} (section ${PLEX_SECTION_ID} on ${PLEX_URL})"

start_ts=$(date +%s.%N)
http_status=$(curl -sS -o /tmp/notify_plex_response.txt -w '%{http_code}' -X GET "${URL}" 2>/tmp/notify_plex_error.txt)
curl_exit=$?
elapsed=$(awk -v s="$start_ts" -v e="$(date +%s.%N)" 'BEGIN{printf "%.2f", e-s}')

if [[ "$curl_exit" -ne 0 ]]; then
    echo "[notify_plex] ERROR: could not reach Plex at ${PLEX_URL} (curl exit ${curl_exit}, ${elapsed}s): $(sed "s/${PLEX_TOKEN}/***REDACTED***/g" /tmp/notify_plex_error.txt 2>/dev/null)"
elif [[ "$http_status" == "200" ]]; then
    echo "[notify_plex] Plex scan requested successfully (HTTP ${http_status}, ${elapsed}s)"
else
    echo "[notify_plex] WARNING: Plex responded with HTTP ${http_status} (${elapsed}s): $(sed "s/${PLEX_TOKEN}/***REDACTED***/g" /tmp/notify_plex_response.txt 2>/dev/null | head -c 300)"
fi
rm -f /tmp/notify_plex_response.txt /tmp/notify_plex_error.txt
