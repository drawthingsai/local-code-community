---
name: check_lean-and-lean-tools
description: Use check_lean to machine-check material, non-obvious universal claims involving induction, recursive functions or data structures, arbitrary depth, or reusable lemmas in coding, debugging, review, and design.
---

# `check_lean` and `lean` tools

Use Lean when an important universal claim needs induction, recursive definitions, arbitrary-depth structures, termination reasoning, or several composing lemmas. Prefer `check_lean` over Python sampling to establish these universal claims. Sampling can find counterexamples, but cannot prove that a property holds for all inputs or states. An informal proof can guide the formalization but does not replace machine-checking when that confidence matters. This is an escalation tool, not a default reasoning method: prefer `check_smt` for compact arithmetic, bitvector, Boolean, constraint, and finite-state questions, and ordinary tests for concrete cases.

## What's Available

Both commands run through Bash using the embedded Lean interpreter. Bundled libraries include **Init, all of Std (including Std.Data), Lean, and Lake modules**, with tactics such as `induction`, `cases`, `simp`, `rw`, `simpa`, and `omega`. Imports extract the needed bundled modules on demand; no installation is needed. Prefer focused imports to keep loading and disk use small.

**Mathlib is not bundled.** If the proof needs it, read [the optional Mathlib workflow](references/mathlib.md) for the prepared, version-matched package and its in-runtime installer. Do not assume Mathlib imports or tactics are usable before installation.

This is not a desktop toolchain: there is no `lake` build command or `elan`, native plugin loading, executable generation, or `lean --run`. Bundled Lake modules do not provide the Lake CLI. Local `.lean` files are not automatically compiled when imported; keep small checks self-contained. `lean --short-version` reports the embedded version.

## Submit a proof

`check_lean 'SOURCE'` takes **a string of Lean source, not a filename**. For an existing file, use `check_lean --stdin < proof.lean`. For a source string beginning with a `--` comment, use `check_lean -- 'SOURCE'` to end option parsing.

Use a quoted heredoc for multiline source. This example proves a property for every tree, regardless of depth:

```sh
check_lean --stdin <<'LEAN'
module
prelude
public import Init

public inductive ProofTree where
  | leaf : Nat → ProofTree
  | fork : ProofTree → ProofTree → ProofTree

public def mirror : ProofTree → ProofTree
  | .leaf n => .leaf n
  | .fork l r => .fork (mirror r) (mirror l)

public theorem mirror_twice (t : ProofTree) : mirror (mirror t) = t := by
  induction t with
  | leaf n => rfl
  | fork l r ihl ihr => simp [mirror, ihl, ihr]
LEAN
```

Include the target theorem, imports, definitions, and required helper lemmas in each submission; declarations do not persist across calls. Use the exported-module style above, not `import all` into private library internals.

For file-oriented iteration, use `lean proof.lean` or `lean --json proof.lean` for diagnostics, then audit with `check_lean --stdin < proof.lean`. A successful ordinary `lean` command can still contain `sorry` or additional axioms; it is not equivalent to an audited `valid` result. `#print axioms theoremName` helps inspect dependencies. `--timeout` is a Lean heartbeat budget, not seconds; Bash cancellation/timeout is separate.

## Develop and interpret the proof

- Formalize only the uncertain claim and the minimal relevant abstraction. For induction, consider strengthening the hypothesis or proving a combined helper lemma. On failure, inspect the diagnostic and revise the definition, lemma, or termination argument before retrying; do not resubmit unchanged source.
- Preserve the original semantics: arithmetic widths and overflow, preconditions, recursive structure, equality, and abstractions. `Nat` and `Int` are not fixed-width machine integers. Check for impossible hypotheses that make the theorem vacuous.
- Read the plain-text status, not just the exit code. `valid` means the submitted declarations check using the accepted standard axioms (`propext`, `Classical.choice`, `Quot.sound`) or none. `conditional` means they check relative to the listed additional `assumptions:`; it does not establish those assumptions or their consistency. Both statuses exit successfully. `invalid` means a proof/source error or rejected proof dependency. Runtime errors, cancellation, and timeouts establish nothing.
- Do not use `sorry`, proof holes, or invent axioms to make a theorem pass. Explicit theorem hypotheses still limit a `valid` result; they need not appear in `assumptions:`. Successful imports or `#eval` alone are not a universal proof, and imported compiled artifacts are part of the trusted environment.
- Explain the checked claim, relevant assumptions, and remaining modeling limits in the original problem's terms. Never present `conditional` as an unconditional proof or make Lean source the primary answer unless requested.
