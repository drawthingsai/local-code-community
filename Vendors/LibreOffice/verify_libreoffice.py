#!/usr/bin/env python3
"""Verify Office provenance, payload integrity, static linkage and public symbols."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record-checksums", action="store_true", help="Record a reviewed rebuild before verifying")
    args = parser.parse_args()
    # Do not resolve symlinks: Bazel exposes the vendor files in a runfiles tree.
    vendor = Path(__file__).absolute().parent
    files = [p for p in vendor.iterdir() if p.is_file() and
             (p.suffix in (".py", ".sh", ".cpp", ".h", ".hpp", ".m", ".conf", ".md", ".txt", ".dsh")
              or p.name in ("BUILD", ".gitignore", "LIBREOFFICE_BUILD_INFO"))]
    for name in ("Frameworks", "Resources", "ResourcesMacOS", "Patches", "Tests", "Receipts", "Notices"):
        files += [p for p in (vendor / name).rglob("*") if p.is_file() and "__pycache__" not in p.parts]
    files.sort()
    lines = []
    for path in files:
        with path.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        lines.append(f"{digest}  {path.relative_to(vendor).as_posix()}\n")
    contents = "".join(lines)
    manifest = vendor / "SHA256SUMS"
    if args.record_checksums:
        manifest.write_text(contents)
    assert manifest.read_text() == contents, "Vendor checksums differ; fetch LFS files or review the rebuild"
    metadata = dict(line.split("=", 1) for line in (vendor / "LIBREOFFICE_BUILD_INFO").read_text().splitlines())
    assert metadata["LIBREOFFICE_LINKAGE"] == "static" and metadata["LIBREOFFICE_BACKEND"] == "svp"
    framework = vendor / "Frameworks/Office.xcframework"
    slices = plistlib.loads((framework / "Info.plist").read_bytes())["AvailableLibraries"]
    assert {s["LibraryIdentifier"] for s in slices} == {"ios-arm64", "macos-arm64"}
    for item in slices:
        platform = item["LibraryIdentifier"]
        assert item["SupportedArchitectures"] == ["arm64"] and "SupportedPlatformVariant" not in item
        assert item["SupportedPlatform"] == ("ios" if platform == "ios-arm64" else "macos")
        library = framework / platform / item["LibraryPath"]
        with library.open("rb") as source:
            assert source.read(8) == b"!<arch>\n", f"Not a static archive: {library}"
        assert (framework / platform / item["HeadersPath"] / "OfficeCommand.h").read_bytes() == (vendor / "OfficeCommand.h").read_bytes()
        symbols = subprocess.check_output(["xcrun", "nm", "-m", str(library)], text=True)
        exports = sorted({line.split()[-1] for line in symbols.splitlines()
                          if " external " in line and "(undefined)" not in line})
        assert exports == (vendor / "exported_symbols.txt").read_text().splitlines() == ["_OfficeCommandRun"]
        commands = subprocess.check_output(["xcrun", "otool", "-l", str(library)], text=True)
        platforms = set(re.findall(r"^\s+platform (\S+)$", commands, re.M))
        assert platforms and platforms <= ({"2", "IOS"} if platform == "ios-arm64" else {"1", "MACOS"})
        assert "__compact_unwind" in commands
        resources = vendor / ("Resources" if platform == "ios-arm64" else "ResourcesMacOS")
        receipt = json.loads((vendor / "Receipts" / (platform + ".json")).read_text())
        assert receipt["coreRevision"] == metadata["LIBREOFFICE_SOURCE_COMMIT"]
        with library.open("rb") as source:
            assert hashlib.file_digest(source, "sha256").hexdigest() == receipt["archiveSHA256"]
        for name, expected in receipt["sourceSHA256"].items():
            path = vendor / name
            assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, path
        for patch in (vendor / "Patches").glob("*.patch"):
            assert hashlib.sha256(patch.read_bytes()).hexdigest() == receipt["patchSHA256"][patch.name], patch
        program = resources / ("office/program" if platform == "ios-arm64" else "office/Resources")
        assert (program / "fundamentalrc").is_file()
        assert {p.name for p in resources.iterdir()} == {"office"}
        assert sum(p.stat().st_size for p in resources.rglob("*") if p.is_file()) == receipt["packagedResourceBytes"]
        for path in resources.rglob("*"):
            assert path.name not in ("Info.plist", "PkgInfo", "CREDITS.fodt", "MainMenu.nib"), path
            assert path.suffix not in (".app", ".cpp", ".cxx", ".py", ".sh", ".md", ".patch"), path
        data = resources / ("office/share" if platform == "ios-arm64" else "office/Resources")
        for name in ("config/wizard", "gallery", "basic", "tipoftheday", "toolbarmode", "wizards"):
            assert not (data / name).exists(), data / name
        assert (vendor / "Notices/LibreOffice/SourceNotice.txt").is_file()
        print(f"Verified {platform}: static archive, private symbols, compact unwind, resources and source receipts")
    print(f"Verified {len(files)} vendored files")


if __name__ == "__main__":
    main()
