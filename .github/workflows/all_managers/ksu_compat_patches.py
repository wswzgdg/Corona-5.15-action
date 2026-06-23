#!/usr/bin/env python3
"""
ksu_compat_patches.py: Targeted compatibility patches for KSU source files.

These fix known issues in specific KSU versions that fail on 5.15 kernels.
Each patch checks if the issue still exists before applying.

Run BEFORE compilation. Returns exit 0 if patches applied, 1 if nothing needed.
"""
import os, re, sys

KSU_DIR = os.environ.get('WORKDIR', '')
COMMON_DIR = os.path.join(KSU_DIR, 'kernel_workspace/kernel_platform/common')
KSU_SRC = os.path.join(COMMON_DIR, 'drivers/kernelsu')

applied = []
skipped = []


def patch_file(rel_path, check_fn, fix_fn, description):
    """Apply a patch if the check function says it's needed."""
    fpath = os.path.join(KSU_SRC, rel_path)
    if not os.path.isfile(fpath):
        skipped.append(f"{description} (file not found: {rel_path})")
        return
    with open(fpath) as f:
        content = f.read()
    if not check_fn(content):
        skipped.append(f"{description} (not needed)")
        return
    new_content = fix_fn(content)
    if new_content == content:
        skipped.append(f"{description} (no change)")
        return
    with open(fpath, 'w') as f:
        f.write(new_content)
    applied.append(description)


# --- Patch 1: for_each_thread(p, t) missing variable declarations ---
# KSU app_profile.c uses for_each_thread(p, t) but some versions
# don't declare p/t at function scope when CONFIG_KSU_TRACEPOINT_HOOK is set.

def check_for_each_thread_missing_decl(content):
    """Check if for_each_thread(p, t) is used but p is not declared in the same function."""
    if 'for_each_thread' not in content:
        return False
    lines = content.split('\n')
    for i, line in enumerate(lines):
        if 'for_each_thread' in line and re.search(r'for_each_thread\s*\(\s*p\s*,\s*t\s*\)', line):
            # Walk backward to find function start
            brace_depth = 0
            for j in range(i - 1, max(i - 80, -1), -1):
                brace_depth -= lines[j].count('{')
                brace_depth += lines[j].count('}')
                if brace_depth < 0:
                    # Found function body start, check for p declaration
                    block = '\n'.join(lines[j:i])
                    if re.search(r'struct\s+task_struct\s+\*\s*p\b', block):
                        return False  # Already declared
                    return True  # Missing
    return False


def fix_for_each_thread_missing_decl(content):
    """Add p and t declarations before for_each_thread usage."""
    lines = content.split('\n')
    result = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.search(r'for_each_thread\s*\(\s*p\s*,\s*t\s*\)', line):
            # Check if declarations exist above
            block_above = '\n'.join(lines[max(0, i-40):i])
            has_p = bool(re.search(r'struct\s+task_struct\s+\*\s*p\b', block_above))
            has_t = bool(re.search(r'struct\s+task_struct\s+\*\s*t\b', block_above))
            indent = re.match(r'^(\s*)', line).group(1)
            if not has_p and not has_t:
                result.append(f'{indent}struct task_struct *p = current, *t;')
            elif not has_p:
                result.append(f'{indent}struct task_struct *p = current;')
            elif not has_t:
                result.append(f'{indent}struct task_struct *t;')
        result.append(line)
        i += 1
    return '\n'.join(result)


patch_file(
    'policy/app_profile.c',
    check_for_each_thread_missing_decl,
    fix_for_each_thread_missing_decl,
    "app_profile: add missing p/t declarations for for_each_thread"
)


# --- Summary ---
if applied:
    print(f"Applied {len(applied)} compat patch(es):")
    for desc in applied:
        print(f"  + {desc}")
if skipped:
    print(f"Skipped {len(skipped)} patch(es):")
    for desc in skipped:
        print(f"  - {desc}")

# Report for release notes
if skipped and not applied:
    print("\nNOTE: All compat patches skipped — upstream may have fixed these issues.")
    print("Consider removing obsolete patches from ksu_compat_patches.py")

sys.exit(0 if applied else 1)
