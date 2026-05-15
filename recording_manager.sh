#!/usr/bin/env bash
# VisionAI Recording Manager
# Polls the API every POLL_INTERVAL seconds for pending recordings and manages
# per-recording ffmpeg capture and S3 upload.
#
# Designed to run as a macOS LaunchDaemon. Configure via ENV_FILE.
#
# Required env vars (via ENV_FILE or shell environment):
#   VISIONAI_API_ENDPOINT  VISIONAI_API_TOKEN
#   AWS_ACCESS_KEY_ID  AWS_SECRET_ACCESS_KEY  AWS_REGION  AWS_BUCKET_NAME
# Optional:
#   SERVER_ID          - filter recordings to this server only
#   POLL_INTERVAL      - seconds between polls (default: 300)
#   SEGMENT_DURATION   - seconds per recording segment (default: 600)
#   UPLOAD_RETRIES     - max upload attempts per segment (default: 3)
#   UPLOAD_RETRY_DELAY - seconds between upload retries (default: 10)
#   DEBUG              - set to 1 for verbose logging
#   ENV_FILE           - path to .env file (default: ~/.visionai/.env)
#   LOG_FILE           - path to log file (default: /var/log/visionai/recording-manager.log)

set -uo pipefail

SEGMENT_DURATION=${SEGMENT_DURATION:-600}
POLL_INTERVAL=${POLL_INTERVAL:-300}
UPLOAD_RETRIES=${UPLOAD_RETRIES:-3}
UPLOAD_RETRY_DELAY=${UPLOAD_RETRY_DELAY:-10}
ENV_FILE=${ENV_FILE:-${HOME}/.visionai/.env}
LOG_FILE=${LOG_FILE:-/var/log/visionai/recording-manager.log}
TMP_DIR=/tmp/visionai-rec
ACTIVE_DIR=$TMP_DIR/active
PID_FILE=/var/run/visionai-recording-manager.pid

mkdir -p "$(dirname "$LOG_FILE")" "$TMP_DIR" "$ACTIVE_DIR"
exec >> "$LOG_FILE" 2>&1

_ts()       { date '+%Y-%m-%d %H:%M:%S'; }
log()       { echo "[$(_ts)] [rec-mgr] $*" >&2; }
log_warn()  { echo "[$(_ts)] [rec-mgr] WARN: $*" >&2; }
log_error() { echo "[$(_ts)] [rec-mgr] ERROR: $*" >&2; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo "[$(_ts)] [rec-mgr] DEBUG: $*" >&2 || true; }

# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; log "Loaded $ENV_FILE"; } \
    || log_warn "Env file not found at $ENV_FILE — using existing environment"

_check_vars() {
    local missing=()
    for v in VISIONAI_API_ENDPOINT VISIONAI_API_TOKEN \
              AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_BUCKET_NAME; do
        [[ -z "${!v:-}" ]] && missing+=("$v")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required variables: ${missing[*]}"; exit 1
    fi
}
_check_vars

for _cmd in jq ffmpeg curl; do
    command -v "$_cmd" >/dev/null 2>&1 || { log_error "$_cmd not found — install it first"; exit 1; }
done

# ---- Pick a video encoder: VideoToolbox if available, else libx264 ----
# Bitrate-targeted (500k / 800k cap) for predictable file sizes —
# ~37MB per 10-min segment vs ~150MB with stream-copy. Down-scale
# anything wider than 720p so we don't waste bits on detail the
# uplink can't carry.
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q '^[[:space:]]*V[^ ]*[[:space:]]\+h264_videotoolbox'; then
    VIDEO_ENCODER_ARGS=(-c:v h264_videotoolbox -b:v 500k -maxrate 800k -bufsize 1200k)
    log "Video encoder: h264_videotoolbox (hardware, ~500 kbps target)"
else
    VIDEO_ENCODER_ARGS=(-c:v libx264 -preset veryfast -b:v 500k -maxrate 800k -bufsize 1200k)
    log_warn "h264_videotoolbox not available — using libx264 software encoder"
fi

# ---- Locate a Python 3 with boto3 -------------------------------------
_find_python() {
    # Prefer PYTHON_BIN if set in env
    if [[ -n "${PYTHON_BIN:-}" && -x "$PYTHON_BIN" ]]; then
        "$PYTHON_BIN" -c "import boto3" 2>/dev/null && { echo "$PYTHON_BIN"; return; }
    fi
    # Search common venv locations
    for _py in \
        /Users/visionify/vision-pallet-management-inference/.venv/bin/python3 \
        /Users/visionify/visionai/vision-pallet-management-inference/.venv/bin/python3 \
        /Users/visionify/.venv/bin/python3 \
        /opt/visionai/.venv/bin/python3 \
        python3 python; do
        [[ -x "$_py" ]] || command -v "$_py" >/dev/null 2>&1 || continue
        "$_py" -c "import boto3" 2>/dev/null && { echo "$_py"; return; }
    done
    echo ""
}
PYTHON_BIN=$(_find_python)
if [[ -z "$PYTHON_BIN" ]]; then
    log_error "No Python 3 with boto3 found — set PYTHON_BIN in $ENV_FILE"; exit 1
fi
log "Using Python: $PYTHON_BIN (boto3 available)"

# ---- Singleton ---------------------------------------------------------
if [[ -f "$PID_FILE" ]]; then
    _old=$(cat "$PID_FILE" 2>/dev/null || true)
    if [[ -n "${_old:-}" ]] && kill -0 "$_old" 2>/dev/null; then
        log_error "Already running (PID $_old). Exiting."; exit 1
    fi
fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"; log "Stopped (PID $$)"' EXIT INT TERM

rm -f "${ACTIVE_DIR}"/* 2>/dev/null || true
log "Started (PID=$$, poll=${POLL_INTERVAL}s, segment=${SEGMENT_DURATION}s)"

# ---- API helpers -------------------------------------------------------
_api_get() {
    curl -sf --max-time "${2:-10}" \
        -H "Content-Type: application/json" \
        -H "x-api-token: $VISIONAI_API_TOKEN" \
        "$1"
}

_api_patch() {
    curl -sf --max-time 10 -X PATCH \
        -H "Content-Type: application/json" \
        -H "x-api-token: $VISIONAI_API_TOKEN" \
        -d "$2" "$1"
}

# ---- Upload file to S3 via boto3, return presigned GET URL or empty ---
# Mirrors the inference repo's upload_media() pattern
# (utils/s3_bucket.py): 1MB multipart chunks, single-threaded,
# fail-fast internally (max_attempts=1) and rely on this outer
# retry loop. Small chunks minimise bytes lost when the uplink
# drops mid-part — the previous 8MB chunks failed repeatedly on
# this site's flaky connection.
_s3_upload() {
    local file="$1" key="$2"
    local attempt=1
    local stderr_file; stderr_file=$(mktemp)

    while [[ $attempt -le $UPLOAD_RETRIES ]]; do
        local result rc
        result=$("$PYTHON_BIN" - "$file" "$AWS_BUCKET_NAME" "$key" \
                "$AWS_REGION" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" \
                2>"$stderr_file" <<'PYEOF'
import sys, os, warnings, mimetypes, fcntl
warnings.filterwarnings("ignore")
import boto3
from botocore.config import Config
from boto3.s3.transfer import TransferConfig
from botocore.exceptions import BotoCoreError, ClientError

file, bucket, key, region, ak, sk = sys.argv[1:]
try:
    # Serialize uploads across all concurrent recordings — one
    # segment uploads at a time, so multiple cameras hitting a
    # segment boundary together don't fight for the uplink. The
    # lock is released automatically when this process exits.
    lock_fp = open("/tmp/visionai-rec/s3-upload.lock", "a+")
    fcntl.flock(lock_fp.fileno(), fcntl.LOCK_EX)

    cfg = Config(
        signature_version="s3v4",
        region_name=region,
        retries={"max_attempts": 1, "mode": "standard"},
        connect_timeout=60,
        read_timeout=600,
        tcp_keepalive=True,
        user_agent_extra="visionai-recording-manager",
    )
    s3 = boto3.client("s3",
                      aws_access_key_id=ak, aws_secret_access_key=sk,
                      region_name=region, config=cfg)
    # 1MB chunks + single-threaded — same as the inference uploader.
    # On flaky links, smaller chunks mean each network blip costs
    # at most 1MB instead of 8MB.
    tcfg = TransferConfig(
        multipart_threshold=1 * 1024 * 1024,
        multipart_chunksize=1 * 1024 * 1024,
        max_concurrency=1,
        use_threads=False,
    )
    content_type = mimetypes.guess_type(file)[0] or "application/octet-stream"
    with open(file, "rb") as f:
        s3.upload_fileobj(
            f, bucket, key,
            ExtraArgs={"ContentType": content_type, "ACL": "private"},
            Config=tcfg,
        )
    url = s3.generate_presigned_url("get_object",
              Params={"Bucket": bucket, "Key": key}, ExpiresIn=604800)
    print(url)
except (BotoCoreError, ClientError, Exception) as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
        )
        rc=$?
        if [[ $rc -eq 0 ]]; then
            rm -f "$stderr_file"
            echo "$result"
            return
        fi

        local err; err=$(tr '\n' ' ' < "$stderr_file")
        log_warn "S3 upload failed for $key (attempt $attempt/$UPLOAD_RETRIES): ${err}" >&2
        attempt=$(( attempt + 1 ))
        [[ $attempt -le $UPLOAD_RETRIES ]] && sleep "$UPLOAD_RETRY_DELAY"
    done

    rm -f "$stderr_file"
    log_error "S3 upload permanently failed for $key after $UPLOAD_RETRIES attempts" >&2
    echo ""
}

_file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# ---- Camera recording-enabled check -----------------------------------
_camera_recording_enabled() {
    local resp
    resp=$(_api_get \
        "${VISIONAI_API_ENDPOINT}/recordings/inference?action=camera-status&cameraId=$1" \
        5 2>/dev/null) || return 0   # default: enabled if API unreachable
    local enabled
    enabled=$(echo "$resp" | jq -r 'if .success then (.data.recordingEnabled // true) else true end' \
        2>/dev/null)
    [[ "$enabled" != "false" ]]
}

# ---- Claim recording: 0=claimed, 1=already taken/error ----------------
_api_start() {
    local tmp code ok
    tmp=$(mktemp)
    code=$(curl -s -o "$tmp" -w "%{http_code}" --max-time 10 -X PATCH \
        -H "Content-Type: application/json" \
        -H "x-api-token: $VISIONAI_API_TOKEN" \
        -d "$(jq -n --arg id "$1" '{recordingId:$id,action:"start"}')" \
        "${VISIONAI_API_ENDPOINT}/recordings/inference")
    ok=$(jq -r '.success' "$tmp" 2>/dev/null); rm -f "$tmp"
    [[ "$code" != "409" && "$ok" == "true" ]]
}

_api_complete() {
    local resp
    resp=$(_api_patch "${VISIONAI_API_ENDPOINT}/recordings/inference" \
        "$(jq -n \
            --arg rid "$1" \
            --arg s3u "$2" \
            --argjson sl "$(cat "$3")" \
            '{recordingId:$rid,action:"complete",s3_url:$s3u,s3_urls:$sl}')" \
        2>/dev/null) || true
    log "Recording $1 complete: $resp"
}

_api_fail() {
    _api_patch "${VISIONAI_API_ENDPOINT}/recordings/inference" \
        "$(jq -n \
            --arg rid "$1" \
            --arg err "${2:0:500}" \
            '{recordingId:$rid,action:"fail",error_message:$err}')" \
        >/dev/null 2>&1 || true
    log "Recording $1 failed: ${2:0:120}"
}

_push_segments() {
    local resp
    resp=$(_api_patch "${VISIONAI_API_ENDPOINT}/recordings/inference" \
        "$(jq -n \
            --arg rid "$1" \
            --arg s3u "$2" \
            --argjson sl "$(cat "$3")" \
            '{recordingId:$rid,action:"update-segments",s3_url:$s3u,s3_urls:$sl}')" \
        2>/dev/null) || true
    [[ "$(echo "$resp" | jq -r '.success' 2>/dev/null)" != "true" ]] \
        && log_warn "Segment push non-success for $1: $resp" || true
}

# ---- ffmpeg segment capture — always runs to full duration ------------
# Deadline watchdog kills a hung ffmpeg that doesn't exit on its own.
_ffmpeg_record() {
    local rtsp="$1" out="$2" dur="$3"
    local deadline=$(( $(date +%s) + dur + 60 ))

    ffmpeg -rtsp_transport tcp -i "$rtsp" -t "$dur" \
        -vf "scale='min(1280,iw)':-2" \
        "${VIDEO_ENCODER_ARGS[@]}" \
        -an -movflags +faststart -y "$out" \
        >/dev/null 2>&1 &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        if [[ $(date +%s) -gt $deadline ]]; then
            kill "$pid" 2>/dev/null || true
            log_warn "ffmpeg deadline exceeded for $out, killed"
            break
        fi
    done
    wait "$pid" 2>/dev/null || true
}

# ---- Upload first frame as thumbnail, echo presigned URL or empty -----
_upload_thumb() {
    local seg="$1" s3_key="$2"
    # Derive tmp path from seg filename (already unique per recording+segment).
    # macOS mktemp only substitutes trailing X's, so the previous
    # `mktemp /tmp/visionai_th_XXXXXX.jpg` template raced and collided
    # under concurrent recordings — see "mkstemp failed: File exists" logs.
    local tmp="${TMP_DIR}/$(basename "$seg" .mp4)_thumb.jpg"
    ffmpeg -i "$seg" -frames:v 1 -f image2 -y "$tmp" >/dev/null 2>&1 || true
    if [[ -s "$tmp" ]]; then
        _s3_upload "$tmp" "$s3_key"
        rm -f "$tmp"
    else
        rm -f "$tmp"; echo ""
    fi
}

# ---- Full recording lifecycle (invoked as a background subprocess) ----
_run_recording() {
    trap - EXIT INT TERM  # don't inherit the parent's PID-file cleanup trap

    local rec_id="$1" cam_id="$2" cam_name="$3" dur_min="$4" rtsp="$5"
    # Sanitise camera name for use as an S3 path component
    local cam_safe; cam_safe=$(echo "$cam_name" | tr '[:upper:]' '[:lower:]' | tr ' /' '--' | tr -cd 'a-z0-9_-')
    local rec_ts; rec_ts=$(date '+%Y%m%d-%H%M%S')
    local base="recordings/${cam_safe}"
    local total=$(( dur_min * 60 )) elapsed=0 idx=0
    local segs; segs=$(mktemp "${TMP_DIR}/segs_${rec_id}_XXXXXX.json")
    local last_url=""
    echo "[]" > "$segs"

    log "Recording $rec_id: starting (cam=$cam_name, ${dur_min}min, path=$base)"

    if ! _api_start "$rec_id"; then
        log "Recording $rec_id: already claimed by another server — skip"
        rm -f "${ACTIVE_DIR}/${rec_id}" "$segs"
        return
    fi

    while [[ $elapsed -lt $total ]]; do
        local seg_dur=$(( SEGMENT_DURATION < (total - elapsed) ? SEGMENT_DURATION : (total - elapsed) ))
        local idx_fmt; idx_fmt=$(printf "%03d" "$idx")
        local seg_file="${TMP_DIR}/rec_${rec_id}_${idx_fmt}.mp4"

        _ffmpeg_record "$rtsp" "$seg_file" "$seg_dur"

        if [[ -s "$seg_file" ]]; then
            local sz; sz=$(_file_size "$seg_file")
            local fname="${cam_safe}-${rec_ts}-${idx_fmt}"
            local thumb; thumb=$(_upload_thumb "$seg_file" "${base}/${fname}_thumb.jpg") || thumb=""
            local url;   url=$(_s3_upload "$seg_file" "${base}/${fname}.mp4") || url=""
            if [[ -n "$url" ]]; then
                rm -f "$seg_file"
            else
                log_warn "Recording $rec_id: segment $idx_fmt upload failed — removing local file to free disk"
                rm -f "$seg_file"
            fi

            local entry
            if [[ -n "$thumb" ]]; then
                entry=$(jq -n \
                    --arg  u "${url:-}" --argjson s "$sz" \
                    --argjson d "$seg_dur" --arg t "$thumb" \
                    '{url:$u,size_bytes:$s,duration_seconds:$d,thumbnail_url:$t}')
            else
                entry=$(jq -n \
                    --arg  u "${url:-}" --argjson s "$sz" --argjson d "$seg_dur" \
                    '{url:$u,size_bytes:$s,duration_seconds:$d}')
            fi

            [[ -n "$url" ]] && last_url="$url"
            jq --argjson e "$entry" '. + [$e]' "$segs" > "${segs}.tmp" \
                && mv "${segs}.tmp" "$segs"
            _push_segments "$rec_id" "${last_url:-}" "$segs"
            if [[ -n "$url" ]]; then
                log "Recording $rec_id: segment $idx_fmt uploaded (${sz}B)"
            else
                log_warn "Recording $rec_id: segment $idx_fmt UPLOAD FAILED — recorded locally was ${sz}B but no S3 URL"
            fi
        else
            log_warn "Recording $rec_id: segment $idx_fmt missing or empty"
            rm -f "$seg_file"
        fi

        elapsed=$(( elapsed + seg_dur ))
        idx=$(( idx + 1 ))
    done

    _api_complete "$rec_id" "${last_url:-}" "$segs"
    rm -f "${ACTIVE_DIR}/${rec_id}" "$segs" "${segs}.tmp" 2>/dev/null || true
    log "Recording $rec_id: done"
}

# ---- Dispatch a JSON array of recording objects -----------------------
_dispatch() {
    local json="$1"
    local n; n=$(echo "$json" | jq 'length')
    local dispatched=0

    for i in $(seq 0 $(( n - 1 ))); do
        local rec; rec=$(echo "$json" | jq ".[$i]")
        local rec_id cam_id cam_name srv_id rtsp dur
        rec_id=$(echo "$rec" | jq -r '.id')
        cam_id=$(echo "$rec" | jq -r '.cameras.id          // empty')
        cam_name=$(echo "$rec" | jq -r '.cameras.name      // .cameras.id // empty')
        srv_id=$(echo "$rec" | jq -r '.cameras.server_id   // empty')
        rtsp=$(echo "$rec"   | jq -r '.cameras.rtsp        // empty')
        dur=$(echo "$rec"    | jq -r '.duration_minutes    // 10')

        if [[ -n "${SERVER_ID:-}" && "$srv_id" != "$SERVER_ID" ]]; then
            log_debug "Recording $rec_id: skip (server_id $srv_id != $SERVER_ID)"; continue
        fi

        if [[ -f "${ACTIVE_DIR}/${rec_id}" ]]; then
            log_debug "Recording $rec_id: already active, skip"; continue
        fi

        if ! _camera_recording_enabled "$cam_id"; then
            log "Recording $rec_id: camera $cam_id has recording disabled — skipping"
            continue
        fi

        if [[ -z "$rtsp" ]]; then
            log_warn "Recording $rec_id: no RTSP URL — marking failed"
            _api_fail "$rec_id" "Camera has no RTSP URL"; continue
        fi

        touch "${ACTIVE_DIR}/${rec_id}"
        log "Recording $rec_id: dispatching (cam=$cam_name, ${dur}min)"
        _run_recording "$rec_id" "$cam_id" "$cam_name" "$dur" "$rtsp" &
        dispatched=$(( dispatched + 1 ))
    done

    # Back off briefly when all recordings were filtered (avoid hammering the API)
    [[ $dispatched -eq 0 && $n -gt 0 ]] && sleep 5 || true
}

# ---- Poll the API for pending recordings and dispatch them ------------
_poll() {
    log "Polling for pending recordings..."
    local resp
    resp=$(_api_get "${VISIONAI_API_ENDPOINT}/recordings/inference?action=pending" 10 \
        2>/dev/null) || { log_error "API unreachable — retry in ${POLL_INTERVAL}s"; return; }

    local ok; ok=$(echo "$resp" | jq -r '.success' 2>/dev/null)
    [[ "$ok" != "true" ]] && { log_error "API error: $resp"; return; }

    local recs; recs=$(echo "$resp" | jq '.data // []')
    local n; n=$(echo "$recs" | jq 'length')
    [[ "$n" -eq 0 ]] && { log "No pending recordings"; return; }
    log "Found $n pending recording(s)"
    _dispatch "$recs"
}

# ---- Main loop ---------------------------------------------------------
_poll   # immediate check on startup

while true; do
    sleep "$POLL_INTERVAL"
    _poll
done
