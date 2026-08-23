# video-encode

Watches an input directory, re-encodes video files to H.265 (HEVC) for Plex, writes
the result to an output directory (mirroring subfolders), deletes the original on success,
and optionally asks Plex to do a targeted rescan of the affected folder.

## How it works

- Every `SCAN_INTERVAL_SECONDS` (default 300s) the container scans each configured job's
  input directory recursively for video files matching `VIDEO_EXTENSIONS`.
- A file is only processed once its size has stopped changing for `STABLE_CHECK_SECONDS`,
  to avoid picking up a file that's still being copied/downloaded.
- Encoding is done to a temporary `.part` file first, verified against the source (duration
  check, tolerance `DURATION_TOLERANCE_SECONDS`), then atomically renamed into place in
  `OUTPUT_DIR`. Output is always `.mkv` (best subtitle/chapter/metadata support).
- All streams are mapped (`-map 0`) and file-level metadata/chapters are preserved
  (`-map_metadata 0 -map_chapters 0`). Audio/subtitles are stream-copied by default.
- Only after the verified output exists is the original file in `INPUT_DIR` deleted.
- If `SKIP_IF_ALREADY_HEVC=true` (default) and the source is already HEVC, the file is
  copied through unchanged instead of being re-encoded.
- Before touching a file, a lock directory is created next to it (`.video-encode-lock.<name>`)
  so multiple systems can safely run this tool concurrently against the same shared
  input/output mounts; a system that finds a file already locked skips it until the next
  scan. A lock older than `FILE_LOCK_STALE_SECONDS` is assumed abandoned (e.g. the owning
  system crashed) and is reclaimed.
- If `EXTRACT_ARCHIVES=true` (default), release folders containing rar/zip/7z archives
  (including headerless multi-volume rar sets with no first `.rar` volume) are extracted
  in place before the video scan runs. Extraction is skipped if a video file is already
  present in that folder. If extraction doesn't yield a video file, the archive is left
  untouched and an error is logged; if it succeeds, the archive parts are removed once the
  extracted video has been successfully encoded.
- Directories named `Sample`/`Samples` (see `SAMPLE_DIR_NAMES`) are treated as preview clips
  and are never scanned or encoded.
- If configured, Plex is asked to run a **partial/targeted scan** of just the output
  subfolder (not a full library refresh) so it picks up the change quickly.
- For each encode, the configured hardware order is attempted in sequence. A failed
  NVENC initialization falls back to QSV, then software libx265.

## Multiple paths

Set `JOBS` to semicolon-separated entries using this format:

```text
name|container_input|container_output|plex_section_id|plex_input_path|plex_output_path
```

Example:

```text
JOBS=TV|/mnt/gaia/Video/TV-Shows/Original|/mnt/gaia/Video/TV-Shows/Production|2|/share/GaiaVideo/TV-Shows/Original|/share/GaiaVideo/TV-Shows/Production;Movies|/mnt/gaia/Video/Movies/Original|/mnt/gaia/Video/Movies/Production|1|/share/GaiaVideo/Movies/Original|/share/GaiaVideo/Movies/Production
```

The `MEDIA_ROOT_HOST_DIR` mount must contain every container input/output path. Jobs run
sequentially, and queue/conversion messages include the job name.

## Important: Plex ratings/watched-status caveat

Star ratings, watch status, and viewing history are stored in **Plex's own database**,
keyed to a matched metadata item (movie/episode) — they are not stored in the video file
itself. Replacing a file does **not** lose that data as long as:

- The new file lands in the **same relative path/filename convention** Plex already knows
  (e.g. same show/season folder and matching filename), so Plex treats it as an updated
  version of the same item rather than a brand new one, and
- The library item isn't deleted/removed from Plex in between (e.g. via "empty trash").

If `OUTPUT_DIR` is a brand-new location Plex hasn't scanned before, files landing there
will appear as new library items with no rating/history, regardless of what this tool does.
`map_metadata`/`map_chapters` only preserve metadata embedded in the file itself (title,
chapters, language tags, etc.), not Plex's server-side user data.

### API-assisted migration

Set `PLEX_METADATA_MIGRATION=true` to have the container query Plex for the old item before
deletion, then find the new item after the Production partial scan. It restores the Plex
user rating when one exists, marks the new item watched when the old item had been viewed,
and restores the original **date added** timestamp. Plex does not expose a supported endpoint
to copy the exact view count, last-viewed date, or resume position, so those values are logged
as not migrated. A failed API migration never prevents a verified output from replacing the
source file.

## Configuration

Copy `.env.example` to `.env` and adjust. Key variables:

| Variable | Default | Notes |
|---|---|---|
| `HW_ACCEL_ORDER` | `nvenc,qsv,software` | comma-separated fallback order for each file |
| `CRF` | `20` | libx265 quality (software mode), lower = better/larger |
| `PRESET` | `medium` | libx265 speed/efficiency tradeoff |
| `NVENC_CQ` / `NVENC_PRESET` | `23` / `p5` | NVENC quality/preset |
| `QSV_QUALITY` | `23` | QSV global quality |
| `AUDIO_CODEC` | `copy` | stream-copy audio; set e.g. `aac` to transcode |
| `SCAN_INTERVAL_SECONDS` | `300` | how often to scan for new files |
| `FILE_LOCK_STALE_SECONDS` | `21600` | reclaim a per-file lock left behind by a crashed run on another system |
| `EXTRACT_ARCHIVES` | `true` | extract rar/zip/7z release archives in place before scanning for video |
| `SAMPLE_DIR_NAMES` | `sample samples preview previews` | directory names (case-insensitive) excluded as preview clips |
| `CPU_CORES` | — | docker-compose `cpuset`: host CPU cores the container may use, e.g. `0-15` |
| `CPU_LIMIT` | — | docker-compose CPU time cap in core-equivalents, e.g. `16` |
| `FFMPEG_NICE_LEVEL` | `15` | `nice` level for the ffmpeg process (higher = lower CPU priority) |
| `FFMPEG_IONICE_CLASS` / `FFMPEG_IONICE_LEVEL` | `2` / `7` | `ionice` class/level for ffmpeg (lower I/O priority) |
| `PLEX_URL` / `PLEX_TOKEN` / `PLEX_SECTION_ID` | — | all three required to enable Plex notification |
| `PLEX_PATH_MAP_FROM` / `PLEX_PATH_MAP_TO` | — | remap this container's output path to the path Plex sees, if they differ |
| `PLEX_METADATA_MIGRATION` | `false` | snapshot old Plex state and restore supported fields on the new item |
| `PLEX_INPUT_PATH_MAP_FROM` / `PLEX_INPUT_PATH_MAP_TO` | `/input` / — | map the old input path to Plex's Original path for the snapshot |
| `PLEX_MIGRATION_TIMEOUT_SECONDS` | `900` | maximum wait for Plex to index the new output item |

Finding your `PLEX_TOKEN`: see Plex's docs on "Finding an authentication token". Finding
`PLEX_SECTION_ID`: visit the library in Plex web, the number in the URL after
`/library/sections/` is the section ID (or query `GET /library/sections` with your token).

## Hardware acceleration

- **NVENC** is attempted first by default. Install `nvidia-container-toolkit` on the host;
  the GPU reservation is active in [docker-compose.yml](docker-compose.yml).
- **QSV** is attempted second by default through the active `/dev/dri` passthrough. The
  image includes `intel-media-va-driver-non-free`.
- Software libx265 is the final fallback and provides the best quality/compression, but is
  slowest. Change `HW_ACCEL_ORDER` to alter the order.

## Running

```bash
cp .env.example .env
# edit .env: set MEDIA_ROOT_HOST_DIR, JOBS, and Plex credentials as needed
docker compose up -d --build
docker compose logs -f
```
