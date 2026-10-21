#!/usr/bin/env python3
"""Package a completed pinned SVP build into one private native archive (macOS arm64)."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


def output(*args):
    return subprocess.check_output(list(map(str, args)), text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kit', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    vendor = pathlib.Path(__file__).resolve().parent
    kit = args.kit.resolve(strict=True)
    build = kit / '.build/native-darwin-arm64'
    config = (build / 'config_host.mk').read_text()
    assert re.search(r'^export ENABLE_HEADLESS=TRUE$', config, re.M), 'SVP is required'
    assert re.search(r'^export DISABLE_DYNLOADING=TRUE$', config, re.M), 'Static engine is required'
    assert output('git', '-C', kit, 'rev-parse', 'HEAD') == 'b19bb73c74ed893b8a5d1716d32df32a113ed31b'
    assert output('git', '-C', kit / '.build/core', 'rev-parse', 'HEAD') == 'bce0998afefdbc355585ca324285661a2170ba77'
    destination = args.output.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    work = vendor / '.build/encapsulation'
    work.mkdir(parents=True, exist_ok=True)
    # The pinned engine's link map enumerates the complete closure of archives
    # and SDK dependencies. Replace its worker object with our owned C API; never
    # package upstream main, its Node protocol, or the diagnostic host.
    archives, sdk_libraries = [], []
    for line in (build / 'workdir/dsh-native-static.map').open(errors='replace'):
        if line.startswith('# Sections:'):
            break
        match = re.match(r'\[\s*\d+\] (/.+)', line)
        if not match:
            continue
        path = match[1].split('(')[0]
        if path.endswith('/libvclplug_osxlo.a'):
            continue  # SVP owns SalData; never include the Aqua plugin.
        if path.endswith('.a') and path not in archives:
            archives.append(path)
        elif path.endswith('.tbd') and path not in sdk_libraries:
            sdk_libraries.append(path)
        elif path.endswith('.o'):
            assert path.endswith('/desktop/source/app/dsh_native_worker.o'), path
    assert len(archives) > 100
    sdk = output('xcrun', '--sdk', 'macosx', '--show-sdk-path')
    sdk_version = output('xcrun', '--sdk', 'macosx', '--show-sdk-version')
    compiler = ['xcrun', '--sdk', 'macosx', 'clang++', '-arch', 'arm64', '-mmacosx-version-min=13.5',
                '-std=c++17', '-O2', '-fvisibility=hidden', '-fvisibility-inlines-hidden']
    command_object = work / 'OfficeCommand.o'
    run(*compiler, '-I', kit / '.build/core/include',
        '-I', build / 'workdir/UnpackedTarball/fontconfig', '-I', build / 'workdir/UnpackedTarball/boost', '-c', vendor / 'OfficeCommand.cpp', '-o', command_object)
    response = work / 'inputs.txt'
    response.write_text('\n'.join('"' + str(p) + '"' for p in [command_object, *archives]) + '\n')
    merged = work / 'Office.o'
    exports = vendor / 'exported_symbols.txt'
    linker = os.environ.get('OFFICE_LD_CLASSIC') or output('xcrun', '--sdk', 'macosx', '--find', 'ld-classic')
    run(linker, '-r', '-d', '-arch', 'arm64',
        '-syslibroot', sdk, '-platform_version', 'macos', '13.5', sdk_version,
        '-u', '_OfficeCommandRun', '-exported_symbols_list', exports,
        '@' + str(response), '-o', merged)
    run('xcrun', 'nmedit', '-s', exports, merged)
    library = destination / 'libOffice.a'
    run('xcrun', 'libtool', '-static', '-D', '-o', library, merged)
    run('xcrun', 'strip', '-S', '-x', library)
    run('xcrun', 'ranlib', '-D', library)
    symbols = output('xcrun', 'nm', '-m', library)
    assert '(common)' not in symbols and ' private external ' not in symbols
    assert '_NSApplicationLoad' not in symbols, 'The AppKit spellchecker must not enter the headless archive'
    actual = sorted({line.split()[-1] for line in symbols.splitlines()
                     if ' external ' in line and '(undefined)' not in line})
    assert actual == exports.read_text().splitlines(), actual
    (destination / 'exports.txt').write_text('\n'.join(actual) + '\n')
    # Keep SDK link requirements explicit and portable across Xcode SDK versions.
    frameworks, dylibs = set(), set()
    for path in sdk_libraries:
        if '/PrivateFrameworks/' in path or '/usr/lib/system/' in path:
            continue
        match = re.search(r'/([^/]+)\.framework/', path)
        if match:
            frameworks.add(match[1])
        else:
            dylibs.add(pathlib.Path(path).stem.removeprefix('lib'))
    link_flags = [flag for name in sorted(frameworks) for flag in ['-framework', name]]
    link_flags += ['-l' + name for name in sorted(dylibs)]
    # Ordinary standalone hosts link the same encapsulated archive as ios_system.
    (destination / 'bin').mkdir(exist_ok=True)
    for source, name in [('office_main.cpp', 'office'), ('Tests/probe_main.cpp', 'office-probe'), ('Tests/session_main.cpp', 'office-session')]:
        binary = destination / 'bin' / name
        run(*compiler, vendor / source, library, *link_flags, '-Wl,-dead_strip', '-o', binary)
        run('codesign', '--force', '--sign', '-', binary)
    package = kit / 'packages/darwin-arm64'
    for name in ['program', 'licenses']:
        shutil.copytree(package / name, destination / name, dirs_exist_ok=True)
    # Upstream's package allowlist misses the Calc RTL tab-bar layout.
    layout = 'LibreOfficeDev.app/Contents/Resources/config/soffice.cfg/svt/ui/tabbuttonsmirrored.ui'
    shutil.copy2(build / 'instdir' / layout, destination / 'program' / layout)
    # LOK takes Contents/Frameworks as its installation anchor even though all
    # code is static. Bundlers omit empty directories, so retain this one with
    # an ordinary resource file included by Bazel's structured-resources glob.
    anchor = destination / 'program/LibreOfficeDev.app/Contents/Frameworks'
    anchor.mkdir(parents=True, exist_ok=True)
    (anchor / 'static-runtime.txt').write_text(
        'LibreOfficeKit installation anchor. Native code is statically linked into the host.\n')
    (destination / 'include').mkdir(exist_ok=True)
    shutil.copy2(vendor / 'OfficeCommand.h', destination / 'include/OfficeCommand.h')
    owned_sources = ['OfficeCommand.cpp', 'OfficeCommand.h', 'document-operations.hpp', 'document-validation.hpp', 'font-metadata.hpp', 'font-operations.hpp', 'render-operations.hpp']
    receipt = {
        'kitRevision': output('git', '-C', kit, 'rev-parse', 'HEAD'),
        'coreRevision': output('git', '-C', kit / '.build/core', 'rev-parse', 'HEAD'),
        'platform': 'macos-arm64', 'minimumOSVersion': '13.5', 'backend': 'svp',
        'exports': actual, 'archiveBytes': library.stat().st_size,
        'archiveSHA256': hashlib.sha256(library.read_bytes()).hexdigest(),
        'sdkFrameworks': sorted(frameworks), 'sdkDylibs': sorted(dylibs),
        'patchSHA256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (vendor / 'Patches').glob('*.patch')},
        'corePatchSHA256': hashlib.sha256(subprocess.check_output(['git', '-C', str(kit / '.build/core'), 'diff', '--binary'])).hexdigest(),
        'sourceSHA256': {name: hashlib.sha256((vendor / name).read_bytes()).hexdigest()
                         for name in owned_sources},
    }
    (destination / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
