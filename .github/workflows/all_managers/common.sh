#!/usr/bin/env bash
set -e

MANAGER="$1"
KERNEL_SUFFIX="${2:-}"
SUSFS_MODE="${3:-on}"
USE_KPN="${4:-false}"
VERSION_NAME_RAW="${5:-eternitylonely}"
LLVM_CLANG_VERSION="${CLANG_VERSION:-22}"
WORKDIR="$(pwd)"
export WORKDIR

source "$WORKDIR/.github/workflows/all_managers/toolchain.sh"

version_name_with_author() {
  local raw_name="${1:-eternitylonely}"
  printf '%s@Bai' "$raw_name"
}

VERSION_NAME_TRIMMED="${VERSION_NAME_RAW//[[:space:]]/}"
VERSION_NAME_FULL=""
if [ -n "$VERSION_NAME_TRIMMED" ]; then
  VERSION_NAME_FULL="$(version_name_with_author "$VERSION_NAME_RAW")"
fi

export PATH="/usr/lib/ccache:$PATH"
export PATH="$(toolchain_bin_dir "$LLVM_CLANG_VERSION" "$WORKDIR"):$PATH"
export LD_LIBRARY_PATH="$(toolchain_lib_dir "$LLVM_CLANG_VERSION" "$WORKDIR")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ---- 依赖安装 ----
if [ -z "${SKIP_APT:-}" ]; then
  sudo apt-mark hold firefox 2>/dev/null
  sudo apt-mark hold libc-bin 2>/dev/null
  sudo apt-get purge -y man-db
  sudo rm -rf /var/lib/man-db/auto-update
  sudo apt-get update -y -qq
  sudo apt-get install -y --no-install-recommends \
    binutils python-is-python3 ccache repo \
    flex bison dwarves bc make cmake zip aria2 gnupg gawk rsync \
    binutils-aarch64-linux-gnu binutils-arm-linux-gnueabihf \
    tar gzip xz-utils bzip2 device-tree-compiler libc6-dev-i386
fi

# ---- 工具链 ----
ensure_toolchain "$LLVM_CLANG_VERSION" "$WORKDIR"

# ---- 解析仓库信息 ----
if [ "${ANDROID_RELEASE:-16}" = "15" ]; then
  VENDOR_BRANCH="oneplus/sm8550_v_15.0.0_oneplus11"
  COMMON_REPO="Corona-oplus-kernel/5.15oplus-c15"
  COMMON_BRANCH="Corona"
else
  VENDOR_BRANCH="oneplus/sm8550_b_16.0.0_oneplus_11"
  COMMON_REPO="Corona-oplus-kernel/kernel_common_oplus"
  COMMON_BRANCH="android13-5.15-lts"
fi
VENDOR_URL="https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8550"
if [ -n "${KERNEL_COMMON_TOKEN:-}" ]; then
  COMMON_URL="https://${KERNEL_COMMON_TOKEN}@github.com/${COMMON_REPO}.git"
else
  COMMON_URL="https://github.com/${COMMON_REPO}.git"
fi

# ---- 函数：clone common + 清理 ----
clone_common_and_clean() {
  local target="$1"
  rm -rf "$target/common" "$target/AnyKernel3"
  if [ -n "${COMMON_COMMIT:-}" ]; then
    echo "克隆 common 仓库（指定提交: $COMMON_COMMIT）"
    git init "$target/common"
    cd "$target/common"
    git remote add origin "$COMMON_URL"
    git fetch --depth=1 origin "$COMMON_COMMIT"
    git checkout FETCH_HEAD
    cd -
  else
    echo "克隆 common 仓库（分支: $COMMON_BRANCH 最新）"
    git clone --depth=1 "$COMMON_URL" -b "$COMMON_BRANCH" "$target/common"
  fi
  rm -f "$target/common/android/abi_gki_protected_exports_*"
  sed -i 's/ -dirty//g' "$target/common/scripts/setlocalversion" 2>/dev/null
  sed -i "\$i res=\$(echo \"\$res\" | sed 's/ -dirty//g')" \
    "$target/common/scripts/setlocalversion" 2>/dev/null
}

# ---- out 缓存仓库（git push 模式，统一 none 分支） ----
OUT_CACHE_REPO="Corona-oplus-kernel/common-makeout"

restore_out_cache() {
  local cache_dir="$WORKDIR/out_cache"
  local out_dir="$WORKDIR/kernel_workspace/kernel_platform/common/out"
  rm -rf "$cache_dir"
  if git clone --depth=1 "https://${KERNEL_COMMON_TOKEN:-}@github.com/${OUT_CACHE_REPO}.git" -b none "$cache_dir" 2>/dev/null; then
    mkdir -p "$out_dir"
    cp -a "$cache_dir/." "$out_dir/" 2>/dev/null || true
    echo "out: restored from none branch"
  else
    rm -rf "$cache_dir"
    echo "out: none branch not found, fresh build"
  fi
}

save_out_cache() {
  local out_dir="$WORKDIR/kernel_workspace/kernel_platform/common/out"
  [ ! -d "$out_dir" ] && return 0
  [ "$MANAGER" != "none" ] && echo "out: skip save (only none branch persisted)" && return 0
  local git_dir="$WORKDIR/out_cache_git"
  rm -rf "$git_dir"
  (
    set +e
    git init -b none "$git_dir"
    cd "$git_dir" || return 0
    git remote add origin "https://${KERNEL_COMMON_TOKEN:-}@github.com/${OUT_CACHE_REPO}.git"
    rsync -a --delete "$out_dir/" ./
    git add -A
    if git -c user.email="ci@github.com" -c user.name="CI Bot" commit -m "out: none $(date -u +%Y%m%d-%H%M%S)" >/dev/null 2>&1; then
      git push --force origin none </dev/null >/dev/null 2>&1 || true
      echo "out: saved to none branch (force push)"
    else
      echo "out: no changes, skip push"
    fi
  )
  rm -rf "$git_dir"
}

# ---- 源码准备 ----
if [ -z "${SKIP_SOURCE_PREP:-}" ]; then
  if [ ! -d kernel_workspace/.git ]; then
    rm -rf kernel_workspace
    GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_TIME=20 GIT_HTTP_LOW_SPEED_LIMIT=1000 \
      git clone --depth=1 -b "$VENDOR_BRANCH" "$VENDOR_URL" kernel_workspace || {
      echo "::warning::vendor 仓库不可用，跳过 vendor clone"
      mkdir -p kernel_workspace/kernel_platform
    }
  else
    echo "kernel_workspace 已存在，跳过 clone"
  fi

  cd kernel_workspace
  rm -rf "$WORKDIR/out_zips"
  cd kernel_platform
  clone_common_and_clean "."
  cd ../
else
  echo "复用预置 workspace，跳过 repo sync"
  rm -rf "$WORKDIR/out_zips"
  cd kernel_workspace/kernel_platform
  clone_common_and_clean "."
fi

# ---- 管理器安装 ----
cd "$WORKDIR/kernel_workspace/kernel_platform/common"

case "$MANAGER" in
  sukisu)
    curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/refs/heads/dev/kernel/setup.sh" | bash -s dev
    if [ -n "$VERSION_NAME_FULL" ] && [ -f "./KernelSU/kernel/Kbuild" ]; then
      sed -i 's|^KSU_VERSION_FULL := .*|KSU_VERSION_FULL := $(if $(call git_short_sha),v$(VERSION_TAG)-'"$VERSION_NAME_FULL"',v$(VERSION_TAG)-$(REPO_NAME)-unknown@unknown)|' ./KernelSU/kernel/Kbuild
    fi
    ;;
  resukisu)
    curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/refs/heads/dev/kernel/setup.sh" | bash -s dev
    ;;
  ksunext)
    ksu_branch="dev"
    [ "$SUSFS_MODE" = "on" ] && ksu_branch="dev-susfs"
    curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/refs/heads/${ksu_branch}/kernel/setup.sh" | bash -s "$ksu_branch"
    ;;
  ksu)
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/refs/heads/main/kernel/setup.sh" | bash -s dev
    ;;
  kowsu)
    curl -LSs "https://raw.githubusercontent.com/KOWX712/KernelSU/refs/heads/master/kernel/setup.sh" | bash -s master
    ;;
  none)
    ;;
  *)
    echo "Unknown manager: $MANAGER"; exit 1;;
esac

cd "$WORKDIR/kernel_workspace/kernel_platform"

# ---- SUSFS 补丁 ----
if [ "$MANAGER" != "none" ] && [ "$SUSFS_MODE" = "on" ]; then
  rm -rf susfs4ksu
  SUSFS_CLONE_OK=
  for _try in 1 2 3; do
    if GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_TIME=20 GIT_HTTP_LOW_SPEED_LIMIT=1000 \
      git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu susfs4ksu \
      -b "gki-${ANDROID_VERSION}-${KERNEL_VERSION}" 2>/dev/null; then
      SUSFS_CLONE_OK=1
      break
    fi
    echo "SUSFS clone failed (attempt $_try/3), retrying in 15s..."
    sleep 15
  done
  if [ -n "$SUSFS_CLONE_OK" ]; then
    cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch ./common/
    cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
    cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
    cd "$WORKDIR/kernel_workspace/kernel_platform/common"
    patch -p1 -F 3 < "50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch" || true
    cd "$WORKDIR/kernel_workspace/kernel_platform"
  else
    echo "::warning::SUSFS 仓库 3 次重试后仍不可用，跳过 SUSFS 补丁"
    exit 1
  fi
fi

# ---- KSU compat 补丁（仅对未自带 SUSFS 的管理器打） ----
if [ "$SUSFS_MODE" = "on" ] && [ "$MANAGER" != "none" ] && [ -d "./common/KernelSU" ]; then
  if grep -rq CONFIG_KSU_SUSFS ./common/KernelSU/kernel/ 2>/dev/null; then
    echo "KSU 源码已自带 SUSFS 集成，跳过 compat patch"
  elif grep -q "hook/lsm_hook.o" ./common/KernelSU/kernel/Kbuild 2>/dev/null; then
    echo "KSU 源码含独立 hook 架构（如 SukiSU），跳过不兼容的 compat patch"
  else
    cp ./susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./common/KernelSU/
    cd "$WORKDIR/kernel_workspace/kernel_platform/common/KernelSU"
    patch -p1 -F 3 < 10_enable_susfs_for_ksu.patch || true
    cd "$WORKDIR/kernel_workspace/kernel_platform"
  fi
fi

# ---- defconfig 配置 ----
DEFCONFIG=./common/arch/arm64/configs/gki_defconfig
if [ "$MANAGER" != "none" ]; then
  {
    echo "CONFIG_KSU=y"
    if [ "$SUSFS_MODE" = "on" ]; then
      echo "CONFIG_KSU_SUSFS=y"
      echo "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y"
    fi
    if [ "$MANAGER" = "resukisu" ] && [ -n "$VERSION_NAME_FULL" ]; then
      echo "CONFIG_KSU_FULL_NAME_FORMAT=\"%TAG_NAME%-${VERSION_NAME_FULL}\""
    fi
    if [ "$USE_KPN" != "true" ] && [ "$MANAGER" = "sukisu" ]; then
      echo "CONFIG_KPM=y"
    fi
  } >> "$DEFCONFIG"
fi

sed -i 's/check_defconfig//' ./common/build.config.gki
touch ./common/.scmversion

# ---- Droidspaces 容器支持 ----
if [ "${DROIDSPACES_ENABLE:-true}" = "true" ]; then
  echo "正在启用 Droidspaces 容器支持..."
  REPO_URL="https://github.com/$GITHUB_REPOSITORY/raw/refs/heads/$GITHUB_REF_NAME/droidspaces_patch"

  for p in \
    01.disable_crc_checks_for_lkms.patch \
    02.fix_restore_cgroup_file_prefix_handling.patch \
    "03.5.15+_use_android_abi_padding_for_posix_mqueue.patch" \
    04.sysvipc_task_struct.patch; do
    wget "$REPO_URL/$p" -O "$p" 2>/dev/null
    patch -p1 -F 3 < "$p" -d ./common || true
  done

  if [ -f ./common/drivers/misc/ntsync.c ]; then
    echo "common 源码已含 ntsync.c，跳过 NTSync 补丁"
  else
    wget "$REPO_URL/ntsync_compat_android13-5.15.patch" -O ntsync_compat.patch 2>/dev/null
    patch -p1 -F 3 < ntsync_compat.patch -d ./common || true
  fi

  for cfg in \
    CONFIG_NTSYNC=y CONFIG_SYSVIPC=y CONFIG_POSIX_MQUEUE=y \
    CONFIG_IPC_NS=y CONFIG_PID_NS=y CONFIG_DEVTMPFS=y \
    CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y \
    CONFIG_NETFILTER_XT_TARGET_REJECT=y \
    CONFIG_NETFILTER_XT_TARGET_LOG=y \
    CONFIG_NETFILTER_XT_MATCH_RECENT=y \
    CONFIG_IP_SET=y CONFIG_IP_SET_HASH_IP=y \
    CONFIG_IP_SET_HASH_NET=y CONFIG_NETFILTER_XT_SET=y \
    CONFIG_TMPFS_XATTR=y; do
    grep -q "^${cfg}" "$DEFCONFIG" || echo "$cfg" >> "$DEFCONFIG"
  done
fi

# ---- 内核版本后缀 ----
if [ -n "$KERNEL_SUFFIX" ]; then
  echo "替换内核版本名称: $KERNEL_SUFFIX"
  sed -i "\$s|echo \"\$res\"|echo \"-${KERNEL_SUFFIX}\"|" ./common/scripts/setlocalversion
fi

# ---- 编译 ----
cd "$WORKDIR/kernel_workspace/kernel_platform/common"
export KBUILD_BUILD_USER="ZakoBai"
export KBUILD_BUILD_HOST="XinRan"

LDCACHE_DIR="${WORKDIR}/kernel_workspace/.thinlto-cache"
mkdir -p "$LDCACHE_DIR"
LD_LINKER="$(command -v ld.lld)"
if [ -n "$LD_LINKER" ]; then
  LD_WRAPPER="${WORKDIR}/kernel_workspace/ld-wrapper"
  printf '#!/bin/bash\nexec "%s" "$@" --thinlto-cache-dir="%s" --thinlto-cache-policy=cache_size_bytes=3g --thinlto-jobs=%s\n' \
    "$LD_LINKER" "$LDCACHE_DIR" "$(nproc --all)" > "$LD_WRAPPER"
  chmod +x "$LD_WRAPPER"
else
  LD_WRAPPER=""
fi

ROOT_REAL_PATH="$(cd "$WORKDIR/kernel_workspace/kernel_platform" && pwd -P)"

MAKE_ARGS=(
  -j$(nproc --all) LLVM=1 ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CC="ccache clang"
  LD="$LD_WRAPPER"
  HOSTLD="$LD_WRAPPER"
  O=out
  KCFLAGS+=-O2
  KCFLAGS+=-Wno-error
  KCFLAGS+="-fdebug-prefix-map=$ROOT_REAL_PATH=."
  KCFLAGS+="-fmacro-prefix-map=$ROOT_REAL_PATH=."
  KCFLAGS+="-ffile-prefix-map=$ROOT_REAL_PATH=."
)

make "${MAKE_ARGS[@]}" gki_defconfig

# 置空 retry 源文件，fix_retry.py 在链接失败时动态生成
: > "$WORKDIR/kernel_workspace/kernel_platform/common/kernelsu_retry.c"

__retry_make_Image() {
  local max_attempts=7 attempt=1
  local WEAK_RETRY="$WORKDIR/kernel_workspace/kernel_platform/common/kernelsu_retry.c"
  local FIX_SCRIPT="$WORKDIR/.github/workflows/all_managers/fix_retry.py"

  while [ $attempt -le $max_attempts ]; do
    echo "--- make Image (attempt $attempt/$max_attempts) ---"
    set +e
    make "${MAKE_ARGS[@]}" Image 2>&1 | tee /tmp/make_image.log
    local rc=${PIPESTATUS[0]}
    set -e
    if [ $rc -eq 0 ]; then
      echo "Image 编译成功"
      return 0
    fi
    python3 "$FIX_SCRIPT" /tmp/make_image.log "$WEAK_RETRY" || true
    rm -f "$WORKDIR/kernel_workspace/kernel_platform/common/out/kernelsu_retry.o"
    rm -f "$WORKDIR/kernel_workspace/kernel_platform/common/out/drivers/kernelsu/ksu_weak_stubs.o"
    # 删除 .*.cmd 缓存文件让 make 重新解析 Makefile 中新增的 obj-y
    find "$WORKDIR/kernel_workspace/kernel_platform/common/out/drivers/kernelsu" -name ".*.cmd" -delete 2>/dev/null || true
    find "$WORKDIR/kernel_workspace/kernel_platform/common/out/drivers/kernelsu" -name "built-in.a" -delete 2>/dev/null || true
    rm -f "$WORKDIR/kernel_workspace/kernel_platform/common/out/drivers/kernelsu/core/ksu_weak_stubs.o"
    rm -rf "$LDCACHE_DIR" && mkdir -p "$LDCACHE_DIR"
    attempt=$((attempt + 1))
    continue
  done
  echo "::error::Image 编译在 $max_attempts 次尝试后仍失败"
  return 1
}

restore_out_cache

# 编译前应用已知兼容性补丁
python3 "$WORKDIR/.github/workflows/all_managers/ksu_compat_patches.py" || true
__retry_make_Image || { echo "编译失败，跳过打包"; exit 1; }
save_out_cache || true

# ---- 打包 ----
if [ -z "${SKIP_PACKAGE:-}" ]; then
  source "$WORKDIR/.github/workflows/all_managers/packaging.sh"
  cd "$WORKDIR/kernel_workspace/kernel_platform"
  AK3_URL="https://github.com/Corona-oplus-kernel/AnyKernel3"
  if [ -n "${AK3_TOKEN:-}" ]; then
    AK3_URL="https://${AK3_TOKEN}@github.com/Corona-oplus-kernel/AnyKernel3"
  fi
  CORONA_URL="https://github.com/Corona-oplus-kernel/Corona_module"
  prepare_anykernel_tree "$MANAGER" "$USE_KPN" "$AK3_URL" "$CORONA_URL"
  mkdir -p "$WORKDIR/out_zips"
  SUSFS_PKG_LABEL=""
  if [ "${BUILD_SUSFS_MODE:-}" = "both" ] && [ "$SUSFS_MODE" = "on" ] && [ "$MANAGER" != "none" ]; then
    SUSFS_PKG_LABEL="SUSFS"
  fi
  package_anykernel_zip "$MANAGER" "$KERNEL_VERSION" \
    "./common/out/arch/arm64/boot/Image" "$WORKDIR/out_zips" "noksu" "$SUSFS_PKG_LABEL" >/dev/null
  rm -rf AnyKernel3
fi

# 清理所有嵌套 .git 目录，避免 actions/checkout post-cleanup 的 submodule 误报
find "$WORKDIR/kernel_workspace" -name ".git" -type d -exec rm -rf {} + 2>/dev/null || true
