#!/usr/bin/env bash
# Host-side helper invoked by `yolo export`.
#
# Reads from environment (all required):
#   VM_ID          source vm-id (running)
#   NAME           yolo name (used for paths inside the bundle)
#   OUT            absolute output path for the .tar.gz bundle
#   META_TMP       path to the metadata.json staged by yolo
#   AP_PATH        path to <name>.applied (may not exist)
#   CWD_PATH       path to <name>.cwd     (may not exist)
#   YOLOFILE_SRC   absolute path to a Yolofile to include, or "" to skip
#   PLACEHOLDER    placeholder image tag baked into manifest.json
#
# Output: a docker-save-format image.tar bundled with metadata + yolo state,
# gzipped to $OUT.
set -euo pipefail

: "${VM_ID:?VM_ID required}"
: "${NAME:?NAME required}"
: "${OUT:?OUT required}"
: "${META_TMP:?META_TMP required}"
: "${AP_PATH:=}"
: "${CWD_PATH:=}"
: "${YOLOFILE_SRC:=}"
: "${PLACEHOLDER:?PLACEHOLDER required}"

WORK="$(mktemp -d -t yolo-export-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"

# 1. Stream the merged rootfs out of the running guest. --one-file-system
#    confines tar to the in-guest rootfs, skipping /proc, /sys, /dev, /run,
#    and the host-mounted workspace. --xattrs preserves SELinux contexts
#    and capabilities for Fedora-based images.
echo "[yolo] capturing rootfs from $VM_ID (this may take a while)" >&2
mkdir layer-tmp
matchlock exec "$VM_ID" -u root -- \
  tar -cf - --one-file-system --numeric-owner --xattrs --xattrs-include='*' -C / . \
  > layer-tmp/layer.tar

# 2. diff_id = sha256(layer.tar). Also used as the legacy v1 layer dir name.
DIFF_ID="$(sha256sum layer-tmp/layer.tar | awk '{print $1}')"
mv layer-tmp "$DIFF_ID"

# 3. v1 layer metadata (legacy fields docker-load still expects).
printf '1.0' > "$DIFF_ID/VERSION"
printf '{"id":"%s","architecture":"amd64","os":"linux","config":{}}\n' \
  "$DIFF_ID" > "$DIFF_ID/json"

# 4. OCI image config. Minimal but valid: arch + os + rootfs diff_ids.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"architecture":"amd64","os":"linux","created":"%s","config":{"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]},"rootfs":{"type":"layers","diff_ids":["sha256:%s"]},"history":[{"created":"%s","created_by":"yolo export"}]}\n' \
  "$NOW" "$DIFF_ID" "$NOW" > cfg.json
CONFIG_HASH="$(sha256sum cfg.json | awk '{print $1}')"
mv cfg.json "${CONFIG_HASH}.json"

# 5. manifest.json + legacy repositories. The placeholder tag is replaced
#    at import time with a destination-local unique tag.
printf '[{"Config":"%s.json","RepoTags":["%s"],"Layers":["%s/layer.tar"]}]\n' \
  "$CONFIG_HASH" "$PLACEHOLDER" "$DIFF_ID" > manifest.json
PH_NAME="${PLACEHOLDER%:*}"
PH_VER="${PLACEHOLDER#*:}"
printf '{"%s":{"%s":"%s"}}\n' "$PH_NAME" "$PH_VER" "$DIFF_ID" > repositories

# 6. Pack the docker-save tarball.
tar -cf image.tar manifest.json repositories "${CONFIG_HASH}.json" "$DIFF_ID"
rm -rf "$DIFF_ID" "${CONFIG_HASH}.json" manifest.json repositories

# 7. Bundle yolo state + metadata.
mkdir state
if [ -n "$AP_PATH"  ] && [ -f "$AP_PATH"  ]; then cp "$AP_PATH"  "state/${NAME}.applied"; fi
if [ -n "$CWD_PATH" ] && [ -f "$CWD_PATH" ]; then cp "$CWD_PATH" "state/${NAME}.cwd";     fi
cp "$META_TMP" metadata.json

EXTRA=""
if [ -n "$YOLOFILE_SRC" ] && [ -f "$YOLOFILE_SRC" ]; then
  cp "$YOLOFILE_SRC" Yolofile
  EXTRA="Yolofile"
fi

# 8. Final compressed bundle.
tar -czf "$OUT" metadata.json image.tar state $EXTRA
echo "[yolo] wrote $(du -h "$OUT" | awk '{print $1}') → $OUT" >&2
