# Monkey download preview

The preview runs through `ChatWorkflow` and the same `EmbeddedDownloadController`
as an actual model download. It creates no download or model files.

The automatic review hook has been removed. Normal app launches show only real
downloads. To replay the fixture, call `ChatWorkflow.previewDownload()`
from a debugger with a workflow reference.

Available scenarios through `ChatWorkflow.previewDownload(_:)`:

- `normal`: a download with a stall and burst.
- `error`: pauses with an error at 15 seconds; tap the card's retry button to resume.
- `fast`: finishes transport in two seconds, exercising completion during the intro.

Every scenario uses the production 50% decision after the first hide. Preview
code does not override whether the second peek hides or climbs out.

The normal fixture takes 32 seconds of foreground time, including a four-second
network stall and a burst. The final animation may finish after transport does.
The close button dismisses the preview. Call `previewDownload(_:)` again to replay.
Real download / generation banners take precedence over the preview.

## Implementation

`DownloadItemController` renders its view model and keeps its original
`UIView.animate` path by default. Local Code passes `usesAnimation: false`.
`EmbeddedDownloadController` owns Advance, the real download model, and the
displayed progress. It sends one displayed view model for the fill, percentage,
and bytes, always clamped to real progress. Card spacing remains unchanged;
the monkey can overlap the labels.

At the first displayed crossing of 40%, `MonkeyAnimationController` asks its
embedded download controller to stop Advance at its current value. Its display
link drives the Lottie frame, contact
anchor, and display progress on one clock. `MonkeyAnimation` owns the testable
action sequencing. The second piece is chosen only after the first hide ends.
Both peeks and the climb use the same perch. After the climb, the bar holds on
a landing grid: the initial edge plus a whole number of the approved short
bound's distance. If necessary, the monkey waits for real progress to reach
that landing. It repeats the crouch/bound with a perched recovery, then plays
the original bound into the push stance. Every bound keeps its fixed distance;
the final step is never stretched or shortened to fit an arbitrary edge.

The monkey overlay is constrained to the progress track. Fill constraints and
the overlay update in UIKit's normal layout pass; frame updates do not force
layout. The shared download component has no monkey, transport-versus-display,
or Advance ownership state.

The 70% kick checkpoint is used at most once, and skipped if the bar has already
passed it before the approach. A push waits at its common contact pose when no
progress is available. Errors finish the current contact action and settle;
retry stands up without restarting the intro or making another random decision.
Successful model readiness is reported immediately; the workflow retains only
the banner through its ending. CLI download events currently report no outcome,
so those banners dismiss on their existing `finished` event without celebration.

The app assets are generated from the approved monkey rig, with a closed push
cycle and matching approach / rest / retry connectors:

```sh
node Art/MonkeyKungFu/lottie/export-app.mjs
bazel run //Apps/LocalCode:MonkeyAnimationTests -- \
  "$PWD/Apps/LocalCode/Resources/Animations/Monkey/monkey-motion.json"
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

`Art/MonkeyKungFu/lottie/AppNativeCheck.swift` verifies native Lottie loop and
contact-pose joins against the pinned renderer. The original HTML and Lottie
review assets remain available under `Art/MonkeyKungFu/`.
