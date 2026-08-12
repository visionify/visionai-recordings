#!/usr/bin/env python3
"""
Backfill Content-Type on recordings uploaded before the manager set it.

The Azure upload path never set a content type, so every blob landed as
application/octet-stream. A browser given such a URL downloads the file instead
of playing it, and <video>/<img> fail outright — so existing recordings are
effectively unplayable in place even though the bytes are fine.

This is metadata-only: it rewrites each blob's content settings and never
touches the blob contents. Defaults to a dry run.

    python3 backfill_content_type.py                 # report what would change
    python3 backfill_content_type.py --apply         # actually change it
    python3 backfill_content_type.py --apply --prefix recordings/assemblers/

Reads AZURE_STORAGE_CONNECTION_STRING / AZURE_STORAGE_CONTAINER from
~/.visionai/.env (parsed, never sourced — the connection string is full of ';'
and '=' and breaks a shell `source`).
"""
import argparse
import os
import sys

TYPES = {".mp4": "video/mp4", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


def load_env(path):
    env = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            val = val.strip()
            if len(val) > 1 and val[0] == val[-1] and val[0] in "\"'":
                val = val[1:-1]
            env[key.strip()] = val
    return env


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="perform the change (default: dry run)")
    ap.add_argument("--prefix", default="recordings/", help="blob name prefix to scan")
    ap.add_argument("--env-file", default=os.path.expanduser("~/.visionai/.env"))
    args = ap.parse_args()

    try:
        from azure.storage.blob import BlobServiceClient, ContentSettings
    except ImportError:
        sys.exit("azure-storage-blob is not installed for this interpreter")

    env = load_env(args.env_file)
    client = BlobServiceClient.from_connection_string(env["AZURE_STORAGE_CONNECTION_STRING"])
    container = client.get_container_client(env.get("AZURE_STORAGE_CONTAINER") or "media")

    scanned = changed = skipped = 0
    for blob in container.list_blobs(name_starts_with=args.prefix):
        ext = os.path.splitext(blob.name)[1].lower()
        want = TYPES.get(ext)
        if not want:
            continue
        scanned += 1
        current = blob.content_settings.content_type
        if current == want:
            skipped += 1
            continue
        print(f"{'FIX ' if args.apply else 'WOULD FIX'} {blob.name}  {current!r} -> {want!r}")
        if args.apply:
            container.get_blob_client(blob.name).set_http_headers(
                ContentSettings(content_type=want, content_disposition="inline")
            )
            changed += 1

    print(f"\nscanned={scanned} already_correct={skipped} "
          f"{'changed' if args.apply else 'would_change'}={changed if args.apply else scanned - skipped}")
    if not args.apply:
        print("dry run — re-run with --apply to write the changes")


if __name__ == "__main__":
    main()
