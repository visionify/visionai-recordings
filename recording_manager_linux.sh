#!/usr/bin/env bash
# VisionAI Recording Manager — Linux/Debian
#
# This single script serves two purposes:
#   1. Installer  — sets up dependencies and a systemd service (run once with sudo)
#   2. Daemon     — polls the API and manages camera recordings (run by systemd)
#
# ── Install ──────────────────────────────────────────────────────────────────
#
#   curl -fsSL https://raw.githubusercontent.com/visionify/visionai-recordings/main/recording_manager_linux.sh \
#     | sudo bash -s install
#
# With a custom .env file path (default: ~/.visionai/.env):
#
#   curl -fsSL ... | sudo bash -s install ENV_FILE=/path/to/.env
#
# ── Uninstall ─────────────────────────────────────────────────────────────────
#
#   sudo systemctl stop visionai-recording-manager
#   sudo systemctl disable visionai-recording-manager
#   sudo rm /etc/systemd/system/visionai-recording-manager.service
#   sudo rm /usr/local/bin/visionai-recording-manager
#   sudo systemctl daemon-reload
#
# ── Daemon env vars (set in ENV_FILE) ────────────────────────────────────────
#   Required: VISIONAI_API_ENDPOINT  VISIONAI_API_TOKEN
#             EVENTS_AZURE_BLOB_CONNECTION_STRING
#   Optional: POLL_INTERVAL (default 300s)
#             UPLOAD_RETRIES (default 3)   UPLOAD_RETRY_DELAY (default 10s)
#             PYTHON_BIN  DEBUG  ENV_FILE  LOG_FILE

set -uo pipefail

# =============================================================================
# INSTALLER  (only runs when first arg is "install")
# =============================================================================
if [[ "${1:-}" == "install" || "${1:-}" == "--install" ]]; then

    REPO_URL="https://raw.githubusercontent.com/visionify/visionai-recordings/main/recording_manager_linux.sh"
    INSTALL_BIN="/usr/local/bin/visionai-recording-manager"
    SERVICE_NAME="visionai-recording-manager"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    LOG_DIR="/var/log/visionai"

    REAL_USER="${SUDO_USER:-$(whoami)}"
    REAL_HOME=$(eval echo "~$REAL_USER")
    DEFAULT_ENV_FILE="${REAL_HOME}/.visionai/.env"

    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
    ok()   { echo -e "${GREEN}  ✓${NC}  $*"; }
    warn() { echo -e "${YELLOW}  !${NC}  $*"; }
    err()  { echo -e "${RED}  ✗${NC}  $*" >&2; exit 1; }
    step() { echo -e "\n${BLUE}▶${NC}  $*"; }

    echo ""
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │   VisionAI Recording Manager  ·  Linux      │"
    echo "  └─────────────────────────────────────────────┘"
    echo ""

    [[ "$(uname)" == "Linux" ]] \
        || err "This installer targets Linux only (detected: $(uname))"
    [[ "$(id -u)" -eq 0 ]] \
        || err "Run this installer with sudo — see usage at the top of this script"
    command -v apt-get  >/dev/null 2>&1 || err "apt-get not found — requires a Debian/Ubuntu system"
    command -v systemctl >/dev/null 2>&1 || err "systemd not found — requires a systemd-based system"

    # ── Dependencies ─────────────────────────────────────────────────────────
    step "Updating package lists and checking dependencies..."
    apt-get update -qq </dev/null

    _apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" </dev/null; }

    _require() {
        local cmd="$1" pkg="${2:-$1}"
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$cmd  $(command -v "$cmd")"
        else
            warn "$cmd not found — installing..."
            _apt_install "$pkg"
            hash -r 2>/dev/null || true
            command -v "$cmd" >/dev/null 2>&1 \
                || err "$cmd still not found after install — check apt output above"
            ok "$cmd  $(command -v "$cmd")"
        fi
    }

    _require jq
    _require ffmpeg
    _require curl
    _require python3
    # python3-venv is a separate package on Debian/Ubuntu
    _apt_install python3-venv

    # ── Python venv + azure-storage-blob ─────────────────────────────────────
    VENV_DIR="/opt/visionai/.venv"
    step "Setting up Python venv at $VENV_DIR..."
    mkdir -p "$(dirname "$VENV_DIR")"

    if [[ ! -x "$VENV_DIR/bin/python3" ]]; then
        python3 -m venv "$VENV_DIR" || err "Failed to create venv at $VENV_DIR"
        ok "Created venv: $VENV_DIR"
    else
        ok "Venv already exists: $VENV_DIR"
    fi

    if "$VENV_DIR/bin/python3" -c "from azure.storage.blob import BlobServiceClient" 2>/dev/null; then
        ok "azure-storage-blob already installed"
    else
        warn "Installing azure-storage-blob into venv..."
        "$VENV_DIR/bin/pip" install --quiet azure-storage-blob \
            || err "pip install azure-storage-blob failed — check your network and try again"
        "$VENV_DIR/bin/python3" -c "from azure.storage.blob import BlobServiceClient" 2>/dev/null \
            || err "azure-storage-blob not importable after install"
        ok "azure-storage-blob installed"
    fi

    # ── Env file ──────────────────────────────────────────────────────────────
    step "Locating env file..."
    ENV_FILE="${ENV_FILE:-}"

    if [[ -z "$ENV_FILE" ]]; then
        for _c in "$DEFAULT_ENV_FILE" "/root/.visionai/.env"; do
            [[ -f "$_c" ]] && { ENV_FILE="$_c"; break; }
        done
    fi

    if [[ -z "$ENV_FILE" ]]; then
        echo "  No .env file found. Enter the full path to your .env file:"
        read -rp "  > " ENV_FILE
    fi

    [[ -f "$ENV_FILE" ]] || err "Env file not found: $ENV_FILE"

    if [[ "$ENV_FILE" != "$DEFAULT_ENV_FILE" ]]; then
        mkdir -p "$(dirname "$DEFAULT_ENV_FILE")"
        cp "$ENV_FILE" "$DEFAULT_ENV_FILE"
        ok "Copied $ENV_FILE → $DEFAULT_ENV_FILE"
        ENV_FILE="$DEFAULT_ENV_FILE"
    fi

    chmod 600 "$ENV_FILE"
    chown "$REAL_USER" "$ENV_FILE"
    ok "Env file: $ENV_FILE"

    # ── Install this script ───────────────────────────────────────────────────
    step "Installing recording manager..."
    mkdir -p "$(dirname "$INSTALL_BIN")"
    mkdir -p "$LOG_DIR"

    # If we're running from a real file, copy it directly; otherwise download.
    if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        cp "${BASH_SOURCE[0]}" "$INSTALL_BIN"
        ok "Installed (from local copy): $INSTALL_BIN"
    else
        curl -fsSL "$REPO_URL" -o "$INSTALL_BIN" </dev/null \
            || err "Download failed: $REPO_URL"
        ok "Installed (downloaded): $INSTALL_BIN"
        ok "Source: $REPO_URL"
    fi
    chmod +x "$INSTALL_BIN"
    ok "Log dir: $LOG_DIR"

    # ── systemd service unit ──────────────────────────────────────────────────
    step "Creating systemd service unit..."

    cat > "$SERVICE_FILE" << SERVICE_EOF
[Unit]
Description=VisionAI Recording Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash ${INSTALL_BIN}
Restart=always
RestartSec=10
Environment=ENV_FILE=${ENV_FILE}
Environment=LOG_FILE=${LOG_DIR}/recording-manager.log
Environment=PYTHON_BIN=${VENV_DIR}/bin/python3

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    chmod 644 "$SERVICE_FILE"
    ok "Service file: $SERVICE_FILE"

    # ── Enable and start ──────────────────────────────────────────────────────
    step "Enabling and starting service..."
    systemctl daemon-reload

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        warn "Service already running — restarting..."
        systemctl restart "$SERVICE_NAME"
    else
        systemctl enable "$SERVICE_NAME"
        systemctl start "$SERVICE_NAME"
    fi

    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Service running  ($SERVICE_NAME)"
    else
        warn "Service may not be active yet — check: journalctl -u $SERVICE_NAME -f"
    fi

    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │  Done!                                                          │"
    echo "  │                                                                 │"
    printf "  │  Service  %-54s│\n" "$SERVICE_NAME"
    printf "  │  Binary   %-54s│\n" "$INSTALL_BIN"
    printf "  │  Env file %-54s│\n" "$ENV_FILE"
    printf "  │  Logs     %-54s│\n" "${LOG_DIR}/recording-manager.log"
    echo "  │                                                                 │"
    echo "  │  Useful commands:                                               │"
    echo "  │    journalctl -u visionai-recording-manager -f                  │"
    echo "  │    systemctl status visionai-recording-manager                  │"
    echo "  │    systemctl restart visionai-recording-manager                 │"
    echo "  │    systemctl stop visionai-recording-manager                    │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    exit 0
fi

# =============================================================================
# RECORDING MANAGER DAEMON  (default mode — invoked by systemd)
# =============================================================================

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

# Safer env loader — only exports lines matching KEY=VALUE, skips comments/blanks
_load_env() {
    local file="$1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%$'\r'}"                              # strip Windows \r
        line="${line%"${line##*[! ]}"}"                    # strip trailing spaces
        [[ "$line" =~ ^[[:space:]]*# ]] && continue       # skip comments
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue       # skip blank lines
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]    || continue   # skip invalid
        local _key="${line%%=*}"
        local _val="${line#*=}"
        # Strip matching surrounding double or single quotes
        if [[ "$_val" == \"*\" ]]; then _val="${_val#\"}"; _val="${_val%\"}"; fi
        if [[ "$_val" == \'*\' ]]; then _val="${_val#\'}"; _val="${_val%\'}"; fi
        export "${_key}=${_val}"
    done < "$file"
}
if [[ -f "$ENV_FILE" ]]; then
    _load_env "$ENV_FILE"
    log "Loaded $ENV_FILE"
else
    log_warn "Env file not found at $ENV_FILE — using existing environment"
fi

_check_vars() {
    local missing=()
    for v in VISIONAI_API_ENDPOINT VISIONAI_API_TOKEN \
              EVENTS_AZURE_BLOB_CONNECTION_STRING; do
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

# ---- Locate a Python 3 with azure-storage-blob -------------------------
_find_python() {
    if [[ -n "${PYTHON_BIN:-}" && -x "$PYTHON_BIN" ]]; then
        "$PYTHON_BIN" -c "from azure.storage.blob import BlobServiceClient" 2>/dev/null \
            && { echo "$PYTHON_BIN"; return; }
    fi
    for _py in \
        /opt/visionai/.venv/bin/python3 \
        /home/visionify/.venv/bin/python3 \
        /home/visionify/visionai/.venv/bin/python3 \
        /usr/local/bin/python3 \
        python3 python; do
        [[ -x "$_py" ]] || command -v "$_py" >/dev/null 2>&1 || continue
        "$_py" -c "from azure.storage.blob import BlobServiceClient" 2>/dev/null \
            && { echo "$_py"; return; }
    done
    echo ""
}
PYTHON_BIN=$(_find_python)
if [[ -z "$PYTHON_BIN" ]]; then
    log_error "No Python 3 with azure-storage-blob found — run: pip3 install azure-storage-blob"
    exit 1
fi
log "Using Python: $PYTHON_BIN (azure-storage-blob available)"

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
log "Started (PID=$$, poll=${POLL_INTERVAL}s)"
log "API endpoint: ${VISIONAI_API_ENDPOINT:-<NOT SET>}"
if [[ -n "${VISIONAI_API_TOKEN:-}" ]]; then
    log "API token: set (${#VISIONAI_API_TOKEN} chars)"
else
    log "API token: <NOT SET>"
fi

# ---- API helpers -------------------------------------------------------
_api_get() {
    curl -sf --max-time "${2:-10}" \
        -H "Content-Type: application/json" \
        -H "Token: $VISIONAI_API_TOKEN" \
        "$1"
}

_api_post() {
    curl -sf --max-time 10 -X POST \
        -H "Content-Type: application/json" \
        -H "Token: $VISIONAI_API_TOKEN" \
        -d "$2" "$1"
}

# POST /v2/update-recording-url — covers in_progress, completed, failed
_api_update() {
    local recording_id="$1" azure_url="$2" status="$3"
    local start_time="${4:-}" stop_time="${5:-}" duration="${6:-0}" camera_id="${7:-0}"
    local body resp
    body=$(jq -n \
        --argjson rid "$recording_id" \
        --arg     url "$azure_url" \
        --arg     st  "$status" \
        --arg     start "$start_time" \
        --arg     stop  "$stop_time" \
        --argjson dur   "$duration" \
        --argjson cid   "$camera_id" \
        '{recording_id:$rid,azure_url:$url,status:$st,
          start_time:$start,stop_time:$stop,duration:$dur,camera_id:$cid}')
    resp=$(_api_post "${VISIONAI_API_ENDPOINT}/v2/update-recording-url" "$body" 2>/dev/null) || true
    log_debug "Recording $recording_id: _api_update status=$status resp=${resp:0:120}"
}

# Claim recording by setting status to in_progress; returns 0 if claimed, 1 if rejected
_api_start() {
    local rec_id="$1" cam_id="$2" start_time="$3"
    local tmp code body ok
    tmp=$(mktemp)
    code=$(curl -s -o "$tmp" -w "%{http_code}" --max-time 10 -X POST \
        -H "Content-Type: application/json" \
        -H "Token: $VISIONAI_API_TOKEN" \
        -d "$(jq -n \
                --arg rid   "$rec_id" \
                --arg cid   "$cam_id" \
                --arg start "$start_time" \
                '{recording_id:$rid,camera_id:$cid,azure_url:"",
                  status:"in_progress",start_time:$start,stop_time:"",duration:0}')" \
        "${VISIONAI_API_ENDPOINT}/v2/update-recording-url")
    body=$(cat "$tmp" 2>/dev/null); rm -f "$tmp"
    ok=$(echo "$body" | jq -r '.success // "false"' 2>/dev/null)
    log_debug "Recording $rec_id: _api_start HTTP=$code body=${body:0:200}"
    if [[ "$code" == "409" ]]; then
        log "Recording $rec_id: claim rejected (409) — already claimed by another server"
        return 1
    fi
    if [[ "$ok" != "true" ]]; then
        log_warn "Recording $rec_id: claim failed (HTTP $code): ${body:0:300}"
        return 1
    fi
    return 0
}

# ---- Create raw-recordings container if it doesn't exist ---------------
_ensure_raw_recordings_folder() {
    "$PYTHON_BIN" - "$EVENTS_AZURE_BLOB_CONNECTION_STRING" 2>/dev/null <<'PYEOF' || true
import sys
from azure.storage.blob import BlobServiceClient
conn_str = sys.argv[1]
client = BlobServiceClient.from_connection_string(conn_str)
container_client = client.get_container_client("raw-recordings")
try:
    container_client.get_container_properties()
except Exception:
    container_client.create_container()
    print("Created container: raw-recordings")
PYEOF
}

# ---- Upload file to Azure Blob Storage, return SAS URL or empty --------
_azure_upload() {
    local file="$1" blob_name="$2"
    local attempt=1

    while [[ $attempt -le $UPLOAD_RETRIES ]]; do
        local result
        result=$("$PYTHON_BIN" - "$file" "raw-recordings" \
                "$blob_name" "$EVENTS_AZURE_BLOB_CONNECTION_STRING" 2>&1 <<'PYEOF'
import sys
from azure.storage.blob import BlobServiceClient, generate_blob_sas, BlobSasPermissions
from datetime import datetime, timedelta, timezone
file_path, container, blob_name, conn_str = sys.argv[1:]
try:
    client = BlobServiceClient.from_connection_string(conn_str)
    blob_client = client.get_blob_client(container=container, blob=blob_name)
    with open(file_path, "rb") as f:
        blob_client.upload_blob(f, overwrite=True)
    sas_token = generate_blob_sas(
        account_name=client.account_name,
        container_name=container,
        blob_name=blob_name,
        account_key=client.credential.account_key,
        permission=BlobSasPermissions(read=True),
        expiry=datetime.now(timezone.utc) + timedelta(days=7),
    )
    print(f"{blob_client.url}?{sas_token}")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
        ) && { echo "$result"; return; }

        log_warn "Azure upload failed for $blob_name (attempt $attempt/$UPLOAD_RETRIES): ${result}" >&2
        attempt=$(( attempt + 1 ))
        [[ $attempt -le $UPLOAD_RETRIES ]] && sleep "$UPLOAD_RETRY_DELAY"
    done

    log_error "Azure upload permanently failed for $blob_name after $UPLOAD_RETRIES attempts" >&2
    echo ""
}

_file_size() { stat -c%s "$1" 2>/dev/null || echo 0; }

# ---- ffmpeg capture with deadline watchdog; stderr saved to <out>.err ----
_ffmpeg_run() {
    local out="$1" dur="$2" errfile="$3" deadline="$4"
    shift 4

    "$@" >/dev/null 2>"$errfile" &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        if [[ $(date +%s) -gt $deadline ]]; then
            kill "$pid" 2>/dev/null || true
            log_warn "ffmpeg deadline exceeded for $out — killed"
            break
        fi
    done
    wait "$pid" 2>/dev/null || true
}

_ffmpeg_record() {
    local rtsp="$1" out="$2" dur="$3"
    local errfile="${out}.err"
    local deadline=$(( $(date +%s) + dur + 60 ))

    # Try transcoding (resize + re-encode)
    _ffmpeg_run "$out" "$dur" "$errfile" "$deadline" \
        ffmpeg \
        -rtsp_transport tcp \
        -i "$rtsp" \
        -t "$dur" \
        -vf "scale=w='min(iw,1280)':h='min(ih,720)':force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p" \
        -r 5 \
        -c:v libx264 -preset medium -crf 26 \
        -maxrate 400k -bufsize 800k \
        -profile:v high -pix_fmt yuv420p \
        -g 5 -keyint_min 5 -sc_threshold 0 \
        -an \
        -movflags +faststart \
        -y "$out"

    # Fallback to codec copy if transcoding produced no output
    if [[ ! -s "$out" ]]; then
        log_warn "Transcode failed for $out — retrying with codec copy"
        deadline=$(( $(date +%s) + dur + 60 ))
        _ffmpeg_run "$out" "$dur" "$errfile" "$deadline" \
            ffmpeg \
            -rtsp_transport tcp \
            -i "$rtsp" \
            -t "$dur" \
            -c:v copy \
            -an \
            -movflags +faststart \
            -y "$out"
    fi
}

# ---- Upload first frame as thumbnail, echo blob URL or empty ----------
_upload_thumb() {
    local seg="$1" blob_key="$2"
    local tmp; tmp=$(mktemp /tmp/visionai_th_XXXXXX.jpg)
    ffmpeg -i "$seg" -frames:v 1 -f image2 -y "$tmp" >/dev/null 2>&1 || true
    if [[ -s "$tmp" ]]; then
        _azure_upload "$tmp" "$blob_key"
        rm -f "$tmp"
    else
        rm -f "$tmp"; echo ""
    fi
}

# ---- Full recording lifecycle (runs as a background subprocess) --------
_run_recording() {
    trap - EXIT INT TERM  # don't inherit parent PID-file cleanup trap

    local rec_id="$1" cam_id="$2" cam_name="$3" dur_sec="$4" rtsp="$5" site_name="${6:-unknown-site}"
    local cam_safe; cam_safe=$(echo "$cam_name" \
        | tr '[:upper:]' '[:lower:]' | tr ' /' '--' | tr -cd 'a-z0-9_-')
    local site_safe; site_safe=$(echo "$site_name" \
        | tr '[:upper:]' '[:lower:]' | tr ' /' '--' | tr -cd 'a-z0-9_-')
    local rec_date; rec_date=$(date '+%Y-%m-%d')
    local rec_ts; rec_ts=$(date '+%H%M%S')
    local start_time; start_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local rec_file="${TMP_DIR}/rec_${rec_id}.mp4"
    local blob_path="${site_safe}/${rec_date}/${cam_safe}-${rec_ts}.mp4"
    local thumb_path="${site_safe}/${rec_date}/${cam_safe}-${rec_ts}_thumb.jpg"

    log "Recording $rec_id: starting (cam=$cam_name, site=$site_name, ${dur_sec}s)"

    local min_dur=$(( dur_sec / 2 ))
    local attempt=0 max_attempts=3 remaining="$dur_sec"

    while (( attempt < max_attempts && remaining > min_dur )); do
        attempt=$(( attempt + 1 ))
        _ffmpeg_record "$rtsp" "$rec_file" "$remaining"

        if [[ ! -s "$rec_file" ]]; then
            local ffmpeg_err
            ffmpeg_err=$(grep -v "^$" "${rec_file}.err" 2>/dev/null | tail -5 | tr '\n' ' ')
            log_error "Recording $rec_id: ffmpeg failed for camera '$cam_name' (${rtsp%%@*}) — ${ffmpeg_err:-no output}"
            _api_update "$rec_id" "" "failed" "$start_time" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$dur_sec" "$cam_id"
            rm -f "$rec_file" "${rec_file}.err" "${ACTIVE_DIR}/${rec_id}"
            return
        fi

        local actual_dur
        actual_dur=$(ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$rec_file" 2>/dev/null | cut -d. -f1)
        actual_dur=${actual_dur:-0}

        if (( actual_dur >= min_dur )); then
            break
        fi

        log_warn "Recording $rec_id: short recording (${actual_dur}s/${remaining}s), attempt $attempt/$max_attempts — retrying"
        remaining=$(( remaining - actual_dur ))
        rm -f "$rec_file" "${rec_file}.err"
        sleep 5
    done

    local sz; sz=$(_file_size "$rec_file")
    log "Recording $rec_id: ffmpeg done (${sz}B), uploading..."

    local url; url=$(_azure_upload "$rec_file" "$blob_path") || url=""
    local thumb; thumb=$(_upload_thumb "$rec_file" "$thumb_path") || thumb=""
    rm -f "$rec_file" "${rec_file}.err"

    local stop_time; stop_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if [[ -n "$url" ]]; then
        _api_update "$rec_id" "$url" "completed" "$start_time" "$stop_time" "$dur_sec" "$cam_id"
        log "Recording $rec_id: completed — $blob_path (${sz}B)"
    else
        _api_update "$rec_id" "" "failed" "$start_time" "$stop_time" "$dur_sec" "$cam_id"
        log_error "Recording $rec_id: upload failed"
    fi

    rm -f "${ACTIVE_DIR}/${rec_id}"
}

# ---- Dispatch a list of recording objects ------------------------------
_dispatch() {
    local json="$1"
    local n; n=$(echo "$json" | jq 'length' 2>/dev/null); n=${n:-0}
    local dispatched=0

    for i in $(seq 0 $(( n - 1 ))); do
        local rec; rec=$(echo "$json" | jq ".[$i]")
        local rec_id cam_id cam_name site_name rtsp dur_sec
        rec_id=$(echo "$rec"    | jq -r '.recording_id       // empty')
        cam_id=$(echo "$rec"    | jq -r '.camera_id          // empty')
        cam_name=$(echo "$rec"  | jq -r '.camera_name        // .camera_id // empty')
        site_name=$(echo "$rec" | jq -r '.site_name          // empty')
        rtsp=$(echo "$rec"      | jq -r '.camera_url         // empty')
        dur_sec=$(echo "$rec"   | jq -r '.recording_duration // 3600')

        if [[ -z "$rec_id" || -z "$rtsp" ]]; then
            log_warn "Skipping invalid entry (missing recording_id or camera_url): $rec"
            continue
        fi

        if [[ -f "${ACTIVE_DIR}/${rec_id}" ]]; then
            log_debug "Recording $rec_id: already active — skip"; continue
        fi

        touch "${ACTIVE_DIR}/${rec_id}"
        log "Recording $rec_id: dispatching (cam=$cam_name, site=$site_name, ${dur_sec}s)"
        _run_recording "$rec_id" "$cam_id" "$cam_name" "$dur_sec" "$rtsp" "$site_name" &
        dispatched=$(( dispatched + 1 ))
    done

    [[ $dispatched -eq 0 && $n -gt 0 ]] && sleep 5 || true
}

# ---- Normalise GET response, then dispatch ----------------------------
_poll() {
    log "Polling for pending recordings..."
    local resp http_code tmp
    tmp=$(mktemp)
    http_code=$(curl -s -o "$tmp" -w "%{http_code}" --max-time 10 \
        -H "Content-Type: application/json" \
        -H "Token: $VISIONAI_API_TOKEN" \
        "${VISIONAI_API_ENDPOINT}/v2/get-recording-status?recording_type=raw")
    resp=$(cat "$tmp"); rm -f "$tmp"

    # 000 = curl couldn't connect at all (bad endpoint, no network, empty var)
    if [[ "$http_code" == "000" ]]; then
        log_error "API unreachable (HTTP 000) — check VISIONAI_API_ENDPOINT and network — retry in ${POLL_INTERVAL}s"
        return
    fi

    # API returns 404 + "No active recordings found" when the queue is empty
    if [[ "$http_code" == "404" ]]; then
        local msg; msg=$(echo "$resp" | jq -r '.message // ""' 2>/dev/null)
        if echo "$msg" | grep -qi "no active recording"; then
            log "No pending recordings"
            return
        fi
        log_error "API error (HTTP 404): ${resp:0:200} — retry in ${POLL_INTERVAL}s"
        return
    fi

    if [[ "$http_code" != "200" ]]; then
        log_error "API error (HTTP $http_code): ${resp:0:200} — retry in ${POLL_INTERVAL}s"
        return
    fi

    # Support: { data:[...] }  { data:{...} }  [...]  {...}
    local recs
    if   echo "$resp" | jq -e '.data | type == "array"'  >/dev/null 2>&1; then
        recs=$(echo "$resp" | jq '.data')
    elif echo "$resp" | jq -e '.data | type == "object"' >/dev/null 2>&1; then
        recs=$(echo "$resp" | jq '[.data]')
    elif echo "$resp" | jq -e 'type == "array"'          >/dev/null 2>&1; then
        recs="$resp"
    elif echo "$resp" | jq -e '.recording_id'            >/dev/null 2>&1; then
        recs=$(echo "$resp" | jq '[.]')
    else
        log_error "Unexpected API response: ${resp:0:200}"; return
    fi

    local n; n=$(echo "$recs" | jq 'length' 2>/dev/null); n=${n:-0}
    [[ "$n" -eq 0 ]] && { log "No pending recordings"; return; }
    log "Found $n pending recording(s)"
    _dispatch "$recs"
}

# ---- Main loop ---------------------------------------------------------
_ensure_raw_recordings_folder
log "Azure container ready (raw-recordings/ folder ensured)"

_poll  # immediate check on startup

while true; do
    sleep "$POLL_INTERVAL"
    _poll
done
