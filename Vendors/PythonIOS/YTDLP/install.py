#!/usr/bin/env python3
"""Install hash-pinned yt-dlp resources and the reviewed ios_system patch."""
import argparse
import base64
import csv
import io
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile
from pathlib import Path

# PYTHON_BUILD_INFO keys for the pinned wheels; versions come from resources.json.
BUILD_INFO_KEYS = {'yt_dlp': 'YTDLP_VERSION', 'yt_dlp_ejs': 'YTDLP_EJS_VERSION', 'mutagen': 'YTDLP_MUTAGEN_VERSION'}
FEATURE_POLICY = 'python-resources node=embedded ffmpeg=embedded subprocess=synchronous self-update=app-release'
# App Store review delists apps whose binary links to U.S.-embargoed territories, so
# these Iranian site extractors (module: class) and the nitter.ir instance are removed.
EMBARGOED_EXTRACTORS = {'aparat': 'AparatIE', 'presstv': 'PressTVIE',
                        'telewebion': 'TelewebionIE', 'varzesh3': 'Varzesh3IE'}
# Hosts on embargoed ccTLDs, including regex-escaped ones; new matches need review.
EMBARGOED_HOST = re.compile(rb'(?i)[a-z0-9-]+\\*\.(?:ir|cu|kp|sy)(?=[\'"/:|\\]|$)')


def remove_once(path, pattern):
    """Remove exactly one match so upstream drift fails like --fuzz=0."""
    source, count = re.subn(pattern, '', path.read_text(encoding='utf-8'), flags=re.M)
    if count != 1:
        raise ValueError(f'Expected one {pattern!r} in {path}')
    path.write_text(source, encoding='utf-8')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cache', type=Path, default=Path('/private/tmp/yt-dlp-resources'))
args = parser.parse_args()
vendor = Path(__file__).resolve().parents[1]
wheels = json.loads(Path(__file__).with_name('resources.json').read_text())
args.cache.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='yt-dlp-stage-') as temporary:
    stage = Path(temporary)
    for item in wheels:
        archive = args.cache / item['filename']
        if not archive.exists():
            with urllib.request.urlopen(item['url']) as response:
                archive.write_bytes(response.read())
        if hashlib.sha256(archive.read_bytes()).hexdigest() != item['sha256']:
            raise ValueError(f'Checksum mismatch: {archive}')
        with zipfile.ZipFile(archive) as wheel:
            wheel.extractall(stage)
    subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-i',
                    str(vendor / 'Patches/yt-dlp-ios-system.patch')], cwd=stage, check=True)
    extractor = stage / 'yt_dlp/extractor'
    lazy = extractor / 'lazy_extractors.py'
    for module, name in EMBARGOED_EXTRACTORS.items():
        (extractor / f'{module}.py').unlink()
        remove_once(extractor / '_extractors.py', rf'^from \.{module} import {name}\n')
        remove_once(lazy, rf'^class {name}\(LazyLoadExtractor\):\n(?:    .*\n)+\n\n')
        remove_once(lazy, rf"'{name}': {name}, ")
    remove_once(extractor / 'nitter.py', r"^        'nitter\.ir',\n")
    # The generated lazy NitterIE regex embeds the instance list.
    remove_once(lazy, re.escape(r'nitter\\.ir|'))
    for path in sorted(stage.rglob('*')):
        if path.is_file() and not path.relative_to(stage).parts[0].endswith('.data'):
            if host := EMBARGOED_HOST.search(path.read_bytes()):
                raise ValueError(f'Review embargoed host {host[0]!r} in {path.relative_to(stage)}')
    for record in stage.glob('*.dist-info/RECORD'):
        rows = [row for row in csv.reader(io.StringIO(record.read_text()))
                if not Path(row[0]).parts[0].endswith('.data') and (stage / row[0]).is_file()]
        for row in rows:
            path = stage / row[0]
            if path != record:
                data = path.read_bytes()
                row[1] = 'sha256=' + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip('=')
                row[2] = str(len(data))
        with record.open('w', newline='') as output:
            csv.writer(output, lineterminator='\n').writerows(rows)
    # Omit host manpages/completions/scripts; ios_system owns our CLI entry.
    for resources in ('Resources', 'ResourcesMacOS'):
        packages = vendor / resources / 'Library/lib/python3.14/site-packages'
        for metadata in stage.glob('*.dist-info'):
            name = metadata.name.rsplit('-', 1)[0]
            for previous in packages.glob(f'{name}-*.dist-info'):
                shutil.rmtree(previous)
        for source in sorted(stage.iterdir()):
            if source.name.endswith('.data'):
                continue
            target = packages / source.name
            if target.exists():
                shutil.rmtree(target) if target.is_dir() else target.unlink()
            shutil.copytree(source, target) if source.is_dir() else shutil.copyfile(source, target)
# Wheel filenames are {distribution}-{version}-...; record exactly what was installed.
build_info = [f'{BUILD_INFO_KEYS[name]}={version}'
              for name, version, *_ in (item['filename'].split('-') for item in wheels)]
build_info.append(f'YTDLP_FEATURE_POLICY={FEATURE_POLICY}')
Path(__file__).with_name('BUILD_INFO').write_text('\n'.join(build_info) + '\n')
