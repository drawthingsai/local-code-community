"""Prefetch exactly the configured make download plan with SHA-256 verification."""
import concurrent.futures
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.parse

build = pathlib.Path(sys.argv[1]).resolve()
plan = subprocess.check_output(["gmake", "-n", "download"], cwd=build, text=True)
tarballs = build.parent / "tarballs"
tarballs.mkdir(exist_ok=True)
jobs = []
for line in plan.splitlines():
    url = re.search(r"https://[^\s'\"]+", line)
    if not url:
        continue
    checksum = re.search(r'expected checksum for .*? is ([a-f0-9]{64})', line)
    if not checksum:
        raise RuntimeError("Download has no expected SHA-256")
    jobs.append((url.group(), checksum.group(1)))


def fetch(job):
    url, expected = job
    name = pathlib.PurePosixPath(urllib.parse.urlparse(url).path).name
    target = tarballs / name
    if target.exists():
        assert hashlib.file_digest(target.open("rb"), "sha256").hexdigest() == expected, name
        return name
    fd, temporary = tempfile.mkstemp(prefix="prefetch-", dir=tarballs)
    os.close(fd)
    try:
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                        "--retry", "3", "--connect-timeout", "30", "--max-time", "900",
                        "--output", temporary, url], check=True)
        with open(temporary, "rb") as source:
            actual = hashlib.file_digest(source, "sha256").hexdigest()
        if actual != expected:
            raise RuntimeError(f"SHA-256 mismatch: {name}")
        os.replace(temporary, target)
        print(f"Verified {name}", flush=True)
        return name
    finally:
        pathlib.Path(temporary).unlink(missing_ok=True)


with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    list(pool.map(fetch, jobs))
print(f"Verified {len(jobs)} configured downloads.", flush=True)
