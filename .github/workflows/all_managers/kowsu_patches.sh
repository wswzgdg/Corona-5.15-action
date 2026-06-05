#!/usr/bin/env bash
# kowsu_patches.sh: Patch ALL files that reference ksu_su_compat_enabled
set -e
D="$1"  # common/drivers/kernelsu/ directory

[ -d "$D" ] || exit 0

grep -rl "ksu_su_compat_enabled" "$D" --include="*.c" 2>/dev/null | while read -r F; do
  # decl: bool → struct static_key_true ... STATIC_KEY_TRUE_INIT
  sed -i 's/\bbool\b.*\bksu_su_compat_enabled\b.*=[[:space:]]*true/struct static_key_true ksu_su_compat_enabled = STATIC_KEY_TRUE_INIT/' "$F" 2>/dev/null || true
  # ternary: var ? 1 : 0 → static_key_enabled(&var.key) ? 1 : 0
  sed -i 's/ksu_su_compat_enabled[[:space:]]*?[[:space:]]*1[[:space:]]*:[[:space:]]*0/static_key_enabled(\&ksu_su_compat_enabled.key) ? 1 : 0/g' "$F"
  # unary '!': !var → !static_key_enabled(&var.key)
  sed -i 's/!ksu_su_compat_enabled/!static_key_enabled(\&ksu_su_compat_enabled.key)/g' "$F" 2>/dev/null || true
  # assign true → static_key_enable(&var.key)
  sed -i 's/ksu_su_compat_enabled[[:space:]]*=[[:space:]]*true/static_key_enable(\&ksu_su_compat_enabled.key)/g' "$F" 2>/dev/null || true
  # assign false → static_key_disable(&var.key)
  sed -i 's/ksu_su_compat_enabled[[:space:]]*=[[:space:]]*false/static_key_disable(\&ksu_su_compat_enabled.key)/g' "$F" 2>/dev/null || true
  # assign VAR → if/else static_key_enable/disabe(&var.key)
  sed -i 's/ksu_su_compat_enabled[[:space:]]*=[[:space:]]*\([a-zA-Z_][a-zA-Z0-9_]*\)[[:space:]]*;/if (\1) static_key_enable(\&ksu_su_compat_enabled.key); else static_key_disable(\&ksu_su_compat_enabled.key);/g' "$F" 2>/dev/null || true
  echo "kowsu_patches: $F"
done

# Also patch header
H="$D/feature/sucompat.h"
[ -f "$H" ] && sed -i 's/extern bool ksu_su_compat_enabled/extern struct static_key_true ksu_su_compat_enabled/' "$H" 2>/dev/null || true
echo "kowsu_patches: done"