#!/usr/bin/env python3
"""Compile the production exporter in a minimal UIKit host for Catalyst verification."""
import pathlib
import platform
import plistlib
import subprocess

source = pathlib.Path(__file__).resolve().parent
repo = source.parents[2]
app = pathlib.Path('/tmp/HTML2VideoTest.app')
binary = app / 'Contents/MacOS/HTML2VideoTest'
binary.parent.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
subprocess.run([
    'xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-O',
    '-target', f'{platform.machine()}-apple-ios15.4-macabi', '-sdk', sdk,
    '-Fsystem', sdk + '/System/iOSSupport/System/Library/Frameworks',
    '-L', sdk + '/System/iOSSupport/usr/lib/swift',
    '-Xlinker', '-rpath', '-Xlinker', '/System/iOSSupport/usr/lib/swift',
    '-module-cache-path', '/tmp/HTML2VideoTest-module-cache',
    *map(str, sorted((repo / 'Libraries/HTMLVideoExporter/Sources').glob('*.swift'))),
    str(source / 'CatalystMain.swift'), '-o', str(binary),
], check=True)
with (app / 'Contents/Info.plist').open('wb') as output:
    plistlib.dump({
        'CFBundleName': 'HTML2VideoTest', 'CFBundleIdentifier': 'com.liuliu.html2video-test',
        'CFBundleExecutable': binary.name, 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'CFBundleSupportedPlatforms': ['MacOSX'], 'UIDeviceFamily': [2],
        'LSMinimumSystemVersion': '12.3',
        'UIApplicationSceneManifest': {'UIApplicationSupportsMultipleScenes': False},
    }, output)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
print(binary)
