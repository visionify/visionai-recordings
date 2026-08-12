#!/usr/bin/env bash
# VisionAI Recording Manager
# Polls the API every POLL_INTERVAL seconds for pending recordings and manages
# per-recording ffmpeg capture and S3 upload.
#
# Designed to run as a macOS LaunchDaemon. Configure via ENV_FILE.
#
# Required env vars (via ENV_FILE or shell environment):
#   VISIONAI_API_ENDPOINT  VISIONAI_API_TOKEN
#
#   STORAGE_BACKEND selects the upload target (default: aws):
#     aws   - AWS_ACCESS_KEY_ID  AWS_SECRET_ACCESS_KEY  AWS_REGION  AWS_BUCKET_NAME
#     azure - AZURE_STORAGE_CONNECTION_STRING  AZURE_STORAGE_CONTAINER
# Optional:
#   SERVER_ID          - filter recordings to this server only
#   POLL_INTERVAL      - seconds between polls (default: 300)
#   SEGMENT_DURATION   - seconds per recording segment (default: 600)
#   UPLOAD_RETRIES     - max upload attempts per segment (default: 3)
#   UPLOAD_RETRY_DELAY - base seconds between upload retries, doubled each attempt (default: 10)
#   UPLOAD_CHUNK_MB    - upload chunk size in MiB (default: 1)
#   UPLOAD_SOCKET_TIMEOUT - per-chunk socket timeout in seconds (default: 120)
#   FFMPEG_RW_TIMEOUT_US  - ffmpeg RTSP read timeout in microseconds (default: 15000000)
#   WORK_DIR           - in-flight segment dir (default: /var/lib/visionai/rec-work)
#   SPOOL_DIR          - retry backlog for segments that failed upload
#                        (default: /var/lib/visionai/rec-spool)
#   SPOOL_MAX_GB       - disk ceiling for that backlog (default: 5)
#   SPOOL_MAX_AGE_HOURS   - drop spooled segments older than this (default: 48)
#   SPOOL_DRAIN_PER_POLL  - max spooled segments retried per poll (default: 6)
#   DEBUG              - set to 1 for verbose logging
#   ENV_FILE           - path to .env file (default: ~/.visionai/.env)
#   LOG_FILE           - path to log file (default: /var/log/visionai/recording-manager.log)
# Azure-only optional:
#   AZURE_CDN_BASE_URL         - serve SAS URLs from this CDN/Front Door host instead of *.blob.core.windows.net
#   AZURE_CDN_INCLUDE_CONTAINER- set to 1 if the CDN path includes the container name
#   AZURE_SAS_EXPIRY_DAYS      - SAS token validity in days (default: 7)

set -uo pipefail

SEGMENT_DURATION=${SEGMENT_DURATION:-600}
POLL_INTERVAL=${POLL_INTERVAL:-300}
UPLOAD_RETRIES=${UPLOAD_RETRIES:-3}
UPLOAD_RETRY_DELAY=${UPLOAD_RETRY_DELAY:-10}
ENV_FILE=${ENV_FILE:-${HOME}/.visionai/.env}
LOG_FILE=${LOG_FILE:-/var/log/visionai/recording-manager.log}
STORAGE_BACKEND=${STORAGE_BACKEND:-aws}
AZURE_SAS_EXPIRY_DAYS=${AZURE_SAS_EXPIRY_DAYS:-7}
AZURE_CDN_INCLUDE_CONTAINER=${AZURE_CDN_INCLUDE_CONTAINER:-0}
# Upload chunk size in MiB. Every network blip costs at most one chunk, so on a
# weak uplink smaller is better; on a good one it only adds request overhead.
UPLOAD_CHUNK_MB=${UPLOAD_CHUNK_MB:-1}
# Per-chunk socket timeout. The default Azure SDK timeout is long enough that a
# stalled uplink burns minutes before failing, which is how a 3-attempt retry
# budget was exhausted inside one segment interval.
UPLOAD_SOCKET_TIMEOUT=${UPLOAD_SOCKET_TIMEOUT:-120}
# Socket timeout for ffmpeg's RTSP reads. Without it a camera that accepts the
# connection and then stops sending leaves ffmpeg blocked indefinitely — which
# is what produced week-old ffmpeg processes holding their camera's session.
FFMPEG_RW_TIMEOUT_US=${FFMPEG_RW_TIMEOUT_US:-15000000}

# Working directory for in-flight segments.
#
# This used to be /tmp/visionai-rec. macOS's periodic reaper deletes untouched
# /tmp files after ~3 days, and /tmp is cleared on boot, so a long recording
# could have its segment deleted out from under a running ffmpeg — the process
# keeps writing to an unlinked inode and the bytes are gone. A durable path
# removes the whole class of problem instead of working around it per-poll.
WORK_DIR=${WORK_DIR:-/var/lib/visionai/rec-work}
TMP_DIR=$WORK_DIR          # retained: existing call sites refer to TMP_DIR
ACTIVE_DIR=$TMP_DIR/active
UPLOAD_LOCK=$WORK_DIR/upload.lock
PID_FILE=${PID_FILE:-/var/run/visionai-recording-manager.pid}

# ---- Upload spool ------------------------------------------------------
# A segment that fails every upload attempt is NOT discarded. It is moved here
# with a sidecar describing where it belongs, and retried on later polls.
#
# This is deliberately NOT under /tmp: the macOS reaper deletes untouched /tmp
# files after ~3 days, which would silently destroy the very backlog this exists
# to protect. It also has to survive a daemon restart, and /tmp is cleared on
# boot.
SPOOL_DIR=${SPOOL_DIR:-/var/lib/visionai/rec-spool}
SPOOL_STATE_DIR="$SPOOL_DIR/state"
# Disk ceiling for the backlog. A site that is offline for days must not fill
# the boot volume — past the cap the OLDEST segments are evicted first, loudly,
# because a recent recording is worth more than an ancient one.
SPOOL_MAX_GB=${SPOOL_MAX_GB:-5}
# Give up on a segment this old. Past this the clip has little value and the
# backend has long since finalised the recording.
SPOOL_MAX_AGE_HOURS=${SPOOL_MAX_AGE_HOURS:-48}
# Cap the work one poll will do, so draining a large backlog can never starve
# the capture of new recordings.
SPOOL_DRAIN_PER_POLL=${SPOOL_DRAIN_PER_POLL:-6}

# Re-create the working dirs every time they're needed: macOS's periodic
# /tmp reaper deletes files under /tmp that haven't been touched in ~3 days,
# so a long-running daemon can't rely on a one-time mkdir at startup.
_ensure_tmp_dirs() {
    mkdir -p "$TMP_DIR" "$ACTIVE_DIR" 2>/dev/null || true
    mkdir -p "$SPOOL_DIR" "$SPOOL_STATE_DIR" 2>/dev/null || true
}

mkdir -p "$(dirname "$LOG_FILE")"
_ensure_tmp_dirs
exec >> "$LOG_FILE" 2>&1

_ts()       { date '+%Y-%m-%d %H:%M:%S'; }
log()       { echo "[$(_ts)] [rec-mgr] $*" >&2; }
log_warn()  { echo "[$(_ts)] [rec-mgr] WARN: $*" >&2; }
log_error() { echo "[$(_ts)] [rec-mgr] ERROR: $*" >&2; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo "[$(_ts)] [rec-mgr] DEBUG: $*" >&2 || true; }

# Safer env loader — only exports lines matching KEY=VALUE, never *executes*
# the value. Sourcing the file directly breaks on Azure connection strings
# (full of ';' and '=') and any other value with shell metacharacters.
_load_env() {
    local file="$1" line _key _val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"                              # strip Windows \r
        line="${line%"${line##*[! ]}"}"                    # strip trailing spaces
        [[ "$line" =~ ^[[:space:]]*# ]] && continue        # skip comments
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue        # skip blank lines
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue  # skip invalid
        _key="${line%%=*}"
        _val="${line#*=}"
        # Strip one layer of matching surrounding double or single quotes
        if [[ "$_val" == \"*\" ]]; then _val="${_val#\"}"; _val="${_val%\"}"; fi
        if [[ "$_val" == \'*\' ]]; then _val="${_val#\'}"; _val="${_val%\'}"; fi
        export "${_key}=${_val}"
    done < "$file"
}
if [[ -f "$ENV_FILE" ]]; then
    _load_env "$ENV_FILE"; log "Loaded $ENV_FILE"
else
    log_warn "Env file not found at $ENV_FILE — using existing environment"
fi

# Normalise backend selection (env file may have overridden the default above)
STORAGE_BACKEND=$(echo "${STORAGE_BACKEND:-aws}" | tr '[:upper:]' '[:lower:]')
case "$STORAGE_BACKEND" in
    aws|azure) ;;
    *) log_error "Unknown STORAGE_BACKEND='$STORAGE_BACKEND' (expected aws or azure)"; exit 1 ;;
esac

_check_vars() {
    local required=(VISIONAI_API_ENDPOINT VISIONAI_API_TOKEN)
    if [[ "$STORAGE_BACKEND" == "azure" ]]; then
        required+=(AZURE_STORAGE_CONNECTION_STRING AZURE_STORAGE_CONTAINER)
    else
        required+=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION AWS_BUCKET_NAME)
    fi
    local missing=()
    for v in "${required[@]}"; do
        [[ -z "${!v:-}" ]] && missing+=("$v")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required variables: ${missing[*]}"; exit 1
    fi
}
_check_vars
log "Storage backend: $STORAGE_BACKEND"

# ---- URL style: permanent CDN link vs time-limited signed link ---------
#
# Default to a permanent CDN URL whenever a CDN host is configured, because a
# signed URL expires (7 days) while that URL is stored in the backend against
# the recording — so the archive silently fills with dead links that no longer
# play. For a recording archive that is a data-retention bug, not a nicety.
#
# In the deployments seen so far this is not a weakening of access control: the
# blob container is already `public_access: blob`, meaning any blob is
# anonymously readable by anyone holding its URL. The SAS token was buying an
# expiry date, not secrecy. It still works for a private container fronted by a
# CDN that authenticates to its origin. Set CDN_PUBLIC_URLS=0 to keep expiry.
CDN_BASE_URL=${CDN_BASE_URL:-${AZURE_CDN_BASE_URL:-}}
if [[ -n "$CDN_BASE_URL" ]]; then
    CDN_PUBLIC_URLS=${CDN_PUBLIC_URLS:-1}
else
    CDN_PUBLIC_URLS=${CDN_PUBLIC_URLS:-0}
fi
if [[ "$CDN_PUBLIC_URLS" == "1" && -z "$CDN_BASE_URL" ]]; then
    log_warn "CDN_PUBLIC_URLS=1 but no CDN base URL configured — falling back to signed URLs"
    CDN_PUBLIC_URLS=0
fi
if [[ "$CDN_PUBLIC_URLS" == "1" ]]; then
    log "URL style: permanent CDN links via ${CDN_BASE_URL}"
else
    log "URL style: signed links (expire after ${AZURE_SAS_EXPIRY_DAYS}d)"
fi

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

# ---- Locate a Python 3 with the SDK the selected backend needs --------
if [[ "$STORAGE_BACKEND" == "azure" ]]; then
    _PY_IMPORT="from azure.storage.blob import BlobServiceClient"
    _PY_PKG="azure-storage-blob"
else
    _PY_IMPORT="import boto3"
    _PY_PKG="boto3"
fi
_find_python() {
    # Prefer PYTHON_BIN if set in env
    if [[ -n "${PYTHON_BIN:-}" && -x "$PYTHON_BIN" ]]; then
        "$PYTHON_BIN" -c "$_PY_IMPORT" 2>/dev/null && { echo "$PYTHON_BIN"; return; }
    fi
    # Build the search list. The daemon runs as root, so $HOME isn't the
    # deploying user's — derive candidate homes from the ENV_FILE path and
    # from every account under /Users so venvs are found regardless of which
    # user (visionify, palletvision, …) owns them.
    local _candidates=() _home _rel
    for _home in "$(dirname "$(dirname "$ENV_FILE")")" /Users/*; do
        [[ -d "$_home" ]] || continue
        for _rel in \
            vision-pallet-management-inference/.venv/bin/python3 \
            visionai/vision-pallet-management-inference/.venv/bin/python3 \
            .venv/bin/python3; do
            _candidates+=("$_home/$_rel")
        done
    done
    _candidates+=(/opt/visionai/.venv/bin/python3 python3 python)

    local _py
    for _py in "${_candidates[@]}"; do
        [[ -x "$_py" ]] || command -v "$_py" >/dev/null 2>&1 || continue
        "$_py" -c "$_PY_IMPORT" 2>/dev/null && { echo "$_py"; return; }
    done
    echo ""
}
PYTHON_BIN=$(_find_python)
if [[ -z "$PYTHON_BIN" ]]; then
    log_error "No Python 3 with $_PY_PKG found — install it (pip install $_PY_PKG) or set PYTHON_BIN in $ENV_FILE"; exit 1
fi
log "Using Python: $PYTHON_BIN ($_PY_PKG available)"

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
                "$UPLOAD_LOCK" "${CDN_BASE_URL:-}" "$CDN_PUBLIC_URLS" \
                2>"$stderr_file" <<'PYEOF'
import sys, os, warnings, mimetypes, fcntl
warnings.filterwarnings("ignore")
import boto3
from botocore.config import Config
from boto3.s3.transfer import TransferConfig
from botocore.exceptions import BotoCoreError, ClientError

(file, bucket, key, region, ak, sk, lock_path,
 cdn_base_url, public_urls) = sys.argv[1:]
try:
    # Serialize uploads across all concurrent recordings — one
    # segment uploads at a time, so multiple cameras hitting a
    # segment boundary together don't fight for the uplink. The
    # lock is released automatically when this process exits.
    lock_fp = open(lock_path, "a+")
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
    # Same trade-off as the Azure path: an unsigned CDN URL never expires, so
    # access control moves entirely to the CDN (e.g. CloudFront with an origin
    # access identity). The object ACL is left untouched — objects stay private
    # and the distribution is what serves them.
    if public_urls == "1" and cdn_base_url:
        host = cdn_base_url.split("://", 1)[-1].rstrip("/")
        print(f"https://{host}/{key}")
    else:
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
        # Exponential backoff. A flat delay retries three times inside ~30s,
        # which is far shorter than a typical uplink brown-out and burns the
        # whole budget while the link is still down.
        [[ $attempt -lt $UPLOAD_RETRIES ]] \
            && sleep $(( UPLOAD_RETRY_DELAY * (1 << (attempt - 1)) ))
        attempt=$(( attempt + 1 ))
    done

    rm -f "$stderr_file"
    log_error "S3 upload permanently failed for $key after $UPLOAD_RETRIES attempts" >&2
    echo ""
}

# ---- Upload file to Azure Blob Storage, return SAS URL or empty -------
# Mirrors _s3_upload: same outer retry loop and the same single-flight
# upload lock so concurrent recordings don't fight for the uplink. When
# AZURE_CDN_BASE_URL is set the returned URL is served from that CDN /
# Front Door host instead of *.blob.core.windows.net.
_azure_upload() {
    local file="$1" blob_name="$2"
    local attempt=1
    local stderr_file; stderr_file=$(mktemp)

    while [[ $attempt -le $UPLOAD_RETRIES ]]; do
        local result rc
        result=$("$PYTHON_BIN" - "$file" "$AZURE_STORAGE_CONTAINER" "$blob_name" \
                "$AZURE_STORAGE_CONNECTION_STRING" "${CDN_BASE_URL:-}" \
                "$AZURE_CDN_INCLUDE_CONTAINER" "$AZURE_SAS_EXPIRY_DAYS" \
                "$UPLOAD_CHUNK_MB" "$UPLOAD_SOCKET_TIMEOUT" "$UPLOAD_LOCK" \
                "$CDN_PUBLIC_URLS" \
                2>"$stderr_file" <<'PYEOF'
import sys, warnings, fcntl
warnings.filterwarnings("ignore")
from datetime import datetime, timedelta, timezone
from azure.storage.blob import (BlobServiceClient, generate_blob_sas,
                                BlobSasPermissions, ContentSettings)

(file_path, container, blob_name, conn_str,
 cdn_base_url, cdn_include_container, sas_expiry_days,
 chunk_mb, socket_timeout, lock_path, public_urls) = sys.argv[1:]
try:
    # Serialize uploads across all concurrent recordings — same lock as
    # the S3 path so multiple cameras hitting a segment boundary together
    # don't saturate the uplink. Released automatically on process exit.
    lock_fp = open(lock_path, "a+")
    fcntl.flock(lock_fp.fileno(), fcntl.LOCK_EX)

    chunk = int(chunk_mb) * 1024 * 1024
    # Chunk exactly like the S3 path. This was the asymmetry that made one
    # weak-uplink site fail ~84% of its video uploads while the others were
    # near-perfect: the S3 path had been tuned down to 1MB parts, but Azure
    # was still using SDK defaults — a 4MB block size and a single 35MB PUT
    # below the 64MB max_single_put_size threshold. One 35MB request over a
    # link that stalls mid-transfer can never succeed, and it failed with
    # "the write operation timed out" every time, on every retry.
    #
    # retry_total=0: the outer bash loop owns retrying, so the SDK must not
    # silently burn the whole per-attempt budget on its own internal retries.
    client = BlobServiceClient.from_connection_string(
        conn_str,
        max_block_size=chunk,
        max_single_put_size=chunk,
        connection_timeout=int(socket_timeout),
        read_timeout=int(socket_timeout),
        retry_total=0,
    )
    blob_client = client.get_blob_client(container=container, blob=blob_name)

    # Without an explicit content type Azure stores every blob as
    # application/octet-stream, and a browser then DOWNLOADS the recording
    # instead of playing it — <video> and <img> both fail on the returned URL.
    # The S3 path has always set this; the Azure path never did, so every clip
    # uploaded so far is unplayable in place. `inline` keeps the browser from
    # treating it as an attachment.
    import mimetypes as _mt
    guessed = _mt.guess_type(file_path)[0]
    if file_path.endswith(".mp4"):
        guessed = "video/mp4"
    content_settings = ContentSettings(
        content_type=guessed or "application/octet-stream",
        content_disposition="inline",
    )
    with open(file_path, "rb") as f:
        blob_client.upload_blob(f, overwrite=True, max_concurrency=1,
                                content_settings=content_settings)
    # A permanent CDN URL carries no SAS token, so it never expires — which is
    # the point, but it also means the object is reachable by anyone holding the
    # link. That is only safe when the CDN/Front Door origin is what enforces
    # access; the blob container itself must not be left publicly enumerable.
    if public_urls == "1" and cdn_base_url:
        host = cdn_base_url.split("://", 1)[-1].rstrip("/")
        path = f"{container}/{blob_name}" if cdn_include_container == "1" else blob_name
        print(f"https://{host}/{path}")
    else:
        sas_token = generate_blob_sas(
            account_name=client.account_name,
            container_name=container,
            blob_name=blob_name,
            account_key=client.credential.account_key,
            permission=BlobSasPermissions(read=True),
            expiry=datetime.now(timezone.utc) + timedelta(days=int(sas_expiry_days)),
        )
        if cdn_base_url:
            host = cdn_base_url.split("://", 1)[-1].rstrip("/")
            path = f"{container}/{blob_name}" if cdn_include_container == "1" else blob_name
            url = f"https://{host}/{path}?{sas_token}"
        else:
            url = f"{blob_client.url}?{sas_token}"
        print(url)
except Exception as e:
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
        log_warn "Azure upload failed for $blob_name (attempt $attempt/$UPLOAD_RETRIES): ${err}" >&2
        # Exponential backoff. A flat delay retries three times inside ~30s,
        # which is far shorter than a typical uplink brown-out and burns the
        # whole budget while the link is still down.
        [[ $attempt -lt $UPLOAD_RETRIES ]] \
            && sleep $(( UPLOAD_RETRY_DELAY * (1 << (attempt - 1)) ))
        attempt=$(( attempt + 1 ))
    done

    rm -f "$stderr_file"
    log_error "Azure upload permanently failed for $blob_name after $UPLOAD_RETRIES attempts" >&2
    echo ""
}

# ---- Backend-agnostic upload: dispatches to the configured backend ----
_storage_upload() {
    if [[ "$STORAGE_BACKEND" == "azure" ]]; then
        _azure_upload "$@"
    else
        _s3_upload "$@"
    fi
}

# ---- Verify the permanent-URL configuration before trusting it ---------
#
# A permanent CDN URL is only useful if it actually resolves, and the path shape
# is deployment-specific: whether the container name belongs in the path depends
# on how the CDN origin is configured. Guessing wrong produces URLs that 404 —
# and because the URL is written into the backend against the recording, a wrong
# guess silently fills the archive with dead links that nobody notices until
# someone tries to play a clip weeks later.
#
# So don't guess: upload a few bytes once at startup, try each path shape, and
# keep the one that returns 200. If none does, fall back to signed URLs, which
# expire but at least work.
_probe_public_url() {
    [[ "$CDN_PUBLIC_URLS" == "1" ]] || return 0

    local probe="${WORK_DIR}/.cdn-probe"
    local key="recordings/.cdn-probe.txt"
    echo "visionai recording-manager cdn probe" > "$probe" 2>/dev/null || return 0

    # Upload once (signed path is irrelevant here — we only need the object).
    local saved="$CDN_PUBLIC_URLS"
    CDN_PUBLIC_URLS=0
    _storage_upload "$probe" "$key" >/dev/null 2>&1
    CDN_PUBLIC_URLS="$saved"
    rm -f "$probe"

    local host; host=$(echo "$CDN_BASE_URL" | sed -E 's|^[a-z]+://||; s|/$||')
    local container="${AZURE_STORAGE_CONTAINER:-$AWS_BUCKET_NAME}"
    local shape code
    for shape in "$AZURE_CDN_INCLUDE_CONTAINER" 1 0; do
        if [[ "$shape" == "1" ]]; then
            code=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 20 "https://${host}/${container}/${key}" 2>/dev/null)
        else
            code=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 20 "https://${host}/${key}" 2>/dev/null)
        fi
        if [[ "$code" == "200" ]]; then
            if [[ "$AZURE_CDN_INCLUDE_CONTAINER" != "$shape" ]]; then
                log_warn "CDN path shape corrected: AZURE_CDN_INCLUDE_CONTAINER=$shape (configured $AZURE_CDN_INCLUDE_CONTAINER returned 404)"
            fi
            AZURE_CDN_INCLUDE_CONTAINER="$shape"
            log "CDN probe OK — permanent URLs resolve (HTTP 200, container-in-path=$shape)"
            return 0
        fi
    done

    log_error "CDN probe failed (last HTTP $code) — permanent URLs would 404, falling back to signed URLs"
    CDN_PUBLIC_URLS=0
}

_file_size() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }
_file_mtime() { stat -f%m "$1" 2>/dev/null || stat -c%Y "$1" 2>/dev/null || echo 0; }

# ---- Upload spool: keep the bytes when the network refuses them -------
#
# Previously a segment whose uploads all failed was deleted "to free disk".
# That converted a transient uplink problem into permanent, unrecoverable data
# loss: the recording existed on disk, was thrown away, and the backend was
# still told about the segment — with an empty url but a working thumbnail_url,
# because the tiny thumbnail uploaded fine while the 35MB video timed out.
# That is exactly the "thumbnail but no video" the operators saw.
#
# Now the file is parked here with a sidecar saying where it belongs, and later
# polls retry it. State lives with the spool so it survives a daemon restart.

# Persistent per-recording segment array (the same JSON pushed to the API).
_spool_state_file() { echo "${SPOOL_STATE_DIR}/segs_${1}.json"; }

# Park a segment that could not be uploaded. Args: file rec_id key idx entry_index
_spool_add() {
    local file="$1" rec_id="$2" key="$3" idx="$4" entry_index="$5"
    _ensure_tmp_dirs
    local base="rec${rec_id}_seg${idx}_$(date +%s)"
    local dest="${SPOOL_DIR}/${base}.mp4"
    if ! mv "$file" "$dest" 2>/dev/null; then
        log_error "Recording $rec_id: could not spool segment $idx — file left at $file"
        return 1
    fi
    jq -n --arg rid "$rec_id" --arg key "$key" --arg idx "$idx" \
          --argjson ei "$entry_index" --argjson ts "$(date +%s)" \
          '{recording_id:$rid,key:$key,segment:$idx,entry_index:$ei,spooled_at:$ts}' \
          > "${SPOOL_DIR}/${base}.json"
    log_warn "Recording $rec_id: segment $idx spooled for retry ($(_file_size "$dest")B) — $dest"
}

# Total spool size in bytes (mp4s only).
_spool_bytes() {
    local total=0 f
    for f in "$SPOOL_DIR"/*.mp4; do
        [[ -e "$f" ]] || continue
        total=$(( total + $(_file_size "$f") ))
    done
    echo "$total"
}

# Enforce the age and size ceilings. Oldest first: a stale clip is worth less
# than the one recorded five minutes ago, and an unbounded spool would fill the
# boot volume on a site that stays offline.
_spool_evict() {
    local now; now=$(date +%s)
    local max_age=$(( SPOOL_MAX_AGE_HOURS * 3600 ))
    local f age
    for f in "$SPOOL_DIR"/*.mp4; do
        [[ -e "$f" ]] || continue
        age=$(( now - $(_file_mtime "$f") ))
        if [[ $age -gt $max_age ]]; then
            log_error "Spool: dropping $(basename "$f") — older than ${SPOOL_MAX_AGE_HOURS}h ($(( age / 3600 ))h), never uploaded"
            rm -f "$f" "${f%.mp4}.json"
        fi
    done

    local cap=$(( SPOOL_MAX_GB * 1024 * 1024 * 1024 ))
    local used; used=$(_spool_bytes)
    [[ $used -le $cap ]] && return 0
    log_error "Spool: ${used}B exceeds the ${SPOOL_MAX_GB}GB cap — evicting oldest segments"
    # ls -tr: oldest first
    local victim
    while [[ $used -gt $cap ]]; do
        victim=$(ls -tr "$SPOOL_DIR"/*.mp4 2>/dev/null | head -1)
        [[ -z "$victim" ]] && break
        used=$(( used - $(_file_size "$victim") ))
        log_error "Spool: evicting $(basename "$victim") to stay under cap — this recording is lost"
        rm -f "$victim" "${victim%.mp4}.json"
    done
}

# Retry spooled segments. Bounded per poll so a large backlog can never starve
# the capture of new recordings.
_spool_drain() {
    _ensure_tmp_dirs
    _spool_evict

    local pending; pending=$(ls "$SPOOL_DIR"/*.mp4 2>/dev/null | wc -l | tr -d ' ')
    [[ "$pending" -eq 0 ]] && return 0
    log "Spool: $pending segment(s) awaiting upload, retrying up to $SPOOL_DRAIN_PER_POLL"

    local done_count=0 f meta rec_id key entry_index url state
    # Oldest first so the backlog drains in recording order.
    for f in $(ls -tr "$SPOOL_DIR"/*.mp4 2>/dev/null); do
        [[ $done_count -ge $SPOOL_DRAIN_PER_POLL ]] && break
        meta="${f%.mp4}.json"
        if [[ ! -f "$meta" ]]; then
            log_warn "Spool: $(basename "$f") has no sidecar — dropping"
            rm -f "$f"; continue
        fi
        rec_id=$(jq -r '.recording_id' "$meta")
        key=$(jq -r '.key' "$meta")
        entry_index=$(jq -r '.entry_index' "$meta")

        url=$(_storage_upload "$f" "$key") || url=""
        done_count=$(( done_count + 1 ))
        if [[ -z "$url" ]]; then
            log_warn "Spool: retry failed for $(basename "$f") — staying spooled"
            continue
        fi

        log "Spool: recovered $(basename "$f") -> uploaded"
        rm -f "$f" "$meta"

        # Patch the URL into the recording's segment array and re-push it, so a
        # segment that lands late still reaches the backend.
        state=$(_spool_state_file "$rec_id")
        if [[ -f "$state" ]]; then
            jq --argjson i "$entry_index" --arg u "$url" \
               'if (.|length) > $i then (.[$i].url = $u | .[$i] |= del(.pending)) else . end' \
               "$state" > "${state}.tmp" && mv "${state}.tmp" "$state"
            _push_segments "$rec_id" "$url" "$state"
            # Once nothing is pending the state file has done its job.
            if [[ "$(jq '[.[] | select(.pending == true)] | length' "$state")" == "0" ]] \
               && [[ ! -f "${ACTIVE_DIR}/${rec_id}" ]]; then
                rm -f "$state"
            fi
        else
            log_warn "Spool: no segment state for recording $rec_id — URL recovered but not re-pushed"
        fi
    done
}

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

# `pending` is bookkeeping for the local spool, not part of the API contract —
# strip it so the payload stays exactly what the backend already accepts.
_segments_payload() { jq 'map(del(.pending))' "$1" 2>/dev/null || echo "[]"; }

_api_complete() {
    local resp
    resp=$(_api_patch "${VISIONAI_API_ENDPOINT}/recordings/inference" \
        "$(jq -n \
            --arg rid "$1" \
            --arg s3u "$2" \
            --argjson sl "$(_segments_payload "$3")" \
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
            --argjson sl "$(_segments_payload "$3")" \
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
        -rw_timeout "${FFMPEG_RW_TIMEOUT_US}" \
        -vf "scale='min(1280,iw)':-2" \
        "${VIDEO_ENCODER_ARGS[@]}" \
        -an -movflags +faststart -y "$out" \
        >/dev/null 2>&1 &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        if [[ $(date +%s) -gt $deadline ]]; then
            # SIGTERM, then SIGKILL if it does not go. An ffmpeg blocked in a
            # stalled RTSP read ignores TERM, and the old code then fell into an
            # unbounded `wait` — which is how processes survived for a week,
            # holding their camera's RTSP connection against the inference engine
            # and wedging the recording that spawned them. Never wait forever on
            # a process we have already decided to kill.
            log_warn "ffmpeg deadline exceeded for $out — terminating"
            kill -TERM "$pid" 2>/dev/null || true
            local waited=0
            while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 10 ]]; do
                sleep 1; waited=$(( waited + 1 ))
            done
            if kill -0 "$pid" 2>/dev/null; then
                log_error "ffmpeg ignored SIGTERM for $out — SIGKILL"
                kill -KILL "$pid" 2>/dev/null || true
                sleep 1
            fi
            break
        fi
    done
    wait "$pid" 2>/dev/null || true
}

# ---- Reap ffmpeg left behind by a previous daemon generation ------------
# launchd restarts the manager, but any ffmpeg it had spawned keeps running and
# keeps its RTSP session open. Those sessions compete with the inference engine
# for single-consumer cameras, so clear them out before starting new captures.
_reap_stale_ffmpeg() {
    local max_life=$(( SEGMENT_DURATION + 300 ))
    local now; now=$(date +%s)
    local pid started age
    while read -r pid started; do
        [[ -z "$pid" ]] && continue
        # Never touch ffmpeg belonging to a live recording of THIS generation.
        kill -0 "$pid" 2>/dev/null || continue
        age=$(( now - started ))
        [[ $age -lt $max_life ]] && continue
        log_error "Reaping stale ffmpeg pid=$pid (age $(( age / 60 ))m, > $(( max_life / 60 ))m) — it was holding an RTSP session"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    # macOS ps has no `etimes` (that is a Linux/procps keyword — it errors out
    # with "keyword not found", which would make this reaper silently do
    # nothing). Parse the portable `etime` form: [[DD-]HH:]MM:SS.
    # Match the legacy /tmp path too. The processes this was written to clean up
    # were started by an older build and are still writing to /tmp/visionai-rec,
    # so matching only the new WORK_DIR would walk straight past them.
    done < <(ps -eo pid=,etime=,args= \
             | awk -v now="$now" -v dir="$WORK_DIR" -v legacy="/tmp/visionai-rec" '
                 index($0, "ffmpeg") && (index($0, dir) || index($0, legacy)) && !index($0, "awk") {
                     e = $2; d = 0
                     if (e ~ /-/) { split(e, p, "-"); d = p[1]; e = p[2] }
                     n = split(e, t, ":")
                     if (n == 3)      secs = t[1]*3600 + t[2]*60 + t[3]
                     else if (n == 2) secs = t[1]*60 + t[2]
                     else             secs = 0
                     secs += d * 86400
                     print $1, now - secs
                 }')
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
        _storage_upload "$tmp" "$s3_key"
        rm -f "$tmp"
    else
        rm -f "$tmp"; echo ""
    fi
}

# ---- Full recording lifecycle (invoked as a background subprocess) ----
_run_recording() {
    trap - EXIT INT TERM  # don't inherit the parent's PID-file cleanup trap
    _ensure_tmp_dirs      # this runs in a subshell; guarantee dirs before mktemp/ffmpeg

    local rec_id="$1" cam_id="$2" cam_name="$3" dur_min="$4" rtsp="$5"
    # Sanitise camera name for use as an S3 path component
    local cam_safe; cam_safe=$(echo "$cam_name" | tr '[:upper:]' '[:lower:]' | tr ' /' '--' | tr -cd 'a-z0-9_-')
    local rec_ts; rec_ts=$(date '+%Y%m%d-%H%M%S')
    local base="recordings/${cam_safe}"
    local total=$(( dur_min * 60 )) elapsed=0 idx=0
    # The segment array lives in the spool state dir, not a mktemp under /tmp:
    # a segment that lands from the spool hours later still needs this array to
    # patch its URL into, and that must survive both the /tmp reaper and a
    # daemon restart.
    local segs; segs=$(_spool_state_file "$rec_id")
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
            local seg_key="${base}/${fname}.mp4"

            # Video FIRST, thumbnail second. The thumbnail is ~50KB and almost
            # always succeeds; the video is tens of MB and is what actually fails
            # on a weak uplink. Uploading the thumbnail first is what published a
            # thumbnail with no video and made a lost recording look like a
            # successful one in the UI.
            local url; url=$(_storage_upload "$seg_file" "$seg_key") || url=""

            local thumb=""
            if [[ -n "$url" ]]; then
                thumb=$(_upload_thumb "$seg_file" "${base}/${fname}_thumb.jpg") || thumb=""
            fi

            # entry_index is the position this segment will occupy in the array,
            # so a late spool recovery knows which element to patch.
            local entry_index; entry_index=$(jq 'length' "$segs")
            local entry
            if [[ -n "$url" ]]; then
                rm -f "$seg_file"
                last_url="$url"
                if [[ -n "$thumb" ]]; then
                    entry=$(jq -n --arg u "$url" --argjson s "$sz" \
                                  --argjson d "$seg_dur" --arg t "$thumb" \
                        '{url:$u,size_bytes:$s,duration_seconds:$d,thumbnail_url:$t}')
                else
                    entry=$(jq -n --arg u "$url" --argjson s "$sz" --argjson d "$seg_dur" \
                        '{url:$u,size_bytes:$s,duration_seconds:$d}')
                fi
                log "Recording $rec_id: segment $idx_fmt uploaded (${sz}B)"
            else
                # Keep the bytes. Mark the entry pending so the backend can tell
                # "still uploading" from "gone", and so _spool_drain can find it.
                entry=$(jq -n --argjson s "$sz" --argjson d "$seg_dur" \
                    '{url:"",size_bytes:$s,duration_seconds:$d,pending:true}')
                log_warn "Recording $rec_id: segment $idx_fmt upload failed (${sz}B) — spooling for retry"
                _spool_add "$seg_file" "$rec_id" "$seg_key" "$idx_fmt" "$entry_index"
            fi

            jq --argjson e "$entry" '. + [$e]' "$segs" > "${segs}.tmp" \
                && mv "${segs}.tmp" "$segs"
            _push_segments "$rec_id" "${last_url:-}" "$segs"
        else
            log_warn "Recording $rec_id: segment $idx_fmt missing or empty"
            rm -f "$seg_file"
        fi

        elapsed=$(( elapsed + seg_dur ))
        idx=$(( idx + 1 ))
    done

    _api_complete "$rec_id" "${last_url:-}" "$segs"
    rm -f "${ACTIVE_DIR}/${rec_id}" "${segs}.tmp" 2>/dev/null || true

    # Keep the segment array only while something is still spooled for it —
    # _spool_drain needs it to patch in a late URL and re-push. Deleting it
    # unconditionally is what would strand a recovered segment with nowhere to
    # report itself.
    local still_pending; still_pending=$(jq '[.[] | select(.pending == true)] | length' "$segs" 2>/dev/null || echo 0)
    if [[ "$still_pending" == "0" ]]; then
        rm -f "$segs" 2>/dev/null || true
        log "Recording $rec_id: done"
    else
        log_warn "Recording $rec_id: done, but $still_pending segment(s) still queued for upload — will retry from the spool"
    fi
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
    _ensure_tmp_dirs   # re-create dirs in case the OS reaped them since last poll
    _reap_stale_ffmpeg # clear captures that outlived their recording
    # Drain first: a segment already on disk is worth more than one not yet
    # captured, and this is bounded so it cannot starve new recordings.
    _spool_drain
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

# ---- One-time migration from the old /tmp working directory ------------
# Earlier versions kept in-flight segments in /tmp/visionai-rec. Anything left
# there is a segment that was captured but never uploaded, so carry it into the
# spool rather than leaving it for the reaper to delete.
_migrate_legacy_tmp() {
    local legacy=/tmp/visionai-rec
    [[ "$WORK_DIR" == "$legacy" ]] && return 0
    [[ -d "$legacy" ]] || return 0
    local f n=0
    for f in "$legacy"/rec_*.mp4; do
        [[ -e "$f" ]] || continue
        # Orphans from a previous generation: no sidecar exists, so they cannot
        # be re-pushed to a recording. Keep the bytes where an operator can find
        # them instead of silently discarding evidence.
        mv "$f" "${SPOOL_DIR}/orphan_$(basename "$f")" 2>/dev/null && n=$(( n + 1 ))
    done
    [[ $n -gt 0 ]] && log_warn "Migrated $n orphaned segment(s) from $legacy into the spool (no sidecar — recover manually)"
    return 0
}

# ---- Main loop ---------------------------------------------------------
_migrate_legacy_tmp
log "Work dir: $WORK_DIR | spool: $SPOOL_DIR (cap ${SPOOL_MAX_GB}GB, max age ${SPOOL_MAX_AGE_HOURS}h)"
_probe_public_url
_poll   # immediate check on startup

while true; do
    sleep "$POLL_INTERVAL"
    _poll
done
