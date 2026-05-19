#!/usr/bin/env bash
set -e

# 前置 prepare-source 工作流的源码同步阶段：只做 repo init / repo sync。
# common（私有 kernel_common_oplus）必须留到 build 阶段再 clone，否则会随 artifact
# 暴露给公开仓库的访客；setlocalversion 修补、abi 清理同样放到 build 阶段。

WORKDIR="$(pwd)"

mkdir -p kernel_workspace
cd kernel_workspace

if [ ! -d .repo ]; then
  echo "初始化源码仓库..."
  if [ "${ANDROID_RELEASE:-16}" = "15" ]; then
    MANIFEST_XML="oneplus_ace3_v.xml"
  else
    MANIFEST_XML="oneplus_ace3_b.xml"
  fi
  repo init -u https://github.com/Numbersf/kernel_manifest -b oneplus/sm8550 -m "$MANIFEST_XML" --no-tags --depth=1
else
  echo "复用已有源码仓库..."
fi
REPO_LAUNCHER="$PWD/.repo/repo/repo"
if [ -x "$REPO_LAUNCHER" ]; then
  "$REPO_LAUNCHER" sync -j$(nproc --all) -c --no-tags --no-clone-bundle --optimized-fetch --prune
else
  repo sync -j$(nproc --all) -c --no-tags --no-clone-bundle --optimized-fetch --prune
fi

# 顺手清掉 manifest 里同样会被 build 重新克隆的目录，缩小 artifact 体积
cd kernel_platform
rm -rf common AnyKernel3

echo "源码 workspace 已准备完成（不含 common）"
