# HyperFrames command

`hyperframes` is a native command with a bundled JavaScript worker. It is registered with ios_system for the app and agent CLI, and available as a macOS executable:

```sh
bazel build //Apps/HyperFramesCLI:hyperframes
bazel-bin/Apps/HyperFramesCLI/hyperframes init /tmp/my-video --non-interactive
bazel-bin/Apps/HyperFramesCLI/hyperframes check /tmp/my-video --json --snapshots
bazel-bin/Apps/HyperFramesCLI/hyperframes snapshot /tmp/my-video --at 1 --zoom '#title'
```

Implemented commands: `init`, `lint`, `compositions`, `timeline`, `preview`, `present`, `check`, and `snapshot`. `--help` lists their options and the compiled-page export sequence using `html2video`. The app command, agent CLI, and standalone executable share this help text. Scaffolding is noninteractive and includes local GSAP, runtime, player, and slideshow assets. Existing project directories are never overwritten. Preview and presentation are foreground processes; `--no-open` suppresses opening their URL.

## Execution boundaries

`hyperframes --version` prints the fixed command version `0.8.78`, matching the pinned upstream source. This native diagnostic works without starting Node or locating the runtime assets.

The native command creates one short-lived NodeMobile environment for upstream JavaScript rules and compilation. Private stdin/stdout pipes carry JSON requests and responses. User output is a separate protocol message; diagnostics go to the command's stderr. There is no HTTP RPC endpoint and no native command launched from JavaScript.

The worker uses the upstream linter, HTML bundler, composition/timeline parsers, check pipeline, motion rules, contrast calculations, browser audit scripts, and slideshow harness. Swift handles WebKit page creation, evaluation, deterministic seeking, media metadata, PNG capture, and contact sheets. Embedded videos use the same AVFoundation frame bridge as export, including Canvas/WebGL source substitution.

The preview HTTP server binds to loopback, checks canonical file containment, supports byte ranges, and recompiles HTML on each request. The worker that starts it exits. Later page requests create short-lived compiler workers, leaving NodeMobile free between requests. Ctrl-C or Bash cancellation stops the server and any owned work.

`html2video` remains a separate native command. PNG capture does not invoke it or encode/decode an intermediate video. Export and snapshot share `HTMLVideoPage`, `HTMLVideoMediaBridge`, and `HTMLPageSnapshot` in `Libraries/HTMLVideoExporter`.

## Color and capture

`HTMLPageSnapshot` owns the common WebKit capture boundary and named sRGB color space. UIKit snapshots request the needed backing resolution. AppKit transparent capture uses WebKit's PDF API because `takeSnapshot` flattens alpha onto white. The PDF is rasterized at the requested output density. Neither path changes the CSS viewport or enlarges an already captured low-resolution image.

PNG encoding preserves the sRGB profile and alpha. The exporter still writes its existing matching sRGB pixel-buffer attachments and transfer-function tag. Contact sheets use the same sRGB space with an opaque dark background.

Zoom defaults to 3×, supports a selector or `x,y,width,height`, and preserves viewport layout. Missing selectors fail; collapsed/invisible regions are skipped. Snapshots go to `snapshots/`, including a contact sheet. Check overviews use upstream labeled annotations; error crops keep upstream `finding-NN-<code>.png` names.

## Upstream and build

`Upstream/` contains source files from HyperFrames commit `b66739820762551e0af268d19568cd8a790a35f2`. Only files needed for the worker and browser runtime are retained. The sole source patch is in `packages/core/src/audio/audioFxAutomation.ts`: preserve the initial hold before a delayed first keyframe's linear ramp. Both the preview runtime and offline exporter use this scheduler. All other retained upstream files are verbatim. The three browser audit scripts come from that same commit. The player and slideshow distribution bundles are from `hyperframes@0.8.77`; GSAP is 3.15.0 and retains its license header. The skill is bundled under `Apps/LocalCode/Resources/Skills/hyperframes/`; `Vendors/HyperFrames/VERSION` records its upstream repository and revision.

The explicit adaptations are in `Worker/build.mjs` and `Worker/platform.mjs`:

- Extract the reusable browser driver and composition/slideshow functions without their desktop command/server dependencies.
- Inject native browser operations and an AVFoundation media probe instead of Puppeteer and ffprobe subprocesses.
- Adapt HEVC diagnostic guidance to native export and browser preview support.
- Retain authored JavaScript comments instead of using a native esbuild transform solely to strip comments.
- Use linkedom's own canvas fallback for Node-side DOM parsing; real drawing happens in WebKit.
- Remove telemetry and inject check dependencies. Use a monotonic clock for audit timings.
- Report HDR promotion inspection as unavailable; do not fabricate a successful inspection.

Rebuild with the pinned build-only dependencies:

```sh
cd Apps/HyperFramesCLI/Worker
npm ci --ignore-scripts
npm run build
```

The app ships the generated files under `Resources/HyperFrames`, not `node_modules`. Runtime does not require Sharp, libvips, Chrome, FFmpeg, esbuild, or native Node addons. `LICENSE.hyperframes` and `Resources/HyperFrames/THIRD_PARTY_LICENSES.txt` record upstream/bundled dependencies; GSAP's distribution header links its license.

## Verification

`HyperFramesCLILib` declares the resource group as runtime data, so any Apple app linking the command inherits `HyperFrames/` in its bundle. App targets do not need to repeat that resource dependency.

```sh
python3 Apps/HyperFramesCLI/Tests/verify.py bazel-bin/Apps/HyperFramesCLI/hyperframes
python3 Apps/HyperFramesCLI/Tests/verify_colors.py bazel-bin/Apps/HyperFramesCLI/hyperframes
python3 Apps/HyperFramesCLI/Tests/build_uikit_probe.py /tmp/HyperFramesCapture.app
python3 Apps/HyperFramesCLI/Tests/verify_colors.py bazel-bin/Apps/HyperFramesCLI/hyperframes /tmp/HyperFramesCapture.app/Contents/MacOS/UIKitCapture
bazel test //Apps/LocalCode:CLIParityTests --test_filter=CLIParityTests.testHyperFramesThroughBashTool
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
python3 Apps/HyperFramesCLI/Tests/verify_bundle.py bazel-bin/Apps/HyperFramesCLI/hyperframes /path/to/LocalCode.ipa
```

`verify_bundle.py` checks the built app's complete runtime payload, then runs version/help, scaffolding, lint, and capture in a temporary macOS bundle using those resources. Its working directory and executable are outside the checkout, and Bazel environment fallbacks are removed, so repository resources cannot mask a packaging omission. It also accepts an unpacked `.app`.

FFmpeg is used only to create independent test media. The color tests decode reference videos and output PNGs through AVFoundation/CoreGraphics into sRGB. They cover opaque/half-alpha CSS patches, untagged/sRGB/BT.709/BT.601 video, and 3× crops, including an assertion that the PNG carries an sRGB profile. A vector-stripe fixture proves 3× captures preserve detail unavailable at 1×. The command tests cover real lint/check failures, motion sidecars, contrast, caption zones, nested compositions, native media probing, preview refresh, byte ranges, containment, and cancellation.

## Export workflow

The skill saves the preview server's `/__hyperframes_composition.html` response as `.hyperframes-export.htm` in the project root, then passes that compiled page to `html2video`. This preserves nested composition compilation and project-relative assets using the existing commands. Fetch a fresh page before each export; `html2video` itself does not compile source files. The full sequence is in `Apps/LocalCode/Resources/Skills/hyperframes/guides/hyperframes-cli/references/preview-render.md`.
