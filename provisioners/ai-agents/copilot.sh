#!/usr/bin/env bash
# ai-agents/copilot.sh — install GitHub Copilot CLI in a yolo VM.
#
# Upstream: https://github.com/github/copilot-cli
# Requires an active Copilot subscription. Authenticate inside the VM via:
#   copilot                # then use /login slash command
# or set GH_TOKEN / GITHUB_TOKEN (fine-grained PAT with "Copilot Requests"
# permission) in the VM environment before launching.

set -euo pipefail

# ---------------- Non-interactive dnf ----------------
if ! grep -q '^assumeyes' /etc/dnf/dnf.conf 2>/dev/null; then
    echo 'assumeyes=True'          >> /etc/dnf/dnf.conf
    echo 'install_weak_deps=False' >> /etc/dnf/dnf.conf
fi

# ---------------- Prereqs for the installer ----------------
dnf -q install curl-minimal ca-certificates tar gzip xz

# ---------------- Copilot CLI ----------------
# The official installer drops a self-contained binary into $PREFIX/bin/
# (defaults to /usr/local/bin when run as root). No Node.js needed.
echo "==> [yolo:ai-agent/copilot] installing GitHub Copilot CLI (latest)"
curl -fsSL https://gh.io/copilot-install | bash

echo "==> [yolo:ai-agent/copilot] done"
copilot --version 2>&1 | head -1 || true
echo
echo "Launch inside the VM with:  copilot"
echo "Then use the /login slash command, or export GH_TOKEN before launching."
