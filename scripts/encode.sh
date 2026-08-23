#!/usr/bin/env bash
# Scans INPUT_DIR recursively for video files, re-encodes each to H.265 into OUTPUT_DIR
# (mirroring the subfolder structure), and removes the original on success.
set -uo pipefail

INPUT_DIR="${INPUT_DIR:-/input}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
WORK_DIR="${WORK_DIR:-/var/tmp/video-encode-work}"
LOCK_FILE="${LOCK_FILE:-/var/tmp/video-encode.lock}"

HW_ACCEL_ORDER="${HW_ACCEL_ORDER:-nvenc,qsv,software}"
CRF="${CRF:-20}"                        # software libx265 quality (lower = better/larger, 18-24 typical)
PRESET="${PRESET:-medium}"              # software libx265 preset
NVENC_CQ="${NVENC_CQ:-23}"              # nvenc constant quality
NVENC_PRESET="${NVENC_PRESET:-p5}"
QSV_QUALITY="${QSV_QUALITY:-23}"        # qsv global_quality
AUDIO_CODEC="${AUDIO_CODEC:-copy}"      # copy | aac | ac3 ...
VIDEO_EXTENSIONS="${VIDEO_EXTENSIONS:-mkv mp4 avi mov m4v ts wmv flv webm}"
TEMP_FILE_SUFFIXES="${TEMP_FILE_SUFFIXES:-.part .tmp .partial .download}"
STABLE_CHECK_SECONDS="${STABLE_CHECK_SECONDS:-30}"
DURATION_TOLERANCE_SECONDS="${DURATION_TOLERANCE_SECONDS:-5}"
SKIP_IF_ALREADY_HEVC="${SKIP_IF_ALREADY_HEVC:-true}"
PROGRESS_LOG_INTERVAL_SECONDS="${PROGRESS_LOG_INTERVAL_SECONDS:-30}"
PLEX_METADATA_MIGRATION="${PLEX_METADATA_MIGRATION:-true}"
# Cross-host lock so multiple systems can run against the same shared input/output mounts.
FILE_LOCK_STALE_SECONDS="${FILE_LOCK_STALE_SECONDS:-21600}"
# Compressed scene releases (rar/zip/7z) are extracted in place before scanning for video files.
EXTRACT_ARCHIVES="${EXTRACT_ARCHIVES:-true}"
# Directory names (case-insensitive) treated as preview/sample clips and excluded entirely.
SAMPLE_DIR_NAMES="${SAMPLE_DIR_NAMES:-sample samples preview previews}"
# Lower scheduling/I-O priority so ffmpeg yields to other work on the host under contention.
FFMPEG_NICE_LEVEL="${FFMPEG_NICE_LEVEL:-15}"
FFMPEG_IONICE_CLASS="${FFMPEG_IONICE_CLASS:-2}"   # 2=best-effort, 3=idle
FFMPEG_IONICE_LEVEL="${FFMPEG_IONICE_LEVEL:-7}"   # 0-7, higher = lower priority (best-effort only)
# Re-evaluate CPU core count/niceness for each file based on current host load, instead of a
# fixed affinity for the whole container's lifetime.
DYNAMIC_AFFINITY="${DYNAMIC_AFFINITY:-true}"
MIN_ENCODE_CORES="${MIN_ENCODE_CORES:-2}"
MAX_ENCODE_CORES="${MAX_ENCODE_CORES:-}"   # empty = no cap beyond the cores available to the container

mkdir -p "$WORK_DIR"

# Persists across scan cycles for the lifetime of the container (reset on container restart).
CONVERSION_COUNT_FILE="$WORK_DIR/conversions_count"
[[ -f "$CONVERSION_COUNT_FILE" ]] || echo 0 > "$CONVERSION_COUNT_FILE"

bump_conversion_count() {
    local total
    total=$(( $(cat "$CONVERSION_COUNT_FILE") + 1 ))
    echo "$total" > "$CONVERSION_COUNT_FILE"
    echo "[encode] conversions completed this container run: $total"
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "[encode] another run is still in progress, skipping this cycle"
    exit 0
fi

is_stable() {
    local file="$1"
    local size1 size2
    size1=$(stat -c%s "$file" 2>/dev/null) || return 1
    sleep "$STABLE_CHECK_SECONDS"
    size2=$(stat -c%s "$file" 2>/dev/null) || return 1
    if [[ "$size1" != "$size2" ]]; then
        echo "[encode] file still changing: $file (${size1} -> ${size2} bytes)"
        return 1
    fi
    return 0
}

# Per-file lock directory next to the input file, visible to every host sharing the same mount.
# mkdir is atomic even over NFS/SMB, unlike flock, which only coordinates within one host.
acquire_file_lock() {
    local lock_dir="$1"
    if mkdir "$lock_dir" 2>/dev/null; then
        { echo "host=$(hostname)"; echo "pid=$$"; echo "started=$(date -Iseconds)"; } > "$lock_dir/owner" 2>/dev/null || true
        return 0
    fi
    local age
    age=$(( $(date +%s) - $(stat -c%Y "$lock_dir" 2>/dev/null || date +%s) ))
    if (( age > FILE_LOCK_STALE_SECONDS )); then
        echo "[encode] reclaiming stale lock (${age}s old): $lock_dir"
        rm -rf "$lock_dir" 2>/dev/null
        if mkdir "$lock_dir" 2>/dev/null; then
            { echo "host=$(hostname)"; echo "pid=$$"; echo "started=$(date -Iseconds)"; } > "$lock_dir/owner" 2>/dev/null || true
            return 0
        fi
    fi
    return 1
}

release_file_lock() {
    rm -rf "$1" 2>/dev/null || true
}

# True if any path component of $1 (relative to INPUT_DIR) matches a configured sample-dir name.
is_sample_dir() {
    local dir="$1" rel seg name
    rel="${dir#"$INPUT_DIR"/}"
    local -a segments
    IFS='/' read -ra segments <<< "$rel"
    for seg in "${segments[@]}"; do
        for name in $SAMPLE_DIR_NAMES; do
            [[ "${seg,,}" == "${name,,}" ]] && return 0
        done
    done
    return 1
}

# True if $1 (a directory) already has a video file directly in it (i.e. already extracted).
dir_has_video() {
    local dir="$1" ext
    local -a existing
    for ext in $VIDEO_EXTENSIONS; do
        existing=("$dir"/*."$ext")
        (( ${#existing[@]} > 0 )) && return 0
    done
    return 1
}

# Extracts compressed scene releases (rar/zip/7z, including headerless multi-volume rar sets
# with no first .rar volume) so the normal encode pass can pick up the resulting video file.
# On success, records the archive parts in a marker file so process_file can remove them once
# the extracted video has been encoded; on failure the archives are left untouched for review.
extract_release_archives() {
    [[ "$EXTRACT_ARCHIVES" == "true" ]] || return 0
    local dir entry lock_dir marker
    local -a parts
    while IFS= read -r -d '' dir; do
        is_sample_dir "$dir" && continue
        dir_has_video "$dir" && continue

        entry=""
        parts=("$dir"/*.[Rr][Aa][Rr] "$dir"/*.[Rr]00 "$dir"/*.[Zz][Ii][Pp] "$dir"/*.7[Zz] "$dir"/*.001)
        (( ${#parts[@]} == 0 )) && continue
        entry="${parts[0]}"

        lock_dir="$dir/.video-encode-extract-lock"
        if ! acquire_file_lock "$lock_dir"; then
            echo "[encode] skipping extraction, locked by another system: $dir"
            continue
        fi

        parts=("$dir"/*.[Rr][Aa][Rr] "$dir"/*.[Rr][0-9][0-9] "$dir"/*.[Zz][Ii][Pp] "$dir"/*.[Zz][0-9][0-9] "$dir"/*.7[Zz] "$dir"/*.[0-9][0-9][0-9])
        echo "[encode] extracting compressed release: $entry"
        case "${entry,,}" in
            *.rar|*.r00)
                unrar x -y -o+ "$entry" "$dir/" > "$WORK_DIR/extract.log" 2>&1
                ;;
            *)
                7z x -y "$entry" -o"$dir" > "$WORK_DIR/extract.log" 2>&1
                ;;
        esac

        if dir_has_video "$dir"; then
            echo "[encode] extraction succeeded: $dir"
            marker="$dir/.video-encode-archive-cleanup"
            printf '%s\n' "${parts[@]}" > "$marker"
        else
            echo "[encode] ERROR: extraction produced no video file, leaving archive in place: $dir"
            tail -n 20 "$WORK_DIR/extract.log" 2>/dev/null || true
        fi
        release_file_lock "$lock_dir"
    done < <(find "$INPUT_DIR" -type f \( -iname '*.rar' -o -iname '*.r00' -o -iname '*.zip' -o -iname '*.7z' -o -iname '*.001' \) -printf '%h\0' | sort -zu)
}

get_duration() {
    ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | cut -d. -f1
}

is_already_hevc() {
    local codec
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null)
    [[ "$codec" == "hevc" ]]
}

build_video_args() {
    local encoder="$1"
    case "$encoder" in
        nvenc)
            echo "-c:v hevc_nvenc -preset ${NVENC_PRESET} -rc vbr -cq ${NVENC_CQ} -b:v 0"
            ;;
        qsv)
            echo "-c:v hevc_qsv -global_quality ${QSV_QUALITY} -preset medium"
            ;;
        *)
            echo "-c:v libx265 -preset ${PRESET} -crf ${CRF}"
            ;;
    esac
}

encode_with_fallback() {
    local label="$1" src_duration="$2" output_path="$3" recovery_mode="${4:-false}"
    shift 4
    local encoder video_args
    local -a common_args video_arg_array
    common_args=("$@")
    IFS=',' read -ra encoders <<< "$HW_ACCEL_ORDER"
    for encoder in "${encoders[@]}"; do
        encoder="${encoder//[[:space:]]/}"
        video_args=$(build_video_args "$encoder")
        read -ra video_arg_array <<< "$video_args"
        if [[ "$recovery_mode" == "true" ]]; then
            echo "[encode] trying ${encoder} with decode-error tolerance: ${label}"
        else
            echo "[encode] trying ${encoder}: ${label}"
        fi
        if run_ffmpeg_with_progress "$label ($encoder)" "$src_duration" "${common_args[@]}" "${video_arg_array[@]}" -f matroska "$output_path"; then
            echo "[encode] encoder selected: ${encoder}"
            return 0
        fi
        echo "[encode] ${encoder} failed, trying next encoder"
    done
    return 1
}

# Average idle% over ~1s for the given space-separated list of CPU core numbers, using /proc/stat.
sample_avg_idle_pct() {
    local cores="$1" snap1 snap2
    snap1=$(awk -v cores="$cores" '
        BEGIN { n=split(cores,c," "); for (i=1;i<=n;i++) want["cpu" c[i]]=1 }
        $1 in want { idle=$5+$6; total=0; for (f=2; f<=NF; f++) total+=$f; print idle, total }
    ' /proc/stat 2>/dev/null)
    sleep 1
    snap2=$(awk -v cores="$cores" '
        BEGIN { n=split(cores,c," "); for (i=1;i<=n;i++) want["cpu" c[i]]=1 }
        $1 in want { idle=$5+$6; total=0; for (f=2; f<=NF; f++) total+=$f; print idle, total }
    ' /proc/stat 2>/dev/null)
    awk -v s1="$snap1" -v s2="$snap2" 'BEGIN {
        n1=split(s1, a1, "\n"); n2=split(s2, a2, "\n");
        di=0; dt=0
        for (i=1;i<=n1 && i<=n2;i++) {
            split(a1[i], p1, " "); split(a2[i], p2, " ")
            di += (p2[1]-p1[1]); dt += (p2[2]-p1[2])
        }
        if (dt<=0) dt=1
        pct = di*100/dt; if (pct<0) pct=0; if (pct>100) pct=100
        printf "%d", pct
    }'
}

# Picks how many CPU cores (and what nice level) this encode should use, based on current host
# load across the cores actually available to this container. Sets ENCODE_CPU_LIST/ENCODE_NICE_LEVEL.
compute_affinity() {
    [[ "$DYNAMIC_AFFINITY" == "true" ]] || return 0
    local allowed_list part start end n
    allowed_list=$(taskset -pc $$ 2>/dev/null | awk -F': ' '{print $2}')
    [[ -z "$allowed_list" ]] && allowed_list="0-$(( $(nproc) - 1 ))"

    local -a cores=()
    for part in ${allowed_list//,/ }; do
        if [[ "$part" == *-* ]]; then
            start="${part%-*}"; end="${part#*-}"
            for (( n=start; n<=end; n++ )); do cores+=("$n"); done
        else
            cores+=("$part")
        fi
    done
    (( ${#cores[@]} == 0 )) && cores=(0)
    local total_avail=${#cores[@]}

    local idle_pct
    idle_pct=$(sample_avg_idle_pct "${cores[*]}")
    [[ -z "$idle_pct" ]] && idle_pct=50

    local want_cores
    want_cores=$(( (total_avail * idle_pct + 50) / 100 ))
    (( want_cores < MIN_ENCODE_CORES )) && want_cores=$MIN_ENCODE_CORES
    (( want_cores > total_avail )) && want_cores=$total_avail
    if [[ -n "$MAX_ENCODE_CORES" ]] && (( want_cores > MAX_ENCODE_CORES )); then
        want_cores=$MAX_ENCODE_CORES
    fi

    local -a picked=("${cores[@]:0:$want_cores}")
    ENCODE_CPU_LIST=$(IFS=,; echo "${picked[*]}")

    # Low idle -> nice 19 (most polite); high idle -> the configured baseline (never more aggressive).
    ENCODE_NICE_LEVEL=$(( 19 - (idle_pct * (19 - FFMPEG_NICE_LEVEL) / 100) ))
    (( ENCODE_NICE_LEVEL < FFMPEG_NICE_LEVEL )) && ENCODE_NICE_LEVEL=$FFMPEG_NICE_LEVEL
    (( ENCODE_NICE_LEVEL > 19 )) && ENCODE_NICE_LEVEL=19

    echo "[encode] host idle ${idle_pct}% across ${total_avail} available core(s); using ${want_cores} core(s) [${ENCODE_CPU_LIST}], nice=${ENCODE_NICE_LEVEL}"
}

# Patterns seen when the source itself is damaged: decode errors are expected to carry over to the output.
DECODE_ERROR_PATTERN='Invalid data found when processing input|Invalid NAL unit size|Error while decoding stream|error while decoding MB|is not allocated|co located POCs unavailable'

# Runs ffmpeg in the background and periodically logs progress (% complete, fps, speed, eta)
# parsed from its machine-readable -progress output, since -loglevel warning hides ffmpeg's own stats.
# Sets FFMPEG_SOURCE_HAD_DECODE_ERRORS=true when the source's own stream data looked corrupted.
run_ffmpeg_with_progress() {
    local label="$1" src_duration="$2"
    shift 2
    local progress_file stderr_log
    progress_file=$(mktemp "$WORK_DIR/progress.XXXXXX")
    stderr_log=$(mktemp "$WORK_DIR/ffmpeg-stderr.XXXXXX")

    local nice_level="${ENCODE_NICE_LEVEL:-$FFMPEG_NICE_LEVEL}"
    local -a affinity_args=()
    if [[ "$DYNAMIC_AFFINITY" == "true" && -n "${ENCODE_CPU_LIST:-}" ]]; then
        affinity_args=(taskset --cpu-list "$ENCODE_CPU_LIST")
    fi
    local -a ionice_args=(-c "$FFMPEG_IONICE_CLASS")
    [[ "$FFMPEG_IONICE_CLASS" != "3" ]] && ionice_args+=(-n "$FFMPEG_IONICE_LEVEL")
    nice -n "$nice_level" ionice "${ionice_args[@]}" "${affinity_args[@]}" ffmpeg "$@" -progress "$progress_file" -nostats 2> >(tee "$stderr_log" >&2) &
    local ffmpeg_pid=$!

    if [[ "$src_duration" -gt 0 ]] 2>/dev/null; then
        while kill -0 "$ffmpeg_pid" 2>/dev/null; do
            sleep "$PROGRESS_LOG_INTERVAL_SECONDS"
            kill -0 "$ffmpeg_pid" 2>/dev/null || break
            local out_time_us fps speed percent eta
            out_time_us=$(grep -a '^out_time_us=' "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2)
            fps=$(grep -a '^fps=' "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2)
            speed=$(grep -a '^speed=' "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
            [[ -n "$out_time_us" && "$out_time_us" =~ ^[0-9]+$ ]] || continue
            percent=$(awk -v t="$out_time_us" -v d="$src_duration" 'BEGIN{ if (d>0) printf "%.0f", (t/1000000)/d*100; else print 0 }')
            eta="n/a"
            if [[ -n "$speed" && "$speed" != "0x" && "$speed" =~ ^[0-9.]+x$ ]]; then
                eta=$(awk -v t="$out_time_us" -v d="$src_duration" -v s="${speed%x}" 'BEGIN{ remaining=d-(t/1000000); if (s>0 && remaining>0) printf "%.0fs", remaining/s; else print "n/a" }')
            fi
            echo "[encode] progress: $label ${percent}% fps=${fps:-0} speed=${speed:-n/a} eta=${eta}"
        done
    fi

    wait "$ffmpeg_pid"
    local ffmpeg_exit=$?
    if grep -aqE "$DECODE_ERROR_PATTERN" "$stderr_log" 2>/dev/null; then
        FFMPEG_SOURCE_HAD_DECODE_ERRORS=true
    fi
    rm -f "$progress_file" "$stderr_log"
    return "$ffmpeg_exit"
}

process_file() {
    local input="$1"
    local rel_path rel_dir base_name out_dir final_output tmp_output migration_state
    rel_path="${input#"$INPUT_DIR"/}"
    rel_dir=$(dirname "$rel_path")
    base_name=$(basename "$rel_path")
    base_name="${base_name%.*}"

    out_dir="$OUTPUT_DIR"
    [[ "$rel_dir" != "." ]] && out_dir="$OUTPUT_DIR/$rel_dir"
    final_output="$out_dir/${base_name}.mkv"
    tmp_output="$out_dir/.${base_name}.mkv.part"
    migration_state="$WORK_DIR/plex-metadata-$(printf '%s' "$input" | sha256sum | cut -d' ' -f1).json"

    local lock_dir="$(dirname "$input")/.video-encode-lock.$(basename "$input")"
    if ! acquire_file_lock "$lock_dir"; then
        local owner_info
        owner_info=$(cat "$lock_dir/owner" 2>/dev/null | tr '\n' ' ')
        echo "[encode] skipping, locked by another system (${owner_info:-unknown owner}): $input"
        return 0
    fi
    trap 'release_file_lock "$lock_dir"' RETURN

    if [[ -f "$final_output" ]]; then
        echo "[encode] output already exists, treating as already converted: $final_output"
        if [[ "$PLEX_METADATA_MIGRATION" == "true" ]]; then
            python3 /app/scripts/migrate_plex_metadata.py snapshot "$input" "$migration_state" || true
            /app/scripts/notify_plex.sh "$out_dir" || true
            python3 /app/scripts/migrate_plex_metadata.py apply "$final_output" "$migration_state" || true
        fi
        echo "[encode] removing original because converted output exists: $input"
        rm -f "$input"
        return 0
    fi

    echo "[encode] checking stability: $input"
    if ! is_stable "$input"; then
        echo "[encode] file still being written, will retry next cycle: $input"
        return 0
    fi

    if [[ "$SKIP_IF_ALREADY_HEVC" == "true" ]] && is_already_hevc "$input"; then
        echo "[encode] already HEVC, moving without re-encoding: $input"
        mkdir -p "$out_dir"
        cp -f "$input" "$final_output"
    else
        mkdir -p "$out_dir"
        echo "[encode] encoding (fallback order: ${HW_ACCEL_ORDER}): $input -> $final_output"
        compute_affinity

        local src_duration_precheck
        src_duration_precheck=$(get_duration "$input")
        src_duration_precheck="${src_duration_precheck:-0}"

        # -f matroska is required because ffmpeg can't infer a container from the ".part" temp extension.
        # Keep the stream map explicit and avoid -map_metadata/-map_chapters here: on some FFmpeg builds
        # those options are parsed as stream selectors and trigger the "Invalid stream specifier: map_metadata" error.
        # Some FFmpeg builds reject `-c copy` / `-c:a copy` as stream specifier syntax; the most compatible path is
        # to map the streams explicitly and let the per-encoder video codec set the video stream while leaving the
        # input audio/subtitle streams intact by default.
        local -a ffmpeg_common_args ffmpeg_recovery_args
        ffmpeg_common_args=(-y -hide_banner -loglevel warning -i "$input" \
            -map 0:v:0 -map 0:a -map "0:s?" )
        ffmpeg_recovery_args=(-y -hide_banner -loglevel warning -err_detect ignore_err -i "$input" \
            -map 0:v:0 -map 0:a -map "0:s?" )
        local used_recovery=false
        FFMPEG_SOURCE_HAD_DECODE_ERRORS=false
        if ! encode_with_fallback "$base_name" "$src_duration_precheck" "$tmp_output" false "${ffmpeg_common_args[@]}"; then
            echo "[encode] retrying with decode-error tolerance for damaged input: $input"
            used_recovery=true
            if ! encode_with_fallback "$base_name" "$src_duration_precheck" "$tmp_output" true "${ffmpeg_recovery_args[@]}"; then
                echo "[encode] ERROR: ffmpeg failed for $input"
                rm -f "$tmp_output"
                return 1
            fi
        fi

        # A damaged source can legitimately decode to a shorter output; don't discard a recovered file for that.
        local src_duration out_duration diff
        local source_damaged=false
        [[ "$used_recovery" == "true" || "$FFMPEG_SOURCE_HAD_DECODE_ERRORS" == "true" ]] && source_damaged=true
        src_duration=$(get_duration "$input")
        out_duration=$(get_duration "$tmp_output")
        if [[ -z "$src_duration" || -z "$out_duration" ]]; then
            if [[ "$source_damaged" == "true" ]]; then
                echo "[encode] WARNING: could not verify duration for damaged source $input, keeping recovered output anyway"
            else
                echo "[encode] ERROR: could not verify duration for $input, discarding output"
                rm -f "$tmp_output"
                return 1
            fi
        else
            diff=$(( src_duration - out_duration ))
            diff=${diff#-}
            if (( diff > DURATION_TOLERANCE_SECONDS )); then
                if [[ "$source_damaged" == "true" ]]; then
                    echo "[encode] WARNING: output duration mismatch (src=${src_duration}s out=${out_duration}s) on damaged source, keeping recovered output anyway"
                else
                    echo "[encode] ERROR: output duration mismatch (src=${src_duration}s out=${out_duration}s), discarding output"
                    rm -f "$tmp_output"
                    return 1
                fi
            fi
        fi

        mv -f "$tmp_output" "$final_output"
    fi

    if [[ "$PLEX_METADATA_MIGRATION" == "true" ]]; then
        python3 /app/scripts/migrate_plex_metadata.py snapshot "$input" "$migration_state" || true
    fi

    echo "[encode] success, removing original: $input"
    rm -f "$input"

    local archive_marker="$(dirname "$input")/.video-encode-archive-cleanup"
    if [[ -f "$archive_marker" ]]; then
        echo "[encode] removing source compressed files for extracted release: $(dirname "$input")"
        local archive_file
        while IFS= read -r archive_file; do
            [[ -n "$archive_file" ]] && rm -f "$archive_file"
        done < "$archive_marker"
        rm -f "$archive_marker"
    fi

    bump_conversion_count
    /app/scripts/notify_plex.sh "$out_dir" || true
    if [[ "$PLEX_METADATA_MIGRATION" == "true" ]]; then
        python3 /app/scripts/migrate_plex_metadata.py apply "$final_output" "$migration_state" || true
    fi
}

run_job() {
    local job_name="$1"
    echo "[encode] starting job: ${job_name} (input=${INPUT_DIR}, output=${OUTPUT_DIR}, Plex section=${PLEX_SECTION_ID})"
    shopt -s nullglob globstar nocaseglob

    extract_release_archives

    local -a queue=()
    local ext f suffix base_name_lower
    for ext in $VIDEO_EXTENSIONS; do
        for f in "$INPUT_DIR"/**/*."$ext"; do
            [[ -f "$f" ]] || continue
            if is_sample_dir "$(dirname "$f")"; then
                echo "[encode] ignoring preview/sample file: $f"
                continue
            fi
            base_name_lower="${f##*/}"
            base_name_lower="${base_name_lower,,}"
            for suffix in $TEMP_FILE_SUFFIXES; do
                if [[ "$base_name_lower" == *"${suffix,,}" ]]; then
                    echo "[encode] ignoring temp/partial file: $f"
                    continue 2
                fi
            done
            queue+=("$f")
        done
    done

    if [[ "${#queue[@]}" -eq 0 ]]; then
        echo "[encode] job ${job_name}: no files found to process"
    else
        echo "[encode] job ${job_name}: found ${#queue[@]} file(s) queued for encoding"
        for f in "${queue[@]}"; do
            process_file "$f" || echo "[encode] failed processing: $f"
        done
    fi
}

run_configured_jobs() {
    local job job_name job_input job_output job_section plex_input plex_output
    local job_count=0
    IFS=';' read -ra configured_jobs <<< "$JOBS"
    for job in "${configured_jobs[@]}"; do
        [[ -n "$job" ]] || continue
        IFS='|' read -r job_name job_input job_output job_section plex_input plex_output <<< "$job"
        if [[ -z "$job_name" || -z "$job_input" || -z "$job_output" || -z "$job_section" || -z "$plex_input" || -z "$plex_output" ]]; then
            echo "[encode] invalid job definition (expected name|input|output|section|plex_input|plex_output): $job"
            continue
        fi
        INPUT_DIR="$job_input"
        OUTPUT_DIR="$job_output"
        PLEX_SECTION_ID="$job_section"
        PLEX_INPUT_PATH_MAP_FROM="$job_input"
        PLEX_INPUT_PATH_MAP_TO="$plex_input"
        PLEX_PATH_MAP_FROM="$job_output"
        PLEX_PATH_MAP_TO="$plex_output"
        export PLEX_SECTION_ID PLEX_INPUT_PATH_MAP_FROM PLEX_INPUT_PATH_MAP_TO PLEX_PATH_MAP_FROM PLEX_PATH_MAP_TO
        run_job "$job_name"
        job_count=$((job_count + 1))
    done
    [[ "$job_count" -gt 0 ]] || echo "[encode] JOBS is empty; configure at least one job"
}

if [[ -n "${JOBS:-}" ]]; then
    run_configured_jobs
else
    run_job "default"
fi
