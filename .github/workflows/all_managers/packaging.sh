#!/usr/bin/env bash

# Shared AnyKernel3 packaging helpers. These keep branch selection, extra asset
# downloads, and final zip naming consistent between local test and matrix jobs.

# Map workflow manager names to the final package label.
manager_type_name() {
  local manager="$1"
  local none_label="${2:-noksu}"
  case "$manager" in
    sukisu) printf 'SukiSU' ;;
    resukisu) printf 'ReSukiSU' ;;
    ksunext) printf 'KSUNEXT' ;;
    ksu) printf 'KSU' ;;
    kowsu) printf 'KowSU' ;;
    none) printf '%s' "$none_label" ;;
    *) printf '%s' "$manager" ;;
  esac
}

# Prepare the AnyKernel3 tree and inject any manager-specific assets.
prepare_anykernel_tree() {
  local manager="$1"
  local use_kpn="$2"
  local ak3_url="$3"
  local corona_url="$4"

  # resukisu 强制走 KPN（已移除内置 KPM 支持）
  local effective_kpn="$use_kpn"
  [ "$manager" = "resukisu" ] && effective_kpn="true"

  if [ "$effective_kpn" = "true" ] && [ "$manager" != "none" ]; then
    git clone -b kp-n "$ak3_url" --depth=1 AnyKernel3
    mkdir -p ./AnyKernel3/patch ./AnyKernel3/module
    curl -fL https://github.com/KernelSU-Next/KPatch-Next/releases/latest/download/kptools-android -o ./AnyKernel3/patch/kptools
    curl -fL https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest/download/kpimg -o ./AnyKernel3/patch/kpimg
    curl -fL https://github.com/cctv18/KPatch-Next/releases/latest/download/kpn.zip -o ./AnyKernel3/module/kpn.zip
  elif [ "$effective_kpn" != "true" ] && [ "$manager" = "sukisu" ]; then
    git clone -b kpm "$ak3_url" --depth=1 AnyKernel3
    mkdir -p ./AnyKernel3/patch ./AnyKernel3/module
    local patch_url=""
    local api_resp=""
    local auth_args=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    for attempt in 1 2 3 4 5; do
      api_resp=$(curl -fsSL --retry 3 --retry-delay 5 \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${auth_args[@]}" \
        https://api.github.com/repos/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest || true)
      patch_url=$(printf '%s' "$api_resp" | python3 -c 'import json,sys
try:
  data=json.load(sys.stdin)
except Exception:
  sys.exit(0)
assets=data.get("assets", []) if isinstance(data,dict) else []
matches=[a.get("browser_download_url","") for a in assets if "patch_android" in a.get("name","")]
print(matches[0] if matches else "")')
      [ -n "$patch_url" ] && break
      echo "patch_android 资源解析失败，第 ${attempt} 次重试..." >&2
      sleep $((attempt * 5))
    done
    if [ -z "$patch_url" ]; then
      echo "API 受限，回退到 release 直链下载 patch_android" >&2
      patch_url="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest/download/patch_android"
    fi
    curl -fL --retry 3 --retry-delay 5 "$patch_url" -o ./AnyKernel3/patch/patch
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

# Copy the built Image into AnyKernel3 and emit the final zip name.
package_anykernel_zip() {
  local manager="$1"
  local kernel_version="$2"
  local image_path="$3"
  local output_path="$4"
  local none_label="${5:-noksu}"
  local susfs_label="${6:-}"

  cp -f "$image_path" ./AnyKernel3/Image/Image
  if [ ! -f ./AnyKernel3/Image/Image ]; then
    echo "未找到内核镜像文件，构建可能出错"
    return 1
  fi

  local manager_label
  manager_label="$(manager_type_name "$manager" "$none_label")"
  local susfs_suffix=""
  [ -n "$susfs_label" ] && susfs_suffix="_${susfs_label}"
  local zip_name="AK3-${kernel_version}-${manager_label}${susfs_suffix}@bai.zip"
  (cd AnyKernel3 && zip -r "$output_path/$zip_name" ./*)
  printf '%s' "$zip_name"
}
