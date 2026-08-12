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
#   sudo rm -f /etc/logrotate.d/visionai-recording-manager
#   sudo systemctl daemon-reload
#   # /var/lib/visionai holds the upload spool — check it is empty before
#   # removing it, or you discard recordings that never reached the cloud:
#   #   ls /var/lib/visionai/rec/spool && sudo rm -rf /var/lib/visionai
#
# ── Daemon env vars (set in ENV_FILE) ────────────────────────────────────────
#   Required: VISIONAI_API_ENDPOINT  VISIONAI_API_TOKEN
#             EVENTS_AZURE_BLOB_CONNECTION_STRING
#   Optional: POLL_INTERVAL (default 300s)
#             UPLOAD_RETRIES (default 3)   UPLOAD_RETRY_DELAY (default 10s)
#             PYTHON_BIN  DEBUG  ENV_FILE  LOG_FILE
#
#   Site scoping — resolved automatically from /v2/token-context (site_uuid,
#   site_name). These optional .env vars override the API values if set:
#             VISIONAI_SITE_UUID  VISIONAI_FIREBASE_PATH  VISIONAI_SITE_NAME
#
#   Firebase push (optional — enables near-instant start/stop instead of waiting
#   for the next poll; falls back to polling when unset or unavailable):
#             FIREBASE_DATABASE_URL  (Realtime DB URL — required to enable push)
#     Service account, either:
#             FIREBASE_SERVICE_ACCOUNT  (path to service-account JSON), or the
#             individual fields used by the backend:
#             FIREBASE_PROJECT_ID  FIREBASE_PRIVATE_KEY_ID  FIREBASE_PRIVATE_KEY
#             FIREBASE_CLIENT_EMAIL  FIREBASE_CLIENT_ID  FIREBASE_CLIENT_X509_CERT_URL

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

    # firebase-admin enables the optional push listener (near-instant start/stop).
    # Non-fatal: if it can't be installed, the daemon just runs in polling-only mode.
    if "$VENV_DIR/bin/python3" -c "import firebase_admin" 2>/dev/null; then
        ok "firebase-admin already installed"
    else
        warn "Installing firebase-admin into venv (optional — enables push start/stop)..."
        if "$VENV_DIR/bin/pip" install --quiet firebase-admin 2>/dev/null \
            && "$VENV_DIR/bin/python3" -c "import firebase_admin" 2>/dev/null; then
            ok "firebase-admin installed"
        else
            warn "firebase-admin install failed — daemon will run in polling-only mode"
        fi
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
# A capture in flight gets time to finalize its mp4 before systemd escalates to
# SIGKILL. The old 20s could cut a stop/restart mid-write, losing the moov atom
# and with it the whole recording.
TimeoutStopSec=90
# Captures and the upload spool live here (creates /var/lib/visionai, 0750).
# NOT under /tmp: systemd clears /tmp at boot, which would delete spooled
# recordings that are waiting out a network outage.
StateDirectory=visionai
StateDirectoryMode=0750
Environment=WORK_DIR=/var/lib/visionai/rec
Environment=ENV_FILE=${ENV_FILE}
Environment=LOG_FILE=${LOG_DIR}/recording-manager.log
Environment=PYTHON_BIN=${VENV_DIR}/bin/python3

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    chmod 644 "$SERVICE_FILE"
    ok "Service file: $SERVICE_FILE"

    # ── Log rotation ──────────────────────────────────────────────────────────
    # The daemon appends to one file forever; on a busy site with DEBUG=1 that
    # is the thing that eventually fills the disk. copytruncate because the
    # daemon holds the fd open via `exec >>` and never reopens it.
    step "Configuring log rotation..."
    cat > /etc/logrotate.d/visionai-recording-manager << 'LOGROTATE_EOF'
/var/log/visionai/recording-manager.log {
    daily
    rotate 14
    maxsize 100M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LOGROTATE_EOF
    chmod 644 /etc/logrotate.d/visionai-recording-manager
    ok "Log rotation: /etc/logrotate.d/visionai-recording-manager (14 days, 100MB cap)"

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
# Captures and the upload spool live on real disk, NOT under /tmp. systemd
# clears /tmp at boot and prunes it on a timer (`D /tmp … 30d`), and on modern
# Ubuntu /tmp is tmpfs — so a spooled recording waiting out a network outage
# would be written to RAM and then deleted by a reboot, which is precisely the
# data it exists to protect. Falls back to the legacy path when the state dir
# cannot be created (non-root run).
LEGACY_TMP_DIR=/tmp/visionai-rec
WORK_DIR=${WORK_DIR:-/var/lib/visionai/rec}
if ! mkdir -p "$WORK_DIR" 2>/dev/null; then
    WORK_DIR=$LEGACY_TMP_DIR
fi
TMP_DIR=$WORK_DIR
ACTIVE_DIR=$TMP_DIR/active
SPOOL_DIR=${SPOOL_DIR:-$TMP_DIR/spool}
PID_FILE=/var/run/visionai-recording-manager.pid
LISTENER_SCRIPT=$TMP_DIR/firebase_listener.py
# Spool ceilings — a permanently broken uplink must not fill the disk.
SPOOL_MAX_AGE_HOURS=${SPOOL_MAX_AGE_HOURS:-72}
SPOOL_MAX_MB=${SPOOL_MAX_MB:-20000}
# Refuse to start a capture when the work disk is this low (MB). A recording
# that runs the disk to zero takes the daemon's logs and spool down with it.
MIN_FREE_MB=${MIN_FREE_MB:-2000}
FIREBASE_RESTART_DELAY=${FIREBASE_RESTART_DELAY:-15}
# A capture counts as complete once it covers this share of the requested
# window. It is deliberately close to 100: the previous rule accepted anything
# past the halfway mark, which silently turned a 30-minute request into a
# 15-minute file that was still reported as a full-length success.
RECORDING_COMPLETE_PCT=${RECORDING_COMPLETE_PCT:-95}
RECORDING_MAX_ATTEMPTS=${RECORDING_MAX_ATTEMPTS:-3}
# Captures are taken in windows of this length and joined at the end, so a
# stream that drops costs one window rather than the whole recording. Longer
# windows mean fewer files; shorter ones bound how much a single failure loses.
SEGMENT_DURATION=${SEGMENT_DURATION:-600}
# Used only when a start payload carries no recognizable duration field.
RECORDING_DEFAULT_SEC=${RECORDING_DEFAULT_SEC:-3600}
# RTSP socket I/O timeout. Without it a stalled read is invisible until the
# capture's deadline, so the recording just ends short; with it ffmpeg fails
# fast and the attempt loop resumes for the part that is missing.
FFMPEG_RW_TIMEOUT_US=${FFMPEG_RW_TIMEOUT_US:-15000000}
# Seconds to let ffmpeg finalize on SIGTERM before escalating to SIGKILL.
FFMPEG_TERM_GRACE=${FFMPEG_TERM_GRACE:-10}
# Azure Blob layout: <container>/<prefix>/<site_uuid>/<camera>-<timestamp>.mp4
AZURE_CONTAINER=${AZURE_CONTAINER:-recordings}
AZURE_BLOB_PREFIX=${AZURE_BLOB_PREFIX:-raw-recordings}
# Resolved at startup from /v2/token-context (the token is opaque to us).
CLIENT_SITE_ID=""
CLIENT_SITE_NAME=""
CLIENT_SITE_UUID=""
CLIENT_FIREBASE_PATH=""   # recording-commands/{site_uuid} — listener scope

mkdir -p "$(dirname "$LOG_FILE")" "$TMP_DIR" "$ACTIVE_DIR" "$SPOOL_DIR"
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

# ---- URL style: permanent CDN link vs time-limited signed link ---------
# Resolved here, after the env file is loaded, because the defaults below are
# derived from whether a CDN host was configured.
#
# A signed URL expires, and that URL is what the backend stores against the
# recording — so an archive built on signed links quietly fills with dead
# playback URLs that nobody notices until someone opens a clip weeks later.
# When a CDN host is configured, hand back a permanent unsigned URL instead.
# That is only safe where the CDN (or a public-read container) is what governs
# access; set CDN_PUBLIC_URLS=0 to keep expiry.
CDN_BASE_URL=${CDN_BASE_URL:-${AZURE_CDN_BASE_URL:-}}
AZURE_CDN_INCLUDE_CONTAINER=${AZURE_CDN_INCLUDE_CONTAINER:-0}
AZURE_SAS_EXPIRY_DAYS=${AZURE_SAS_EXPIRY_DAYS:-7}
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

# ---- Locate a Python 3 with firebase_admin (optional push listener) -----
# Returns a python path with firebase_admin importable, or "" if none.
_find_python_firebase() {
    for _py in "$PYTHON_BIN" \
        /opt/visionai/.venv/bin/python3 \
        /home/visionify/.venv/bin/python3 \
        /home/visionify/visionai/.venv/bin/python3 \
        /usr/local/bin/python3 \
        python3 python; do
        [[ -n "$_py" ]] || continue
        [[ -x "$_py" ]] || command -v "$_py" >/dev/null 2>&1 || continue
        "$_py" -c "import firebase_admin" 2>/dev/null && { echo "$_py"; return; }
    done
    echo ""
}

# Firebase is enabled only when a DB URL is set AND a python with firebase_admin
# exists. Otherwise the daemon runs polling-only (mirrors the backend fallback).
FIREBASE_PYTHON=""
FIREBASE_ENABLED=0
if [[ -n "${FIREBASE_DATABASE_URL:-}" ]]; then
    FIREBASE_PYTHON=$(_find_python_firebase)
    if [[ -n "$FIREBASE_PYTHON" ]]; then
        FIREBASE_ENABLED=1
        log "Firebase push enabled (python=$FIREBASE_PYTHON, db=${FIREBASE_DATABASE_URL})"
    else
        log_warn "FIREBASE_DATABASE_URL set but firebase_admin not importable — polling only. Run: pip3 install firebase-admin"
    fi
else
    log "Firebase disabled (FIREBASE_DATABASE_URL not set) — polling only"
fi

# ---- Singleton ---------------------------------------------------------
if [[ -f "$PID_FILE" ]]; then
    _old=$(cat "$PID_FILE" 2>/dev/null || true)
    if [[ -n "${_old:-}" ]] && kill -0 "$_old" 2>/dev/null; then
        log_error "Already running (PID $_old). Exiting."; exit 1
    fi
fi
echo $$ > "$PID_FILE"
_cleanup() {
    rm -f "$PID_FILE"
    [[ -n "${FIREBASE_LOOP_PID:-}" ]] && kill "$FIREBASE_LOOP_PID" 2>/dev/null || true
    pkill -f "$LISTENER_SCRIPT" 2>/dev/null || true
    log "Stopped (PID $$)"
}
# On a signal, exit promptly (don't resume the poll loop) — that turns the EXIT
# trap into the single cleanup path and lets `systemctl stop/restart` finish in
# ~1s instead of waiting out TimeoutStopSec before SIGKILL.
trap _cleanup EXIT
trap 'exit 0' INT TERM

rm -rf "${ACTIVE_DIR:?}"/* 2>/dev/null || true
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

# NOTE: dedup is local — the atomic `mkdir "$ACTIVE_DIR/<rec_id>"` claim in
# _dispatch_one guarantees a single recording per id within THIS daemon. There
# is no cross-machine claim (update-recording-url never returns 409), so run
# exactly one daemon per site_uuid; two daemons on the same site would each
# record and upload the same recording.

# Resolve the Firebase listener path and labelling from /v2/token-context (the
# token is opaque to us). The backend pushes commands to
# recording-commands/{site_uuid}/{recording_id}; token-context returns site_uuid
# (listener scope), site_name (Azure folder label) and site_id (safety filter).
# .env values may override any of these; without a uuid the listener falls back
# to the unscoped root path and relies on the site_id filter.
_fetch_site_context() {
    local resp
    resp=$(_api_get "${VISIONAI_API_ENDPOINT}/v2/token-context" 10 2>/dev/null) || resp=""
    if [[ -n "$resp" ]]; then
        CLIENT_SITE_ID=$(echo "$resp"   | jq -r '.site_id   // empty' 2>/dev/null)
        CLIENT_SITE_NAME=$(echo "$resp" | jq -r '.site_name // empty' 2>/dev/null)
        CLIENT_SITE_UUID=$(echo "$resp" | jq -r '.site_uuid // empty' 2>/dev/null)
    else
        log_warn "/v2/token-context unavailable — check VISIONAI_API_ENDPOINT/TOKEN"
    fi

    # Optional .env overrides (API is normally the source of truth).
    [[ -n "${VISIONAI_SITE_UUID:-}" ]] && CLIENT_SITE_UUID="$VISIONAI_SITE_UUID"
    [[ -n "${VISIONAI_SITE_NAME:-}" ]] && CLIENT_SITE_NAME="$VISIONAI_SITE_NAME"

    # site_uuid drives both the Firebase listener path and the Azure blob layout.
    [[ -n "$CLIENT_SITE_UUID"           ]] && CLIENT_FIREBASE_PATH="recording-commands/${CLIENT_SITE_UUID}"
    [[ -n "${VISIONAI_FIREBASE_PATH:-}" ]] && CLIENT_FIREBASE_PATH="$VISIONAI_FIREBASE_PATH"

    if [[ -z "$CLIENT_FIREBASE_PATH" ]]; then
        log_warn "No site_uuid resolved — Firebase listener will use the unscoped root path (filtering by site_id)"
    fi
    log "Firebase: path=${CLIENT_FIREBASE_PATH:-<root>} site_uuid=${CLIENT_SITE_UUID:-<none>} site_id=${CLIENT_SITE_ID:-<none>} site_name=${CLIENT_SITE_NAME:-<none>}"
}

# ---- Create the recordings container if it doesn't exist ---------------
# Echoes the container's public access level ("blob", "container", or
# "private"), which decides whether permanent CDN URLs can resolve at all.
_ensure_container() {
    "$PYTHON_BIN" - "$EVENTS_AZURE_BLOB_CONNECTION_STRING" "$AZURE_CONTAINER" 2>/dev/null <<'PYEOF' || true
import sys
from azure.storage.blob import BlobServiceClient
conn_str, container = sys.argv[1:3]
client = BlobServiceClient.from_connection_string(conn_str)
container_client = client.get_container_client(container)
try:
    props = container_client.get_container_properties()
except Exception:
    # Created private: making a container world-readable is not a decision this
    # daemon should take on its own. Permanent CDN URLs then need either an
    # operator to set public access, or a CDN that authenticates to the origin.
    container_client.create_container()
    print("created:private")
else:
    print(f"exists:{props.public_access or 'private'}")
PYEOF
}

# ---- Upload file to Azure Blob Storage, return playable URL or empty ---
# Returns a permanent CDN URL when CDN_PUBLIC_URLS=1, otherwise a SAS URL that
# expires after AZURE_SAS_EXPIRY_DAYS.
_azure_upload() {
    local file="$1" blob_name="$2"
    local attempt=1

    while [[ $attempt -le $UPLOAD_RETRIES ]]; do
        local result
        result=$("$PYTHON_BIN" - "$file" "$AZURE_CONTAINER" \
                "$blob_name" "$EVENTS_AZURE_BLOB_CONNECTION_STRING" \
                "${CDN_BASE_URL:-}" "$AZURE_CDN_INCLUDE_CONTAINER" \
                "$AZURE_SAS_EXPIRY_DAYS" "$CDN_PUBLIC_URLS" 2>&1 <<'PYEOF'
import sys
from azure.storage.blob import (BlobServiceClient, generate_blob_sas,
                                BlobSasPermissions, ContentSettings)
from datetime import datetime, timedelta, timezone
(file_path, container, blob_name, conn_str,
 cdn_base_url, cdn_include_container, sas_expiry_days, public_urls) = sys.argv[1:]
try:
    client = BlobServiceClient.from_connection_string(conn_str)
    blob_client = client.get_blob_client(container=container, blob=blob_name)

    # Without an explicit content type Azure stores every blob as
    # application/octet-stream, and a browser then DOWNLOADS the recording
    # instead of playing it — <video> and <img> both fail on the returned URL.
    # `inline` keeps the browser from treating it as an attachment.
    import mimetypes as _mt
    guessed = _mt.guess_type(file_path)[0]
    if file_path.endswith(".mp4"):
        guessed = "video/mp4"
    content_settings = ContentSettings(
        content_type=guessed or "application/octet-stream",
        content_disposition="inline",
    )
    with open(file_path, "rb") as f:
        blob_client.upload_blob(f, overwrite=True, content_settings=content_settings)

    def _cdn_url(suffix=""):
        host = cdn_base_url.split("://", 1)[-1].rstrip("/")
        path = f"{container}/{blob_name}" if cdn_include_container == "1" else blob_name
        return f"https://{host}/{path}{suffix}"

    # A permanent CDN URL carries no SAS token, so it never expires — which is
    # the point, but it also means the object is reachable by anyone holding the
    # link. That is only safe when the CDN/Front Door origin is what enforces
    # access; the blob container itself must not be left publicly enumerable.
    if public_urls == "1" and cdn_base_url:
        print(_cdn_url())
    else:
        sas_token = generate_blob_sas(
            account_name=client.account_name,
            container_name=container,
            blob_name=blob_name,
            account_key=client.credential.account_key,
            permission=BlobSasPermissions(read=True),
            expiry=datetime.now(timezone.utc) + timedelta(days=int(sas_expiry_days)),
        )
        print(_cdn_url(f"?{sas_token}") if cdn_base_url
              else f"{blob_client.url}?{sas_token}")
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

# ---- Upload spool: keep the bytes when the network refuses them --------
#
# An upload that exhausts its retries used to end with `rm -f "$rec_file"`,
# which turns a transient uplink problem into permanent data loss: the camera
# footage is gone and the recording is marked failed. Instead, park the file
# with a sidecar describing where it was headed, and retry on later polls.
_spool_put() {
    local file="$1" rec_id="$2" cam_id="$3" blob_path="$4" thumb_path="$5" \
          start_time="$6" stop_time="$7" duration="$8"
    local base="${SPOOL_DIR}/${rec_id}"

    mkdir -p "$SPOOL_DIR" 2>/dev/null || return 1
    mv -f "$file" "${base}.mp4" 2>/dev/null || return 1
    jq -n --arg rid "$rec_id" --arg cid "$cam_id" --arg bp "$blob_path" \
          --arg tp "$thumb_path" --arg st "$start_time" --arg et "$stop_time" \
          --argjson dur "$duration" \
        '{recording_id:$rid,camera_id:$cid,blob_path:$bp,thumb_path:$tp,
          start_time:$st,stop_time:$et,duration:$dur}' > "${base}.json" 2>/dev/null \
        || { rm -f "${base}.mp4"; return 1; }
    log_warn "Recording $rec_id: upload failed — spooled $(_file_size "${base}.mp4")B for retry"
    return 0
}

# Enforce the spool ceilings, oldest first: a stale clip is worth less than a
# working disk, and an unbounded spool is its own outage.
_spool_prune() {
    local now; now=$(date +%s)
    local max_age=$(( SPOOL_MAX_AGE_HOURS * 3600 ))
    local f mtime

    for f in "$SPOOL_DIR"/*.mp4; do
        [[ -f "$f" ]] || continue
        mtime=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
        if (( now - mtime > max_age )); then
            log_warn "Spool: dropping $(basename "$f") — older than ${SPOOL_MAX_AGE_HOURS}h"
            rm -f "$f" "${f%.mp4}.json"
        fi
    done

    local used_mb
    used_mb=$(du -sm "$SPOOL_DIR" 2>/dev/null | cut -f1); used_mb=${used_mb:-0}
    (( used_mb <= SPOOL_MAX_MB )) && return 0
    while read -r f; do
        [[ -f "$f" ]] || continue
        (( used_mb <= SPOOL_MAX_MB )) && break
        local mb; mb=$(( $(_file_size "$f") / 1048576 ))
        log_warn "Spool: over ${SPOOL_MAX_MB}MB — dropping oldest $(basename "$f")"
        rm -f "$f" "${f%.mp4}.json"
        used_mb=$(( used_mb - mb ))
    done < <(ls -1tr "$SPOOL_DIR"/*.mp4 2>/dev/null)
}

# Retry spooled uploads. Called from the poll loop, so a recording that could
# not be shipped when it finished still lands once the network comes back.
_spool_drain() {
    _spool_prune
    local f meta rec_id cam_id blob_path thumb_path start_time stop_time duration url thumb

    for f in "$SPOOL_DIR"/*.mp4; do
        [[ -f "$f" ]] || continue
        meta="${f%.mp4}.json"
        if [[ ! -f "$meta" ]]; then
            log_warn "Spool: $(basename "$f") has no sidecar — dropping"
            rm -f "$f"; continue
        fi
        rec_id=$(jq -r '.recording_id // empty' "$meta" 2>/dev/null)
        cam_id=$(jq -r '.camera_id    // empty' "$meta" 2>/dev/null)
        blob_path=$(jq -r '.blob_path // empty' "$meta" 2>/dev/null)
        thumb_path=$(jq -r '.thumb_path // empty' "$meta" 2>/dev/null)
        start_time=$(jq -r '.start_time // empty' "$meta" 2>/dev/null)
        stop_time=$(jq -r '.stop_time  // empty' "$meta" 2>/dev/null)
        duration=$(jq -r '.duration    // 0' "$meta" 2>/dev/null)
        [[ -z "$rec_id" || -z "$blob_path" ]] && { log_warn "Spool: unusable sidecar $(basename "$meta") — dropping"; rm -f "$f" "$meta"; continue; }

        log "Spool: retrying upload for recording $rec_id"
        url=$(_azure_upload "$f" "$blob_path") || url=""
        [[ -z "$url" ]] && { log_warn "Spool: recording $rec_id still not uploadable — leaving spooled"; continue; }

        thumb=""
        [[ -n "$thumb_path" ]] && { thumb=$(_upload_thumb "$f" "$thumb_path") || thumb=""; }
        _api_update "$rec_id" "$url" "completed" "$start_time" "$stop_time" "$duration" "$cam_id"
        log "Recording $rec_id: completed from spool — $blob_path"
        rm -f "$f" "$meta"
    done
}

# ---- Reap ffmpeg left behind by a previous daemon generation -----------
# systemd restarts the manager, but ffmpeg it had spawned keeps running and
# keeps its RTSP session open. Those sessions compete with the inference engine
# for single-consumer cameras, so clear them before starting new captures.
#
# Liveness is decided by the claim directory, not by a time limit: a capture
# whose recording_id still holds a claim is this generation's and is left alone
# no matter how long it has been running, so a legitimately long recording is
# never cut short. $1 is a minimum age in seconds, which only guards against
# racing a capture that has started but not yet had its claim observed.
_reap_stale_ffmpeg() {
    local min_age="${1:-300}"
    local pid age args rid
    while read -r pid age; do
        [[ -z "$pid" ]] && continue
        kill -0 "$pid" 2>/dev/null || continue
        args=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
        # Matches both the current segment names (rec_<id>_sNNN.mp4) and the
        # part names an older build used (rec_<id>_pNN.mp4), so a rolling
        # update does not walk past captures started by the previous version.
        rid=$(sed -nE 's|.*/rec_([^/[:space:]]+)_[sp][0-9]+\.mp4.*|\1|p' <<<"$args")
        if [[ -n "$rid" && -d "${ACTIVE_DIR}/${rid}" ]]; then
            log_debug "ffmpeg pid=$pid belongs to active recording $rid — leaving it"
            continue
        fi
        if [[ -z "$rid" ]]; then
            # Not a capture: the concat join or a thumbnail pass, neither of
            # which carries a recording id. Both finish in seconds, so only
            # reap one that has clearly wedged rather than racing a live one.
            (( age < 3600 )) && continue
        fi
        log_error "Reaping orphaned ffmpeg pid=$pid (age $(( age / 60 ))m, recording ${rid:-unknown}) — it was holding an RTSP session"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    # Match the legacy /tmp work dir too: processes started by an older build
    # are still writing there, and matching only WORK_DIR walks past them.
    done < <(ps -eo pid=,etimes=,args= 2>/dev/null \
             | awk -v age="$min_age" -v dir="$WORK_DIR" -v legacy="$LEGACY_TMP_DIR" '
                 index($0, "ffmpeg") && (index($0, dir) || index($0, legacy)) \
                 && !index($0, "awk") && $2 >= age { print $1, $2 }')
}

# ---- Free space on the work disk, in MB --------------------------------
_free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# ---- Verify permanent CDN URLs actually resolve ------------------------
# Whether the container name belongs in the CDN path is deployment-specific,
# and because the URL is written into the backend against the recording, a
# wrong guess silently fills the archive with dead links that nobody notices
# until someone tries to play a clip weeks later.
#
# So don't guess: upload a few bytes once at startup, try each path shape, and
# keep the one that returns 200. If none does, fall back to signed URLs, which
# expire but at least work.
_probe_public_url() {
    [[ "$CDN_PUBLIC_URLS" == "1" ]] || return 0

    local probe="${TMP_DIR}/.cdn-probe"
    local key="${AZURE_BLOB_PREFIX}/.cdn-probe.txt"
    echo "visionai recording-manager cdn probe" > "$probe" 2>/dev/null || return 0

    # Upload once — we only need the object to exist; the URL style used to put
    # it there is irrelevant to what we are testing.
    local saved="$CDN_PUBLIC_URLS"
    CDN_PUBLIC_URLS=0
    _azure_upload "$probe" "$key" >/dev/null 2>&1
    CDN_PUBLIC_URLS="$saved"
    rm -f "$probe"

    local host; host=$(echo "$CDN_BASE_URL" | sed -E 's|^[a-z]+://||; s|/$||')
    local shape code=""
    for shape in "$AZURE_CDN_INCLUDE_CONTAINER" 1 0; do
        if [[ "$shape" == "1" ]]; then
            code=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 20 "https://${host}/${AZURE_CONTAINER}/${key}" 2>/dev/null)
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

    log_error "CDN probe failed (last HTTP ${code:-none}) — permanent URLs would not resolve, falling back to signed URLs"
    CDN_PUBLIC_URLS=0
}

# ---- RTSP socket timeout flag (name varies by ffmpeg version) ----------
# ffmpeg <5 spells the RTSP demuxer's socket timeout `-stimeout`; 5.0 dropped
# that name and moved it to `-timeout` (both in microseconds). Probe for the
# one this build understands — passing the wrong flag makes ffmpeg exit
# immediately, which is how the flags came to be dropped altogether. Check
# `stimeout` first: on ffmpeg 4.x `-timeout` also exists but means the listen
# timeout in *seconds*, so matching it there would buy no read protection.
FFMPEG_RTSP_TIMEOUT_ARGS=()
_detect_rtsp_timeout_flag() {
    local help; help=$(ffmpeg -hide_banner -h demuxer=rtsp 2>/dev/null)
    if grep -qE '^[[:space:]]+-stimeout[[:space:]]' <<<"$help"; then
        FFMPEG_RTSP_TIMEOUT_ARGS=(-stimeout "$FFMPEG_RW_TIMEOUT_US")
    elif grep -qE '^[[:space:]]+-timeout[[:space:]]' <<<"$help"; then
        FFMPEG_RTSP_TIMEOUT_ARGS=(-timeout "$FFMPEG_RW_TIMEOUT_US")
    else
        log_warn "ffmpeg has no RTSP socket timeout option — a stalled stream will only be caught by the capture deadline"
    fi
}

# ---- Stop an ffmpeg child, escalating if it ignores SIGTERM ------------
# SIGTERM first so ffmpeg finalizes the moov atom (+faststart leaves a playable
# partial). An ffmpeg blocked in a stalled RTSP read ignores TERM, and the old
# code then fell into an unbounded `wait` — that is how captures survived for
# days holding a camera's RTSP session against the inference engine. Never wait
# forever on a process we have already decided to kill.
_stop_ffmpeg() {
    local pid="$1" out="$2"
    kill -TERM "$pid" 2>/dev/null || true
    local waited=0
    while kill -0 "$pid" 2>/dev/null && (( waited < FFMPEG_TERM_GRACE )); do
        sleep 1; waited=$(( waited + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
        log_error "ffmpeg ignored SIGTERM for $out — SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
        sleep 1
    fi
}

# ---- ffmpeg capture with deadline watchdog; stderr saved to <out>.err ----
# A non-empty $stopflag path that appears mid-capture triggers a graceful stop
# (SIGTERM) so an in-progress recording can be ended early on command. ffmpeg
# finalizes the moov atom on SIGTERM (+faststart), yielding a playable partial.
_ffmpeg_run() {
    local out="$1" dur="$2" errfile="$3" deadline="$4" stopflag="${5:-}"
    shift 5

    "$@" >/dev/null 2>"$errfile" &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        sleep 2
        if [[ -n "$stopflag" && -f "$stopflag" ]]; then
            log "ffmpeg stop requested for $out — ending early"
            _stop_ffmpeg "$pid" "$out"
            break
        fi
        if [[ $(date +%s) -gt $deadline ]]; then
            log_warn "ffmpeg deadline exceeded for $out — terminating"
            _stop_ffmpeg "$pid" "$out"
            break
        fi
    done
    wait "$pid" 2>/dev/null || true
}

_ffmpeg_record() {
    local rtsp="$1" out="$2" dur="$3" stopflag="${4:-}"
    local errfile="${out}.err"
    local deadline=$(( $(date +%s) + dur + 60 ))

    # Try transcoding (resize + re-encode). `-t` bounds *stream* time, not wall
    # time: an encoder that cannot sustain the input rate falls behind and gets
    # cut off by the deadline with only part of the window captured, so the
    # preset has to leave headroom on modest hardware.
    _ffmpeg_run "$out" "$dur" "$errfile" "$deadline" "$stopflag" \
        ffmpeg \
        -rtsp_transport tcp \
        ${FFMPEG_RTSP_TIMEOUT_ARGS[@]+"${FFMPEG_RTSP_TIMEOUT_ARGS[@]}"} \
        -i "$rtsp" \
        -t "$dur" \
        -vf "scale=w='min(iw,1280)':h='min(ih,720)':force_original_aspect_ratio=decrease:force_divisible_by=2,format=yuv420p" \
        -r 5 \
        -c:v libx264 -preset veryfast -crf 26 \
        -maxrate 400k -bufsize 800k \
        -profile:v high -pix_fmt yuv420p \
        -g 5 -keyint_min 5 -sc_threshold 0 \
        -an \
        -movflags +faststart \
        -y "$out"

    # Fallback to codec copy if transcoding produced no output. Skip when an
    # early stop was requested — empty output there means a near-immediate stop,
    # not a transcode failure, and a copy retry would just block on the dead RTSP.
    if [[ ! -s "$out" && ! ( -n "$stopflag" && -f "$stopflag" ) ]]; then
        log_warn "Transcode failed for $out — retrying with codec copy"
        deadline=$(( $(date +%s) + dur + 60 ))
        _ffmpeg_run "$out" "$dur" "$errfile" "$deadline" "$stopflag" \
            ffmpeg \
            -rtsp_transport tcp \
            ${FFMPEG_RTSP_TIMEOUT_ARGS[@]+"${FFMPEG_RTSP_TIMEOUT_ARGS[@]}"} \
            -i "$rtsp" \
            -t "$dur" \
            -c:v copy \
            -an \
            -movflags +faststart \
            -y "$out"
    fi
}

# ---- Whole-second duration of a media file, 0 when unreadable ---------
# Always echoes an integer: the value is passed to the API as a JSON number,
# and ffprobe answers "N/A" for a file whose moov atom never got written.
_probe_duration() {
    local d; d=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | cut -d. -f1)
    [[ "$d" =~ ^[0-9]+$ ]] || d=0
    echo "$d"
}

# ---- Join capture parts into one mp4 ----------------------------------
# Every part comes from the same camera through the same encoder settings, so a
# stream copy through the concat demuxer is safe and near-instant. Returns
# non-zero if the join fails, leaving the caller to fall back to a single part.
_concat_parts() {
    local out="$1"; shift
    local list="${out%.mp4}.parts.txt" p rc
    : > "$list" || return 1
    for p in "$@"; do
        # Single-quoted paths in the concat list; ' is not in the sanitized set
        # these names are built from, but escape it rather than assume.
        printf "file '%s'\n" "${p//\'/\'\\\'\'}" >> "$list"
    done
    ffmpeg -f concat -safe 0 -i "$list" -c copy -movflags +faststart -y "$out" \
        >/dev/null 2>"${out}.err"
    rc=$?
    rm -f "$list"
    [[ $rc -eq 0 && -s "$out" ]]
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
    local rec_stamp; rec_stamp=$(date '+%Y%m%d-%H%M%S')
    local start_time; start_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local rec_file="${TMP_DIR}/rec_${rec_id}.mp4"
    # Blob layout: <prefix>/<site_uuid>/<camera>-<timestamp>.{mp4,jpg} inside the
    # $AZURE_CONTAINER container. Falls back to the sanitized site name if the
    # uuid couldn't be resolved from token-context.
    local site_seg="${CLIENT_SITE_UUID:-${site_safe:-unknown-site}}"
    local blob_path="${AZURE_BLOB_PREFIX}/${site_seg}/${cam_safe}-${rec_stamp}.mp4"
    local thumb_path="${AZURE_BLOB_PREFIX}/${site_seg}/${cam_safe}-${rec_stamp}_thumb.jpg"
    local stopflag="${ACTIVE_DIR}/${rec_id}.stop"

    log "Recording $rec_id: starting (cam=$cam_name, site=$site_name, ${dur_sec}s)"

    # Capture in segments rather than one long ffmpeg run. A dropped RTSP
    # session, a stalled camera or an encoder that falls behind then costs one
    # segment instead of the whole recording, and the deadline watchdog notices
    # a wedged capture within SEGMENT_DURATION+60 instead of the full duration.
    # Each pass records the next window, or re-records whatever the last one
    # left missing; the pieces are joined into a single file at the end, because
    # this API takes one URL per recording.
    local min_dur=$(( dur_sec * RECORDING_COMPLETE_PCT / 100 ))
    local captured=0 seg_idx=0 short_runs=0 last_err=""
    local -a parts=()

    log "Recording $rec_id: capturing ${dur_sec}s in segments of up to ${SEGMENT_DURATION}s"

    while (( captured < dur_sec )); do
        # This pass covers the next segment, or the tail if less than one
        # segment is left. After a short segment it covers the gap instead.
        local want=$(( dur_sec - captured ))
        (( want > SEGMENT_DURATION )) && want=$SEGMENT_DURATION

        local part; part=$(printf '%s/rec_%s_s%03d.mp4' "$TMP_DIR" "$rec_id" "$seg_idx")
        _ffmpeg_record "$rtsp" "$part" "$want" "$stopflag"

        local got=0
        if [[ -s "$part" ]]; then
            got=$(_probe_duration "$part")
            parts+=("$part")
            seg_idx=$(( seg_idx + 1 ))
            captured=$(( captured + got ))
        else
            last_err=$(grep -v "^$" "${part}.err" 2>/dev/null | tail -5 | tr '\n' ' ')
            rm -f "$part" "${part}.err"
        fi

        # An explicit early-stop ends the recording now — keep what was captured
        # and skip the resume logic below.
        if [[ -f "$stopflag" ]]; then
            log "Recording $rec_id: stopped on command — finalizing"
            break
        fi

        (( captured >= dur_sec )) && break

        # A segment that came back short means the stream faltered. The budget
        # counts *consecutive* short segments, so a dead camera stops the loop
        # while a long recording survives blips scattered through it — each
        # healthy segment advances the capture, so this still terminates.
        if (( got < want * RECORDING_COMPLETE_PCT / 100 )); then
            short_runs=$(( short_runs + 1 ))
            if (( short_runs >= RECORDING_MAX_ATTEMPTS )); then
                if (( ${#parts[@]} == 0 )); then
                    log_error "Recording $rec_id: ffmpeg produced nothing for camera '$cam_name' (${rtsp%%@*}) in $short_runs attempts — ${last_err:-no output}"
                else
                    log_warn "Recording $rec_id: giving up after $short_runs short segments — captured ${captured}s of ${dur_sec}s"
                fi
                break
            fi
            log_warn "Recording $rec_id: segment came back ${got}s of ${want}s (${short_runs}/${RECORDING_MAX_ATTEMPTS} consecutive short) — captured ${captured}s of ${dur_sec}s, resuming"
            sleep 5
        else
            short_runs=0
            log_debug "Recording $rec_id: segment $seg_idx done (${got}s) — ${captured}s of ${dur_sec}s"
        fi
    done

    # Nothing at all was captured across every attempt — report failed and bail.
    if (( ${#parts[@]} == 0 )); then
        log_error "Recording $rec_id: no video captured for camera '$cam_name' (${rtsp%%@*}) — ${last_err:-no output}"
        _api_update "$rec_id" "" "failed" "$start_time" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "0" "$cam_id"
        rm -rf "${ACTIVE_DIR:?}/${rec_id}" "${stopflag}"
        return
    fi

    if (( ${#parts[@]} == 1 )); then
        mv -f "${parts[0]}" "$rec_file"
    else
        log "Recording $rec_id: joining ${#parts[@]} segments (${captured}s total)"
        if ! _concat_parts "$rec_file" "${parts[@]}"; then
            # Joining failed: ship the longest segment rather than nothing.
            local best="${parts[0]}" best_dur=0 p p_dur
            for p in "${parts[@]}"; do
                p_dur=$(_probe_duration "$p")
                (( p_dur > best_dur )) && { best="$p"; best_dur=$p_dur; }
            done
            log_warn "Recording $rec_id: could not join ${#parts[@]} segments — uploading the longest (${best_dur}s)"
            mv -f "$best" "$rec_file"
        fi
    fi
    rm -f "${parts[@]}" "${parts[@]/%/.err}"

    local sz; sz=$(_file_size "$rec_file")

    # An early stop before any frames were captured leaves an empty file —
    # nothing to upload.
    if [[ ! -s "$rec_file" ]]; then
        log_warn "Recording $rec_id: stopped with no captured video — nothing to upload"
        _api_update "$rec_id" "" "failed" "$start_time" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "0" "$cam_id"
        rm -f "$rec_file" "${rec_file}.err"; rm -rf "${ACTIVE_DIR:?}/${rec_id}" "${stopflag}"
        return
    fi

    # Always report the length of the file we are actually shipping. Reporting
    # the requested duration is what let a truncated capture reach the dashboard
    # as a full-length recording, hiding the truncation from everyone.
    local report_dur; report_dur=$(_probe_duration "$rec_file")

    log "Recording $rec_id: ffmpeg done (${report_dur}s of ${dur_sec}s, ${sz}B), uploading..."

    if [[ ! -f "$stopflag" ]] && (( report_dur < min_dur )); then
        log_warn "Recording $rec_id: SHORT — captured ${report_dur}s of the requested ${dur_sec}s across ${#parts[@]} segment(s); uploading what there is"
    fi

    local stop_time; stop_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local url; url=$(_azure_upload "$rec_file" "$blob_path") || url=""

    # Upload failed after every retry. Keep the footage and try again on a later
    # poll rather than deleting it — the bytes are unrecoverable once dropped,
    # and the usual cause (a bad uplink) fixes itself.
    if [[ -z "$url" ]]; then
        rm -f "${rec_file}.err"
        if _spool_put "$rec_file" "$rec_id" "$cam_id" "$blob_path" "$thumb_path" \
                      "$start_time" "$stop_time" "$report_dur"; then
            rm -rf "${ACTIVE_DIR:?}/${rec_id}" "${stopflag}"
            return
        fi
        log_error "Recording $rec_id: upload failed and could not be spooled — recording lost"
        _api_update "$rec_id" "" "failed" "$start_time" "$stop_time" "$report_dur" "$cam_id"
        rm -f "$rec_file"; rm -rf "${ACTIVE_DIR:?}/${rec_id}" "${stopflag}"
        return
    fi

    local thumb; thumb=$(_upload_thumb "$rec_file" "$thumb_path") || thumb=""
    rm -f "$rec_file" "${rec_file}.err"

    _api_update "$rec_id" "$url" "completed" "$start_time" "$stop_time" "$report_dur" "$cam_id"
    log "Recording $rec_id: completed — $blob_path (${sz}B)"

    rm -rf "${ACTIVE_DIR:?}/${rec_id}" "${stopflag}"
}

# ---- Resolve a start payload's duration, in seconds --------------------
# The field has carried three spellings: `duration_seconds` (Firebase push) and
# `recording_duration` (poll) are seconds, while the macOS client's endpoint
# sends `duration_minutes`. Read all three rather than letting a renamed field
# fall through to the hour-long default, which silently turns every recording
# into a 60-minute one. Echoes seconds on stdout; logs go to stderr.
_duration_sec() {
    local json="$1" rec_id="${2:-?}" field v

    for field in duration_seconds recording_duration; do
        v=$(echo "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null)
        v="${v%%.*}"   # tolerate 1800.0
        if [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )); then
            # Every dashboard preset is minutes; a "seconds" value below 60 is
            # almost certainly minutes that were never converted. Honour it as
            # sent — but say so, because the recording will be seconds long.
            (( v < 60 )) && log_warn "Recording $rec_id: ${field}=${v} is under a minute — if the dashboard asked for ${v} minutes, the sender is not converting to seconds"
            echo "$v"; return
        fi
    done

    v=$(echo "$json" | jq -r '.duration_minutes // empty' 2>/dev/null)
    v="${v%%.*}"
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 )); then
        log "Recording $rec_id: duration taken from duration_minutes=${v} ($(( v * 60 ))s)"
        echo $(( v * 60 )); return
    fi

    log_warn "Recording $rec_id: no usable duration field in payload (looked for duration_seconds, recording_duration, duration_minutes) — defaulting to ${RECORDING_DEFAULT_SEC}s"
    echo "$RECORDING_DEFAULT_SEC"
}

# ---- Dispatch a single recording; atomic claim avoids double-start -----
# Used by both the poll loop and the Firebase consumer (which run concurrently).
# `mkdir` is the claim: it succeeds for exactly one caller per recording_id.
# Returns 0 if dispatched, 1 if skipped (invalid, already active, or no disk).
_dispatch_one() {
    local rec_id="$1" cam_id="$2" cam_name="$3" dur_sec="$4" rtsp="$5" site_name="${6:-}"

    if [[ -z "$rec_id" || -z "$rtsp" ]]; then
        log_warn "Skipping invalid recording (missing recording_id or camera_url): id='$rec_id'"
        return 1
    fi

    # Starting a capture with no room to write it fills the disk and takes the
    # logs and the spool down with it. Refuse early and say so.
    local free_mb; free_mb=$(_free_mb "$TMP_DIR"); free_mb=${free_mb:-0}
    if (( free_mb < MIN_FREE_MB )); then
        log_error "Recording $rec_id: only ${free_mb}MB free on $TMP_DIR (need ${MIN_FREE_MB}MB) — refusing to start"
        _api_update "$rec_id" "" "failed" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "0" "$cam_id"
        return 1
    fi

    if ! mkdir "${ACTIVE_DIR}/${rec_id}" 2>/dev/null; then
        log_debug "Recording $rec_id: already active — skip"
        return 1
    fi

    log "Recording $rec_id: dispatching (cam=$cam_name, site=$site_name, ${dur_sec}s)"
    _run_recording "$rec_id" "$cam_id" "$cam_name" "$dur_sec" "$rtsp" "$site_name" &
    return 0
}

# ---- Dispatch a list of recording objects (poll path) ------------------
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
        dur_sec=$(_duration_sec "$rec" "${rec_id:-?}")

        _dispatch_one "$rec_id" "$cam_id" "$cam_name" "$dur_sec" "$rtsp" "$site_name" \
            && dispatched=$(( dispatched + 1 ))
    done

    [[ $dispatched -eq 0 && $n -gt 0 ]] && sleep 5 || true
}

# ---- Conservative polling-based stop detection (fallback only) ---------
# When Firebase push is unavailable, a recording that disappears from the
# server's active list is taken as a stop. Two-poll hysteresis + a startup
# grace period guard against the brief window where a just-claimed recording
# isn't yet reported active (the in_progress claim clears the camera flag).
# $1 = newline-separated recording_ids the server currently reports active.
_poll_stop_check() {
    [[ "$FIREBASE_ENABLED" == "1" ]] && return 0   # push path owns stop
    local active_ids="$1"
    local now; now=$(date +%s)
    local missdir="${TMP_DIR}/pollmiss"; mkdir -p "$missdir"
    local d rid started misses
    for d in "${ACTIVE_DIR}"/*/; do
        [[ -d "$d" ]] || continue
        rid=$(basename "$d")
        if printf '%s\n' "$active_ids" | grep -qxF "$rid"; then
            rm -f "${missdir}/${rid}"; continue
        fi
        started=$(stat -c %Y "$d" 2>/dev/null || echo "$now")
        (( now - started < 60 )) && continue   # too new — don't race the claim
        misses=$(cat "${missdir}/${rid}" 2>/dev/null || echo 0)
        misses=$(( misses + 1 ))
        echo "$misses" > "${missdir}/${rid}"
        if (( misses >= 2 )); then
            log "Recording $rid: absent from server for 2 polls — stopping early"
            touch "${ACTIVE_DIR}/${rid}.stop"
            rm -f "${missdir}/${rid}"
        fi
    done
}

# ---- Firebase listener: write the embedded Python helper to disk -------
# Kept inline (like the Azure upload snippets) so the daemon stays a single
# installable file. Reads service-account creds + DB URL from the environment
# and streams recording start/stop commands as one JSON object per stdout line.
_write_listener_script() {
    cat > "$LISTENER_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
"""Stream VisionAI recording start/stop commands from Firebase RTDB.

Connects to recording-commands/{site_uuid}/{recording_id} and prints each command
as a single compact JSON line to stdout. The initial snapshot (commands still
in-flight — the backend deletes each one when its recording completes) is recorded
but NOT emitted, so a listener reconnect never re-triggers an in-progress or stale
command; anything genuinely active is recovered by polling. Exits non-zero on
fatal error so the bash supervisor restarts it.
"""
import json
import os
import sys
import time

try:
    import firebase_admin
    from firebase_admin import credentials, db
except Exception as e:  # pragma: no cover
    print(f"firebase_admin import failed: {e}", file=sys.stderr)
    sys.exit(2)

DB_URL = os.environ.get("FIREBASE_DATABASE_URL")
if not DB_URL:
    print("FIREBASE_DATABASE_URL not set", file=sys.stderr)
    sys.exit(2)


def _load_credentials():
    sa_path = os.environ.get("FIREBASE_SERVICE_ACCOUNT")
    if sa_path and os.path.isfile(sa_path):
        return credentials.Certificate(sa_path)
    sa = {
        "type": "service_account",
        "project_id": os.environ.get("FIREBASE_PROJECT_ID"),
        "private_key_id": os.environ.get("FIREBASE_PRIVATE_KEY_ID"),
        "private_key": (os.environ.get("FIREBASE_PRIVATE_KEY") or "").replace("\\n", "\n"),
        "client_email": os.environ.get("FIREBASE_CLIENT_EMAIL"),
        "client_id": os.environ.get("FIREBASE_CLIENT_ID"),
        "auth_uri": "https://accounts.google.com/o/oauth2/auth",
        "token_uri": "https://oauth2.googleapis.com/token",
        "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
        "client_x509_cert_url": os.environ.get("FIREBASE_CLIENT_X509_CERT_URL"),
    }
    if not (sa["project_id"] and sa["private_key"] and sa["client_email"]):
        print("Firebase service account env vars incomplete", file=sys.stderr)
        sys.exit(2)
    return credentials.Certificate(sa)


def _collect(data):
    """Yield dicts that look like recording commands (have an 'action')."""
    if isinstance(data, dict):
        if "action" in data and "recording_id" in data:
            yield data
        else:
            for v in data.values():
                yield from _collect(v)
    elif isinstance(data, list):
        # RTDB returns a list when keys are sequential integers.
        for v in data:
            if v is not None:
                yield from _collect(v)


_seen = {}      # recording_id -> last seen timestamp
_primed = {"v": False}


def _emit(c):
    out = {
        "action": c.get("action"),
        "recording_id": c.get("recording_id"),
        "camera_id": c.get("camera_id"),
        "camera_name": c.get("camera_name"),
        "camera_url": c.get("camera_url"),
        "recording_type": c.get("recording_type"),
        "duration_seconds": c.get("duration_seconds"),
        "site_id": c.get("site_id"),
    }
    print(json.dumps(out), flush=True)


def _handle(event):
    try:
        for c in _collect(event.data):
            rid = str(c.get("recording_id"))
            ts = c.get("timestamp", "")
            if _seen.get(rid) == ts:
                continue                 # already processed this exact command
            _seen[rid] = ts
            if _primed["v"]:
                _emit(c)                 # live change — act on it
            # else: part of the initial snapshot — record only
    except Exception as e:
        print(f"handler error: {e}", file=sys.stderr)
    finally:
        # The first delivered event is the initial snapshot; everything after
        # it is a live change.
        _primed["v"] = True


def main():
    try:
        cred = _load_credentials()
        firebase_admin.initialize_app(cred, {"databaseURL": DB_URL})
        # Scope to this client's site path when known, so we never see other
        # sites' commands; fall back to the whole tree if it's unknown.
        ref_path = os.environ.get("FIREBASE_PATH") or "recording-commands"
        db.reference(ref_path).listen(_handle)
        print(f"listener connected ({ref_path})", file=sys.stderr)
    except Exception as e:
        print(f"listener init failed: {e}", file=sys.stderr)
        sys.exit(1)
    # listen() streams on a background thread; block the main thread.
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
PYEOF
}

# ---- Firebase consumer + supervisor (runs as a background subprocess) --
# Reads one JSON command per line from the listener and feeds the shared
# dispatch / stop path. Restarts the listener with a backoff if it exits.
_firebase_loop() {
    trap - EXIT INT TERM   # don't inherit the daemon's PID-file cleanup
    while true; do
        log "Firebase listener: starting"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local action rec_id cam_id cam_name rtsp rtype dur
            action=$(echo "$line" | jq -r '.action       // empty' 2>/dev/null)
            rec_id=$(echo "$line" | jq -r '.recording_id // empty' 2>/dev/null)
            [[ -z "$rec_id" ]] && continue
            case "$action" in
                start)
                    rtype=$(echo "$line" | jq -r '.recording_type // "inference"' 2>/dev/null)
                    if [[ "$rtype" != "raw" ]]; then
                        log_debug "Firebase: start $rec_id type=$rtype — not raw, skip"; continue
                    fi
                    local cmd_site; cmd_site=$(echo "$line" | jq -r '.site_id // empty' 2>/dev/null)
                    # Belt-and-suspenders: even though the listener is scoped to
                    # our site path, drop any command for a different site.
                    if [[ -n "$CLIENT_SITE_ID" && -n "$cmd_site" && "$cmd_site" != "$CLIENT_SITE_ID" ]]; then
                        log_debug "Firebase: start $rec_id for site $cmd_site != ours ($CLIENT_SITE_ID) — skip"; continue
                    fi
                    cam_id=$(echo "$line"   | jq -r '.camera_id        // empty' 2>/dev/null)
                    cam_name=$(echo "$line" | jq -r '.camera_name      // .camera_id // empty' 2>/dev/null)
                    rtsp=$(echo "$line"     | jq -r '.camera_url       // empty' 2>/dev/null)
                    dur=$(_duration_sec "$line" "$rec_id")
                    # Prefer the resolved site name; else a stable site-<id> folder.
                    local site_label="$CLIENT_SITE_NAME"
                    [[ -z "$site_label" && -n "$cmd_site" ]] && site_label="site-${cmd_site}"
                    log "Firebase: start command for recording $rec_id (cam=$cam_name, site=${site_label:-unknown}, ${dur}s)"
                    _dispatch_one "$rec_id" "$cam_id" "$cam_name" "$dur" "$rtsp" "$site_label" || true
                    ;;
                stop)
                    if [[ -d "${ACTIVE_DIR}/${rec_id}" ]]; then
                        log "Firebase: stop command for recording $rec_id — finalizing"
                        touch "${ACTIVE_DIR}/${rec_id}.stop"
                    else
                        log_debug "Firebase: stop for $rec_id but not active locally — ignoring"
                    fi
                    ;;
                *)
                    log_debug "Firebase: unknown action '$action' for $rec_id"
                    ;;
            esac
        done < <("$FIREBASE_PYTHON" "$LISTENER_SCRIPT" 2>>"$LOG_FILE")
        log_warn "Firebase listener exited — restarting in ${FIREBASE_RESTART_DELAY}s"
        sleep "$FIREBASE_RESTART_DELAY"
    done
}

# ---- Normalise GET response, then dispatch ----------------------------
_poll() {
    log "Polling for pending recordings..."

    mkdir -p "$TMP_DIR" "$ACTIVE_DIR" "$SPOOL_DIR" 2>/dev/null || true
    _reap_stale_ffmpeg   # clear captures that outlived their recording
    _spool_drain         # ship anything the network refused earlier

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
            _poll_stop_check ""   # nothing active server-side → stop any locals
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
    local active_ids; active_ids=$(echo "$recs" | jq -r '.[].recording_id // empty' 2>/dev/null)
    _poll_stop_check "$active_ids"
    [[ "$n" -eq 0 ]] && { log "No pending recordings"; return; }
    log "Found $n pending recording(s)"
    _dispatch "$recs"
}

# ---- Main loop ---------------------------------------------------------
log "Work dir: $TMP_DIR (spool: $SPOOL_DIR, $(_free_mb "$TMP_DIR")MB free)"

# Recordings spooled by an older build under /tmp are still worth shipping, and
# /tmp is cleared on reboot — move them onto the state dir before that happens.
if [[ "$TMP_DIR" != "$LEGACY_TMP_DIR" && -d "$LEGACY_TMP_DIR/spool" ]]; then
    _migrated=$(find "$LEGACY_TMP_DIR/spool" -maxdepth 1 -type f -name '*.mp4' 2>/dev/null | wc -l)
    if (( _migrated > 0 )); then
        mv -f "$LEGACY_TMP_DIR"/spool/* "$SPOOL_DIR"/ 2>/dev/null \
            && log "Migrated $_migrated spooled recording(s) from $LEGACY_TMP_DIR/spool" \
            || log_warn "Could not migrate spooled recordings from $LEGACY_TMP_DIR/spool"
    fi
fi

# Claim directories now survive a restart (the state dir is not wiped like /tmp
# was), so any claim present at startup belongs to a dead generation. Clear them
# first — otherwise they block every future dispatch of those recording ids —
# then reap the ffmpeg those recordings left holding their RTSP sessions.
_stale_claims=$(find "$ACTIVE_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
if (( _stale_claims > 0 )); then
    log_warn "Clearing $_stale_claims claim(s) left by a previous daemon generation"
    rm -rf "${ACTIVE_DIR:?}"/* 2>/dev/null || true
fi
_reap_stale_ffmpeg 0

_detect_rtsp_timeout_flag
log "ffmpeg RTSP timeout: ${FFMPEG_RTSP_TIMEOUT_ARGS[*]:-none}"

_container_state=$(_ensure_container)
_container_access="${_container_state#*:}"
log "Azure container ready (${AZURE_CONTAINER}/${AZURE_BLOB_PREFIX}/, access=${_container_access:-unknown})"

# Permanent URLs carry no token, so the object has to be readable without one.
# Say so up front rather than letting the probe fail with no explanation.
if [[ "$CDN_PUBLIC_URLS" == "1" && "$_container_access" == "private" ]]; then
    log_warn "Container '${AZURE_CONTAINER}' is private but permanent CDN URLs are on — these resolve only if ${CDN_BASE_URL} authenticates to its origin. If the probe below fails, either set the container's public access to 'blob' or leave CDN_PUBLIC_URLS=0."
fi

# Confirm permanent CDN links actually resolve before any recording is written
# with one; falls back to signed URLs if they don't.
_probe_public_url

# Resolve the site this token is scoped to (for Firebase scoping + labelling).
_fetch_site_context

# Start the Firebase push listener (near-instant start/stop). Polling below
# continues regardless and is the sole mechanism when Firebase is disabled.
FIREBASE_LOOP_PID=""
if [[ "$FIREBASE_ENABLED" == "1" ]]; then
    export FIREBASE_PATH="$CLIENT_FIREBASE_PATH"   # scope listener to our site path
    _write_listener_script
    _firebase_loop &
    FIREBASE_LOOP_PID=$!
    log "Firebase listener active (loop PID=$FIREBASE_LOOP_PID, path=${CLIENT_FIREBASE_PATH:-<root>})"
else
    log "Firebase listener not started — polling only"
fi

_poll  # immediate check on startup

while true; do
    sleep "$POLL_INTERVAL"
    _poll
done
