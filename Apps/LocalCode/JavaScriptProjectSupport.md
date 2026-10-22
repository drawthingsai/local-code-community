# JavaScript and Node.js Project Support in Local Code

Survey and architecture notes, 2026-07-17.

This document combines the runtime discussion around Node.js, Deno, Bun, and
JavaScriptCore with a survey of representative browser projects. The purpose is
to define what "comprehensive Node.js project support" should mean on iOS and
to identify which parts require a JavaScript runtime, a package manager, native
tool adapters, or only a browser preview.

## Executive conclusion

The main finding is that this is not one problem:

1. A **browser preview** runs the final HTML, CSS, JavaScript, images, and
   WebAssembly.
2. A **project build environment** installs packages and turns source such as
   TypeScript, TSX, Markdown, and framework components into those browser
   artifacts.
3. A **Node.js-compatible runtime** supplies JavaScript execution and Node APIs.
4. A **native tool layer** supplies tools such as esbuild, Rolldown,
   Lightning CSS, Sharp, and framework compilers that npm packages normally
   download as executables or native addons.

Supporting item 3 does not automatically provide item 4. This is the most
important correction to the initial runtime-only framing.

The recommended direction is:

- Ship static project preview independently and early. Several sophisticated
  demos need no Node.js process after they have been built.
- Use a Node 24 LTS-era runtime as the primary long-term compatibility target.
  Existing Node projects should see actual Node semantics where iOS permits
  them.
- Integrate the runtime with Local Code's existing project-scoped
  `ios_system` environment rather than pretending iOS has general-purpose
  processes.
- Start package installation with npm and pure JavaScript. Browser-targeted
  WebAssembly can run in the preview, and Node-side WebAssembly can run through
  V8's DrumBrake interpreter. Require an explicit, tested host declaration for
  Node Wasm packages rather than assuming JIT-compiled Node behavior. Disable
  lifecycle scripts by default and reject downloaded native code.
- Materialize exact, tested Wasm providers in each project's `node_modules`
  under the dependency names expected by the project. Pair that installation
  policy with one generic virtual `node` child bridge; do not add
  package-specific runtime shims for esbuild, Rollup, or Vite. Keep statically
  linked native implementations as measured fallbacks, not the default path.
- Run a WebContainers-in-`WKWebView` feasibility spike in parallel. It may be
  the fastest way to demonstrate npm and Vite, but it has iOS version, memory,
  embedding, and commercial-license questions.
- Treat Bun as a worthwhile second native spike because it uses
  JavaScriptCore and includes a package manager and bundler. Do not assume that
  using JavaScriptCore makes the rest of Bun portable to iOS.
- Treat Deno's permissions and package execution design as useful references.
  Deno itself uses V8, Rust, and Tokio and does not currently offer an iOS
  target, so it does not remove the hard porting work.

## Terminology corrections

### `npx` does not generate HTML

`npx` is npm's package executable resolver and runner. What happens depends on
the executable:

- `npx create-vite` scaffolds source files.
- `npx vite build` invokes Vite to create deployable assets.
- `npx vitepress build docs` invokes VitePress to compile Markdown pages to
  HTML.

Local Code therefore needs package resolution, `bin` entry-point execution,
and the capabilities of the selected tool. Implementing a command named
`npx` alone is not enough.

### Vite and VitePress are different layers

[Vite](https://vite.dev/) is a development server and frontend build tool. A
normal React single-page application built by Vite often has one HTML shell
whose content is rendered in the browser.

[VitePress](https://vitepress.dev/guide/what-is-vitepress) is a Vue-based
static-site generator built on Vite. It is not a React tool. Its current guide
requires Node.js 22 or newer and states that each Markdown file is compiled to
a corresponding HTML file. React-oriented static content alternatives include
[Docusaurus](https://docusaurus.io/) and [Astro with React/MDX](https://docs.astro.build/en/guides/integrations-guide/react/).

### Deno 2.x is not JavaScriptCore-based

The current Deno release at the time of this survey is
[2.9.3](https://github.com/denoland/deno/releases/tag/v2.9.3). Deno describes
itself as built on [V8, Rust, and Tokio](https://github.com/denoland/deno).
It is not based on JavaScriptCore.

### Runtime compatibility and toolchain compatibility are separate

A runtime may correctly implement `fs`, `path`, `Buffer`, ESM, CommonJS, and
`package.json`, yet still fail a build when a package tries to load:

- a platform-specific `.node` addon;
- a downloaded native executable;
- a binary selected by an optional platform package;
- `node-gyp`, Rust, Go, C, or C++ compilation;
- a real child process or daemon.

That distinction appears repeatedly in the surveyed projects.

## Survey method

For deployed demos, the page HTML and production assets were inspected. For
public projects, the repository, `package.json`, lockfile choice, scripts, and
relevant configuration were inspected. Production bundles can establish what
the browser executes, but cannot always prove the exact source build tool.
Inferences are labeled as such.

The sites and repositories can change after the survey date.

## Project survey

| Project | Browser artifact | Source/build requirements | Local Code implication |
| --- | --- | --- | --- |
| [fly.pieter.com](https://fly.pieter.com/) | Large HTML document, direct Three.js and NippleJS scripts, WebGL, Web Audio, WebSocket, browser storage | Public deployed output does not expose a framework build; multiplayer and geo-IP services are remote | Static preview is sufficient for the frontend artifact. npm is not required to run it. |
| [macos27.kimi.page](https://macos27.kimi.page/) | Hashed JS/CSS assets mounted at `#root`; React, Zustand, Lucide, and Tailwind fingerprints | Source repository/build manifest was not found; a Vite-shaped output is plausible but not proven | Built output is static. Rebuilding the TSX source would require a React/TypeScript/CSS toolchain. |
| [PuruVJ/macos-web](https://github.com/PuruVJ/macos-web) | Static Svelte/PWA output | pnpm, Svelte 5, TypeScript 6, Vite 8, image tools, service-worker tooling | A strong modern frontend fixture. It requires Node 22+ and multiple native tool paths. |
| [daedalOS](https://github.com/DustinBrett/daedalOS) | Next static export containing browser JS/WASM applications | Yarn, Next 15, React 19, TypeScript, custom Node prebuild scripts, Webpack configuration, tests | Rich static output, but a broad and framework-specific source build. |
| [98.js](https://github.com/1j01/98) | Checked-in HTML, CSS, JS, and assets | npm is mainly used for local serving, file-index generation, spelling, and Playwright tests | Preview can work before npm support. Development commands are a useful pure-JS/process-bridge fixture. |
| [v86](https://github.com/copy/v86) | JavaScript and WebAssembly x86 emulator | Source build also needs Make, Rust/Wasm, compatible Clang, Java for optimized Closure output, and Node.js | Consuming its prebuilt browser/npm artifacts is in scope. Rebuilding the emulator from source on iOS is not. |
| [Puter](https://github.com/HeyPuter/puter) | Browser GUI plus a substantial server platform | Node 24+, npm workspaces, backend services, native packages, databases, and worker tooling | Defines the boundary between a frontend project and a self-hosted platform. Local Code should not promise full local deployment. |

These projects are requirement probes, not named product-support targets.
Release gates should use small repository-owned fixtures for tools such as
esbuild, Vite, React, and VitePress. A project's visual theme or application
domain is not part of the support contract.

### fly.pieter.com

The deployed flight simulator identifies itself as made with Three.js. The
page inspected on the survey date was approximately 494 KB of HTML and inline
JavaScript. Its primary local scripts were:

```html
<script src="/assets/three.min.js"></script>
<script src="/assets/nipplejs.min.js"></script>
```

The page uses the global `THREE` API directly, including `THREE.Scene` and
`THREE.WebGLRenderer`. It also uses browser APIs such as gamepad input,
`localStorage`, Web Audio, fetch, and a WebSocket connection to a remote game
server.

Findings:

- The deployed frontend is not evidence that a Node runtime is needed.
- Static serving plus a capable `WKWebView` is enough to execute the frontend.
- Multiplayer remains dependent on the remote backend.
- A generated single-file or low-build web project is a valuable first-class
  Local Code use case, not merely a fallback.

Pieter Levels' [project write-up](https://levels.io/fly-pieter-com-vibecoded-flight-simulator/)
provides authorship and project context, while the deployed page provides the
technical evidence above.

### macos27.kimi.page

The deployed root page contains a `#root` element and one hashed module bundle
plus one hashed stylesheet. On the survey date the assets were approximately
2.42 MB of JavaScript and 84 KB of CSS.

The JavaScript bundle contains:

- React and React DOM `createRoot`;
- embedded source-path metadata such as `src/App.tsx`, `src/main.tsx`, and many
  app-specific `.tsx` components;
- Zustand persistence middleware;
- Lucide component code;
- browser features including persistent storage, audio, camera/microphone
  capture, and media recording.

The CSS contains the standard `--tw-*` variable family associated with
Tailwind output. The hashed module layout resembles Vite output, but without a
source manifest or public repository that remains an inference.

Findings:

- Local Code can preview the production artifact without Node.
- Rebuilding the apparent TSX source requires package installation, JSX/TS
  transformation, CSS processing, and bundling.
- Camera, microphone, media playback, and permission handling are preview
  concerns. They are independent of the build runtime.
- Production bundles are not a substitute for a source project when the goal
  is editable local development.

### PuruVJ/macos-web

The current [`package.json`](https://github.com/PuruVJ/macos-web/blob/main/package.json)
uses pnpm and includes Svelte 5, TypeScript 6, Vite 8, PWA tooling, and
`vite-imagetools`.

This small manifest exposes several important compatibility layers:

- `vite-imagetools@10.0.1` requires Node 22 or newer.
- It directly depends on `sharp`, a native image-processing package.
- Vite 8 uses the Rust-based Rolldown bundler and includes Lightning CSS.
- Vite 8 itself requires Node 20.19+ or 22.12+, while this project's image
  plugin raises the effective floor to Node 22.
- The package manager is pnpm, so npm-only lockfile support is not
  comprehensive support for this project.

Sharp 0.35 publishes a WebContainers-specific Wasm package in addition to
desktop native packages. That is encouraging for a WebContainers spike, but it
does not provide a generic iOS Node addon.

This is the best surveyed "hard modern frontend" fixture. If it builds in Local
Code, a substantial amount of the proposed provider and virtual-process layer
is working.

### daedalOS

The current [`package.json`](https://github.com/DustinBrett/daedalOS/blob/main/package.json)
uses Yarn scripts, Next 15, React 19, TypeScript, numerous browser-side Wasm
packages, and custom Node prebuild scripts. Its
[`next.config.js`](https://github.com/DustinBrett/daedalOS/blob/main/next.config.js)
sets `output: "export"`, so the production result is static even though the
source build uses Next and Webpack.

Findings:

- A static final artifact can come from a large Node build graph.
- Framework compilation, custom Webpack plugins, package aliases, asset rules,
  and prebuild scripts all matter.
- Next's compiler/native package path needs its own compatibility test.
- Playwright browser installation and test execution should not be implied by
  successful application builds.
- Browser-side Wasm packages are useful and in scope even when their original
  source toolchains are not.

### 98.js

The repository checks in its browser source and assets. Its
[`package.json`](https://github.com/1j01/98/blob/master/package.json) uses npm
for a live server, a watched filesystem index, linting, dependency refresh,
and Playwright tests.

Findings:

- The application can be previewed directly without a compilation step.
- `npm start` is still a useful test of package `bin` resolution, concurrent
  scripts, watching, signals/cancellation, and local HTTP serving.
- Playwright's downloaded browsers and real process model are outside the
  initial iOS support contract.

### v86

v86 translates x86 machine code to WebAssembly at runtime. Its repository
provides prebuilt `libv86.js`/Wasm releases and an official npm package for
embedding in Vite, React, Next, or Webpack projects.

Its documented source build requires Make, Rust with a Wasm target, compatible
Clang, Java for optimized builds, and Node.js. Tests add still more native
tools.

Findings:

- "Can use v86 in a web project" is a reasonable Local Code goal.
- "Can rebuild v86 from source" is not a reasonable Node support goal.
- Prebuilt JavaScript/Wasm packages are an important compatibility category.

### Puter

Puter's current root
[`package.json`](https://github.com/HeyPuter/puter/blob/main/package.json)
requires Node 24+, uses npm workspaces, starts a Node backend, and explicitly
allows selected lifecycle scripts for packages including native database,
image, and worker components.

Findings:

- Current real projects already require Node 24, not the Node 18 version in the
  latest Node.js Mobile release.
- Selective lifecycle-script policy is normal even outside iOS.
- Editing or building a separable browser package may be possible.
- Running the complete backend, databases, workers, and service topology
  should be an explicit unsupported case rather than an accidental promise.

## What the survey changes

### Static preview should precede npm

fly.pieter.com and 98.js demonstrate that sophisticated projects can run from
checked-in browser files. macos27 demonstrates that built React output also
needs only static serving. Local Code can provide substantial value before it
can build every source graph.

### Package-manager diversity matters

The sample includes npm, pnpm, and Yarn. A project cannot always be safely
converted to npm because lockfiles, workspace layouts, peer dependency
resolution, patches, and `resolutions`/overrides can change behavior.

The implementation can start with npm, but the compatibility contract should
say so. pnpm and Yarn should later be supplied as pinned, app-tested CLIs rather
than silently translated.

### Native build tools are ordinary frontend dependencies

The difficult packages are not rare backend-only addons:

- Supported Vite releases bring esbuild plus Rollup, or Rolldown and
  Lightning CSS, depending on the pinned version.
- Next has a framework compiler/native package path.
- Image pipelines commonly use Sharp.
- Playwright and Tauri bring platform executables even when they are not needed
  for the browser build.

The package installer must classify packages and the runtime must have a
curated native-tool strategy.

### Browser WebAssembly is more valuable than source-build breadth

Projects such as v86, ffmpeg.wasm, Stockfish, and browser QuickJS can be useful
inside the preview without their source compilers being present on iOS. The
support contract should favor consuming app-bundled browser artifacts, plus
downloaded assets permitted by policy, over pretending to provide a Unix build
machine. This observation applies to `WKWebView`; it does not imply that
JITless embedded Node can instantiate the same modules.

### Browser capability is a separate test surface

The surveyed sites use WebGL, Web Audio, WebSocket, gamepads, service workers,
cross-origin isolation, camera/microphone capture, media recording, and
persistent browser storage. A build can succeed while the preview still fails.
Runtime tests and `WKWebView` tests need separate fixture suites.

## Runtime options

| Option | Engine and compatibility | iOS reality | Recommended role |
| --- | --- | --- | --- |
| Embedded Node.js | V8 and actual Node core semantics | Node.js Mobile proves static iOS/V8 builds with JIT disabled, but its latest release is Node 18 and mobile APIs remain constrained | Primary long-term compatibility target, forward-ported to Node 24 LTS |
| Deno 2.x | V8, Rust, Tokio, broad Node/npm compatibility, built-in permissions | Official binaries cover macOS, Linux, and Windows, not iOS; the full CLI/runtime is a large port | Design reference; optional later runtime only if an iOS port becomes maintainable |
| Bun | JavaScriptCore, Node compatibility, package manager, `bunx`, native bundler | Official platforms are macOS, Linux, and Windows; no iOS target; its native runtime is much more than JSC | Second native feasibility spike and possible curated builder |
| Custom JavaScriptCore layer | Apple's system engine and public embedding API | Easy engine access, but Node modules, package loading, streams, npm, process behavior, and tools must be recreated | Lightweight scripting only, not comprehensive Node projects |
| WebContainers | Browser-hosted Node environment and command model | Safari/iOS 16.4+ support is beta; `WKWebView`, memory, file sync, headers, and licensing require proof | Fast parallel product/feasibility spike |

### Embedded Node.js

[Node.js Mobile](https://github.com/nodejs-mobile/nodejs-mobile) is important
evidence, not a ready dependency:

- Its iOS build creates static libraries and starts V8 with JIT disabled.
- Its documentation says the runtime expects one instance per app process and
  should run on a background thread separate from the WebView.
- It documents that `child_process` APIs creating real processes encounter
  mobile permission limits.
- Native addons work only when cross-compiled and bundled for the target.
- Its latest published release is
  [Node 18.20.4](https://github.com/nodejs-mobile/nodejs-mobile/releases/tag/v18.20.4),
  while Node 18 is end-of-life and surveyed projects require Node 22 or 24.

Node 24 is the current LTS line and is the appropriate compatibility target.
The practical work is to forward-port or recreate the mobile build patches,
then maintain them against an LTS release.

The primary advantage is semantic: existing Node projects and npm CLIs are
written for Node. We avoid implementing a second compatibility layer before
encountering iOS-specific differences.

#### Node 24 vendoring investigation

The official Node.js Mobile releases end at Node 18.20.4, so a Node 24 vendor
has to start from an unpublished port. Three active lines were compared:

| Port | Node base | Finding |
| --- | --- | --- |
| [`gmaclennan/nodejs-mobile`](https://github.com/gmaclennan/nodejs-mobile), recipe commit `9eec30ebe09e4146bc557740da02baae88051721` | 24.19.0 | Patch-oriented mobile port with device/simulator CI and an explicit upstream-upgrade workflow. Its build-relevant patches are the basis of the checked-in Node 24.22.1 port. |
| [`origami-ltd/nodejs-mobile`](https://github.com/origami-ltd/nodejs-mobile), commit `6ea1971786a98e3a320e68ed254ecb88c12bdca6` | 24.18.0 | Earlier full-source port used to establish the original Node 24 baseline and retained as an independent audit cross-check. |
| [`Acurast/nodejs-mobile`](https://github.com/Acurast/nodejs-mobile) | 24.5.0 | Useful independent evidence that Node 24 can be carried to iOS, but farther behind the selected LTS point release. |

Local Code now pins the official Node 24.22.1 source archive and SHA-256 in
[`Vendors/NodeJS/build_nodejs_mobile.sh`](../../Vendors/NodeJS/build_nodejs_mobile.sh).
The checked-in mobile patch is a reviewed rebase of the Gmaclennan recipe's
build changes, while a separate Local Code patch owns the embedding host and
DrumBrake integration.
The generated static XCFramework has `ios-arm64`, `ios-arm64-simulator`, and
`macos-arm64` slices, small ICU, SQLite, and the full Node library closure. It
excludes host tools and test archives. The local source patch lowers the
fork's deployment target from iOS 17.0 to Local Code's iOS 15.4 target, wires
DrumBrake into Node's GYP build, and ports its stale V8 APIs and ARM64
assumptions to Node 24. Node 24's libuv implementation itself requires at
least iOS 14 because it uses `preadv` and `pwritev`. The native macOS slice
targets macOS 13.5, matching the Node 24 build setting.

The vendor deliberately follows the PythonIOS generated-runtime model. A
single recipe builds pinned source plus the checked-in patch in a clean
temporary tree, emits a committed payload and provenance manifest, and can be
checked independently by `Vendors/NodeJS/verify_nodejs_mobile.sh` or
`//Vendors/NodeJS:NodeMobileVendorTests`. Bazel imports the result with
`apple_static_xcframework_import`; the XCFramework contains static `.a`
archives rather than a dynamic runtime. Future JavaScript/npm payloads belong
in project storage. Any future native fallback must be statically linked and
registered at app build time, not downloaded as a `.node`, `.dylib`, or
dynamic framework.

The full build is large: after native-symbol encapsulation, the device,
simulator, and macOS slices are approximately 89 MiB, 90 MiB, and 90 MiB
respectively, and the three-slice XCFramework is approximately 269 MiB. The
aggregate is always-linked to preserve Node/V8 static registrations. A
production size pass should disable genuinely unused Node features while
retaining the private native-dependency boundary. Size work must rerun the
complete core-module fixture because missing registration objects often
appear only at runtime.

The original port was audited against pristine Node 24.18.0 before vendoring;
the current mobile patch was rebased against pristine Node 24.22.1.
The files that had carried unsafe stale-Node-18 changes in earlier ports are
either upstream-identical (`deps/uv/src/unix/fs.c` and
`deps/uvwasi/src/uvwasi.c`) or have a narrowly scoped mobile delta. The
remaining changes disable the V8 trap handler on iOS, guard mobile environment
cloning, expose mobile version metadata, and add the iOS cross-build wiring.
An unmodified source compile completed for arm64 iOS; the fork's own packaging
then failed only because it requested the removed `libbase64.a`. The Local
Code recipe replaces that stale manifest with the actual Node 24 static link
closure.

The first JITless runtime hid `WebAssembly`. This mattered beyond optional Wasm
packages: Node's global `fetch` uses Undici, which lazily instantiates a
WebAssembly build of llhttp. DrumBrake provides a source-level V8 interpreter
path selected by `--wasm-jitless`, so no `fetch` shim is required.

The first ARM64 DrumBrake build still failed because its JS-to-Wasm wrapper
loaded the exported function index through a 32-bit register. This iOS build
disables V8 pointer compression, and its tagged Smi payload occupies the upper
32 bits. Every nonzero function index was therefore read as zero, causing
Undici to invoke the wrong llhttp callback. Loading the complete tagged Smi
through `x15` fixes nonzero exports, imported-function index spaces, and the
loopback `fetch` fixture. DrumBrake compatibility and performance across the
broader Wasm ecosystem still need systematic testing.

On iOS the runtime reports `process.platform === "ios"`; the native macOS
slice reports `"darwin"`. The iOS value correctly prevents npm and loaders
from selecting downloaded `darwin-arm64` binaries, but it also means packages
whose `os` metadata or JavaScript branches only recognize `darwin`, `linux`,
and `win32` will reject or miss iOS. The installer must own those exact
substitution cases instead of globally changing the platform string.

This establishes a maintainable Node 24 runtime and `ios_system` command
baseline. Canonical `npm` and `npx` now run a checksum-pinned upstream npm
payload through that host, and project setup places `node_modules/.bin` on
`PATH` without setting `NODE_PATH`. The host supplies disposable command
environments, process-exit interception, stream redirection, session-scoped
environment/cwd forwarding, and command-scoped cancellation. The strict
project materializer, exact Wasm substitution catalog, support lock, and
native-payload scanner remain separate work.

The real `LocalCode` application links `ios_system`, PythonIOS, and NodeMobile
directly into its executable. PythonIOS and NodeMobile both cover `ios-arm64`,
`ios-arm64-simulator`, and `macos-arm64`; their independent OpenSSL and other
native dependency symbols are private inside the Node aggregate so both
runtimes link into one executable without cross-binding. The full Local Code
simulator and device applications build with both runtimes. The standalone
Node simulator build and runtime suite also pass. The
`StaticInlineNodeMacOS` Bazel target also links and runs the same Node 24,
core-module, DrumBrake WebAssembly, loopback HTTP, and global `fetch` suite
against the vendored `macos-arm64` archive.

Initial tool fixtures now provide stronger evidence than the runtime suite
alone. Exact native-free graphs using `esbuild-wasm` and
`@rollup/wasm-node` built vanilla Vite, React+Vite, and VitePress projects
through NodeMobile on macOS. Direct Rollup Wasm and esbuild-wasm CLI fixtures
also passed on an arm64 iOS simulator. The first full Vite simulator build
reached HTML transformation and failed at `spawn node ENOENT`. After adding a
generic virtual Node-child bridge, the unchanged Vite `7.1.2` graph passed on
both macOS NodeMobile and the iOS simulator. React+Vite `7.1.2` and VitePress
`1.6.4` also passed through the bridge on macOS. No esbuild-specific runtime
branch or new native library was needed. Exact versions, negative
native-package runs, and limitations are recorded in
[`NodeMobileSupportBundle.md`](NodeMobileSupportBundle.md#executable-evidence).

### Deno 2.x

Deno's current
[Node and npm compatibility documentation](https://docs.deno.com/runtime/fundamentals/node/)
reports support for nearly every `node:` module, npm packages, `package.json`,
CommonJS, local `node_modules`, and Node-API. As of Deno 2.8, more than 75
percent of Node's own test suite passes.

That makes Deno a credible desktop alternative to Node. It does not mean Deno
has a small implementation surface:

- The compatibility layer implements much of Node in addition to Deno APIs.
- Native addons and tools still need FFI and platform binaries.
- Scripts can still invoke executables and `node`.
- The full product includes V8, Rust/Tokio integration, networking, filesystem,
  watchers, permissions, package management, and CLI behavior.
- `deno_core` is an embedding foundation, not the complete Deno CLI/runtime.
- Deno's [official installation assets](https://docs.deno.com/runtime/getting_started/installation/)
  cover desktop macOS, Linux, and Windows, not iOS.

[`deno x`](https://docs.deno.com/runtime/reference/cli/x/) is conceptually
similar to `npx`, and Deno's permission model is a strong reference for Local
Code. The runtime itself is not currently a shortcut to an iOS implementation.

### Bun

The current [Bun repository](https://github.com/oven-sh/bun) describes the
runtime as written in Rust and powered by JavaScriptCore. Bun combines a
Node-compatible runtime, package manager, `bunx`, script runner, and native
bundler. Its bundler handles JavaScript, TypeScript, JSX, CSS, and HTML.

This makes Bun technically attractive for Local Code-owned templates:

- one native integration could cover runtime, installation, and basic builds;
- its built-in bundler could avoid Vite for a curated React/TSX workflow;
- JavaScriptCore may fit iOS constraints better than a new V8 port.

There are still major unknowns:

- Bun publishes binaries for macOS, Linux, and Windows, not iOS.
- Its filesystem, networking, process, package-manager, transpiler, and bundler
  layers are native code and operating-system integration.
- Using JavaScriptCore does not prove that Bun can be built against the public
  iOS `JavaScriptCore.framework`; API and linkage assumptions need a spike.
- Existing projects that say `vite build` expect Vite and its plugin behavior.
  Replacing Vite with `bun build` changes semantics and cannot be transparent.

Bun is therefore a worthwhile experiment, especially for a Local Code-created
project format, but not the strongest default promise for arbitrary Node
repositories.

### Custom JavaScriptCore compatibility layer

JavaScriptCore provides JavaScript execution, not Node.js. A comprehensive
layer would still need to implement and maintain:

- ESM and CommonJS loading with Node package resolution and export conditions;
- `Buffer`, streams, events, timers, crypto, URL, and Node globals;
- filesystem and network modules;
- npm registry, semver, lockfiles, integrity checks, and package extraction;
- package `bin` resolution and scripts;
- process, signal, TTY, worker, and child-process behavior;
- TypeScript/JSX/CSS/asset transformation and framework tooling.

This is reasonable for a constrained scripting API, but it recreates too much
of Node for the stated project goal.

### WebContainers

[WebContainers](https://webcontainers.io/guides/introduction) run Node
applications and command-line tools inside a browser and explicitly target
Vite-like development environments. They provide the fastest route to a
realistic prototype.

Constraints:

- iOS/iPadOS support begins at 16.4 and remains described as beta.
- The current browser-support documentation requires `SharedArrayBuffer` and
  cross-origin isolation. The embedding page needs appropriate COOP/COEP
  behavior.
- Safari support does not prove that the same environment works reliably in
  an app's `WKWebView`.
- Mobile memory is constrained, and StackBlitz documents out-of-memory cases.
- Native addons are disabled unless a JavaScript or WebAssembly alternative
  exists.
- Production use in a commercial, for-profit product requires a
  [commercial license](https://webcontainers.io/enterprise); prototypes do
  not.
- Local Code currently supports OS versions below 16.4, so this path would be
  version-gated or require raising the deployment target.

The spike should test a real device and embedded `WKWebView`, not merely Safari.

## Existing Local Code substrate

Local Code already has much of the shell boundary an embedded runtime needs:

- [`BashTools.swift`](Sources/Agent/BashTools.swift) creates a project-scoped
  `.localc` area, configures app library/cache/project paths, binds command
  streams, sets the mini-root/current directory, and calls
  `ios_system_osh` for one fresh non-interactive OSH evaluation per tool
  call.
- [`ios_system_command_registry.c`](../../Vendors/ios_system/ios_system_command_registry.c)
  statically registers commands including `sh`, `git`, `curl`, `python`, and
  `pip`; the integration now also registers canonical `node`.
- [`ios_system.m`](../../Vendors/ios_system/ios_system.m) already applies an
  embedded-package policy: runtime pip installs are restricted to pure-Python
  wheels, and `os.system` is bridged back to `ios_system_osh`.
- [`libc_replacement.c`](../../Vendors/ios_system/libc_replacement.c) emulates
  process identifiers, `fork`, and `waitpid` over in-process command threads.

The JavaScript design should mirror the useful parts of the Python design:

- project-scoped writable paths and caches;
- static app-bundled native capabilities;
- downloaded interpreted packages where policy permits, plus browser Wasm or
  exact project-local Node Wasm substitutions with a validated host;
- explicit errors for native packages that would require downloaded executable
  code or source compilation;
- shell commands routed through a controlled command registry.

It should not assume that the existing thread-based process emulation is
automatically compatible with libuv or Node's process model.

## Proposed native architecture

### 1. Static preview service

Provide a project-root HTTP origin managed by the app and open it in an
isolated `WKWebView`.

Required behavior:

- select `index.html` or a configured output directory;
- correct MIME types, module loading, history fallback, and cache invalidation;
- console, network, and runtime error forwarding to Local Code;
- reload after file changes or completed builds;
- explicit permission handling for camera, microphone, downloads, and external
  navigation;
- configurable cross-origin-isolation headers for projects that require them;
- no privileged native app bridge exposed to untrusted project JavaScript.

This service is useful with or without Node.

### 2. `NodeRuntimeHost`

Embed one process-lifetime Node platform and serialize command requests
through a host object. Canonical `node`, `npm`, and `npx` are now registered in
`ios_system`; all three execute through the same host.

Do not repeatedly call Node's ordinary CLI `main` as if each call were a new
Unix process. Package CLIs mutate globals, install handlers, retain event-loop
work, and call `process.exit`.

The implemented host uses this isolation model:

- initialize Node/V8 once and create and tear down a fresh Node
  `Environment`, isolate, and event loop for each serialized command;
- compile the host into Node's `libnode`, clone the initialized option state
  for each command, and use Node's own option parser and normal main-module
  selection for CommonJS, ESM, eval, stdin, syntax checking, preloads, and
  other per-environment CLI modes;
- accept but ignore V8 and unknown V8-forwarded flags because V8's
  process-wide configuration was fixed when the reusable runtime initialized;
- intercept command exit without terminating the app;
- stop the owned environment on cancellation;
- supply command-scoped arguments, environment, current directory, and
  standard streams;
- key cancellation by command identifier so one shell session cannot stop a
  different queued or active Node job.

Interactive REPL input and startup-only operations such as snapshot/SEA
creation and `node --run` remain unavailable because they require ownership of
the app process rather than one disposable command environment.

This lifecycle remains a release gate: each Node update must rerun sequential,
queued-cancellation, and teardown tests.

### 3. npm and package execution

Local Code now bundles npm `11.19.1` from the pinned Node source as a signed,
checksum-validated app resource. The app extracts it transactionally into its
Library directory, while packages remain in the project and npm's cache is
stored under `<project>/.localc/node/cache`. Lifecycle scripts are disabled by
default.

The focused command test now covers `npm install` of a local pure-JavaScript
package, ordinary package imports, direct project `bin` execution, `npx`,
`npm exec`, and `npm run`. Normal Node module lookup remains authoritative, so
the app does not set `NODE_PATH`; only `<project>/node_modules/.bin` is added
to the managed command `PATH`.

The remaining production installation policy is:

- validate registry metadata, tarball integrity, semver, ESM, CommonJS,
  `package.json`, `package-lock.json`, and package `bin` links;
- preserve upstream `npm install`, `npm run`, `npm exec`, and `npx` behavior
  inside the supported process contract;
- enforce installation with lifecycle scripts disabled;
- permit pure JavaScript packages;
- permit browser-targeted WebAssembly in `WKWebView`;
- permit Node-side WebAssembly only when an exact support-catalog substitution
  declares DrumBrake or another named host and passes its conformance suite;
- reject `.node` addons, downloaded executables, and source builds unless a
  future statically linked fallback explicitly owns that package/version;
- explain the rejected package and available alternative in the error;
- make network, filesystem, and environment access visible and policy-driven.

Later compatibility:

- pinned pnpm and Yarn CLIs;
- their lockfiles and workspace layouts;
- private registries and `.npmrc` policy;
- an allowlist for audited lifecycle scripts that do not install executable
  code.

`npx` resolves a package's `bin` entry through upstream npm. Its usual
`sh -c` launch is parsed by the generic bridge without starting a shell; only
a Node shebang entry inside the allowed project roots is submitted to
`NodeRuntimeHost`. It does not require a package-specific executable or OS
child process.

### 4. Generic virtual Node-child bridge

Patch the Node child-process boundary for one safe, package-independent
operation: `spawn("node", [projectLocalJavaScriptEntry, ...])`. Run the entry
in a disposable Worker and expose virtual stdin/stdout/stderr, argv,
environment, exit status, asynchronous cancellation, and a documented signal
subset.

The first implementation now passes its lifecycle/negative fixture and a
native-free Vite `7.1.2` production build on macOS NodeMobile and an arm64 iOS
simulator. It also accepts npm's narrow asynchronous `sh -c` shape only when a
restricted parser resolves the command to a project-local Node shebang. It
rejects arbitrary commands, native executable magic, root escapes, shell
operators and expansion, detached processes, process groups, daemonization,
and IPC. It currently requires the child's cwd to equal its parent and does
not provide synchronous spawn. Those gaps must be solved generically if a
supported tool needs them.

This bridge is not an esbuild adapter. esbuild works because its exact Wasm
package is present at the ordinary project-local `esbuild` path and its
ordinary JavaScript code asks Node to launch its normal JavaScript `bin`
entry.

### 5. Project-local Wasm substitutions and native fallbacks

The common compatibility unit is an exact `PackageSubstitution`. It records
what the project requested and which registry package is materialized at that
path in the project's own `node_modules`. It does not add a package-specific
runtime facade or move the provider into a read-only app resource.

The concrete installation, catalog identity, virtual-child contract, and
validation design is documented in
[`NodeMobileSupportBundle.md`](NodeMobileSupportBundle.md).

For example, the validated Rollup record is conceptually:

```json
{
  "id": "rollup-wasm-4.62.2",
  "consumer": {
    "name": "rollup",
    "version": "4.62.2",
    "integrity": "<registry SRI>"
  },
  "provider": {
    "name": "@rollup/wasm-node",
    "version": "4.62.2",
    "integrity": "<registry SRI>"
  },
  "materializedPath": "node_modules/rollup",
  "host": "node-drumbrake",
  "targets": ["ios-arm64", "ios-arm64-simulator", "macos-arm64"],
  "tests": ["rollup-api", "vite-7.1.2-build"]
}
```

The production record also includes the dependency edge, payload hashes,
license, limits, and support-catalog version. Matching remains exact; a
basename or open semver range is insufficient.

#### Substitution installation and validation

A patched npm installation should handle a substitution as follows:

1. Resolve the ordinary dependency graph and lockfile with lifecycle scripts
   disabled.
2. Match the consumer package name, exact version, integrity, dependency edge,
   and iOS target. Matching only a basename such as `sharp.node` is not
   sufficient.
3. Fetch the exact Wasm provider and verify its registry integrity. Do not
   fetch or extract the matched native executable or `.node` payload.
4. Materialize the provider's ordinary package contents at the consumer's
   expected path in staged `node_modules`; package imports and `bin` resolution
   then remain standard Node behavior.
5. Scan the completed graph by metadata and file magic before promotion.
6. Record the selection in `.localc/node/support-lock.json`, including both
   packages, integrities, payload hashes, materialized path, catalog version,
   project lock hash, and target.

Some upstream loaders branch on `process.platform` before they try to resolve
a platform package. Local Code should not globally claim to be macOS merely to
reach the `darwin-arm64` branch. The exact install record must instead select a
provider that exposes the required API on iOS.

`npm ls` should continue to show the dependency requested by the project, plus
a Local Code provider annotation. The substitution must also be visible in
build logs. It must not look like the downloaded macOS package was executed.

An unsupported version fails before running the build, for example:

```text
Unsupported native package: rolldown@1.2.0
Local Code contains rolldown-wasi-1.1.3 for rolldown@1.1.3.
Use a tested Vite version or build this project on another machine.
```

Optional-package omission and future linked-native fallbacks are separate from
project-local Wasm substitution.

#### esbuild through the generic bridge

The Node API for esbuild does not call a Node-API addon. It locates a
platform-specific executable, starts it with `child_process.spawn`, and speaks
a private binary protocol over stdin/stdout. The protocol starts with an exact
version handshake. The `esbuild-wasm@X.Y.Z` package, materialized at the
project's expected `esbuild` path, launches:

```text
esbuild --service=X.Y.Z --ping
```

and rejects a service that reports a different version.

No package-specific service adapter is needed. The installer places the exact
`esbuild-wasm` package at `node_modules/esbuild`, including its ordinary
`bin/esbuild` JavaScript entry. The generic virtual-child bridge validates that
entry and starts it in a disposable Node Worker with in-memory pipes,
cancellation, and cleanup.

A statically linked Go service remains a fallback if the Wasm service fails
physical-device compatibility or performance gates.

This exact path now passes Vite `7.1.2` through NodeMobile on macOS and an
arm64 iOS simulator. The asynchronous API is covered. esbuild's synchronous
API uses `execFileSync`, which the initial generic bridge does not implement;
that remains an explicit gap instead of an esbuild-only shortcut.

Each protocol version needs an explicit record. Select the first exact version
from a repository-owned esbuild fixture and the Vite release chosen for the
initial support matrix. Add another version only when another supported
toolchain lockfile requires it. Separate project-local package paths and
Workers can represent multiple exact protocol versions, but that case still
needs an explicit fixture before it is supported.

#### Validated Wasm providers and candidates

Several important tools now publish an official Wasm package with the same
version as the native package. They are valuable conformance targets before
maintaining an iOS Rust/C++ port. The Wasm file and its glue code would be
installed into the project after registry-integrity validation and exposed at
the dependency path expected by that exact graph.

`@rollup/wasm-node@4.62.2` now passes a direct bundle through DrumBrake on
macOS and an arm64 iOS simulator. Each additional provider still needs proof
for its required Wasm features, WASI imports, workers, memory use, and
teardown. This remains an explicit installer substitution: npm does not
automatically know that `rollup` should mean `@rollup/wasm-node`, and some
native-package loaders never attempt their Wasm sibling.

| Consumer package | Exact provider and status | Required installation behavior |
| --- | --- | --- |
| `rollup@4.62.2` | `@rollup/wasm-node@4.62.2`, validated on macOS and iOS simulator | Materialize the provider at `node_modules/rollup`; validate `.`, `parseAst`, `loadConfigFile`, `getLogFilter`, and the CLI. This avoids `@rollup/rollup-*-*`, whose addon only supplies parser/hash functions. |
| `rolldown@1.1.3` | `@rolldown/binding-wasm32-wasi@1.1.3` | Materialize the exact fallback package expected by Rolldown and prevent its WebContainer fallback from invoking pnpm. |
| `lightningcss@1.32.0` | `lightningcss-wasm@1.32.0` | Materialize at the exact consumer path only after its Node Wasm entry preserves `transform`, `transformStyleAttribute`, `bundle`, `bundleAsync`, helpers, and feature constants. |
| `@tailwindcss/oxide@4.3.3` | `@tailwindcss/oxide-wasm32-wasi@4.3.3` | Provision the package; the generated Oxide loader already falls back to it. Validate file scanning and worker teardown. Tailwind 3 does not need this substitution. |
| `@parcel/watcher@2.5.6` | `@parcel/watcher-wasm@2.5.6` | Materialize at the consumer path only if the official Wasm package passes API parity. It recursively crawls directories and is less efficient, so cap roots and watcher count. |
| Next `15.5.5` SWC loader | `@next/swc-wasm-nodejs@15.5.5` | Provision the exact fallback and prevent Next from downloading it on demand. This only solves the compiler binding; it does not solve Next workers, Webpack, image optimization, or server behavior. |
| `sharp@0.35.0` | `@img/sharp-wasm32@0.35.0` | Accept only if an exact project-local graph preserves Sharp's public API without a package-specific runtime branch. Test the operations used by `vite-imagetools`; enforce input-pixel and memory limits. |

These packages are not small in aggregate. The inspected compressed npm
tarballs range from roughly 0.8 MB for Rollup Wasm to 6.4 MB for Next SWC
Wasm. Project installation should fetch only providers selected by that
project's exact graph.

There are three plausible hosts, and none should be hidden behind the word
"Wasm":

| Host | What Local Code would ship | Suitable execution shape | Main limitation |
| --- | --- | --- | --- |
| `NativeWasiHost` | A statically linked interpreter/runtime plus explicit WASI preview-1 filesystem, clocks, randomness, stdio, and thread support | Direct C ABI around compute-heavy Wasm modules; potentially usable by synchronous Node facades | A runtime still has to be selected, audited for App Store-safe interpreter mode, and proven against NAPI/WASI thread glue. This is a substantial native dependency. |
| `WebViewWasmHost` | An isolated, non-preview `WKWebView` with a signed JS bootstrap and message protocol | Asynchronous service-style tools whose inputs and outputs can be serialized | It cannot transparently satisfy synchronous Node APIs or direct plugin callbacks. Shared memory needs cross-origin isolation, and project filesystem access must be mirrored or RPC-backed. |
| `JavaScriptWasmInterpreterHost` | A pure-JavaScript Wasm interpreter loaded inside Node | Small, unthreaded modules used infrequently | Performance is much lower, and current threaded WASI/NAPI packages such as Rolldown and Oxide are not plausible first targets. |

The first host spike should use one small synchronous package and one
service-shaped package. It must prove API semantics, filesystem access,
cancellation, peak memory, and repeated teardown before any of the table
entries is marked supported. If no host passes, the correct implementation is
an exact statically linked fallback or an unsupported-package error, not an
unqualified Wasm substitution.

The required runtime capabilities are also package-specific:

- Rolldown and Tailwind Oxide use `wasm32-wasip1-threads`-style NAPI/WASI glue
  and require a host with shared memory, workers, and cancellation; a simple
  JavaScript interpreter shim is insufficient.
- Lightning CSS uses a Node-specific Wasm entry and Asyncify for async
  bundling.
- Sharp's Wasm build includes image codecs and libvips, so it has a much larger
  attack and memory surface than a syntax transformer.
- Next SWC being loadable does not imply that `next build` is compatible.

The materialized provider must run upstream API tests and fixture builds.
Similar function names are not enough evidence of drop-in compatibility.

#### Statically linked native fallback

Use this only when no official Wasm package exists, no viable host can
preserve the package API, or measured Wasm memory/performance is unacceptable.

For a linked fallback, Local Code compiles the audited Rust/C++ addon and its
dependencies for device and simulator as part of the app. It exposes each
addon initializer under a unique symbol. A patched Node module loader maps an
exact generated facade to that initializer instead of calling `dlopen` on a
downloaded `.node` file.

For example, a native Lightning CSS fallback could generate a facade whose
exports are initialized by
`localcode_lightningcss_1_32_0_init(napi_env, exports)`. The mapping is valid
only for `lightningcss@1.32.0` and only after its upstream Node API tests pass.
The same mechanism could host Rolldown or Sharp, but each remains a separate
exact fallback with separate native dependencies and limits.

This does not create general Node-API support. `better-sqlite3`, `canvas`,
`bcrypt`, `keytar`, `workerd`, and an arbitrary package built with `node-gyp`
do not become loadable because one statically linked NAPI-RS addon works.

#### Exact first support matrix

Support is defined by repository-owned tool fixtures, not by an application's
visual design:

| Tool/fixture | Native-shaped dependencies | Required Local Code treatment |
| --- | --- | --- |
| esbuild JavaScript API and CLI | An exact service process | Materialize same-version `esbuild-wasm` at `node_modules/esbuild` and run its normal JavaScript `bin` through the generic bridge. Async build/transform, CLI output, version handshake, cancellation, and teardown are required; sync APIs remain a separate generic transport problem. |
| Vanilla Vite production build | esbuild service plus Rollup 4 for a selected Vite 5-7 release | Use the simulator-validated same-version esbuild/Rollup substitutions selected by the pinned lockfile. Skip optional `fsevents` and use polling or app file notifications. |
| React + TypeScript on the same Vite release | The Vite graph plus the selected React plugin's exact dependencies | Reuse the vanilla Vite substitutions and prove TSX transformation, CSS/assets, production output, and browser startup. Any additional native-shaped dependency found in the pinned lockfile needs its own record. |
| VitePress Markdown build | Its pinned Vite graph plus Vue and Markdown compilation | Build a small multi-page documentation site and validate generated HTML, navigation, code highlighting, assets, and links. Reuse substitutions only when exact versions match. |
| Vite 8 | Rolldown and Lightning CSS; image plugins may add Sharp | Treat official Wasm providers as host-validation candidates, not automatically runnable packages. Use a separately linked fallback only where WASI threads, synchronous APIs, or memory requirements cannot be hosted. |
| Tailwind 4 projects | `@tailwindcss/oxide` platform binding | Evaluate the exact official Oxide WASI package only with a proven threaded host; otherwise use a linked implementation. Do not require this for Tailwind 3 projects. |
| Selected Next static export | `@next/swc-*`; optional Sharp; workers and framework build behavior | Evaluate the exact Next SWC Wasm fallback and Sharp behind a proven host, then classify remaining process/worker requirements. Do not label Next supported based on SWC alone. |
| Parcel/Nx projects using `@parcel/watcher` | C++ watcher addon and platform packages | Use a same-version project-local watcher Wasm provider only after API parity; expect slower crawling and constrain watched roots. |

#### Rules that are not substitutions

An `OptionalDependencyRule` may omit a package only when the parent package has
a tested fallback:

- omit `fsevents` and use polling or app-owned file notifications;
- omit Tauri/Electron platform tooling when invoking only a separate web build;
- avoid `sass-embedded` when the project accepts the pure-JavaScript `sass`
  package.

That is different from claiming to provide the omitted package. Local Code
must not silently alias `sass-embedded` to `sass` for a project that imports
the embedded protocol directly.

The following remain explicit unsupported boundaries, not vague future
substitutions:

- Playwright/Puppeteer browser downloads and browser-process control;
- Tauri and Electron application packaging;
- `node-gyp` and arbitrary C/C++/Rust/Go compilation;
- arbitrary `.node` addons;
- desktop services such as `workerd`;
- backend packages such as `better-sqlite3`, `canvas`, and `keytar` unless each
  receives its own audited static fallback.

Provider selection must be exact and observable. Silently substituting a
different bundler, compiler, image implementation, or package version can
change output and break plugins.

### 6. Build and preview orchestration

Treat a production build as the first supported framework workflow:

1. install under the package policy;
2. run the configured build script;
3. identify the output directory;
4. serve it with the app preview service;
5. map build errors back to source files.

Persistent dev servers, file watching, HMR, and port forwarding can follow.
They are valuable, but they add runtime-handle cleanup and app lifecycle
problems that a one-shot static build avoids.

## Support contract

"Comprehensive" should describe a large useful subset honestly, not claim to
be a desktop Unix environment.

### Level A: static web projects

Supported:

- HTML, CSS, JavaScript modules, images, fonts, and Wasm;
- checked-in dependencies and remote browser dependencies;
- project-local HTTP preview and browser diagnostics.

Representative fixtures: fly.pieter.com-style output and 98.js.

### Level B: Node/npm JavaScript projects

Supported:

- modern ESM and CommonJS;
- common Node core modules within the iOS sandbox;
- `package.json`, npm lockfiles, package `bin` entry points, and scripts;
- pure-JavaScript npm dependencies;
- browser Wasm in preview and exact project-local Node-side Wasm substitutions
  only when their declared host has passed conformance tests;
- one-shot Node CLIs and simple loopback HTTP servers;
- TypeScript/JSX when supplied by a supported JavaScript/Wasm tool.

Explicit limitations:

- no true OS process tree;
- no arbitrary native addon or downloaded executable;
- no unrestricted lifecycle scripts;
- no daemon that survives the app lifecycle.

### Level C: curated frontend toolchains

Supported after exact provider and host validation:

- selected Vite ranges;
- React, Vue, and Svelte templates;
- TypeScript, JSX/TSX, PostCSS, Tailwind, and supported Sass paths;
- VitePress and selected React/MDX static generators;
- selected static-export framework configurations;
- the generic virtual Node-child bridge plus same-version `esbuild-wasm`
  substitutions for supported esbuild versions;
- same-version Wasm-provider or linked-native fallback records for selected
  Rollup, Rolldown, Lightning CSS, Sharp, Tailwind Oxide, and framework
  compiler versions.

Compatibility is versioned. "Vite 8 supported" should mean a tested matrix of
Vite, plugins, providers, and hosts, not every future plugin.

### Level D: interactive development

Later support:

- loopback development servers;
- file watching;
- HMR/reload;
- port discovery;
- stopping and restarting cleanly across app background/foreground changes.

### Outside the contract

- arbitrary `.node` addons or downloaded platform binaries;
- `node-gyp`, arbitrary C/C++/Rust/Go build toolchains;
- Docker, virtual machines, system services, and package managers for an
  emulated full operating system;
- Tauri/Electron packaging;
- Playwright's downloaded browsers;
- unrestricted subprocesses, daemons, and process groups;
- complete local deployment of service platforms such as Puter.

Users can still edit these repositories and preview or build separable browser
artifacts when those artifacts fall into a supported level.

## Security and App Store constraints

The current Apple Developer Program License Agreement section 3.3.1(B) says
that interpreted code may be downloaded if it does not change the app's
primary purpose, bypass signing/sandbox/security, or create an app storefront.
It separately describes an exception for programming environments intended
for learning. If Local Code intended to rely on that exception, the current
text also requires:

- downloaded code to occupy no more than 80 percent of the viewing area,
  except where Apple documentation permits otherwise;
- a reasonably conspicuous indicator that the user is in a programming
  environment;
- no store or storefront for other code or applications;
- downloaded source to be completely viewable and editable, without
  precompiled libraries or frameworks included in that downloaded code.

This supports further product and legal analysis; it is not an automatic
approval for the proposed design, and Local Code may not qualify for the
learning-focused exception merely because it can edit code.

Engineering consequences:

- all linked native fallback code must be compiled into and signed with the
  submitted app;
- project-local Wasm providers must be integrity-verified, scanned, visible in
  the support lock, and permitted by the final product/legal policy; they must
  never be treated as native executable code;
- npm installation must reject native executable payloads rather than run
  them;
- downloaded JavaScript source should remain visible and editable;
- package browsing should not become an application storefront;
- project code must stay in the app container and must not bypass sandbox
  controls;
- the project preview must not receive a privileged native bridge;
- Local Code's advertised purpose, UI treatment, and package behavior need
  review against the exact agreement used for submission.

The agreement can change, so this must be rechecked before implementation and
submission.

## Feasibility spikes

Run the same small acceptance suite against native Node, WebContainers, and
Bun where possible. This gives comparable evidence instead of architecture
arguments based only on engine choice.

### Spike A: Node 24 on iOS

Current baseline:

- checksum-pinned Node.js 24.22.1 source plus reproducible mobile patches and
  a static XCFramework recipe;
- clean arm64 device and arm64 simulator slices, imported through Bazel;
- successful Bazel device and simulator link builds at the app's iOS 15.4
  minimum;
- a passing iOS 26.5 simulator run covering CommonJS, ESM, `Buffer`, crypto,
  zlib, streams, temporary-file I/O, `node:sqlite`, small ICU, and loopback
  `node:http`;
- measured runtime identity:
  `{"node":"24.22.1","platform":"ios","arch":"arm64","intl":"78.3"}`;
- passing DrumBrake fixtures for function zero, a nonzero exported function,
  and an export whose index follows an imported callback;
- a successful global `fetch` against the loopback `node:http` server;
- passing environment-context and virtual-child tests, plus successful
  reusable-host version probes for Node 24.22.1 and npm/npx 11.19.1;
- the full reusable `ios_system` gate passes its package install and nested-npx
  cases, then is killed at the `_npx`-cached tarball case, which fails the same
  way with the previous 24.20.0 runtime;
- successful full Local Code simulator and device builds with PythonIOS and
  NodeMobile linked into the same executable.

Still prove in the runtime host and on a physical device:

- runtime behavior on Local Code's minimum supported iOS version; the current
  iOS 15.4 result is a compile/link result, while execution was tested on iOS
  26.5;
- clean background-thread startup and shutdown on a physical device;
- remote HTTPS `fetch`, DNS, proxy, certificate-store, cancellation, and
  streaming behavior beyond the loopback parser fixture;
- a pure-JS npm package;
- a package `bin` invocation;
- memory and cold-start measurements.

### Spike B: WebContainers in `WKWebView`

Prove on physical iPhone and iPad hardware:

- boot inside the app's actual `WKWebView`;
- project file import/export and incremental sync;
- COOP/COEP and `SharedArrayBuffer`;
- npm install and package scripts;
- current simple Vite and VitePress builds;
- current `macos-web` install/build attempt;
- preview URL routing;
- memory behavior across reload, backgrounding, and a second project;
- offline behavior and cache size;
- commercial license feasibility.

### Spike C: Bun on iOS

Before attempting broad compatibility, prove:

- whether Bun can use an iOS-compatible/public JavaScriptCore linkage;
- static arm64 compilation without prohibited runtime code generation;
- filesystem, networking, event loop, and package cache in an app container;
- sequential command isolation;
- `bun install`, `bunx`, and `bun build` for a small React/TSX project;
- which Node compatibility tests fail specifically because iOS lacks
  processes or native addons.

### Shared fixture ladder

Use increasingly difficult fixtures:

1. One static HTML/Three.js-style project.
2. One pure-JS Node CLI with ESM and CommonJS dependencies.
3. `npx` execution of a pure-JS package.
4. Direct esbuild JavaScript API and CLI builds.
5. A vanilla TypeScript/Vite production build.
6. A React/TypeScript/Vite production build and browser startup.
7. A small multi-page VitePress Markdown build.
8. PostCSS, supported Tailwind, and supported Sass paths.
9. A browser-targeted Wasm dependency consumed from npm.
10. A Vite development server and HMR after command teardown is reliable.
11. Expected, well-explained failures for an arbitrary native addon, source
    build, and downloaded executable.

Record install success, build success, preview success, native-package
classification, time, peak memory, disk usage, and cleanup behavior separately.
Surveyed third-party applications may be run as exploratory stress tests, but
they are not release gates and do not define the support contract.

## Recommended sequence

1. Keep the static preview service and browser fixture suite independent from
   Node support.
2. Keep the implemented canonical `node`, bundled `npm`/`npx`, project
   `.bin` path, and virtual Node-child command tests as the foundation.
3. Implement project-local npm materialization with lifecycle scripts disabled,
   exact Wasm substitutions, a support lock, and native-payload scanning.
4. Extend the passing sequential command-isolation suite to project A/project
   B installer fixtures.
5. Promote the validated esbuild/Rollup graph and vanilla Vite and React+Vite
   builds to hermetic macOS, simulator, and physical-device gates.
6. Validate the pinned VitePress production build through the same mechanism.
7. Evaluate Rolldown and Lightning CSS providers for a minimal Vite 8 fixture.
   Add a linked fallback only where a proven Wasm host cannot satisfy threads,
   synchronous APIs, memory, or performance.
8. Validate supported PostCSS, Tailwind, Sass, and image-processing paths.
9. Add pnpm/Yarn and lockfile fixtures.
10. Add persistent dev servers, watchers, and HMR only after command teardown
    is reliable.

As of the implementation spike, the likely long-term architecture is embedded
Node 24 plus `ios_system`, a strict project installer with exact Wasm-provider
records, and one generic virtual Node-child mechanism. WebContainers remains a
useful comparison, Deno does not currently reduce the iOS port enough to lead,
and Bun is best evaluated as a focused builder/runtime experiment rather than
assumed to be a drop-in answer.

## Primary sources

Runtime and platform:

- [Node.js release status](https://nodejs.org/en/about/previous-releases)
- [Node.js Mobile repository](https://github.com/nodejs-mobile/nodejs-mobile)
- [Node.js Mobile FAQ](https://github.com/nodejs-mobile/nodejs-mobile/blob/main/doc_mobile/FAQ.md)
- [Node.js Mobile iOS build notes](https://github.com/nodejs-mobile/nodejs-mobile/blob/main/doc_mobile/BUILDING.md)
- [Gmaclennan Node 24 patch recipe](https://github.com/gmaclennan/nodejs-mobile/tree/9eec30ebe09e4146bc557740da02baae88051721)
- [Origami Node 24.18 audit cross-check](https://github.com/origami-ltd/nodejs-mobile/tree/6ea1971786a98e3a320e68ed254ecb88c12bdca6)
- [Acurast Node.js Mobile fork](https://github.com/Acurast/nodejs-mobile)
- [Deno repository](https://github.com/denoland/deno)
- [Deno Node/npm compatibility](https://docs.deno.com/runtime/fundamentals/node/)
- [Deno installation targets](https://docs.deno.com/runtime/getting_started/installation/)
- [Bun repository](https://github.com/oven-sh/bun)
- [Bun bundler documentation](https://bun.com/docs/bundler)
- [Bun installation targets](https://bun.com/docs/installation)
- [WebContainers introduction](https://webcontainers.io/guides/introduction)
- [WebContainers browser support](https://webcontainers.io/guides/browser-support)
- [WebContainers native-addon limitations](https://webcontainers.io/guides/troubleshooting)
- [WebContainers commercial usage](https://webcontainers.io/enterprise)
- [Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/)

Tooling:

- [Vite 8 announcement and requirements](https://vite.dev/blog/announcing-vite8)
- [VitePress getting started](https://vitepress.dev/guide/getting-started)
- [esbuild installation model](https://esbuild.github.io/getting-started/)
- [Vite 8.1.3 package metadata](https://registry.npmjs.org/vite/8.1.3)
- [Rollup 4.62.2 package metadata](https://registry.npmjs.org/rollup/4.62.2)
- [Rollup 4.62.2 Wasm package metadata](https://registry.npmjs.org/%40rollup%2Fwasm-node/4.62.2)
- [Rolldown 1.1.3 package metadata](https://registry.npmjs.org/rolldown/1.1.3)
- [Rolldown 1.1.3 WASI binding metadata](https://registry.npmjs.org/%40rolldown%2Fbinding-wasm32-wasi/1.1.3)
- [Lightning CSS 1.32.0 package metadata](https://registry.npmjs.org/lightningcss/1.32.0)
- [Lightning CSS 1.32.0 Wasm package metadata](https://registry.npmjs.org/lightningcss-wasm/1.32.0)
- [Sharp 0.35.0 package metadata](https://registry.npmjs.org/sharp/0.35.0)
- [Tailwind Oxide 4.3.3 package metadata](https://registry.npmjs.org/%40tailwindcss%2Foxide/4.3.3)
- [Next 15.5.5 package metadata](https://registry.npmjs.org/next/15.5.5)
- [Next 15.5.5 SWC Wasm package metadata](https://registry.npmjs.org/%40next%2Fswc-wasm-nodejs/15.5.5)
- [Parcel Watcher 2.5.6 Wasm package metadata](https://registry.npmjs.org/%40parcel%2Fwatcher-wasm/2.5.6)

Surveyed projects:

- [fly.pieter.com](https://fly.pieter.com/)
- [fly.pieter.com project write-up](https://levels.io/fly-pieter-com-vibecoded-flight-simulator/)
- [macos27.kimi.page](https://macos27.kimi.page/)
- [PuruVJ/macos-web](https://github.com/PuruVJ/macos-web)
- [DustinBrett/daedalOS](https://github.com/DustinBrett/daedalOS)
- [1j01/98](https://github.com/1j01/98)
- [copy/v86](https://github.com/copy/v86)
- [HeyPuter/puter](https://github.com/HeyPuter/puter)
