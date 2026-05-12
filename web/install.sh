#!/usr/bin/env bash
# install.sh — one-step installer for matchlock + yolo on Fedora.
#
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/rubiojr/yolo/main/web/install.sh | bash
#
# Or pin versions:
#   curl -fsSL https://raw.githubusercontent.com/rubiojr/yolo/main/web/install.sh \
#     | bash -s -- --yolo-version v0.1.0 --matchlock-version 0.2.4
#
# What it does:
#   1. Pre-flight: only Fedora (mutable, dnf-based) is supported.
#   2. Installs host dependencies (curl, tar) via dnf.
#   3. Installs matchlock via the upstream installer (RPM from GitHub).
#   4. Downloads the matching yolo binary from GitHub Releases into
#      ~/.local/bin (or $YOLO_PREFIX) and verifies its sha256 checksum.
#   5. Prints next-step hints (matchlock diagnose / setup linux).

set -euo pipefail

# ---------------- Configuration ----------------
YOLO_REPO="${YOLO_REPO:-rubiojr/yolo}"
YOLO_VERSION="${YOLO_VERSION:-}"            # empty = latest
MATCHLOCK_VERSION="${MATCHLOCK_VERSION:-}"  # empty = latest
YOLO_PREFIX="${YOLO_PREFIX:-$HOME/.local/bin}"

MATCHLOCK_INSTALLER_URL="${MATCHLOCK_INSTALLER_URL:-https://raw.githubusercontent.com/jingkaihe/matchlock/main/scripts/install.sh}"

SKIP_MATCHLOCK=0
SKIP_DEPS=0
ALLOW_MISSING_CHECKSUM=0

# ---------------- Logging ----------------
if [ -t 1 ]; then
  C_BLUE=$'\033[1;34m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi
log()  { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
warn() { printf '%s==>%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s==>%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; exit 1; }

# ---------------- Help ----------------
usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --yolo-version VERSION        Install a specific yolo release (e.g. v0.1.0).
                                Default: latest.
  --matchlock-version VERSION   Install a specific matchlock release.
                                Default: latest.
  --prefix DIR                  Install yolo into DIR (default: ~/.local/bin).
  --skip-matchlock              Skip installing matchlock (assume already present).
  --skip-deps                   Skip dnf install of host build/runtime deps.
  --allow-missing-checksum      Don't fail if the release lacks a .sha256 sidecar
                                (useful for forks / dev releases — discouraged).
  -h, --help                    Show this help.

Environment variables (alternative to flags):
  YOLO_VERSION, MATCHLOCK_VERSION, YOLO_PREFIX, YOLO_REPO
EOF
}

# ---------------- Argument parsing ----------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yolo-version)
      [ "$#" -ge 2 ] || die "--yolo-version requires a value"
      YOLO_VERSION="$2"; shift 2 ;;
    --matchlock-version)
      [ "$#" -ge 2 ] || die "--matchlock-version requires a value"
      MATCHLOCK_VERSION="$2"; shift 2 ;;
    --prefix)
      [ "$#" -ge 2 ] || die "--prefix requires a value"
      YOLO_PREFIX="$2"; shift 2 ;;
    --skip-matchlock) SKIP_MATCHLOCK=1; shift ;;
    --skip-deps)      SKIP_DEPS=1; shift ;;
    --allow-missing-checksum) ALLOW_MISSING_CHECKSUM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

# ---------------- Pre-flight: OS ----------------
log "Pre-flight: checking that this is a Fedora host"
[ -r /etc/os-release ] || die "/etc/os-release not found; this installer supports Fedora only."
# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != "fedora" ]; then
  die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. This installer supports Fedora only."
fi

# Fedora Atomic variants (Silverblue, Kinoite, CoreOS, IoT, …) layer packages
# via rpm-ostree rather than dnf. The matchlock RPM installer assumes a mutable
# dnf host, so we hard-fail here with a clear pointer rather than half-install.
case "${VARIANT_ID:-}" in
  silverblue|kinoite|sericea|onyx|coreos|iot|atomic)
    die "Detected Fedora Atomic variant '${VARIANT_ID}'. This installer requires a mutable dnf host. Layer matchlock with 'rpm-ostree install' manually or use the Fedora Workstation/Server/Cloud editions."
    ;;
esac
if command -v rpm-ostree >/dev/null 2>&1 && ! command -v dnf >/dev/null 2>&1; then
  die "rpm-ostree detected without dnf — this installer requires a mutable Fedora host."
fi
log "  detected: ${PRETTY_NAME:-Fedora}${VARIANT_ID:+ (${VARIANT_ID})}"

# ---------------- Pre-flight: arch ----------------
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m). yolo ships linux/amd64 and linux/arm64 only." ;;
esac
log "  architecture: ${ARCH}"

# ---------------- Pre-flight: required commands ----------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
need_cmd uname
need_cmd bash

# ---------------- sudo helper ----------------
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    die "running as non-root and 'sudo' is not available; install sudo or run this script as root"
  fi
fi

# ---------------- Install host deps ----------------
if [ "$SKIP_DEPS" -eq 0 ]; then
  log "Installing host dependencies via dnf (curl, tar, ca-certificates)"
  $SUDO dnf install -y --setopt=install_weak_deps=False \
    curl tar ca-certificates
else
  warn "Skipping host dependency install (--skip-deps)"
fi

need_cmd curl

# ---------------- Install matchlock ----------------
if [ "$SKIP_MATCHLOCK" -eq 0 ]; then
  log "Installing matchlock via upstream installer"
  ML_ARGS=()
  [ -n "$MATCHLOCK_VERSION" ] && ML_ARGS=(--version "$MATCHLOCK_VERSION")
  # The upstream installer runs `sudo dnf install` internally.
  curl -fsSL "$MATCHLOCK_INSTALLER_URL" | bash -s -- "${ML_ARGS[@]}"
else
  warn "Skipping matchlock install (--skip-matchlock)"
fi

# ---------------- Resolve yolo download URL ----------------
if [ -n "$YOLO_VERSION" ]; then
  case "$YOLO_VERSION" in
    v*) YOLO_TAG="$YOLO_VERSION" ;;
    *)  YOLO_TAG="v$YOLO_VERSION" ;;
  esac
  YOLO_BASE_URL="https://github.com/${YOLO_REPO}/releases/download/${YOLO_TAG}"
  YOLO_LABEL="$YOLO_TAG"
else
  YOLO_BASE_URL="https://github.com/${YOLO_REPO}/releases/latest/download"
  YOLO_LABEL="latest"
fi

YOLO_ASSET="yolo-linux-${ARCH}"
YOLO_URL="${YOLO_BASE_URL}/${YOLO_ASSET}"
YOLO_SHA_URL="${YOLO_URL}.sha256"

# ---------------- Install yolo ----------------
log "Downloading yolo (${YOLO_LABEL}, linux/${ARCH})"
mkdir -p "$YOLO_PREFIX"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! curl -fL --proto '=https' --tlsv1.2 -o "$TMP/$YOLO_ASSET" "$YOLO_URL"; then
  die "failed to download $YOLO_URL — does a release exist for ${YOLO_LABEL}?"
fi

# Checksum verification: required by default for the official repo so a
# silently-broken release can't ship an unverified binary. Opt-out exists for
# forks / dev tags via --allow-missing-checksum.
if curl -fsSL -o "$TMP/$YOLO_ASSET.sha256" "$YOLO_SHA_URL" 2>/dev/null; then
  log "Verifying SHA-256 checksum"
  ( cd "$TMP" && sha256sum -c "$YOLO_ASSET.sha256" >/dev/null ) \
    || die "checksum mismatch for $YOLO_ASSET"
else
  if [ "$ALLOW_MISSING_CHECKSUM" -eq 1 ]; then
    warn "No .sha256 sidecar for ${YOLO_ASSET}; skipping verification (--allow-missing-checksum)."
  else
    die "No .sha256 sidecar published at $YOLO_SHA_URL — refusing to install an unverified binary. Re-run with --allow-missing-checksum if you really mean it."
  fi
fi

install -m 0755 "$TMP/$YOLO_ASSET" "$YOLO_PREFIX/yolo"
log "Installed: $YOLO_PREFIX/yolo"

# ---------------- PATH hint ----------------
case ":${PATH:-}:" in
  *":$YOLO_PREFIX:"*) ;;
  *)
    warn "$YOLO_PREFIX is not on your \$PATH."
    warn "Add this to your shell rc (~/.bashrc, ~/.zshrc, …):"
    warn "    export PATH=\"$YOLO_PREFIX:\$PATH\""
    ;;
esac

# ---------------- Summary ----------------
cat <<EOF

${C_BLUE}==>${C_RESET} All done.

Next steps:
  - matchlock diagnose
  - If diagnose reports missing host setup:  sudo matchlock setup linux
  - cd into a project and run:  yolo

Versions:
  yolo:      ${YOLO_LABEL}  (${YOLO_PREFIX}/yolo)
  matchlock: $( [ "$SKIP_MATCHLOCK" -eq 1 ] && echo "(skipped)" || echo "${MATCHLOCK_VERSION:-latest}" )

EOF
