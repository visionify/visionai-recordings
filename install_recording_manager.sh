#!/usr/bin/env bash
# VisionAI Recording Manager — macOS Installer
#
# Installs visionai-recording-manager as a macOS LaunchDaemon that:
#   • starts automatically at boot
#   • restarts on crash
#   • polls the VisionAI API every 5 minutes to start camera recordings
#
# ── Install (same pattern as Homebrew) ───────────────────────────────────────
#
#   sudo /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/visionify/visionai-recordings/main/install_recording_manager.sh)"
#
# With a custom .env file path (default: ~/.visionai/.env):
#
#   sudo ENV_FILE=/path/to/.env /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/visionify/visionai-recordings/main/install_recording_manager.sh)"
#
# ── Uninstall ────────────────────────────────────────────────────────────────
#
#   sudo launchctl unload /Library/LaunchDaemons/com.visionai.recording-manager.plist
#   sudo rm /Library/LaunchDaemons/com.visionai.recording-manager.plist
#   sudo rm /usr/local/bin/visionai-recording-manager
#
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

REPO_BASE="https://raw.githubusercontent.com/visionify/visionai-recordings/main"
INSTALL_BIN="/usr/local/bin/visionai-recording-manager"
PLIST_PATH="/Library/LaunchDaemons/com.visionai.recording-manager.plist"
LOG_DIR="/var/log/visionai"
SERVICE_LABEL="com.visionai.recording-manager"

# Resolve the real user's home dir (sudo sets SUDO_USER; fall back to current user)
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
echo "  │   VisionAI Recording Manager  ·  Installer  │"
echo "  └─────────────────────────────────────────────┘"
echo ""

# ── Checks ───────────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || err "This installer targets macOS only (detected: $(uname))"
[[ "$(id -u)" -eq 0 ]]       || err "Run this installer with sudo — see usage at the top of this script"

# ── Dependencies ─────────────────────────────────────────────────────────────
step "Checking dependencies..."

BREW_USER="$REAL_USER"
BREW_BIN=""
if   [[ -x "/opt/homebrew/bin/brew" ]]; then BREW_BIN="/opt/homebrew/bin/brew"
elif [[ -x "/usr/local/bin/brew"    ]]; then BREW_BIN="/usr/local/bin/brew"
fi

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

_brew_install() {
    if [[ -n "$BREW_BIN" ]]; then
        sudo -u "$BREW_USER" "$BREW_BIN" install "$1" </dev/null
    else
        err "Homebrew not found. Install it as $BREW_USER:\n  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    fi
}

_require() {
    local cmd="$1" pkg="${2:-$1}"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd  $(command -v "$cmd")"
    else
        warn "$cmd not found — installing via Homebrew (as $BREW_USER)..."
        _brew_install "$pkg"
        hash -r 2>/dev/null || true
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$cmd  $(command -v "$cmd")"
        else
            err "$cmd still not found after install — check Homebrew output above"
        fi
    fi
}

_require jq
_require ffmpeg
_require curl
# awscli is required only for the AWS backend — installed later, once the
# env file is resolved and STORAGE_BACKEND is known.

# ── Verify ffmpeg has VideoToolbox (hardware H.264 encoder) ──────────────────
# VideoToolbox is built into macOS — the recording script uses
# h264_videotoolbox for low-CPU, real-time encoding at ~500 kbps.
# Homebrew's ffmpeg always ships with it; static/conda builds often
# don't. If the installed ffmpeg lacks it, reinstall via Homebrew.
_has_videotoolbox() {
    ffmpeg -hide_banner -encoders 2>/dev/null \
        | grep -q '^[[:space:]]*V[^ ]*[[:space:]]\+h264_videotoolbox'
}

step "Verifying VideoToolbox encoder in ffmpeg..."
if _has_videotoolbox; then
    ok "h264_videotoolbox  available  ($(command -v ffmpeg))"
else
    warn "ffmpeg at $(command -v ffmpeg) lacks h264_videotoolbox — reinstalling via Homebrew..."
    if [[ -n "$BREW_BIN" ]]; then
        sudo -u "$BREW_USER" "$BREW_BIN" reinstall ffmpeg </dev/null \
            || sudo -u "$BREW_USER" "$BREW_BIN" install ffmpeg </dev/null
        hash -r 2>/dev/null || true
        if _has_videotoolbox; then
            ok "h264_videotoolbox  now available"
        else
            warn "h264_videotoolbox still missing — recording will fall back to libx264 (software, higher CPU)"
        fi
    else
        warn "Homebrew not found — cannot reinstall ffmpeg. Recording will fall back to libx264 (software, higher CPU)"
    fi
fi

# ── Env file ─────────────────────────────────────────────────────────────────
step "Locating env file..."
ENV_FILE="${ENV_FILE:-}"

if [[ -z "$ENV_FILE" ]]; then
    for _c in "$DEFAULT_ENV_FILE" "${REAL_HOME}/.visionai/.env" "/opt/visionai/.env"; do
        if [[ -f "$_c" ]]; then ENV_FILE="$_c"; break; fi
    done
fi

if [[ -z "$ENV_FILE" ]]; then
    echo "  No .env file found. Enter the full path to your .env file:"
    read -rp "  > " ENV_FILE
fi

[[ -f "$ENV_FILE" ]] || err "Env file not found: $ENV_FILE"

# If the env file is not already in ~/.visionai/, copy it there
if [[ "$ENV_FILE" != "$DEFAULT_ENV_FILE" ]]; then
    mkdir -p "$(dirname "$DEFAULT_ENV_FILE")"
    cp "$ENV_FILE" "$DEFAULT_ENV_FILE"
    ok "Copied $ENV_FILE → $DEFAULT_ENV_FILE"
    ENV_FILE="$DEFAULT_ENV_FILE"
fi

# Ensure root (the daemon) can read it
chmod 644 "$ENV_FILE"
chown "$REAL_USER" "$ENV_FILE"
ok "Env file: $ENV_FILE"

# ── Python SDK for the selected storage backend ──────────────────────────────
# The daemon uploads via Python (boto3 for AWS, azure-storage-blob for Azure)
# using whatever venv recording_manager.sh's _find_python() locates. Make sure
# the matching SDK is importable from that Python, installing it if missing.
step "Checking Python storage SDK..."

# Pull a value out of the resolved env file (strips surrounding quotes).
_envval() {
    local v; v=$(grep -E "^[[:space:]]*$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2-)
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    echo "$v"
}

STORAGE_BACKEND=$(_envval STORAGE_BACKEND | tr '[:upper:]' '[:lower:]')
STORAGE_BACKEND="${STORAGE_BACKEND:-aws}"
ENV_PYTHON_BIN=$(_envval PYTHON_BIN)

if [[ "$STORAGE_BACKEND" == "azure" ]]; then
    SDK_PKG="azure-storage-blob"; SDK_IMPORT="from azure.storage.blob import BlobServiceClient"
else
    SDK_PKG="boto3"; SDK_IMPORT="import boto3"
    _require aws awscli   # AWS backend only
fi

# Mirror recording_manager.sh's _find_python() search order to pick the Python
# the daemon will actually use, preferring PYTHON_BIN from the env file.
_pick_python() {
    local _py
    for _py in \
        "$ENV_PYTHON_BIN" \
        /Users/visionify/vision-pallet-management-inference/.venv/bin/python3 \
        /Users/visionify/visionai/vision-pallet-management-inference/.venv/bin/python3 \
        /Users/visionify/.venv/bin/python3 \
        /opt/visionai/.venv/bin/python3 \
        python3 python; do
        [[ -z "$_py" ]] && continue
        if [[ -x "$_py" ]]; then echo "$_py"; return; fi
        command -v "$_py" >/dev/null 2>&1 && { command -v "$_py"; return; }
    done
    echo ""
}
TARGET_PY=$(_pick_python)

if [[ -z "$TARGET_PY" ]]; then
    warn "No Python 3 found — install one with $SDK_PKG, or set PYTHON_BIN in $ENV_FILE"
elif sudo -u "$REAL_USER" "$TARGET_PY" -c "$SDK_IMPORT" >/dev/null 2>&1; then
    ok "$SDK_PKG already available ($TARGET_PY)"
else
    warn "$SDK_PKG not importable from $TARGET_PY — installing..."
    # Install as the venv's owner to avoid root-owned files; fall back to root.
    sudo -u "$REAL_USER" "$TARGET_PY" -m pip install --quiet "$SDK_PKG" </dev/null 2>/dev/null \
        || "$TARGET_PY" -m pip install --quiet "$SDK_PKG" </dev/null 2>/dev/null || true
    if sudo -u "$REAL_USER" "$TARGET_PY" -c "$SDK_IMPORT" >/dev/null 2>&1; then
        ok "$SDK_PKG installed ($TARGET_PY)"
    else
        warn "Could not install $SDK_PKG into $TARGET_PY — install it manually:\n      $TARGET_PY -m pip install $SDK_PKG"
    fi
fi

# ── Download recording manager script ────────────────────────────────────────
step "Downloading recording manager script..."
mkdir -p "$(dirname "$INSTALL_BIN")"

SCRIPT_URL="${REPO_BASE}/recording_manager.sh"
if curl -fsSL "$SCRIPT_URL" -o "$INSTALL_BIN" </dev/null; then
    chmod +x "$INSTALL_BIN"
    ok "Installed: $INSTALL_BIN"
    ok "Source:    $SCRIPT_URL"
else
    err "Download failed: $SCRIPT_URL"
fi

mkdir -p "$LOG_DIR"
ok "Log dir:   $LOG_DIR"

# ── LaunchDaemon plist ───────────────────────────────────────────────────────
step "Creating LaunchDaemon..."

RUNTIME_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cat > "$PLIST_PATH" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${INSTALL_BIN}</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>ENV_FILE</key>
        <string>${ENV_FILE}</string>
        <key>LOG_FILE</key>
        <string>${LOG_DIR}/recording-manager.log</string>
        <key>PATH</key>
        <string>${RUNTIME_PATH}</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>WorkingDirectory</key>
    <string>/tmp</string>
</dict>
</plist>
PLIST_EOF

ok "Plist: $PLIST_PATH"

# ── Load / reload service ────────────────────────────────────────────────────
step "Starting service..."
if launchctl list "$SERVICE_LABEL" >/dev/null 2>&1; then
    warn "Service already loaded — reloading..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    sleep 1
fi
launchctl load -w "$PLIST_PATH"
sleep 2

if launchctl list "$SERVICE_LABEL" >/dev/null 2>&1; then
    ok "Service running  ($SERVICE_LABEL)"
else
    warn "Service loaded but may not be active yet — check logs"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │  Done!                                                          │"
echo "  │                                                                 │"
printf "  │  Service  %-54s│\n" "$SERVICE_LABEL"
printf "  │  Binary   %-54s│\n" "$INSTALL_BIN"
printf "  │  Env file %-54s│\n" "$ENV_FILE"
printf "  │  Logs     %-54s│\n" "${LOG_DIR}/recording-manager.log"
echo "  │                                                                 │"
echo "  │  Useful commands:                                               │"
echo "  │    tail -f ${LOG_DIR}/recording-manager.log       │"
echo "  │    launchctl list $SERVICE_LABEL  │"
echo "  │    sudo launchctl unload $PLIST_PATH    │"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""
