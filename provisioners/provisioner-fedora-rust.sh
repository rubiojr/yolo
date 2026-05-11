#!/usr/bin/env bash
# provisioner-fedora-rust.sh
#
# Installs upstream Rust (rustup → stable toolchain by default) and a
# curated set of Cargo tools into a Fedora-based yolo VM.
#
# Override with $YOLO_RUST_CHANNEL (e.g. nightly, beta, 1.80.0).

set -euo pipefail

CHANNEL="${YOLO_RUST_CHANNEL:-stable}"

# ---------------- Non-interactive dnf ----------------
if ! grep -q '^assumeyes' /etc/dnf/dnf.conf 2>/dev/null; then
    echo 'assumeyes=True'          >> /etc/dnf/dnf.conf
    echo 'install_weak_deps=False' >> /etc/dnf/dnf.conf
fi

# ---------------- Base build tools ----------------
dnf -q install \
    curl-minimal ca-certificates git make gcc gcc-c++ \
    pkgconfig openssl-devel \
    tar gzip xz which findutils

# ---------------- rustup + toolchain ----------------
echo "==> [yolo:fedora-rust] installing rustup (channel: ${CHANNEL})"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain "$CHANNEL" --profile minimal

# Shell integration
cat > /etc/profile.d/cargo.sh <<'PROFILE'
export CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}
export PATH=$CARGO_HOME/bin:$PATH
PROFILE
chmod 0644 /etc/profile.d/cargo.sh

# Fresh fedora:44 ships no /root/.bashrc.
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

export CARGO_HOME=/root/.cargo
export PATH=/root/.cargo/bin:$PATH

# ---------------- Components ----------------
echo "==> [yolo:fedora-rust] adding rustfmt, clippy, rust-analyzer"
rustup component add rustfmt clippy rust-analyzer

# ---------------- Dev tooling ----------------
echo "==> [yolo:fedora-rust] installing Cargo tools"
cargo install --locked cargo-watch cargo-edit cargo-nextest

echo "==> [yolo:fedora-rust] done"
rustc --version
cargo --version
