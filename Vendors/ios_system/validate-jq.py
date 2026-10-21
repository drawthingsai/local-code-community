#!/usr/bin/env python3
"""Run the checked-in upstream jq suites through the embedded shell."""
import os
from pathlib import Path
import shlex
import subprocess
import sys

runner = str(Path(sys.argv[1]).resolve())
source = Path(sys.argv[2]).resolve()
for suite in ("jq", "optional", "onig", "man", "manonig", "base64", "uri"):
    command = shlex.join(["jq", "-L", str(source / "tests/modules"),
                         "--run-tests", str(source / f"tests/{suite}.test")])
    result = subprocess.run([runner, command], capture_output=True,
                            env=dict(os.environ, PAGER="less"), timeout=120)
    output = result.stdout.decode(errors="replace")
    if result.returncode or "tests passed" not in output:
        sys.stderr.write(output + result.stderr.decode(errors="replace"))
        raise SystemExit(f"jq upstream {suite} suite failed ({result.returncode})")
    for line in output.splitlines():
        if "tests passed" in line:
            print(f"jq {suite}: {line}")

checks = [
    ("set -o pipefail; printf '%s' '{\"n\":2}' | jq '.n * 3' | cat", b"6\n", 0),
    ("set -o pipefail; printf false | jq -e . | cat", b"false\n", 1),
    ("JQ_TEST_VALUE=local jq -nr '[$ENV.JQ_TEST_VALUE,env.JQ_TEST_VALUE] | join(\"/\")'", b"local/local\n", 0),
    ("jq -n 'halt_error(7)'", b"", 7),
    ("/usr/bin/jq -nc '[range(3)]'", b"[0,1,2]\n", 0),
]
for command, expected, status in checks:
    result = subprocess.run([runner, command], capture_output=True, timeout=30)
    if (result.returncode, result.stdout) != (status, expected):
        raise SystemExit(f"jq shell check failed: {command}\n{result}")
print(f"jq shell integration: {len(checks)} checks passed")
