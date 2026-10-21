# Offline audio effects

`runtime.ts` adapts the pinned HyperFrames graph to the exporter's PCM bridge.
The DSP, parameter normalization, automation scheduler, and tail calculations
come from `Apps/HyperFramesCLI/Upstream` at
`b66739820762551e0af268d19568cd8a790a35f2` (Apache-2.0; see `LICENSE.hyperframes`).
The shared scheduler has one source patch: a linear ramp whose first point is
after playback begins holds its initial value until that point. This fixes the
same behavior in preview and export; other upstream implementations are unchanged.

Generate the checked-in Swift string with the esbuild version pinned by
`Apps/HyperFramesCLI/Worker/package-lock.json`:

```sh
ESBUILD_MODULE="$PWD/Apps/HyperFramesCLI/Worker/node_modules/esbuild" \
  node Libraries/HTMLVideoExporter/AudioEffects/build.mjs
```

The Swift library embeds this script, so both the standalone command and the
embedded command have identical behavior without locating external resources,
starting Node, or invoking another command.

`HTMLVideoAudioEffects` runs the bundle in an isolated `WKContentWorld` on the
exporter's existing file-backed WKWebView. AVFoundation prepares local audio
with trim, loop, and pitch-preserving rate changes. A reader transfers 48 kHz
float PCM in bounded messages; Web Audio processes one clip or group at a time.
Intermediate CAFs remain float so boosts and group sums can exceed full scale
before the downstream fader. The final audio/video encoder performs encoding.

Order: prepared clip → clip FX → clip volume → clip fades → group sum → group FX
→ group volume → final mix. Clip/group faders use the upstream +12 dB gain ceiling;
boosted clips and clips with fades use floating-point processing even without
an FX chain. Rate changes (constant or automated) also take this bounded PCM path:
native final export can otherwise emit pitch-conversion samples beyond the track's
time range.
Clip fades use upstream's fade rules and the original clip duration, multiplying
volume automation after effects. Hidden clips, ancestors, and groups suppress audio.
Effect automation and fades use the clip's local clock, including
visibility cuts. Clips are processed from their beginning before their output is
trimmed, preserving effect history at negative starts and visibility cuts. Group
automation uses composition time. Delay/reverb tails use
upstream's bounded tail calculation (maximum five seconds) and are clipped at
the output duration. Worklet behavior is upstream behavior, including the
pitch shifter's approximately 50 ms latency. Static worklet parameters remain
static; only parameters supported by the upstream scheduler can be automated.

## Audio contract

These rules govern both the native dry path and offline effects path. The page
supplies authored metadata and sampled timeline volume; it does not play audio.

| Concern | Rule |
| --- | --- |
| Clocks | With authored start `S` and composition time `T`, clip-local time is `T - S`. Clip FX, volume, and fades use that clock. Group FX and volume use composition time starting at zero. |
| Source preparation | Source time integrates the rate lane over clip-local time, then adds the source trim. Looping wraps within the source remainder after trim. Rate changes preserve pitch and do not compress the volume/fade clock. |
| Visibility | Bound source input at the effective clip/source/ancestor end. Trim processed output before `max(0, visibleStart)` without restarting the clip clock or shortening its authored fade duration. FX tails can continue after the input ends. |
| Clip history | Process from the clip's beginning, including a negative-time prefix, then trim the processed result. Tail-producing FX may remain audible after the input ends, including when the input is entirely before time zero. |
| Group history | Sum the audible member contributions on the composition clock before group FX. A group begins at composition zero; it does not reconstruct member audio discarded before that boundary. Moving stateful FX from a clip to its group is therefore not generally equivalent. |
| Automation | Hold the first value before the first point and the last value after the last point. Between points, preserve the authored interpolation/curve. Explicit volume automation replaces sampled timeline volume and static gain. Without a lane, sample author timeline volume at captured frames and interpolate between samples. |
| Processing order | Source trim/rate/loop → clip FX → clip volume → clip fades → visibility/output trim → group sum → group FX → group volume → final mix. Clip input ends at the effective source/ancestor end; an FX tail can extend past that input end, bounded by the output. |
| Levels and fades | Static gain clamps at +12 dB, automation uses its normalized range, and fades multiply the resulting fader. Keep intermediates floating-point so mixing and faders do not add an integer clamp before final encoding. |
| Muting | Hidden clips, ancestors, and groups contribute no audio or effect tail. Unrelated tracks remain unaffected. |
| Equivalence | An identity clip FX chain or identity group must preserve the dry envelope, timing, and level. Compare stateful clip cuts with a full clip's corresponding output; do not apply that invariant to a group moved across composition zero. |

`verify_audio_contract.py` tests these interactions with explicit gain formulas
and geometric sums of delayed tone pulses, without using the production scheduler
as its oracle. Its dry/identity-FX/group matrix covers offsets, negative starts,
visibility intersections, source trim, rate, and loop preparation. Separate cases
combine volume precedence, boosts, fades, groups, delayed first points, curved/via
lanes, and stateful tails. The existing effects and rate suites cover DSP builders,
source-time integration, invalid input, and cancellation in more detail.

The Web Audio input and rendered output are whole-clip buffers. Sequential
processing bounds simultaneous allocations to one clip/group, but memory still
scales with that clip/group's duration and channel count. Transfers and CAF writes
are chunked; malformed chains and rendering failures fail the export. There is
no dry-audio fallback. Cancellation releases native readers, browser state, and
intermediate files. Progress in PCM transfer refreshes the export timeout.

Verification:

```sh
python3 Apps/HTML2VideoCLI/Tests/verify_audio_effects.py /path/to/html2video
python3 Apps/HTML2VideoCLI/Tests/verify_audio_contract.py /path/to/html2video
python3 Apps/HTML2VideoCLI/Tests/build_catalyst.py
python3 Apps/HTML2VideoCLI/Tests/verify_audio_effects.py \
  /tmp/HTML2VideoTest.app/Contents/MacOS/HTML2VideoTest --catalyst
python3 Apps/HTML2VideoCLI/Tests/verify_audio_contract.py \
  /tmp/HTML2VideoTest.app/Contents/MacOS/HTML2VideoTest --catalyst
python3 Apps/HTML2VideoCLI/Tests/verify_colors.py /path/to/html2video --audio-fx
```

Tests measure decoded exported audio: all 16 effects, custom worklets, EQ,
compression/gating, octave shift, channel separation, clip/group automation,
negative starts, visibility cuts, effect history, clip fades, ancestor/group muting,
effect tails, loops/rates, float headroom, compiled group instance IDs, malformed inputs, and
audio-phase cancellation.
UIKit coverage uses Catalyst; an iOS build separately checks app integration.
