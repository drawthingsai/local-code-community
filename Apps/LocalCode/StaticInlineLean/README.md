# StaticInlineLean experiment

The experiment statically links Lean 4.34.0 into macOS/iOS and interprets imported
Lean IR. Local Code now registers `lean` and `check_lean` as `ios_system` commands,
not additional model tools. Mathlib remains an optional, version-matched local
artifact package.

## Shell commands

```sh
check_lean 'theorem example_proof (n : Nat) : n ≤ n + 2 := by omega'
check_lean --stdin < proof.lean
lean proof.lean
lean --json --stdin < proof.lean
```

`check_lean` takes **source text**, not a file name. Its output is the plain-text
proof response below. Both `valid` and `conditional` exit successfully; invalid
proofs and runtime errors exit 1, and shell cancellation exits 130.
For source beginning with `--` (a Lean line comment), use the usual option
separator: `check_lean -- '-- comment …'`.

`lean` takes a file or `--stdin` and prints conventional diagnostics. Ordinary
Lean permits `sorry` warnings and additional axioms, so exit success is not the
same as the auditor's `valid`. Use `#print axioms theoremName` for inspection.

The option table/short-option grammar is generated verbatim from pinned upstream
`src/util/shell.cpp`, and option values are handled by upstream
`Lean.ShellOptions.process`. The embedding supports `-D`, `-T`/`--timeout`
(Lean's deterministic heartbeat limit, not seconds), `--stdin`, `-q`,
`-E`/`--error`, `--json` for `lean`, and upstream version/help/features queries.
Other options are explicitly rejected; handlers with immediate process-global
side effects are never invoked. Argument validation otherwise remains upstream. This
first command surface does not implement artifact output, `--run`, root/setup
overrides, server/worker modes, task-manager changes, or native plugins/codegen.
The upstream help is retained with an embedding-support notice.

Both commands share the lazy resource cache, resolve input and `LEAN_PATH` entries
against the shell session's PWD and aliases, and route Lean streams to the command
streams. `LEAN_PATH` contains colon-separated unpacked package roots; the current
directory is searched after explicit roots. The default archive is bundled in
the app. For a standalone host, set `LEAN_RESOURCE_ARCHIVE` to `Lean_Init_Std.zip`
(the manifest must be alongside it); `LEAN_RESOURCE_CACHE` optionally selects the
cache parent. Bazel CLI runfiles are also discovered automatically.

Cancellation disables Darwin's asynchronous pthread cancellation while Lean owns
objects/locks, polls while reading input or waiting for resources, and forwards
the session flag to a Lean cancellation token during elaboration. Stream callbacks
poll blocked pipes too and preserve buffered session stdin. Native work runs on
Lean-owned threads for upstream stack sizing, stack guards, and TLS cleanup.
The anonymous stream callbacks report cancellation with `ECANCELED`, not `EINTR`:
this pinned Lean version's `EINTR` decoder requires a filename and otherwise
dereferences null. Shell cancellation still returns 130.
`IO.Process.exit` / `forceExit` return an embedding error;
they do not terminate the app. This is not a sandbox: arbitrary unsafe Lean or
non-cooperative user IO is not isolated, and a full virtual filesystem for code
executed by `#eval` is not provided.

The solver prompts describe `check_lean` as a fallback for work unsuitable for
`check_smt`. The bundled [check_lean and lean tools skill](../Resources/Skills/check_lean-and-lean-tools/SKILL.md)
covers proof strategy, command usage, and the currently available libraries.

## Native isolation and symbol retention

Lean, its C bridge, and its mini-GMP/libuv/mimalloc dependencies are partially
linked into one encapsulated archive, following NodeMobile and PythonIOS. Only
the selected Lean C ABI remains public; dependency references bind inside that
archive before local symbols are stripped. The raw dependency archives and their
headers are not propagated to app consumers. Build-time checks require an exact
export match and reject unbound allocator/libuv/GMP references.

Lean uses an explicitly initialized, private `uv_loop_t`, not `uv_default_loop()`.
Its loop and worker remain alive for the embedded runtime's process lifetime;
individual commands do not close them. This is symbol/loop ownership isolation,
not process isolation: libuv signal handling and other OS resources can still
have process-wide effects.

Mimalloc serves Lean's explicit `mi_*` calls only. A compilation guard rejects
malloc override, Apple interposition, and malloc-zone replacement switches, even
when defined as zero. The app continues using libSystem malloc; mimalloc retains
its own heap/TLS initialization. Mini-GMP supplies Lean's large-integer arithmetic.

Lean's interpreter uses `dlsym` for native functions, constants, and module
initializers. The shared `LeanBridge` dependency supplies a generated linker
response file with exact `-u` roots, following the retention pattern already used
by `PythonFramework`. No application target needs `-export_dynamic` or a global
`-exported_symbols_list`: the latter would also hide unlisted Python/`ios_system`
exports when those runtimes are statically linked into the host CLI.

`Vendors/Lean/exported_symbols.txt` is the reviewed ABI selector. The generator
intersects it with public definitions in the target-platform Lean archives only
(including the C bridge and embedding-safe platform stubs), never with unrelated app or
dependency symbols. C++ implementation symbols, private/undefined symbols, and
the renamed process-exit implementations are not retention roots. Both generated
functions and exported constants are included; the interpreter looks up both.
The response file avoids command-line length limits and also replaces the old
`alwayslink` requirement for generated Lean code. Changes to the pinned Lean ABI
should review the selector, especially nonstandard `@[extern]`/`@[export]` names.

`LeanCommandTests` runs a copied, locally stripped and ad-hoc-signed executable,
checks every selected symbol with `dlsym`, then exercises the commands. Under
`--config=release`, it also verifies that an unrelated public function with a
Lean-like name is dead stripped. `LeanSymbolRootsTests` checks the public/hidden,
undefined, weak, data, and LTO-symbol selection cases. The command tests also check
private dependency visibility, libSystem allocator binding, alternating Lean/Node
timers, and large-integer arithmetic. `LeanEncapsulationTests` deliberately collides
host/dependency functions and common globals and tests the allocator-policy guard.

Use `strip -S -x` for executables with name-only lookup. Bare `strip -u -r`
removes such symbols even when the linker used an export list. For a standalone
Lean executable, `strip -u -r -s lean-symbols.txt` explicitly retains the Lean
interface; a combined host would also need to preserve the other runtimes'
interfaces. The ordinary local/debug-symbol strip avoids that app-wide policy.

## Proof responses

Responses are plain text with lowercase statuses:

- `valid`: elaboration succeeds and new declarations depend only on the standard
  axioms `propext`, `Classical.choice`, and `Quot.sound` (or no axioms).
- `conditional`: elaboration succeeds with additional axioms. `assumptions:` lists
  their names, deduplicated and sorted, including transitive imported dependencies.
  This checks a proof relative to those assumptions; it does not establish the
  assumptions or their consistency.
- `invalid`: elaboration fails, or declarations depend on `sorryAx` or the
  experiment's unsupported deprecated native-reduction axioms
  `Lean.ofReduceBool` / `Lean.ofReduceNat`.
- `error`: a bridge/runtime error prevents checking.

For example, a theorem proved using a local package's axiom produces:

```text
status: conditional
assumptions:
  externalHypothesis
```

Explicit theorem parameters remain part of the theorem's statement, so they do
not by themselves change `valid` to `conditional`. The macOS file-checking harness
returns success for either status. `main.m` contains regressions for conditional
proofs, deduplication, transitive dependencies, explicit parameters, proof holes,
mixed assumptions/holes, deprecated native reduction, and successive invocations.

## On-demand resources

The current broad resource selection in `lean4_toolchain.BUILD.bazel` includes
`.olean`, `.ir`, and `.ir.sig` for Init, all of Std, Lean, and Lake. It excludes
`.olean.private`, `.olean.server`, native libraries, and sources. This is broader
than the earlier Init + Std.Data / selected-tactics size estimate.

The archive is now built by `//Vendors/Lean:LeanRuntimeArchive`, using deterministic
ZIP DEFLATE level 6. Its 2,516 modules occupy **183.45 MiB** compressed. The adjacent
`Lean_Init_Std.json` records the exact Lean version, archive hash, module imports,
and each artifact's path, size, and SHA-256. Dependencies are read from the compiled
`.olean` metadata by `ExportModuleDependencies.lean`, not guessed from source text.

`LeanRuntimeResources` implements synchronous lazy preparation and checking:

- Lean's own header parser discovers direct imports, including implicit Init and
  nested comments. The manifest supplies a conservative transitive module closure,
  including private/meta dependency edges; all three facets travel together.
- Only this closure is extracted. Existing local package roots take precedence;
  their requested modules' import metadata is read by Lean without running their
  initializers, allowing those packages to request bundled dependencies lazily too.
- The cache is keyed by Lean version and archive hash. Every module is verified
  before use. A module's files are staged and hash/CRC checked, individually renamed
  atomically, and marked complete last. Missing, corrupt, or interrupted modules
  are rebuilt from the archive.
- Each check supplies a fresh explicit `ImportArtifacts` map. A later import in
  the same process therefore sees newly extracted modules. The old root-only
  artifact-map cache has been removed.
- Extraction, checking, and `clearCache()` share one process-wide lock. Cache
  clearing cannot run during a check through this API. This is not a cross-process
  filesystem lock, and direct callers of the C bridge do not acquire this lease.
- Automatic eviction is not implemented. The default cache lives under the app's
  reclaimable Caches directory; explicit clearing is recoverable from the ZIP.

The manifest's cold-cache closures are:

| Import | Modules | Extracted MiB |
| --- | ---: | ---: |
| Init.Prelude | 1 | 3.609 |
| Init | 649 | 112.863 |
| Std.Data | 675 | 178.491 |
| Lean.Parser | 698 | 188.263 |

These are individual closures, not incremental allocations when run in sequence.
Broad imports still materialize broad closures. No source, native library, or
`.olean.private` file is added to the payload by this change.

### Earlier compression baseline (2026-09-05)

The initial investigation measured the same files using ZIP DEFLATE level 9:

| Data group | Raw MiB | Deflated entries MiB |
| --- | ---: | ---: |
| Init | 112.22 | 30.89 |
| Std | 130.46 | 36.47 |
| Lean | 409.37 | 97.25 |
| Lake | 38.64 | 9.04 |

The complete archive, including ZIP metadata, was **174.64 MiB**, versus
**690.69 MiB** for its 7,443 input files (74.7% smaller). Python's ZIP extraction
took **4.76 seconds** on this Mac, and SHA-256 comparison verified every extracted
file against its original. Compression took 550.81 seconds while native builds
were also running; that is a build-time cost, not a first-use cost. These timings
are not a ZIPFoundation or iOS device benchmark.

The earlier raw-resource development IPA was 868.62 MiB, including its 174.72 MiB
signed executable. It stored ZIP entries uncompressed. Compressing the resources
therefore saves space in our development IPA and installed app; it should not be
interpreted as an equivalent improvement over an already compressed distribution
download. The native executable remains installed, signed code outside the archive.

With Lean 4.34.0, if every module is eventually extracted, the archive and full
cache occupy about 880.94 MiB of data in total, plus the native executable. Lazy extraction saves
space through focused imports, not by eliminating that worst-case duplication.

### Running the experiment

Build the macOS checker and its data archive:

```sh
bazel build //Apps/LocalCode:StaticInlineLeanMacOS //Vendors/Lean:LeanRuntimeArchive
```

Run the suite with `STATIC_INLINE_LEAN_ARCHIVE` pointing to the absolute path of
`bazel-bin/Vendors/Lean/Lean_Init_Std.zip`. The manifest must be beside it. Optionally
set `STATIC_INLINE_LEAN_CACHE` to a fresh temporary directory for cold-cache
measurements. Each check logs required modules, newly extracted modules, and bytes.
Passing a `.lean` source path runs just that file. `STATIC_INLINE_LEAN_PACKAGE_ROOT`
continues to accept colon-separated roots containing unpacked local packages.

For comparison with the original unpacked runtime, set
`STATIC_INLINE_LEAN_BASE_ROOT` instead of the archive variable. The iOS experiment
uses its bundled ZIP/manifest by default and the app's Caches directory.

```sh
bazel test //Vendors/Lean:LeanResourcesTests
bazel build //Apps/LocalCode:StaticInlineLean --ios_multi_cpus=arm64
```

## Broader CLI compatibility

The executable is named `lean`; `leanprover` is the upstream organization. `lake`
is the build/package tool and `elan` manages native toolchains.

The focused commands above use `ios_registerCommand` and an in-process
`int (int, char **)` entry point. Writing `.olean`/IR artifacts is possible without
a native C compiler but is not implemented here. Upstream `lean --run` invokes
Lean's IR interpreter, so interpreted programs are also a possible later extension.

The embedding keeps ownership separate from upstream `lean_main`:

- `src/util/shell.cpp` creates a process-lifetime initializer and task manager and
  uses global option parsing. Our bridge already owns initialization and serialized
  evaluation; reuse that ownership.
- `Lean.shellMain` normally calls `IO.Process.exit` after checking. An embedded
  frontend must return a status instead. User code calling process exit also needs
  an embedding-safe implementation before supporting arbitrary `--run` programs.
- Session streams and search paths are scoped to each call. Synchronous
  elaboration gives the command ownership of diagnostics and cancellation;
  arbitrary user-spawned background IO is not process-isolated.
- Integrate cooperative cancellation with the managed-runtime path. Do not allow
  `ios_kill` to asynchronously cancel a Lean evaluation pthread.
- Keep the frontend and proof-audit response separate: a conventional Lean command
  has its own diagnostics/exit conventions; `check_lean` additionally classifies
  the proof's assumptions.

Desktop CLI parity is a larger scope. The current bridge deliberately uses exported
module artifacts even for legacy source headers. Full legacy/private import
semantics may need more artifact facets: the toolchain's complete `.olean.private`
set alone is about 1,284 MiB uncompressed. Its server facets add about 30 MiB.
Those are not included in the current payload.

Unmodified `lake build`/`lake exe` and `elan` are not drop-in commands: Lake's build
actions spawn `lean`, C tools, and other executables, while Elan installs/switches
native toolchains. A proof-only Lake workflow would need adapted in-process build
actions and package acquisition. Downloaded native plugins/executables cannot be
used by this interpreter-only iOS design. Start with `lean` and local artifacts.

Upstream references:

- [Lean 4.34.0 shell implementation](https://github.com/leanprover/lean4/blob/v4.34.0/src/Lean/Shell.lean)
- [Lean 4.34.0 C++ entry point](https://github.com/leanprover/lean4/blob/v4.34.0/src/util/shell.cpp)
- [Lake build actions](https://github.com/leanprover/lean4/blob/v4.34.0/src/lake/Lake/Build/Actions.lean)
- [Lake documentation](https://lean-lang.org/doc/reference/latest/Build-Tools-and-Distribution/Lake/)

## Lean / Mathlib 4.34.0 verification (2026-09-16)

Lean is pinned to stable `v4.34.0`, commit
`293d5d0c0c3f3dded4688b3ccd6a33939ac5102b`. The matching upstream Mathlib tag,
commit `5ed2965256430c3649e86755f9576b54eca72435`, was mirrored to
`drawthingsai/mathlib4` without changing its branch history. Existing Apple
patches, bridge APIs, dependency encapsulation, and targeted symbol retention
work unchanged; no blanket exports or new native dependencies were introduced.

- The bundled archive contains 2,516 modules, **183.45 MiB** compressed and
  **697.49 MiB** unpacked. SHA-256:
  `40239857cf58af1dfd09495454f7c33bc0dfcbf77050127d03cb511f803363f3`.
- All 13 core proof/response cases passed with cold and warm caches. The warm
  run extracted zero files. Release `LeanCommandTests`, `LeanSkillExamplesTests`,
  `LeanSymbolRootsTests`, and `LeanEncapsulationTests` passed, including stripped
  symbol lookup, allocator/libuv isolation, option handling, and cancellation.
  `LeanResourcesTests`, `SkillCatalogTests`, and `ShellCommandParserTests` passed.
- The standalone `StaticInlineLean` arm64 iOS target builds and signs with
  `--config=release`. The full `LocalCode` app build is blocked outside Lean:
  `Apps/DrawThingsCLI/DrawThingsCLI.swift` calls `DynamicGraph.fork` at lines
  2175, 2225, and 4148, but the linked `DynamicGraph` API has no such member.
  That unrelated integration was not changed here.
- `Mathlib-4.34.0-5ed296525643.zip` contains 8,908 modules, **637.58 MiB**
  compressed and **2,091.85 MiB** of unpacked module data. SHA-256:
  `f4744917a457e03cd19d7daa5e20b1f3aaa4705b01e01c15abb3d77f0759a899`.
  The matching cache lacked `Mathlib.Probability.Kernel.Invariance` and `Mathlib`;
  `lake build +Mathlib:olean` built those from pinned sources before packaging.
  CRCs, the complete dependency closure, exported-only facets, and every installed
  module's hash/size were verified. No private/server facets or native code ship.
- The unchanged package smoke proof (full Mathlib import, group cancellation,
  rational `ring`, and primes beyond an arbitrary bound) returned `status: valid`
  in the release embedding with a fresh lazy cache: 1,836 base modules,
  535,357,856 bytes. After publication, all four GitHub release asset hashes
  matched the prepared files. `MathlibInstallValidation` used the unmodified
  bundled installer through embedded Python and `cd /app_bundle` to download the
  public ZIP into a fresh project, verify the pinned archive/manifest and every
  module, and remove the temporary download. The following `ios_system`
  `check_lean --stdin` smoke proof returned `status: valid`. A second invocation
  re-verified the installed package without downloading and returned `valid`
  again. Both harness invocations exited 0. All 10 installer regression tests
  and the updated skill/catalog/parser tests passed.

The manual `MathlibInstallValidation` harness also accepts
`PROJECT RESOURCES LEAN_ARCHIVE PROOF EXPECTED_STATUS`, where `EXPECTED_STATUS`
is `valid` or `conditional`. `PROOF` is resolved relative to the project (or may
be absolute), and its contents are redirected to the real `ios_system`
`check_lean --stdin` command with the installed package on `LEAN_PATH`.
The harness requires both exit code 0 and an exact matching status line.
Omitting the optional pair still runs the installed `SmokeTest.lean` and expects
`valid`; that default invocation passed after adding this option.

### Long-gap proof compatibility

The source from [openai/LongGapsBetweenPrimes at `03a1190d0bc5`](https://github.com/openai/LongGapsBetweenPrimes/tree/03a1190d0bc5502d9f54eeb60ad3e45e22b0df0b)
is unchanged from its original `8f5fa88c88b4` revision and targets Lean 4.33.0.
It **does not pass unchanged** against Mathlib 4.34.0, even with desktop Lean.
Mathlib renamed the nonnegative-real product lemmas to `Finset.prod_le_prod₀`
and `Finset.prod_le_one₀`; the old names now have different ordered-monoid
signatures. The included [compatibility patch](LongGapsBetweenPrimes-4.34.patch)
changes exactly eight lemma references, without changing statements, hypotheses,
or proof strategy. Apply it to that pinned upstream checkout with `git apply`.

The patched full source passes both desktop Lean and the release static embedding
using only the prepared exported Mathlib artifacts and bundled lazy resources.
The embedding reports `status: valid`; `long_prime_gaps` depends only on
`propext`, `Classical.choice`, and `Quot.sound`. The audit also checks the newly
submitted helper declarations, including `long_gap_theorem` and `short_translates`.
This is a Mathlib source-port requirement, not a bundle failure. The large FLT
repository was not rebuilt as part of this upgrade.

### PrimeGaps186 compatibility

The unchanged 210,637-line source from
[PrimeGaps186 at `61340d0b7416`](https://github.com/openai/PrimeGaps186/tree/61340d0b74163003b32756bb16e91d9209a5e330)
was checked through the release `MathlibInstallValidation` harness and the actual
`ios_system` `check_lean --stdin` command, using the published exported-only
4.34.0 package. This completed the retry of the earlier resource-limited run:
**18 minutes 10 seconds**, exit code 1, `status: invalid`.

The source pins Lean 4.34.0-rc2 and Mathlib
`bbcd1968ee6950abe88b85dba6995da346c4b2a8`, not the stable Mathlib revision above.
The completed check reported 163 error diagnostics (including cascading errors
and two recursion-depth limits). Representative source/API incompatibilities:

- `PowerSeries.derivative R` now requires the implicit ring argument form
  `PowerSeries.derivative (R := R)`.
- Nonnegative-real product inequalities need `Finset.prod_le_prod₀`, rather than
  the current ordered-monoid `Finset.prod_le_prod`.
- `eLpNorm_add_le`, `eLpNorm_mono`, and `measurable_pi_lambda` have changed argument
  signatures.

A small embedded reproducer using the old derivative/product forms returned
`invalid`; the same focused check with the 4.34 forms returned `valid`. The full
run reported no missing-module or native-symbol diagnostics, but it is **not a
passing bundle proof test**. No compatibility edits were made to the full source.
This is a failed check against a different dependency revision, not a finding
that the mathematical claim is false.

The three explicit project axioms (`PrimeGap186.kloosterman3_bound`,
`PrimeGap186.kloosterman2_correlation_bound`, and
`PrimeGap186.physical_integral_bounds`) did not cause this rejection: source
errors stop the check before the axiom audit. If a compatible source checks with
only these additional axioms, the expected result is `conditional`, not `valid`
or an axiom-policy failure. The separate Python numerical certificate was not run.

The [v4.34.0 release](https://github.com/drawthingsai/mathlib4/releases/tag/v4.34.0)
is published and the public download/install path is verified in the release
macOS embedding. No iOS device execution has been performed.

## Prepared Mathlib verification (2026-09-09)

The [published v4.33.1 package](https://github.com/drawthingsai/mathlib4/releases/tag/v4.33.1)
was prepared from upstream
Mathlib commit `0df444a360eaa60ab8c11dca51a86af692955474` (v4.33.1), with its
lockfile-pinned dependencies and Lean commit
`819816b2e0a3bf405af45ae5c7af2491d8f5bee6`. The skill's optional Mathlib reference
now documents an in-runtime installer; it does not require desktop preparation.

- `Mathlib-4.33.1-0df444a360ea.zip` contains the 8,690-module transitive closure
  of `Mathlib`, flattened into one `lib/lean` package root. It contains exported
  `.olean`, `.ir`, and `.ir.sig` data, dependency licenses, provenance, a per-file
  manifest, and a smoke proof. No native executables/libraries or private/server
  facets are included. It is **627.65 MiB** compressed and **2,060.40 MiB** of
  unpacked module data, excluding the separately bundled base libraries.
- Archive SHA-256:
  `d0f857c5ba8362f40edbea8ba7137c4276ae38cb10c35e87383f74da3b87c732`.
  The archive hash, every module file's hash/size, and the dependency closure
  were verified before testing a fresh extraction.
- The release macOS embedding successfully checked a broad `public import Mathlib`
  proof combining group cancellation, `ring` over rationals, and existence of
  primes beyond an arbitrary bound: `status: valid`. A cold bundled cache
  extracted 1,808 base modules (532,725,568 bytes). The same proof also passed
  through `ios_system` with `LEAN_PATH` and `check_lean --stdin`.
- This exposed a native metadata-reader lifetime bug: pure JSON serialization
  was compiled after freeing its mapped module region, sometimes returning an
  empty import list. `moduleImports` now forces serialization through an IO
  reference before freeing the region. A release command regression checks that
  native dependency reads retain `Init.Prelude`. Rebuild the app with this fix
  before trying the prepared package.
- The published ZIP was downloaded by embedded Python through `ios_system`,
  checked against its pinned hash, extracted, and verified per module. The
  installer uses a project-local staging directory and atomic rename, preserves
  existing installations, and removes its temporary ZIP. A second invocation
  re-verified the installed files without downloading. Both cold installation
  and reuse were followed by `status: valid` on the Mathlib smoke proof.
- `//Apps/LocalCode:MathlibInstallValidation` is a manual release macOS harness
  taking `PROJECT RESOURCES LEAN_ARCHIVE`. With host Python resource/certificate
  paths configured, it tests the native `cd /app_bundle` and Python direct-command
  sequence, then a fresh session for the Lean check. The reference deliberately
  uses a single-line direct sequence with a literal project path: generic OSH's
  builtin `cd` does not resolve this virtual alias. A parser regression checks
  that the documented command stays on the direct path.
- `MathlibInstallerTests` covers version/hash rejection, safe extraction,
  interrupted downloads, preservation of existing files, corruption detection,
  and reuse. It passes along with `SkillCatalogTests`, `ShellCommandParserTests`,
  release `LeanSkillExamplesTests`, and release `LeanCommandTests`. The skill's
  heredoc proof runs through the real shell test harness.
- A separate exploratory run prepended Python installation and the Mathlib proof
  to the full single-session command stress suite. Installation and proof passed,
  but its later blocked-stdin cancellation assertion failed (`ios_kill() != 0`).
  This mixed-session stress observation remains unresolved; it is not covered by
  the successful fresh-session installer harness. No iOS device execution was
  performed in this verification.

## Command integration verification (2026-09-08)

- Native retention was verified with `--config=release` and its `-dead_strip`
  link. `LeanCommandTests` finds all **222,701** selected interpreter symbols
  after `strip -S -x`, verifies the unretained export probe is absent, and passes
  the command/cancellation suite. `LeanSymbolRootsTests` and `Z3CommandTests`
  also pass in this configuration.
- `//Apps/LocalCode:LocalCode` builds and signs successfully with the unmodified
  release configuration for arm64 iOS. Its packaged, signed executable retains
  all 222,701 selected symbols in the export table. `LeanResourcesTests` and
  `CheckSmtToolTests` pass in their normal test configuration.
- The 13-case proof suite passes with cold and warm caches on the stripped
  release executable; the warm run extracts nothing. A separate
  `strip -u -r -s lean-symbols.txt` copy also passed both runs. The final
  standalone executable is approximately **143.00 MiB** after local/debug-symbol
  stripping and ad-hoc signing (excluding the ZIP resources). On the compared,
  re-signed copies, the aggressive keep-list strip saves only about 33 KiB and
  takes substantially longer.
- A small native linker probe also verified `-u` with C LTO, dead stripping,
  and local/debug-symbol stripping: the selected symbol remains discoverable
  and an unrelated function disappears. This is not a full-app C LTO build.
- The release `LocalCodeCLI` executable links and runs `--help`, but the bare
  Swift Bazel target fails its output validation because the expected dSYM
  DWARF file is not produced. The release Swift test targets hit the same issue
  (after enabling `swift.enable_testing` for `@testable` imports). This build-rule
  issue is separate from Lean symbol retention; no shared dSYM rules were changed.
- Rebased the branch onto `origin/main` at `e3e3cd732`; restored the existing
  experiment changes without conflicts.
- Both `//Apps/LocalCode:LocalCode` (arm64 iOS) and
  `//Apps/LocalCode:LocalCodeCLI` build successfully. The host CLI's `--help`
  also runs successfully.
- `LeanCommandTests`, `LeanResourcesTests`, `CheckSmtToolTests`, and
  `Z3CommandTests` pass. Shell regressions exercise upstream option validation,
  repeated invocations, quoted source and `--`, stdin/files/redirection,
  plain-text auditing, conventional JSON diagnostics, heartbeat exhaustion,
  process-exit protection, cancellation during a running tactic and blocked
  input/output, and successful calls after cancellation.
- The existing 13-case macOS proof suite passes with cold and warm caches after
  the thread-lifecycle changes; the second process performs zero extractions.
  Mathlib/prime-gap/FLT cases were not rerun here.
- The signed iOS IPA contains only `Lean_Init_Std.zip` (190,633,946 bytes) and
  `Lean_Init_Std.json` (1,400,394 bytes) as bundled Lean data, not loose `.olean`
  or IR facets. The CLI runfiles contain both resources as well.
- No on-device execution was performed in this verification.

## Archive verification (2026-09-06)

- The archive and macOS checker builds passed.
- `bazel test //Vendors/Lean:LeanResourcesTests`: all 12 cache tests passed,
  including warm reuse, later imports, missing/corrupt/interrupted modules,
  explicit clearing, hash/version rejection, and parent/child module markers.
- All 13 macOS smoke checks passed with a cold cache, then passed again in a
  second process with **zero extractions throughout the warm run**. This includes
  nested comments in the import header, implicit Init, later imports in the same
  process, and the existing valid/invalid/conditional response cases.
- The original nine response checks also passed against the unpacked toolchain.
- A separate local package's exported artifacts were imported using an initially
  empty bundled cache. Its transitive imports requested only the 631-module Init
  closure. The proof returned `conditional`, reported `externalHypothesis` once,
  and exited successfully.
- `bazel build //Apps/LocalCode:StaticInlineLean --ios_multi_cpus=arm64`: passed.
  The resulting development IPA is **358.53 MiB**, down from **868.62 MiB** with
  loose resources. It contains the **181.80 MiB** archive, **1.34 MiB** manifest,
  and **175.37 MiB** signed executable; no loose Lean artifacts or dylibs remain.
  The embedded archive's hash matches both its manifest and the macOS artifact.

The actual cache grew as follows during the cold suite:

| Checks completed | Cached modules | Artifact MiB |
| --- | ---: | ---: |
| Minimal `Init.Prelude` proof and repeat | 1 | 3.61 |
| Implicit Init proof | 631 | 112.22 |
| Proof importing both Init and Std.Data | 843 | 190.25 |
| Later Lean.Parser import and remaining checks | 1,015 | 254.33 |

These are cumulative artifact sizes, excluding completion markers and filesystem
allocation overhead. The Init + Std.Data union is larger than Std.Data alone.
The complete cold suite took 33.88 seconds and the warm suite 10.37 seconds on
this Mac while builds were running; these are observations, not controlled device
benchmarks. Packaging changes disk usage, not Lean's proof-checking memory needs:
the suite's peak resident memory was about 3.7 GB.

No iOS device runtime test or large Mathlib proof was rerun in this verification.
