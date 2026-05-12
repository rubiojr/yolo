#!/usr/bin/env bash
# Host-side helper invoked by `yolo import`.
#
# Reads from environment:
#   WORK   absolute path to an empty tempdir to extract into
#   ABS    absolute path to the .tar.gz archive
#
# Extracts the archive (hardened against path traversal) and verifies that
# only whitelisted top-level entries are present, plus required files.
set -euo pipefail

: "${WORK:?WORK required}"
: "${ABS:?ABS required}"

cd "$WORK"
tar --no-same-owner --no-absolute-names -xzf "$ABS"

# Whitelist of allowed top-level entries.
for entry in *; do
  case "$entry" in
    metadata.json|image.tar|state|Yolofile) : ;;
    *) echo "[yolo] unexpected archive entry: $entry" >&2; exit 2 ;;
  esac
done

test -f metadata.json
test -f image.tar
