#!/usr/bin/env bash
set -e

MANAGER="$1"
# 第 2 个参数用于 setlocalversion，影响内核名后缀
KERNEL_SUFFIX="${2:-}"
SUSFS_MODE="${3:-on}"
USE_KPN="${4:-false}"
VERSION_NAME_RAW="${5:-eternitylonely}"
LLVM_CLANG_VERSION="${CLANG_VERSION:-22}"
WORKDIR="$(pwd)"

source "$WORKDIR/.github/workflows/all_managers/toolchain.sh"
source "$WORKDIR/.github/workflows/all_managers/packaging.sh"

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

mkdir -p kernel_workspace
cd kernel_workspace
# 未设置 SKIP_APT 时才安装依赖，方便在重复调用时跳过 apt 节省时间
if [ -z "${SKIP_APT:-}" ]; then
  sudo apt-mark hold firefox 2>/dev/null
  sudo apt-mark hold libc-bin 2>/dev/null
  sudo apt-get purge -y man-db
  sudo rm -rf /var/lib/man-db/auto-update
  sudo apt-get update -y -qq
  sudo apt-get install -y --no-install-recommends     binutils python-is-python3 libssl-dev libelf-dev ccache repo
  sudo apt-get install -y     flex bison dwarves libssl-dev libelf-dev bc python3 python-is-python3     make cmake zip aria2 gnupg gawk rsync     binutils-aarch64-linux-gnu binutils-arm-linux-gnueabihf     tar gzip xz-utils bzip2 device-tree-compiler libc6-dev-i386
  ensure_toolchain "$LLVM_CLANG_VERSION" "$WORKDIR"
fi

if [ ! -d .repo ]; then
  echo "初始化源码仓库..."
  repo init -u https://github.com/Numbersf/kernel_manifest -b oneplus/sm8550 -m oneplus_ace3_b.xml --no-tags --depth=1
else
  echo "复用已有源码仓库..."
fi
REPO_LAUNCHER="$PWD/.repo/repo/repo"
# 优先使用仓库内 repo init 拉下来的 launcher，找不到时再退回系统 repo 命令
if [ -x "$REPO_LAUNCHER" ]; then
  "$REPO_LAUNCHER" sync -j$(nproc --all) -c --no-tags --no-clone-bundle --optimized-fetch --prune
else
  repo sync -j$(nproc --all) -c --no-tags --no-clone-bundle --optimized-fetch --prune
fi

cd kernel_platform
rm -rf common AnyKernel3
rm -rf "$WORKDIR/out_zips"
COMMON_URL="https://github.com/Corona-oplus-kernel/kernel_common_oplus.git"
# 有 token 时改用带鉴权地址，避免私有/限流场景下 clone 失败
if [ -n "${KERNEL_COMMON_TOKEN:-}" ]; then
  COMMON_URL="https://${KERNEL_COMMON_TOKEN}@github.com/Corona-oplus-kernel/kernel_common_oplus.git"
fi
git clone --depth=1 "$COMMON_URL" -b android13-5.15-lts common
cd ../

# toolchain (reuse to save space)
ensure_toolchain "$LLVM_CLANG_VERSION" "$WORKDIR"

# prep common
cd kernel_platform
rm common/android/abi_gki_protected_exports_* || true
# 去掉 -dirty，避免源码目录状态把额外后缀带进最终内核版本字符串
for f in common/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  sed -i '$i res=$(echo "$res" | sed '''s/-dirty//g''')' "$f"
  done

# setup manager
cd common
# 先接入选中的管理器，再按需要覆盖显示版本中的提交哈希
case "$MANAGER" in
  sukisu)
    curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/refs/heads/main/kernel/setup.sh" | bash -s builtin
    if [ -n "$VERSION_NAME_FULL" ] && [ -f "./KernelSU/kernel/Kbuild" ]; then
      sed -i 's|^KSU_VERSION_FULL := .*|KSU_VERSION_FULL := $(if $(call git_short_sha),v$(VERSION_TAG)-'"$VERSION_NAME_FULL"',v$(VERSION_TAG)-$(REPO_NAME)-unknown@unknown)|' ./KernelSU/kernel/Kbuild
    fi
    ;;
  resukisu)
    if [ "$SUSFS_MODE" = "on" ]; then
      curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/refs/heads/susfs-ksud/kernel/setup.sh" | bash -s susfs-ksud
    else
      curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/refs/heads/main/kernel/setup.sh" | bash -s main
    fi
    ;;
  ksunext)
    if [ "$SUSFS_MODE" = "on" ]; then
      curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/refs/heads/dev-susfs/kernel/setup.sh" | bash -s dev-susfs
    else
      curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/refs/heads/dev/kernel/setup.sh" | bash -s dev
    fi
    ;;
  ksu)
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/refs/heads/main/kernel/setup.sh" | bash -s main
    ;;
  kowsu)
    curl -LSs "https://raw.githubusercontent.com/KOWX712/KernelSU/refs/heads/master/kernel/setup.sh" | bash -s master
    ;;
  none)
    # 无管理器模式下不接入任何 KernelSU 变体，后面也会跳过相关配置
    ;;
  *)
    echo "Unknown manager: $MANAGER"; exit 1;;
 esac
cd ..

# SUSFS patch (skip none)
# 只有启用了管理器且显式开启 SUSFS 时才打补丁；none 模式保持纯内核构建
if [ "$MANAGER" = "ksu" ] && [ "$SUSFS_MODE" = "on" ]; then
  rm -rf susfs4ksu
  git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu susfs4ksu -b gki-${ANDROID_VERSION}-${KERNEL_VERSION}
  cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch ./common/
  cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
  cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
  cd ./common
  patch -p1 -F 3 < 50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch || true
  cd ..
fi

# 启用 SUSFS 时补兼容补丁，暴露 fake_state/ksu_selinux_hide_running 符号
if [ "$MANAGER" = "ksu" ] && [ "$SUSFS_MODE" = "on" ]; then
  # 目录存在才补，避免上游结构变化时直接报错退出
  if [ -d "./KernelSU" ]; then
    cp ./susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/
    cd ./KernelSU
    patch -p1 -F 3 < 10_enable_susfs_for_ksu.patch || true
    cd ..
  fi
fi

# configs
cd "$WORKDIR/kernel_workspace/kernel_platform"
# 只要启用了任一管理器，就把对应 KSU 配置写进 defconfig；SUSFS 开关按构建输入控制
if [ "$MANAGER" != "none" ]; then
  DEFCONFIG=./common/arch/arm64/configs/gki_defconfig
  echo "CONFIG_KSU=y" >> "$DEFCONFIG"
  if [ "$SUSFS_MODE" = "on" ]; then
    echo "CONFIG_KSU_SUSFS=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_TRY_UMOUNT=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" >> "$DEFCONFIG"
    echo "CONFIG_KSU_SUSFS_SUS_MAP=y" >> "$DEFCONFIG"
  fi
  if [ "$MANAGER" = "resukisu" ] && [ -n "$VERSION_NAME_FULL" ]; then
    echo "CONFIG_KSU_FULL_NAME_FORMAT=\"%TAG_NAME%-${VERSION_NAME_FULL}\"" >> "$DEFCONFIG"
  fi
  # SukiSU / ReSukiSU 默认走内置 KPM；启用 KP-N 时跳过，避免重复 patch
  if [ "$USE_KPN" != "true" ] && { [ "$MANAGER" = "sukisu" ] || [ "$MANAGER" = "resukisu" ]; }; then
    echo "CONFIG_KPM=y" >> "$DEFCONFIG"
  fi
fi

sed -i 's/check_defconfig//' ./common/build.config.gki
touch ./common/.scmversion

# Droidspaces 容器支持
if [ "${DROIDSPACES_ENABLE:-false}" != "false" ]; then
  echo "正在启用 Droidspaces 容器支持..."
  REPO_URL="https://github.com/$GITHUB_REPOSITORY/raw/refs/heads/$GITHUB_REF_NAME/droidspaces_patch"
  # 应用 OKI 5.15 Droidspaces 核心补丁
  for p in \
    01.disable_crc_checks_for_lkms.patch \
    02.fix_restore_cgroup_file_prefix_handling.patch \
    "03.5.15+_use_android_abi_padding_for_posix_mqueue.patch" \
    04.sysvipc_task_struct.patch; do
    wget "$REPO_URL/$p" -O "$p"
    patch -p1 -F 3 < "$p" -d ./common || true
  done
  # 应用 NTSync 补丁 (base 已在源码内置，仅打 compat)
  wget "$REPO_URL/ntsync_compat_android13-5.15.patch" -O ntsync_compat.patch
  patch -p1 -F 3 < ntsync_compat.patch -d ./common || true
  # 开启 Droidspaces 容器所需内核配置
  DEFCONFIG=./common/arch/arm64/configs/gki_defconfig
  echo "CONFIG_PID_NS=y" >> "$DEFCONFIG"
  echo "CONFIG_IPC_NS=y" >> "$DEFCONFIG"
  echo "CONFIG_UTS_NS=y" >> "$DEFCONFIG"
  echo "CONFIG_USER_NS=y" >> "$DEFCONFIG"
  echo "CONFIG_SYSVIPC=y" >> "$DEFCONFIG"
  echo "CONFIG_DEVTMPFS=y" >> "$DEFCONFIG"
  echo "CONFIG_NAMESPACES=y" >> "$DEFCONFIG"
  echo "CONFIG_POSIX_MQUEUE=y" >> "$DEFCONFIG"
  echo "CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y" >> "$DEFCONFIG"
  echo "CONFIG_NETFILTER_XT_TARGET_LOG=y" >> "$DEFCONFIG"
  echo "CONFIG_NETFILTER_XT_MATCH_RECENT=y" >> "$DEFCONFIG"
  echo "CONFIG_CGROUP_DEVICE=y" >> "$DEFCONFIG"
  echo "CONFIG_CGROUP_PIDS=y" >> "$DEFCONFIG"
  echo "CONFIG_MEMCG=y" >> "$DEFCONFIG"
  echo "CONFIG_NTSYNC=y" >> "$DEFCONFIG"
  if [ "$DROIDSPACES_ENABLE" = "extend" ]; then
    echo "正在启用容器环境扩展支持..."
    echo "CONFIG_BT_HCIVHCI=y" >> "$DEFCONFIG"
    echo "CONFIG_STATIC_USERMODEHELPER=n" >> "$DEFCONFIG"
    # 添加 Lindroid EVDI DRM 驱动
    wget "$REPO_URL/evdi_drm.patch" -O evdi_drm.patch
    patch -p1 -F 3 < evdi_drm.patch -d ./common || true
    echo "CONFIG_DRM_LINDROID_EVDI=y" >> "$DEFCONFIG"
  fi
fi

# kernel suffix
# 这里单独处理内核名后缀，不影响管理器显示版本
if [ -n "$KERNEL_SUFFIX" ]; then
  echo "替换内核版本名称: $KERNEL_SUFFIX"
  for f in ./common/scripts/setlocalversion; do
    sed -i "\$s|echo \"\$res\"|echo \"-${KERNEL_SUFFIX}\"|" "$f"
  done
fi

# build
cd "$WORKDIR/kernel_workspace/kernel_platform/common"
export KBUILD_BUILD_USER=ZakoBai♡
export KBUILD_BUILD_HOST=XinRan
make -j$(nproc --all) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="ccache clang" LD="ld.lld" HOSTLD=ld.lld O=out KCFLAGS+=-O2 KCFLAGS+=-Wno-error gki_defconfig
make -j$(nproc --all) LLVM=1 LLVM_IAS=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="ccache clang" LD="ld.lld" HOSTLD=ld.lld O=out KCFLAGS+=-O2 KCFLAGS+=-Wno-error Image

# package
cd "$WORKDIR/kernel_workspace/kernel_platform"
AK3_URL="https://github.com/Corona-oplus-kernel/AnyKernel3"
# 有 AK3_TOKEN 时走鉴权地址，避免拉包仓库时触发匿名限制
if [ -n "${AK3_TOKEN:-}" ]; then
  AK3_URL="https://${AK3_TOKEN}@github.com/Corona-oplus-kernel/AnyKernel3"
fi
CORONA_URL="https://github.com/Corona-oplus-kernel/Corona_module"
prepare_anykernel_tree "$MANAGER" "$USE_KPN" "$AK3_URL" "$CORONA_URL"
mkdir -p "$WORKDIR/out_zips"
package_anykernel_zip "$MANAGER" "$KERNEL_VERSION" "./common/out/arch/arm64/boot/Image" "$WORKDIR/out_zips" >/dev/null

rm -rf AnyKernel3
