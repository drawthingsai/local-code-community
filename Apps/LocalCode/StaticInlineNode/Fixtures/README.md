# NodeMobile tool fixtures

These are small, repository-owned compatibility probes for frontend tools.
They test tool behavior rather than a particular application's visual design.

The project `package.json` files are ordinary upstream-shaped manifests:

- `vite-vanilla`: Vite `7.1.2`;
- `vite-react`: Vite `7.1.2`, React `19.1.1`, and
  `@vitejs/plugin-react` `5.0.2`;
- `vitepress`: VitePress `1.6.4`.

The standalone scripts isolate provider and runtime behavior:

- `esbuild-smoke.js`: ordinary esbuild JavaScript API and CLI service;
- `esbuild-wasm-cli-smoke.js`: same-process `esbuild-wasm` CLI;
- `rollup-wasm-smoke.js`: direct `@rollup/wasm-node` API;
- `vite-wasm-smoke.js`: programmatic Vite production build;
- `esbuild-wasm-input.ts`: deterministic TypeScript input;
- `virtual-node-child-smoke.js`: generic virtual-child stdio, lifecycle,
  nested launch, constrained shell-form Node bins, cancellation, and rejection
  contract.

## Results

The 2026-07-20 exploratory run used NodeMobile 24.18.0 with
`--jitless --wasm-jitless`.

| Fixture | macOS arm64 | arm64 iOS 26.3 simulator |
| --- | --- | --- |
| Existing NodeMobile runtime suite | Pass | The previously committed baseline passes; this run rebuilt the app. |
| esbuild `0.25.9` with `@esbuild/darwin-arm64` | Pass | Not eligible: it is a Mach-O executable. |
| Vanilla Vite `7.1.2`, ordinary graph | Pass | Not eligible: the graph contains esbuild and Rollup native payloads. |
| React `19.1.1` + Vite `7.1.2`, ordinary graph | Pass | Not eligible for the same reason. |
| VitePress `1.6.4`, ordinary graph | Pass with repeated file-descriptor warnings | Not attempted. |
| `@rollup/wasm-node@4.62.2` direct API | Pass | Pass with `process.platform === "ios"`. |
| `esbuild-wasm@0.25.12` CLI | Pass | Pass with `process.platform === "ios"`. |
| Vanilla Vite with exact esbuild/Rollup Wasm aliases, before the generic bridge | Pass | Reaches HTML transformation, then fails with `spawn node ENOENT`. |
| Generic virtual Node-child contract | Pass | Pass. |
| Bundled npm `11.16.0`, top-level/nested npx, and local or `_npx`-cached pure-JS package `bin` through `ios_system` | Pass | The macOS integration harness covers the same command host used by iOS; simulator run pending. |
| The same native-free Vite graph through the generic bridge | Pass | Pass; emits HTML, JavaScript, and CSS with `process.platform === "ios"`. |
| React+Vite with exact Wasm aliases and generic bridge | Pass | Not repeated on iOS because it uses the same validated service boundary. |
| VitePress with `esbuild-wasm@0.21.5`, Rollup Wasm, and generic bridge | Pass with repeated file-descriptor warnings | Not yet attempted. |

The Wasm Vite graphs were staged with lifecycle scripts disabled and optional
native packages omitted. A file-magic scan found no Mach-O, ELF, PE, `.node`,
dylib, or shared-object payload.

The 2026-08-28 Node 24.20.0/npm 11.19.0 upgrade reran the core macOS and iOS
simulator runtime suites and the virtual-child fixture successfully. The full
`ios_system` test confirms the upgraded version commands, then stops at a
pre-existing OSH `/home/project` alias fixture before reaching its npm install
and nested-npx cases.

Host npm was used to create the temporary Vite package graphs. The
`ios_system` fixture now separately validates bundled npm/npx, a local
pure-JavaScript install with lifecycle scripts disabled, project `.bin`
lookup, ordinary package imports, direct/npx/npm-exec/npm-run launch, nested
`npx`, and a package tarball executed from the managed `_npx` cache. The
policy-enforcing project materializer and physical-device performance remain
unvalidated. Cancellation is covered by the focused virtual-child fixture;
reusable command isolation is covered by
`//Apps/LocalCode:StaticInlineNodeIOSSystemTests`.

## Harness behavior

`bazel test //Apps/LocalCode:StaticInlineNodeProcessPolicyTests` exercises the
native rejection policy in standalone Node and inside ios_system, with and
without the virtual-child preload. It covers
CommonJS/ESM child-process APIs, direct bindings, `process.execve`, signal
rejection, ordinary Workers, Workers with `execArgv: []`, and nested Workers.
The virtual-child suite independently verifies that Worker-backed launches and
cancellation still work. The ios_system suite runs Node with a closed stdout
pipe to check that EPIPE does not terminate the host.

`StaticInlineNodeMacOS` runs its baseline suite with no arguments. Additional
arguments are forwarded to the linked NodeMobile runtime, so a fixture can be
run without accidentally using the system Node executable.

On iOS, `STATIC_INLINE_NODE_SCRIPT` selects one staged JavaScript fixture.
When the simulator launches the signed app executable with arguments, those
arguments are also forwarded to NodeMobile. The signed app discovers the
generic preload under `NodeMobile/Runtime` automatically. The product app now
owns the same preload through `NodeRuntimeHost` and `ios_system`; neither path
depends on iOS process creation.

The detailed dependency and validation implications are maintained in
[`../../NodeMobileSupportBundle.md`](../../NodeMobileSupportBundle.md#executable-evidence).
