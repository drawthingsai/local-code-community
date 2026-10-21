---
name: hyperframes-cli
description: >
  Use the HyperFrames CLI development loop: init, lint, check, snapshot, preview, present,
  compositions, and timeline. Export compositions with html2video.
  Also use when diagnosing build or render failures.
---

# HyperFrames CLI

Run the supplied command directly as `hyperframes ...` from the project directory. Export video with `html2video` using the [compiled export page](references/preview-render.md#render). A missing bundled runtime is an installation failure; restore the command's bundled resources before retrying.

## Development loop

1. **Scaffold:** `hyperframes init <project>` (centered blank).
2. **Author:** write the composition using [hyperframes-core](../hyperframes-core/GUIDE.md). To know what is on a project's timeline (tracks, clips, starts, ends, what plays), run `hyperframes timeline --json` instead of reading `index.html` and every sub-composition file: nested rows carry absolute main-timeline `absStart`/`absEnd` and their owning `file`, not just their local, per-sub-composition time. Prefer `--json` over the text form; it costs fewer tokens for the same or better correctness. See `references/upgrade-info-misc.md` for one-liners that answer common questions without reading the whole output.
3. **Get fast feedback while editing:** run `hyperframes lint` after the first HTML pass and after structural changes.
4. **Run the final gate:** run `hyperframes check`; it reruns lint before opening the browser. Do not prepend a redundant standalone lint invocation. Add `--snapshots` for annotated overview frames and finding crops.
5. **Inspect sub-compositions:** when `index.html` mounts `data-composition-src`, capture midpoint snapshots and inspect each mounted scene.
6. **Open the final preview:** run `hyperframes preview --foreground --no-open`, verify the URL returns HTTP 200, hand the preview URL to the user, and ask whether to revise or render. Keep it alive until review ends.
7. **Render only after approval:** prepare the [compiled export page](references/preview-render.md#render), then run `html2video .hyperframes-export.htm --output out.mp4`.
8. **Verify the output:** confirm the file exists and is non-empty. Compare its duration (and fps if the brief set it) to the root `data-duration`.

```bash
# Fast iteration check; repeat while authoring as needed.
hyperframes lint

# Required final gate; includes lint.
hyperframes check
hyperframes preview --foreground --no-open

# In another Bash invocation, from the project directory after approval:
# Set PREVIEW_URL to the printed preview URL.
curl --fail --silent --show-error "${PREVIEW_URL%/}/__hyperframes_composition.html" --output .hyperframes-export.htm &&
  html2video .hyperframes-export.htm --output out.mp4
test -s out.mp4
```

`check` runs lint first, then uses one browser session and one seek pass to audit runtime errors, failed requests, layout, `*.motion.json` assertions, and WCAG contrast. Persistent findings gate the exit code; transient entrance or exit findings are informational. Use `--strict` to gate warnings.

## Preview before render

Open the final composition preview only after `check` passes, to review the assembled timeline. The plan in chat and the `storyboard.html` sketch sheet are not approval of the final video. Rendering always requires the final approval defined by `../../references/review-loop.md`.

## Sub-composition smoke test

Static audits cannot catch every mount failure. When the project uses sub-compositions, capture at least one visible midpoint for each host slot:

```bash
hyperframes snapshot --at <t1>,<t2>,<t3>
```

Treat tiny unstyled content, canvas-sized icons, missing hero elements, or timeline-registration timeouts as render-blocking mount defects. See `../hyperframes-core/references/sub-compositions.md` for the corresponding fixes.

## Read the matching reference before running a command

The following references and owning skills are mandatory command contracts, not optional background reading. Before running a command in the table, read its matching row.

| Need                                                                                               | Reference                             |
| -------------------------------------------------------------------------------------------------- | ------------------------------------- |
| `init`                                                                        | `references/init-and-scaffold.md`     |
| `lint`, `check`, motion sidecars, `snapshot`                                                       | `references/lint-validate-inspect.md` |
| `preview`, `html2video`                                   | `references/preview-render.md`        |
| `compositions`, `timeline` | `references/upgrade-info-misc.md`     |

For composition variables, also read [hyperframes-core](../hyperframes-core/GUIDE.md) → `references/variables-and-media.md`. Before `hyperframes present`, read [slideshow](../slideshow/GUIDE.md).

```bash
hyperframes present <project-dir> --port 3004 --no-open
```

`present` serves a navigable deck.

## Generate media

Use supplied assets, or generate images, edit images (including background removal), and generate 5–10 second audio-video clips with `draw-things-cli`. Choose Qwen Image 2.1 for image editing and MiniMax H3 for short audio-video clips. Read the installed command help and model list for model IDs and generation settings:

```bash
draw-things-cli generate --help
draw-things-cli models list
draw-things-cli generate --model <image-model-id> --prompt "<prompt>" --output public/image.png
draw-things-cli generate --model <edit-model-id> --image public/input.png --prompt "<edit>" --output public/edited.png
draw-things-cli generate --model <video-model-id> --prompt "<prompt>" --output public/clip.mp4
```

Keep the generated files in the project and inspect them before placing them in the composition.
