#!/usr/bin/env bash
# install.sh — one-step installer for matchlock + yolo.
#
# Quick install:
#   curl -fsSL https://yolo.rbel.co/install.sh | bash
#
# Or pin versions:
#   curl -fsSL https://yolo.rbel.co/install.sh \
#     | bash -s -- --yolo-version v0.1.0 --matchlock-version 0.2.4
#
# Supported hosts:
#   - Fedora (Workstation/Server/Cloud; not Atomic/rpm-ostree variants)
#   - Ubuntu 26.04 LTS (Resolute Raccoon)
#
# What it does:
#   1. Pre-flight: detects Fedora (dnf) or Ubuntu (apt) and refuses anything else.
#   2. Installs host dependencies (curl, tar, ca-certificates).
#   3. Installs matchlock from GitHub Releases (.rpm on Fedora, .deb on Ubuntu).
#   4. Downloads the matching yolo binary from GitHub Releases into
#      ~/.local/bin (or $YOLO_PREFIX) and verifies its sha256 checksum.
#   5. Prints next-step hints (matchlock diagnose / setup linux).

set -euo pipefail

# ---------------- Configuration ----------------
YOLO_REPO="${YOLO_REPO:-rubiojr/yolo}"
YOLO_VERSION="${YOLO_VERSION:-}"            # empty = latest
MATCHLOCK_VERSION="${MATCHLOCK_VERSION:-}"  # empty = latest
YOLO_PREFIX="${YOLO_PREFIX:-$HOME/.local/bin}"

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
  --skip-deps                   Skip the host package-manager install of
                                build/runtime deps (curl, tar, ca-certificates).
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
log "Pre-flight: checking host OS"
[ -r /etc/os-release ] || die "/etc/os-release not found; cannot identify host."
# shellcheck disable=SC1091
. /etc/os-release

case "${ID:-}" in
  fedora)
    DISTRO="fedora"
    # Fedora Atomic variants (Silverblue, Kinoite, CoreOS, IoT, …) layer packages
    # via rpm-ostree rather than dnf. The matchlock RPM install assumes a mutable
    # dnf host, so we hard-fail here with a clear pointer rather than half-install.
    case "${VARIANT_ID:-}" in
      silverblue|kinoite|sericea|onyx|coreos|iot|atomic)
        die "Detected Fedora Atomic variant '${VARIANT_ID}'. This installer requires a mutable dnf host. Layer matchlock with 'rpm-ostree install' manually or use the Fedora Workstation/Server/Cloud editions."
        ;;
    esac
    if command -v rpm-ostree >/dev/null 2>&1 && ! command -v dnf >/dev/null 2>&1; then
      die "rpm-ostree detected without dnf — this installer requires a mutable Fedora host."
    fi
    ;;
  ubuntu)
    DISTRO="ubuntu"
    # Ubuntu Core (snap-only, immutable) reports ID=ubuntu-core, so it never
    # reaches this branch. WSL Ubuntu is identified as plain ubuntu and is fine
    # — matchlock won't work there in practice (no /dev/kvm), but install will
    # succeed and `matchlock diagnose` will explain. Hard requirements:
    command -v apt-get >/dev/null 2>&1 || die "apt-get not found on this Ubuntu host."
    command -v dpkg    >/dev/null 2>&1 || die "dpkg not found — needed to install matchlock .deb."
    if [ "${VERSION_ID:-}" != "26.04" ]; then
      warn "Ubuntu ${VERSION_ID:-?} detected; only 26.04 LTS is officially tested. Continuing anyway."
    fi
    ;;
  *)
    die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. Supported: Fedora (mutable) and Ubuntu 26.04 LTS."
    ;;
esac
log "  detected: ${PRETTY_NAME:-$ID}${VARIANT_ID:+ (${VARIANT_ID})}"

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
  log "Installing host dependencies (curl, tar, ca-certificates)"
  case "$DISTRO" in
    fedora)
      $SUDO dnf install -y --setopt=install_weak_deps=False \
        curl tar ca-certificates
      ;;
    ubuntu)
      # apt-get update can race with cloud-init's apt phase on freshly-booted
      # cloud images; the verify script gates on `cloud-init status --wait`
      # before invoking us. Plain `apt-get` is fine on already-settled hosts.
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends curl tar ca-certificates
      ;;
  esac
else
  warn "Skipping host dependency install (--skip-deps)"
fi

need_cmd curl

# ---------------- Install matchlock ----------------
# We deliberately don't use matchlock's upstream curl|bash installer here:
# it uses bash process substitution (`< <(...)`), which fails inside
# matchlock's own microVMs ("/dev/fd/63: No such file or directory") and
# also breaks when fed to `bash -s --` from a pipe. Resolving the package
# asset URL directly is simpler and only uses plain pipes anyway.
matchlock_asset_url() {
  local arch="$1" version="${2:-}" ext="$3"
  local api_url

  if [ -z "$version" ]; then
    api_url="https://api.github.com/repos/jingkaihe/matchlock/releases/latest"
  else
    case "$version" in v*) ;; *) version="v$version" ;; esac
    api_url="https://api.github.com/repos/jingkaihe/matchlock/releases/tags/$version"
  fi

  # Use retries so a transient DNS / TCP blip during cloud-init or first-boot
  # network setup doesn't fail the whole install.
  curl -fsSL --proto '=https' --tlsv1.2 \
    --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
    "$api_url" \
    | sed -nE "s/.*\"browser_download_url\":[[:space:]]*\"(https:\/\/[^\"]*_linux_${arch}\.${ext})\".*/\1/p" \
    | head -n1
}

if [ "$SKIP_MATCHLOCK" -eq 0 ]; then
  case "$DISTRO" in
    fedora) ML_EXT="rpm" ;;
    ubuntu) ML_EXT="deb" ;;
  esac
  log "Resolving matchlock ${ML_EXT} (${MATCHLOCK_VERSION:-latest}, linux/${ARCH})"
  ML_PKG_URL="$(matchlock_asset_url "$ARCH" "$MATCHLOCK_VERSION" "$ML_EXT")" \
    || die "failed to query GitHub for matchlock releases"
  [ -n "$ML_PKG_URL" ] || die "no matchlock .${ML_EXT} asset found for linux/${ARCH} in release ${MATCHLOCK_VERSION:-latest}"
  log "  asset: $ML_PKG_URL"

  case "$DISTRO" in
    fedora)
      log "Installing matchlock via dnf"
      $SUDO dnf install -y --setopt=install_weak_deps=False "$ML_PKG_URL"
      ;;
    ubuntu)
      # apt-get install accepts a local path that starts with `./` or `/` and
      # ends in `.deb`, and will resolve dependencies from the apt repos. We
      # download the deb to a temp dir first so apt has a stable filename.
      log "Downloading matchlock .deb"
      ML_DEB_DIR="$(mktemp -d)"
      ML_DEB="$ML_DEB_DIR/matchlock.deb"
      curl -fL --proto '=https' --tlsv1.2 \
        --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
        -o "$ML_DEB" "$ML_PKG_URL" \
        || { rm -rf "$ML_DEB_DIR"; die "failed to download $ML_PKG_URL"; }
      log "Installing matchlock via apt-get"
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends "$ML_DEB"
      rm -rf "$ML_DEB_DIR"
      ;;
  esac
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

if ! curl -fL --proto '=https' --tlsv1.2 \
      --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
      -o "$TMP/$YOLO_ASSET" "$YOLO_URL"; then
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
