#!/usr/bin/env bash
# build-kernels.sh — build yolo guest kernels with podman.
#
# Compiles minimal Linux kernels (arm64 + x86_64) with the full Docker/Podman
# netfilter stack enabled (see guest/kernel/{arm64,x86_64}.config) and drops the
# raw kernel binaries into tmp/kernels/:
#
#   tmp/kernels/kernel         # x86_64 vmlinux  (Firecracker / KVM)
#   tmp/kernels/kernel-arm64   # arm64  Image    (Virtualization.framework)
#
# Both filenames match matchlock's kernel-cache layout, so an artifact can be
# handed straight to matchlock, e.g.:
#   matchlock run --kernel "file://$PWD/tmp/kernels/kernel-arm64" ...
#
# Uses `podman` (not docker). Because podman on macOS runs in *remote* mode —
# which does not support `build --output type=local` — the kernel binary is
# extracted from the built `scratch` image via `podman create` + `podman cp`
# rather than a BuildKit local export.
#
# Usage:
#   scripts/build-kernels.sh                 # both arches -> tmp/kernels
#   ARCH=arm64  scripts/build-kernels.sh     # arm64 only
#   ARCH=x86_64 scripts/build-kernels.sh     # x86_64 only
#   KERNEL_VERSION=6.19.8 scripts/build-kernels.sh
#   OUTPUT_DIR=/some/dir  scripts/build-kernels.sh
#
# Environment:
#   ARCH                  x86_64 | arm64 | all   (default: all)
#   KERNEL_VERSION        kernel version to build (default: 6.19.8)
#   KERNEL_SOURCE_VERSION override kernel.org tarball version (default: derived)
#   OUTPUT_DIR            output directory        (default: <repo>/tmp/kernels)
#   PODMAN                podman binary           (default: podman)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KERNEL_DIR="$REPO_ROOT/guest/kernel"

ARCH="${ARCH:-all}"
KERNEL_VERSION="${KERNEL_VERSION:-6.19.8}"
KERNEL_SOURCE_VERSION="${KERNEL_SOURCE_VERSION:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/tmp/kernels}"
PODMAN="${PODMAN:-podman}"
IMAGE_REPO="localhost/yolo-guest-kernel"

log() { printf '\033[2m[build-kernels]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[build-kernels] %s\033[0m\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
    cat <<'EOF'
build-kernels.sh — build yolo guest kernels (arm64 + x86_64) with podman.

Drops raw kernel binaries into tmp/kernels/:
  tmp/kernels/kernel         x86_64 vmlinux  (Firecracker / KVM)
  tmp/kernels/kernel-arm64   arm64  Image    (Virtualization.framework)

Usage:
  scripts/build-kernels.sh                 # both arches -> tmp/kernels
  ARCH=arm64  scripts/build-kernels.sh     # arm64 only
  ARCH=x86_64 scripts/build-kernels.sh     # x86_64 only
  KERNEL_VERSION=6.19.8 scripts/build-kernels.sh
  OUTPUT_DIR=/some/dir  scripts/build-kernels.sh

Environment:
  ARCH                  x86_64 | arm64 | all   (default: all)
  KERNEL_VERSION        kernel version          (default: 6.19.8)
  KERNEL_SOURCE_VERSION kernel.org tarball ver  (default: derived)
  OUTPUT_DIR            output directory         (default: <repo>/tmp/kernels)
  PODMAN                podman binary            (default: podman)
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

command -v "$PODMAN" >/dev/null 2>&1 \
    || die "podman not found on PATH (set \$PODMAN to override)"
[ -f "$KERNEL_DIR/Dockerfile" ] || die "missing $KERNEL_DIR/Dockerfile"

# build_arch <arch> <target-stage> <src-path-in-image> <output-filename>
build_arch() {
    local arch="$1" target="$2" src="$3" dest="$4"
    local tag="$IMAGE_REPO:$arch"
    local cid=""

    log "building $arch kernel (KERNEL_VERSION=$KERNEL_VERSION) via podman…"
    "$PODMAN" build \
        --build-arg KERNEL_VERSION="$KERNEL_VERSION" \
        --build-arg KERNEL_SOURCE_VERSION="$KERNEL_SOURCE_VERSION" \
        --target "$target" \
        -t "$tag" \
        -f "$KERNEL_DIR/Dockerfile" \
        "$KERNEL_DIR" \
        || die "podman build failed for $arch"

    # podman remote mode (macOS) has no `build --output type=local`, so extract
    # the single kernel file from the scratch image with a throwaway container.
    # The `create` command argument is never executed — it only satisfies
    # podman's requirement that a container have a command.
    log "extracting $src -> $OUTPUT_DIR/$dest"
    cid="$("$PODMAN" create "$tag" "$src" 2>/dev/null)" \
        || die "podman create failed for $tag"
    if ! "$PODMAN" cp "$cid:$src" "$OUTPUT_DIR/$dest"; then
        "$PODMAN" rm -f "$cid" >/dev/null 2>&1 || true
        die "podman cp failed ($cid:$src)"
    fi
    "$PODMAN" rm -f "$cid" >/dev/null 2>&1 || true

    # Checksum sidecar, shipped next to the kernel as a release asset. yolo
    # verifies the auto-download against it. `sha256sum` on Linux, `shasum` on
    # macOS; cd into OUTPUT_DIR so the recorded filename is bare (no path).
    ( cd "$OUTPUT_DIR" \
        && { command -v sha256sum >/dev/null 2>&1 && sha256sum "$dest" || shasum -a 256 "$dest"; } \
        > "$dest.sha256" )

    log "built $OUTPUT_DIR/$dest ($(du -h "$OUTPUT_DIR/$dest" | cut -f1)) + $dest.sha256"
}

mkdir -p "$OUTPUT_DIR"

log "============================================"
log "yolo guest kernel builder (podman)"
log "  version:    $KERNEL_VERSION"
log "  arch:       $ARCH"
log "  output:     $OUTPUT_DIR"
log "  dockerfile: $KERNEL_DIR/Dockerfile"
log "============================================"

case "$ARCH" in
    x86_64 | amd64)  build_arch x86_64 output-x86_64 /kernel       kernel ;;
    arm64 | aarch64) build_arch arm64  output-arm64  /kernel-arm64 kernel-arm64 ;;
    all)
        build_arch x86_64 output-x86_64 /kernel       kernel
        build_arch arm64  output-arm64  /kernel-arm64 kernel-arm64
        ;;
    *) die "unsupported ARCH: $ARCH (want: x86_64 | arm64 | all)" ;;
esac

log "done. kernels in: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
