---
name: general-video
description: >
  Author or edit a custom HyperFrames composition when no specialized workflow fits, or when
  BRIEF.md sets flow: companion. Use for longer or multi-scene pieces, brand and sizzle reels,
  montages, static loops, static title cards, footage remixes, and freeform builds. Use
  motion-graphics instead for a short unnarrated motion-first unit, including an animated title.
  Route fresh creation through hyperframes before using this skill.
---

# General video

## 1. Start from project state

Apply the first matching row; do not evaluate lower state rows:

| State                                                      | Action                                                                                                         |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Specific edit                                              | Make the edit, preserve existing project decisions, then rerun affected checks. Do not reopen discovery.       |
| `BRIEF.md` exists                                          | Read it. If `workflow` names another workflow and `flow` is not `companion`, hand off. Ask no brief questions. |
| No brief, but `hyperframes.json` or `STORYBOARD.md` exists | Resume from files and recorded preferences. Backfill `BRIEF.md` only from known facts.                         |
| Fresh creation                                             | Run [hyperframes](../../SKILL.md) and its intent layer. Return here only for `workflow: general-video` or `flow: companion`.  |

For a new project, choose a kebab-case directory name from the brief and scaffold before writing the brief:

```bash
hyperframes init "videos/<project>" --non-interactive --example=blank
```

Then write `BRIEF.md` at the project root using `../../references/brief-format.md`. In an existing project, the root is the directory containing `hyperframes.json`.

## 2. Interpret the run shape

Use only the canonical terms from `../../references/brief-contract.md`:

| Field          | Meaning                               | Effect                                                                              |
| -------------- | ------------------------------------- | ----------------------------------------------------------------------------------- |
| `flow`         | Who drives                            | `automation`: choose and execute the route. `companion`: co-create in conversation. |
| `storyboard`   | Plan, sketch, and review before build | `yes`: run plan and sketch review (`storyboard.html`). `no`: build without it.      |
| derived `mode` | How checkpoint gates behave           | Follow the brief contract. Never ask the user to name a mode.                       |

Do not invent synonyms for these states. An ongoing “just build it” signal is handled by the intent layer and arrives as `flow: automation`, `storyboard: no`.

- For `flow: automation`, choose the route and state it in one line in the first progress update.
- For a specific edit, make the edit without inventing a new route.

For a hard cut, trim, splice, or reorder of existing footage, duplicate the same
video source into multiple clip elements. On each copy, set the source range
with `data-media-start` plus `data-duration`, then set authored placement/order
with `data-start`. Separately authored audio follows the identical clip ranges
and timing on matching `<audio>` elements. [hyperframes-core](../hyperframes-core/GUIDE.md) owns this temporal
edit; use [hyperframes-animation](../hyperframes-animation/GUIDE.md) only for visual-property animation such as
zoom, punch, pan, crop, mask, or `clip-path` on an inner wrapper.
Copy the full contracts from `../hyperframes-core/references/creator-editing-recipes.md`.

### Companion flow

When `flow: companion`:

- Read `BRIEF.md` and reconcile accepted `## Assets` and `## Customizations` with project artifacts. Complete accepted work that is still pending; leave completed work alone; do not offer an accepted capability again as if it were new.
- **Arrive as the director, not the contractor.** A user who chose companion chose involvement and quality; the honest response is the best version you can design, not the smallest one you can defend. The first plan is the ceiling treatment: the story arc (borrow the nearest genre lens — menu § Genre lenses), the design spec, each scene's motion treatment cited by name (§ 4's plan discipline), the transitions, the audio identity — music and sound marks, or deliberate silence — the user's material placed, and a designed open and close. Say what each layer adds in one line; flag the expensive ones (generation or render time) as you name them. The user trims a treatment down; they should never have to assemble one approval by approval.
- **The ceiling belongs to the concept, not the toolbox.** Every layer must serve the brief's message — a treatment that would dress any video the same way is decoration. Craft rises to the ceiling; content never grows past what was asked (§ 6).
- Between checkpoints, `../../references/capability-menu.md` works two ways. As the trigger list: offer a relevant capability when the user mentions its input or the build reaches its need. As each pass's upgrade channel: a plan, sketch, or build checkpoint may carry one or two traced offers pointed at material the user is looking at ("scene 3's stat wants the count-up treatment"). Read it before offering; never dump the full catalog.
- After the user accepts a capability, produce its artifact and record the decision in the matching `BRIEF.md` body section immediately. Rewrite a frontmatter field and record the confirmed preference only when the user explicitly changes it.
- Keep the same storyboard, validation, final-preview, and render-approval gates. Companion changes who steers, not what quality requires.

## 3. Load required knowledge before each stage

These reads are mandatory when their condition matches:

| Condition                                                                                                         | Read before acting                                                                                                                                                                                                                     |
| ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Any composition HTML or scene layout                                                                              | [hyperframes-core](../hyperframes-core/GUIDE.md); use `references/determinism-rules.md` for its layout contract                                                                                                                                                     |
| Any non-trivial creation or visual treatment                                                                      | [hyperframes-creative](../hyperframes-creative/GUIDE.md) → `references/house-style.md` and `references/video-composition.md`                                                                                                                                            |
| Any motion, animation, or scene transition                                                                        | [hyperframes-animation](../hyperframes-animation/GUIDE.md); follow its routing to the matching rules, adapters, blueprints, or transition references                                                                                                                     |
| `storyboard: yes`                                                                                                 | `../../references/storyboard-format.md` and `../../references/review-loop.md`                                                                                                                                        |
| Multi-scene assembly                                                                                              | `../../references/production-loop.md`                                                                                                                                                                                         |
| `flow: companion`, before the first plan                                                                          | [hyperframes-creative](../hyperframes-creative/GUIDE.md) → `references/story-spine.md` and `references/house-style.md`; the nearest genre lens and the full `../../references/capability-menu.md` — the ceiling treatment is designed from these, not recalled |
| A companion capability offer | `../../references/capability-menu.md`                                                                                                                                                                                         |
| A design spec exists, before final approval                                                                       | [hyperframes-creative](../hyperframes-creative/GUIDE.md) → `references/design-adherence.md`                                                                                                                                                                             |

Do not replace these reads with recollection. Progressive disclosure saves context only when the matching reference is actually loaded.

## 4. Execute the composition

Use this dependency order. Skip a stage only when its input is absent.

1. **Plan.** State the viewer arc, structure, rhythm, and duration driver. Use one file for a short single scene; use sub-compositions for three or more hard scene cuts or any reused scene. Read [hyperframes-creative](../hyperframes-creative/GUIDE.md) → `references/story-spine.md` for narrated arcs, `references/beat-direction.md` for rhythm, and [hyperframes-core](../hyperframes-core/GUIDE.md) → `references/composition-patterns.md` for structure. For an open-ended multi-scene brief, expand the prompt through [hyperframes-creative](../hyperframes-creative/GUIDE.md) → `references/prompt-expansion.md`. A multi-scene plan cites each scene's shape: a blueprint id from [hyperframes-animation](../hyperframes-animation/GUIDE.md) → `blueprints-index.md` when one fits, or the named rules it composes from `rules-index.md` when none does — motion names come from those indexes, never invented. Story truth decides which scenes exist; the citation dresses them. A multi-scene plan is also recorded in `STORYBOARD.md`: one `## Frame N` block per scene in `STORYBOARD.md` — `status: outline`, a declared `src:`, the blueprint/rules citation, and the beat text — **even when `storyboard: no`**. The storyboard sheet is the review surface.
2. **Review the plan when requested.** For `storyboard: yes`, run the shared review loop over those blocks. For `storyboard: no`, continue without a plan pause or sketch sheet.
3. **Resolve dependencies.** Stage user assets and resolve only what the brief requires. Use [hyperframes-cli](../hyperframes-cli/GUIDE.md) → Generate media for images, image edits, and short audio-video clips.
4. **Build scenes.** For a short single-scene piece, implement the scene at its most visible moment before adding motion (the confirmed wireframe, when present, is that end state and must not be redrawn), then animate from its cited blueprint or rules — read the full recipe body ([hyperframes-animation](../hyperframes-animation/GUIDE.md) → `blueprints/<id>.md`, `rules/<id>.md`) before writing motion.

5. **Assemble.** Mount scenes, media, transitions, captions, and audio using the production loop. Real voice duration overrides estimates.
6. **Verify.** Use `hyperframes lint` for fast feedback after the first HTML pass and structural changes. For the final gate, run `hyperframes check`; it reruns lint internally, so do not run a redundant standalone lint immediately before it. For sub-compositions, inspect midpoint snapshots.
7. **Final approval.** Open the final preview only after checks pass. Ask whether to render or revise. Render only after approval.

## 5. Gates that always apply

### Keep scope exact

Build what the user asked for. A title card is not a title card plus three scenes, music, and captions. Offer additions before adding them.

### Establish design before HTML

Resolve the design source in this order: `frame.md` → `design.md` → `DESIGN.md`. Treat the first file found as brand truth.

When no design spec exists, complete all four items before writing composition HTML:

1. Ground the visual identity in `house-style.md` and `video-composition.md`.
2. Write one sentence naming the concept angle for every non-trivial creation.
3. Choose an embeddable font pairing from [hyperframes-creative](../hyperframes-creative/GUIDE.md) → `references/typography.md`; do not assume an unbundled display font exists in the renderer.
4. Define the focal element, edge anchors, supporting detail, and background treatment.

Match density to the requested format and message. Density examples are guidance for produced frames, not permission to invent claims, scenes, or a fixed number of elements.

For a named style or mood, read [hyperframes-creative](../hyperframes-creative/GUIDE.md) → `references/visual-styles.md`. When the user needs to choose visually and no shipped preset fits, read [hyperframes-creative](../hyperframes-creative/GUIDE.md) → `references/design-picker.md` and run the interactive design selection there.

### Preserve the composition contract

Timed elements use `class="clip"`; the root and relevant ancestors are sized; each composition registers one paused, seek-safe timeline on `window.__timelines`; rendering is deterministic. Do not use render-time network fetches, clocks, or unseeded randomness.

### Borrow workflows safely

When the piece resembles a shipped workflow, borrow its genre references as examples. Borrow its story shape and taste, not its private scripts, pipeline state, or directory contract. The generic build remains owned by this skill.

## 7. Done

A run is complete only when:

- requested scope is implemented;
- for `flow: companion`, the treatment is delivered, not just the scope: every scene's cited blueprint or rules realized, the audio identity present (or the silence chosen and said), the open and close designed rather than defaulted;
- `hyperframes check` passes, including its built-in lint stage;
- design adherence is reviewed against [hyperframes-creative](../hyperframes-creative/GUIDE.md) → `references/design-adherence.md` when a design spec exists;
- contrast findings are resolved;
- sub-composition snapshots are inspected when applicable;
- an autonomous handoff includes an inspected contact or snapshot sheet; multi-scene sheets use scene midpoints;
- the handoff names the final preview or rendered artifact as applicable and reports the actual duration for a time-based deliverable;
- the user approves the final preview before render;
- the rendered file is verified when a render was requested.
