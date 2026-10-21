#!/usr/bin/env python3
"""Encapsulate the iOS SVP engine and verify its device link and public symbols."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

def run(*args):
    subprocess.run(list(map(str, args)), check=True)


def output(*args):
    return subprocess.check_output(list(map(str, args)), text=True).strip()


def main():
    vendor = Path(__file__).resolve().parent
    build = vendor / ".build/ios-arm64"
    core = vendor / ".build/ios-core"
    work = vendor / ".build/ios-encapsulation"
    destination = vendor / "Artifacts/ios-arm64"
    work.mkdir(parents=True, exist_ok=True)
    destination.mkdir(parents=True, exist_ok=True)
    config = (build / "config_host.mk").read_text()
    for key, value in [("OS", "iOS"), ("ENABLE_HEADLESS", "TRUE"),
                       ("DISABLE_DYNLOADING", "TRUE"), ("ENABLE_CUSTOMTARGET_COMPONENTS", "TRUE")]:
        assert re.search(rf"^export {key}={value}$", config, re.M), (key, value)
    assert output("git", "-C", core, "rev-parse", "HEAD") == "bce0998afefdbc355585ca324285661a2170ba77"
    sdk = output("xcrun", "--sdk", "iphoneos", "--show-sdk-path")
    sdk_version = output("xcrun", "--sdk", "iphoneos", "--show-sdk-version")
    compiler = ["xcrun", "--sdk", "iphoneos", "clang++", "-target", "arm64-apple-ios15.4",
                "-isysroot", sdk, "-std=c++17", "-O2", "-fvisibility=hidden", "-fvisibility-inlines-hidden"]
    command = work / "OfficeCommand.o"
    run(*compiler, "-I", core / "include", "-I", build / "workdir/UnpackedTarball/fontconfig", "-I", build / "workdir/UnpackedTarball/boost",
        "-c", vendor / "OfficeCommand.cpp", "-o", command)
    # Only target-side archives; host code generators live in workdir_for_build.
    # Darwin archive search pulls the closure referenced by OfficeCommandRun and
    # the generated static UNO component map. No whole-archive/ObjC loading.
    archives = sorted((build / "instdir/program").glob("*.a"))
    archives += sorted((build / "workdir/LinkTarget/Library").glob("*.a"))
    archives += sorted((build / "workdir/LinkTarget/StaticLibrary").glob("*.a"))
    for path in sorted((build / "workdir/UnpackedTarball").rglob("*.a")):
        if any(part in ("stubdata", "test", "tests", "instdir") for part in path.parts):
            continue
        archives.append(path)
    # Several external builds install identical archives in a second directory.
    seen, unique = set(), []
    for path in archives:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest not in seen:
            seen.add(digest)
            unique.append(path)
    assert len(unique) > 100
    for path in unique:
        commands = output("xcrun", "otool", "-l", path)
        platforms = set(re.findall(r"^\s+platform (\S+)$", commands, re.M))
        assert platforms <= {"2", "IOS"}, (path, platforms)
        assert "LC_VERSION_MIN_MACOSX" not in commands, path
    response = work / "inputs.txt"
    response.write_text("\n".join('"' + str(p) + '"' for p in [command, *unique]) + "\n")
    merged = work / "Office.o"
    exports = vendor / "exported_symbols.txt"
    linker = os.environ.get("OFFICE_LD_CLASSIC") or output("xcrun", "--find", "ld-classic")
    run(linker, "-r", "-d", "-arch", "arm64", "-syslibroot", sdk,
        "-platform_version", "ios", "15.4", sdk_version, "-u", "_OfficeCommandRun",
        "-exported_symbols_list", exports, "@" + str(response), "-o", merged)
    run("xcrun", "nmedit", "-s", exports, merged)
    library = destination / "libOffice.a"
    run("xcrun", "libtool", "-static", "-D", "-o", library, merged)
    run("xcrun", "strip", "-S", "-x", library)
    run("xcrun", "ranlib", "-D", library)
    symbols = output("xcrun", "nm", "-m", library)
    assert "(common)" not in symbols and " private external " not in symbols
    actual = sorted({line.split()[-1] for line in symbols.splitlines()
                     if " external " in line and "(undefined)" not in line})
    assert actual == ["_OfficeCommandRun"], actual
    assert "_NSApplicationLoad" not in symbols and "_OBJC_CLASS_$_NSWindow" not in symbols
    (destination / "exports.txt").write_text("\n".join(actual) + "\n")
    frameworks = ["CoreFoundation", "CoreGraphics", "CoreText", "Foundation", "ImageIO", "Security", "UIKit"]
    dylibs = ["c++", "iconv", "z"]
    flags = [flag for name in frameworks for flag in ("-framework", name)] + ["-l" + n for n in dylibs]
    # A real final device link catches unresolved C++/UNO/external references;
    # an archive-only build cannot establish that the integration will link.
    binary = work / "office-link-validation"
    run(*compiler, vendor / "office_main.cpp", library, *flags, "-Wl,-dead_strip", "-o", binary)
    load_commands = output("xcrun", "vtool", "-show-build", binary)
    assert "platform IOS" in load_commands and "minos 15.4" in load_commands
    assert "__compact_unwind" in output("xcrun", "otool", "-l", merged)
    assert "__unwind_info" in output("xcrun", "otool", "-l", binary)
    dependencies = output("xcrun", "otool", "-L", binary)
    assert all(s not in dependencies for s in ("AppKit", "Cocoa", "Carbon", "CoreUI", "libcairo"))
    resources = destination / "program/office"
    shutil.copytree(build / "instdir", resources, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("*.a", "*.dylib", "*.py", "*.sh"))
    # iOS LibreOfficeKit bootstraps from rc at its explicit installation path.
    (resources / "program/rc").write_text(
        "[Bootstrap]\nURE_BOOTSTRAP=${ORIGIN}/fundamentalrc\n"
        "UNO_TYPES=${ORIGIN}/types.rdb ${ORIGIN}/types/offapi.rdb\n"
        "UNO_SERVICES=${ORIGIN}/services.rdb ${ORIGIN}/services/services.rdb\n")
    (destination / "include").mkdir(exist_ok=True)
    shutil.copy2(vendor / "OfficeCommand.h", destination / "include/OfficeCommand.h")
    owned = [vendor / name for name in ("OfficeCommand.cpp", "OfficeCommand.h", "document-operations.hpp", "document-validation.hpp", "font-metadata.hpp", "font-operations.hpp", "render-operations.hpp")]
    licenses = destination / "licenses"
    licenses.mkdir(exist_ok=True)
    for name in ("COPYING", "COPYING.MPL", "COPYING.LGPL", "NOTICE"):
        if (core / name).exists():
            shutil.copy2(core / name, licenses / name)
    for name in ("LICENSE", "LICENSE.html", "NOTICE"):
        shutil.copy2(build / "instdir" / name, licenses / name)
    receipt = {"platform": "ios-arm64", "minimumOSVersion": "15.4", "backend": "svp",
               "sdkVersion": sdk_version,
               "coreRevision": output("git", "-C", core, "rev-parse", "HEAD"),
               "archiveBytes": library.stat().st_size,
               "archiveSHA256": hashlib.sha256(library.read_bytes()).hexdigest(),
               "exports": actual, "sdkFrameworks": frameworks, "sdkDylibs": dylibs,
               "archiveInputCount": len(unique), "inputPlatformsValidated": True,
               "compactUnwindPreserved": True, "linkedBinaryBytes": binary.stat().st_size,
               "programResourceBytes": sum(p.stat().st_size for p in resources.rglob("*") if p.is_file()),
               "patchSHA256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in (vendor / "Patches").glob("*.patch")},
               "corePatchSHA256": hashlib.sha256(subprocess.check_output(["git", "-C", str(core), "diff", "--binary"])).hexdigest(),
               "deviceLink": True, "deviceRuntime": False,
               "sourceSHA256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in owned}}
    (destination / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
