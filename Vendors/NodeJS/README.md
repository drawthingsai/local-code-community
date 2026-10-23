# NodeJS

This directory contains the generated static Node.js Mobile runtime and
embedding host used by Local Code's `ios_system` integration, plus the pinned
upstream npm command payload packaged separately from the native runtime.

Regenerate it on an Apple Silicon Mac with:

```sh
Vendors/NodeJS/build_nodejs_mobile.sh
```

This follows the same generated-vendor model as `Vendors/PythonIOS`: one
checked-in recipe starts from pinned source, applies the checked-in patches in a
clean temporary tree, builds the complete native runtime, records provenance,
and writes checksums for the committed result. The XCFramework is only a
container for static `.a` libraries; it is not a dynamic framework.

The script downloads the checksum-pinned official Node 24.22.1 source archive.
The checked-in `nodejs-mobile-ios.patch` carries the iOS, JITless V8, OpenSSL,
Abseil, and host-tool build changes forward from `gmaclennan/nodejs-mobile`
recipe commit `9eec30ebe09e4146bc557740da02baae88051721`, whose source base was Node
24.19.0. Local Code's separate source patch sets the iOS deployment target to
15.4, adds the reusable embedding host, and ports V8's DrumBrake WebAssembly
interpreter to the Node 24 GYP build. The interpreter changes account for
current V8 type representations, builds without pointer compression, and
ARM64 tagged values.

The generated `Frameworks/NodeMobile.xcframework` contains static libraries
for:

- `ios-arm64`
- `ios-arm64-simulator`
- `macos-arm64`

With the recorded Xcode 26.6 build, the encapsulated device, simulator, and
macOS slices are about 89 MiB each. The three-slice XCFramework occupies about
267 MiB. These are not a production
size target. The macOS slice targets macOS 13.5, matching the Node 24 build's
deployment setting.

Mac Catalyst arm64 uses a generated object from the macOS archive, following the
PythonIOS Catalyst import. `replatform_node_for_catalyst.sh` changes only the
platform load command with the shared Mach-O rewriter, preserving private symbols
and compact unwind. It does not use a zippered macOS/Catalyst relocatable link,
which Xcode 27.1 rejects for this archive.

The build is the full Node configuration with small ICU, SQLite, inspector
support, V8's JITless runtime setting, and DrumBrake selected by
`--wasm-jitless`. Explicit interpreter bounds checks are enabled. Node startup
snapshots and the Node code cache are disabled. The source checkout and
intermediate objects remain outside the repository under `/private/tmp`.
GoogleTest and other host-only archives are deliberately excluded from the
aggregate library. In particular, `libgtest_main.a` cannot be included in an
always-linked iOS target because it defines a second `main`.

The final aggregate is collapsed into one relocatable object. Only
`node_start` and the four command-lifecycle functions
`node_mobile_prepare_command`, `node_mobile_run_command`,
`node_mobile_cancel_command`, and `node_mobile_finish_command` remain public;
Node's V8, libuv, OpenSSL, ICU, SQLite, compression, and other native symbols
are private. This boundary is required because PythonIOS and NodeMobile carry
independently tested OpenSSL releases. It prevents either runtime from binding
to the other's static dependency implementation.
Any future static Node-API addon or native adapter that needs Node internals
must be an input to this aggregate before encapsulation, with its registrar
included there. It cannot be linked afterward against hidden N-API symbols.

The vendor now includes the deterministic
`Resources/NodeMobile/Commands/npm-11.19.1.zip` payload from the pinned Node
source. It supplies canonical npm/npx command code, but does not by itself
grant general npm ecosystem compatibility:

- ordinary child processes and downloaded executables cannot run on iOS;
- downloaded `.node` addons cannot be loaded;
- the strict project materializer, Wasm substitution catalog, and
  native-payload scanner are app integration concerns;
- V8 runtime code generation is disabled;
- WebAssembly runs through DrumBrake rather than JIT-compiled Liftoff or
  TurboFan code, so compatibility and performance still need broader testing.

The npm/npx payload is packaged as a signed app resource and extracted into
the app container after checksum validation; it is not linked into
`NodeMobile.xcframework`. Any supported native package adapter must be
compiled into the submitted app's static libraries and registered at build
time, following PythonIOS's treatment of native extension modules. Downloaded
`.node`, `.dylib`, or dynamic-framework payloads are not an extension
mechanism for this integration.

## `ios_system` embedding host

`NodeRuntimeHost.cpp` is compiled into Node's own `libnode` target so it uses
the exact internal option layout selected by that build. It initializes Node
and V8 once for the app process and reuses that platform across serialized
commands. Every `node` invocation is parsed by Node's command-line parser and
gets a fresh `CommonEnvironmentSetup`, isolate, event loop, argv, environment,
working directory, and redirected streams. Node therefore selects its normal
CommonJS, ESM, eval, print, stdin, syntax-check, test-runner, and preload entry
points instead of the embedding host reimplementing those modes.

V8 flags are accepted but ignored after process initialization because V8's
process-wide configuration is fixed to the vendored JITless settings. The
same applies to unknown options that Node forwards to V8. Interactive REPL
input and process-startup operations such as snapshots, SEA creation, and
`node --run` are not available in the reusable host.

`process.exit` becomes a command status instead of terminating the app.
Native process spawning, `process.execve`, and process signaling are rejected
with `ENOTSUP` in the packaged C++ bindings on all three platforms. A signal-0
probe of the app's own PID remains available. These guards apply to every
Environment, including Workers with `execArgv: []` and commands without the
optional virtual-child preload. Worker-backed virtual children retain their
existing launch and cancellation behavior.

Cancellation is keyed by a command identifier, so stopping a queued Node job
cannot stop a different shell session's active command. `ios_system` prepares
stable command state before publishing the Node pthread as the session root.
Cancellation sets a sticky flag on that state and synchronously calls
`node::Stop` once an Environment is attached. The run call observes
cancellation both before and after attaching the Environment, and cleanup
releases the state after the run returns. This matches the Python integration's
register, publish, interrupt, and unregister lifecycle without polling or a
startup callback.

`ios_system` registers canonical `node`, `npm`, and `npx` commands. npm and npx
are thin wrappers around their upstream JavaScript entries and execute through
the same Node host. `ios_system` publishes the configured npx JavaScript entry
to the generic virtual Node-child bridge, allowing nested `spawn("npx", ...)`
to run without an OS executable. The Local Code app supplies that preload as a
signed resource, sets each command's allowed project root, and places
`<project>/node_modules/.bin` on `PATH`. Normal module resolution does not
require `NODE_PATH`. The policy-enforcing project installer remains separate
work; it does not require another native Node runtime.

## Fetch and WebAssembly

Node 24's global `fetch` uses Undici, whose HTTP parser is a WebAssembly build
of llhttp. The first JITless baseline hid `WebAssembly`, so Undici could not
initialize. Enabling DrumBrake exposed the API, but the initial ARM64 port
loaded `WasmExportedFunctionData::function_index` through `w15`. This Node iOS
configuration disables V8 pointer compression, so a Smi's payload is in the
upper 32 bits of its 64-bit tagged value. The 32-bit load therefore turned
every nonzero exported function index into zero. Undici then called the wrong
llhttp callback and reported `TypeError: fetch failed`.

The ARM64 wrapper now loads the complete tagged Smi through `x15`. Focused
tests cover a nonzero exported function and a module whose function index space
starts with an imported callback. With that fix, Undici dispatches the correct
callbacks and `fetch()` succeeds against a loopback `node:http` server. This is
a source-level V8 integration; no JavaScript `fetch` shim is used.

The source port remains provisional. Its build changes are now based on the
patch-oriented `gmaclennan/nodejs-mobile` recipe, which makes the upstream
Node point-release rebase reviewable independently from Local Code's embedding
and DrumBrake changes. The earlier `origami-ltd/nodejs-mobile` Node 24.18.0
port remains an audit cross-check. Local Code's own device and simulator tests
remain the authority for this generated artifact.

See [`UPGRADING.md`](UPGRADING.md) for the point-release rebase procedure,
source-of-truth boundaries, and required validation matrix.

Validate the integration with:

```sh
Vendors/NodeJS/verify_nodejs_mobile.sh
bazel test //Vendors/NodeJS:NodeMobileVendorTests
bazel build //Apps/LocalCode:StaticInlineNode --ios_multi_cpus=arm64
bazel build //Apps/LocalCode:StaticInlineNode --ios_multi_cpus=sim_arm64
bazel build //Apps/LocalCode:StaticInlineNodeMacOS
bazel run //Apps/LocalCode:StaticInlineNodeMacOS
bazel test //Apps/LocalCode:StaticInlineNodeIOSSystemTests
bazel test //Apps/LocalCode:StaticInlineNodeVirtualChildTests
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=sim_arm64
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

For iOS, install and launch the app on a simulator or physical device. Both
the iOS app and macOS command-line probe should end with:

```text
[StaticInlineNode] suite passed
```

The Node 24.22.1 baseline passes the iOS device and simulator Bazel link
builds, the runtime suite on an arm64 iOS 26.5 simulator, and the linked macOS
arm64 runtime suite. The suite exercises Node startup, CommonJS, ESM,
`Buffer`, crypto, zlib, streams, temporary-file I/O, `node:sqlite`, small ICU,
loopback `node:http`, DrumBrake WebAssembly dispatch, and a successful global
`fetch`. The environment-context, virtual-child, and process-policy tests also
pass, and the reusable `ios_system` test confirms Node 24.22.1 plus npm/npx
11.19.1 startup, a local package install, and top-level and nested npx. That
test is then killed at the `_npx`-cached tarball case, which fails the same way
with the previous 24.20.0 runtime; that case must be rerun after the harness
regression is repaired.
The previous Node 24.18.0 pre-OSH baseline passed repeated
CommonJS/ESM/eval/stdin commands, state isolation, cancellation, nested npx,
and the combined PythonIOS/NodeMobile OpenSSL encapsulation check. The full
Local Code simulator and device applications build with PythonIOS and
NodeMobile in the same executable.

A physical-device runtime run and runtime tests on the minimum supported iOS
and macOS versions are still required before treating this as product-ready.
On iOS the port reports `process.platform === "ios"`; the native macOS slice
reports `"darwin"`. Package metadata and native loaders that only recognize
`"darwin"` therefore need explicit iOS compatibility handling; Local Code
must not globally pretend to be macOS. Production integration also needs a
size pass by disabling genuinely unused Node features while retaining the
private native dependency boundary.

`NODEJS_BUILD_INFO` records source and toolchain provenance. `SHA256SUMS`
records the committed payload. Rebuilding with the recorded Xcode version is
the supported reproduction path; byte-for-byte identity across different
Xcode releases is not assumed. The standalone verifier checks payload
integrity, static linkage, slice architecture, header identity, and the exact
public C API without requiring a Node rebuild. Do not commit the external
source tree, intermediate Node build output, or build logs from `/private/tmp`.
