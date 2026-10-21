"""Exercise native libgit2 LFS filters and transfers against a local Batch API."""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

binary = str(Path(sys.argv[1]).resolve())
objects = {}
verified = []
requests = []
corrupt = False
reject_upload = False
expected_auth = None


class Server(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if expected_auth:
            assert self.headers.get("Authorization") == expected_auth
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/verify":
            oid = request["oid"]
            assert self.headers.get("X-LFS-Action") == "verify-secret"
            assert hashlib.sha256(objects[oid]).hexdigest() == oid
            assert len(objects[oid]) == request["size"]
            verified.append(oid)
            self.send(200)
            return
        assert self.path == "/repo.git/info/lfs/objects/batch", self.path
        assert self.headers["Content-Type"] == "application/vnd.git-lfs+json"
        assert request["transfers"] == ["basic"]
        assert request["hash_algo"] == "sha256"
        operation = request["operation"]
        requests.append(operation)
        entries = []
        for pointer in request["objects"]:
            entry = dict(pointer)
            oid = pointer["oid"]
            if operation == "upload":
                if reject_upload:
                    entry["error"] = {"code": 403, "message": "denied"}
                elif oid not in objects:
                    entry["actions"] = {
                        "upload": {"href": base + "/object/" + oid,
                                   "header": {"X-LFS-Action": "upload-secret"}},
                        "verify": {"href": base + "/verify",
                                   "header": {"X-LFS-Action": "verify-secret"}},
                    }
            elif oid in objects:
                entry["actions"] = {"download": {"href": base + "/object/" + oid,
                                                "header": {"X-LFS-Action": "download-secret"}}}
            else:
                entry["error"] = {"code": 404, "message": "missing"}
            entries.append(entry)
        self.send(200, json.dumps({"transfer": "basic", "objects": entries}).encode())

    def do_PUT(self):
        if expected_auth:
            assert self.headers.get("Authorization") == expected_auth
        assert self.headers.get("X-LFS-Action") == "upload-secret"
        data = self.rfile.read(int(self.headers["Content-Length"]))
        oid = self.path.rsplit("/", 1)[-1]
        assert hashlib.sha256(data).hexdigest() == oid
        objects[oid] = data
        self.send(200)

    def do_GET(self):
        if expected_auth:
            assert self.headers.get("Authorization") == expected_auth
        assert self.headers.get("X-LFS-Action") == "download-secret"
        data = objects[self.path.rsplit("/", 1)[-1]]
        self.send(200, b"corrupt" if corrupt else data, "application/octet-stream")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Server)
base = f"http://127.0.0.1:{server.server_port}"
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()

with tempfile.TemporaryDirectory(prefix="git-lfs-", dir=os.environ.get("TEST_TMPDIR")) as directory:
    root = Path(directory)
    repo = root / "repo"
    repo.mkdir()

    def git(*args, cwd=repo):
        return subprocess.check_output(["/usr/bin/git", "-C", str(cwd), *args], stderr=subprocess.PIPE)

    def native(*args, cwd=repo, ok=True, env=None):
        result = subprocess.run([binary, str(cwd), *args], capture_output=True, timeout=30,
                                env={**os.environ, **(env or {})})
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result

    git("init", "-b", "main")
    git("config", "user.name", "LFS Tests")
    git("config", "user.email", "lfs@example.invalid")
    git("remote", "add", "origin", base + "/repo.git")
    (repo / ".lfsconfig").write_text(f"[lfs]\n    url = {base}/repo.git/info/lfs\n")
    native("lfs", "version")
    native("lfs", "install")
    native("lfs", "track", "*.bin", "with space.dat")
    attrs = (repo / ".gitattributes").read_bytes()
    native("lfs", "track", "*.bin")
    assert (repo / ".gitattributes").read_bytes() == attrs
    native("lfs", "track", "bad\npattern", ok=False)
    data = bytes(range(256)) * 1024
    oid = hashlib.sha256(data).hexdigest()
    (repo / "model.bin").write_bytes(data)
    (repo / "with space.dat").write_bytes(data)
    native("add", ".gitattributes", ".lfsconfig", "model.bin", "with space.dat")
    pointer = git("show", ":model.bin")
    assert pointer == f"version https://git-lfs.github.com/spec/v1\noid sha256:{oid}\nsize {len(data)}\n".encode(), pointer[:200]
    assert git("show", ":with space.dat") == pointer
    cache = repo / ".git/lfs/objects" / oid[:2] / oid[2:4] / oid
    assert cache.read_bytes() == data
    git("commit", "-m", "LFS initial")
    assert native("status").stdout == b"0\n"
    native("push")
    assert objects[oid] == data and verified == [oid]
    assert requests.count("upload") == 1, "Duplicate content should upload only once"
    native("push")  # Already-present upload response needs no action.
    assert verified == [oid]
    assert oid.encode() in native("lfs", "ls-files").stdout

    # Check all history, including an object no longer in the current tree.
    later = b"replacement model"
    later_oid = hashlib.sha256(later).hexdigest()
    (repo / "model.bin").write_bytes(later)
    native("add", "model.bin")
    git("rm", "-f", "with space.dat")
    git("commit", "-m", "LFS replacement")
    reject_upload = True
    native("push", ok=False)
    assert later_oid not in objects
    reject_upload = False
    native("lfs", "push", "origin", "HEAD")
    assert objects[later_oid] == later
    later_pointer = git("show", "HEAD:model.bin")
    later_cache = repo / ".git/lfs/objects" / later_oid[:2] / later_oid[2:4] / later_oid
    later_cache.unlink()
    native("lfs", "fetch")
    assert later_cache.read_bytes() == later

    # Explicit pull hydrates only the exact indexed pointer and preserves edits.
    (repo / "model.bin").write_bytes(later_pointer)
    native("lfs", "checkout")
    assert (repo / "model.bin").read_bytes() == later
    (repo / "model.bin").write_bytes(b"user edit")
    native("lfs", "pull")
    assert (repo / "model.bin").read_bytes() == b"user edit"
    (repo / "model.bin").write_bytes(later_pointer)
    later_cache.unlink()
    corrupt = True
    native("lfs", "pull", ok=False)
    assert not later_cache.exists()
    assert (repo / "model.bin").read_bytes() == later_pointer
    assert not list(later_cache.parent.glob("*.tmp"))
    corrupt = False
    native("lfs", "pull")
    assert (repo / "model.bin").read_bytes() == later

    # Native smudge during checkout, and the standard skip-smudge environment.
    (repo / "model.bin").unlink()
    native("checkout-head", env={"GIT_LFS_SKIP_SMUDGE": "1"})
    assert (repo / "model.bin").read_bytes() == later_pointer
    (repo / "model.bin").unlink()
    native("checkout-head")
    assert (repo / "model.bin").read_bytes() == later
    assert native("status").stdout == b"0\n"
    native("lfs", "fetch", env={"LFS_TEST_CANCELLED": "1"}, ok=False)
    native("lfs", "push", "origin", "--all", ok=False)
    native("lfs", "unsupported", ok=False)
    clone = root / "clone"
    native("clone", str(repo), str(clone))
    assert (clone / "model.bin").read_bytes() == later
    assert native("status", cwd=clone).stdout == b"0\n"
    # Existing Git credentials cover both batch and same-origin action requests.
    git("config", "user.name", "lfs-user")
    git("config", "user.password", "test-token")
    expected_auth = "Basic " + base64.b64encode(b"lfs-user:test-token").decode()
    later_cache.unlink()
    native("lfs", "fetch")
    native("push")
    expected_auth = None
    # A malformed pointer must not be silently staged as an ordinary blob.
    (repo / "broken.bin").write_bytes(b"version https://git-lfs.github.com/spec/v1\next-test bad\n")
    native("add", "broken.bin", ok=False)

    print("Git LFS: tracking, clean/smudge, upload/verify, history, fetch/checkout/pull, corruption and cancellation passed.")

server.shutdown()
thread.join()
