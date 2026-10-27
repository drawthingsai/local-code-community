#!/usr/bin/env python3 -I
"""Compare legacy ios_system commands between two osh_validation binaries.

Usage: parity.py BASELINE NEW CORPUS... [--locale L]... [--jobs N] [--show-same]

Each corpus line is one shell command, run from a fresh copy of the fixture
tree by both binaries. Lines starting with '#' are comments. stdout, stderr,
exit status and the resulting tree (types, modes, contents, symlink targets,
and modification times that were set explicitly) must match.
"""
import concurrent.futures
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

FIXED_TIME = 1704164640  # 2024-01-02 03:04:00 UTC


def make_fixture(root):
    def write(name, data, mode=0o644):
        path = os.path.join(root, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as handle:
            handle.write(data if isinstance(data, bytes) else data.encode())
        os.chmod(path, mode)
        os.utime(path, (FIXED_TIME, FIXED_TIME))

    lines = ''.join(f'line {i} value{i % 7} key{i % 3}\n' for i in range(1, 41))
    write('lines.txt', lines)
    write('words.txt', 'banana\nApple\ncherry\napple\nBanana\n\ndate\ncherry\n')
    write('numbers.txt', '10\n9\n-3\n2.5\n100\n0x10\n1e3\n007\n\n42\n')
    write('csv.txt', 'name,age,city\nann,31,Paris\nbob,27,Oslo\ncat,45,Rome\ndan,27,Lima\n')
    write('tabs.txt', 'a\tb\tc\n1\t2\t3\nx\t\tz\n')
    write('unicode.txt', 'café naïve\nŻółw 中文 🙂\nÉCOLE école\nstraße STRASSE\n')
    write('crlf.txt', 'one\r\ntwo\r\nthree\r\n')
    write('noeol.txt', 'first\nlast without newline')
    write('empty.txt', '')
    write('blank.txt', '\n\n \n\t\n')
    write('dups.txt', 'a\na\nb\nB\nb\nc\nc\nc\na\n')
    write('long.txt', ('x' * 5000 + '\n') * 3)
    write('binary.bin', bytes(range(256)) * 4)
    write('mixed.bin', b'text line\n\x00\x01binary\xff\nmore text\n')
    write('script.sed', 's/value/VALUE/g\n/key0/d\n')
    write('prog.awk', '{ total += $2 } END { print NR, total }\n')
    write('spaces in name.txt', 'spaced file\n')
    write('-dash.txt', 'leading dash\n')
    write('ro.txt', 'read only\n', 0o444)
    write('exec.sh', '#!/bin/sh\necho run\n', 0o755)
    write('dir/a.txt', 'a in dir\n')
    write('dir/b.log', 'b log\nerror here\n')
    write('dir/sub/c.txt', 'c in sub\nerror deep\n')
    write('dir/sub/deep/d.txt', 'deep\n')
    write('dir/.hidden', 'hidden\n')
    write('other/x.txt', 'x\n')
    os.symlink('lines.txt', os.path.join(root, 'link.txt'))
    os.symlink('dir', os.path.join(root, 'dirlink'))
    os.symlink('missing-target', os.path.join(root, 'broken'))
    os.symlink('../a.txt', os.path.join(root, 'dir/sub/up.txt'))
    os.makedirs(os.path.join(root, 'emptydir'))
    for directory in ['dir/sub/deep', 'dir/sub', 'dir', 'other', 'emptydir']:
        os.utime(os.path.join(root, directory), (FIXED_TIME, FIXED_TIME))


def snapshot(root, run_root):
    result = {}
    recent = time.time() - 600
    for directory, names, files in os.walk(root):
        names.sort()
        for name in sorted(names + files):
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            try:
                info = os.lstat(path)
            except OSError as error:
                result[relative] = ['unreadable', error.errno]
                continue
            entry = [stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode)]
            if stat.S_ISLNK(info.st_mode):
                # Absolute targets name the run's own directory.
                target = os.readlink(path)
                entry.append(target.replace(os.path.realpath(run_root), '<RUN>').replace(run_root, '<RUN>'))
            elif stat.S_ISREG(info.st_mode):
                try:
                    with open(path, 'rb') as handle:
                        entry.append(hashlib.sha256(handle.read()).hexdigest())
                except OSError as error:
                    entry.append(f'unreadable {error.errno}')
            if info.st_mtime < recent and not stat.S_ISLNK(info.st_mode) and not stat.S_ISDIR(info.st_mode):
                entry.append(int(info.st_mtime))
            result[relative] = entry
    return result


def run(binary, command, locale, template):
    run_root = tempfile.mkdtemp(prefix='parity-')
    try:
        fixture = os.path.join(run_root, 'fx')
        shutil.copytree(template, fixture, symlinks=True)
        capture = os.path.join(run_root, 'cap')
        os.makedirs(capture)
        os.makedirs(os.path.join(run_root, 'tmp'))
        script = (f"cd '{fixture}' && {{ {command}\n}} >'{capture}/out' 2>'{capture}/err'; "
                  f"echo $? >'{capture}/status'")
        env = {'PATH': '/usr/bin:/bin', 'HOME': run_root, 'TEST_TMPDIR': os.path.join(run_root, 'tmp'),
               'LC_ALL': locale, 'LANG': locale, 'TZ': 'UTC', 'COLUMNS': '80'}
        try:
            process = subprocess.run([binary, script], cwd=run_root, env=env, stdin=subprocess.DEVNULL,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=120)
        except subprocess.TimeoutExpired:
            return {'timeout': True}
        if not os.path.exists(os.path.join(capture, 'status')):
            # The process died: keep its own diagnostics (sanitizer reports).
            report = [line for line in process.stderr.decode(errors='replace').splitlines()
                      if not line.startswith('20')]
            text = '\n'.join(report[-40:]).replace(os.path.realpath(run_root), '<RUN>').replace(run_root, '<RUN>')
            return {'crash': process.returncode, 'report': text}

        # The harness puts its own directory on PATH; each binary has its own.
        binary_root = os.path.dirname(os.path.realpath(binary)).encode()

        def read(name):
            try:
                with open(os.path.join(capture, name), 'rb') as handle:
                    return handle.read().replace(run_root.encode(), b'<RUN>').replace(
                        os.path.realpath(run_root).encode(), b'<RUN>').replace(binary_root, b'<BIN>')
            except FileNotFoundError:
                return None
        return {'stdout': read('out'), 'stderr': read('err'), 'status': read('status'),
                'tree': snapshot(fixture, run_root)}
    finally:
        shutil.rmtree(run_root, ignore_errors=True)


def main():
    arguments = sys.argv[1:]
    locales, jobs, show_same, corpora, expected_path = [], 8, False, [], None
    baseline, new = arguments[0], arguments[1]
    index = 2
    while index < len(arguments):
        if arguments[index] == '--locale':
            locales.append(arguments[index + 1]); index += 2
        elif arguments[index] == '--jobs':
            jobs = int(arguments[index + 1]); index += 2
        elif arguments[index] == '--show-same':
            show_same = True; index += 1
        elif arguments[index] == '--expected':
            expected_path = arguments[index + 1]; index += 2
        else:
            corpora.append(arguments[index]); index += 1
    locales = locales or ['C', 'en_US.UTF-8']
    commands = []
    for corpus in corpora:
        with open(corpus) as handle:
            for line in handle:
                line = line.rstrip('\n')
                if line.strip() and not line.lstrip().startswith('#'):
                    commands.append(line)
    # Differences the new code is meant to have: "command<TAB>reason" lines.
    expected = {}
    if expected_path:
        with open(expected_path) as handle:
            for line in handle:
                if line.strip() and not line.startswith('#'):
                    command, reason = line.rstrip('\n').split('\t', 1)
                    expected[command] = reason
    differing = set()
    template = tempfile.mkdtemp(prefix='parity-fixture-')
    make_fixture(os.path.join(template, 'fx'))
    template = os.path.join(template, 'fx')
    work = [(command, locale) for command in commands for locale in locales]
    differences = 0
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        futures = {pool.submit(lambda c, l: (run(baseline, c, l, template), run(new, c, l, template)), c, l): (c, l)
                   for c, l in work}
        for future in concurrent.futures.as_completed(futures):
            command, locale = futures[future]
            old, current = future.result()
            if old == current:
                if show_same:
                    print(f'same [{locale}] {command}')
                continue
            differing.add(command)
            if command in expected:
                print(f'EXPECTED [{locale}] {command}  ({expected[command]})')
            else:
                differences += 1
                print(f'DIFF [{locale}] {command}')
            for key in ['timeout', 'crash', 'status', 'stdout', 'stderr']:
                if old.get(key) != current.get(key):
                    print(f'  {key}: baseline={old.get(key)!r:.400}\n  {key}:      new={current.get(key)!r:.400}')
            for side, result in (('baseline', old), ('new', current)):
                if result.get('report'):
                    print(f'  {side} report:\n' + result['report'])
            if old.get('tree') != current.get('tree') and 'tree' in old and 'tree' in current:
                a, b = old.get('tree') or {}, current.get('tree') or {}
                for name in sorted(set(a) | set(b)):
                    if a.get(name) != b.get(name):
                        print(f'  tree {name}: baseline={a.get(name)} new={b.get(name)}')
    stale = sorted(command for command in expected if command in commands and command not in differing)
    for command in stale:
        print(f'STALE expected difference no longer differs: {command}')
    print(f'{len(work)} runs, {differences} unexpected differences, '
          f'{len(differing & set(expected))} commands differing as expected, {len(stale)} stale')
    return 1 if differences or stale else 0


if __name__ == '__main__':
    sys.exit(main())
