#!/usr/bin/env python3
"""fix_retry.py: Auto-fix KSU/SUSFS compile/link errors, then retry make."""
import sys, re, os
from collections import defaultdict

logfile = sys.argv[1]
weak_out = sys.argv[2]

with open(logfile) as f:
    log = f.read()

link_fixes = False
compile_fixes = False

KSU_DIR = os.environ.get('WORKDIR', '')
COMMON_DIR = os.path.join(KSU_DIR, 'kernel_workspace/kernel_platform/common')


def resolve_ksu_source(short_path: str) -> str:
    path = short_path.replace('source/', '', 1)
    return os.path.abspath(os.path.join(COMMON_DIR, path))


# --- Phase 1: Collect undefined symbols ---
undef_refs = set()
for m in re.finditer(r"undefined reference to `([a-zA-Z0-9_]+)'", log):
    undef_refs.add(m.group(1))
for m in re.finditer(r"ld.lld: error: undefined symbol: (\w+)", log):
    sym = m.group(1)
    if re.search(r'ksu|susfs|find_kernel', sym, re.I):
        undef_refs.add(sym)


# --- Phase 2: Parse & fix compile errors ---
FIX_MAP = {
    'struct kprobe':     '#include <linux/kprobes.h>',
    'struct stat':       '#include <linux/stat.h>',
    'struct pt_regs':    '#include <linux/ptrace.h>',
    'struct work_struct':'#include <linux/workqueue.h>',
}
HEADER_FNS = {'register_kprobe', 'unregister_kprobe',
              'register_kretprobe', 'unregister_kretprobe'}

file_errors = defaultdict(list)
for m in re.finditer(
    r'(?P<file>source/drivers/kernelsu/[\w./-]+\.c):(?P<line>\d+):(?P<col>\d+):\s+error:\s+(?P<msg>.*)',
    log, re.MULTILINE
):
    full_path = resolve_ksu_source(m.group('file'))
    if os.path.exists(full_path):
        file_errors[full_path].append({
            'msg': m.group('msg'),
            'line': int(m.group('line')),
        })

for fpath, errs in file_errors.items():
    missing_includes = set()
    missing_externs = set()
    missing_forward = set()
    needs_local_vars = set()
    msg_text = ' '.join(e['msg'] for e in errs)

    # --- 2a. Conflicting types: kernel already declares it ---
    for e in errs:
        m = re.search(r"conflicting types for '(\w+)'", e['msg'])
        if not m:
            continue
        sym = m.group(1)
        target_line = e['line'] - 1
        with open(fpath) as f:
            lines = f.readlines()
        if not (0 <= target_line < len(lines)):
            continue
        orig = lines[target_line]
        if orig.strip().startswith(('/*', '#if 0')):
            continue
        # Check if this is a function definition (has braces)
        brace_depth = 0
        end_brace = -1
        for j in range(target_line, min(target_line + 200, len(lines))):
            brace_depth += lines[j].count('{') - lines[j].count('}')
            if brace_depth <= 0 and j > target_line:
                end_brace = j
                break
            if '{' in lines[j] and j == target_line:
                continue
            if '{' in lines[j] and brace_depth > 0:
                # found opening brace, keep searching for close
                continue
        if end_brace > target_line:
            lines.insert(end_brace + 1, '#endif\n')
            lines.insert(target_line, f'#if 0 /* fix_retry: kernel already defines {sym} */\n')
        else:
            lines[target_line] = f'/* fix_retry: kernel already defines {sym} */\n'
        with open(fpath, 'w') as f:
            f.writelines(lines)
        compile_fixes = True
        print(f"Conflict: removed KSU '{sym}' ({os.path.basename(fpath)}:{target_line+1})")

    # --- 2b. Redefinition: comment out or #if 0 the duplicate ---
    redef_syms = []
    for e in errs:
        m = re.search(r"redefinition of '(\w+)'", e['msg'])
        if m:
            redef_syms.append((m.group(1), e['line'] - 1))
    if redef_syms:
        with open(fpath) as f:
            lines = f.readlines()
        modified = False
        for sym, target_line in sorted(redef_syms, key=lambda x: x[1], reverse=True):
            if not (0 <= target_line < len(lines)):
                continue
            orig = lines[target_line]
            if orig.strip().startswith(('/*', '#if 0', '#endif')):
                continue
            # For variable declarations (line ends with ;)
            stripped = orig.strip()
            if stripped.endswith(';') or (stripped.endswith(',') and '{' not in stripped):
                lines[target_line] = f'/* fix_retry: redefined {sym} */ // ' + orig
                modified = True
                print(f"Redef: commented '{sym}' ({os.path.basename(fpath)}:{target_line+1})")
                continue
            # For function definitions: wrap in #if 0 / #endif
            brace_depth = 0
            end_brace = -1
            for j in range(target_line, len(lines)):
                brace_depth += lines[j].count('{') - lines[j].count('}')
                if brace_depth <= 0 and j > target_line:
                    end_brace = j
                    break
            if end_brace > target_line:
                lines.insert(end_brace + 1, '#endif\n')
                lines.insert(target_line, f'#if 0 /* fix_retry: {sym} already defined */\n')
            else:
                lines[target_line] = f'/* fix_retry: redefined {sym} */ // ' + orig
            modified = True
            print(f"Redef: #if 0 '{sym}' ({os.path.basename(fpath)}:{target_line+1})")
        if modified:
            with open(fpath, 'w') as f:
                f.writelines(lines)
            compile_fixes = True

    # --- 2c. StaticKey unary '!' ---
    for e in errs:
        m = re.search(r"invalid argument type 'struct (static_key_\w+)' to unary expression", e['msg'])
        if not m:
            continue
        target_line = e['line'] - 1
        with open(fpath) as f:
            lines = f.readlines()
        if 0 <= target_line < len(lines):
            line = lines[target_line]
            # Pattern: !ksu_su_compat_enabled → !static_key_enabled(&var.key)
            new_line = re.sub(
                r'!(\w+)\b(?!\s*\()',
                r'!static_key_enabled(&\1.key)',
                line
            )
            if new_line != line:
                lines[target_line] = new_line
                with open(fpath, 'w') as f:
                    f.writelines(lines)
                compile_fixes = True
                print(f"Unary: fixed '!{m.group(1)}' ({os.path.basename(fpath)}:{target_line+1})")

    # --- 2c2. StaticKey arithmetic/assignment ---
    for e in errs:
        if "where arithmetic or pointer type is required" in e['msg'] or \
           "assigning to 'struct static_key_true' from" in e['msg'] or \
           "assigning to 'struct static_key_false' from" in e['msg']:
            target_line = e['line'] - 1
            with open(fpath) as f:
                lines = f.readlines()
            if not (0 <= target_line < len(lines)):
                continue
            line = lines[target_line]
            modified = False
            # ternary: var ? X : Y → static_key_enabled(&var.key) ? X : Y
            new_line = re.sub(
                r'\b(\w+_enabled)\s*\?',
                r'static_key_enabled(&\1.key) ?',
                line
            )
            if new_line != line:
                lines[target_line] = new_line
                modified = True
            if not modified:
                # if (var) or while (var) → if (static_key_enabled(&var.key))
                new_line = re.sub(
                    r'\b(if|while)\s*\(\s*(\w+_enabled)\s*\)',
                    r'\1 (static_key_enabled(&\2.key))',
                    line
                )
                if new_line != line:
                    lines[target_line] = new_line
                    modified = True
            if not modified:
                # var = true → static_key_enable(&var.key)
                new_line = re.sub(
                    r'\b(\w+_enabled)\s*=\s*true\s*;',
                    r'static_key_enable(&\1.key);',
                    line
                )
                if new_line != line:
                    lines[target_line] = new_line
                    modified = True
            if not modified:
                # var = false → static_key_disable(&var.key)
                new_line = re.sub(
                    r'\b(\w+_enabled)\s*=\s*false\s*;',
                    r'static_key_disable(&\1.key);',
                    line
                )
                if new_line != line:
                    lines[target_line] = new_line
                    modified = True
            if not modified:
                # var = EXPR → if (EXPR) static_key_enable(&var.key); else static_key_disable(&var.key);
                m_assign = re.match(
                    r'^(\s*)\b(\w+_enabled)\s*=\s*(.+?)\s*;',
                    line
                )
                if m_assign:
                    indent, var, expr = m_assign.group(1), m_assign.group(2), m_assign.group(3)
                    lines[target_line] = (
                        f'{indent}if ({expr}) static_key_enable(&{var}.key); '
                        f'else static_key_disable(&{var}.key);\n'
                    )
                    modified = True
            if modified:
                with open(fpath, 'w') as f:
                    f.writelines(lines)
                compile_fixes = True
                print(f"StaticKey: fixed type usage ({os.path.basename(fpath)}:{target_line+1})")

    # --- 2d. UserArgPtr ---
    for e in errs:
        if "parameter of type 'struct user_arg_ptr *'" not in e['msg']:
            continue
        target_line = e['line'] - 1
        with open(fpath) as f:
            lines = f.readlines()
        if 0 <= target_line < len(lines) and 'argv_user' in lines[target_line]:
            new_line = re.sub(
                r'\bargv_user\b',
                r'(&(struct user_arg_ptr){ .ptr = argv_user, .is_compat = IS_ENABLED(CONFIG_COMPAT) })',
                lines[target_line]
            )
            if new_line != lines[target_line]:
                lines[target_line] = new_line
                with open(fpath, 'w') as f:
                    f.writelines(lines)
                compile_fixes = True
                print(f"UserArgPtr: fixed ({os.path.basename(fpath)}:{target_line+1})")

    # --- 2e. Collect missing includes/forward/extern ---
    for struct_name, include in FIX_MAP.items():
        if re.search(r'\b' + re.escape(struct_name) + r'\b', msg_text):
            missing_includes.add(include)

    for e in errs:
        m = re.search(r"implicit declaration of function '(\w+)'", e['msg'])
        if m and m.group(1) not in HEADER_FNS:
            missing_forward.add(f'int {m.group(1)}(void);')

    for e in errs:
        m = re.search(r"use of undeclared identifier '(\w+)'", e['msg'])
        if m:
            sym = m.group(1)
            if sym in ('st_size_ptr', 'filename_user', 'argv_user', 'pending_sucompat',
                       'p', 't'):
                continue
            if sym in ('ret', 'regs', 'statbuf'):
                needs_local_vars.add(sym)
            else:
                missing_externs.add(sym)

    for e in errs:
        m = re.search(r"variable has incomplete type 'struct (\w+)'", e['msg'])
        if m:
            sn = f"struct {m.group(1)}"
            for s, inc in FIX_MAP.items():
                if s == sn:
                    missing_includes.add(inc)

    if not (missing_includes or missing_forward or missing_externs or needs_local_vars):
        continue

    with open(fpath) as f:
        lines = f.readlines()
    if any('fix_retry_applied' in l for l in lines):
        continue

    insert = ['/* fix_retry_applied */\n']
    for inc in sorted(missing_includes):
        insert.append(f'{inc}\n')
    for fn in sorted(missing_forward):
        insert.append(f'{fn}\n')
    for sym in sorted(missing_externs):
        insert.append(f'extern int {sym};\n')

    if needs_local_vars:
        local_parts = []
        if 'ret' in needs_local_vars:
            local_parts.append('int ret;')
        if 'regs' in needs_local_vars:
            local_parts.append('const struct pt_regs *regs = NULL;')
        if 'statbuf' in needs_local_vars:
            local_parts.append('struct stat *statbuf = NULL;')
        local_line = ' '.join(local_parts) + '\n'
        brace_count = 0
        injected = False
        for i, line in enumerate(lines):
            brace_count += line.count('{')
            if brace_count > 0 and not injected:
                lines[i] = line + local_line
                injected = True
                break
        if not injected:
            lines.append(local_line)

    new_lines = []
    inserted = False
    for line in lines:
        if not inserted and line.startswith('#include'):
            new_lines.append(line)
            new_lines.extend(insert)
            inserted = True
        else:
            new_lines.append(line)
    if not inserted:
        new_lines = insert + lines
    with open(fpath, 'w') as f:
        f.writelines(new_lines)
    compile_fixes = True
    print(f"Fixed {os.path.basename(fpath)}: "
          f"{len(missing_includes)}i {len(missing_forward)}f {len(missing_externs)}e "
          f"local={needs_local_vars}")


# --- Phase 3: Duplicate symbols → __weak ---
dup_syms = set()
dup_locations = {}
for m in re.finditer(r"ld.lld: error: duplicate symbol: (\w+)\n>>> defined in [^\n]*?(\w+)\.o\)\n>>> defined in [^\n]*?(\w+)\.o\)", log):
    dup_syms.add(m.group(1))
    dup_locations[m.group(1)] = m.group(3)  # second .o file
if not dup_syms:
    for m in re.finditer(r"ld.lld: error: duplicate symbol: (\w+)", log):
        dup_syms.add(m.group(1))

if dup_syms:
    ksu_dir = os.path.join(COMMON_DIR, 'drivers/kernelsu')
    ksu_sources = []
    for root, dirs, files in os.walk(ksu_dir):
        for fname in files:
            if fname.endswith('.c'):
                ksu_sources.append(os.path.join(root, fname))

    for sym in dup_syms:
        # Prefer the second definition location if known
        preferred = dup_locations.get(sym)
        search_files = ksu_sources
        if preferred:
            pref_files = [f for f in ksu_sources if os.path.basename(f) == preferred + '.c']
            if pref_files:
                search_files = pref_files

        for fpath in search_files:
            with open(fpath) as f:
                clines = f.readlines()
            was_modified = False
            for i, cline in enumerate(clines):
                if sym in cline and '__weak' not in cline and '#if 0' not in cline:
                    new_line = re.sub(
                        r'^(\s*)((?:static\s+)?(?:inline\s+)?[\w]+(?:\s+\*?\s*)?)(' + re.escape(sym) + r'\b)',
                        r'\1__weak \2\3', cline
                    )
                    if new_line != cline:
                        clines[i] = new_line
                        was_modified = True
                        break
            if was_modified:
                with open(fpath, 'w') as f:
                    f.writelines(clines)
                compile_fixes = True
                print(f"Duplicate: __weak '{sym}' ({os.path.basename(fpath)})")
                break


# --- Phase 4: Weak stubs for remaining undefined symbols ---
if not compile_fixes and undef_refs:
    ksu_related = {s for s in undef_refs if re.search(r'ksu|susfs|find_kernel', s, re.I)}
    if ksu_related:
        with open(weak_out, 'w') as f:
            f.write('/* Auto-generated __weak stubs */\n')
            f.write('#include <linux/types.h>\n')
            f.write('#include <linux/jump_label.h>\n')
            for sym in sorted(undef_refs):
                f.write(f'int __weak {sym}(void) {{ return 0; }}\n')

        # Write Makefile entry in common/ (ONE dirname, not two!)
        common_dir = os.path.dirname(os.path.abspath(weak_out))
        makefile = os.path.join(common_dir, "Makefile")
        obj_line = "obj-y += kernelsu_retry.o"
        if os.path.isfile(makefile):
            with open(makefile) as mf:
                if obj_line not in mf.read():
                    with open(makefile, "a") as mf2:
                        mf2.write(obj_line + "\n")
        link_fixes = True
        print(f"Generated {len(undef_refs)} weak stubs ({len(ksu_related)} ksu-related) at {common_dir}")

sys.exit(0 if (compile_fixes or link_fixes) else 1)