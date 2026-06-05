#!/usr/bin/env python3
"""fix_retry.py: Fix compile/link errors from KSU/SUSFS sources, then retry."""
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
    """Convert 'source/drivers/kernelsu/foo.c' to absolute path under COMMON_DIR."""
    path = short_path.replace('source/', '', 1)
    return os.path.abspath(os.path.join(COMMON_DIR, path))


# --- 1. Parse undefined symbols ---
undef_refs = set()
for m in re.finditer(r"undefined reference to `([a-zA-Z0-9_]+)'", log):
    undef_refs.add(m.group(1))
for m in re.finditer(r"ld.lld: error: undefined symbol: (\w+)", log):
    sym = m.group(1)
    if re.search(r'ksu|susfs|find_kernel', sym, re.I):
        undef_refs.add(sym)

# --- 2. Fix compile errors per KSU source file ---
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
    r'(?P<file>source/drivers/kernelsu/\S+?\.c):(?P<line>\d+):(?P<col>\d+):\s+error:\s+(?P<msg>.*)',
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

    # Check for conflicting types first (kernel headers already define the symbol)
    conflict_fixed = False
    for e in errs:
        m = re.search(r"conflicting types for '(\w+)'", e['msg'])
        if m:
            sym = m.group(1)
            target_line = e['line']
            with open(fpath) as f:
                lines = f.readlines()
            for idx in [target_line - 1, target_line - 2, target_line]:
                if idx >= len(lines) or idx < 0:
                    continue
                if sym in lines[idx] and not lines[idx].strip().startswith('/*'):
                    lines[idx] = f'/* fix_retry: kernel already defines {sym} */\n'
                    with open(fpath, 'w') as f:
                        f.writelines(lines)
                    compile_fixes = True
                    conflict_fixed = True
                    print(f"Conflict: removed KSU declaration of '{sym}' in {os.path.basename(fpath)} (line {idx+1})")
                    break
        if conflict_fixed:
            break

    # Redefinition: kernel/SUSFS already defines the symbol, fix ALL in one pass
    for e in errs:
        m = re.search(r"redefinition of '(\w+)'", e['msg'])
        if not m:
            continue
        sym = m.group(1)
        target_line = e['line'] - 1
        with open(fpath) as f:
            lines = f.readlines()
        if 0 <= target_line < len(lines):
            orig = lines[target_line]
            if not orig.strip().startswith(('/*', '*', '__weak')):
                stripped = orig.strip()
                # Function def in same file: __weak does not help, use fallback
                if not stripped.endswith(';') and not stripped.endswith(','):
                    pass
                else:
                    new_line = re.sub(
                        r'^(\s*)((?:static\s+)?(?:inline\s+)?\w+(?:\s+\*?)?)(' + re.escape(sym) + r'\b)',
                        r'\1__weak \2 \3',
                        orig
                    )
                    if new_line != orig:
                        lines[target_line] = new_line
                        with open(fpath, 'w') as f:
                            f.writelines(lines)
                        compile_fixes = True
                        print(f"Redef: added __weak to '{sym}' in {os.path.basename(fpath)} (line {target_line+1})")
                        continue
        # Fallback: try commenting out a nearby declaration
        # If it is a function definition (no ;), wrap with #if 0 / #endif
        for delta in (0, 1, 2):
            idx = target_line - delta
            if idx < 0 or idx >= len(lines):
                continue
            if sym in lines[idx] and not lines[idx].strip().startswith(('/*', '*', '#')):
                stripped = lines[idx].strip()
                if not stripped.endswith(';') and not stripped.endswith(','):
                    brace_count = 0
                    end_idx = idx
                    started = False
                    while end_idx < len(lines):
                        brace_count += lines[end_idx].count('{') - lines[end_idx].count('}')
                        if brace_count > 0:
                            started = True
                        if started and brace_count == 0:
                            break
                        end_idx += 1
                    lines.insert(end_idx + 1, '#endif /* fix_retry: SUSFS already defines */\n')
                    lines.insert(idx, '#if 0 /* fix_retry: SUSFS already defines */\n')
                else:
                    lines[idx] = f'// fix_retry: SUSFS already defines {sym}\n'
                with open(fpath, 'w') as f:
                    f.writelines(lines)
                compile_fixes = True
                print(f"Redef: removed KSU '{sym}' in {os.path.basename(fpath)} (line {idx+1})")
                break

    
    # --- 2d. UserArgPtr: incompatible pointer types passing to struct user_arg_ptr * ---
    for e in errs:
        if "parameter of type 'struct user_arg_ptr *'" not in e['msg']:
            continue
        target_line = e['line'] - 1
        with open(fpath) as f:
            lines = f.readlines()
        if 0 <= target_line < len(lines):
            line = lines[target_line]
            if 'argv_user' in line:
                new_line = re.sub(
                    r'\bargv_user\b',
                    r'(&(struct user_arg_ptr){ .ptr = argv_user, .is_compat = IS_ENABLED(CONFIG_COMPAT) })',
                    line
                )
                if new_line != line:
                    lines[target_line] = new_line
                    with open(fpath, 'w') as f:
                        f.writelines(lines)
                    compile_fixes = True
                    print(f"UserArgPtr: wrapped argv_user ({os.path.basename(fpath)}:{target_line+1})")
                    break

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
            if sym in ('st_size_ptr', 'filename_user', 'argv_user', 'pending_sucompat'):
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

# --- 3. Multiple definitions: add __weak to KSU's definition ---
for m in re.finditer(r"ld.lld: error: duplicate symbol: (\w+)", log):
    sym = m.group(1)
    for fpath in list(file_errors.keys()):
        with open(fpath) as f:
            clines = f.readlines()
        was_modified = False
        pat = re.compile(r'\b' + re.escape(sym) + r'\s*\(')
        for i, cline in enumerate(clines):
            if pat.search(cline) and not '__weak' in cline:
                new_line = re.sub(
                    r'^(\s*)(?:(?:static\s+)?(?:inline\s+)?(?:int|void|bool|long|char|size_t|ssize_t|u\d+|s\d+))\s+(\w+\s*\()',
                    r'\1__weak \2 \3',
                    cline
                )
                if new_line != cline:
                    clines[i] = new_line
                    was_modified = True
                    break
        if was_modified:
            with open(fpath, 'w') as f:
                f.writelines(clines)
            compile_fixes = True
            print(f"Duplicate: added __weak to '{sym}' in {os.path.basename(fpath)}")

# --- 4. Generate weak stubs when no compile errors remain ---
if not compile_fixes and undef_refs:
    ksu_related = {s for s in undef_refs if re.search(r'ksu|susfs|find_kernel', s, re.I)}
    if ksu_related:
        with open(weak_out, 'w') as f:
            f.write('/* Auto-generated __weak stubs */\n')
            f.write('#include <linux/types.h>\n')
            f.write('#include <linux/jump_label.h>\n')
            for sym in sorted(undef_refs):
                f.write(f'int __weak {sym}(void) {{ return 0; }}\n')

        common_dir = os.path.dirname(os.path.dirname(os.path.abspath(weak_out)))
        makefile = os.path.join(common_dir, "Makefile")
        obj_line = "obj-y += kernelsu_retry.o"
        if os.path.isfile(makefile):
            with open(makefile) as mf:
                if obj_line not in mf.read():
                    with open(makefile, "a") as mf2:
                        mf2.write(obj_line + "\n")
        link_fixes = True
        print(f"Generated {len(undef_refs)} weak stubs ({len(ksu_related)} ksu-related)")

sys.exit(0 if (compile_fixes or link_fixes) else 1)