#!/usr/bin/env python3
"""Cross-check embedded Info-ZIP against system tools and Python zipfile."""
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time
import zipfile
ROOT = pathlib.Path(tempfile.mkdtemp(prefix='infozip-validation-'))
ZIP = 'zip'
UNZIP = 'unzip'
runner = str(pathlib.Path(sys.argv[1]).resolve())

def invoke(args, **kwargs):
    if args[0] in (ZIP, UNZIP):
        args = [runner, 'cd ' + shlex.quote(str(ROOT)) + ' && ' + shlex.join(args)]
    return subprocess.run(args, **kwargs)
checks = []


def run(args, status=0, **kw):
    p = invoke(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, **kw)
    assert p.returncode == status, (args, p.returncode, p.stdout[-1000:], p.stderr[-1000:])
    return p.stdout

def check(name, condition):
    assert condition, name
    checks.append(name)
(ROOT / 'input').mkdir()
fixtures = {
    'empty': b'',
    'tiny': b'abc',
    'random.bin': os.urandom(256 * 1024),
    'text.txt': b'apple banana cherry\n' * 10000,
    'hello world.txt': b'spaces\n',
    '日本語.txt': '世界\n'.encode(),
}
for n, b in fixtures.items():
    (ROOT / 'input' / n).write_bytes(b)
(ROOT / 'input' / 'link').symlink_to('text.txt')
for level in range(10):
    a = f'level-{level}.zip'
    run([ZIP, '-q', f'-{level}', '-r', a, 'input'])
    run(['/usr/bin/unzip', '-tqq', a])
    run([UNZIP, '-tqq', a])
    with zipfile.ZipFile(ROOT / a) as z:
        for n, b in fixtures.items():
            check(f'level {level} bytes {n}', z.read('input/' + n) == b)
    run([UNZIP, '-q', a, '-d', f'extract-{level}'])
    for n, b in fixtures.items():
        check(f'level {level} extract {n}', (ROOT / f'extract-{level}' / 'input' / n).read_bytes() == b)
check('unzip pipe output', run([UNZIP, '-p', 'level-6.zip', 'input/tiny']) == b'abc')
run([ZIP, '-qz', 'comment.zip', 'input/tiny'], input=b'archive comment\n.\n')
run([ZIP, '-qc', 'entry-comment.zip', 'input/tiny'], input=b'entry comment\n')
with zipfile.ZipFile(ROOT / 'comment.zip') as z:
    check('archive comment', z.comment == b'archive comment')
with zipfile.ZipFile(ROOT / 'entry-comment.zip') as z:
    check('entry comment', z.getinfo('input/tiny').comment == b'entry comment')
run([ZIP, '-qy', 'symlink.zip', 'input/link'])
run([UNZIP, '-q', 'symlink.zip', '-d', 'symlink-out'])
check('symlink restored', (ROOT / 'symlink-out/input/link').is_symlink())
for creator, extractor, name in [(ZIP, '/usr/bin/unzip', 'our'), ('/usr/bin/zip', UNZIP, 'system')]:
    run([creator, '-q', '-P', 'testpass', name + '.zip', 'input/tiny'])
    check(name + ' password interoperability', run([extractor, '-P', 'testpass', '-p', name + '.zip', 'input/tiny']) == b'abc')
    run([extractor, '-P', 'wrong', '-tqq', name + '.zip'], status=82)
run([ZIP, '-q', 'update.zip', 'input/tiny'])
(ROOT / 'input' / 'tiny').write_bytes(b'updated')
os.utime(ROOT / 'input' / 'tiny', (time.time() + 10, time.time() + 10))
run([ZIP, '-qu', 'update.zip', 'input/tiny'])
check('update', run([UNZIP, '-p', 'update.zip', 'input/tiny']) == b'updated')
run([ZIP, '-q', 'update.zip', 'input/text.txt'])
run([ZIP, '-qd', 'update.zip', 'input/tiny'])
with zipfile.ZipFile(ROOT / 'update.zip') as z:
    check('delete', z.namelist() == ['input/text.txt'])
run([ZIP, '-qr', 'excluded.zip', 'input', '-x', '*.bin'])
with zipfile.ZipFile(ROOT / 'excluded.zip') as z:
    check('exclude', not any((n.endswith('.bin') for n in z.namelist())))
z = run([ZIP, '-q', '-fz', '-', '-'], input=b'stdin data')
(ROOT / 'stream.zip').write_bytes(z)
check('stdin and stdout ZIP64', run([UNZIP, '-p', 'stream.zip', '-']) == b'stdin data')
check('ZIP64 record', b'PK\x06\x06' in z)
run([UNZIP, '--invalid'], status=10)
run([ZIP, '--invalid'], status=16)
run([UNZIP, 'missing.zip'], status=9)
run([UNZIP, '-qn', 'level-6.zip', '-d', 'extract-6'])
(ROOT / 'extract-6/input/tiny').write_bytes(b'keep')
run([UNZIP, '-qn', 'level-6.zip', '-d', 'extract-6'])
check('never overwrite', (ROOT / 'extract-6/input/tiny').read_bytes() == b'keep')
run([UNZIP, '-qo', 'level-6.zip', '-d', 'extract-6'])
check('overwrite', (ROOT / 'extract-6/input/tiny').read_bytes() == b'abc')
(ROOT / 'safe').mkdir()
(ROOT / 'outside').mkdir()
(ROOT / 'safe/link').symlink_to('../outside', target_is_directory=True)
with zipfile.ZipFile(ROOT / 'escape.zip', 'w') as z:
    z.writestr('link/escape.txt', b'escape')
p = invoke([UNZIP, '-o', 'escape.zip', '-d', 'safe'], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
check('reject symlink escape', p.returncode != 0 and (not (ROOT / 'outside/escape.txt').exists()))
with zipfile.ZipFile(ROOT / 'dotdot.zip', 'w') as z:
    z.writestr('../dotdot.txt', b'escape')
p = invoke([UNZIP, '-o', 'dotdot.zip', '-d', 'safe'], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
check('dotdot stays inside', not (ROOT / 'dotdot.txt').exists() and (ROOT / 'safe/dotdot.txt').read_bytes() == b'escape')
check('zipinfo listing', run([UNZIP, '-Z1', 'level-6.zip']) == run(['/usr/bin/unzip', '-Z1', 'level-6.zip']))
run([UNZIP, '-qo', 'level-6.zip', 'input/*.txt', '-d', 'selected'])
check('member filter', not (ROOT / 'selected/input/random.bin').exists() and (ROOT / 'selected/input/text.txt').exists())
with zipfile.ZipFile(ROOT / 'corrupt.zip', 'w', compression=zipfile.ZIP_STORED) as z:
    z.writestr('data', b'checksum payload')
a = bytearray((ROOT / 'corrupt.zip').read_bytes())
offset = a.index(b'checksum payload')
a[offset] ^= 1
(ROOT / 'corrupt.zip').write_bytes(a)
run([UNZIP, '-tqq', 'corrupt.zip'], status=2)
check('corrupt CRC reported', True)
(ROOT / 'truncated.zip').write_bytes(a[:20])
p = invoke([UNZIP, '-tqq', 'truncated.zip'], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
check('truncated archive reported', p.returncode != 0)
for command, expected, status in [
    ("printf 'pipeline bytes' | zip -q -fz - - | cat > pipeline.zip; unzip -p pipeline.zip -",
     b'pipeline bytes', 0),
    ('unzip -p level-6.zip input/tiny | zip -q -fz pipe.zip -; unzip -p pipe.zip -',
     b'abc', 0),
    ('unzip -p level-6.zip input/tiny | cat',
     b'abc', 0),
    ('set -o pipefail; unzip -p missing.zip | cat',
     b'', 9),
    ("ZIPOPT='-q -0' zip env-shell.zip input/tiny; UNZIPOPT=-p unzip env-shell.zip input/tiny",
     b'updated', 0),
    ('/usr/bin/zip -q virtual.zip input/tiny; /usr/bin/unzip -p virtual.zip input/tiny',
     b'updated', 0),
]:
    p = subprocess.run([runner, 'cd ' + shlex.quote(str(ROOT)) + ' && ' + command], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    check('pipeline ' + command, (p.returncode, p.stdout) == (status, expected))
# DOS attributes must use the kernel's mask; stored Unix modes must survive it.
permissions = {
    'writable': (0, 0x20, b'writable', 0o666, True),
    'readonly': (0, 0x21, b'readonly', 0o444, True),
    'directory/': (0, 0x10, b'', 0o777, True),
    'directory/child': (0, 0x20, b'child', 0o666, True),
    'readonly-directory/': (0, 0x11, b'', 0o555, True),
    'readonly-directory/child': (0, 0x20, b'child', 0o666, True),
    'unix-executable': (3, 0o100751 << 16, b'executable', 0o751, False),
    'unix-directory/': (3, (0o40750 << 16) | 0x10, b'', 0o750, False),
    'unix-directory/child': (3, 0o100640 << 16, b'child', 0o640, False),
}
with zipfile.ZipFile(ROOT / 'permissions.zip', 'w') as z:
    for name, (host, attributes, content, mode, masked) in permissions.items():
        entry = zipfile.ZipInfo(name)
        entry.create_system = host
        entry.external_attr = attributes
        z.writestr(entry, content)
for mask in (0o000, 0o022, 0o027, 0o077, 0o200):
    destination = ROOT / f'permissions-{mask:o}'
    destination.mkdir(mode=0o700)
    run([UNZIP, '-q', 'permissions.zip', '-d', str(destination)], umask=mask)
    for name, (host, attributes, content, mode, masked) in permissions.items():
        expected = mode & ~mask if masked else mode
        actual = (destination / name).stat().st_mode & 0o777
        check(f'permissions {mask:o} {name}: {actual:o} == {expected:o}', actual == expected)
        if not name.endswith('/'):
            check(f'permission fixture bytes {mask:o} {name}', (destination / name).read_bytes() == content)
    # Make read-only directories writable again for the test fixture's cleanup.
    for name in permissions:
        if name.endswith('/'):
            (destination / name).chmod(0o700)
for option in ('-TT', '--unzip-command'):
    p = invoke([ZIP, '-qT', option, 'echo', 'unsupported.zip', 'input/tiny'],
               cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    check(option + ' rejected before archive creation',
          p.returncode == 16 and b'not supported' in p.stdout + p.stderr and not (ROOT / 'unsupported.zip').exists())
report = {'root': str(ROOT), 'checks': len(checks), 'passed': checks}
(ROOT / 'validation.json').write_text(json.dumps(report, indent=2))
print(json.dumps({'root': str(ROOT), 'checks': len(checks)}))
