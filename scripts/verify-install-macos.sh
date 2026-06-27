#!/usr/bin/env bash
# verify-install-macos.sh — verify web/install.sh on macOS.
#
# Unlike the Linux verify scripts (which boot a QEMU/KVM cloud guest and run
# install.sh inside it), the GitHub macOS runner *is* the target host, so we
# run install.sh directly on it.
#
# install.sh on macOS downloads a `yolo-darwin-<arch>` release asset, but a
# published release may not have one yet. To keep this self-contained, we build
# the darwin binary from the working tree, lay it out as a local file:// "release"
# (binary + .sha256 sidecar), and point install.sh at it via $YOLO_BASE_URL.
# This exercises install.sh's real download + checksum + install path (and the
# macOS branch: OS detection, the Apple `container` flag, the portable shasum
# verification) without depending on a published darwin release.
#
# It then asserts the installed binary works and that the new container-backend
# preflight fires with the install link when Apple's `container` is absent
# (which it is on a stock runner).
#
# Usage:
#   scripts/verify-install-macos.sh
#
# Requirements: macOS host, rugo + Go (to build), curl, shasum.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$ROOT/web/install.sh}"

# ---------------- Logging ----------------
if [ -t 1 ]; then
    C_BLUE=$'\033[1;34m'; C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
else
    C_BLUE=""; C_RED=""; C_RESET=""
fi
log() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
die() { printf '%s==>%s %s\n' "$C_RED"  "$C_RESET" "$*" >&2; exit 1; }

# ---------------- Pre-flight ----------------
[ "$(uname -s)" = "Darwin" ] || die "this script must run on macOS (got $(uname -s))"
[ -r "$INSTALL_SH" ] || die "install.sh not found at $INSTALL_SH"
for c in rugo curl shasum mktemp; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
done

case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64)  ARCH="amd64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac
ASSET="yolo-darwin-${ARCH}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/yolo-verify-macos.XXXXXX")"
REL="$WORK/release"
PREFIX="$WORK/bin"
mkdir -p "$REL" "$PREFIX"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------- Build a local "release" ----------------
log "Building $ASSET from $ROOT/yolo.rugo"
( cd "$ROOT" && CGO_ENABLED=0 rugo build yolo.rugo -o "$REL/$ASSET" ) \
    || die "rugo build yolo.rugo failed"
chmod +x "$REL/$ASSET"
# Sidecar must use the bare filename (install.sh verifies with `cd <tmp> &&
# shasum -a 256 -c <asset>.sha256`).
( cd "$REL" && shasum -a 256 "$ASSET" > "$ASSET.sha256" )
log "  built: $(file -b "$REL/$ASSET" 2>/dev/null || echo "$ASSET")"

# ---------------- Run install.sh against the local release ----------------
log "Running install.sh against local file:// release"
OUT="$WORK/install.out"
if ! YOLO_BASE_URL="file://$REL" bash "$INSTALL_SH" --prefix "$PREFIX" >"$OUT" 2>&1; then
    cat "$OUT" >&2
    die "install.sh exited non-zero"
fi
cat "$OUT"

# ---------------- Assertions: install.sh behaviour ----------------
grep -q "macOS host" "$OUT" || die "install.sh did not take the macOS path"
[ -x "$PREFIX/yolo" ]       || die "yolo was not installed at $PREFIX/yolo"
"$PREFIX/yolo" --help    >/dev/null || die "installed 'yolo --help' failed"
"$PREFIX/yolo" --version >/dev/null || die "installed 'yolo --version' failed"
log "verified: install.sh installed a working darwin yolo"

# install.sh must flag (not install) Apple's `container` when it's absent.
if ! command -v container >/dev/null 2>&1; then
    grep -qi "container.* not found on PATH" "$OUT" \
        || die "expected install.sh to flag the missing 'container' CLI"
    grep -q "apple/container/releases" "$OUT" \
        || die "expected install.sh to print the container install URL"
    log "verified: install.sh flags missing Apple 'container' CLI with install link"
fi

# matchlock is a supported opt-in macOS backend — install.sh must flag it
# (present: show version + how to select it; absent: the Homebrew install hint),
# never install it.
if command -v matchlock >/dev/null 2>&1; then
    grep -qi "matchlock found" "$OUT" \
        || die "expected install.sh to report the present matchlock backend"
else
    grep -qi "matchlock .*was not found" "$OUT" \
        || die "expected install.sh to flag the missing matchlock backend"
    grep -q "brew install matchlock" "$OUT" \
        || die "expected install.sh to print the matchlock Homebrew install hint"
fi
log "verified: install.sh flags the matchlock macOS backend (no install)"

# ---------------- Assertion: container-backend preflight ----------------
# container is the default backend on macOS; with no `container` CLI present the
# backend must fail fast with the install link (exit 127), not a cryptic error.
if ! command -v container >/dev/null 2>&1; then
    log "Checking container-backend preflight (no 'container' CLI present)"
    set +e
    PF_OUT="$("$PREFIX/yolo" --backend container -- echo hi 2>&1)"
    PF_RC=$?
    set -e
    [ "$PF_RC" -eq 127 ] || { printf '%s\n' "$PF_OUT" >&2; die "expected exit 127 from container preflight, got $PF_RC"; }
    printf '%s\n' "$PF_OUT" | grep -q "apple/container/releases" \
        || { printf '%s\n' "$PF_OUT" >&2; die "expected the install URL in the preflight error"; }
    log "verified: container backend preflight errors with the install link (exit 127)"
fi

log "macOS install.sh verification OK"
