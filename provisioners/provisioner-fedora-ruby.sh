#!/usr/bin/env bash
# provisioner-fedora-ruby.sh
#
# Installs Ruby + bundler into a Fedora-based yolo VM. Uses Fedora's
# packaged Ruby by default (current at 3.x). Set $YOLO_RUBY_VERSION to
# pin a specific stream (e.g. "3.3"); the script will try `dnf module`
# to honor it.

set -euo pipefail

RUBY_VERSION="${YOLO_RUBY_VERSION:-}"

# ---------------- Non-interactive dnf ----------------
if ! grep -q '^assumeyes' /etc/dnf/dnf.conf 2>/dev/null; then
    echo 'assumeyes=True'          >> /etc/dnf/dnf.conf
    echo 'install_weak_deps=False' >> /etc/dnf/dnf.conf
fi

# ---------------- Base build tools (gems often need native ext) ----------------
dnf -q install \
    git make gcc gcc-c++ pkgconfig redhat-rpm-config \
    libyaml-devel openssl-devel zlib-devel readline-devel \
    sqlite-devel libxml2-devel libxslt-devel \
    tar gzip xz which findutils ca-certificates curl-minimal

# ---------------- Ruby ----------------
if [ -n "$RUBY_VERSION" ]; then
    echo "==> [yolo:fedora-ruby] installing ruby:${RUBY_VERSION} module"
    if ! dnf -q module enable "ruby:${RUBY_VERSION}" 2>/dev/null; then
        echo "(no ruby:${RUBY_VERSION} module on this Fedora; falling back to default)"
    fi
fi
dnf -q install ruby ruby-devel rubygems

echo "==> [yolo:fedora-ruby] Ruby version:"
ruby --version

# ---------------- Bundler + common gems ----------------
echo "==> [yolo:fedora-ruby] installing bundler"
gem install --no-document bundler

# Make `gem install` go to a writable user prefix even when running as root
# so /root/.gem/ruby/<x>/bin works across `gem install` and `bundle config`.
cat > /etc/profile.d/ruby.sh <<'PROFILE'
export GEM_HOME=${GEM_HOME:-$HOME/.gem/$(ruby -e 'print RUBY_VERSION' 2>/dev/null || echo default)}
export PATH=$GEM_HOME/bin:$PATH
PROFILE
chmod 0644 /etc/profile.d/ruby.sh

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

echo "==> [yolo:fedora-ruby] done"
ruby --version
bundle --version
