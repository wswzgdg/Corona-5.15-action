#!/usr/bin/env bash

toolchain_dir() {
  local clang_version="$1"
  local root_dir="$2"
  case "$clang_version" in
    14) printf '%s/clang14/clang-r450784d' "$root_dir" ;;
    22) printf '%s/clang22/LLVM-22.1.0-Linux-X64' "$root_dir" ;;
    23) printf '%s/clang23/llvm-23' "$root_dir" ;;
    *)
      printf 'unsupported clang version: %s\n' "$clang_version" >&2
      return 1
      ;;
  esac
}

toolchain_bin_dir() {
  local clang_version="$1"
  local root_dir="$2"
  printf '%s/bin' "$(toolchain_dir "$clang_version" "$root_dir")"
}

toolchain_clang_bin() {
  local clang_version="$1"
  local root_dir="$2"
  printf '%s/clang' "$(toolchain_bin_dir "$clang_version" "$root_dir")"
}

clang_version_label() {
  local clang_bin="$1"
  local fallback_version="$2"
  local raw_label version_label
  raw_label="$($clang_bin -v 2>&1 | grep 'clang version' | head -n 1)"
  version_label="$(printf '%s' "$raw_label" | grep -oE '[0-9]+(\.[0-9]+){0,2}' | head -n 1)"
  if [ -n "$version_label" ]; then
    printf '%s' "$version_label"
  else
    printf '%s' "$fallback_version"
  fi
}

ensure_llvm23_toolchain() {
  local root_dir="$1"
  local clang_root
  clang_root="$(toolchain_dir 23 "$root_dir")"
  if [ -x "$clang_root/bin/clang" ]; then
    return 0
  fi

  . /etc/os-release
  local llvm_apt_codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
  wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | sudo gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg
  printf 'deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] http://apt.llvm.org/%s/ llvm-toolchain-%s main\n' "$llvm_apt_codename" "$llvm_apt_codename" | sudo tee /etc/apt/sources.list.d/llvm.list >/dev/null
  sudo apt update -y
  sudo apt install -y --no-install-recommends clang-23 lld-23 llvm-23
  mkdir -p "$root_dir/clang23"
  rm -rf "$clang_root"
  cp -a /usr/lib/llvm-23 "$clang_root"
}

ensure_android_clang14_toolchain() {
  local root_dir="$1"
  local clang_root
  clang_root="$(toolchain_dir 14 "$root_dir")"
  if [ -x "$clang_root/bin/clang" ]; then
    return 0
  fi

  mkdir -p "$clang_root"
  curl -fsSL "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android13-release/clang-r450784d.tar.gz" | tar -xz -C "$clang_root"
}

ensure_llvm22_toolchain() {
  local root_dir="$1"
  local clang_root parent_dir
  clang_root="$(toolchain_dir 22 "$root_dir")"
  if [ -x "$clang_root/bin/clang" ]; then
    return 0
  fi

  parent_dir="$root_dir/clang22"
  mkdir -p "$parent_dir"
  rm -rf "$clang_root"
  (
    cd "$parent_dir"
    aria2c -s16 -x16 -k1M https://github.com/llvm/llvm-project/releases/download/llvmorg-22.1.0/LLVM-22.1.0-Linux-X64.tar.xz -o clang.tar.xz
    tar -xvf clang.tar.xz -C ./
    rm -rf clang.tar.xz
  )
}

ensure_toolchain() {
  local clang_version="$1"
  local root_dir="$2"
  case "$clang_version" in
    14) ensure_android_clang14_toolchain "$root_dir" ;;
    22) ensure_llvm22_toolchain "$root_dir" ;;
    23) ensure_llvm23_toolchain "$root_dir" ;;
    *)
      printf 'unsupported clang version: %s\n' "$clang_version" >&2
      return 1
      ;;
  esac
}
