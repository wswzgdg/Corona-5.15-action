# syntax=docker/dockerfile:1.6
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ARG LLVM_VERSION=23

# Kernel build deps + repo + git/git-lfs + zstd (matches the apt list previously
# installed inline in kernel-build.yml).
RUN apt-get update -y -qq \
 && apt-get install -y -qq --no-install-recommends \
      ca-certificates wget curl gnupg lsb-release sudo \
      git git-lfs \
      ccache flex bison dwarves libssl-dev libelf-dev bc python3 python-is-python3 \
      make cmake zip aria2 gawk rsync \
      binutils-aarch64-linux-gnu binutils-arm-linux-gnueabihf \
      tar gzip xz-utils bzip2 zstd device-tree-compiler libc6-dev-i386 \
      patch \
      repo \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh cache delete / gh release download).
RUN install -dm 0755 /etc/apt/keyrings \
 && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update -y -qq \
 && apt-get install -y -qq --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# LLVM/Clang 23 from apt.llvm.org (matches ensure_llvm23_toolchain).
RUN . /etc/os-release \
 && CN="${UBUNTU_CODENAME:-${VERSION_CODENAME}}" \
 && wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] http://apt.llvm.org/${CN}/ llvm-toolchain-${CN} main" > /etc/apt/sources.list.d/llvm.list \
 && apt-get update -y -qq \
 && apt-get install -y -qq --no-install-recommends \
      clang-${LLVM_VERSION} lld-${LLVM_VERSION} llvm-${LLVM_VERSION} \
 && rm -rf /var/lib/apt/lists/*

# Android clang14 (GoogleSource archive) — same path layout as ensure_android_clang14_toolchain.
RUN mkdir -p /opt/clang14/clang-r450784d \
 && curl -fsSL "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android13-release/clang-r450784d.tar.gz" \
      | tar -xz -C /opt/clang14/clang-r450784d

# LLVM 22 (upstream release tarball) — same path layout as ensure_llvm22_toolchain.
RUN mkdir -p /opt/clang22 \
 && cd /opt/clang22 \
 && curl -fsSL https://github.com/llvm/llvm-project/releases/download/llvmorg-22.1.0/LLVM-22.1.0-Linux-X64.tar.xz -o clang.tar.xz \
 && tar -xf clang.tar.xz -C ./ \
 && rm -f clang.tar.xz

# repo launcher (matches kernel-build.yml).
RUN curl -sSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo \
 && chmod +x /usr/local/bin/repo

ENV PATH="/usr/lib/llvm-${LLVM_VERSION}/bin:${PATH}"
ENV PREBUILT_CLANG_ROOT=/usr/lib/llvm-23
ENV PREBUILT_CLANG14_ROOT=/opt/clang14/clang-r450784d
ENV PREBUILT_CLANG22_ROOT=/opt/clang22/LLVM-22.1.0-Linux-X64
