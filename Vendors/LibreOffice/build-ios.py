#!/usr/bin/env python3
"""Build the pinned iOS arm64 SVP engine, with private static font dependencies."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

KIT_REVISION = "b19bb73c74ed893b8a5d1716d32df32a113ed31b"
CORE_REVISION = "bce0998afefdbc355585ca324285661a2170ba77"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit", type=Path, required=True, help="Pinned dsh kit with .build/core prepared")
    parser.add_argument("--configure-only", action="store_true")
    args = parser.parse_args()
    vendor = Path(__file__).resolve().parent
    kit = args.kit.resolve(strict=True)
    core = vendor / ".build/ios-core"
    build = vendor / ".build/ios-arm64"
    tarballs = vendor / ".build/tarballs"
    jobs = int(os.environ.get("OFFICE_BUILD_JOBS", "12"))
    assert jobs > 0
    os.environ["PATH"] = "/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:" + os.environ["PATH"]
    os.environ.update(MAKE="gmake", CFLAGS="-O2", CXXFLAGS="-O2")

    def run(*command, cwd=None):
        subprocess.run(list(map(str, command)), cwd=cwd, check=True)

    def revision(path):
        return subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()

    assert revision(kit) == KIT_REVISION
    assert revision(kit / ".build/core") == CORE_REVISION
    patches = sorted(p for p in (kit / "engine/native/patches").glob("*.patch") if p.name < "0090")
    patches += [vendor / "Patches" / name for name in (
        "headless-static.patch", "headless-fonts.patch", "headless-factory.patch",
        "headless-spellcheck.patch", "headless-font-refresh.patch", "ios-svp.patch")]
    identity = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in patches}
    stamp = core / ".office-patches.json"
    if not core.exists():
        run("git", "clone", "--local", kit / ".build/core", core)
        for patch in patches:
            run("git", "apply", patch, cwd=core)
        stamp.write_text(json.dumps({"patches": identity, "sourceDiffSHA256": hashlib.sha256(
            subprocess.check_output(["git", "diff", "--binary"], cwd=core)).hexdigest()}, indent=2) + "\n")
    assert revision(core) == CORE_REVISION
    expected = {"patches": identity, "sourceDiffSHA256": hashlib.sha256(
        subprocess.check_output(["git", "diff", "--binary"], cwd=core)).hexdigest()}
    if not stamp.exists() or json.loads(stamp.read_text()) != expected:
        raise RuntimeError("iOS checkout patch receipt differs; use a fresh ios-core checkout")
    build.mkdir(parents=True, exist_ok=True)
    if not tarballs.exists():
        tarballs.symlink_to((kit / ".build/tarballs").resolve(strict=True), target_is_directory=True)
    flags = [line for line in (vendor / "ios.conf").read_text().splitlines()
             if line and not line.startswith("#")]
    flags += ["--with-external-tar=" + str(tarballs.resolve()), "--with-parallelism=" + str(jobs)]
    configure_input = "\n".join(flags) + "\n"
    if (build / "config_host.mk").exists():
        if set((build / "autogen.input").read_text().splitlines()) != set(flags):
            raise RuntimeError("Configured iOS flags differ; use a fresh ios-arm64 build directory")
    else:
        (build / "autogen.input").write_text(configure_input)
        run("sh", core / "autogen.sh", cwd=build)
    if args.configure_only:
        return
    run("python3", vendor / "prefetch.py", build)
    run("gmake", f"-j{jobs}", "cross-toolset", cwd=build)
    # The upstream ios target stages a GUI app with galleries/dictionaries that
    # this conversion-only build intentionally omits. Package resources ourselves.
    os.environ["BUILDDIR"] = str(build)
    run("gmake", f"-sj{jobs}", "-f", core / "Makefile.gbuild", "build", cwd=build)


if __name__ == "__main__":
    main()
