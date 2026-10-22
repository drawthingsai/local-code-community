# NodeMobile project dependency and native-payload support

Status: generic child bridge and canonical `ios_system` `node`, `npm`, and
`npx` commands, including nested `npx`, implemented and validated, 2026-07-30.

This document turns the package/tooling direction in
[`JavaScriptProjectSupport.md`](JavaScriptProjectSupport.md) into a concrete
installation, runtime, and validation model for the vendored NodeMobile
runtime.

## Decision

Keep the installed project graph ordinary. A supported Wasm provider is
materialized under the dependency name expected by the project inside its
own `node_modules`; the runtime does not contain an esbuild-, Rollup-, or
Vite-specific import shim.

For the first pinned toolchain this means exact npm-style substitutions such
as:

```text
node_modules/esbuild  -> esbuild-wasm@0.25.12 package contents
node_modules/rollup   -> @rollup/wasm-node@4.62.2 package contents
```

The project continues to execute `require("esbuild")`, import `rollup`, and
resolve their normal `bin` entries. Local Code records the substitution in a
support lock but does not rewrite the user's `package.json` or pretend that a
downloaded native package ran.

The runtime supplies one package-independent compatibility mechanism:

```text
spawn("node", [projectLocalJavaScriptEntry, ...arguments], options)
                                |
                                v
                  disposable Node Worker
             virtual stdin / stdout / stderr

spawn("npx", [...arguments], options)
                 |
                 v
       configured npx-cli.js Worker
                 |
                 v
       project/cache Node bin Worker
```

This is sufficient for the asynchronous esbuild service used by Vite. The
bridge validates a project-local JavaScript entry, creates a disposable
Worker, forwards argv/environment/stdio, reports exit and error events, and
supports cancellation. It rejects arbitrary commands and native executable
payloads. For npm's normal `exec` implementation, it also recognizes the
narrow `sh -c "<project Node bin> <arguments>"` form, parses it without
executing a shell, resolves a Node shebang entry inside an allowed project
root, and submits that entry to the same Worker path. Shell operators,
expansion, environment assignments, and non-Node commands remain rejected.
Nested `npx` is translated to the exact upstream `npx-cli.js` entry configured
by `ios_system`; npm then resolves a project bin or installs one under the
project's managed `_npx` cache, and the resolved Node shebang returns through
the same generic Worker path. Nothing in this path switches on a package name.

Downloaded `.node` addons, Mach-O/ELF/PE executables, dylibs, shared objects,
and source builds remain unsupported. A statically linked native fallback can
be added later for a measured compatibility or performance failure, but it is
not part of the initial Vite path and it must not appear in `node_modules`.

## What is implemented now

The current implementation combines JavaScript resources with a reusable
native command host:

- `Resources/NodeMobile/Runtime/virtual-node-child-preload.cjs` patches the
  CommonJS and ESM `node:child_process` `spawn` export.
- `Resources/NodeMobile/Runtime/virtual-node-child-bootstrap.cjs` initializes
  each disposable Worker, installs command-scoped argv/environment, protects
  the host PID, and adapts Worker stdio to Node file descriptors `0`, `1`, and
  `2`.
- `StaticInlineNode/main.m` can inject the preload before an external script;
  the iOS smoke app discovers it in signed app resources automatically.
- `StaticInlineNode/Fixtures/virtual-node-child-smoke.js` validates CommonJS
  and ESM interception, argv, an environment snapshot, all three pipe
  directions, nested launch, exit, cancellation, arbitrary-command rejection,
  root confinement, and native-magic rejection.
- `StaticInlineNode/Fixtures/vite-wasm-smoke.js` is the integration gate.
- `Vendors/NodeJS/Sources/NodeRuntimeHost.cpp` owns one process-lifetime
  Node/V8 platform and creates a disposable environment for each serialized
  command. It is compiled into `libnode` and delegates option parsing and
  main-module selection to the pinned Node implementation instead of
  maintaining a second CLI dispatcher.
- `ios_system` registers canonical `node`, forwards the session cwd,
  environment, and file descriptors, and uses command-scoped cancellation.
- `ios_system` also registers canonical `npm` and `npx` wrappers. They execute
  the upstream CLI entry files through the same canonical `node` host rather
  than introducing another runtime or native command implementation. The
  configured `npx` JavaScript entry is also published to the child bridge so a
  Node program can launch nested `npx` without an OS executable.
- `Vendors/NodeJS/Resources/NodeMobile/Commands/npm-11.19.1.zip` is a
  deterministic, checksum-pinned copy of the npm payload from the pinned Node
  source. Local Code validates and extracts it transactionally from the signed
  app bundle into the app Library directory.
- Project setup prepends `<project>/node_modules/.bin` to the managed command
  `PATH`, uses `<project>/.localc/node/cache` for npm's cache, and disables
  lifecycle scripts by default. It deliberately does not set `NODE_PATH`;
  ordinary Node lookup already resolves `node_modules` from the importing
  module and current project hierarchy.
- Local Code discovers the signed preload at launch and supplies the active
  project as the virtual-child root for each Bash job.

The `Apps/LocalCode` application includes both the runtime preload and npm
command archive. The strict project dependency materializer, exact Wasm
substitutions, support lock, and whole-graph native-payload scanner remain
separate work.

No package-specific native library, executable, `.node` addon, or second
adapter XCFramework was added. The existing `NodeMobile.xcframework` was
rebuilt with the generic host and a private native-symbol boundary.

## Executable evidence

The compatibility runs in this table used Node 24.18.0 with
`--jitless --wasm-jitless`.

| Runtime and fixture | Result | What it establishes |
| --- | --- | --- |
| macOS arm64 NodeMobile baseline | Passed the existing core-module, SQLite, HTTP, `fetch`, and DrumBrake suite. | The linked runtime remains healthy. |
| `@rollup/wasm-node@4.62.2` direct API | Passed on macOS and on an arm64 iOS 26.3 simulator. | Rollup's official Wasm parser runs under DrumBrake with `process.platform === "ios"`. |
| `esbuild-wasm@0.25.12` CLI | Passed on macOS and the same simulator. | The official esbuild Wasm payload and Go JavaScript host run in NodeMobile without a native service executable. |
| Vite `7.1.2` with project-local esbuild and Rollup substitutions, before the bridge | macOS passed; iOS reached HTML transformation and failed with `spawn node ENOENT`. | The missing capability was Node-on-Node child launch, not a missing native library. |
| Generic virtual-child contract fixture | Passed with system Node, macOS NodeMobile, and iOS simulator NodeMobile. | Pipes, argv, environment, rejection, exit, and cancellation work without an OS process. |
| Bundled npm `11.16.0`, npx, and project `bin` fixture | Passed through the real `ios_system` registry on macOS NodeMobile. | The signed upstream CLI payload runs through `node`; a local pure-JavaScript package installs with scripts disabled; normal `node_modules` imports work; its Node shebang runs directly, through top-level and nested `npx`, `npm exec`, and `npm run`. A tarball supplied to nested `npx --package` executes from the managed `_npx` cache without an OS process or `NODE_PATH`. |
| The same native-free Vite `7.1.2` graph through the generic bridge | Vanilla passed on macOS NodeMobile and the arm64 iOS simulator; React+Vite also passed on macOS. The simulator generated HTML, JavaScript, and CSS with `process.platform === "ios"`. | Vite needs no esbuild-specific runtime branch and no new native library for this pinned graph. |
| Native-free VitePress `1.6.4` through the generic bridge | Passed its two-page static build on macOS NodeMobile. | The bridge is package-independent; repeated NodeMobile file-descriptor warnings remain. |

The staged Vite graph was scanned by file magic and contained Wasm but no
Mach-O, ELF, PE, `.node`, dylib, or shared-object payload. Those tool graphs
were constructed with host npm before the bundled command work; the focused
pure-JavaScript install now uses bundled npm. The policy-enforcing project
materializer remains to be implemented. A physical-device run is still
required before declaring release support.

The current packaged baseline is Node 24.22.1/npm 11.19.1. Its core macOS and
iOS simulator runtime suites and virtual-child fixture pass. The reusable
`ios_system` test confirms all three upgraded version commands, the npm
install, and top-level and nested npx, then is killed at the `_npx`-cached
tarball case, which fails the same way with the previous 24.20.0 runtime; that
row remains evidence from the last fully passing pre-OSH baseline until the
harness regression is repaired and rerun.

NodeMobile currently prints one unmanaged-file-descriptor warning during the
macOS vanilla/React Vite runs and many during VitePress. The builds succeed
and Workers are released, but these warnings remain a cleanup regression to
investigate.

## Command execution boundary

`ios_system` now has one direct-command contract:

```c
int ios_system(int argc, const char *const argv[]);
```

It preserves already-tokenized arguments exactly and performs the existing
PATH, shebang, Wasm, and static-command resolution without applying shell
tokenization, expansion, aliases, or redirection parsing. Shell text has one
separate entry point, `ios_system_osh(const char *)`.

Each Bash tool call configures its project directory, environment, streams,
timeout, cancellation, and session, then evaluates the supplied text in a
fresh non-interactive OSH instance. OSH invokes foreground external
commands synchronously through the argv API, so `cd`, `&&`, `||`, input/output
redirection, and multiple sequential Node/npm/npx invocations share the
correct state within that tool call. The caller's directory and standard
descriptors are restored afterward; shell state does not persist across tool
calls.

The no-process OSH executor implements pipelines, command substitution, and
subshells with isolated shell state and virtual streams. Background jobs and
process substitution remain explicitly unsupported. The embedded OSH runtime
is serialized, so an embedded command cannot recursively start another shell
evaluation while its outer invocation waits. Node's validated virtual-child
bridge remains the process-free mechanism used by Vite and related tools.

## Directory environment

The canonical real-path environment and directory aliases live in
[`DirectoryEnvironment.md`](DirectoryEnvironment.md). The earlier virtual
filesystem proposal is retained only as a rejected design in
[`JailedDirectoryStructure.md`](JailedDirectoryStructure.md).

Node receives the real workspace `HOME`, active-project cwd and `PWD`, and app
cache `TMPDIR`. It therefore uses the same paths as OSH and Python without
libuv filesystem virtualization.

## Generic virtual-child contract

### Accepted operation

The initial bridge accepts:

```js
childProcess.spawn("node", [entryPath, ...arguments], {
  cwd: process.cwd(),
  env,
  stdio: ["pipe", "pipe", "pipe"],
  signal,
  timeout,
});
```

`process.execPath` is also accepted as the command. The entry path may be
extensionless, which is required for normal package `bin` files. CommonJS and
ESM main-module loading follow Node's `Module.runMain()` behavior.

The bridge also accepts the exact asynchronous shell launch shape used by
upstream npm exec:

```js
childProcess.spawn("sh", ["-c", "project-bin argument"], options);
```

This does not run `sh`. A restricted parser accepts only quoting, escaping,
and whitespace, resolves `project-bin` through `PATH`, verifies that its real
path is inside an allowed root and that its first line is a Node shebang, then
runs the resolved JavaScript file through the same Worker mechanism.

The bridge exposes the child-process properties and behavior used by current
frontend tools:

- writable `stdin` and readable `stdout` / `stderr`;
- `stdio`, `spawnfile`, `spawnargs`, and a synthetic negative `pid`;
- `spawn`, `error`, `exit`, and `close` events;
- `exitCode`, `signalCode`, and `killed` state;
- `kill`, `ref`, and `unref`;
- `AbortSignal`, timeout, and kill-signal cancellation.

Worker stdio has no numeric file descriptors by default. The bootstrap gives
the three streams their conventional descriptor numbers and routes async
`fs.read(0, ...)` through virtual stdin. This is generic descriptor
compatibility; it is why Go's standard Wasm host used by esbuild can speak its
binary service protocol without writing to the app's real stdout.

### Validation

Before constructing a Worker, the bridge:

1. accepts the literal `node` command, the current `process.execPath`, or the
   restricted `sh -c` Node-bin shape described above;
2. requires a direct script path or a `PATH` entry with a Node shebang;
3. resolves `cwd`, the entry, and configured roots through `realpath`;
4. requires the entry to be a regular file inside one of
   `NODE_MOBILE_VIRTUAL_NODE_ROOTS`;
5. rejects `.node` and Mach-O, ELF, or PE file magic even if the extension is
   misleading;
6. rejects shell operators/expansion and the `shell`, detached, uid, and gid
   options;
7. accepts only `pipe`, `inherit`, and `ignore` stdio modes, including numeric
   descriptors `0`, `1`, and `2` as their inherited equivalents.

The Worker receives a copied environment. `NODE_OPTIONS` is removed before
project code runs, and the controlled preload is installed explicitly for
nested Node children. A child calling `process.kill(process.pid)` exits only
its Worker; it cannot signal the shared app process.

### Intentional initial gaps

This is not an emulated Unix process tree. The first implementation does not
support:

- `spawnSync`, `execFileSync`, `exec`, or general shell execution;
- Node CLI switches before the entry path (`node -e`, `node --import`, and
  similar forms);
- a child working directory different from its parent;
- arbitrary `ios_system` commands, IPC channels, detached children, process
  groups, uid/gid changes, or daemonization;
- synchronous reads from virtual file descriptor `0`;
- OS-level memory isolation or a distinct real PID.

Vite's production path is asynchronous and stays inside this contract.
Direct synchronous esbuild APIs remain unsupported until a generic sync
transport is designed; they must not be special-cased by package name.

Worker stdio reference control currently relies on Node's internal Worker
stdio port. The Node version is pinned, and the contract fixture is therefore
a required gate for every NodeMobile update.

## Project dependency materialization

The bundled npm CLI can currently perform an ordinary pure-JavaScript install
directly into the user's project, with lifecycle scripts disabled by default.
The production support contract still requires a policy-enforcing transaction
rooted in that project:

```text
<project>/
  package.json
  package-lock.json
  node_modules/
  .localc/
    node/cache/
    node/staging/
    node/support-lock.json
```

The installer should:

1. resolve the project's ordinary lockfile graph with lifecycle scripts
   disabled;
2. compare every package name, version, registry integrity, dependency edge,
   target, and required entry point against the support catalog;
3. replace an exact supported native-shaped edge with its exact Wasm provider
   while materializing the consumer's expected path in staged
   `node_modules`;
4. omit an optional dependency only when an exact parent/version rule proves
   the tested fallback;
5. scan metadata, symlinks, extensions, and file magic across the completed
   staged graph;
6. write `support-lock.json` and atomically promote both the graph and lock.

An install failure leaves the preceding `node_modules` and support lock
untouched.

The support lock is audit state, not runtime authority. For every
substitution it records:

- the original consumer name, version, integrity, and dependency edge;
- provider name, version, integrity, and relevant payload hashes;
- the materialized consumer path;
- the project lockfile hash and support-catalog version;
- the platform and named conformance fixtures that justified the selection.

The user manifest and lockfile remain the declaration of what the project
requested. Commands such as `npm ls` and Local Code build logs should annotate
the exact substitution so it is never mistaken for the original native
implementation.

### Initial exact substitutions

| Expected dependency | Materialized provider | Current evidence |
| --- | --- | --- |
| `esbuild@0.25.12` | `esbuild-wasm@0.25.12` at `node_modules/esbuild` | Direct CLI, Vite 7.1.2 on macOS NodeMobile and iOS simulator. |
| `rollup@4.62.2` | `@rollup/wasm-node@4.62.2` at `node_modules/rollup` | Direct API on macOS NodeMobile and iOS simulator; Vite 7.1.2 integration. |
| VitePress' `esbuild@0.21.5` edge | `esbuild-wasm@0.21.5` at that graph's `node_modules/esbuild` | VitePress 1.6.4 native-free build through the generic bridge on macOS NodeMobile; simulator pending. |

These are exact tested records, not open semver ranges. Installing a newer
Vite or plugin graph must resolve and validate its own exact providers.

## Native library policy

There are three distinct categories:

1. NodeMobile's own static dependency closure (V8, libuv, OpenSSL, ICU,
   SQLite, and related libraries) remains owned by the existing Node vendor.
2. Project dependencies and supported Wasm substitutions remain ordinary
   files in the project's `node_modules`.
3. A future native fallback, if measurements require one, is compiled into
   the signed app and selected by an exact catalog record. It is never
   downloaded or dynamically loaded from a project.

The initial support bundle has no category-3 artifact. Do not create a
`NodeMobileAdapters.xcframework` merely to support the pinned Vite graph.

Because Node and N-API symbols are private in the final runtime object, a
future static addon that needs them must be added to the NodeMobile aggregate
before encapsulation, together with its generated registrar. A narrow adapter
that does not use Node internals may instead expose an explicitly reviewed C
entry point. In either case, the vendor verifier's exact public-symbol set must
be updated intentionally.

If a future linked fallback is justified, its record must include exact
consumer/provider versions and integrities, source and patch hashes, entry
symbol, target slices, license, capability and memory limits, and focused
conformance tests. The `.node` loader still rejects all dynamic addons; a
generated static registrar exposes only the named implementation. One linked
fallback does not grant general Node-API compatibility.

## `NodeRuntimeHost` and `ios_system`

The product path now registers canonical `node`, `npm`, and `npx` in
`ios_system`. `NodeRuntimeHost` receives the command-scoped cwd, argv,
environment, streams, preload, and unique cancellation identifier.
`ios_system` prepares stable command state before publishing the Node pthread
as the session root. Cancellation sets the state's sticky flag and calls
`node::Stop` synchronously when an Environment is attached; the run call
checks the flag before and after that attachment. Cleanup releases the state
after the run returns. This mirrors the Python register/publish/unregister
lifecycle without polling or a callback. The npm and npx entries are upstream
JavaScript files invoked through that same host.

One process-lifetime Node platform supervises disposable command
environments. The host does not call ordinary `node_start()` repeatedly. For
each command, it:

1. clones the initialized Node option state and parses the command with
   Node's own option table;
2. uses the app-selected support resource and project roots;
3. creates command-scoped argv, environment, cwd, and streams;
4. installs the package/native policy and generic virtual-child preload;
5. lets Node select its normal CommonJS, ESM, eval, stdin, syntax-check,
   test-runner, and preload entry point;
6. translates `process.exit` into a command result;
7. stops the owned environment on command-scoped cancellation;
8. destroys the command environment while retaining the process platform.

V8 and unknown V8-forwarded flags are consumed without changing the already
initialized process-wide V8 configuration. Interactive REPL input and
startup-only snapshot, SEA, and `node --run` operations are intentionally
rejected.

The runtime's complete static dependency closure is collapsed into one
relocatable object. Only `node_start` and the four NodeMobile command-lifecycle
entry points remain public. This keeps Node's OpenSSL and other native
dependencies isolated from PythonIOS's independently versioned static
dependencies in the same app.

`npx` and `npm exec` resolve a package's normal project-local `bin` entry. The
constrained launch bridge verifies its Node shebang and submits that JavaScript
file to the host. It does not need a package-specific executable shim or an OS
process.

## Validation gates

### Resource and installation policy

- exact catalog schema and deterministic serialization;
- registry integrity for every consumer and provider;
- lifecycle scripts disabled by default;
- complete graph scan for `.node`, native libraries, executable magic,
  source-build launchers, path escapes, and undeclared Wasm;
- exact set equality between staged files and support-lock hashes;
- a negative fixture for unknown versions, renamed native files, tampered
  locks, source builds, and escaping symlinks.

### Runtime contract

- the focused virtual-child fixture on system Node and linked NodeMobile;
- CommonJS and ESM `child_process.spawn` parity;
- pipe backpressure, large binary frames, exit/error ordering, timeout, abort,
  kill, repeated create/destroy, and parent-command cleanup;
- accepted simple shell-form project Node bins, and rejected arbitrary
  commands, shell operators, native entries, root escapes, alternate cwd, and
  unsupported stdio;
- sequential command and project-A/project-B isolation through the final
  `NodeRuntimeHost`.

### Toolchain fixtures

Run, in order:

1. pure-JavaScript CLI and `npx`;
2. direct Rollup Wasm and esbuild-wasm CLI;
3. vanilla Vite production build;
4. React/TypeScript Vite production build;
5. VitePress static build;
6. development server, watching, and HMR only after teardown is reliable.

Record install, build, and preview separately, including selected
substitutions, time, peak memory, disk use, warnings, and cleanup.

macOS arm64 is the fast lane. Every support-resource change requires an arm64
iOS simulator run. A physical arm64 device, including the minimum supported
iOS release, is a release gate for a Node update, new Wasm provider, or future
linked fallback.

## Current Bazel shape

- `//Vendors/NodeJS:NodeMobile` imports the existing static runtime.
- `//Vendors/NodeJS:NodeCommandResources` packages the checksum-pinned npm
  command archive as a structured app resource.
- `//Apps/LocalCode:NodeMobileRuntimeResources` packages the generic bridge
  for the standalone iOS probe.
- The same files are included in the Local Code app through its existing
  `Resources/**` glob.
- `//Apps/LocalCode:StaticInlineNodeMacOS` runs linked macOS checks.
- `//Apps/LocalCode:StaticInlineNode` runs linked simulator/device checks.
- `//Apps/LocalCode:StaticInlineNodeVirtualChildTests` is the hermetic macOS
  contract test for the generic bridge.
- `//Apps/LocalCode:StaticInlineNodeIOSSystemTests` covers repeated commands,
  exact direct argv, one-shot OSH cwd and redirection behavior, state
  isolation, stream lifetime, exit/error behavior, early and queued
  cancellation, recovery, and the virtual-child preload through the real
  command registry. It also covers
  bundled npm/npx versions, local pure-JavaScript installation, ordinary
  `node_modules` resolution, project `.bin` lookup, direct Node shebang
  dispatch, `npx`, `npm exec`, and `npm run`. Its combined
  PythonIOS/NodeMobile binary verifies that the PythonIOS side resolves
  OpenSSL 3.0.20 while Node uses and exercises its private OpenSSL 3.5.7.
- `//Apps/LocalCode:LocalCode` links `ios_system`, PythonIOS, and the
  private-dependency NodeMobile runtime directly into the app executable.

Current focused verification:

```sh
bazel build //Apps/LocalCode:StaticInlineNodeMacOS
bazel build //Apps/LocalCode:StaticInlineNode --ios_multi_cpus=sim_arm64
bazel test //Apps/LocalCode:StaticInlineNodeVirtualChildTests
bazel test //Apps/LocalCode:StaticInlineNodeIOSSystemTests
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=sim_arm64
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64

NODE_MOBILE_VIRTUAL_NODE_PRELOAD="$PWD/Apps/LocalCode/Resources/NodeMobile/Runtime/virtual-node-child-preload.cjs" \
NODE_MOBILE_VIRTUAL_NODE_ROOTS="$PWD/Apps/LocalCode/StaticInlineNode/Fixtures" \
bazel-bin/Apps/LocalCode/StaticInlineNodeMacOS \
  Apps/LocalCode/StaticInlineNode/Fixtures/virtual-node-child-smoke.js
```

The Vite fixture additionally points to an exact materialized native-free
graph. It becomes a hermetic repository test when the project dependency
materializer lands.

## Next implementation steps

1. Implement the exact project dependency materializer and
   `.localc/node/support-lock.json`.
2. Make the native-payload scanner and substitution catalog hermetic Bazel
   tests.
3. Promote vanilla Vite, React+Vite, and VitePress graphs from temporary npm
   staging to repository-owned install fixtures.
4. Run the same suite on a physical device and measure memory/performance.
5. Design a generic synchronous child transport only if supported tools need
   `spawnSync`/`execFileSync`; do not add an esbuild-specific shortcut.
6. Consider a statically linked native fallback only after an exact Wasm path
   fails a device compatibility or performance gate.
