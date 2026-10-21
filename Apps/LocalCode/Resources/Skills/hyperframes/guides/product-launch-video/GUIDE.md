---
name: product-launch-video
description: "Turn a supplied product brief, script, or assets into a product launch / promo video — SaaS promos, feature reveals, product demos, app and company launches. Use when the user wants to market, launch, promote, or reveal a product. Unclear → hyperframes."
---

# Product Launch to HyperFrames

Use this skill to understand a product and its brand, plan a launch video, and build it frame by frame in HyperFrames.

> **The front door is [hyperframes](../../SKILL.md).** You are the orchestrator. Run each step, verify its gate, and only then continue to the next step. This skill is for a **product being marketed, launched, promoted, or revealed**, including requests such as "promo for our site" when the purpose is promotional.md` carries the show-it-as-is intent, and the supplied screens become the assets the video features. Any other intent, a bare "make a video", or any uncertainty → read [hyperframes](../../SKILL.md) first — the intent layer owns every route decision, and a fresh creation arriving here without `BRIEF.md` goes through it anyway (Setup's opening rule).

You are the orchestrator. Work in `videos/<project>/`. Run steps in order and pass each gate before continuing. User-gated steps are Step 0, Step 3, and Step 6. Read `../../references/brief-contract.md` before Step 0 — it defines the gate types and how `BRIEF.md`'s `flow`/`storyboard` derive the mode that governs the Step 3/4/6 gates. Build each frame from the storyboard. Do not put design or motion rules here; those live in this skill's local `../hyperframes-animation/rules/` + `../hyperframes-animation/blueprints/`, and `hyperframes-creative`.

Workflow: Step 0 setup -> `hyperframes.json`; Step 1 assets -> `public/`; Step 2 design system -> `frame.md`; Step 3 storyboard/script -> `STORYBOARD.md` and `SCRIPT.md`; Step 3.1 audio -> placed media; Step 4 visual design -> enriched `STORYBOARD.md`; Step 5 frames -> `compositions/frames/NN-*.html` and `index.html`; Step 6 final render -> `renders/video.mp4`.

---

## Step 0: Setup

Goal: Enter with a confirmed brief, create the HyperFrames project, and make the brief durable.

**The brief is confirmed by the intent layer, not by questions asked here.** Opening rule, in order: **(1)** `BRIEF.md` exists → read it and ask nothing — the brief is settled, and its `flow`/`storyboard` derive the mode (brief contract § 1). **(2)** No `BRIEF.md` but the project exists (`hyperframes.json` / `STORYBOARD.md` on disk) → resume from the storyboard's frontmatter and the recorded preferences; never re-interrogate a half-built project. **(3)** Neither — a fresh creation request that arrived here directly → read [hyperframes](../../SKILL.md) and run its intent layer (`references/intent-interview.md`): it conducts this route's questions (`../../references/routes/product-launch-video.md`), and hands back the locked brief. Edit requests skip all of this — go do the edit.

Initialize only if `hyperframes.json` is missing. Name `<project>` from the brand or domain in kebab-case, such as `acme-promo`; never use workspace name or timestamp.

`hyperframes init "videos/<project>" --non-interactive --example=blank`

After init, let `<PROJECT_ROOT>` be `videos/<project>` and run every subsequent relative-path command with that directory as its working directory. In the commands below, `.` means `<PROJECT_ROOT>`; never write output files in the caller directory.

**Write `BRIEF.md` immediately after init** (never before — `init` refuses a non-empty directory): the intent layer's locked brief, shape per `../../references/brief-format.md`.

**Gate:** `hyperframes.json` and `BRIEF.md` exist.

---

## Step 1: Collect assets

Goal: Collect the source material, brand signals, and usable assets for the video.

Save the supplied brief or script verbatim as `user_script.txt`. `VO_MODE` (verbatim or restructured) comes from `BRIEF.md`. Place supplied assets under `public/` and record their paths and descriptions in `asset-descriptions.md`. Use [hyperframes-cli](../hyperframes-cli/GUIDE.md) → Generate media for additional images, image edits, or short audio-video clips.

**Gate:** you can state the brand in one clear sentence, and `asset-descriptions.md` identifies the source material.

---

## Step 2: Design System

Goal: Choose one shipped frame preset for this video's `frame.md`.

When `BRIEF.md` names a `style_preset`, use it; the judgment call is yours only when the brief is silent. Read `../hyperframes-creative/references/design-spec.md` and choose from `../hyperframes-creative/frame-presets/`. Copy the preset's `FRAME.md` to `frame.md`, then apply the supplied brand colors and fonts while keeping the preset's keys, structure, and components.

**Gate:** `frame.md` exists from a named preset.

---

## Step 3: Storyboard and Script

Goal: Turn the brief and supplied material into an approved frame-by-frame story plan.

Read `../hyperframes-creative/references/story-spine.md` (hook language, value-before-evidence, storyboard-as-proposal, source-traceable visuals), `references/story-design.md`, `../hyperframes-animation/blueprints-index.md`, `../../references/storyboard-format.md`, and `../../references/script-format.md`. Use them to write `STORYBOARD.md` and, when narration is needed, `SCRIPT.md`. Set the frontmatter `duration:` from the brief's `length` — a rough expectation; assembly reports where the cut lands against it.

Use `story-design.md` for story blueprint, hook, persuasion logic, beats, `VO_MODE`, and asset choices. As a **soft guide**, consult the role→blueprint menu in `../hyperframes-animation/blueprints-index.md`: for each beat, note a candidate blueprint id when one fits. Story truth still decides which beats exist — never force a beat to fit a blueprint, and never invent a beat just because a proven shape is available. Choose each visual frame's `asset_candidates` from `asset-descriptions.md` (the canonical inventory) — don't browse raw `public/`. Do not ask the user to pick assets unless that inventory is missing or unusable. Use the exact required fields from the storyboard and script references.

After drafting, run the review loop's plan pass — `../../references/review-loop.md` § 1: present the plan as a proposal, and ask the two questions — approve or change, and **sketches first** (recommended) or skip. Feedback arrives as a chat reply; loop until approved. This is a **checkpoint gate** (brief contract § 1): in autonomous mode there is nothing to ask — post the same summary as a heads-up and proceed; sketches collapse into the build, and the one preview question comes at Step 6.

**Gate:** `STORYBOARD.md` exists, every visual frame has `asset_candidates`, `SCRIPT.md` exists when narration is needed, and the user approved the frame-by-frame plan (autonomous: the summary was posted as a heads-up).

---

## Step 3.1: Audio

Use the supplied narration, music, and timing data. Real voice duration overrides estimates. For generated short audio-video clips, use [hyperframes-cli](../hyperframes-cli/GUIDE.md) → Generate media.

---

## Step 4: Frame Visual Design

Goal: Add the visual direction, layout intent, and motion choices to each storyboard frame.

**Sketch the storyboard sheet first (collaborative only).** The moment the plan is approved, run the sketch pass — `../../references/review-loop.md` § 2 (don't wait on Step 3.1; sketches don't use timings): wireframe every frame yourself as a cell of `storyboard.html` (`../hyperframes-creative/references/storyboard-recipe.md` § 3), mark each `built`, pause for the one layout question when every frame is `built`, and revise only the sketches named until the sheet is confirmed. Stand-ins: plain labeled blocks for the supplied assets — the real files arrive with Step 5. Only then write the visual design below onto the confirmed layouts. In autonomous mode, or when the user chose to skip sketches at Step 3, skip this pass — frames go straight from `outline` to `animated` at Step 5.

Edit `STORYBOARD.md` in place. Do not create another storyboard. Use `frame.md` as source of truth for color, type, layout feel, and style.

Read `references/visual-design.md`, `../hyperframes-animation/blueprints-index.md`, `references/motion-language.md`, and `../hyperframes-animation/rules-index.md`. Use `visual-design.md` for the method (the time-coded shot sequence, the inline Layout vocabulary, and the required `## Video direction` block). Use `../hyperframes-animation/blueprints-index.md` to pick each frame's shot shape. Use `motion-language.md` (the motion vocabulary + the motion doctrine) and `../hyperframes-animation/rules-index.md` (valid rule names) for motion — do not invent motion names.

For every visual frame, write a **time-coded shot sequence** into `STORYBOARD.md` per `visual-design.md`'s method: pick the frame's blueprint (or compose), instantiate it with THIS product's content, and pace each Scene's reveal to the voiceover so the frame develops across its full duration instead of front-loading then freezing. State layout and motion **inline** per Scene (vocabularies in `visual-design.md` and `motion-language.md`). Add one video-wide `## Video direction` block.

When an element visibly continues across a frame boundary, record the same numerical handoff for both frames in `STORYBOARD.md`: add `handoff_out:` to the outgoing frame and a matching `handoff_in:` to the incoming frame. Name the element and its exact x/y position, scale, opacity, and motion direction/speed at the cut — state every field even when it does not change, because a constant is `opacity: 1`, not an omission. Omit the whole block only for a deliberate clean cut. The goal is simple: the frames must not use two different versions of the same seam.

Do not change story, script, asset choices, `asset_candidates`, `transition_in`, or supplied source material. Do not write HTML in this step.

Stage named assets after visual design is locked:

**Gate:** every visual frame has a time-coded shot sequence whose reveals are paced to the voiceover (no front-loading); `## Video direction` exists; `assets/` contains the named assets. Collaborative: the sketch sheet was confirmed.

---

## Step 5: Build Frames

Goal: Build every storyboard frame as an HTML composition and assemble the playable video.

Build `compositions/frames/NN-*.html` from each frame's shot sequence. Read the cited blueprint and rule recipes before writing motion. A confirmed sketch defines the layout. Use [hyperframes-core](../hyperframes-core/GUIDE.md) for the composition contract and `../../references/production-loop.md` for assembly.

**Full-bleed backgrounds ride on a `class="clip"` layer, never the `#root`.** A frame's ground (color field / gradient / grid) is its own full-duration background clip.

Mark each completed frame as `animated` in `STORYBOARD.md`. Mount scenes, media, transitions, captions, and audio in `index.html`. For captions, use [embedded-captions](../embedded-captions/GUIDE.md) with supplied timing data.

**Gate:** every frame is marked `animated`, `index.html` exists, and captions are built when requested.

---

## Step 6: Finalize

Goal: Verify the assembled video, get user approval, and render the final MP4.

Run checks, pause for review, then render.

`hyperframes lint`

`hyperframes check`

`hyperframes snapshot --at <frame-midpoints-and-each-cut-minus-0.1s-and-plus-0.2s>`

`snapshot` stitches the captured frames into one contact sheet (`snapshots/contact-sheet.png`). Inspect the midpoint frames for layout failures, then compare the two images around every cut. A continuing element must keep the promised position, scale, opacity, and direction; fix any visible pop before rendering.

If a command fails, surface stderr and stop — don't pile on recovery commands. Fix it yourself: the cheapest safe edit to `compositions/frames/NN-*.html`, then rerun the failed check.

After checks pass, pause for user review — the review loop's final look (`../../references/review-loop.md` § 4): one question, on the final preview — render now, or what changes? (Autonomous: the one kept question, preview first or render.) Then deliver the MP4 with the contact sheet and the frame ids so revisions can target a single frame.

Preview: `hyperframes preview --foreground --no-open`

Render only after user approval (autonomous mode: after the preview-or-render question):

Prepare the [compiled export page](../hyperframes-cli/references/preview-render.md#render), then run:

`html2video .hyperframes-export.htm --output renders/video.mp4`

Do not rerun `lint`, `check`, or `snapshot` after rendering unless the user asks.

**Gate:** `lint` and `check` passed and the snapshots were inspected before render; user approved at the review pause (autonomous: checks passed and the delivery includes the contact sheet); `renders/video.mp4` exists. Final reply states MP4 path and final duration.

---

## Quick Reference

**Formats:** landscape `1920x1080`; portrait `1080x1920`; square `1080x1080` — derived from the destination (brief contract § 2). Set the format once in the storyboard frontmatter.

The reusable, product-agnostic shot shapes live in `../hyperframes-animation/blueprints/` (indexed by `../hyperframes-animation/blueprints-index.md`).

| Read                                                                                                                                                        | When                                                                                                     |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `[../hyperframes/references/brief-contract.md](../../references/brief-contract.md)`                                                                | Gate types, mode derivation from `BRIEF.md`, field semantics.                                            |
| `[../hyperframes-creative/references/story-spine.md](../hyperframes-creative/references/story-spine.md)`                                                    | Step 3: story doctrine — hook language, value-before-evidence, proposal shape, source-traceable visuals. |
| `[../hyperframes-creative/frame-presets/](../hyperframes-creative/frame-presets/)`                                                                          | Step 2: choose and adopt a frame preset.                                                                 |
| `[../hyperframes-creative/references/design-spec.md](../hyperframes-creative/references/design-spec.md)`                                                    | Step 2: apply brand tokens correctly.                                                                    |
| `[references/story-design.md](references/story-design.md)`                                                                                                  | Step 3: plan the product-launch story.                                                                   |
| `[../hyperframes-animation/blueprints-index.md](../hyperframes-animation/blueprints-index.md)`                                                              | Step 3: role→blueprint menu. Step 4: pick the shot shape.                                                |
| `[../hyperframes/references/storyboard-format.md](../../references/storyboard-format.md)`                                                          | Step 3: write `STORYBOARD.md`.                                                                           |
| `[../hyperframes/references/script-format.md](../../references/script-format.md)`                                                                  | Step 3: write `SCRIPT.md`.                                                                               |
| `[references/visual-design.md](references/visual-design.md)`                                                                                                | Step 4: write the frame's shot sequence (+ Layout vocabulary).                                           |
| `[references/motion-language.md](references/motion-language.md)`                                                                                            | Step 4: the motion vocabulary + the motion doctrine.                                                     |
| `[references/cut-catalog.md](references/cut-catalog.md)`                                                                                                    | Step 4-5: the cut catalog (worker builds within-frame seams).                                            |
| `[../hyperframes-animation/rules-index.md](../hyperframes-animation/rules-index.md)` + `[../hyperframes-animation/rules/](../hyperframes-animation/rules/)` | Step 5: local rule recipe bodies for the cited motions.                                                  |
