# html2video

Export a local HTML page to H.264 MP4/MOV or transparent HEVC MOV, with audio. The command is registered in the app's embedded shell and the macOS agent CLI. Invoke it through the Bash tool. NodeMobile’s current child-process bridge only accepts Node scripts, so direct `child_process.execFile("html2video", ...)` is not supported. It uses WebKit and AVFoundation, with no Chrome, FFmpeg, Sharp, or Node native addon at runtime.

```sh
html2video ./project --output ./out.mp4
html2video ./project --format mov --alpha --output ./overlay.mov
html2video ./index.html --output ./out.mp4 --fps 30000/1001 --json
html2video ./project --output ./out.mp4 --variables '{"title":"Q4 Report"}'
```

`--format` accepts `mp4` or `mov` and defaults to the output extension. `--alpha` requires MOV and selects HEVC with alpha; without it, output is opaque H.264. Page backgrounds still apply: author a transparent HTML/body/composition background for an overlay. Transparent capture uses UIKit snapshots and, on macOS, WebKit’s public transparent-PDF API (macOS 14 or later). Audio mixing preserves the alpha channel.

Capture converts page colors to sRGB. Pixel buffers and the encoded video use the same sRGB transfer function, with BT.709 primaries and YCbCr matrix, so color-managed playback preserves the page's appearance. Embedded video retains AVFoundation's interpretation of its source profile; untagged inputs can receive an inferred profile. Compare source and output in a common color space rather than comparing their raw decoded RGB values.

There is no subcommand. The input defaults to `.`; a directory must contain `index.html`. `--width`, `--height`, and `--duration` override the page's viewport dimensions and duration. Dimensions must be even integers from 2 to 8192. The exporter emits `ceil(duration × fps)` frames, sampled starting at time zero, and rounds the output duration up to a complete frame. `--timeout` limits stalled page loading, frame capture, and encoding (default 60 seconds). `--variables-file` accepts a JSON object instead of inline `--variables`. `--json` writes result metadata to stdout; progress goes to stderr. Existing output files are never overwritten. Cancellation exits with 130 and removes partial files.

`html2video --version` prints the fixed command version `1.0.0` without requiring an input or output path.

## Page contract

HyperFrames pages can use their normal root `data-composition-id`, `data-width`, `data-height`, and `data-duration` attributes. The exporter supplies render-time variables through `window.__hfVariables`, configures the export frame rate, and uses `__player.renderSeek()` when a runtime is present. Standalone compositions can register paused GSAP timelines in `window.__timelines`; the exporter seeks those timelines, CSS/WAAPI animations, and timed clip visibility. Raw external `data-composition-src` loading and per-instance variables require a compiled page with the HyperFrames runtime. This command does not compile project files or install browser libraries.

An ordinary HTML page can provide its own deterministic seek function:

```html
<script>
window.html2video = {
  width: 1280,
  height: 720,
  duration: 5,
  async seek(seconds) {
    // Set DOM, Canvas, WebGL, or animation state to this exact time.
    // Resolve only after any asynchronous drawing has finished.
  }
};
</script>
```

Declared composition dimensions (or explicit `--width`/`--height`) set the viewport before author scripts run. The exporter waits for fonts, images, seek promises, and the WebKit snapshot presentation barrier. It advances one frame at a time and keeps one captured frame in flight. Arbitrary timers and live network state are not deterministic animation clocks.

## Embedded media

Video and audio sources must be local files inside the input HTML's directory. AVFoundation decodes video frames, including source alpha. The exporter supplies them as video posters, preserving the original element's CSS layout, object-fit, transforms, and clipping. Before each page seek, it also installs decoded images for Canvas `drawImage` / `createPattern` and WebGL 1/2 `texImage2D` / `texSubImage2D` calls that receive a video element. It publishes HyperFrames’ `__render_frame__` siblings with unique render IDs, exposes decoded dimensions/readiness, and delivers `requestVideoFrameCallback` notifications before drawing. Runtime pages also use HyperFrames’ GPU re-seek hook and completion barrier, including repeated seeks to frame zero. The exporter owns `video.currentTime` through the declared clip timing; assigning it from page code does not change the exported source frame. Browser video playback is paused. Use a separate `<audio>` element for sound, including sound from the same MP4:

```html
<video src="assets/clip.mp4" muted playsinline
  data-start="1" data-duration="5" data-media-start="2"></video>
<audio id="sound" src="assets/clip.mp4"
  data-start="1" data-duration="5" data-media-start="2" data-volume="0.8"></audio>
```

Supported timing includes nested composition offsets, source trims, constant `data-playback-rate` and `data-automation` rate lanes (0.1–10), looping the source after its trim point, and clip visibility windows. Audio is mixed offline with matching offsets, trims, and rates. Linear `data-automation` volume lanes take precedence over sampled timeline `volume` changes. Clip and group volume support HyperFrames’ authoring gain range up to +12 dB (approximately 3.98×), with higher values clamped to that ceiling. Mixing adds a final native encode pass to combine picture and sound.

Audio effects use HyperFrames' `data-fx-chain` schema and shared Web Audio graph inside WKWebView. All 16 upstream effects are supported, including compressor, limiter, gate, bitcrush, and pitch-shift worklets. `data-automation` drives the parameters supported by the upstream scheduler and volume envelopes; effects run before the clip fader. `hf-audio-group` buses sum their members before applying group effects and volume, including compiled instance IDs and group mute. Delay/reverb tails extend beyond a clip's input and stop at the output duration. Intermediate audio remains floating-point through effects and group mixing. Invalid chains or processing failures fail the export. No additional command or runtime dependency is needed.

```html
<audio src="assets/voice.wav" data-start="0" data-duration="5"
  data-fx-chain='{"version":1,"nodes":[{"id":"voice","type":"compressor"}]}'></audio>
```

See `Libraries/HTMLVideoExporter/AudioEffects/README.md` for implementation, regeneration, memory behavior, and the audio-effects verification suite. The upstream pitch shifter adds approximately 50 ms of latency; static worklet parameters are not automatable.

Current limits: no `--strict-variables`. Video frame substitution covers the Canvas/WebGL calls above in the main document; worker/iframe rendering, WebGPU uploads, `VideoFrame`, and `createImageBitmap(video)` are not bridged. External media URLs and dynamic media insertion are not supported. The HyperFrames skill documents fetching the compiled composition from its preview server before invoking this command; see `Apps/LocalCode/Resources/Skills/hyperframes/guides/hyperframes-cli/references/preview-render.md`.

A rate lane overrides `data-playback-rate`. Its point times are clip-local, values interpolate logarithmically, and `curve` / `viaX` / `viaY` shape the transitions using the pinned HyperFrames semantics. Video and audio share the same integrated source-time table, including natural clip duration, trim offsets, visibility cuts, and looping:

```html
<video src="assets/clip.mp4" muted playsinline data-start="0" data-duration="4"
  data-automation='{"version":1,"lanes":[{"target":"rate","points":[{"t":0,"v":0.5},{"t":2,"v":2},{"t":4,"v":1}]}]}'></video>
```

Apply the same rate lane to the separate audio element. As in HyperFrames, audio keeps pitch by using short constant-speed slices: approximately 250 ms, capped at 240 slices per audible clip window. Each slice consumes the exact source interval from the shared table; within a slice its speed is the mean rate. Volume envelopes remain on the clip's timeline clock. This is a bounded audio approximation of the continuous ramp, while video uses the per-frame mapping directly.

## Build and verification

```sh
bazel build //Apps/HTML2VideoCLI:html2video
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
python3 Apps/HTML2VideoCLI/Tests/verify.py bazel-bin/Apps/HTML2VideoCLI/html2video
python3 Apps/HTML2VideoCLI/Tests/verify_ramps.py bazel-bin/Apps/HTML2VideoCLI/html2video
python3 Apps/HTML2VideoCLI/Tests/verify_alpha_textures.py bazel-bin/Apps/HTML2VideoCLI/html2video
python3 Apps/HTML2VideoCLI/Tests/verify_colors.py bazel-bin/Apps/HTML2VideoCLI/html2video
```

`verify_viewport.py` checks script-time viewport dimensions and media queries for landscape/portrait snapshot and export, including explicit output-size overrides.

The black-box test uses FFmpeg/ffprobe **only for verification**. It checks every decoded frame of a 10-second DOM/Canvas/WebGL/SVG/WAAPI fixture, rational frame rates, media source-frame identity through nested offsets and speed changes, AAC fades, looping, sampled volume, and silence, variable initialization, output preservation, missing assets, timeout, and cancellation cleanup.

`verify_colors.py` compares sixteen color patches after AVFoundation decoding and CoreGraphics conversion to sRGB. It covers CSS colors, alpha, audio muxing, and embedded video with untagged, sRGB, BT.709, and BT.601 profiles. Pass the UIKit host binary with `--catalyst` to repeat the same checks through UIKit. Add `--audio-fx` to exercise offline audio effects during the color checks. FFmpeg only generates the test fixtures; raw RGB comparisons across different source profiles are deliberately avoided.

`Tests/build_catalyst.py` builds a minimal UIKit host from the production exporter sources. Run its printed executable with `<input.html> <output.mp4>` to exercise the hidden attached view used by the app. This is a native integration test, not a replacement implementation.

For runtime compatibility checks, pass `--hyperframes-runtime /path/to/hyperframe-runtime.js --gsap /path/to/gsap.min.js` to `verify.py`. Validation used the HyperFrames 0.8.77 runtime and the pinned upstream GSAP asset; all 120 runtime-driven frames at 60 fps passed. This does not establish compatibility with every HyperFrames adapter.

The ramp test checks the native timing table against 2,408 source/inverse samples generated by the pinned upstream functions, then decodes 1,080 ramped video frames and measures audio pitch, source timing, and volume. Cases cover logarithmic and shaped curves, via points, normalization, trims, loops, nested visibility, negative starts, and natural duration.

Run `verify_ramps.py /tmp/HTML2VideoTest.app/Contents/MacOS/HTML2VideoTest --catalyst` after `build_catalyst.py` to repeat the ramp checks through UIKit. To regenerate the timing reference using the pinned upstream source, run `node Apps/HTML2VideoCLI/Tests/generate_rate_reference.mjs /path/to/hyperframes-checkout` with a Node version supporting TypeScript stripping. The generator reads the recorded commit directly through Git.

`verify_alpha_textures.py` uses AVFoundation to inspect the HEVC auxiliary alpha layer, since FFmpeg may decode only the opaque base layer. It checks alternating source-frame identity, transparent/partial/opaque pixels, black/white compositing, DOM video, all Canvas draw overloads, WebGL 1/2 texture uploads, frame callbacks, CSS transforms/filters, SVG, and audio mixing. Duplicate author IDs are tested with two independently timed video instances. Add `--hyperframes-runtime /path/to/hyperframe-runtime.js` to verify runtime-driven textures and asynchronous `hf-seek` completion, including the first frame. Pass the UIKit host binary with `--catalyst` to run the same checks through UIKit. The host accepts `<input.html> <output.mov> --alpha`.
