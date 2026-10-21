"""Validate the embedded diff frontend against BSD output and patch semantics."""
import os
from pathlib import Path
import random
import shlex
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
checks = 0

with tempfile.TemporaryDirectory(prefix="native-diff-", dir=os.environ.get("TEST_TMPDIR")) as directory:
    root = Path(directory)
    left, right = root / "left", root / "right"

    def embedded(options):
        command = shlex.join(["diff", *options, str(left), str(right)])
        result = subprocess.run([binary, command], capture_output=True, timeout=30)
        assert result.returncode in (0, 1, 2), result.stderr.decode(errors="replace")
        return result

    formats = [[], ["-u"], ["-u0"], ["-C", "2"], ["-e"], ["-f"], ["-n"],
               ["-D", "FEATURE"], ["-q"], ["-b"], ["-w"], ["-i"], ["-B"],
               ["--strip-trailing-cr"], ["-t"]]
    pairs = [(b"one\n", b"two\n"), (b"", b"new\n"), (b"old\n", b""),
             (b"a\nb\nc\n", b"d\n"), (b"a\tb\n", b"a  b\n"),
             (b"A\n", b"a\n"), (b"a\r\n", b"a\n"),
             (b"a\nb\n", b"a\n\nb\n"), (b"a\n", b".\nx\n.\n")]
    for old, new in pairs:
        left.write_bytes(old)
        right.write_bytes(new)
        for options in formats:
            options = [*options, "-L", "left", "-L", "right"]
            actual = embedded(options)
            expected = subprocess.run(["/usr/bin/diff", *options, str(left), str(right)],
                                      capture_output=True, timeout=30)
            assert (actual.returncode, actual.stdout) == (expected.returncode, expected.stdout), (
                options, old, new, actual.returncode, actual.stdout, expected.stdout)
            checks += 1

    left.write_bytes(b"before")
    right.write_bytes(b"after")
    options = ["-c", "-L", "left", "-L", "right"]
    actual = embedded(options)
    expected = subprocess.run(["/usr/bin/diff", *options, str(left), str(right)], capture_output=True)
    assert (actual.returncode, actual.stdout) == (expected.returncode, expected.stdout)
    checks += 1

    # Repeated lines allow multiple correct diffs: apply each generated patch
    # instead of requiring xdiff and BSD to pick identical change boundaries.
    randomizer = random.Random(7492)
    for case in range(20):
        old = [f"line {index % 7}\n".encode() for index in range(30)]
        new = old.copy()
        for edit in range(5):
            index = randomizer.randrange(len(new) + 1)
            new[index:index + randomizer.randrange(3)] = [
                f"insert {case} {edit}\n".encode() for _ in range(randomizer.randrange(3))]
        if case % 3 == 0:
            old[-1] = old[-1].rstrip(b"\n")
        if case % 4 == 0:
            new[-1] = new[-1].rstrip(b"\n")
        for options in (["-u"], ["-C", "2"]):
            old_data, new_data = b"".join(old), b"".join(new)
            # macOS patch rejects even BSD-generated context patches in some
            # missing-final-newline cases. Exercise those through unified
            # round trips and compare context output directly below.
            if options[0] == "-C":
                old_data = old_data.rstrip(b"\n") + b"\n"
                new_data = new_data.rstrip(b"\n") + b"\n"
            left.write_bytes(old_data)
            right.write_bytes(new_data)
            patch = embedded([*options, "-L", "left", "-L", "right"])
            target = root / "applied"
            target.write_bytes(left.read_bytes())
            applied = subprocess.run(["/usr/bin/patch", "-s", str(target)], input=patch.stdout,
                                     capture_output=True, timeout=30)
            assert applied.returncode == 0 and target.read_bytes() == right.read_bytes(), (
                case, options, patch.stdout, applied.stderr)
            checks += 1

print(f"diff: {checks} reference and patch-application checks passed.")
