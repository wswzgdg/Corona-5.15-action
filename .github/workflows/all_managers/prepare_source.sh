#!/usr/bin/env bash
set -e

# 与 common.sh 共享前期源码准备阶段：repo init/sync + common clone + setlocalversion 修补。
# 当矩阵编译数较多时，前置 prepare-source 工作流跑一次后将整个 kernel_workspace 上传成
# artifact，之后所有 build 矩阵项直接下载解压，避免每个任务重复同步源码。

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

cd kernel_platform
rm -rf common AnyKernel3
if [ "${ANDROID_RELEASE:-16}" = "15" ]; then
  COMMON_REPO="Corona-oplus-kernel/5.15oplus-c15"
  COMMON_BRANCH="Corona"
else
  COMMON_REPO="Corona-oplus-kernel/kernel_common_oplus"
  COMMON_BRANCH="android13-5.15-lts"
fi
COMMON_URL_PUBLIC="https://github.com/${COMMON_REPO}.git"
if [ -n "${KERNEL_COMMON_TOKEN:-}" ]; then
  COMMON_URL_AUTH="https://${KERNEL_COMMON_TOKEN}@github.com/${COMMON_REPO}.git"
else
  COMMON_URL_AUTH="$COMMON_URL_PUBLIC"
fi
git clone --depth=1 "$COMMON_URL_AUTH" -b "$COMMON_BRANCH" common
# artifact 会被下载到其它 job，确保 .git/config 内不包含鉴权 URL
git -C common remote set-url origin "$COMMON_URL_PUBLIC"

rm common/android/abi_gki_protected_exports_* || true
for f in common/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
done

echo "源码 workspace 已准备完成"
