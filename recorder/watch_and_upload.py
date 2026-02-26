#!/usr/bin/env python3
"""
watch_and_upload.py — Vidyaro Recorder Service
===============================================

Watches /recordings for sentinel files written by nginx-rtmp's
exec_record_done directive:

    exec_record_done sh -c 'touch "/recordings/$name.done" || true';

When a <lectureId>.done file is found:
  1. Finds the matching <lectureId>_<timestamp>.flv file
  2. Converts FLV → MP4 using ffmpeg (fast re-mux, web-optimised)
  3. Uploads MP4 to Cloudflare R2 via S3-compatible API (aws s3 cp)
  4. Calls Appwrite PATCH to set lecture.videoUrl = recording URL
  5. Calls Vidyaro app webhook as backup
  6. Deletes FLV AFTER Appwrite is updated (so we have a fallback)
  7. Deletes .done sentinel

Nginx-rtmp strips query params from $name, so:
  OBS stream key:  lectureId?pwd=XXXXXXXX
  nginx $name:     lectureId   ← this is what .done and .flv are named

Environment variables (injected by docker run --env-file):
  R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY
  R2_BUCKET_NAME, R2_PUBLIC_URL
  APPWRITE_ENDPOINT, APPWRITE_PROJECT_ID, APPWRITE_API_KEY
  APPWRITE_DATABASE_ID, APPWRITE_LECTURES_COL_ID
  VIDYARO_APP_URL, INTERNAL_SECRET
"""

import os
import sys
import time
import glob
import json
import subprocess
import urllib.request
import urllib.parse
from datetime import datetime
from pathlib import Path

# ── Config ─────────────────────────────────────────────────────────────────
RECORDINGS_DIR = Path("/recordings")
POLL_INTERVAL  = 5   # seconds between directory scans

R2_ACCOUNT_ID        = os.environ["R2_ACCOUNT_ID"]
R2_ACCESS_KEY_ID     = os.environ["R2_ACCESS_KEY_ID"]
R2_SECRET_ACCESS_KEY = os.environ["R2_SECRET_ACCESS_KEY"]
R2_BUCKET_NAME       = os.environ["R2_BUCKET_NAME"]
R2_PUBLIC_URL        = os.environ["R2_PUBLIC_URL"].rstrip("/")
R2_ENDPOINT          = f"https://{R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

APPWRITE_ENDPOINT    = os.environ["APPWRITE_ENDPOINT"].rstrip("/")
APPWRITE_PROJECT_ID  = os.environ["APPWRITE_PROJECT_ID"]
APPWRITE_API_KEY     = os.environ["APPWRITE_API_KEY"]
APPWRITE_DATABASE_ID = os.environ["APPWRITE_DATABASE_ID"]
APPWRITE_LECTURES    = os.environ.get("APPWRITE_LECTURES_COL_ID", "lectures")

VIDYARO_APP_URL  = os.environ.get("VIDYARO_APP_URL", "").rstrip("/")
INTERNAL_SECRET  = os.environ.get("INTERNAL_SECRET", "")

# ── Helpers ─────────────────────────────────────────────────────────────────

def log(msg: str):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S IST")
    print(f"[recorder {ts}] {msg}", flush=True)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kwargs)



def appwrite_get_stream(room_id: str) -> str | None:
    """GET lectureId from stream_keys collection by matching roomId."""
    # Nginx stream name is now roomId, so we look it up by roomId to find the lecture
    query = urllib.parse.quote(json.dumps({"method": "equal", "attribute": "roomId", "values": [room_id]}))
    url = f"{APPWRITE_ENDPOINT}/databases/{APPWRITE_DATABASE_ID}/collections/stream_keys/documents?queries[0]={query}"
    req = urllib.request.Request(
        url, method="GET",
        headers={
            "X-Appwrite-Project": APPWRITE_PROJECT_ID,
            "X-Appwrite-Key":     APPWRITE_API_KEY,
            "User-Agent":         "Vidyaro-Recorder/1.0",
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
            docs = data.get("documents", [])
            if docs:
                return docs[0].get("lectureId")
    except Exception as e:
        log(f"  Appwrite GET stream_keys error: {e}")
    return None

def appwrite_patch(collection: str, doc_id: str, data: dict) -> int:

    """PATCH a document in Appwrite. Returns HTTP status code."""
    url = f"{APPWRITE_ENDPOINT}/databases/{APPWRITE_DATABASE_ID}/collections/{collection}/documents/{doc_id}"
    payload = json.dumps({"data": data}).encode()
    req = urllib.request.Request(
        url, data=payload, method="PATCH",
        headers={
            "Content-Type":       "application/json",
            "X-Appwrite-Project": APPWRITE_PROJECT_ID,
            "X-Appwrite-Key":     APPWRITE_API_KEY,
            "User-Agent":         "Vidyaro-Recorder/1.0",
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        log(f"  Appwrite HTTP {e.code}: {e.read().decode()[:200]}")
        return e.code
    except Exception as e:
        log(f"  Appwrite error: {e}")
        return 0


def call_webhook(lecture_id: str, recording_url: str) -> bool:
    """Call the Next.js internal webhook as a backup."""
    if not VIDYARO_APP_URL or not INTERNAL_SECRET:
        return True  # skipped — not configured

    url  = f"{VIDYARO_APP_URL}/api/internal/recording-ready"
    body = json.dumps({"lectureId": lecture_id, "recordingUrl": recording_url}).encode()
    req  = urllib.request.Request(
        url, data=body, method="POST",
        headers={
            "Content-Type":      "application/json",
            "x-internal-secret": INTERNAL_SECRET,
            "User-Agent":        "Vidyaro-Recorder/1.0",
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status == 200
    except Exception as e:
        log(f"  Webhook error: {e}")
        return False


# ── Core pipeline ────────────────────────────────────────────────────────────

def find_flv_for_stream(lecture_id: str) -> Path | None:
    """
    lecture_id: the nginx $name variable — stream name WITHOUT query params.
    nginx records as: /recordings/{lecture_id}_{timestamp}.flv
    We return the most-recent FLV for this lectureId.
    """
    pattern = str(RECORDINGS_DIR / f"{lecture_id}_*.flv")
    matches = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    if matches:
        return Path(matches[0])
    return None


def process_sentinel(done_file: Path):
    """Full pipeline for one completed stream recording."""
    room_id = done_file.stem  # the stream name in nginx is now the roomId

    log(f"── New recording sentinel: {done_file.name}")
    log(f"   Room ID = {room_id}")

    # Look up lecture ID from Appwrite
    lecture_id = appwrite_get_stream(room_id)
    if not lecture_id:
        # Fallback in case old streams didn't have lectureId field
        lecture_id = room_id
        log(f"   WARNING: Could not find lectureId for room {room_id}. Using roomId as lectureId")
    else:
        log(f"   Lecture ID = {lecture_id}")

    # ── Find the FLV ──────────────────────────────────────────────────
    flv = find_flv_for_stream(room_id)
    if not flv:
        log(f"  ERROR: No FLV found for room_id '{room_id}' — skipping")
        done_file.unlink(missing_ok=True)
        return

    log(f"   FLV file  = {flv.name}  ({flv.stat().st_size // 1024 // 1024} MB)")

    # Wait briefly — nginx may still be flushing the final bytes
    time.sleep(3)

    # ── Step 1: Convert FLV → MP4 ───────────────────────────────────────
    timestamp   = datetime.now().strftime("%Y%m%d_%H%M%S")
    mp4_name    = f"{lecture_id}_{timestamp}.mp4"
    # Write MP4 to /recordings (host bind-mount) NOT /tmp (tiny container overlay)
    # This handles 2GB+ lecture recordings safely.
    mp4_path    = RECORDINGS_DIR / mp4_name
    r2_key      = f"recordings/{lecture_id}/{mp4_name}"
    public_url  = f"{R2_PUBLIC_URL}/{r2_key}"

    # Sanity check: ensure enough disk space (need ~2x FLV size for MP4)
    flv_size = flv.stat().st_size
    disk     = os.statvfs(str(RECORDINGS_DIR))
    free_bytes = disk.f_bavail * disk.f_frsize
    if free_bytes < flv_size * 1.5:
        log(f"  ERROR: Not enough disk space. Need {flv_size*1.5/1e9:.1f}GB, have {free_bytes/1e9:.1f}GB")
        done_file.unlink(missing_ok=True)
        return

    log("  Step 1/3 — Converting FLV → MP4 (re-mux, no re-encode)...")
    try:
        run([
            "ffmpeg", "-y",
            "-i", str(flv),
            "-c:v", "copy",        # re-mux video stream without re-encoding
            "-c:a", "aac",         # ensure AAC audio
            "-b:a", "128k",
            "-movflags", "+faststart",  # moov atom first = progressive playback
            str(mp4_path),
        ])
        mb = mp4_path.stat().st_size // 1024 // 1024
        log(f"  ✓ Converted  ({mb} MB → {mp4_path.name})")
    except subprocess.CalledProcessError as e:
        log(f"  ERROR: ffmpeg failed:\n{e.stderr[-500:]}")
        done_file.unlink(missing_ok=True)
        return

    # ── Step 2: Upload to Cloudflare R2 ─────────────────────────────────
    log("  Step 2/3 — Uploading to Cloudflare R2 (multipart for large files)...")
    env = os.environ.copy()
    env["AWS_ACCESS_KEY_ID"]     = R2_ACCESS_KEY_ID
    env["AWS_SECRET_ACCESS_KEY"] = R2_SECRET_ACCESS_KEY

    try:
        run([
            "aws", "s3", "cp",
            str(mp4_path),
            f"s3://{R2_BUCKET_NAME}/{r2_key}",
            "--endpoint-url",        R2_ENDPOINT,
            "--content-type",        "video/mp4",
            "--no-progress",
            "--region",              "auto",
            # Multipart upload: 100MB chunks, activated for files > 100MB
            # Handles recordings up to 5TB. AWS CLI uploads parts in parallel.
            "--multipart-chunksize", "104857600",   # 100 MB in bytes
            "--multipart-threshold", "104857600",   # use multipart for > 100 MB
        ], env=env)
        log(f"  ✓ Uploaded   → {public_url}")
    except subprocess.CalledProcessError as e:
        log(f"  ERROR: R2 upload failed:\n{e.stderr[-500:]}")
        log(f"  FLV kept at {flv} so you can retry manually.")
        mp4_path.unlink(missing_ok=True)
        done_file.unlink(missing_ok=True)
        return
    finally:
        mp4_path.unlink(missing_ok=True)  # always delete MP4 (uploaded or failed)

    # ── Step 3: Update Appwrite FIRST (before deleting FLV) ─────────────
    # Important: update Appwrite while FLV still exists.
    # If both Appwrite AND webhook fail, FLV is kept as last resort.
    log("  Step 3/3 — Updating Appwrite lecture record...")
    appwrite_ok = False
    status = appwrite_patch(APPWRITE_LECTURES, lecture_id, {"videoUrl": public_url})
    if status in (200, 201):
        log(f"  ✓ Appwrite   → videoUrl set to recording")
        appwrite_ok = True
    else:
        log(f"  WARNING: Appwrite returned {status}")

    # Always also call webhook as belt-and-suspenders
    if VIDYARO_APP_URL and INTERNAL_SECRET:
        webhook_ok = call_webhook(lecture_id, public_url)
        if webhook_ok:
            log(f"  ✓ Webhook    → confirmed")
            appwrite_ok = True   # at least one update path worked
        else:
            log(f"  WARNING: Webhook also failed")

    if not appwrite_ok:
        log(f"  ERROR: Both Appwrite and webhook failed!")
        log(f"  ⚠ Manual fix needed: set lecture {lecture_id} videoUrl = {public_url}")
        log(f"  FLV kept at {flv} for reference")
        done_file.unlink(missing_ok=True)
        return   # don't delete FLV — admin may need to investigate

    # ── Delete FLV AFTER successful Appwrite update ───────────────────────
    # Only delete once we KNOW the URL is safely stored in Appwrite.
    try:
        flv.unlink()
        log(f"  ✓ FLV deleted  ({flv.name})")
    except Exception as e:
        log(f"  WARNING: Could not delete FLV: {e}")

    # ── Cleanup sentinel ──────────────────────────────────────────────────
    done_file.unlink(missing_ok=True)

    log(f"── Done ✓  Recording live at: {public_url}")


# ── Orphan cleanup (FLVs from failed uploads > 24h old) ─────────────────────
# Normally FLVs are deleted right after upload. This only catches files
# left behind by upload failures.

def cleanup_orphaned_flv():
    now = time.time()
    one_day = 24 * 3600
    for flv in RECORDINGS_DIR.glob("*.flv"):
        age = now - flv.stat().st_mtime
        if age > one_day:
            log(f"Cleanup: deleting orphaned FLV {flv.name} ({int(age/3600)}h old — upload likely failed)")
            flv.unlink(missing_ok=True)


# ── Main loop ────────────────────────────────────────────────────────────────

def main():
    log("Vidyaro Recorder Service started")
    log(f"  Watching: {RECORDINGS_DIR}")
    log(f"  R2 bucket: {R2_BUCKET_NAME}  endpoint: {R2_ENDPOINT}")
    log(f"  Appwrite: {APPWRITE_ENDPOINT}  db: {APPWRITE_DATABASE_ID}")
    log(f"  Webhook backup: {'enabled' if VIDYARO_APP_URL else 'disabled'}")

    RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
    cleanup_counter = 0

    while True:
        try:
            # Scan for .done sentinel files
            for done_file in sorted(RECORDINGS_DIR.glob("*.done")):
                try:
                    process_sentinel(done_file)
                except Exception as e:
                    log(f"UNHANDLED ERROR processing {done_file.name}: {e}")
                    done_file.unlink(missing_ok=True)

            # Run orphan FLV cleanup once per hour
            cleanup_counter += 1
            if cleanup_counter >= (3600 // POLL_INTERVAL):
                cleanup_orphaned_flv()
                cleanup_counter = 0

        except Exception as e:
            log(f"ERROR in main loop: {e}")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
