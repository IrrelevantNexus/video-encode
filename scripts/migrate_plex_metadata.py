#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ElementTree


def log(message):
    print(f"[plex-migrate] {message}", flush=True)


def config():
    values = [os.getenv(name, "") for name in ("PLEX_URL", "PLEX_TOKEN", "PLEX_SECTION_ID")]
    if not all(values):
        return None
    return values


def request_xml(url, method="GET", params=None):
    query = {"X-Plex-Token": os.environ["PLEX_TOKEN"]}
    query.update(params or {})
    request_url = f"{url}?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(request_url, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        return ElementTree.fromstring(response.read())


def request_mutation(url, method="GET", params=None):
    query = {"X-Plex-Token": os.environ["PLEX_TOKEN"]}
    query.update(params or {})
    request_url = f"{url}?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(request_url, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        response.read()


def library_items(plex_url, section_id):
    url = f"{plex_url.rstrip('/')}/library/sections/{section_id}/all"
    return request_xml(url, params={"includeMedia": "1"})


def find_item(root, wanted_path):
    for item in root.iter():
        rating_key = item.attrib.get("ratingKey")
        if not rating_key:
            continue
        for part in item.findall(".//Part"):
            if part.attrib.get("file") == wanted_path:
                return item
    return None


def find_item_by_identity(root, title, duration, exclude_rating_key=None):
    for item in root.iter():
        rating_key = item.attrib.get("ratingKey")
        if not rating_key or item.attrib.get("title") != title:
            continue
        if exclude_rating_key and rating_key == exclude_rating_key:
            continue
        item_duration = int(item.attrib.get("duration", "0") or 0)
        if not duration or not item_duration or abs(item_duration - duration) <= 10000:
            return item
    return None


def mapped_path(path, source, target):
    if source and target and path == source:
        return target
    if source and target and path.startswith(source.rstrip('/') + '/'):
        return target.rstrip('/') + path[len(source.rstrip('/')):]
    return path


def snapshot(input_path, state_path):
    settings = config()
    if not settings:
        log("Plex credentials are incomplete; skipping metadata snapshot")
        return 0
    plex_url, _, section_id = settings
    plex_path = mapped_path(input_path, os.getenv("PLEX_INPUT_PATH_MAP_FROM", "/input"), os.getenv("PLEX_INPUT_PATH_MAP_TO", ""))
    try:
        item = find_item(library_items(plex_url, section_id), plex_path)
    except Exception as error:
        log(f"could not query old Plex item: {error}")
        return 0
    state = {"status": "not_found", "old_path": plex_path}
    if item is not None:
        state = {
            "status": "found",
            "old_path": plex_path,
            "rating_key": item.attrib.get("ratingKey", ""),
            "title": item.attrib.get("title", ""),
            "duration": item.attrib.get("duration", "0"),
            "user_rating": item.attrib.get("userRating", ""),
            "view_count": item.attrib.get("viewCount", "0"),
            "last_viewed_at": item.attrib.get("lastViewedAt", ""),
            "view_offset": item.attrib.get("viewOffset", "0"),
            "added_at": item.attrib.get("addedAt", ""),
        }
        log(f"captured Plex item {state['rating_key']} for {state['title']!r} (rating={state['user_rating'] or 'none'}, views={state['view_count']})")
    else:
        log(f"no Plex item found for old path: {plex_path}")
    with open(state_path, "w", encoding="utf-8") as state_file:
        json.dump(state, state_file)
    return 0


METADATA_TYPE_IDS = {"movie": 1, "show": 2, "season": 3, "episode": 4}


def update_item(plex_url, section_id, metadata_type, rating_key, fields):
    # Plex's per-item PUT /library/metadata/{key} endpoint ignores field edits silently;
    # locked fields like userRating/addedAt must go through the section bulk-edit endpoint.
    url = f"{plex_url.rstrip('/')}/library/sections/{section_id}/all"
    params = {"type": metadata_type, "id": rating_key}
    for field, value in fields.items():
        params[f"{field}.value"] = value
        params[f"{field}.locked"] = "1"
    request_mutation(url, method="PUT", params=params)


def mark_watched(plex_url, rating_key):
    url = f"{plex_url.rstrip('/')}/:/scrobble"
    request_mutation(url, params={"key": rating_key, "identifier": "com.plexapp.plugins.library"})


def apply(state_path, output_path):
    settings = config()
    if not settings or not os.path.exists(state_path):
        return 0
    plex_url, _, section_id = settings
    with open(state_path, encoding="utf-8") as state_file:
        state = json.load(state_file)
    if state.get("status") != "found":
        log("no old Plex state was captured; skipping migration")
        return 0
    plex_path = mapped_path(output_path, os.getenv("PLEX_PATH_MAP_FROM", "/output"), os.getenv("PLEX_PATH_MAP_TO", ""))
    timeout = int(os.getenv("PLEX_MIGRATION_TIMEOUT_SECONDS", "900"))
    deadline = time.time() + timeout
    item = None
    last_log = 0
    while time.time() < deadline:
        try:
            root = library_items(plex_url, section_id)
            item = find_item(root, plex_path)
            if item is None:
                item = find_item_by_identity(root, state.get("title", ""), int(state.get("duration", "0") or 0), state.get("rating_key", ""))
                if item is not None:
                    log(f"matched new Plex item by title/duration fallback: {state['title']!r}")
        except Exception as error:
            log(f"waiting for new Plex item ({error})")
        if item is not None:
            break
        if time.time() - last_log >= 60:
            log(f"still waiting for Plex to index new item (up to {timeout}s): {plex_path}")
            last_log = time.time()
        time.sleep(10)
    if item is None:
        log(f"timed out waiting for Plex to index new path: {plex_path}")
        return 0
    new_key = item.attrib.get("ratingKey", "")
    metadata_type = METADATA_TYPE_IDS.get(item.attrib.get("type", "movie"), 1)
    log(f"matched new Plex item {new_key} at {plex_path}")
    if state.get("user_rating"):
        try:
            update_item(plex_url, section_id, metadata_type, new_key, {"userRating": state["user_rating"]})
            log(f"restored user rating {state['user_rating']}")
        except Exception as error:
            log(f"could not restore user rating for {new_key}: {error}")
    if int(state.get("view_count", "0") or 0) > 0:
        try:
            mark_watched(plex_url, new_key)
            log("restored watched state (Plex API marks watched; exact view count/date/resume position are not writable here)")
        except Exception as error:
            log(f"could not restore watched state for {new_key}: {error}")
    if state.get("added_at"):
        try:
            update_item(plex_url, section_id, metadata_type, new_key, {"addedAt": state["added_at"]})
            log(f"restored date added {state['added_at']}")
        except Exception as error:
            log(f"could not restore date added for {new_key}: {error}")
    if state.get("view_offset") not in ("", "0"):
        log("resume position was present but was not restored because Plex has no supported metadata migration endpoint for it")
    os.remove(state_path)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] not in ("snapshot", "apply"):
        print("usage: migrate_plex_metadata.py snapshot|apply old-or-new-path state-file", file=sys.stderr)
        sys.exit(2)
    if sys.argv[1] == "snapshot":
        sys.exit(snapshot(sys.argv[2], sys.argv[3]))
    sys.exit(apply(sys.argv[3], sys.argv[2]))