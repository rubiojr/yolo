#!/usr/bin/env bash
# install.sh — one-step installer for yolo (+ matchlock/podman on Linux).
#
# Quick install:
#   curl -fsSL https://yolo.rbel.co/install.sh | bash
#
# Or override versions:
#   curl -fsSL https://yolo.rbel.co/install.sh \
#     | bash -s -- --yolo-version v0.1.0 --matchlock-version 0.2.15
#
# Supported hosts:
#   - Linux: Fedora (Workstation/Server/Cloud; not Atomic/rpm-ostree variants)
#            and Ubuntu 26.04 LTS (Resolute Raccoon).
#   - macOS: Apple silicon / Intel. Installs only the yolo binary; the default
#            backend there is Apple's `container`, which this script does NOT
#            install — it just flags it if it's missing (see
#            https://github.com/apple/container/releases).
#
# What it does:
#   Linux:
#     1. Pre-flight: detects Fedora (dnf) or Ubuntu (apt) and refuses anything else.
#     2. Installs host dependencies (curl, tar, ca-certificates).
#     3. Installs matchlock from GitHub Releases (.rpm on Fedora, .deb on Ubuntu).
#     4. Installs podman (+ passt/slirp4netns on Ubuntu) so 'yolo --backend
#        podman' works. Pass --skip-podman if you only use the matchlock backend.
#     5. Runs 'matchlock setup linux' and enrolls the invoking user in kvm + netdev.
#     6. Restores /dev/net/tun to mode 0666 (kernel-recommended default) and
#        installs a udev rule so it survives reboots.
#   macOS:
#     1. Pre-flight: confirms the host is macOS and flags whether Apple's
#        `container` CLI is installed (it is yolo's default backend on macOS).
#   Both:
#     7. Downloads the matching yolo binary from GitHub Releases into
#        ~/.local/bin (or $YOLO_PREFIX) and verifies its sha256 checksum.
#     8. Prints next-step hints.

set -euo pipefail

# ---------------- Configuration ----------------
YOLO_REPO="${YOLO_REPO:-rubiojr/yolo}"
YOLO_VERSION="${YOLO_VERSION:-}"                    # empty = latest
# Base URL the yolo binary + .sha256 are fetched from. Normally derived from
# YOLO_REPO/YOLO_VERSION to point at GitHub Releases; override it to install
# from a mirror or a local "release" (e.g. file:///path or http://host:port)
# — used by scripts/verify-install-macos.sh to test against a locally-built
# binary without a published release. The github default stays https-only.
YOLO_BASE_URL="${YOLO_BASE_URL:-}"
# matchlock is pinned to a known-good release for reproducible installs.
# Bump this after verifying yolo still works against the new release
# (see release notes at https://github.com/jingkaihe/matchlock/releases).
MATCHLOCK_VERSION="${MATCHLOCK_VERSION:-0.2.15}"
YOLO_PREFIX="${YOLO_PREFIX:-$HOME/.local/bin}"

# Where to point macOS users who don't have Apple's `container` CLI yet.
CONTAINER_INSTALL_URL="https://github.com/apple/container/releases/tag/1.0.0"

SKIP_MATCHLOCK=0
SKIP_DEPS=0
SKIP_SETUP=0
SKIP_PODMAN=0
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

# Portable SHA-256 check: macOS ships `shasum` (Perl), Linux ships `sha256sum`.
# Both understand the "<hash>  <file>" sidecar format produced at release time.
# Verifies "<file>.sha256" against "<file>" inside directory "$1". Returns 2
# when no checksum tool is available so the caller can honour
# --allow-missing-checksum semantics.
sha256_verify() {
  local dir="$1" file="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$dir" && sha256sum -c "$file.sha256" >/dev/null )
  elif command -v shasum >/dev/null 2>&1; then
    ( cd "$dir" && shasum -a 256 -c "$file.sha256" >/dev/null )
  else
    return 2
  fi
}

# ---------------- Help ----------------
usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --yolo-version VERSION        Install a specific yolo release (e.g. v0.1.0).
                                Default: latest.
  --matchlock-version VERSION   Install a specific matchlock release (Linux only).
                                Default: pinned (see MATCHLOCK_VERSION in this script).
  --prefix DIR                  Install yolo into DIR (default: ~/.local/bin).
  --skip-matchlock              (Linux) Skip installing matchlock (assume present).
  --skip-deps                   (Linux) Skip the host package-manager install of
                                build/runtime deps (curl, tar, ca-certificates).
  --skip-setup                  (Linux) Skip 'matchlock setup linux',
                                'matchlock setup user', and the /dev/net/tun fix.
  --skip-podman                 (Linux) Skip installing podman. yolo's podman
                                backend won't work without it.
  --allow-missing-checksum      Don't fail if the release lacks a .sha256 sidecar
                                (useful for forks / dev releases — discouraged).
  -h, --help                    Show this help.

The --skip-* and --matchlock-version flags are Linux-only and ignored on macOS,
where the only host-side dependency (Apple's `container` CLI) is flagged but not
installed by this script.

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
    --skip-setup)     SKIP_SETUP=1; shift ;;
    --skip-podman)    SKIP_PODMAN=1; shift ;;
    --allow-missing-checksum) ALLOW_MISSING_CHECKSUM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

# ---------------- Pre-flight: OS kind ----------------
# Branch on the kernel name: macOS needs an entirely different path (no
# /etc/os-release, no package manager, a darwin yolo binary) from Linux.
case "$(uname -s)" in
  Linux)  OS_KIND="linux";  YOLO_OS="linux" ;;
  Darwin) OS_KIND="macos";  YOLO_OS="darwin" ;;
  *) die "Unsupported OS: $(uname -s). Supported: Linux (Fedora/Ubuntu) and macOS." ;;
esac

# ---------------- Pre-flight: arch (common) ----------------
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m). yolo ships ${YOLO_OS}/amd64 and ${YOLO_OS}/arm64 only." ;;
esac

# ---------------- Pre-flight: required commands ----------------
# NB: curl is NOT required here — Fedora/Ubuntu cloud images don't ship it,
# and the Linux branch installs it as a host dependency. We require curl
# *after* that install (Linux) / in the macOS branch, before it's used.
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
need_cmd uname
need_cmd bash

if [ "$OS_KIND" = "linux" ]; then
  # ============================================================
  # Linux host setup (Fedora / Ubuntu): matchlock + podman + host config.
  # ============================================================
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
  log "  architecture: ${ARCH}"

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

  # curl is needed from here on (matchlock asset query, yolo download). It was
  # just installed above unless --skip-deps was passed; require it now.
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

  # ---------------- Install podman ----------------
  # Podman is the runtime for yolo's podman backend (GUI apps via Wayland,
  # stop/start state persistence). Installing it by default keeps `yolo
  # --backend podman` working out of the box; pass --skip-podman if you
  # only use the matchlock backend.
  #
  # On Fedora the podman package pulls in pasta (passt), netavark,
  # slirp4netns, and newuidmap (shadow-utils, base image) as deps. On
  # Ubuntu we explicitly pull in:
  #   - passt: provides pasta, podman 5.x's default rootless network
  #     helper. Not always a hard dep on older podman.
  #   - slirp4netns: fallback rootless network helper.
  #   - uidmap: provides newuidmap/newgidmap. Rootless podman refuses to
  #     run with "command required for rootless mode with multiple IDs:
  #     newuidmap" otherwise. Ubuntu's podman package doesn't pull this in.
  if [ "$SKIP_PODMAN" -eq 0 ]; then
    case "$DISTRO" in
      fedora)
        log "Installing podman (Fedora)"
        $SUDO dnf install -y --setopt=install_weak_deps=False podman
        ;;
      ubuntu)
        log "Installing podman + passt + slirp4netns + uidmap (Ubuntu)"
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
          --no-install-recommends podman passt slirp4netns uidmap
        ;;
    esac
  else
    warn "Skipping podman install (--skip-podman). 'yolo --backend podman' will not work without it."
  fi

  # ---------------- Host setup (matchlock + /dev/net/tun) ----------------
  # install.sh used to leave 'matchlock setup linux' as a manual follow-up
  # step; the install would succeed but users had to read the summary and
  # run sudo by hand before yolo would work. We escalate via $SUDO during
  # package install anyway, so it's no extra security surface to do the
  # setup steps in the same run.
  #
  # Also: the matchlock setup tightens /dev/net/tun to mode 0660 root:netdev
  # (its binary has cap_net_admin via setcap, so the lockdown doesn't
  # affect matchlock itself). This breaks rootless container tools that
  # open /dev/net/tun from inside a user namespace where supplementary
  # groups aren't mapped — most visibly, podman 5.x's default network
  # helper (pasta) on Ubuntu, which is shipped without file caps and
  # therefore relies on the device being world-accessible (kernel
  # docs recommend 0666 — see Documentation/networking/tuntap.rst).
  #
  # We restore the kernel-recommended permission (0666) and install a
  # udev rule so it survives reboots. CAP_NET_ADMIN inside the namespace
  # is still required for TUNSETIFF, so this doesn't grant additional
  # capability — DAC just stops gating the open() incidentally.
  if [ "$SKIP_SETUP" -eq 0 ]; then
    # Resolve which user to enroll. When called via sudo, $SUDO_USER is
    # the original caller; running as root directly leaves it unset and
    # we skip enrollment with a warning.
    if [ "$(id -u)" -eq 0 ]; then
      TARGET_USER="${SUDO_USER:-}"
    else
      TARGET_USER="$(id -un)"
    fi

    log "Running 'matchlock setup linux' (one-time host setup)"
    $SUDO matchlock setup linux

    if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
      log "Enrolling user '$TARGET_USER' (adds to kvm + netdev groups)"
      $SUDO matchlock setup user "$TARGET_USER"
    else
      warn "Skipping user enrollment — running as root with no SUDO_USER set."
      warn "Run 'sudo matchlock setup user <name>' for each user that should use yolo."
    fi

    # Restore kernel-recommended permission on /dev/net/tun for rootless
    # container tooling. Apply immediately (chmod) and persist across
    # reboots (udev rule).
    if [ -e /dev/net/tun ]; then
      log "Restoring /dev/net/tun permissions to 0666 (kernel-recommended default)"
      $SUDO chmod 0666 /dev/net/tun
    else
      warn "/dev/net/tun is not present yet; the tun kernel module may not be loaded. The udev rule below will apply when it is."
    fi

    udev_rule='# Installed by yolo'\''s install.sh.
#
# Restore the kernel-recommended permission (0666) on /dev/net/tun.
# Matchlock'\''s setup tightens this to 0660 root:netdev for itself —
# the matchlock binary has cap_net_admin via setcap, so the lockdown
# doesn'\''t affect it. But other rootless container tooling (notably
# podman 5.x'\''s default pasta network helper on Ubuntu, which doesn'\''t
# ship file caps) can'\''t open the device from inside a user namespace
# where supplementary groups aren'\''t mapped. CAP_NET_ADMIN is still
# required for TUNSETIFF, so 0666 doesn'\''t grant new privilege; DAC
# just stops gating the open() incidentally.
#
# See Documentation/networking/tuntap.rst for the upstream guidance.
KERNEL=="tun", MODE="0666"
'
    rule_path="/etc/udev/rules.d/99-yolo-tun.rules"
    log "Installing udev rule at $rule_path (persists across reboots)"
    printf '%s' "$udev_rule" | $SUDO tee "$rule_path" >/dev/null
    # Best effort — udevadm may not be present on every minimal image.
    if command -v udevadm >/dev/null 2>&1; then
      $SUDO udevadm control --reload-rules 2>/dev/null || true
      $SUDO udevadm trigger /dev/net/tun 2>/dev/null || true
    fi
  else
    warn "Skipping host setup (--skip-setup)"
  fi

else
  # ============================================================
  # macOS host: only the yolo binary is installed. The default backend is
  # Apple's `container`, which ships as a signed Apple package — we do NOT
  # install it here, we just flag whether it's present.
  # ============================================================
  log "Pre-flight: macOS host (darwin/${ARCH})"

  # macOS ships curl in the base system; it's needed for the yolo download.
  need_cmd curl

  if [ "$SKIP_MATCHLOCK" -eq 1 ] || [ "$SKIP_PODMAN" -eq 1 ] || \
     [ "$SKIP_SETUP" -eq 1 ] || [ "$SKIP_DEPS" -eq 1 ]; then
    warn "Linux-only --skip-* flags are ignored on macOS."
  fi

  if command -v container >/dev/null 2>&1; then
    CVER="$(container --version 2>/dev/null | head -n1 || true)"
    log "  Apple 'container' CLI found${CVER:+: $CVER}"
  else
    warn "Apple's 'container' CLI was not found on PATH."
    warn "It's yolo's default backend on macOS, but this installer does not install it."
    warn "Install the latest release from:"
    warn "    ${CONTAINER_INSTALL_URL}"
    warn "Then start the service with:  container system start"
  fi
fi

# ---------------- Resolve yolo download URL ----------------
# A pre-set $YOLO_BASE_URL (mirror / local release) wins; otherwise derive the
# GitHub Releases URL from YOLO_REPO/YOLO_VERSION.
if [ -n "$YOLO_VERSION" ]; then
  case "$YOLO_VERSION" in
    v*) YOLO_TAG="$YOLO_VERSION" ;;
    *)  YOLO_TAG="v$YOLO_VERSION" ;;
  esac
  : "${YOLO_BASE_URL:=https://github.com/${YOLO_REPO}/releases/download/${YOLO_TAG}}"
  YOLO_LABEL="$YOLO_TAG"
else
  : "${YOLO_BASE_URL:=https://github.com/${YOLO_REPO}/releases/latest/download}"
  YOLO_LABEL="latest"
fi

# Restrict curl to the base URL's scheme. The default (GitHub) is https-only;
# an explicit mirror/local override may legitimately be http:// or file://.
case "$YOLO_BASE_URL" in
  https://*) YOLO_DL_PROTO='=https' ;;
  http://*)  YOLO_DL_PROTO='=http' ;;
  file://*)  YOLO_DL_PROTO='=file' ;;
  *)         YOLO_DL_PROTO='=https' ;;
esac

YOLO_ASSET="yolo-${YOLO_OS}-${ARCH}"
YOLO_URL="${YOLO_BASE_URL}/${YOLO_ASSET}"
YOLO_SHA_URL="${YOLO_URL}.sha256"

# ---------------- Install yolo ----------------
log "Downloading yolo (${YOLO_LABEL}, ${YOLO_OS}/${ARCH})"
mkdir -p "$YOLO_PREFIX"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! curl -fL --proto "$YOLO_DL_PROTO" --tlsv1.2 \
      --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
      -o "$TMP/$YOLO_ASSET" "$YOLO_URL"; then
  die "failed to download $YOLO_URL — does a release exist for ${YOLO_LABEL} (${YOLO_OS}/${ARCH})?"
fi

# Checksum verification: required by default for the official repo so a
# silently-broken release can't ship an unverified binary. Opt-out exists for
# forks / dev tags via --allow-missing-checksum.
if curl -fsSL --proto "$YOLO_DL_PROTO" -o "$TMP/$YOLO_ASSET.sha256" "$YOLO_SHA_URL" 2>/dev/null; then
  log "Verifying SHA-256 checksum"
  set +e
  sha256_verify "$TMP" "$YOLO_ASSET"
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    2) die "no sha256 tool (sha256sum/shasum) available to verify the download" ;;
    *) die "checksum mismatch for $YOLO_ASSET" ;;
  esac
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
if [ "$OS_KIND" = "linux" ]; then
  cat <<EOF

${C_BLUE}==>${C_RESET} All done.

Next steps:
  - matchlock diagnose
$( [ "$SKIP_SETUP" -eq 1 ] && cat <<NOTE
  - Host setup was skipped (--skip-setup). Before using yolo run:
      sudo matchlock setup linux
      sudo matchlock setup user $(id -un)
      sudo chmod 0666 /dev/net/tun
NOTE
)
  - If your shell session pre-dates this install, log out and back in so
    the new kvm/netdev group memberships take effect.
  - cd into a project and run:  yolo

Versions:
  yolo:      ${YOLO_LABEL}  (${YOLO_PREFIX}/yolo)
  matchlock: $( [ "$SKIP_MATCHLOCK" -eq 1 ] && echo "(skipped)" || echo "${MATCHLOCK_VERSION:-latest}" )
  podman:    $( [ "$SKIP_PODMAN" -eq 1 ] && echo "(skipped)" || command -v podman >/dev/null 2>&1 && podman --version 2>/dev/null | awk '{print $3}' || echo "(not installed)" )

EOF
else
  if command -v container >/dev/null 2>&1; then
    CONTAINER_VER="$(container --version 2>/dev/null | head -n1 || true)"
    CONTAINER_STEP="  - Start the container service (if it isn't already):  container system start"
  else
    CONTAINER_VER="(not installed)"
    CONTAINER_STEP="  - Install Apple's 'container' (yolo's default backend on macOS):
      ${CONTAINER_INSTALL_URL}
    then start it with:  container system start"
  fi

  cat <<EOF

${C_BLUE}==>${C_RESET} All done.

Next steps:
${CONTAINER_STEP}
  - cd into a project and run:  yolo

Versions:
  yolo:      ${YOLO_LABEL}  (${YOLO_PREFIX}/yolo)
  container: ${CONTAINER_VER:-(not installed)}

EOF
fi
