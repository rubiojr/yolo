#!/usr/bin/env bash
# verify-install.sh — boot a Fedora cloud guest under QEMU/KVM and verify
# that web/install.sh installs matchlock + yolo end-to-end on a *real*
# KVM-capable host (which a matchlock microVM is not — see Firecracker's
# CPU template, which masks VMX/SVM).
#
# Most of the logic lives in scripts/verify-util.sh; this wrapper just
# parses Fedora-specific args, fetches the Fedora cloud image, then
# hands off to verify_main.
#
# Usage:
#   scripts/verify-install.sh                       # smoke-tests matchlock + podman
#   scripts/verify-install.sh --install-sh path/to/install.sh
#   scripts/verify-install.sh --keep                # don't shut the VM down on exit
#   scripts/verify-install.sh --no-nested-yolo      # skip matchlock smoke test
#   scripts/verify-install.sh --no-podman-yolo      # skip podman smoke test
#
# Host requirements:
#   - /dev/kvm readable+writable
#   - qemu-system-x86_64, cloud-localds (or genisoimage / xorriso),
#     curl, ssh, ssh-keygen, rugo
#   - kvm_intel.nested=1 (or kvm_amd.nested=1) — default on modern kernels.
#
# Note: the verify scripts always rebuild yolo from yolo.rugo and use
# that binary inside the guest. install.sh's behaviour is still
# verified end-to-end (it runs first), but the runtime smoke tests
# exercise your working-tree yolo, not the published binary.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ---------------- Defaults ----------------
DISTRO="fedora"
GUEST_USER="fedora"
INSTALL_SH="${INSTALL_SH:-$ROOT/web/install.sh}"
FEDORA_VERSION="${FEDORA_VERSION:-44}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/yolo-verify}"
SSH_PORT="${SSH_PORT:-2222}"
MEM_MB="${MEM_MB:-4096}"
SMP="${SMP:-2}"
SSH_TIMEOUT="${SSH_TIMEOUT:-300}"
IMAGE=""
KEEP=0
NESTED_YOLO=1
PODMAN_YOLO=1

# Fedora's stock cloud image is roomy enough for the matchlock cache
# (~150 MB) plus a nested microVM rootfs (~5 GB), so we don't resize.
DISK_SIZE=""

# Fedora has no cloud-init customisation needs beyond the common pubkey
# / sudo / shell setup verify-util provides.
CLOUD_INIT_EXTRA=""

# shellcheck source=verify-util.sh
. "$HERE/verify-util.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --install-sh PATH         Path to install.sh under test (default: $INSTALL_SH)
  --image PATH              Pre-downloaded Fedora cloud qcow2 (skip download)
  --fedora-version VER      Fedora release (default: $FEDORA_VERSION)
  --port PORT               Host SSH forward port (default: $SSH_PORT)
  --mem MB                  Guest memory (default: $MEM_MB)
  --smp N                   Guest vCPUs (default: $SMP)
  --keep                    Don't shut the VM down on exit (debug)
  --nested-yolo             Run the matchlock smoke test (default: on)
  --no-nested-yolo          Skip the matchlock smoke test
  --podman-yolo             Run the podman smoke test (default: on)
  --no-podman-yolo          Skip the podman smoke test
  -h, --help                Show this help.

Environment overrides: INSTALL_SH, FEDORA_VERSION, CACHE_DIR, SSH_PORT,
                       MEM_MB, SMP, SSH_TIMEOUT.

Note: yolo is always rebuilt from yolo.rugo and the local binary is
what gets tested inside the guest. \`rugo\` must be on PATH.
EOF
}

# ---------------- Arg parsing ----------------
while [ $# -gt 0 ]; do
    case "$1" in
        --install-sh)      INSTALL_SH="$2"; shift 2 ;;
        --image)           IMAGE="$2"; shift 2 ;;
        --fedora-version)  FEDORA_VERSION="$2"; shift 2 ;;
        --port)            SSH_PORT="$2"; shift 2 ;;
        --mem)             MEM_MB="$2"; shift 2 ;;
        --smp)             SMP="$2"; shift 2 ;;
        --keep)            KEEP=1; shift ;;
        --nested-yolo)     NESTED_YOLO=1; shift ;;
        --no-nested-yolo)  NESTED_YOLO=0; shift ;;
        --podman-yolo)     PODMAN_YOLO=1; shift ;;
        --no-podman-yolo)  PODMAN_YOLO=0; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) die "unknown arg: $1 (try --help)" ;;
    esac
done

# ---------------- Image cache (Fedora-specific) ----------------
# Fedora's per-release Cloud image filename includes a minor revision
# (e.g. Fedora-Cloud-Base-Generic-44-1.5.x86_64.qcow2) that changes with
# each respin, so we scrape the directory listing to discover it.
#
# dl.fedoraproject.org (master mirror) always serves Apache-style HTML
# directory listings. download.fedoraproject.org is a redirector that
# hands you off to a geo-selected mirror — and many of those mirrors do
# NOT serve directory listings (or serve a different HTML format), which
# makes the scrape fail unpredictably (e.g. on GitHub-hosted runners).
# Fall back to the redirector only if the master is unreachable.
fetch_fedora_image() {
    mkdir -p "$CACHE_DIR"
    local image_dir_primary="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Cloud/x86_64/images/"
    local image_dir_fallback="https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Cloud/x86_64/images/"
    local image_name_cached="Fedora-Cloud-Base-Generic-${FEDORA_VERSION}.qcow2"
    IMAGE="${IMAGE:-$CACHE_DIR/$image_name_cached}"

    if [ -s "$IMAGE" ]; then
        return 0
    fi

    log "Discovering Fedora $FEDORA_VERSION cloud image filename"
    local image_dir_url="$image_dir_primary"
    local remote_name
    remote_name="$(_scrape_fedora_listing "$image_dir_url" || true)"
    if [ -z "$remote_name" ]; then
        warn "  primary mirror returned no match: $image_dir_primary"
        image_dir_url="$image_dir_fallback"
        remote_name="$(_scrape_fedora_listing "$image_dir_url" || true)"
    fi
    if [ -z "$remote_name" ]; then
        warn "  fallback mirror returned no match: $image_dir_fallback"
        warn "  (first 500 bytes of the fallback response for debugging:)"
        curl -fsSL --max-time 30 -A 'yolo-verify/1.0' "$image_dir_fallback" 2>/dev/null | head -c 500 >&2 || true
        echo >&2
        die "couldn't find a Fedora cloud .qcow2 (tried $image_dir_primary and $image_dir_fallback; pass --image to override)"
    fi
    log "  fetching $remote_name"
    curl -fL --proto '=https' --tlsv1.2 \
        --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
        -A 'yolo-verify/1.0' \
        -o "$IMAGE.part" "${image_dir_url}${remote_name}" \
        || die "failed to download ${image_dir_url}${remote_name}"
    mv "$IMAGE.part" "$IMAGE"
}

_scrape_fedora_listing() {
    local url="$1"
    curl -fsSL --proto '=https' --tlsv1.2 \
        --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
        -A 'yolo-verify/1.0 (+https://github.com/rubiojr/yolo)' \
        --max-time 60 \
        "$url" \
        | sed -nE 's/.*href="(Fedora-Cloud-Base[^"]*\.x86_64\.qcow2)".*/\1/p' \
        | sort -u | head -n1
}

fetch_fedora_image

verify_main
