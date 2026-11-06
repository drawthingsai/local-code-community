#!/usr/bin/env python3
"""Install the pinned, exported Mathlib package into the selected project."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
from urllib.request import Request, urlopen
import zipfile


LEAN_VERSION = "4.35.0"
LEAN_COMMIT = "eb6cafb7290e8bd5f2937522d8d804f58f02bafc"
MATHLIB_COMMIT = "56a005855ea17e0b0958f73ec801ae140b0a1679"
ARCHIVE = "Mathlib-4.35.0-56a005855ea1.zip"
URL = f"https://github.com/drawthingsai/mathlib4/releases/download/v4.35.0/{ARCHIVE}"
ARCHIVE_SHA256 = "76f9957c113ab1d133823ff96e91ed34f333da8764e3cd670488ea0929a360eb"
MANIFEST_SHA256 = "3b7b318c95f5a8704273ad4352717130e501b1f562f8a4a21f0df87f7aa154c5"
ARCHIVE_BYTES = 664778892


def checksum(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def contained_path(root, name):
    relative = PurePosixPath(name)
    if relative.is_absolute() or ".." in relative.parts or "\\" in name:
        raise ValueError(f"Invalid package path: {name}")
    path = root.joinpath(*relative.parts)
    path.resolve().relative_to(root.resolve())
    return path


def verify_install(destination):
    marker = destination / ".archive-sha256"
    if marker.read_text().strip() != ARCHIVE_SHA256:
        raise ValueError("Existing package has a different archive checksum")
    manifest_path = destination / "manifest.json"
    if checksum(manifest_path) != MANIFEST_SHA256:
        raise ValueError("Installed manifest does not match the pinned release")
    manifest = json.loads(manifest_path.read_text())
    if (manifest["leanVersion"], manifest["leanCommit"], manifest["mathlibCommit"]) != (
        LEAN_VERSION, LEAN_COMMIT, MATHLIB_COMMIT
    ) or manifest["moduleRoot"] != "lib/lean":
        raise ValueError("Package version does not match the embedded runtime")
    modules = manifest["modules"]
    if "Mathlib" not in modules or len(modules) != manifest["moduleCount"]:
        raise ValueError("Incomplete Mathlib manifest")
    for module in modules.values():
        for entry in module["files"]:
            path = contained_path(destination, entry["path"])
            if path.is_symlink() or path.stat().st_size != entry["size"] or checksum(path) != entry["sha256"]:
                raise ValueError(f"Corrupt installed artifact: {entry['path']}")
    if not (destination / "SmokeTest.lean").is_file():
        raise ValueError("Missing package smoke proof")


def install(project_root, lean_version):
    if lean_version != LEAN_VERSION:
        raise ValueError(f"This package requires Lean {LEAN_VERSION}; got {lean_version!r}")
    root = Path(project_root).resolve(strict=True)
    if not root.is_dir():
        raise ValueError("Project root must be an existing directory")
    destination = contained_path(root, f".localc/lean/packages/mathlib/{LEAN_VERSION}")
    if destination.exists():
        print("Verifying existing Mathlib installation...", flush=True)
        verify_install(destination)
        print(f"Already installed: {destination}", flush=True)
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(destination.parent).free < 3 * 2**30:
        raise ValueError("At least 3 GiB free space is required for download and extraction")

    # Only our new staging directory is removed on failure or cancellation.
    # Existing installations are never overwritten. No compressed copy is kept.
    with tempfile.TemporaryDirectory(prefix=".install-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        archive_path = staging / ARCHIVE
        print(f"Downloading {ARCHIVE} ({ARCHIVE_BYTES / 2**20:.0f} MiB)...", flush=True)
        request = Request(URL, headers={"User-Agent": "embedded-lean-mathlib-installer"})
        received = 0
        reported = 0
        with urlopen(request, timeout=60) as response, archive_path.open("xb") as output:
            while chunk := response.read(1024 * 1024):
                received += len(chunk)
                if received > ARCHIVE_BYTES:
                    raise ValueError("Download exceeds the pinned archive size")
                output.write(chunk)
                if received - reported >= 64 * 2**20:
                    print(f"Downloaded {received // 2**20} MiB...", flush=True)
                    reported = received
        if received != ARCHIVE_BYTES or checksum(archive_path) != ARCHIVE_SHA256:
            raise ValueError("Downloaded archive size or SHA-256 does not match the pinned release")
        print("Checksum verified; extracting Mathlib...", flush=True)
        unpacked = staging / "package"
        unpacked.mkdir()
        with zipfile.ZipFile(archive_path) as archive:
            seen = set()
            for entry in archive.infolist():
                name = entry.filename
                if name in seen or (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError(f"Duplicate or symlink archive entry: {name}")
                seen.add(name)
                path = contained_path(unpacked, name)
                if entry.is_dir():
                    path.mkdir(parents=True, exist_ok=True)
                    continue
                path.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as source, path.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
        (unpacked / ".archive-sha256").write_text(ARCHIVE_SHA256 + "\n")
        print("Verifying installed module hashes...", flush=True)
        verify_install(unpacked)
        unpacked.rename(destination)
    print(f"Installed: {destination}", flush=True)
    print("Temporary download and staging files removed; the ZIP can be downloaded again.", flush=True)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", required=True)
    parser.add_argument("--lean-version", required=True, help="Output of lean --short-version")
    args = parser.parse_args()
    try:
        install(args.project_root, args.lean_version)
        return 0
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"Mathlib installation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
