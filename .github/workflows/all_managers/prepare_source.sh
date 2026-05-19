#!/usr/bin/env bash
set -e

# 直接 clone OnePlusOSS sm8550 到 kernel_workspace 根目录。
# 该仓库根树就是 kernel_platform/ 和 vendor/，common 仓库里的
# kernel_platform/common/drivers/soc/oplus/storage 等 symlink 指向
# ../../../../../vendor/oplus/kernel/...，必须落到 kernel_workspace 根。
# common（私有）和 AnyKernel3 一律保留到 build 阶段再 clone。

if [ "${ANDROID_RELEASE:-16}" = "15" ]; then
  VENDOR_BRANCH="oneplus/sm8550_v_15.0.0_oneplus11"
else
  VENDOR_BRANCH="oneplus/sm8550_b_16.0.0_oneplus_11"
fi
VENDOR_URL="https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8550"

if [ ! -d kernel_workspace/.git ]; then
  rm -rf kernel_workspace
  git clone --depth=1 -b "$VENDOR_BRANCH" "$VENDOR_URL" kernel_workspace
else
  echo "kernel_workspace 已存在，跳过 clone"
fi

echo "vendor 已就绪 ($VENDOR_BRANCH)"
