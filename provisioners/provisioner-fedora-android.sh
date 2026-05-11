#!/usr/bin/env bash
# provisioner-fedora-android.sh
#
# Installs the Android SDK command-line tools + a JDK suitable for
# Android/Kotlin/Compose development into a Fedora-based yolo VM.
#
# This intentionally does NOT install Android Studio (GUI). It installs:
#   - Temurin JDK 21 (latest LTS supported by AGP 8.x)
#   - Android cmdline-tools (latest)
#   - platform-tools (adb), the latest stable platform + build-tools
#
# Env overrides:
#   YOLO_ANDROID_API=35
#   YOLO_ANDROID_BUILD_TOOLS=35.0.0
#   YOLO_JDK_VERSION=21

set -euo pipefail

API_LEVEL="${YOLO_ANDROID_API:-35}"
BUILD_TOOLS="${YOLO_ANDROID_BUILD_TOOLS:-35.0.0}"
JDK_VERSION="${YOLO_JDK_VERSION:-21}"

ANDROID_HOME=/opt/android-sdk
CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

case "$(uname -m)" in
    x86_64)  JDK_ARCH=x64 ;;
    aarch64) JDK_ARCH=aarch64 ;;
    *)       echo "unsupported arch: $(uname -m)"; exit 1 ;;
esac

# ---------------- Non-interactive dnf ----------------
if ! grep -q '^assumeyes' /etc/dnf/dnf.conf 2>/dev/null; then
    echo 'assumeyes=True'          >> /etc/dnf/dnf.conf
    echo 'install_weak_deps=False' >> /etc/dnf/dnf.conf
fi

# ---------------- Base tools ----------------
dnf -q install \
    curl-minimal ca-certificates tar gzip xz unzip git make \
    which findutils

# ---------------- JDK (Temurin) ----------------
JDK_PREFIX="/opt/jdk-${JDK_VERSION}"
if [ ! -d "$JDK_PREFIX" ]; then
    echo "==> [yolo:fedora-android] installing Temurin JDK ${JDK_VERSION} (${JDK_ARCH})"
    JDK_URL="https://api.adoptium.net/v3/binary/latest/${JDK_VERSION}/ga/linux/${JDK_ARCH}/jdk/hotspot/normal/eclipse?project=jdk"
    mkdir -p /opt
    tmp=$(mktemp -d)
    curl -fsSL "$JDK_URL" -o "$tmp/jdk.tar.gz"
    mkdir -p "$JDK_PREFIX"
    tar -xzf "$tmp/jdk.tar.gz" -C "$JDK_PREFIX" --strip-components=1
    rm -rf "$tmp"
fi

# ---------------- Android cmdline-tools ----------------
if [ ! -d "$ANDROID_HOME/cmdline-tools/latest" ]; then
    echo "==> [yolo:fedora-android] installing Android cmdline-tools"
    mkdir -p "$ANDROID_HOME/cmdline-tools"
    tmp=$(mktemp -d)
    curl -fsSL "$CMDLINE_URL" -o "$tmp/clt.zip"
    unzip -q "$tmp/clt.zip" -d "$tmp"
    mv "$tmp/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
    rm -rf "$tmp"
fi

# ---------------- Shell integration ----------------
cat > /etc/profile.d/android.sh <<PROFILE
export JAVA_HOME=${JDK_PREFIX}
export ANDROID_HOME=${ANDROID_HOME}
export ANDROID_SDK_ROOT=${ANDROID_HOME}
export PATH=\$JAVA_HOME/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH
PROFILE
chmod 0644 /etc/profile.d/android.sh

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

# Make tools available for the rest of THIS script.
export JAVA_HOME="$JDK_PREFIX"
export ANDROID_HOME ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

echo "==> [yolo:fedora-android] accepting SDK licenses"
# `yes | sdkmanager` triggers SIGPIPE in `yes` once sdkmanager stops reading,
# which combined with `set -o pipefail` aborts the script. Disable pipefail
# just for this step, and feed a finite number of "y" lines so `yes` exits
# normally even without the SIGPIPE handling.
set +o pipefail
printf 'y\n%.0s' {1..200} | sdkmanager --licenses >/dev/null
set -o pipefail

echo "==> [yolo:fedora-android] installing platform-tools, platforms;android-${API_LEVEL}, build-tools;${BUILD_TOOLS}"
sdkmanager --install \
    "platform-tools" \
    "platforms;android-${API_LEVEL}" \
    "build-tools;${BUILD_TOOLS}" \
    >/dev/null

echo "==> [yolo:fedora-android] done"
java -version
sdkmanager --version
echo "ANDROID_HOME=$ANDROID_HOME"
