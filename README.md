# VisionAI Recordings

Linux daemon for VisionAI camera recordings — polls the API for pending recordings, captures video via ffmpeg, uploads segments to Azure Blob Storage, and reports progress back to the API.

## Features

- Runs as a Linux systemd service (auto-starts at boot, restarts on crash)
- Polls the VisionAI API every 60 seconds for pending recordings
- Records RTSP streams in configurable segments via ffmpeg (H.264 + AAC)
- Uploads segments to Azure Blob Storage via `azure-storage-blob`
- Retries failed uploads with configurable retry count and delay
- Uploads a thumbnail (first frame) for each segment
- Always completes all segments once a recording starts
- Reports `in_progress` after each segment, `completed` or `failed` at the end

## Requirements

| Tool | Purpose |
|------|---------|
| `ffmpeg` | RTSP capture and thumbnail extraction |
| `jq` | JSON parsing |
| `curl` | API calls |
| Python 3 + azure-storage-blob | Azure Blob upload (venv auto-created at `/opt/visionai/.venv`) |

The installer handles all of the above via `apt-get` and a Python venv.

Required `.env` variables:

```env
VISIONAI_API_ENDPOINT=https://...
VISIONAI_API_TOKEN=...
EVENTS_AZURE_BLOB_CONNECTION_STRING=DefaultEndpointsProtocol=https;AccountName=...
```


## Install

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
- Create a Python venv at `/opt/visionai/.venv` and install `azure-storage-blob`
- Copy your `.env` to `~/.visionai/.env`
- Install the script to `/usr/local/bin/visionai-recording-manager`
- Register and start a systemd service (`visionai-recording-manager`) that runs at boot

## Update

```bash
sudo curl -fsSL "https://raw.githubusercontent.com/visionify/visionai-recordings/main/recording_manager_linux.sh" \
    -o /usr/local/bin/visionai-recording-manager \
  && sudo systemctl restart visionai-recording-manager
```

## Uninstall

```bash
sudo systemctl stop visionai-recording-manager
sudo systemctl disable visionai-recording-manager
sudo rm /etc/systemd/system/visionai-recording-manager.service
sudo rm /usr/local/bin/visionai-recording-manager
sudo systemctl daemon-reload
```

## Service Management

```bash
# Check service status
systemctl status visionai-recording-manager

# Watch live logs
journalctl -u visionai-recording-manager -f

# Also available in the log file
tail -f /var/log/visionai/recording-manager.log

# Restart / stop
sudo systemctl restart visionai-recording-manager
sudo systemctl stop visionai-recording-manager
```

## Azure Blob File Structure

```
raw-recordings/<camera-name>/<camera-name>-<YYYYMMDD-HHMMSS>-000.mp4
raw-recordings/<camera-name>/<camera-name>-<YYYYMMDD-HHMMSS>-000_thumb.jpg
raw-recordings/<camera-name>/<camera-name>-<YYYYMMDD-HHMMSS>-001.mp4
...
```

A `raw-recordings/.keep` marker blob is created automatically on first start to ensure the folder exists in the container.

## Optional Configuration (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `POLL_INTERVAL` | `60` | Seconds between API polls |
| `SEGMENT_DURATION` | `600` | Seconds per video segment |
| `UPLOAD_RETRIES` | `3` | Max Azure upload attempts per segment |
| `UPLOAD_RETRY_DELAY` | `10` | Seconds between upload retries |
| `PYTHON_BIN` | auto-detected | Path to Python 3 with azure-storage-blob |
| `DEBUG` | `0` | Set to `1` for verbose logging |

## Troubleshooting

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
/opt/visionai/.venv/bin/python3 -c "from azure.storage.blob import BlobServiceClient; print('OK')"

# Test upload manually
/opt/visionai/.venv/bin/python3 - "$EVENTS_AZURE_BLOB_CONTAINER" \
    "$EVENTS_AZURE_BLOB_CONNECTION_STRING" <<'EOF'
import sys
from azure.storage.blob import BlobServiceClient
container, conn_str = sys.argv[1:]
client = BlobServiceClient.from_connection_string(conn_str)
blob = client.get_blob_client(container=container, blob="test/upload-test.txt")
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
ffmpeg -rtsp_transport tcp -i "rtsp://camera-ip/stream" -t 10 /tmp/test.mp4
```
