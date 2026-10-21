# stat — category module

A single **hero number** reveal. Asset-free (the "input" is the number). ~4–6s.

## Plan

`content`: `{ value, prefix ($), suffix (% / x / K-M-B), label, ring: bool }`. Envelope: bold display font, restrained palette + one accent.

## Vocabulary / leans on

- Rules: `../../../hyperframes-animation/rules/{counting-dynamic-scale, stat-bars-and-fills}`.
- Primitives: `count_up` (odometer) · `scale_pop` · `ring_fill` (arc) · `label_stagger` (after value) · `hold`.

## Build

Author the count-up with the following rules:

- **count-up is timeline-driven** — tween a proxy `{v:0}→target` with `onUpdate` writing the formatted number (seek-safe; never setInterval/wall-clock).
- `font-variant-numeric: tabular-nums`; decelerating ease; ~1.2–1.6s then **hold** the final value.
- ring/arc via `stroke-dashoffset`, finishing in sync with the count-up; label fades in **after** the number lands (value → meaning).
