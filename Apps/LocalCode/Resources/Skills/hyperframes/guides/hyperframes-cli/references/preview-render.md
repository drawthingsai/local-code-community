# preview and render

## preview

```bash
hyperframes preview --foreground --no-open
hyperframes preview --foreground --no-open --json
hyperframes preview --foreground --no-open --port 4567
```

Serve the composition as a standalone preview page. Verify the printed URL returns HTTP 200 and keep it alive for the whole review. Use the printed URL as-is.

## render

Rendering requires the final approval defined by `../../../references/review-loop.md`.

Keep the preview running in its own Bash invocation. In another invocation, work from the project directory and set `PREVIEW_URL` to the URL printed by `hyperframes preview`. Save its compiled composition beside `index.html` before each export, so nested scenes, per-instance variables, and relative asset paths resolve:

```bash
PREVIEW_URL="http://127.0.0.1:<printed-port>/"
curl --fail --silent --show-error "${PREVIEW_URL%/}/__hyperframes_composition.html" --output .hyperframes-export.htm && test -s .hyperframes-export.htm
```

Continue only if the download succeeds. Fetch again after source edits. Keep this generated `.htm` file in the project root; it is the export input and is not an authored composition. Export the compiled composition, not the preview player page:

```bash
html2video .hyperframes-export.htm --output out.mp4
html2video .hyperframes-export.htm --format mov --alpha --output overlay.mov
```

Verify the output exists, is non-empty, and has the intended duration. Check video and audio synchronization when the composition includes media.
