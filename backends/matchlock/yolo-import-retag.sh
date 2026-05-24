#!/usr/bin/env bash
# Host-side helper invoked by `yolo import`.
#
# Reads from environment:
#   WORK         absolute path to the extracted bundle dir
#   PLACEHOLDER  placeholder image tag baked in at export time
#   TAG          destination-local image tag to register with matchlock
#
# Re-tags the docker-save image.tar from PLACEHOLDER to TAG, then hands it
# to `matchlock image import`.
set -euo pipefail

: "${WORK:?WORK required}"
: "${PLACEHOLDER:?PLACEHOLDER required}"
: "${TAG:?TAG required}"

cd "$WORK"
mkdir img
tar -xf image.tar -C img
cd img

PH_NAME="${PLACEHOLDER%:*}"
PH_VER="${PLACEHOLDER#*:}"
TAG_NAME="${TAG%:*}"
TAG_VER="${TAG#*:}"

# manifest.json: a single placeholder; safe sed substitution.
sed -i "s|\"${PLACEHOLDER}\"|\"${TAG}\"|g" manifest.json

# repositories: rewrite from scratch using the existing layer-id ref.
LAYER_ID="$(grep -oE '[0-9a-f]{64}' repositories | head -1)"
if [ -z "$LAYER_ID" ]; then
  echo "[yolo] could not parse layer id from repositories" >&2
  exit 2
fi
printf '{"%s":{"%s":"%s"}}\n' "$TAG_NAME" "$TAG_VER" "$LAYER_ID" > repositories

tar -cf ../image.retagged.tar *
cd ..
mv image.retagged.tar image.tar

echo "[yolo] importing image $TAG" >&2
matchlock image import "$TAG" < image.tar
