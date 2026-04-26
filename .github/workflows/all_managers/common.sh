#!/usr/bin/env bash
set -e

MANAGER="$1"
# 第 2 个参数用于 setlocalversion，影响内核名后缀
KERNEL_SUFFIX="${2:-}"
SUSFS_MODE="${3:-on}"
USE_KPN="${4:-false}"
WORKDIR="$(pwd)"

export PATH="/usr/lib/ccache:$PATH"
export PATH="$WORKDIR/clang22/LLVM-22.1.0-Linux-X64/bin:$PATH"

mkdir -p kernel_workspace
cd kernel_workspace
# 未设置 SKIP_APT 时才安装依赖，方便在重复调用时跳过 apt 节省时间
if [ -z "${SKIP_APT:-}" ]; then
  sudo apt-mark hold firefox
  sudo apt-mark hold libc-bin
  sudo apt purge -y man-db
  sudo rm -rf /var/lib/man-db/auto-update
  sudo apt update -y
  sudo apt-get install -y --no-install-recommends     binutils python-is-python3 libssl-dev libelf-dev ccache repo
  sudo apt-get install -y     flex bison dwarves libssl-dev libelf-dev bc python3 python-is-python3     make cmake zip aria2 gnupg gawk rsync     binutils-aarch64-linux-gnu binutils-arm-linux-gnueabihf     tar gzip xz-utils bzip2 device-tree-compiler libc6-dev-i386
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
mkdir -p "$WORKDIR/clang22"
# 本地没有 clang22 工具链时才下载，已有缓存就直接复用
if [ ! -d "$WORKDIR/clang22/LLVM-22.1.0-Linux-X64" ]; then
  cd "$WORKDIR/clang22"
  aria2c -s16 -x16 -k1M https://github.com/llvm/llvm-project/releases/download/llvmorg-22.1.0/LLVM-22.1.0-Linux-X64.tar.xz -o clang.tar.xz
  tar -xvf clang.tar.xz -C ./
  rm -rf clang.tar.xz
  cd "$WORKDIR/kernel_workspace"
fi

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
    ;;
  resukisu)
    curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/refs/heads/main/kernel/setup.sh" | bash -s main
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
if [ "$MANAGER" != "none" ] && [ "$SUSFS_MODE" = "on" ]; then
  rm -rf susfs4ksu
  git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu susfs4ksu -b gki-${ANDROID_VERSION}-${KERNEL_VERSION}
  cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch ./common/
  cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
  cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
  cd ./common
  patch -p1 < 50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch || true
  cd ..
fi

# 只有原版 ksu 在启用 SUSFS 时需要额外补这份兼容补丁，其他分支不走这里
if [ "$MANAGER" = "ksu" ] && [ "$SUSFS_MODE" = "on" ]; then
  # 目录存在才补，避免上游结构变化时直接报错退出
  if [ -d "./KernelSU" ]; then
    cp ./susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/
    cd ./KernelSU
    patch -p1 < 10_enable_susfs_for_ksu.patch || true
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
  # SukiSU / ReSukiSU 默认走内置 KPM；启用 KP-N 时跳过，避免重复 patch
  if [ "$USE_KPN" != "true" ] && { [ "$MANAGER" = "sukisu" ] || [ "$MANAGER" = "resukisu" ]; }; then
    echo "CONFIG_KPM=y" >> "$DEFCONFIG"
  fi
fi

sed -i 's/check_defconfig//' ./common/build.config.gki
touch ./common/.scmversion

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
# KP-N 走独立的 AnyKernel3 分支；SukiSU / ReSukiSU 默认继续使用带 KPM 的打包分支
if [ "$USE_KPN" = "true" ] && [ "$MANAGER" != "none" ]; then
  git clone -b kp-n "$AK3_URL" --depth=1 AnyKernel3
elif [ "$USE_KPN" != "true" ] && { [ "$MANAGER" = "sukisu" ] || [ "$MANAGER" = "resukisu" ]; }; then
  git clone -b kpm "$AK3_URL" --depth=1 AnyKernel3
  PATCH_URL=$(curl -fsSL https://api.github.com/repos/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest | python3 -c 'import json,sys; data=json.load(sys.stdin); assets=data.get("assets", []); matches=[a["browser_download_url"] for a in assets if "patch_android" in a.get("name", "")]; print(matches[0] if matches else "")')
  [ -n "$PATCH_URL" ] || { echo "未找到 patch_android release 资源"; exit 1; }
  curl -fL "$PATCH_URL" -o ./AnyKernel3/patch/patch
else
  git clone -b main "$AK3_URL" --depth=1 AnyKernel3
fi
rm -rf ./AnyKernel3/.git
rm -f ./AnyKernel3/module/Corona.zip
CORONA_URL="https://github.com/Corona-oplus-kernel/Corona_module"
git clone "$CORONA_URL" --depth=1 AnyKernel3/module/Corona
rm -rf ./AnyKernel3/module/Corona/.git
rm -f ./AnyKernel3/module/Corona/LICENSE ./AnyKernel3/module/Corona/README.md
(cd ./AnyKernel3/module/Corona && zip -r ../Corona.zip ./*)
rm -rf ./AnyKernel3/module/Corona
cp -f ./common/out/arch/arm64/boot/Image ./AnyKernel3/Image/Image

case "$MANAGER" in
  sukisu) KSU_TYPENAME="SukiSU";;
  resukisu) KSU_TYPENAME="ReSukiSU";;
  ksunext) KSU_TYPENAME="KSUNext";;
  ksu) KSU_TYPENAME="KSU";;
  kowsu) KSU_TYPENAME="KowSU";;
  none) KSU_TYPENAME="noksu";;
  *) KSU_TYPENAME="$MANAGER";;
 esac

AK3_NAME=AK3-${KERNEL_VERSION}-${KSU_TYPENAME}@bai.zip
mkdir -p "$WORKDIR/out_zips"
(cd AnyKernel3 && zip -r "$WORKDIR/out_zips/$AK3_NAME" ./*)

rm -rf AnyKernel3
