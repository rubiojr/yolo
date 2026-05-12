#!/usr/bin/env bash
# verify-install.sh — boot a Fedora cloud guest under QEMU/KVM and verify
# that web/install.sh installs matchlock + yolo end-to-end on a *real*
# KVM-capable host (which a matchlock microVM is not — see Firecracker's
# CPU template, which masks VMX/SVM).
#
# Usage:
#   scripts/verify-install.sh                 # uses web/install.sh (smoke-tests
#                                             # a nested yolo microVM by default)
#   scripts/verify-install.sh --install-sh path/to/install.sh
#   scripts/verify-install.sh --keep          # don't shut the VM down on exit
#   scripts/verify-install.sh --no-nested-yolo  # skip the nested microVM step
#
# Host requirements:
#   - /dev/kvm readable+writable
#   - qemu-system-x86_64, cloud-localds (cloud-utils on Debian/Ubuntu,
#     cloud-utils on Fedora), curl, ssh, ssh-keygen
#   - kvm_intel.nested=1 (or kvm_amd.nested=1), default on modern kernels.

set -euo pipefail

# ---------------- Defaults ----------------
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

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
LOCAL_YOLO=""

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
  --image PATH              Pre-downloaded Fedora cloud qcow2 (skip download)
  --fedora-version VER      Fedora release (default: $FEDORA_VERSION)
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

Environment overrides: INSTALL_SH, FEDORA_VERSION, CACHE_DIR, SSH_PORT,
                       MEM_MB, SMP, SSH_TIMEOUT.
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
# Fedora's per-release Cloud image filename includes a minor revision
# (e.g. Fedora-Cloud-Base-Generic-44-1.5.x86_64.qcow2) that changes with
# each respin, so we scrape the directory listing to discover it.
#
# Use dl.fedoraproject.org (master mirror) as the primary source: it always
# serves Apache-style HTML directory listings. download.fedoraproject.org
# is a redirector that hands you off to a geo-selected mirror — and many of
# those mirrors do NOT serve directory listings (or serve a different HTML
# format), which makes the scrape fail unpredictably (e.g. on GitHub-hosted
# runners). We fall back to download.fedoraproject.org if the master is
# unreachable.
IMAGE_DIR_PRIMARY="https://dl.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Cloud/x86_64/images/"
IMAGE_DIR_FALLBACK="https://download.fedoraproject.org/pub/fedora/linux/releases/${FEDORA_VERSION}/Cloud/x86_64/images/"
IMAGE_NAME_CACHED="Fedora-Cloud-Base-Generic-${FEDORA_VERSION}.qcow2"
IMAGE="${IMAGE:-$CACHE_DIR/$IMAGE_NAME_CACHED}"

# scrape_listing URL  → echoes a matching Fedora-Cloud-Base-...qcow2 filename, or empty
scrape_listing() {
  local url="$1"
  curl -fsSL --proto '=https' --tlsv1.2 \
    --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
    -A 'yolo-verify/1.0 (+https://github.com/rubiojr/yolo)' \
    --max-time 60 \
    "$url" \
    | sed -nE 's/.*href="(Fedora-Cloud-Base[^"]*\.x86_64\.qcow2)".*/\1/p' \
    | sort -u | head -n1
}

if [ ! -s "$IMAGE" ]; then
  log "Discovering Fedora $FEDORA_VERSION cloud image filename"
  IMAGE_DIR_URL="$IMAGE_DIR_PRIMARY"
  REMOTE_NAME="$(scrape_listing "$IMAGE_DIR_URL" || true)"
  if [ -z "$REMOTE_NAME" ]; then
    warn "  primary mirror returned no match: $IMAGE_DIR_PRIMARY"
    IMAGE_DIR_URL="$IMAGE_DIR_FALLBACK"
    REMOTE_NAME="$(scrape_listing "$IMAGE_DIR_URL" || true)"
  fi
  if [ -z "$REMOTE_NAME" ]; then
    warn "  fallback mirror returned no match: $IMAGE_DIR_FALLBACK"
    warn "  (first 500 bytes of the fallback response for debugging:)"
    curl -fsSL --max-time 30 -A 'yolo-verify/1.0' "$IMAGE_DIR_FALLBACK" 2>/dev/null | head -c 500 >&2 || true
    echo >&2
    die "couldn't find a Fedora cloud .qcow2 (tried $IMAGE_DIR_PRIMARY and $IMAGE_DIR_FALLBACK; pass --image to override)"
  fi
  log "  fetching $REMOTE_NAME"
  curl -fL --proto '=https' --tlsv1.2 \
    --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
    -A 'yolo-verify/1.0' \
    -o "$IMAGE.part" "${IMAGE_DIR_URL}${REMOTE_NAME}" \
    || die "failed to download $IMAGE_DIR_URL$REMOTE_NAME"
  mv "$IMAGE.part" "$IMAGE"
fi
log "  image: $IMAGE"

# ---------------- Workdir + cleanup ----------------
WORK="$(mktemp -d -t yolo-verify-XXXXXX)"
QEMU_PID_FILE="$WORK/qemu.pid"
SERIAL_LOG="$WORK/serial.log"

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "$KEEP" -eq 1 ]; then
    log "--keep: leaving VM running (pid $(cat "$QEMU_PID_FILE" 2>/dev/null || echo ?)) and work dir $WORK"
    log "  ssh -i $WORK/id -p $SSH_PORT -o StrictHostKeyChecking=no fedora@127.0.0.1"
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
cat > "$WORK/user-data" <<EOF
#cloud-config
ssh_pwauth: false
users:
  - default
  - name: fedora
    ssh_authorized_keys:
      - $PUBKEY
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
EOF
echo 'instance-id: yolo-verify' > "$WORK/meta-data"

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

# ---------------- Boot ----------------
log "Booting Fedora $FEDORA_VERSION VM (mem=${MEM_MB}MB, smp=$SMP, ssh port $SSH_PORT)"
qemu-system-x86_64 \
  -name yolo-verify \
  -enable-kvm -cpu host -m "$MEM_MB" -smp "$SMP" \
  -drive file="$IMAGE",if=virtio,snapshot=on \
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
  if ssh "${SSH_OPTS[@]}" fedora@127.0.0.1 true 2>/dev/null; then
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
  ssh "${SSH_OPTS[@]}" fedora@127.0.0.1 "$@"
}

# ---------------- Copy + run install.sh ----------------
log "Copying install.sh into the guest"
scp -P "$SSH_PORT" -i "$WORK/id" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "$INSTALL_SH" fedora@127.0.0.1:/tmp/install.sh >/dev/null

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
    "$LOCAL_YOLO" fedora@127.0.0.1:/tmp/yolo-local >/dev/null
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

log "Running 'sudo matchlock setup linux' and enrolling the fedora user"
run_ssh 'sudo matchlock setup linux && sudo matchlock setup user fedora'

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
