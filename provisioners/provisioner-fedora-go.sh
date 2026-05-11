#!/usr/bin/env bash
# provisioner-fedora-go.sh
#
# Installs upstream Go (from go.dev) and a curated set of popular Go dev
# tools into a Fedora-based yolo VM. Plain bash — no rugo/Go dependency
# in the guest. Runs as root inside the VM via `matchlock exec -i -- bash`.
#
# Override the Go version with $YOLO_GO_VERSION (set on the host; yolo
# propagates it via the matchlock exec environment).

set -euo pipefail

# ---------------- Arch ----------------
case "$(uname -m)" in
    x86_64)  GOARCH=amd64 ;;
    aarch64) GOARCH=arm64 ;;
    *)       echo "unsupported arch: $(uname -m)"; exit 1 ;;
esac

# ---------------- Go version ----------------
GO_VERSION="${YOLO_GO_VERSION:-}"
if [ -z "$GO_VERSION" ]; then
    # https://go.dev/VERSION?m=text → "go1.26.3\ntime ..."
    GO_VERSION="$(curl -fsSL https://go.dev/VERSION?m=text \
                   | head -n1 | sed 's/^go//' 2>/dev/null || true)"
fi
[ -z "$GO_VERSION" ] && GO_VERSION="1.24.0"

GO_URL="https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz"

echo "==> [yolo:fedora-go] installing Go ${GO_VERSION} (${GOARCH})"

# ---------------- Non-interactive dnf ----------------
if ! grep -q '^assumeyes' /etc/dnf/dnf.conf 2>/dev/null; then
    echo 'assumeyes=True'          >> /etc/dnf/dnf.conf
    echo 'install_weak_deps=False' >> /etc/dnf/dnf.conf
fi

# ---------------- Base tooling ----------------
dnf -q install \
    tar gzip xz which findutils ca-certificates curl-minimal \
    git make gcc

# ---------------- Install upstream Go ----------------
[ -d /usr/local/go ] && rm -rf /usr/local/go
curl -fsSL "$GO_URL" | tar -C /usr/local -xz

# ---------------- Shell integration ----------------
# /etc/profile.d/go.sh is sourced by login shells (yolo opens bash -l).
cat > /etc/profile.d/go.sh <<'PROFILE'
export PATH=/usr/local/go/bin:$HOME/go/bin:$PATH
export GOPATH=$HOME/go
PROFILE
chmod 0644 /etc/profile.d/go.sh

# Fresh fedora:44 ships no /root/.bashrc; create one that sources /etc/bashrc
# so non-login interactive bash also picks up /etc/profile.d/*.sh.
if [ ! -f /root/.bashrc ]; then
    cat > /root/.bashrc <<'BASHRC'
if [ -f /etc/bashrc ]; then . /etc/bashrc; fi
BASHRC
fi
if [ ! -f /root/.bash_profile ]; then
    cat > /root/.bash_profile <<'BP'
if [ -f ~/.bashrc ]; then . ~/.bashrc; fi
BP
fi

# Make Go available for the rest of THIS script.
export PATH=/usr/local/go/bin:/root/go/bin:$PATH
export GOPATH=/root/go

echo "==> [yolo:fedora-go] Go version:"
/usr/local/go/bin/go version

echo "==> [yolo:fedora-go] installing dev tooling"
for pkg in \
    golang.org/x/tools/gopls@latest \
    honnef.co/go/tools/cmd/staticcheck@latest \
    github.com/go-delve/delve/cmd/dlv@latest \
    golang.org/x/tools/cmd/goimports@latest \
    mvdan.cc/gofumpt@latest \
    github.com/golangci/golangci-lint/cmd/golangci-lint@latest
do
    /usr/local/go/bin/go install "$pkg"
done

echo "==> [yolo:fedora-go] done. Installed into /usr/local/go and /root/go/bin"
echo "    Try: go version && gopls version && dlv version"
