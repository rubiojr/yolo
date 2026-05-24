#!/usr/bin/env bash
# verify-util.sh — shared logic for verify-install.sh and
# verify-install-ubuntu.sh. Sourced by both; provides functions but
# does not execute anything on its own.
#
# Contract: the sourcing script populates a small set of globals (DISTRO,
# GUEST_USER, image-discovery configuration, port defaults), and then
# calls `verify_main`. The orchestration order — pre-flight, boot, SSH
# wait, install.sh, optional yolo overwrite, matchlock setup/diagnose,
# nested-yolo smoke tests — lives here so both verifiers stay in lock
# step.
#
# Required globals (set by the sourcing wrapper):
#   ROOT             absolute path to the repo root
#   DISTRO           "fedora" | "ubuntu" — selects guest pkg manager,
#                    image-discovery, and cloud-init customisations
#   GUEST_USER       cloud-image default user inside the guest
#   INSTALL_SH       host-side path to install.sh under test
#   CACHE_DIR        where the cached cloud image lives
#   SSH_PORT, MEM_MB, SMP, SSH_TIMEOUT
#   KEEP             0/1 — leave the VM running after the run
#   NESTED_YOLO      0/1 — run the matchlock nested-yolo smoke test
#   PODMAN_YOLO      0/1 — run the podman nested-yolo smoke test
#   LOCAL_YOLO       path | "auto" | "" — replace the installed yolo
#   IMAGE            (out) host-side path to the cached qcow2 / img
#
# Optional globals:
#   DISK_SIZE        e.g. "16G" — overlay resize (Ubuntu's tiny rootfs
#                    needs this; Fedora's doesn't)
#   IMAGE_NAME       wrapper-set hint for the cache filename
#   FETCH_IMAGE      function name the wrapper provides for downloading
#                    the cloud image; sourced lazily so each wrapper
#                    only carries its distro-specific URL/scrape logic
#   CLOUD_INIT_EXTRA additional cloud-config snippet (multi-line string)
#                    merged into the user-data we write
#
# Outputs:
#   WORK             temp dir (cleaned on exit unless --keep)
#   QEMU_PID_FILE
#   SERIAL_LOG
#   DISK             qcow2 overlay used for this run
#   SEED_TOOL        which of cloud-localds / genisoimage / xorriso we
#                    picked

# This file is sourced; don't `set -euo pipefail` here. The wrapper does
# that. Doing it here would override the wrapper's choices (e.g. when a
# wrapper wants to keep ERR-trapping off for a specific block).

# ---------------- Logging ----------------
if [ -t 1 ]; then
    C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
else
    C_BLUE=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
warn() { printf '%s==>%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s==>%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }

# ---------------- Pre-flight ----------------
preflight_host() {
    log "Pre-flight"
    [ -r "$INSTALL_SH" ] || die "install.sh not found at $INSTALL_SH"
    [ -e /dev/kvm ]      || die "/dev/kvm is missing — host does not support KVM"
    [ -r /dev/kvm ] && [ -w /dev/kvm ] \
        || die "no rw access to /dev/kvm (add yourself to the kvm group, log out and back in)"
    for cmd in qemu-system-x86_64 qemu-img curl ssh ssh-keygen scp; do
        command -v "$cmd" >/dev/null || die "missing required command: $cmd"
    done

    # cloud-init NoCloud ISO builder. Prefer cloud-localds; fall back to
    # genisoimage / xorriso which are commonly present on dev hosts.
    SEED_TOOL=""
    for c in cloud-localds genisoimage xorriso; do
        if command -v "$c" >/dev/null; then SEED_TOOL="$c"; break; fi
    done
    [ -n "$SEED_TOOL" ] \
        || die "need one of: cloud-localds (cloud-utils), genisoimage, or xorriso"

    # Nested virt isn't strictly required (we run matchlock inside the
    # guest, but matchlock's microVMs don't use KVM themselves) — but
    # callers should know.
    local nested=""
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
}

# ---------------- Workdir + cleanup ----------------
# Sets WORK, QEMU_PID_FILE, SERIAL_LOG. Registers a trap that kills the
# QEMU process and removes WORK on exit (unless --keep). Wrappers must
# call this after parsing args and before any QEMU activity.
prepare_workdir() {
    WORK="$(mktemp -d -t "yolo-verify-${DISTRO}-XXXXXX")"
    QEMU_PID_FILE="$WORK/qemu.pid"
    SERIAL_LOG="$WORK/serial.log"
    trap _verify_cleanup EXIT INT TERM
}

_verify_cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [ "${KEEP:-0}" -eq 1 ]; then
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

# ---------------- SSH key ----------------
generate_ssh_key() {
    ssh-keygen -t ed25519 -N '' -f "$WORK/id" -q
    PUBKEY="$(cat "$WORK/id.pub")"
}

# ---------------- cloud-init seed ----------------
# Writes $WORK/user-data and $WORK/meta-data. The user-data is a
# common skeleton (adds our pubkey, gives the default user passwordless
# sudo). Wrapper-specific extras (e.g. Ubuntu's DNS fix or any custom
# write_files) flow in via $CLOUD_INIT_EXTRA — appended verbatim to the
# user-data after the users: block, so it can introduce its own
# top-level cloud-config keys.
write_cloud_init() {
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
EOF
    if [ -n "${CLOUD_INIT_EXTRA:-}" ]; then
        printf '%s\n' "$CLOUD_INIT_EXTRA" >> "$WORK/user-data"
    fi
    printf 'instance-id: yolo-verify-%s\n' "$DISTRO" > "$WORK/meta-data"
}

make_seed_iso() {
    local out="$WORK/seed.iso"
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

# ---------------- Disk overlay ----------------
# Always builds the COW overlay in $WORK rather than relying on QEMU's
# `snapshot=on`. snapshot=on writes its temp file to /var/tmp (path is
# hard-coded in QEMU regardless of TMPDIR), which breaks under any
# sandbox that doesn't grant /var/tmp (Landlock-based wrappers, for one).
# Building the overlay ourselves keeps it inside the working directory
# we already own.
prepare_disk_overlay() {
    DISK="$WORK/disk.qcow2"
    qemu-img create -q -f qcow2 -F qcow2 -b "$IMAGE" "$DISK" >/dev/null \
        || die "qemu-img create overlay failed"
    if [ -n "${DISK_SIZE:-}" ]; then
        log "Preparing per-run disk overlay (size=$DISK_SIZE) at $DISK"
        qemu-img resize -q "$DISK" "$DISK_SIZE" >/dev/null \
            || die "qemu-img resize failed"
    fi
}

# ---------------- Boot ----------------
boot_qemu() {
    log "Booting ${DISTRO} VM (mem=${MEM_MB}MB, smp=$SMP, ssh port $SSH_PORT)"
    qemu-system-x86_64 \
        -name "yolo-verify-${DISTRO}" \
        -enable-kvm -cpu host -m "$MEM_MB" -smp "$SMP" \
        -drive file="$DISK",if=virtio,format=qcow2 \
        -drive file="$WORK/seed.iso",if=virtio,format=raw \
        -netdev user,id=n,hostfwd=tcp::"${SSH_PORT}"-:22 -device virtio-net,netdev=n \
        -serial file:"$SERIAL_LOG" \
        -display none \
        -daemonize -pidfile "$QEMU_PID_FILE"
}

# ---------------- SSH ----------------
_ssh_opts() {
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
}

wait_for_ssh() {
    _ssh_opts
    log "Waiting for SSH on port $SSH_PORT (up to ${SSH_TIMEOUT}s)…"
    local deadline=$(( $(date +%s) + SSH_TIMEOUT ))
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
}

run_ssh() {
    # We intentionally pass literal commands; client-side expansion is OK.
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "$GUEST_USER@127.0.0.1" "$@"
}

copy_to_guest() {
    # copy_to_guest LOCAL REMOTE
    scp -P "$SSH_PORT" -i "$WORK/id" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$1" "$GUEST_USER@127.0.0.1:$2" >/dev/null
}

# ---------------- cloud-init wait (Ubuntu) ----------------
# Ubuntu cloud images run unattended-upgrades right after boot; if
# install.sh races with that, apt locks are held and dpkg errors out.
# Skipped silently on distros without `cloud-init`.
wait_cloud_init_if_present() {
    if run_ssh 'command -v cloud-init >/dev/null 2>&1'; then
        log "Waiting for cloud-init to finish (releases the apt/dpkg lock)"
        run_ssh 'sudo cloud-init status --wait' >/dev/null \
            || die "cloud-init did not reach 'done' state"
    fi
}

# ---------------- install.sh ----------------
run_install_sh() {
    log "Copying install.sh into the guest"
    copy_to_guest "$INSTALL_SH" /tmp/install.sh
    log "Running install.sh inside the guest (this will install matchlock + yolo)"
    run_ssh 'bash /tmp/install.sh'
}

# ---------------- Local yolo override ----------------
override_local_yolo_if_set() {
    [ -n "${LOCAL_YOLO:-}" ] || return 0
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
    copy_to_guest "$LOCAL_YOLO" /tmp/yolo-local
    run_ssh 'install -m 0755 /tmp/yolo-local "$HOME/.local/bin/yolo" && rm -f /tmp/yolo-local'
}

# ---------------- Verification ----------------
verify_binaries() {
    log "Verifying binaries are present"
    run_ssh 'set -e
        ls -l /dev/kvm
        command -v matchlock
        command -v ~/.local/bin/yolo || command -v yolo
        matchlock --version
        ~/.local/bin/yolo --help >/dev/null 2>&1 || yolo --help >/dev/null
    '
}

run_matchlock_setup() {
    log "Running 'sudo matchlock setup linux' and enrolling the $GUEST_USER user"
    run_ssh "sudo matchlock setup linux && sudo matchlock setup user $GUEST_USER"
    log "Running 'matchlock diagnose' (fresh SSH session picks up new group membership)"
    run_ssh 'matchlock diagnose'
}

# Install one or more packages inside the guest, using the distro's
# native package manager. Idempotent — runs even if some packages are
# already present.
ensure_guest_pkgs() {
    local pkgs="$*"
    [ -n "$pkgs" ] || return 0
    case "$DISTRO" in
        fedora)
            run_ssh "sudo dnf install -y --quiet $pkgs >/dev/null"
            ;;
        ubuntu)
            run_ssh "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null"
            ;;
        *)
            die "unknown DISTRO '$DISTRO' — extend ensure_guest_pkgs()"
            ;;
    esac
}

# Maps friendly names to distro-specific package names. Add entries as
# new test prerequisites come up. Keep this minimal — prefer using
# tools that are already in the cloud-image base (e.g. python3 instead
# of util-linux's `script`, which has shifted sub-packages across
# Fedora releases).
_pkg_for() {
    local friendly="$1"
    case "$DISTRO:$friendly" in
        fedora:podman)        echo "podman" ;;
        ubuntu:podman)        echo "podman" ;;
        *) die "unknown package mapping for $DISTRO:$friendly" ;;
    esac
}

# ---------------- Matchlock nested-yolo smoke ----------------
nested_yolo_matchlock_smoke() {
    log "Booting a nested yolo microVM (matchlock backend)"
    log "  (first boot downloads a kernel + rootfs; this can take a few minutes)"

    local nested_out_file="$WORK/nested-matchlock.out"
    # shellcheck disable=SC2016
    if ! run_ssh '
        set -euo pipefail
        rm -rf /tmp/yolo-nested
        mkdir -p /tmp/yolo-nested
        cd /tmp/yolo-nested
        YOLO=$HOME/.local/bin/yolo
        cleanup() { (cd /tmp/yolo-nested && "$YOLO" rm) >/dev/null 2>&1 || true; }
        trap cleanup EXIT

        echo "=== passthrough: yolo -- sh -c ... ==="
        "$YOLO" --no-provision -- sh -c "uname -a; echo NESTED_OK_$$"

        echo "=== interactive: yolo (real PTY via python3 pty.spawn) ==="
        # The plain passthrough test above runs a self-contained command and
        # exits regardless of whether matchlock got -t, so it cannot catch
        # regressions in the interactive attach path (e.g. a broken tty_check
        # routing yolo to "-i" only, which leaves in-guest bash without a PTY
        # and produces no prompt — a silent hang for a real user).
        #
        # We need yolo'\''s stdin to actually be a PTY, not a pipe. matchlock
        # checks the inherited stdin for -t and refuses with "-it requires a
        # TTY" if we just `printf ... | yolo`. python3'\''s pty.spawn forks
        # a PTY pair, plumbs the *slave* into the child as its stdin/stdout/
        # stderr (and makes it the controlling terminal via setsid+TIOCSCTTY),
        # and copies the parent'\''s stdin to the master end. Net effect:
        # commands fed to python3'\''s stdin reach yolo through a real PTY,
        # so yolo'\''s tty_check passes and matchlock'\''s -t check sees a
        # genuine TTY on fd 0.
        #
        # `script(1)` would also have worked, but it has bounced between
        # util-linux sub-packages across Fedora releases and isn'\''t always
        # in the cloud-image base. python3 always is.
        printf "%s\n" "uname -s" "echo INTERACTIVE_OK_$$" "exit" \
            | timeout 180 python3 -c "import pty,sys; sys.exit(pty.spawn([\"$YOLO\", \"--no-provision\"]))"
        echo "=== interactive done ==="
    ' 2>&1 | tee "$nested_out_file"; then
        die "nested yolo (matchlock) smoke test failed"
    fi
    local nested_out
    nested_out="$(cat "$nested_out_file")"
    echo "$nested_out" | grep -q '^Linux ' \
        || die "nested yolo did not produce a Linux uname line"
    echo "$nested_out" | grep -q '^NESTED_OK_' \
        || die "nested yolo command did not run to completion"
    # Interactive attach: command output must appear (sanity), AND the
    # typed command must be echoed back (proof in-guest bash got a PTY).
    echo "$nested_out" | grep -q 'INTERACTIVE_OK_' \
        || die "interactive yolo attach: piped commands did not produce output"
    echo "$nested_out" | grep -q 'uname -s' \
        || die "interactive yolo attach: typed command not echoed — in-guest bash has no PTY (tty_check / -t negotiation broken)"
    # Confirm the dispatch went through the matchlock backend. Belt-and-
    # braces: the matchlock backend's start_vm log includes "[matchlock]"
    # at the end of the line.
    echo "$nested_out" | grep -q '\[matchlock\]' \
        || die "yolo did not log the matchlock backend tag — backend dispatch may be wrong"
    log "  nested yolo microVM (matchlock) ran successfully (passthrough + interactive)"
}

# ---------------- Podman nested-yolo smoke ----------------
# Verifies the podman backend boots a container, runs a passthrough
# command, and respects the persistence semantics (stop then re-attach
# without recreating). Uses an explicit -n PODMAN_NAME so the binding
# can't collide with the matchlock test which uses the auto-derived
# cwd-based name.
nested_yolo_podman_smoke() {
    log "Booting a nested yolo container (podman backend)"
    log "  (first run pulls the fedora-toolbox image; this can take a few minutes)"

    # podman isn't part of matchlock's install.sh — install it now.
    ensure_guest_pkgs "$(_pkg_for podman)"

    local nested_out_file="$WORK/nested-podman.out"
    # shellcheck disable=SC2016
    if ! run_ssh '
        set -euo pipefail
        rm -rf /tmp/yolo-podman
        mkdir -p /tmp/yolo-podman
        cd /tmp/yolo-podman
        YOLO=$HOME/.local/bin/yolo
        cleanup() { (cd /tmp/yolo-podman && "$YOLO" rm -n podman-smoke) >/dev/null 2>&1 || true; }
        trap cleanup EXIT

        echo "=== passthrough: yolo --backend podman -- sh -c ... ==="
        "$YOLO" --backend podman -n podman-smoke --no-provision -- \
            sh -c "uname -a; echo PODMAN_OK_$$"

        echo "=== persistence: stop + re-attach should NOT recreate ==="
        # Capture the container id BEFORE stopping.
        ID_BEFORE=$("$YOLO" id -n podman-smoke)
        "$YOLO" stop -n podman-smoke

        # Re-attach. For podman the dispatcher should call be.resume(),
        # not be.start(). The container name (= yolo "id") must be
        # preserved.
        "$YOLO" -n podman-smoke --no-provision -- \
            sh -c "echo PODMAN_RESUMED_$$ from \$(hostname)"
        ID_AFTER=$("$YOLO" id -n podman-smoke)
        if [ "$ID_BEFORE" != "$ID_AFTER" ]; then
            echo "PODMAN_FAIL: id changed across stop+attach ($ID_BEFORE -> $ID_AFTER)" >&2
            exit 1
        fi
        echo "PODMAN_PERSISTED_ID=$ID_AFTER"
        echo "=== podman done ==="
    ' 2>&1 | tee "$nested_out_file"; then
        die "nested yolo (podman) smoke test failed"
    fi
    local nested_out
    nested_out="$(cat "$nested_out_file")"
    echo "$nested_out" | grep -q '^Linux ' \
        || die "yolo (podman): no Linux uname line"
    echo "$nested_out" | grep -q '^PODMAN_OK_' \
        || die "yolo (podman): initial passthrough did not run to completion"
    echo "$nested_out" | grep -q '^PODMAN_RESUMED_' \
        || die "yolo (podman): resume after stop did not run"
    echo "$nested_out" | grep -q '^PODMAN_PERSISTED_ID=yolo-podman-smoke$' \
        || die "yolo (podman): container id did not persist across stop+attach (expected yolo-podman-smoke)"
    # Same belt-and-braces dispatch check as the matchlock side.
    echo "$nested_out" | grep -q '\[podman\]' \
        || die "yolo did not log the podman backend tag — backend dispatch may be wrong"
    log "  nested yolo container (podman) ran successfully (passthrough + resume)"
}

# ---------------- Main orchestrator ----------------
# Drives the full verification flow. Wrapper scripts call this once
# they've done their distro-specific arg parsing and image fetch.
verify_main() {
    preflight_host

    # Wrappers are responsible for placing the cached image at $IMAGE
    # before calling verify_main. They typically do this in a small
    # `fetch_image` helper of their own (Fedora needs to scrape a
    # directory listing, Ubuntu has a stable URL).
    log "  image: $IMAGE"

    prepare_workdir
    generate_ssh_key
    write_cloud_init
    make_seed_iso
    prepare_disk_overlay
    boot_qemu
    wait_for_ssh
    wait_cloud_init_if_present

    run_install_sh
    override_local_yolo_if_set
    verify_binaries
    run_matchlock_setup

    if [ "${NESTED_YOLO:-1}" -eq 1 ]; then
        nested_yolo_matchlock_smoke
    else
        log "Skipping nested yolo (matchlock) smoke test (--no-nested-yolo)"
    fi

    if [ "${PODMAN_YOLO:-1}" -eq 1 ]; then
        nested_yolo_podman_smoke
    else
        log "Skipping nested yolo (podman) smoke test (--no-podman-yolo)"
    fi

    log "All checks passed."
}
