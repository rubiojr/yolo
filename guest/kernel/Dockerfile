# guest/kernel/Dockerfile — build yolo guest kernels (arm64 + x86_64).
#
# Adapted from matchlock's guest/kernel/Dockerfile
# (https://github.com/jingkaihe/matchlock). Two deliberate changes vs. upstream:
#
#   1. Both architectures are CROSS-compiled. Upstream builds x86_64 *natively*
#      (no ARCH/CROSS_COMPILE) and only cross-compiles arm64, which assumes an
#      x86_64 build host. yolo installs both cross toolchains and passes
#      ARCH/CROSS_COMPILE for each target, so scripts/build-kernels.sh produces
#      both kernels from *any* build host — including an Apple Silicon (arm64)
#      Mac driving `podman` (whose Linux VM is itself arm64).
#   2. The kernel .config files carry yolo's extra Docker/Podman netfilter
#      options (see guest/kernel/{arm64,x86_64}.config).
#
# Stages:
#   base           - toolchain (both cross targets) + kernel source (cached)
#   build-x86_64   - x86_64 kernel (cross-compiled) -> vmlinux
#   build-arm64    - arm64 kernel   (cross-compiled) -> arch/arm64/boot/Image
#   output-x86_64  - scratch image containing only /kernel
#   output-arm64   - scratch image containing only /kernel-arm64
#
# The kernel filenames (/kernel for x86_64, /kernel-arm64 for arm64) match
# matchlock's on-disk cache layout, so the artifacts can be fed straight to
# `matchlock run --kernel file://<path>`.
#
# Build via scripts/build-kernels.sh (podman). Manual example:
#   podman build --build-arg KERNEL_VERSION=6.19.8 \
#     --target output-arm64 -t localhost/yolo-guest-kernel:arm64 guest/kernel

ARG KERNEL_VERSION=6.19.8
ARG KERNEL_SOURCE_VERSION

# ---------------------------------------------------------------------------
# Base: toolchain (both cross targets) + kernel source
# ---------------------------------------------------------------------------
FROM ubuntu:22.04 AS base

ARG KERNEL_VERSION
ARG KERNEL_SOURCE_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential bc flex bison libelf-dev libssl-dev wget ca-certificates \
        gcc-aarch64-linux-gnu gcc-x86-64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    kernel_source_version="${KERNEL_SOURCE_VERSION:-$KERNEL_VERSION}"; \
    case "$kernel_source_version" in \
        *.*.0) kernel_source_version="${kernel_source_version%.0}" ;; \
    esac; \
    wget -qO /tmp/linux.tar.xz \
        "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kernel_source_version}.tar.xz" \
    && mkdir /tmp/linux-src \
    && tar xf /tmp/linux.tar.xz -C /tmp/linux-src --strip-components=1 \
    && rm /tmp/linux.tar.xz

# ---------------------------------------------------------------------------
# x86_64 kernel (Firecracker) — cross-compiled with x86_64-linux-gnu-
# ---------------------------------------------------------------------------
FROM base AS build-x86_64

COPY x86_64.config /tmp/linux-src/.config

RUN cd /tmp/linux-src \
    && make ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- olddefconfig \
    && make ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -j"$(nproc)" vmlinux

# ---------------------------------------------------------------------------
# arm64 kernel (Virtualization.framework) — cross-compiled with aarch64-linux-gnu-
# ---------------------------------------------------------------------------
FROM base AS build-arm64

COPY arm64.config /tmp/linux-src/.config

RUN cd /tmp/linux-src \
    && make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig \
    && make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image

# ---------------------------------------------------------------------------
# Output stages (scratch = only the kernel binary, nothing else)
# ---------------------------------------------------------------------------
FROM scratch AS output-x86_64
COPY --from=build-x86_64 /tmp/linux-src/vmlinux /kernel

FROM scratch AS output-arm64
COPY --from=build-arm64 /tmp/linux-src/arch/arm64/boot/Image /kernel-arm64
