#!/usr/bin/env python3
"""Build a standalone, sandboxed Mac Catalyst folder-picker experiment."""

import argparse
import platform
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, default=Path("/tmp/CatalystFolderPickerProbe.app"))
parser.add_argument("--dismiss-after", type=float, help="Dismiss the shared picker after N seconds")
parser.add_argument(
    "--directory", type=Path,
    default=Path.home() / "Library/Containers/com.liuliu.draw-things/Data/Documents/Models",
)
args = parser.parse_args()
source = Path(__file__).resolve().parent
repository = source.parents[3]
app = args.output.expanduser().resolve()
contents = app / "Contents"
executable = contents / "MacOS/CatalystFolderPickerProbe"
executable.parent.mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
sdk = Path(subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
architecture = platform.machine()
if architecture not in ("arm64", "x86_64"):
    raise SystemExit(f"Unsupported architecture: {architecture}")
build_directory = app.parent / "CatalystFolderPickerProbe-build"
build_directory.mkdir(exist_ok=True)
target = f"{architecture}-apple-ios15.4-macabi"
exception_catcher = repository / "Vendors/ExceptionCatcher/Sources"
internal_module = build_directory / "Internal"
internal_module.mkdir(exist_ok=True)
(internal_module / "module.modulemap").write_text(
    f'module Internal {{ header "{exception_catcher}/Internal/include/ExceptionCatcher.h" export * }}\n'
)
subprocess.run([
    "xcrun", "clang", "-target", target, "-isysroot", str(sdk), "-fobjc-arc",
    "-I", str(exception_catcher / "Internal/include"),
    "-c", str(exception_catcher / "Internal/ExceptionCatcher.m"),
    "-o", str(build_directory / "ExceptionCatcherInternal.o"),
], check=True)
subprocess.run([
    "xcrun", "swiftc", "-parse-as-library", "-target", target, "-sdk", str(sdk),
    "-I", str(internal_module), "-module-name", "ExceptionCatcher",
    "-module-cache-path", str(build_directory / "ModuleCache"),
    "-emit-module", "-emit-module-path", str(build_directory / "ExceptionCatcher.swiftmodule"),
    "-emit-object", str(exception_catcher / "ExceptionCatcher/ExceptionCatcher.swift"),
    "-o", str(build_directory / "ExceptionCatcher.o"),
], check=True)
subprocess.run([
    "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-O",
    "-target", target, "-sdk", str(sdk),
    "-Fsystem", str(sdk / "System/iOSSupport/System/Library/Frameworks"),
    "-L", str(sdk / "System/iOSSupport/usr/lib/swift"),
    "-framework", "UIKit", "-framework", "Foundation",
    "-Xlinker", "-rpath", "-Xlinker", "/System/iOSSupport/usr/lib/swift",
    "-I", str(build_directory), "-I", str(internal_module),
    "-module-cache-path", str(build_directory / "ModuleCache"),
    "-module-name", "CatalystFolderPickerProbe",
    str(source / "Probe.swift"), str(repository / "Libraries/Components/Sources/UnifiedDocumentPickerController.swift"),
    str(build_directory / "ExceptionCatcher.o"), str(build_directory / "ExceptionCatcherInternal.o"),
    "-o", str(executable),
], check=True)
info = {
    "CFBundleName": "Catalyst Folder Picker Probe",
    "CFBundleDisplayName": "Catalyst Folder Picker Probe",
    "CFBundleIdentifier": "com.liuliu.local-code.catalyst-folder-picker-probe",
    "CFBundleExecutable": executable.name,
    "CFBundlePackageType": "APPL",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "CFBundleSupportedPlatforms": ["MacOSX"],
    "LSMinimumSystemVersion": "12.3",
    "UIDeviceFamily": [2],
    "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
    "ProbeInitialDirectory": str(args.directory.expanduser().resolve()),
}
if args.dismiss_after is not None:
    info["ProbeDismissAfter"] = args.dismiss_after
with (contents / "Info.plist").open("wb") as output:
    plistlib.dump(info, output)
entitlements = build_directory / "Probe.entitlements"
with entitlements.open("wb") as output:
    plistlib.dump({
        "com.apple.security.app-sandbox": True,
        "com.apple.security.files.user-selected.read-write": True,
        "com.apple.security.files.bookmarks.app-scope": True,
    }, output)
subprocess.run([
    "codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app),
], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
print(app)
