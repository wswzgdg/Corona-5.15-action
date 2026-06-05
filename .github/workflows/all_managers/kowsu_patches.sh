#!/usr/bin/env bash
# kowsu_patches.sh: KowSU static_key 类型兼容补丁
set -e
F="$1"; H="$2"
[ -f "$F" ] || exit 0

sed -i 's/ksu_su_compat_enabled[[:space:]]*?[[:space:]]*1[[:space:]]*:[[:space:]]*0/static_key_enabled(\&ksu_su_compat_enabled.key) ? 1 : 0/g' "$F"
sed -i 's/ksu_su_compat_enabled[[:space:]]*=[[:space:]]*true/static_key_enable(\&ksu_su_compat_enabled.key)/g' "$F" 2>/dev/null || true
sed -i 's/ksu_su_compat_enabled[[:space:]]*=[[:space:]]*false/static_key_disable(\&ksu_su_compat_enabled.key)/g' "$F" 2>/dev/null || true
sed -i 's/ksu_su_compat_enabled[[:space:]]*=[[:space:]]*\([a-zA-Z_][a-zA-Z0-9_]*\)[[:space:]]*;/if (\1) static_key_enable(\&ksu_su_compat_enabled.key); else static_key_disable(\&ksu_su_compat_enabled.key);/g' "$F" 2>/dev/null || true
sed -i 's/\bbool\b.*\bksu_su_compat_enabled\b.*=[[:space:]]*true/struct static_key_true ksu_su_compat_enabled = STATIC_KEY_TRUE_INIT/' "$F" 2>/dev/null || true
[ -f "$H" ] && sed -i 's/extern bool ksu_su_compat_enabled/extern struct static_key_true ksu_su_compat_enabled/' "$H" 2>/dev/null || true
echo "kowsu_patches: done"