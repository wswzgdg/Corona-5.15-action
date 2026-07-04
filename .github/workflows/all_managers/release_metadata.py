#!/usr/bin/env python3

"""Helpers for build-kernel-matrix release metadata.

This script keeps the workflow YAML readable by moving artifact collection and
release body generation into a normal Python module.
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


COMMON_REPO = ('common', 'kernel_common_oplus', 'https://github.com/Corona-oplus-kernel/kernel_common_oplus.git', 'android13-5.15-lts')
AK3_REPOS = {
    'main': ('ak3-main', 'main', 'https://github.com/Corona-oplus-kernel/AnyKernel3.git', 'main'),
    'kpm': ('ak3-kpm', 'kpm', 'https://github.com/Corona-oplus-kernel/AnyKernel3.git', 'kpm'),
}
SUSFS_REMOTE = 'https://gitlab.com/simonpunk/susfs4ksu'
MANAGER_REPOS = {
    'resukisu': ('manager', 'ReSukiSU', 'https://github.com/ReSukiSU/ReSukiSU.git', 'dev'),
    'sukisu': ('manager', 'SukiSU', 'https://github.com/ShirkNeko/SukiSU-Ultra.git', 'main'),
    'ksunext': ('manager', 'KSUNEXT', 'https://github.com/pershoot/KernelSU-Next.git', 'dev-susfs'),
    'ksu': ('manager', 'KernelSU', 'https://github.com/tiann/KernelSU.git', 'dev'),
    'kowsu': ('manager', 'KowSU', 'https://github.com/KOWX712/KernelSU.git', 'master'),
}
MANAGER_ORDER = ['resukisu', 'sukisu', 'ksunext', 'ksu', 'kowsu', 'none']
MANAGER_FLAGS = {
    'resukisu': 'BUILD_RESUKISU',
    'sukisu': 'BUILD_SUKISU',
    'ksunext': 'BUILD_KSUNEXT',
    'ksu': 'BUILD_KSU',
    'kowsu': 'BUILD_KOWSU',
    'none': 'BUILD_NONE',
}
AK3_BY_MANAGER = {
    'resukisu': 'kpm',
    'sukisu': 'kpm',
    'ksunext': 'main',
    'ksu': 'main',
    'kowsu': 'main',
    'none': 'main',
}
ZIP_NAME_PATTERN = re.compile(r'^AK3-[^-]+-(.+?)(?:_SUSFS)?@bai\.zip$')
SOURCE_META_PATTERN = re.compile(r'<!-- source-meta-begin\r?\n(.*?)\r?\nsource-meta-end -->', re.S)


def collect_artifact_metadata(release_dir='release_zips', clang_meta_dir='clang_meta'):
    """Summarize successful managers and the resolved clang version label."""
    success_managers = []
    for path in sorted(Path(release_dir).glob('AK3-*.zip')):
        match = ZIP_NAME_PATTERN.match(path.name)
        if not match:
            continue
        manager = match.group(1)
        if manager == 'noksu':
            manager = 'none'
        success_managers.append(manager.lower())

    Path('successful_managers.json').write_text(
        json.dumps(sorted(set(success_managers)), ensure_ascii=False)
    )

    clang_versions = []
    for path in sorted(Path(clang_meta_dir).glob('*.txt')):
        value = path.read_text(encoding='utf-8').strip()
        if value:
            clang_versions.append(value)
    label = 'unknown'
    versions = sorted(set(clang_versions))
    if len(versions) == 1:
        label = versions[0]
    elif versions:
        label = 'mixed'
    Path('clang_version_label.txt').write_text(label)


def get_ak3_branch(manager):
    """Resolve which AnyKernel3 branch a manager should compare against."""
    if manager == 'none':
        return 'main'
    return AK3_BY_MANAGER[manager]


def normalize_github_url(url):
    """Normalize supported GitHub remotes into clickable https links."""
    url = url.strip()
    if url.startswith('git@github.com:'):
        repo = url.split(':', 1)[1]
        if repo.endswith('.git'):
            repo = repo[:-4]
        return f'https://github.com/{repo}'
    if 'github.com/' in url:
        repo = url.split('github.com/', 1)[1]
        repo = repo.split('@', 1)[-1]
        if repo.endswith('.git'):
            repo = repo[:-4]
        return f'https://github.com/{repo}'
    return url


def with_github_token(remote):
    """Inject the token only for private Corona repositories."""
    token = os.environ.get('KERNEL_COMMON_TOKEN', '').strip()
    if not token:
        return remote
    if 'github.com/Corona-oplus-kernel/' in remote:
        return remote.replace('https://github.com/', f'https://{token}@github.com/')
    return remote


def is_private_release_repo(remote):
    return 'github.com/Corona-oplus-kernel/' in remote


def git_check_output(command, **kwargs):
    """Run git commands with prompting disabled for CI safety."""
    env = kwargs.pop('env', os.environ.copy())
    env['GIT_TERMINAL_PROMPT'] = '0'
    return subprocess.check_output(command, text=True, env=env, stderr=subprocess.STDOUT, **kwargs)


def ls_remote_commit(remote, branch):
    """Read the current remote branch head without cloning a full repo."""
    tokenized_remote = with_github_token(remote)
    if is_private_release_repo(remote) and tokenized_remote == remote:
        return None
    command = ['git', 'ls-remote', tokenized_remote, f'refs/heads/{branch}']
    try:
        output = git_check_output(command).strip()
    except subprocess.CalledProcessError as exc:
        message = exc.output.strip() if exc.output else str(exc)
        if is_private_release_repo(remote) and ('Repository not found' in message or 'could not read Username' in message):
            return None
        print(f'Warning: failed to query {remote}@{branch}: {message}', file=sys.stderr)
        return None
    if not output:
        print(f'Warning: no refs returned for {remote}@{branch}', file=sys.stderr)
        return None
    return output.split()[0]


def read_remote_file(remote, branch, file_path):
    """Fetch a single file from a remote branch without a full clone."""
    tokenized_remote = with_github_token(remote)
    if is_private_release_repo(remote) and tokenized_remote == remote:
        return None
    with tempfile.TemporaryDirectory(prefix='release-meta-') as temp_dir:
        try:
            git_check_output(['git', 'init'], cwd=temp_dir)
            git_check_output(['git', 'fetch', '--depth', '1', '--filter=blob:none', tokenized_remote, f'refs/heads/{branch}'], cwd=temp_dir)
            return git_check_output(['git', 'show', f'FETCH_HEAD:{file_path}'], cwd=temp_dir).strip()
        except subprocess.CalledProcessError as exc:
            message = exc.output.strip() if exc.output else str(exc)
            if is_private_release_repo(remote) and ('Repository not found' in message or 'could not read Username' in message):
                return None
            print(f'Warning: failed to read {file_path} from {remote}@{branch}: {message}', file=sys.stderr)
            return None


def list_recent_commits(remote, branch, limit=15):
    """Fetch a short recent history for fallback release notes rendering."""
    tokenized_remote = with_github_token(remote)
    if is_private_release_repo(remote) and tokenized_remote == remote:
        return []
    with tempfile.TemporaryDirectory(prefix='release-meta-') as temp_dir:
        try:
            git_check_output(['git', 'init'], cwd=temp_dir)
            git_check_output(['git', 'fetch', '--depth', str(limit), '--filter=blob:none', tokenized_remote, f'refs/heads/{branch}'], cwd=temp_dir)
            output = git_check_output(
                ['git', 'log', f'--max-count={limit}', '--format=%H%x01%s', 'FETCH_HEAD'],
                cwd=temp_dir,
            ).strip()
        except subprocess.CalledProcessError as exc:
            message = exc.output.strip() if exc.output else str(exc)
            if is_private_release_repo(remote) and ('Repository not found' in message or 'could not read Username' in message):
                return []
            print(f'Warning: failed to list commits for {remote}@{branch}: {message}', file=sys.stderr)
            return []
    separator = chr(1)
    commits = []
    for line in output.splitlines():
        if separator not in line:
            continue
        commit, subject = line.split(separator, 1)
        commits.append({'commit': commit, 'subject': subject})
    return commits


def list_commits_range(remote, branch, from_commit):
    """Fetch commits in from_commit..HEAD for precise compare sections."""
    tokenized_remote = with_github_token(remote)
    if is_private_release_repo(remote) and tokenized_remote == remote:
        return None
    with tempfile.TemporaryDirectory(prefix='release-meta-') as temp_dir:
        try:
            git_check_output(['git', 'init'], cwd=temp_dir)
            git_check_output(['git', 'fetch', '--filter=blob:none', tokenized_remote, f'refs/heads/{branch}'], cwd=temp_dir)
            try:
                git_check_output(['git', 'fetch', '--filter=blob:none', tokenized_remote, from_commit], cwd=temp_dir)
            except subprocess.CalledProcessError:
                pass
            output = git_check_output(
                ['git', 'log', '--format=%H%x01%s', f'{from_commit}..FETCH_HEAD'],
                cwd=temp_dir,
            ).strip()
        except subprocess.CalledProcessError as exc:
            message = exc.output.strip() if exc.output else str(exc)
            print(f'Warning: failed to list commit range for {remote}@{branch}: {message}', file=sys.stderr)
            return None
    separator = chr(1)
    commits = []
    for line in output.splitlines():
        if separator not in line:
            continue
        commit, subject = line.split(separator, 1)
        commits.append({'commit': commit, 'subject': subject})
    return commits


def env_flag(name, default=True):
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {'1', 'true', 'yes', 'on'}


def get_selected_managers():
    return [manager for manager in MANAGER_ORDER if env_flag(MANAGER_FLAGS[manager], True)]


def get_successful_managers(path='successful_managers.json'):
    file_path = Path(path)
    if not file_path.exists():
        return set()
    try:
        data = json.loads(file_path.read_text())
    except json.JSONDecodeError:
        return set()
    return {str(item).strip().lower() for item in data if str(item).strip()}


def get_susfs_label():
    value = os.environ.get('BUILD_SUSFS', '').strip().lower()
    if value == 'both':
        return 'both'
    return 'on' if env_flag('BUILD_SUSFS', default=True) else 'off'


def get_susfs_version_label():
    susfs_label = get_susfs_label()
    if susfs_label == 'off':
        return ''

    common_branch = COMMON_REPO[3]
    match = re.search(r'(android\d+)-(\d+\.\d+)', common_branch)
    branch_candidates = []
    if match:
        android_name = match.group(1)
        kernel_version = match.group(2)
        branch_candidates.extend([
            f'gki-{android_name}-{kernel_version}-dev',
            f'gki-{android_name}-{kernel_version}',
        ])

    android_release = os.environ.get('BUILD_ANDROID_RELEASE', '16').strip() or '16'
    branch_candidates.extend([
        f'gki-android{android_release}-5.15-dev',
        f'gki-android{android_release}-5.15',
        f'gki-{android_release}-5.15-dev',
        f'gki-{android_release}-5.15',
    ])

    seen = set()
    for branch in branch_candidates:
        if not branch or branch in seen:
            continue
        seen.add(branch)
        module_prop = read_remote_file(SUSFS_REMOTE, branch, 'ksu_module_susfs/module.prop') or ''
        version_match = re.search(r'^version=(.+)$', module_prop, re.M)
        if version_match:
            return version_match.group(1).strip()

    return branch_candidates[0] if branch_candidates else ''


def get_kpn_label():
    return 'on' if env_flag('BUILD_USE_KPN', default=False) else 'off'


def build_repo_entry(repo_tuple):
    """Convert tuple repo definitions into the rendered metadata shape."""
    key, label, remote, branch = repo_tuple
    return {
        'key': key,
        'label': label,
        'remote': remote,
        'branch': branch,
        'commit': ls_remote_commit(remote, branch),
    }


def build_current_meta(selected_managers, successful_managers):
    """Build the current source snapshot that will be rendered and persisted."""
    current = {
        '_build': {
            'susfs': get_susfs_label(),
            'susfs_version': get_susfs_version_label(),
            'kpn': get_kpn_label(),
            'droidspaces': 'on' if os.environ.get('BUILD_DROIDSPACES', 'true').lower() == 'true' else 'off',
            'android': os.environ.get('BUILD_ANDROID_RELEASE', '16'),
            'clang': os.environ.get('BUILD_CLANG_VERSION', ''),
            'version_name': os.environ.get('BUILD_VERSION_NAME', ''),
            'kernel_suffix': os.environ.get('BUILD_KERNEL_SUFFIX', ''),
        },
        '_shared': {'repos': [build_repo_entry(COMMON_REPO)]},
        '_ak3': {'repos': []},
    }
    required_ak3 = []
    for branch_name in ['main', 'kpm']:
        if any(get_ak3_branch(manager) == branch_name for manager in successful_managers):
            required_ak3.append(branch_name)
    for branch_name in required_ak3:
        current['_ak3']['repos'].append(build_repo_entry(AK3_REPOS[branch_name]))
    for manager in selected_managers:
        if manager in MANAGER_REPOS and manager in successful_managers:
            current[manager] = {'repos': [build_repo_entry(MANAGER_REPOS[manager])]}
    return current


def render_commit_link(remote, current_commit, previous_commit=None, compare_text=False):
    if not current_commit:
        return None
    remote = normalize_github_url(remote)
    if remote.startswith('https://github.com/'):
        if previous_commit and previous_commit != current_commit:
            text = f'{previous_commit[:7]}...{current_commit[:7]}' if compare_text else current_commit[:7]
            return f'[`{text}`]({remote}/compare/{previous_commit}...{current_commit})'
        return f'[`{current_commit[:7]}`]({remote}/commit/{current_commit})'
    text = f'{previous_commit[:7]}...{current_commit[:7]}' if previous_commit and previous_commit != current_commit and compare_text else current_commit[:7]
    return f'`{text}`'


def render_hash_line(label, repo, previous_repo=None):
    current_commit = repo.get('commit')
    if not current_commit:
        return None
    previous_commit = (previous_repo or {}).get('commit')
    rendered = render_commit_link(repo.get('remote', ''), current_commit, previous_commit, compare_text=False)
    return f'- {label}: {rendered}'


def render_common_compare_line(repo, previous_repo=None):
    current_commit = repo.get('commit')
    previous_commit = (previous_repo or {}).get('commit')
    if not current_commit or not previous_commit or previous_commit == current_commit:
        return None
    rendered = render_commit_link(repo.get('remote', ''), current_commit, previous_commit, compare_text=True)
    return f'- {repo.get("label", "common")}: {rendered}'


def render_recent_commit_line(remote, item):
    commit = item.get('commit')
    subject = item.get('subject', '').strip() or '(无标题)'
    if not commit:
        return None
    remote = normalize_github_url(remote)
    safe_subject = subject.replace('`', "'")
    if remote.startswith('https://github.com/'):
        return f'- [`{commit[:7]}`]({remote}/commit/{commit}) {safe_subject}'
    return f'- `{commit[:7]}` {safe_subject}'


def load_previous_meta(previous_body):
    """Extract the hidden JSON snapshot from the previous stable release body."""
    match = SOURCE_META_PATTERN.search(previous_body)
    if not match:
        return {}
    try:
        return json.loads(match.group(1))
    except json.JSONDecodeError:
        return {}


def append_rendered_commits(lines, remote, commits):
    """Append rendered commit lines and skip entries that cannot be rendered."""
    for item in commits:
        rendered = render_recent_commit_line(remote, item)
        if rendered:
            lines.append(rendered)


def append_common_section(lines, current_meta, previous_meta):
    """Render the kernel common repository section."""
    common_repo = current_meta['_shared']['repos'][0]
    previous_common = {repo['key']: repo for repo in previous_meta.get('_shared', {}).get('repos', [])}.get('common')
    lines.append('### 内核')
    common_line = render_common_compare_line(common_repo, previous_common)
    if common_line:
        lines.append(common_line)
        range_commits = list_commits_range(common_repo['remote'], common_repo['branch'], previous_common['commit'])
        if range_commits is not None:
            append_rendered_commits(lines, common_repo['remote'], range_commits)
        else:
            append_rendered_commits(lines, common_repo['remote'], list_recent_commits(common_repo['remote'], common_repo['branch'], limit=20))
    elif previous_common and previous_common.get('commit') and previous_common.get('commit') == common_repo.get('commit'):
        lines.append('- 无修改')
    else:
        recent_commits = list_recent_commits(common_repo['remote'], common_repo['branch'], limit=20)
        if recent_commits:
            append_rendered_commits(lines, common_repo['remote'], recent_commits)
        else:
            rendered = render_hash_line(common_repo['label'], common_repo, previous_common)
            if rendered:
                lines.append(rendered)
    lines.append('')


def build_previous_ak3_map(previous_meta):
    """Normalize current and legacy AK3 metadata into one lookup map."""
    previous_ak3 = {repo['key']: repo for repo in previous_meta.get('_ak3', {}).get('repos', [])}
    if previous_ak3:
        return previous_ak3
    for section_key, section in previous_meta.items():
        if section_key.startswith('_'):
            continue
        for repo in section.get('repos', []):
            if repo.get('key') == 'ak3' and repo.get('commit'):
                mapped_branch = AK3_BY_MANAGER.get(section_key, 'main')
                legacy_key = f'ak3-{mapped_branch}'
                if legacy_key not in previous_ak3:
                    previous_ak3[legacy_key] = {**repo, 'key': legacy_key}
    return previous_ak3


def append_ak3_section(lines, current_meta, previous_meta):
    """Render AnyKernel3 branch changes when the current release uses them."""
    ak3_repos = current_meta.get('_ak3', {}).get('repos', [])
    if not ak3_repos:
        return

    previous_ak3 = build_previous_ak3_map(previous_meta)
    lines.append('### 刷机包')
    missing_previous_ak3 = not previous_ak3
    for repo in ak3_repos:
        prev_repo = previous_ak3.get(repo['key'])
        if missing_previous_ak3:
            lines.append(f"- {repo.get('label', 'AK3')}: 无修改")
            continue
        compare_line = render_common_compare_line(repo, prev_repo)
        if compare_line:
            lines.append(compare_line)
            range_commits = list_commits_range(repo['remote'], repo['branch'], prev_repo['commit'])
            if range_commits is not None:
                append_rendered_commits(lines, repo['remote'], range_commits)
            else:
                append_rendered_commits(lines, repo['remote'], list_recent_commits(repo['remote'], repo['branch'], limit=15))
        elif prev_repo and prev_repo.get('commit') and prev_repo.get('commit') == repo.get('commit'):
            lines.append(f"- {repo.get('label', 'AK3')}: 无修改")
        else:
            lines.append(f"- {repo.get('label', 'AK3')}: 无修改")
    lines.append('')


def append_manager_section(lines, current_meta, previous_meta):
    """Render manager source versions as a compact section."""
    manager_lines = []
    for manager in MANAGER_ORDER:
        if manager not in current_meta or manager.startswith('_'):
            continue
        repo = current_meta[manager]['repos'][0]
        previous_repo = {item['key']: item for item in previous_meta.get(manager, {}).get('repos', [])}.get('manager')
        rendered = render_hash_line(repo['label'], repo, previous_repo)
        if rendered:
            manager_lines.append(rendered)
    if not manager_lines:
        return
    lines.append('### 管理器')
    lines.extend(manager_lines)
    lines.append('')


def append_hidden_meta(lines, current_meta):
    """Persist the current snapshot only for stable releases."""
    is_prerelease = env_flag('IS_PRERELEASE', default=False)
    if not is_prerelease:
        lines.append(f"<!-- source-meta-begin\n{json.dumps(current_meta, ensure_ascii=False, separators=(',', ':'))}\nsource-meta-end -->")


def build_release_lines(previous_meta, current_meta):
    """Render the markdown lines for the release body."""
    build_meta = current_meta.get('_build', {})
    susfs_label = build_meta.get('susfs', get_susfs_label())
    susfs_version = build_meta.get('susfs_version', get_susfs_version_label())
    kpn_label = build_meta.get('kpn', get_kpn_label())
    droidspaces_label = build_meta.get('droidspaces', 'on')
    android_label = build_meta.get('android', '16')
    clang_label = build_meta.get('clang', '')
    version_name = build_meta.get('version_name', '')
    kernel_suffix = build_meta.get('kernel_suffix', '')
    lines = ['## 构建选项', '']
    lines.append(f'- Android: {android_label}')
    lines.append(f'- SUSFS: {susfs_label}')
    if susfs_label != 'off' and susfs_version:
        lines.append(f'- SUSFS 版本: {susfs_version}')
    lines.append(f'- Droidspaces: {droidspaces_label}')
    lines.append(f'- KP-N: {kpn_label}')
    if clang_label:
        lines.append(f'- Clang: {clang_label}')
    if version_name:
        lines.append(f'- 版本名: {version_name}')
    if kernel_suffix:
        lines.append(f'- 内核后缀: {kernel_suffix}')
    lines.extend(['', '## 源码变更', ''])
    append_common_section(lines, current_meta, previous_meta)
    append_ak3_section(lines, current_meta, previous_meta)
    append_manager_section(lines, current_meta, previous_meta)
    append_hidden_meta(lines, current_meta)
    return lines


def generate_release_body(output_path='release_body.md'):
    """Entry point for producing the release body markdown file."""
    previous_body_b64 = os.environ.get('PREVIOUS_RELEASE_BODY_B64', '')
    previous_body = ''
    if previous_body_b64:
        previous_body = base64.b64decode(previous_body_b64).decode('utf-8')
    previous_meta = load_previous_meta(previous_body)
    if env_flag('IS_PRERELEASE', default=False):
        previous_meta = {}
    selected_managers = get_selected_managers()
    successful_managers = get_successful_managers()
    current_meta = build_current_meta(selected_managers, successful_managers)
    lines = build_release_lines(previous_meta, current_meta)
    Path(output_path).write_text('\n'.join(lines) + '\n')


def main():
    """Dispatch subcommands used by build-kernel-matrix.yml."""
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest='command', required=True)

    collect_parser = subparsers.add_parser('collect-artifacts')
    collect_parser.add_argument('--release-dir', default='release_zips')
    collect_parser.add_argument('--clang-meta-dir', default='clang_meta')

    body_parser = subparsers.add_parser('generate-release-body')
    body_parser.add_argument('--output', default='release_body.md')

    args = parser.parse_args()
    if args.command == 'collect-artifacts':
        collect_artifact_metadata(args.release_dir, args.clang_meta_dir)
    elif args.command == 'generate-release-body':
        generate_release_body(args.output)


if __name__ == '__main__':
    main()
