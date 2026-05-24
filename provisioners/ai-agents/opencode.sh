#!/usr/bin/env bash
# ai-agents/opencode.sh — install opencode (sst/opencode) in a yolo VM.
#
# Authenticate inside the VM by setting one of the supported provider keys:
#   OPENAI_API_KEY, ANTHROPIC_API_KEY, GROQ_API_KEY, OPENROUTER_API_KEY, ...
# See https://opencode.ai for the full list.

set -euo pipefail

# ---------------- Detect distro / package manager ----------------
PKG=""
if command -v dnf >/dev/null 2>&1; then
    PKG=dnf
elif command -v apt-get >/dev/null 2>&1; then
    PKG=apt
else
    echo "==> [yolo:ai-agent/opencode] no supported package manager (dnf/apt) found" >&2
    exit 1
fi

# ---------------- Prereqs ----------------
case "$PKG" in
    dnf)
        # Non-interactive dnf
        if ! grep -q '^assumeyes' /etc/dnf/dnf.conf 2>/dev/null; then
            echo 'assumeyes=True'          >> /etc/dnf/dnf.conf
            echo 'install_weak_deps=False' >> /etc/dnf/dnf.conf
        fi
        dnf -q install curl-minimal ca-certificates unzip tar gzip
        ;;
    apt)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            curl ca-certificates unzip tar gzip
        ;;
esac

# ---------------- opencode ----------------
echo "==> [yolo:ai-agent/opencode] installing opencode (latest)"
# Official installer script — drops a binary into ~/.opencode/bin
curl -fsSL https://opencode.ai/install | bash

# Symlink into /usr/local/bin so it's on PATH for any shell.
if [ -x /root/.opencode/bin/opencode ]; then
    ln -sf /root/.opencode/bin/opencode /usr/local/bin/opencode
fi

# Also expose it via /etc/profile.d for login shells.
cat > /etc/profile.d/opencode.sh <<'PROFILE'
if [ -d "$HOME/.opencode/bin" ]; then
    export PATH="$HOME/.opencode/bin:$PATH"
fi
PROFILE
chmod 0644 /etc/profile.d/opencode.sh

echo "==> [yolo:ai-agent/opencode] done"
opencode --version 2>&1 | head -1 || true
echo
echo "Set a provider API key (ANTHROPIC_API_KEY / OPENAI_API_KEY / ...) and run: opencode"
