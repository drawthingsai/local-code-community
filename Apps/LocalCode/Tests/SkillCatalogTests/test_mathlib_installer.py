import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


SCRIPT = Path(__file__).resolve().parents[2] / "Resources/Skills/check_lean-and-lean-tools/scripts/install_mathlib.py"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("install_mathlib", SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class MathlibInstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        files = []
        entries = {}
        for suffix in (".olean", ".ir", ".ir.sig"):
            name = f"lib/lean/Mathlib{suffix}"
            data = f"fixture {suffix}".encode()
            entries[name] = data
            files.append({"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        manifest = {
            "leanVersion": installer.LEAN_VERSION,
            "leanCommit": installer.LEAN_COMMIT,
            "mathlibCommit": installer.MATHLIB_COMMIT,
            "moduleRoot": "lib/lean", "moduleCount": 1,
            "modules": {"Mathlib": {"files": files}},
        }
        entries["manifest.json"] = json.dumps(manifest).encode()
        entries["SmokeTest.lean"] = b"theorem fixture : True := True.intro\n"
        self.entries = entries
        self.archive = self.make_archive(entries)
        self.addCleanup(patch.stopall)
        self.pin(self.archive)
        patch.object(installer, "MANIFEST_SHA256", hashlib.sha256(entries["manifest.json"]).hexdigest()).start()
        patch.object(installer.shutil, "disk_usage", return_value=type("Usage", (), {"free": 4 * 2**30})()).start()
        self.download = patch.object(installer, "urlopen", side_effect=lambda *a, **k: io.BytesIO(self.archive)).start()
        self.destination = self.root / f".localc/lean/packages/mathlib/{installer.LEAN_VERSION}"

    @staticmethod
    def make_archive(entries):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            for name, data in entries.items():
                archive.writestr(name, data)
        return stream.getvalue()

    def pin(self, archive):
        patch.object(installer, "ARCHIVE_BYTES", len(archive)).start()
        patch.object(installer, "ARCHIVE_SHA256", hashlib.sha256(archive).hexdigest()).start()

    def install(self):
        return installer.install(self.root, installer.LEAN_VERSION)

    def test_install_and_verified_reuse_without_download(self):
        self.assertEqual(self.install(), self.destination)
        self.download.assert_called_once()
        self.download.reset_mock()
        self.assertEqual(self.install(), self.destination)
        self.download.assert_not_called()
        self.assertEqual(list(self.destination.parent.iterdir()), [self.destination])

    def test_version_mismatch_does_not_create_or_download(self):
        with self.assertRaisesRegex(ValueError, "requires Lean"):
            installer.install(self.root, "4.33.1")
        self.download.assert_not_called()
        self.assertFalse((self.root / ".localc").exists())

    def test_checksum_mismatch_never_installs(self):
        self.archive = bytes([self.archive[0] ^ 1]) + self.archive[1:]
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.install()
        self.assertEqual(list(self.destination.parent.iterdir()), [])

    def test_corrupt_existing_install_is_not_overwritten(self):
        self.install()
        artifact = self.destination / "lib/lean/Mathlib.olean"
        artifact.write_bytes(b"user change")
        self.download.reset_mock()
        with self.assertRaisesRegex(ValueError, "Corrupt installed"):
            self.install()
        self.assertEqual(artifact.read_bytes(), b"user change")
        self.download.assert_not_called()

    def test_changed_manifest_is_rejected(self):
        self.install()
        manifest = self.destination / "manifest.json"
        manifest.write_text("{}")
        with self.assertRaisesRegex(ValueError, "manifest does not match"):
            self.install()

    def test_existing_directory_is_preserved(self):
        self.destination.mkdir(parents=True)
        marker = self.destination / "user.txt"
        marker.write_text("keep")
        with self.assertRaises(OSError):
            self.install()
        self.assertEqual(marker.read_text(), "keep")
        self.download.assert_not_called()

    def test_path_traversal_is_rejected(self):
        for name in ("../escape", "/escape", "lib/../../escape", "lib\\escape"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                installer.contained_path(self.root, name)

    def test_symlink_outside_project_is_rejected(self):
        with tempfile.TemporaryDirectory() as outside:
            (self.root / ".localc").symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError):
                self.install()
            self.assertEqual(list(Path(outside).iterdir()), [])

    def test_bad_archive_path_never_escapes_staging(self):
        self.archive = self.make_archive({**self.entries, "../../escape": b"bad"})
        self.pin(self.archive)
        with self.assertRaisesRegex(ValueError, "Invalid package path"):
            self.install()
        self.assertEqual(list(self.destination.parent.iterdir()), [])

    def test_interrupted_download_cleans_staging(self):
        self.download.side_effect = OSError("network unavailable")
        with self.assertRaisesRegex(OSError, "network unavailable"):
            self.install()
        self.assertEqual(list(self.destination.parent.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
