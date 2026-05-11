# VisionAI Recordings

macOS daemon for VisionAI camera recordings — polls the API for pending recordings, captures video via ffmpeg, uploads segments to S3, and reports progress back to the API.

## Features

- Runs as a macOS LaunchDaemon (auto-starts at boot, restarts on crash)
- Polls the VisionAI API every 10 minutes for pending recordings
- Records RTSP streams in configurable segments via ffmpeg
- Uploads segments to S3 via boto3 with presigned GET URLs
- Retries failed uploads with configurable retry count and delay
- Uploads a thumbnail (first frame) for each segment
- Always completes all segments once a recording starts
- Checks camera recording-enabled status before dispatching

## Requirements

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

## Install

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

## Update

```bash
sudo curl -fsSL "https://raw.githubusercontent.com/visionify/visionai-recordings/main/recording_manager.sh" \
    -o /usr/local/bin/visionai-recording-manager \
  && sudo launchctl unload /Library/LaunchDaemons/com.visionai.recording-manager.plist \
  && sudo launchctl load -w /Library/LaunchDaemons/com.visionai.recording-manager.plist
```

## Uninstall

```bash
sudo launchctl unload /Library/LaunchDaemons/com.visionai.recording-manager.plist
sudo rm /Library/LaunchDaemons/com.visionai.recording-manager.plist
sudo rm /usr/local/bin/visionai-recording-manager
```

## Service Management

```bash
# Check service status
launchctl list com.visionai.recording-manager

# Watch live logs
tail -f /var/log/visionai/recording-manager.log

# Restart
sudo launchctl unload /Library/LaunchDaemons/com.visionai.recording-manager.plist
sudo launchctl load -w /Library/LaunchDaemons/com.visionai.recording-manager.plist
```

## S3 File Structure

```
recordings/<camera-name>/<camera-name>-<YYYYMMDD-HHMMSS>-000.mp4
recordings/<camera-name>/<camera-name>-<YYYYMMDD-HHMMSS>-000_thumb.jpg
recordings/<camera-name>/<camera-name>-<YYYYMMDD-HHMMSS>-001.mp4
...
```

## Optional Configuration (`.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `POLL_INTERVAL` | `600` | Seconds between API polls |
| `SEGMENT_DURATION` | `600` | Seconds per video segment |
| `UPLOAD_RETRIES` | `3` | Max S3 upload attempts per segment |
| `UPLOAD_RETRY_DELAY` | `10` | Seconds between upload retries |
| `PYTHON_BIN` | auto-detected | Path to Python 3 with boto3 |
| `SERVER_ID` | — | Only process recordings for this server |
| `DEBUG` | `0` | Set to `1` for verbose logging |

## Troubleshooting

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

# Test upload manually
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

**Recordings not dispatching for a camera**

Ensure the API returns `recordingEnabled: true` for that camera:
```
GET /recordings/inference?action=camera-status&cameraId=<id>
→ { "success": true, "data": { "recordingEnabled": true } }
```
