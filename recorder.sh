#!/usr/bin/env bash
##############################################################################
#  recorder.sh
#
#  Invoked by nginx-rtmp exec_record_done when a live stream ends.
#
#  Arguments (set by nginx-rtmp):
#    $1 = full path to .flv file   e.g. /recordings/rm_abc123-20260226-140000.flv
#    $2 = stream name / roomId     e.g. rm_abc123
#
#  Pipeline:
#    1.  Validate FLV exists and is large enough to be meaningful
#    2.  ffmpeg: FLV → MP4 (stream-copy video, AAC audio, faststart moov atom)
#    3.  aws s3 cp: upload MP4 to Cloudflare R2 via S3-compatible API
#    4.  Calculate duration via ffprobe
#    5.  Lookup lectureId in Appwrite stream_keys collection (by roomId)
#    6.  POST /api/internal/recording-ready to Next.js app
#        → Appwrite lecture.videoUrl updated, lecture marked as recorded
#    7.  Cleanup temp files
##############################################################################
set -euo pipefail

# Redirect all stdout/stderr to a log file since nginx-rtmp executes this detached
exec >> /var/log/nginx/recorder.log 2>&1

FLV_PATH="$1"
ROOM_ID="$2"

# ── Load env (Docker injects vars; .env fallback for local dev) ───────────────
if [[ -f /etc/nginx/.env ]]; then
  # shellcheck disable=SC1091
  source /etc/nginx/.env
fi

# Fail fast if any required variable is missing
: "${R2_ACCOUNT_ID:?Need R2_ACCOUNT_ID}"
: "${R2_ACCESS_KEY_ID:?Need R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?Need R2_SECRET_ACCESS_KEY}"
: "${R2_BUCKET:?Need R2_BUCKET}"
: "${R2_PUBLIC_URL:?Need R2_PUBLIC_URL}"
: "${VIDYARO_APP_URL:?Need VIDYARO_APP_URL}"
: "${INTERNAL_SECRET:?Need INTERNAL_SECRET}"
: "${APPWRITE_ENDPOINT:?Need APPWRITE_ENDPOINT}"
: "${APPWRITE_PROJECT_ID:?Need APPWRITE_PROJECT_ID}"
: "${APPWRITE_API_KEY:?Need APPWRITE_API_KEY}"
: "${APPWRITE_DATABASE_ID:?Need APPWRITE_DATABASE_ID}"
: "${APPWRITE_STREAM_KEYS_COLLECTION_ID:?Need APPWRITE_STREAM_KEYS_COLLECTION_ID}"

LOG_PREFIX="[recorder] [${ROOM_ID}]"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${LOG_PREFIX} $*"; }

# ─────────────────────────────────────────────────────────────────────────────
#  Step 0: Wait for FLV flush + sanity check
# ─────────────────────────────────────────────────────────────────────────────
log "Stream ended. Waiting 3 s for FLV flush..."
sleep 3

if [[ ! -f "${FLV_PATH}" ]]; then
  log "ERROR: FLV file not found at ${FLV_PATH}"
  exit 1
fi

FLV_SIZE=$(stat -c%s "${FLV_PATH}" 2>/dev/null || echo 0)
log "FLV size: ${FLV_SIZE} bytes"

if [[ "${FLV_SIZE}" -lt 1024 ]]; then
  log "WARN: FLV too small (<1 KB) — test stream or crash. Skipping."
  rm -f "${FLV_PATH}"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Paths
# ─────────────────────────────────────────────────────────────────────────────
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S)
BASENAME="${ROOM_ID}_${TIMESTAMP}"
WORK_DIR="/tmp/recordings/${ROOM_ID}"
MP4_PATH="${WORK_DIR}/${BASENAME}.mp4"
R2_KEY="recordings/${ROOM_ID}/${BASENAME}.mp4"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

mkdir -p "${WORK_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 1: FLV → MP4
# ─────────────────────────────────────────────────────────────────────────────
log "Converting FLV → MP4..."
FFMPEG_LOG="${WORK_DIR}/ffmpeg.log"

if ! ffmpeg -y \
    -i  "${FLV_PATH}" \
    -c:v copy     \
    -c:a aac      \
    -movflags +faststart \
    "${MP4_PATH}" \
    2>"${FFMPEG_LOG}"; then
  log "ERROR: ffmpeg failed — see log below"
  cat "${FFMPEG_LOG}" || true
  exit 1
fi

MP4_SIZE=$(stat -c%s "${MP4_PATH}" 2>/dev/null || echo 0)
log "MP4 ready: ${MP4_PATH} (${MP4_SIZE} bytes)"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 2: Upload to Cloudflare R2
# ─────────────────────────────────────────────────────────────────────────────
log "Uploading to R2: s3://${R2_BUCKET}/${R2_KEY}"

export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION="auto"

if ! aws s3 cp \
    "${MP4_PATH}" \
    "s3://${R2_BUCKET}/${R2_KEY}" \
    --endpoint-url "${R2_ENDPOINT}" \
    --content-type  "video/mp4" \
    --no-progress; then
  log "ERROR: R2 upload failed"
  exit 1
fi

PUBLIC_URL="${R2_PUBLIC_URL}/${R2_KEY}"
log "Upload complete → ${PUBLIC_URL}"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 3: Duration
# ─────────────────────────────────────────────────────────────────────────────
DURATION_SECS=$(ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "${MP4_PATH}" 2>/dev/null | awk -F. '{print $1}')
DURATION_SECS="${DURATION_SECS:-0}"
HOURS=$(( DURATION_SECS / 3600 ))
MINUTES=$(( (DURATION_SECS % 3600) / 60 ))
if [[ "${HOURS}" -gt 0 ]]; then
  DURATION_STR="${HOURS}h ${MINUTES}m"
else
  DURATION_STR="${MINUTES}m"
fi
log "Duration: ${DURATION_STR} (${DURATION_SECS}s)"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 4: Resolve lectureId via Appwrite (stream_keys collection)
# ─────────────────────────────────────────────────────────────────────────────
log "Looking up lectureId for roomId=${ROOM_ID} ..."

APPWRITE_QUERY="equal(\"roomId\", [\"${ROOM_ID}\"])"
ENCODED_QUERY=$(python3 -c \
  "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" \
  "${APPWRITE_QUERY}")

LECTURE_ID=""
STREAM_KEY_RESPONSE=$(curl -sf \
  --max-time 10 \
  -H "Content-Type: application/json" \
  -H "X-Appwrite-Project: ${APPWRITE_PROJECT_ID}" \
  -H "X-Appwrite-Key: ${APPWRITE_API_KEY}" \
  "${APPWRITE_ENDPOINT}/databases/${APPWRITE_DATABASE_ID}/collections/${APPWRITE_STREAM_KEYS_COLLECTION_ID}/documents?queries%5B%5D=${ENCODED_QUERY}" \
  || echo "")

if [[ -n "${STREAM_KEY_RESPONSE}" ]]; then
  LECTURE_ID=$(echo "${STREAM_KEY_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
docs = data.get('documents', [])
if docs:
    print(docs[0].get('lectureId', ''))
" 2>/dev/null || echo "")
fi

if [[ -z "${LECTURE_ID}" ]]; then
  log "WARN: lectureId not found in Appwrite — falling back to roomId"
  LECTURE_ID="${ROOM_ID}"
fi
log "lectureId = ${LECTURE_ID}"

# ─────────────────────────────────────────────────────────────────────────────
#  Step 5: Notify Next.js app
# ─────────────────────────────────────────────────────────────────────────────
WEBHOOK_URL="${VIDYARO_APP_URL}/api/internal/recording-ready"
log "Calling webhook → ${WEBHOOK_URL}"

HTTP_STATUS=$(curl -sf \
  --max-time 20 \
  -w "%{http_code}" \
  -o /tmp/rr_response.json \
  -X POST \
  -H "Content-Type: application/json" \
  -H "x-internal-secret: ${INTERNAL_SECRET}" \
  "${WEBHOOK_URL}" \
  -d "{
    \"lectureId\":    \"${LECTURE_ID}\",
    \"recordingUrl\": \"${PUBLIC_URL}\",
    \"duration\":     \"${DURATION_STR}\"
  }" || echo "000")

if [[ "${HTTP_STATUS}" == "200" ]]; then
  log "✓ Webhook accepted (HTTP 200)"
  cat /tmp/rr_response.json 2>/dev/null || true
else
  log "WARN: Webhook returned HTTP ${HTTP_STATUS}. Retrying in 15 s..."
  sleep 15
  RETRY_STATUS=$(curl -s \
    --max-time 20 \
    -w "%{http_code}" \
    -o /dev/null \
    -X POST \
    -H "Content-Type: application/json" \
    -H "x-internal-secret: ${INTERNAL_SECRET}" \
    "${WEBHOOK_URL}" \
    -d "{\"lectureId\":\"${LECTURE_ID}\",\"recordingUrl\":\"${PUBLIC_URL}\",\"duration\":\"${DURATION_STR}\"}" \
    || echo "000")
  if [[ "${RETRY_STATUS}" == "200" ]]; then
    log "✓ Retry webhook accepted (HTTP 200)"
  else
    log "ERROR: Retry also failed (HTTP ${RETRY_STATUS}). Recording URL: ${PUBLIC_URL}"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Step 6: Delete local FLV + temp files (R2 is the source of truth now)
# ─────────────────────────────────────────────────────────────────────────────
log "Cleaning up..."
rm -f "${MP4_PATH}" "${FFMPEG_LOG}" /tmp/rr_response.json
rm -f "${FLV_PATH}"
rmdir "${WORK_DIR}" 2>/dev/null || true

log "✓ Done. Recording available at: ${PUBLIC_URL}"
