#!/usr/bin/env python3
"""Exercise the built app's HyperFrames payload without checkout/runfiles fallback."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=Path, help='Native macOS hyperframes executable.')
parser.add_argument('app', type=Path, help='Built app bundle or IPA/ZIP archive.')
args = parser.parse_args()
binary = args.binary.resolve()
app = args.app.resolve()
source = Path(__file__).resolve().parents[1] / 'Resources/HyperFrames'
expected = {path.relative_to(source).as_posix(): path.read_bytes()
            for path in source.rglob('*') if path.is_file()}

if app.is_dir():
    candidates = [app / 'Contents/Resources/HyperFrames', app / 'HyperFrames']
    resources = next((path for path in candidates if (path / 'worker.cjs').is_file()), None)
    assert resources, f'Missing HyperFrames runtime in {app}'
    payload = {path.relative_to(resources).as_posix(): path.read_bytes()
               for path in resources.rglob('*') if path.is_file()}
else:
    with zipfile.ZipFile(app) as archive:
        workers = [name for name in archive.namelist() if name.endswith('/HyperFrames/worker.cjs')]
        assert len(workers) == 1, f'Expected one bundled HyperFrames runtime in {app}: {workers}'
        prefix = workers[0].removesuffix('worker.cjs')
        payload = {name[len(prefix):]: archive.read(name) for name in archive.namelist()
                   if name.startswith(prefix) and not name.endswith('/')}
assert payload == expected, f'Bundled HyperFrames payload differs from source: {app}'
print(f'PASS packaged runtime: {len(payload)} files match source', flush=True)

with tempfile.TemporaryDirectory(prefix='hyperframes-bundle-') as temporary:
    root = Path(temporary)
    bundle = root / 'HyperFramesTest.app'
    executable = bundle / 'Contents/MacOS/hyperframes'
    executable.parent.mkdir(parents=True)
    # Copy, rather than symlink: resourcesURL resolves executable ancestors.
    shutil.copy2(binary, executable)
    with (bundle / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleExecutable': 'hyperframes', 'CFBundlePackageType': 'APPL',
                      'CFBundleIdentifier': 'com.liuliu.hyperframes-bundle-test'}, stream)
    environment = {key: value for key, value in os.environ.items()
                   if key not in ('BUILD_WORKSPACE_DIRECTORY', 'TEST_SRCDIR', 'TEST_WORKSPACE')}

    def run(*arguments, status=0):
        result = subprocess.run([str(executable), *map(str, arguments)], cwd=root,
                                env=environment, capture_output=True, text=True, timeout=60)
        assert result.returncode == status, (arguments, result.returncode, result.stdout, result.stderr)
        return result

    # A diagnostic version must work even when the runtime payload is absent.
    version = run('--version')
    assert version.stdout == '0.8.78\n', version
    assert 'Missing bundled runtime' in run('--help', status=1).stderr
    resources = bundle / 'Contents/Resources/HyperFrames'
    for name, data in payload.items():
        target = resources / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    assert '--version' in run('--help').stdout
    project = root / 'movie'
    run('init', project, '--non-interactive')
    assert json.loads(run('lint', project, '--json').stdout)['ok']
    capture = json.loads(run('snapshot', project, '--at', '1', '--zoom', '0,0,64,64',
                             '--zoom-scale', '1', '--json').stdout)
    image = (project / capture['files'][0]).read_bytes()
    assert image[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', image[16:24]) == (64, 64)
    print('PASS isolated app: version without resources; bundled help, init, lint, snapshot', flush=True)
