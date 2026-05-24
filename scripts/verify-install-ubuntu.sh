#!/usr/bin/env bash
# verify-install-ubuntu.sh — boot an Ubuntu 26.04 LTS cloud guest under
# QEMU/KVM and verify that web/install.sh installs matchlock + yolo
# end-to-end on a real KVM-capable host.
#
# Most of the logic lives in scripts/verify-util.sh; this wrapper just
# parses Ubuntu-specific args, downloads the Ubuntu cloud image, sets up
# Ubuntu-specific cloud-init customisations, and hands off to verify_main.
#
# Usage:
#   scripts/verify-install-ubuntu.sh                 # smoke-tests matchlock + podman
#   scripts/verify-install-ubuntu.sh --install-sh path/to/install.sh
#   scripts/verify-install-ubuntu.sh --keep          # don't shut the VM down on exit
#   scripts/verify-install-ubuntu.sh --no-nested-yolo  # skip matchlock smoke test
#   scripts/verify-install-ubuntu.sh --no-podman-yolo  # skip podman smoke test
#
# Host requirements (same as the Fedora verifier):
#   - /dev/kvm readable+writable
#   - qemu-system-x86_64, cloud-localds (or genisoimage / xorriso), curl,
#     ssh, ssh-keygen, rugo
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
DISTRO="ubuntu"
GUEST_USER="ubuntu"
INSTALL_SH="${INSTALL_SH:-$ROOT/web/install.sh}"
UBUNTU_VERSION="${UBUNTU_VERSION:-26.04}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/yolo-verify}"
# Default SSH port differs from verify-install.sh (2222) so the two
# verifiers can run side by side without colliding.
SSH_PORT="${SSH_PORT:-2223}"
MEM_MB="${MEM_MB:-4096}"
SMP="${SMP:-2}"
SSH_TIMEOUT="${SSH_TIMEOUT:-300}"
IMAGE=""
KEEP=0
NESTED_YOLO=1
PODMAN_YOLO=1

# Ubuntu cloud images ship a tiny ~2.3 GB rootfs, far too small to host
# the union of: apt cache + matchlock + Firecracker + a nested microVM
# rootfs (32 GB sparse by yolo's default) + podman storage + the
# fedora-toolbox:44 image (~600 MB). 24 GB has held up to both the
# matchlock and podman smoke tests on a single run with comfortable
# headroom. cloud-init's growpart + cloud-initramfs-growroot expand
# the partition on first boot.
DISK_SIZE="${DISK_SIZE:-24G}"

# DNS workaround for Ubuntu cloud images: when the *host* runs
# systemd-resolved (Fedora workstation default), the host's
# /etc/resolv.conf points to 127.0.0.53. QEMU's slirp DNS forwarder at
# 10.0.2.3 forwards to that loopback address, which it can't reach — so
# the guest's DHCP-provided DNS server is silently dead. We fix it
# guest-side by giving systemd-resolved a public fallback resolver and
# restarting it before anything else runs.
#
# This is merged verbatim into the user-data the shared util writes
# (after the users: block, so we can introduce new top-level keys).
CLOUD_INIT_EXTRA='write_files:
  - path: /etc/systemd/resolved.conf.d/99-yolo-verify.conf
    content: |
      [Resolve]
      DNS=1.1.1.1 8.8.8.8
      FallbackDNS=9.9.9.9 1.0.0.1
runcmd:
  - [ systemctl, restart, systemd-resolved ]'

# shellcheck source=verify-util.sh
. "$HERE/verify-util.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --install-sh PATH         Path to install.sh under test (default: $INSTALL_SH)
  --image PATH              Pre-downloaded Ubuntu cloud .img (skip download)
  --ubuntu-version VER      Ubuntu release (default: $UBUNTU_VERSION)
  --port PORT               Host SSH forward port (default: $SSH_PORT)
  --mem MB                  Guest memory (default: $MEM_MB)
  --smp N                   Guest vCPUs (default: $SMP)
  --keep                    Don't shut the VM down on exit (debug)
  --nested-yolo             Run the matchlock smoke test (default: on)
  --no-nested-yolo          Skip the matchlock smoke test
  --podman-yolo             Run the podman smoke test (default: on)
  --no-podman-yolo          Skip the podman smoke test
  -h, --help                Show this help.

Environment overrides: INSTALL_SH, UBUNTU_VERSION, CACHE_DIR, SSH_PORT,
                       MEM_MB, SMP, SSH_TIMEOUT, DISK_SIZE.

Note: yolo is always rebuilt from yolo.rugo and the local binary is
what gets tested inside the guest. \`rugo\` must be on PATH.

The default SSH port (2223) differs from verify-install.sh (2222) so
the two verifiers can run side by side without colliding.
EOF
}

# ---------------- Arg parsing ----------------
while [ $# -gt 0 ]; do
    case "$1" in
        --install-sh)      INSTALL_SH="$2"; shift 2 ;;
        --image)           IMAGE="$2"; shift 2 ;;
        --ubuntu-version)  UBUNTU_VERSION="$2"; shift 2 ;;
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

# ---------------- Image cache (Ubuntu-specific) ----------------
# Ubuntu cloud images have a predictable filename — no scrape needed.
fetch_ubuntu_image() {
    mkdir -p "$CACHE_DIR"
    local image_url="https://cloud-images.ubuntu.com/releases/${UBUNTU_VERSION}/release/ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
    local image_name_cached="ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
    IMAGE="${IMAGE:-$CACHE_DIR/$image_name_cached}"
    if [ -s "$IMAGE" ]; then
        return 0
    fi
    log "Fetching Ubuntu $UBUNTU_VERSION cloud image"
    log "  $image_url"
    curl -fL --proto '=https' --tlsv1.2 -o "$IMAGE.part" "$image_url" \
        || die "failed to download $image_url"
    mv "$IMAGE.part" "$IMAGE"
}

fetch_ubuntu_image

verify_main
