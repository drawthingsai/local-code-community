# lower-thirds — category module

**Name/title bars, callouts, social overlays** — graphics meant to sit over other footage. Asset-free (+ optional logo). Usually `export: alpha-overlay` (transparent). ~3–6s (or loop/hold).

## Plan

`content`: `{ name, role, position (lower-left / lower-third / corner), brand_colors[] }`. Default `export: alpha-overlay`.

## Vocabulary / leans on

- Primitives: slide/wipe-in · bar reveal · `glow` · fade/slide-out.

## Build

Author a bar that wipes in (`scaleX` from 0, `transform-origin:left`) with text sliding up behind it, hold, slide out. **Transparent background** (`export: alpha-overlay` → `html2video .hyperframes-export.htm --format mov --alpha --output overlay.mov`) so it composites over footage. Prepare the [compiled export page](../../../hyperframes-cli/references/preview-render.md#render) first. Keep it in the title-safe lower band.
