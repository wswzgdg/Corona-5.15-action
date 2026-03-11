#!/usr/bin/env bash
set -e

MANAGER="$1"
WORKDIR="$(pwd)"

export PATH="/usr/lib/ccache:$PATH"
export PATH="$WORKDIR/clang22/LLVM-22.1.0-Linux-X64/bin:$PATH"

if [ -d "kernel_workspace/.repo" ]; then
  mv kernel_workspace/.repo "$WORKDIR/.repo_cache"
fi
rm -rf kernel_workspace
mkdir kernel_workspace
if [ -d "$WORKDIR/.repo_cache" ]; then
  mv "$WORKDIR/.repo_cache" kernel_workspace/.repo
fi
cd kernel_workspace
if [ -z "${SKIP_APT:-}" ]; then
  sudo apt-mark hold firefox
  sudo apt-mark hold libc-bin
  sudo apt purge -y man-db
  sudo rm -rf /var/lib/man-db/auto-update
  sudo apt update -y
  sudo apt-get install -y --no-install-recommends     binutils python-is-python3 libssl-dev libelf-dev ccache repo
  sudo apt-get install -y     flex bison dwarves libssl-dev libelf-dev bc python3 python-is-python3     make cmake zip aria2 gnupg gawk rsync     binutils-aarch64-linux-gnu binutils-arm-linux-gnueabihf     tar gzip xz-utils bzip2 device-tree-compiler libc6-dev-i386
fi

echo "正在克隆源码仓库..."
repo init -u https://github.com/Numbersf/kernel_manifest -b oneplus/sm8550 -m oneplus_ace3_b.xml --no-tags --depth=1
REPO_LAUNCHER="$PWD/.repo/repo/repo"
if [ -x "$REPO_LAUNCHER" ]; then
  "$REPO_LAUNCHER" sync -j$(nproc --all) -c --no-tags --no-clone-bundle
else
  repo sync -j$(nproc --all) -c --no-tags --no-clone-bundle
fi

cd kernel_platform
rm -rf common
COMMON_URL="https://github.com/Corona-oplus-kernel/kernel_common_oplus.git"
if [ -n "${KERNEL_COMMON_TOKEN:-}" ]; then
  COMMON_URL="https://${KERNEL_COMMON_TOKEN}@github.com/Corona-oplus-kernel/kernel_common_oplus.git"
fi
git clone --depth=1 "$COMMON_URL" -b android13-5.15-lts common
cd ../

# toolchain (reuse to save space)
mkdir -p "$WORKDIR/clang22"
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
for f in common/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  sed -i '$i res=$(echo "$res" | sed '''s/-dirty//g''')' "$f"
  done

# setup manager
cd common
case "$MANAGER" in
  sukisu)
    curl -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/refs/heads/main/kernel/setup.sh" | bash -s builtin
    ;;
  resukisu)
    curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/refs/heads/main/kernel/setup.sh" | bash -s main
    ;;
  ksunext)
    curl -LSs "https://raw.githubusercontent.com/pershoot/KernelSU-Next/refs/heads/dev-susfs/kernel/setup.sh" | bash -s dev-susfs
    ;;
  ksu)
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/refs/heads/main/kernel/setup.sh" | bash -s main
    ;;
  kowsu)
    curl -LSs "https://raw.githubusercontent.com/KOWX712/KernelSU/refs/heads/master/kernel/setup.sh" | bash -s master
    ;;
  none)
    # no manager setup
    ;;
  *)
    echo "Unknown manager: $MANAGER"; exit 1;;
 esac
cd ..

# SUSFS patch (skip kowsu and none)
if [ "$MANAGER" != "kowsu" ] && [ "$MANAGER" != "none" ]; then
  rm -rf susfs4ksu
  git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu susfs4ksu -b gki-${ANDROID_VERSION}-${KERNEL_VERSION}
  cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch ./common/
  cp ./susfs4ksu/kernel_patches/fs/* ./common/fs/
  cp ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
  cd ./common
  patch -p1 < 50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch || true
  cd ..
fi

if [ "$MANAGER" = "ksu" ]; then
  if [ -d "./KernelSU" ]; then
    cp ./susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./KernelSU/
    cd ./KernelSU
    patch -p1 < 10_enable_susfs_for_ksu.patch || true
    cd ..
  fi
fi

# configs
cd "$WORKDIR/kernel_workspace/kernel_platform"
if [ "$MANAGER" != "none" ]; then
for k in   CONFIG_KSU_SUSFS=y   CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y   CONFIG_KSU_SUSFS_SUS_PATH=y   CONFIG_KSU_SUSFS_SUS_MOUNT=y   CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y   CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y   CONFIG_KSU_SUSFS_SUS_KSTAT=y   CONFIG_KSU_SUSFS_TRY_UMOUNT=y   CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y   CONFIG_KSU_SUSFS_SPOOF_UNAME=y   CONFIG_KSU_SUSFS_ENABLE_LOG=y   CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y   CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y   CONFIG_KSU_SUSFS_OPEN_REDIRECT=y   CONFIG_KSU_SUSFS_SUS_MAP=y   CONFIG_KSU=y   CONFIG_TMPFS_XATTR=y   CONFIG_TMPFS_POSIX_ACL=y   CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y   CONFIG_LOCALVERSION_AUTO=n   CONFIG_HEADERS_INSTALL=n
 do
  echo "$k" >> ./common/arch/arm64/configs/gki_defconfig
 done

if [ "$MANAGER" = "sukisu" ] || [ "$MANAGER" = "resukisu" ]; then
  echo "CONFIG_KPM=y" >> ./common/arch/arm64/configs/gki_defconfig
fi
fi

sed -i 's/check_defconfig//' ./common/build.config.gki
touch ./common/.scmversion

# build
cd "$WORKDIR/kernel_workspace/kernel_platform/common"
make -j$(nproc --all) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="ccache clang" LD="ld.lld" HOSTLD=ld.lld O=out KCFLAGS+=-O2 KCFLAGS+=-Wno-error gki_defconfig
make -j$(nproc --all) LLVM=1 LLVM_IAS=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC="ccache clang" LD="ld.lld" HOSTLD=ld.lld O=out KCFLAGS+=-O2 KCFLAGS+=-Wno-error Image

# package
cd "$WORKDIR/kernel_workspace/kernel_platform"
AK3_URL="https://github.com/Corona-oplus-kernel/AnyKernel3"
if [ -n "${AK3_TOKEN:-}" ]; then
  AK3_URL="https://${AK3_TOKEN}@github.com/Corona-oplus-kernel/AnyKernel3"
fi
if [ "$MANAGER" = "sukisu" ] || [ "$MANAGER" = "resukisu" ]; then
  git clone -b kpm "$AK3_URL" --depth=1 AnyKernel3
else
  git clone -b main "$AK3_URL" --depth=1 AnyKernel3
fi
rm -rf ./AnyKernel3/.git
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
