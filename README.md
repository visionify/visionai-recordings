# VisionAI Recordings

Daemon for VisionAI camera recordings — polls the API for pending recordings, captures video via ffmpeg, uploads to cloud storage, and reports progress back to the API.

---

## Platform Support

| | macOS | Linux (Debian/Ubuntu) |
|---|---|---|
| Service manager | LaunchDaemon (`launchctl`) | systemd (`systemctl`) |
| Dependencies | Homebrew | `apt-get` |
| Storage | AWS S3 (boto3, presigned URLs) | Azure Blob Storage (SAS URLs) |
| Recording mode | Segmented (10 min chunks) | Single file per recording |
| API auth header | `x-api-token` | `Token` |

---

## macOS

### Requirements

| Tool | Purpose |
|------|---------|
| `ffmpeg` | RTSP capture |
| `jq` | JSON parsing |
| `curl` | API calls |
| Python 3 + boto3 | S3 upload (auto-detected from project venv) |

Required `.env` variables:

```env
VISIONAI_API_ENDPOINT=https://...
VISIONAI_API_TOKEN=...
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=ap-south-1
AWS_BUCKET_NAME=your-bucket
```

### Install

```bash
sudo /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/visionify/visionai-recordings/main/install_recording_manager.sh)"
```

With a custom `.env` path:

```bash
sudo ENV_FILE=/path/to/.env /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/visionify/visionai-recordings/main/install_recording_manager.sh)"
```

The installer will:
- Install `jq`, `ffmpeg`, `curl` via Homebrew if missing
- Copy your `.env` to `~/.visionai/.env`
- Install the script to `/usr/local/bin/visionai-recording-manager`
- Register and start a LaunchDaemon (`com.visionai.recording-manager`) that runs at boot

### Update

```bash
sudo curl -fsSL "https://raw.githubusercontent.com/visionify/visionai-recordings/main/recording_manager.sh" \
    -o /usr/local/bin/visionai-recording-manager \
  && sudo launchctl unload /Library/LaunchDaemons/com.visionai.recording-manager.plist \
  && sudo launchctl load -w /Library/LaunchDaemons/com.visionai.recording-manager.plist
```

### Uninstall

```bash
sudo launchctl unload /Library/LaunchDaemons/com.visionai.recording-manager.plist
sudo rm /Library/LaunchDaemons/com.visionai.recording-manager.plist
sudo rm /usr/local/bin/visionai-recording-manager
```

### Service Management

```bash
# Check status
launchctl list com.visionai.recording-manager

# Watch live logs
tail -f /var/log/visionai/recording-manager.log

# Restart
sudo launchctl unload /Library/LaunchDaemons/com.visionai.recording-manager.plist
sudo launchctl load -w /Library/LaunchDaemons/com.visionai.recording-manager.plist
```

### S3 File Structure

```
recordings/<camera>/<camera>-<YYYYMMDD-HHMMSS>-000.mp4
recordings/<camera>/<camera>-<YYYYMMDD-HHMMSS>-000_thumb.jpg
recordings/<camera>/<camera>-<YYYYMMDD-HHMMSS>-001.mp4
...
```

### Optional Configuration (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `POLL_INTERVAL` | `300` | Seconds between API polls |
| `SEGMENT_DURATION` | `600` | Seconds per video segment |
| `UPLOAD_RETRIES` | `3` | Max S3 upload attempts per segment |
| `UPLOAD_RETRY_DELAY` | `10` | Seconds between upload retries |
| `PYTHON_BIN` | auto-detected | Path to Python 3 with boto3 |
| `SERVER_ID` | — | Only process recordings for this server |
| `DEBUG` | `0` | Set to `1` for verbose logging |

### Troubleshooting (macOS)

**Service not starting**
```bash
launchctl list com.visionai.recording-manager
tail -50 /var/log/visionai/recording-manager.log
```

**API unreachable**
```bash
source ~/.visionai/.env
curl -sf -H "x-api-token: $VISIONAI_API_TOKEN" \
  "${VISIONAI_API_ENDPOINT}/recordings/inference?action=pending"
```

**S3 upload failing**
```bash
source ~/.visionai/.env
python3 -c "import boto3; print(boto3.__version__)"

python3 - /tmp/test.txt "$AWS_BUCKET_NAME" test/test.txt \
    "$AWS_REGION" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" <<'EOF'
import sys, boto3
file, bucket, key, region, ak, sk = sys.argv[1:]
s3 = boto3.client('s3', aws_access_key_id=ak, aws_secret_access_key=sk, region_name=region)
s3.upload_file(file, bucket, key)
print("OK:", s3.generate_presigned_url('get_object', Params={'Bucket':bucket,'Key':key}, ExpiresIn=3600))
EOF
```

If boto3 is not found, add to `~/.visionai/.env`:
```
PYTHON_BIN=/path/to/.venv/bin/python3
```

**ffmpeg not recording**
```bash
ffmpeg -rtsp_transport tcp -i "rtsp://camera-ip/stream" -t 10 /tmp/test.mp4
```

---

## Linux (Debian / Ubuntu)

### Requirements

| Tool | Purpose |
|------|---------|
| `ffmpeg` | RTSP capture and thumbnail extraction |
| `jq` | JSON parsing |
| `curl` | API calls |
| Python 3 + azure-storage-blob | Azure Blob upload (venv auto-created at `/opt/visionai/.venv`) |
| Python 3 + firebase-admin | Optional — Firebase push listener for near-instant start/stop |

The installer handles all of the above via `apt-get` and a Python venv.
(`firebase-admin` is best-effort: if it can't install, the daemon runs in
polling-only mode.)

Required `.env` variables:

```env
VISIONAI_API_ENDPOINT=http://<host>:<port>/api
VISIONAI_API_TOKEN=...
EVENTS_AZURE_BLOB_CONNECTION_STRING=DefaultEndpointsProtocol=https;AccountName=...
```

> Do not wrap values in quotes in the `.env` file.

### Install

```bash
curl -fsSL https://raw.githubusercontent.com/visionify/visionai-recordings/main/recording_manager_linux.sh \
  | sudo bash -s install
```

With a custom `.env` path:

```bash
curl -fsSL https://raw.githubusercontent.com/visionify/visionai-recordings/main/recording_manager_linux.sh \
  | sudo ENV_FILE=/path/to/.env bash -s install
```

The installer will:
- Run `apt-get` to install `jq`, `ffmpeg`, `curl`, `python3`, `python3-venv` if missing
- Create a Python venv at `/opt/visionai/.venv` and install `azure-storage-blob` (and, best-effort, `firebase-admin`)
- Copy your `.env` to `~/.visionai/.env`
- Install the script to `/usr/local/bin/visionai-recording-manager`
- Register and start a systemd service (`visionai-recording-manager`) that runs at boot
- Create the `recordings` Azure Blob container if it doesn't exist

### Update

```bash
sudo curl -fsSL "https://raw.githubusercontent.com/visionify/visionai-recordings/main/recording_manager_linux.sh" \
    -o /usr/local/bin/visionai-recording-manager \
  && sudo systemctl restart visionai-recording-manager
```

### Uninstall

```bash
sudo systemctl stop visionai-recording-manager
sudo systemctl disable visionai-recording-manager
sudo rm /etc/systemd/system/visionai-recording-manager.service
sudo rm /usr/local/bin/visionai-recording-manager
sudo systemctl daemon-reload
```

### Service Management

```bash
# Check status
systemctl status visionai-recording-manager

# Watch live logs
journalctl -u visionai-recording-manager -f

# Also available in the log file
tail -f /var/log/visionai/recording-manager.log

# Restart / stop
sudo systemctl restart visionai-recording-manager
sudo systemctl stop visionai-recording-manager
```

### Azure Blob File Structure

Each recording is a single file (no segments), stored in the **`recordings`**
container under a `raw-recordings/<site_uuid>/` prefix:

```
recordings/                       ← container
  raw-recordings/
    <site_uuid>/
      <camera>-<YYYYMMDD-HHMMSS>.mp4
      <camera>-<YYYYMMDD-HHMMSS>_thumb.jpg
```

Example:
```
recordings/raw-recordings/3f9a…-uuid/office-20260512-143000.mp4
recordings/raw-recordings/3f9a…-uuid/office-20260512-143000_thumb.jpg
```

The container and prefix are overridable via `AZURE_CONTAINER` (default
`recordings`) and `AZURE_BLOB_PREFIX` (default `raw-recordings`). `site_uuid`
comes from `/v2/token-context`; if it can't be resolved, the sanitized site name
is used instead.

### Video Settings

Recordings are optimised for computer vision — frame extraction and annotation:

| Setting | Value | Purpose |
|---------|-------|---------|
| Resolution | max 720p | Sufficient for CV, keeps file size manageable |
| Frame rate | 15 fps | 1 frame per 67ms — good temporal resolution |
| Codec | H.264 (CRF 20) | High quality, universally compatible |
| Pixel format | `yuv420p` | Compatible with OpenCV, PyTorch, YOLO etc. |
| Keyframe interval | every 1s | Fast random seeking during frame extraction |
| Audio | none | Not needed for CV |

Expected file size: **150–400 MB** per 30-minute recording.

### Optional Configuration (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `POLL_INTERVAL` | `300` | Seconds between API polls |
| `UPLOAD_RETRIES` | `3` | Max Azure upload attempts |
| `UPLOAD_RETRY_DELAY` | `10` | Seconds between upload retries |
| `PYTHON_BIN` | auto-detected | Path to Python 3 with azure-storage-blob |
| `DEBUG` | `0` | Set to `1` for verbose logging |
| `FIREBASE_DATABASE_URL` | _unset_ | Realtime DB URL — **set this to enable Firebase push** |
| `FIREBASE_SERVICE_ACCOUNT` | _unset_ | Path to a service-account JSON (alternative to the fields below) |
| `FIREBASE_PROJECT_ID` … | _unset_ | Service-account fields (same as the backend): `FIREBASE_PRIVATE_KEY_ID`, `FIREBASE_PRIVATE_KEY`, `FIREBASE_CLIENT_EMAIL`, `FIREBASE_CLIENT_ID`, `FIREBASE_CLIENT_X509_CERT_URL` |
| `FIREBASE_RESTART_DELAY` | `15` | Seconds before restarting the listener if it exits |

### Firebase push (optional — near-instant start/stop)

By default the daemon **polls** `get-recording-status` every `POLL_INTERVAL` seconds,
so a newly started or scheduled recording is picked up at the next poll (≤ 5 min by
default), and recordings always run their full duration.

Setting `FIREBASE_DATABASE_URL` plus service-account credentials enables a listener
on the backend's Realtime DB path `recording-commands/{site_uuid}/{recording_id}`:

- **Start** commands begin recording within seconds instead of waiting for a poll.
- **Stop** commands end an in-progress recording early; whatever was captured is
  uploaded and reported.

The listener subscribes only to your site's `{site_uuid}` subtree — no cross-client
collisions in a shared Firebase project. The client resolves everything from
`GET /v2/token-context` at startup (using the API token): `site_uuid` (listener
scope), `site_name` (folder label) and `site_id` (a safety filter) — no manual
config needed. The `.env` vars `VISIONAI_SITE_UUID` / `VISIONAI_FIREBASE_PATH` /
`VISIONAI_SITE_NAME` override the API values if you ever need to. If no `site_uuid`
is resolved, the listener falls back to the unscoped root path and filters by `site_id`.

Polling always stays on as a fallback. When Firebase is **disabled**, early-stop is
still best-effort: a recording that disappears from the server's active list for two
consecutive polls is stopped. Set the same `FIREBASE_*` values your backend uses
(`src/api/firebase.js`). If the credentials or `firebase-admin` are missing, the
daemon logs `Firebase disabled` and runs polling-only.

### Troubleshooting (Linux)

**Service not starting**
```bash
systemctl status visionai-recording-manager
journalctl -u visionai-recording-manager -n 50
```

**API unreachable**
```bash
source ~/.visionai/.env
curl -sf -H "Token: $VISIONAI_API_TOKEN" \
  "${VISIONAI_API_ENDPOINT}/v2/get-recording-status?recording_type=raw"
```

**Azure upload failing**
```bash
source ~/.visionai/.env
/opt/visionai/.venv/bin/python3 - \
  "$EVENTS_AZURE_BLOB_CONNECTION_STRING" <<'EOF'
import sys
from azure.storage.blob import BlobServiceClient
conn_str = sys.argv[1]
client = BlobServiceClient.from_connection_string(conn_str)
blob = client.get_blob_client(container="recordings", blob="test/upload-test.txt")
blob.upload_blob(b"test", overwrite=True)
print("OK:", blob.url)
EOF
```

If `azure-storage-blob` is not found, add to `~/.visionai/.env`:
```
PYTHON_BIN=/path/to/.venv/bin/python3
```

**ffmpeg not recording**
```bash
# Test RTSP stream directly
ffmpeg -rtsp_transport tcp -i "rtsp://camera-ip/stream" -t 10 /tmp/test.mp4

# Check last ffmpeg error from a failed recording
ls /tmp/visionai-rec/*.err 2>/dev/null && cat /tmp/visionai-rec/*.err
```

**Check what the service loaded at startup**
```bash
sudo grep "API endpoint\|API token\|Loaded\|Python" \
  /var/log/visionai/recording-manager.log | tail -10
```
