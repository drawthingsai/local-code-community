# Optional Mathlib package

Use this only when the proof needs Mathlib definitions, lemmas, or tactics such as
`ring`. The prepared [v4.34.0 release](https://github.com/drawthingsai/mathlib4/releases/tag/v4.34.0)
contains Mathlib and its pinned dependencies as exported proof/interpreter data,
not native executables. No desktop preparation, `lake`, or compiler is required.
Do not use GitHub's automatically generated source-code ZIP as the package.

## Install through Bash

First run `pwd` and `lean --short-version`. This package requires **4.34.0**; stop
on a different version rather than installing an incompatible release. It is a
638 MiB download and about 2.04 GiB installed. Allow roughly 4 GiB free for staging
and the bundled modules subsequently extracted by Lean. Follow the user's network
and storage constraints before downloading.

Replace `/absolute/project/root` below with the actual project directory reported
by `pwd`, keeping it quoted. Run this as **one line in its own Bash call**:

```sh
cd /app_bundle && python3 Skills/check_lean-and-lean-tools/scripts/install_mathlib.py --project-root '/absolute/project/root' --lean-version 4.34.0
```

Keep this call free of variable assignments, command substitutions, and added
newlines so `cd /app_bundle` resolves correctly. `/app_bundle` is a `cd`
destination, not a Python filesystem path. Do not search for host Python
installations or set `PYTHONHOME`/`PYTHONPATH`.

The installer verifies pinned archive and manifest hashes plus each module file,
then installs atomically to `.localc/lean/packages/mathlib/4.34.0` within that
project. It removes its temporary ZIP after success and re-verifies an existing
installation without downloading again. It does not overwrite an existing,
damaged, or unrelated directory. On failure, inspect the diagnostic; do not bypass
checksum/version checks or delete existing data without checking the exact target.
Interrupted downloads restart on retry. Allow the Bash job to finish and poll it
if the initial call yields.

## Use and verify

In a new Bash call from the project root, run the included smoke proof:

```sh
LEAN_PATH=.localc/lean/packages/mathlib/4.34.0/lib/lean check_lean --stdin < .localc/lean/packages/mathlib/4.34.0/SmokeTest.lean
```

Require `status: valid`. This imports all of Mathlib and checks group cancellation,
a polynomial identity with `ring`, and existence of primes beyond an arbitrary
bound. It is a smoke check, not an independent audit of every imported theorem.

`LEAN_PATH` specifies library directories, not the command to run. Always follow
the assignment with `lean` or `check_lean`:

```sh
LEAN_PATH=.localc/lean/packages/mathlib/4.34.0/lib/lean lean proof.lean
```

For an audited result, use the same prefix with `check_lean 'SOURCE'` or
`check_lean --stdin < proof.lean`. Include the module header
and focused `public import Mathlib.…` imports in the source; `check_lean` still
takes source text, never a filename argument. The package root is `lib/lean`, not
its `Mathlib` subdirectory. Set the prefix in each Bash call; shell environment
changes do not persist across calls. The base libraries stay bundled and lazy;
the optional Mathlib package is fully extracted. Imported compiled artifacts are
part of the trusted environment.
