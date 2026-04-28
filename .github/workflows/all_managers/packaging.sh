#!/usr/bin/env bash

manager_type_name() {
  local manager="$1"
  local none_label="${2:-noksu}"
  case "$manager" in
    sukisu) printf 'SukiSU' ;;
    resukisu) printf 'ReSukiSU' ;;
    ksunext) printf 'KSUNext' ;;
    ksu) printf 'KSU' ;;
    kowsu) printf 'KowSU' ;;
    none) printf '%s' "$none_label" ;;
    *) printf '%s' "$manager" ;;
  esac
}

prepare_anykernel_tree() {
  local manager="$1"
  local use_kpn="$2"
  local ak3_url="$3"
  local corona_url="$4"

  if [ "$use_kpn" = "true" ] && [ "$manager" != "none" ]; then
    git clone -b kp-n "$ak3_url" --depth=1 AnyKernel3
    mkdir -p ./AnyKernel3/patch ./AnyKernel3/module
    curl -fL https://github.com/KernelSU-Next/KPatch-Next/releases/latest/download/kptools-android -o ./AnyKernel3/patch/kptools
    curl -fL https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest/download/kpimg -o ./AnyKernel3/patch/kpimg
    curl -fL https://github.com/cctv18/KPatch-Next/releases/latest/download/kpn.zip -o ./AnyKernel3/module/kpn.zip
  elif [ "$use_kpn" != "true" ] && { [ "$manager" = "sukisu" ] || [ "$manager" = "resukisu" ]; }; then
    git clone -b kpm "$ak3_url" --depth=1 AnyKernel3
    mkdir -p ./AnyKernel3/patch ./AnyKernel3/module
    local patch_url
    patch_url=$(curl -fsSL https://api.github.com/repos/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest | python3 -c 'import json,sys; data=json.load(sys.stdin); assets=data.get("assets", []); matches=[a["browser_download_url"] for a in assets if "patch_android" in a.get("name", "")]; print(matches[0] if matches else "")')
    [ -n "$patch_url" ] || { echo "未找到 patch_android release 资源"; return 1; }
    curl -fL "$patch_url" -o ./AnyKernel3/patch/patch
  else
    git clone -b main "$ak3_url" --depth=1 AnyKernel3
    mkdir -p ./AnyKernel3/patch ./AnyKernel3/module
  fi

  rm -rf ./AnyKernel3/.git
  rm -f ./AnyKernel3/module/Corona.zip
  git clone "$corona_url" --depth=1 ./AnyKernel3/module/Corona
  rm -rf ./AnyKernel3/module/Corona/.git
  rm -f ./AnyKernel3/module/Corona/LICENSE ./AnyKernel3/module/Corona/README.md
  (cd ./AnyKernel3/module/Corona && zip -r ../Corona.zip ./*)
  rm -rf ./AnyKernel3/module/Corona
}

package_anykernel_zip() {
  local manager="$1"
  local kernel_version="$2"
  local image_path="$3"
  local output_path="$4"
  local none_label="${5:-noksu}"

  cp -f "$image_path" ./AnyKernel3/Image/Image
  if [ ! -f ./AnyKernel3/Image/Image ]; then
    echo "未找到内核镜像文件，构建可能出错"
    return 1
  fi

  local manager_label
  manager_label="$(manager_type_name "$manager" "$none_label")"
  local zip_name="AK3-${kernel_version}-${manager_label}@bai.zip"
  (cd AnyKernel3 && zip -r "$output_path/$zip_name" ./*)
  printf '%s' "$zip_name"
}
