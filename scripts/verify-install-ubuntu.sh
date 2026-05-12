#!/usr/bin/env bash
# verify-install-ubuntu.sh — boot an Ubuntu 26.04 LTS cloud guest under
# QEMU/KVM and verify that web/install.sh installs matchlock + yolo
# end-to-end on a real KVM-capable host. This is the Ubuntu analogue of
# verify-install.sh and is intended to run on a Fedora host (or any host
# with /dev/kvm).
#
# Usage:
#   scripts/verify-install-ubuntu.sh                # uses web/install.sh, smoke-tests
#                                                   # a nested yolo microVM by default
#   scripts/verify-install-ubuntu.sh --install-sh path/to/install.sh
#   scripts/verify-install-ubuntu.sh --keep         # don't shut the VM down on exit
#   scripts/verify-install-ubuntu.sh --no-nested-yolo  # skip the nested microVM step
#
# Host requirements (same as the Fedora verifier):
#   - /dev/kvm readable+writable
#   - qemu-system-x86_64, cloud-localds (or genisoimage / xorriso), curl,
#     ssh, ssh-keygen
#   - kvm_intel.nested=1 (or kvm_amd.nested=1), default on modern kernels.

set -euo pipefail

# ---------------- Defaults ----------------
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

INSTALL_SH="${INSTALL_SH:-$ROOT/web/install.sh}"
UBUNTU_VERSION="${UBUNTU_VERSION:-26.04}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/yolo-verify}"
SSH_PORT="${SSH_PORT:-2223}"
MEM_MB="${MEM_MB:-4096}"
SMP="${SMP:-2}"
SSH_TIMEOUT="${SSH_TIMEOUT:-300}"
# Ubuntu cloud images ship a tiny ~2.3 GB rootfs, which is far too small to
# host a matchlock OCI cache + nested microVM rootfs. Grow the per-run overlay
# to this size; cloud-init's growpart + cloud-initramfs-growroot expand the
# partition on first boot.
DISK_SIZE="${DISK_SIZE:-16G}"
IMAGE=""
KEEP=0
NESTED_YOLO=1
LOCAL_YOLO=""

GUEST_USER="ubuntu"

# ---------------- Logging ----------------
if [ -t 1 ]; then
  C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
warn() { printf '%s==>%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s==>%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }

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
  --nested-yolo             Boot a yolo microVM inside the guest (default: on)
  --no-nested-yolo          Skip the nested yolo microVM smoke test
  --local-yolo PATH         After install.sh runs, overwrite the installed
                            yolo binary in the guest with this local one
                            (use 'auto' to build it from yolo.rugo via rugo).
  -h, --help                Show this help.

Environment overrides: INSTALL_SH, UBUNTU_VERSION, CACHE_DIR, SSH_PORT,
                       MEM_MB, SMP, SSH_TIMEOUT.

Note: the default SSH port (2223) differs from verify-install.sh (2222) so
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
    --local-yolo)      LOCAL_YOLO="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

# ---------------- Pre-flight ----------------
log "Pre-flight"
[ -r "$INSTALL_SH" ] || die "install.sh not found at $INSTALL_SH"
[ -e /dev/kvm ]      || die "/dev/kvm is missing — host does not support KVM"
[ -r /dev/kvm ] && [ -w /dev/kvm ] || die "no rw access to /dev/kvm (add yourself to the kvm group, log out and back in)"
for cmd in qemu-system-x86_64 curl ssh ssh-keygen scp; do
  command -v "$cmd" >/dev/null || die "missing required command: $cmd"
done
# We need *some* way to build a cloud-init NoCloud ISO. cloud-localds is the
# cleanest, but it's an extra dep on Fedora; fall back to genisoimage or
# xorriso, which are commonly present.
SEED_TOOL=""
for c in cloud-localds genisoimage xorriso; do
  if command -v "$c" >/dev/null; then SEED_TOOL="$c"; break; fi
done
[ -n "$SEED_TOOL" ] || die "need one of: cloud-localds (cloud-utils), genisoimage, or xorriso"

nested=""
if [ -r /sys/module/kvm_intel/parameters/nested ]; then
  nested="$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || true)"
elif [ -r /sys/module/kvm_amd/parameters/nested ]; then
  nested="$(cat /sys/module/kvm_amd/parameters/nested 2>/dev/null || true)"
fi
case "$nested" in
  Y|1) log "  nested virtualization: enabled" ;;
  *)   warn "  nested virtualization: disabled or unknown — matchlock inside the guest may not work" ;;
esac
log "  install.sh: $INSTALL_SH"

# ---------------- Image cache ----------------
mkdir -p "$CACHE_DIR"
# Ubuntu cloud images have a predictable filename, so no directory scrape needed.
IMAGE_URL="https://cloud-images.ubuntu.com/releases/${UBUNTU_VERSION}/release/ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
IMAGE_NAME_CACHED="ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
IMAGE="${IMAGE:-$CACHE_DIR/$IMAGE_NAME_CACHED}"
if [ ! -s "$IMAGE" ]; then
  log "Fetching Ubuntu $UBUNTU_VERSION cloud image"
  log "  $IMAGE_URL"
  curl -fL --proto '=https' --tlsv1.2 -o "$IMAGE.part" "$IMAGE_URL" \
    || die "failed to download $IMAGE_URL"
  mv "$IMAGE.part" "$IMAGE"
fi
log "  image: $IMAGE"

# ---------------- Workdir + cleanup ----------------
WORK="$(mktemp -d -t yolo-verify-ubuntu-XXXXXX)"
QEMU_PID_FILE="$WORK/qemu.pid"
SERIAL_LOG="$WORK/serial.log"

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "$KEEP" -eq 1 ]; then
    log "--keep: leaving VM running (pid $(cat "$QEMU_PID_FILE" 2>/dev/null || echo ?)) and work dir $WORK"
    log "  ssh -i $WORK/id -p $SSH_PORT -o StrictHostKeyChecking=no $GUEST_USER@127.0.0.1"
    exit "$rc"
  fi
  if [ -f "$QEMU_PID_FILE" ]; then
    local pid
    pid="$(cat "$QEMU_PID_FILE")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    rm -rf "$WORK"
  else
    warn "Non-zero exit ($rc); preserving work dir for inspection: $WORK"
    warn "  serial log: $SERIAL_LOG"
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ---------------- Ephemeral SSH key ----------------
ssh-keygen -t ed25519 -N '' -f "$WORK/id" -q
PUBKEY="$(cat "$WORK/id.pub")"

# ---------------- cloud-init seed ----------------
# Ubuntu cloud images ship with a default `ubuntu` user; we just attach our
# ephemeral pubkey to it and grant passwordless sudo.
#
# DNS workaround: when the host runs systemd-resolved (Fedora workstation
# default), the host's /etc/resolv.conf points to 127.0.0.53. QEMU's slirp DNS
# forwarder at 10.0.2.3 forwards to that loopback address, which it cannot
# reach — so the guest's DHCP-provided DNS server is silently dead. We fix it
# at the guest side by giving systemd-resolved a public fallback resolver and
# restarting it before anything else runs.
cat > "$WORK/user-data" <<EOF
#cloud-config
ssh_pwauth: false
users:
  - default
  - name: $GUEST_USER
    ssh_authorized_keys:
      - $PUBKEY
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
write_files:
  - path: /etc/systemd/resolved.conf.d/99-yolo-verify.conf
    content: |
      [Resolve]
      DNS=1.1.1.1 8.8.8.8
      FallbackDNS=9.9.9.9 1.0.0.1
runcmd:
  - [ systemctl, restart, systemd-resolved ]
EOF
echo 'instance-id: yolo-verify-ubuntu' > "$WORK/meta-data"

make_seed_iso() {
  local out="$1"
  case "$SEED_TOOL" in
    cloud-localds)
      cloud-localds "$out" "$WORK/user-data" "$WORK/meta-data"
      ;;
    genisoimage)
      genisoimage -quiet -output "$out" -volid cidata -joliet -rock \
        -graft-points "user-data=$WORK/user-data" "meta-data=$WORK/meta-data"
      ;;
    xorriso)
      xorriso -as mkisofs -output "$out" -volid cidata -joliet -rock \
        -graft-points "user-data=$WORK/user-data" "meta-data=$WORK/meta-data" >/dev/null
      ;;
  esac
}
make_seed_iso "$WORK/seed.iso"

# ---------------- Per-run disk overlay (resized) ----------------
# Ubuntu cloud images ship with a small rootfs (~2.3 GB) and we need plenty
# of headroom for the matchlock OCI cache + nested microVM rootfs. Create a
# qcow2 overlay backed by the cached base image and grow it to DISK_SIZE.
# cloud-init's growpart will expand the partition on first boot.
DISK="$WORK/disk.qcow2"
log "Preparing per-run disk overlay (size=$DISK_SIZE) at $DISK"
qemu-img create -q -f qcow2 -F qcow2 -b "$IMAGE" "$DISK" >/dev/null \
  || die "qemu-img create overlay failed"
qemu-img resize -q "$DISK" "$DISK_SIZE" >/dev/null \
  || die "qemu-img resize failed"

# ---------------- Boot ----------------
log "Booting Ubuntu $UBUNTU_VERSION VM (mem=${MEM_MB}MB, smp=$SMP, ssh port $SSH_PORT)"
qemu-system-x86_64 \
  -name yolo-verify-ubuntu \
  -enable-kvm -cpu host -m "$MEM_MB" -smp "$SMP" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -drive file="$WORK/seed.iso",if=virtio,format=raw \
  -netdev user,id=n,hostfwd=tcp::"${SSH_PORT}"-:22 -device virtio-net,netdev=n \
  -serial file:"$SERIAL_LOG" \
  -display none \
  -daemonize -pidfile "$QEMU_PID_FILE"

# ---------------- Wait for SSH ----------------
SSH_OPTS=(
  -i "$WORK/id"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=5
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=20
  -p "$SSH_PORT"
)
log "Waiting for SSH on port $SSH_PORT (up to ${SSH_TIMEOUT}s)…"
deadline=$(( $(date +%s) + SSH_TIMEOUT ))
while :; do
  if ssh "${SSH_OPTS[@]}" "$GUEST_USER@127.0.0.1" true 2>/dev/null; then
    break
  fi
  if [ "$(date +%s)" -gt "$deadline" ] || ! kill -0 "$(cat "$QEMU_PID_FILE")" 2>/dev/null; then
    warn "Serial log tail:"
    tail -n 50 "$SERIAL_LOG" >&2 || true
    die "SSH never came up"
  fi
  sleep 2
done
log "  SSH reachable"

run_ssh() {
  # We intentionally pass literal commands; client-side expansion is OK.
  # shellcheck disable=SC2029
  ssh "${SSH_OPTS[@]}" "$GUEST_USER@127.0.0.1" "$@"
}

# Cloud-init on Ubuntu cloud images runs an apt-update / unattended-upgrades
# phase right after boot. If install.sh races with it, dpkg/apt will fail with
# "Could not get lock /var/lib/dpkg/lock-frontend". Block until cloud-init is
# done so the subsequent `apt-get` calls inside install.sh are unblocked.
log "Waiting for cloud-init to finish (releases the apt/dpkg lock)"
run_ssh 'sudo cloud-init status --wait' >/dev/null \
  || die "cloud-init did not reach 'done' state"

# ---------------- Copy + run install.sh ----------------
log "Copying install.sh into the guest"
scp -P "$SSH_PORT" -i "$WORK/id" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "$INSTALL_SH" "$GUEST_USER@127.0.0.1:/tmp/install.sh" >/dev/null

log "Running install.sh inside the guest (this will install matchlock + yolo)"
run_ssh 'bash /tmp/install.sh'

# ---------------- Optional: override yolo with a local build ----------------
if [ -n "$LOCAL_YOLO" ]; then
  if [ "$LOCAL_YOLO" = "auto" ]; then
    log "Building yolo locally from $ROOT/yolo.rugo via rugo"
    command -v rugo >/dev/null \
      || die "rugo not found on PATH; install it (https://github.com/rubiojr/rugo) or pass --local-yolo PATH"
    ( cd "$ROOT" && rugo build yolo.rugo ) \
      || die "rugo build yolo.rugo failed"
    LOCAL_YOLO="$ROOT/yolo"
  fi
  [ -x "$LOCAL_YOLO" ] || die "local yolo binary not found or not executable: $LOCAL_YOLO"
  log "Overwriting installed yolo with local build: $LOCAL_YOLO"
  scp -P "$SSH_PORT" -i "$WORK/id" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$LOCAL_YOLO" "$GUEST_USER@127.0.0.1:/tmp/yolo-local" >/dev/null
  run_ssh 'install -m 0755 /tmp/yolo-local "$HOME/.local/bin/yolo" && rm -f /tmp/yolo-local'
fi

# ---------------- Verify ----------------
log "Verifying binaries are present"
run_ssh 'set -e
  ls -l /dev/kvm
  command -v matchlock
  command -v ~/.local/bin/yolo || command -v yolo
  matchlock --version
  ~/.local/bin/yolo --help >/dev/null 2>&1 || yolo --help >/dev/null
'

log "Running 'sudo matchlock setup linux' and enrolling the $GUEST_USER user"
run_ssh "sudo matchlock setup linux && sudo matchlock setup user $GUEST_USER"

log "Running 'matchlock diagnose' (fresh SSH session picks up new group membership)"
run_ssh 'matchlock diagnose'

if [ "$NESTED_YOLO" -eq 1 ]; then
  log "Booting a nested yolo microVM and running 'uname -a' inside it"
  log "  (first boot downloads a kernel + rootfs; this can take a few minutes)"
  # Run from a fresh empty dir so yolo uses its built-in defaults (no project
  # Yolofile is auto-detected). $HOME and $$ must expand on the guest, not
  # the host — single-quoted heredoc is intentional. Cleanup removes the
  # auto-named CWD-derived VM after the test.
  #
  # We tee both stdout and stderr to a file so the user sees yolo's progress
  # messages live ("[yolo] starting fedora:44 VM", "[yolo] waiting for
  # matchlock exec socket…") while we still get the captured output for
  # post-run assertions. Pure `$()` capture hides progress and makes long
  # first-boot image pulls look indistinguishable from a hang.
  nested_out_file="$WORK/nested.out"
  # shellcheck disable=SC2016
  if ! run_ssh '
    set -euo pipefail
    rm -rf /tmp/yolo-nested
    mkdir -p /tmp/yolo-nested
    cd /tmp/yolo-nested
    YOLO=$HOME/.local/bin/yolo
    cleanup() { (cd /tmp/yolo-nested && "$YOLO" rm) >/dev/null 2>&1 || true; }
    trap cleanup EXIT
    "$YOLO" --no-provision -- sh -c "uname -a; echo NESTED_OK_$$"
  ' 2>&1 | tee "$nested_out_file"; then
    die "nested yolo smoke test failed (see output above)"
  fi
  nested_out="$(cat "$nested_out_file")"
  echo "$nested_out" | grep -q '^Linux ' \
    || die "nested yolo did not produce a Linux uname line"
  echo "$nested_out" | grep -q '^NESTED_OK_' \
    || die "nested yolo command did not run to completion"
  log "  nested yolo microVM ran successfully"
else
  log "Skipping nested yolo smoke test (--no-nested-yolo)"
fi

log "All checks passed."
