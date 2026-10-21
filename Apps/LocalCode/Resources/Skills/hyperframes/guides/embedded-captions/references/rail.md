# Rail track — standard lower-third subtitle

The **default** caption track and the workhorse: a clean, readable subtitle that sits **in front** of everything in the lower third. It carries the transcript.

## Position & safe area

- **Lower third, horizontally centered.** Landscape (16:9): baseline ~80–120px above the
  bottom edge. Portrait (9:16): lower-middle, ~ 600–700px from the bottom (clear of platform UI).
- **Title-safe margins:** keep text within the title-safe box (80% of the frame) / inside any letterbox-pillarbox bars
. Never flush to the frame edge.
- **One caption group on screen at a time.** No accumulation, no cascade.
- It rides above the subject.

## Lines, length, timing

- **≤ 2 lines.** Broadcast target ~ 32–42 chars/line; break at a clause/phrase boundary, never
  mid-word, never leave a dangling 1-word line.
- **Word-synced.** Each group's window envelops its words (`group.in ≤ first word.start`,
  `group.out ≥ last word.end`); each group ≥ 0.5s on screen; ~1.5s min gap discipline so it
  doesn't strobe. Word timings within 80ms of transcript (same gate as everywhere).
- **Grouping** = short readable phrases (see [caption-grouping.md](caption-grouping.md)).

## Look (restrained on purpose)

- **Size: ~`calc(0.045 * var(--h))`** (≈48px @1080, ≈58px @1290) — readable, _not_ hero. Express as a `var(--h)` fraction so it scales across resolutions.
- One clean sans (Inter / Helvetica Now / Neue Haas), weight 500–600; white (or near-white).
- **Legibility without grading the video:** a tight text treatment local to the glyphs only —
  a soft dark drop-shadow, or a subtle rounded gradient pill / 30–40% scrim **sized to the text
  box** (not a full-frame bar, never a frame-wide grade). On luminance > 180 backgrounds, keep
  the scrim; never rely on bare light text.
- Motion is minimal: 150–250ms fade-up in / fade-down out. No glitch, no scale-pop, no per-word
  choreography on the rail.

## The `emphasis` flag (active-word highlight)

The only intensity the rail carries. When a word is graded `emphasis` (the 1–2 punch words in a
phrase), give it an **inline** lift on the rail — accent colour and/or +weight, optionally a
karaoke-style active-word pop (≤1.1× scale) as it's spoken. Keep it inline; it does **not**
leave the rail.

## What the rail never does

- Never goes behind the subject.
- Never accumulates into a multi-line poem.
- Never crosses the face / uses occlusion as an effect.
- Never grades or textures the underlying video.
- Doesn't drop content to "fit fewer blocks" — split into more groups instead. The only drops
  are filler (um/uh, exact stutters, self-corrections); dense conversational `narrator` glue
  ("you know", "sort of") may be trimmed for readability, content/structure words stay.
