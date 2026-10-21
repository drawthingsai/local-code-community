---
name: faceless-explainer
description: "Turn arbitrary text — an article, notes, a topic, a brief — into a faceless explainer video: the visuals are invented per scene (typography, abstract graphics, diagrams, data-viz). Use for topic explainers, concept breakdowns, how-tos, listicles. Product promos use product-launch-video. Unclear → hyperframes."
---

# Faceless Explainer to HyperFrames

Use this skill to turn a body of text into an explainer video: pick a design system, plan a teaching story, and build it frame by frame in HyperFrames. **Faceless** means every visual is invented downstream.

> **The front door is [hyperframes](../../SKILL.md).** You are the orchestrator. Run each step, verify its gate, and only then continue. This skill is for **explaining a topic from text, with invented visuals**. Any other intent, a bare "make a video", or any uncertainty → read [hyperframes](../../SKILL.md) first — the intent layer owns every route decision, and a fresh creation arriving here without `BRIEF.md` goes through it anyway (Setup's opening rule).

You are the orchestrator. Work in `videos/<project>/`. Run steps in order and pass each gate before continuing. User-gated steps are Step 0, Step 3, and Step 6. Read `../../references/brief-contract.md` before Step 0 — it defines the gate types and how `BRIEF.md`'s `flow`/`storyboard` derive the mode that governs the Step 3/4/6 gates. Build each frame from the storyboard. Do not put design or motion rules here; those live in this skill's local `../hyperframes-animation/rules/` + `../hyperframes-animation/blueprints/`, and `hyperframes-creative`.

Workflow: Step 0 setup → `hyperframes.json`; Step 1 brief → `source-text.txt`; Step 2 design system → `frame.md`; Step 3 storyboard/script → `STORYBOARD.md` and `SCRIPT.md`; Step 3.1 audio → placed media; Step 4 visual design → enriched `STORYBOARD.md`; Step 5 frames → `compositions/frames/NN-*.html` and `index.html`; Step 6 final render → `renders/video.mp4`.

---

## Step 0: Setup

Goal: Enter with a confirmed brief, create the HyperFrames project, and make the brief durable.

**The brief is confirmed by the intent layer, not by questions asked here.** Opening rule, in order: **(1)** `BRIEF.md` exists → read it and ask nothing — the brief is settled, and its `flow`/`storyboard` derive the mode (brief contract § 1). **(2)** No `BRIEF.md` but the project exists (`hyperframes.json` / `STORYBOARD.md` on disk) → resume from the storyboard's frontmatter and the recorded preferences; never re-interrogate a half-built project. **(3)** Neither — a fresh creation request that arrived here directly → read [hyperframes](../../SKILL.md) and run its intent layer (`references/intent-interview.md`): it conducts this route's questions (`../../references/routes/faceless-explainer.md`), and hands back the locked brief. Edit requests skip all of this — go do the edit.

Initialize only if `hyperframes.json` is missing. Name `<project>` from the topic in kebab-case, such as `compound-interest-explained`; never use workspace name or timestamp.

`hyperframes init "videos/<project>" --non-interactive --example=blank`

After init, let `<PROJECT_ROOT>` be `videos/<project>` and run every subsequent relative-path command with that directory as its working directory. In the commands below, `.` means `<PROJECT_ROOT>`; never write output files in the caller directory.

**Write `BRIEF.md` immediately after init** (never before — `init` refuses a non-empty directory): the intent layer's locked brief, shape per `../../references/brief-format.md`.

**Gate:** `hyperframes.json` and `BRIEF.md` exist.

---

## Step 1: Brief

Goal: Fold the user's text into the project as the source of information.

Save the user's full input verbatim, then create the source files by hand:

- `source-text.txt` — the full article / notes / topic / brief, verbatim. This is the source of **information**, not a story template (Step 3 reshapes it).
- `tokens.json` — `{ "title": "", "description": "", "colors": [], "fonts": [] }`. Fill `title`/`description` from the brief. Leave `colors`/`fonts` empty unless the user explicitly gave brand colors or fonts — then add them (the design preset supplies a complete palette regardless).

If the user pasted a script or wants their wording kept, save it verbatim as `user_script.txt`; `VO_MODE` (verbatim or restructured) comes from `BRIEF.md` — the intent layer asks it when a script arrives. Ask once here only if the brief somehow lacks it, and store the answer for Step 3.

**Gate:** `source-text.txt` and `tokens.json` exist; you can state the explainer's topic and audience in one clear sentence.

---

## Step 2: Design System

Goal: Choose one shipped frame preset for this video's `frame.md`.

When `BRIEF.md` names a `style_preset`, use it; the judgment call is yours only when the brief is silent. Read `../hyperframes-creative/references/design-spec.md` and choose from `../hyperframes-creative/frame-presets/`. Copy the preset's `FRAME.md` to `frame.md`, then apply the supplied brand colors and fonts while keeping the preset's keys, structure, and components.

**Gate:** `frame.md` exists from a named preset.

---

## Step 3: Storyboard and Script

Goal: Turn the text into an approved frame-by-frame teaching plan.

Read `../hyperframes-creative/references/story-spine.md` (hook language, value-before-evidence, storyboard-as-proposal, source-traceable visuals), `references/story-design.md`, `../hyperframes-animation/blueprints-index.md`, `../../references/storyboard-format.md`, and `../../references/script-format.md`. Use them to write `STORYBOARD.md` and, when narration is needed, `SCRIPT.md`. Set the frontmatter `duration:` from the brief's `length` — a rough expectation; assembly reports where the cut lands against it.

Use `story-design.md` for the explainer structure (concept / how-to / listicle / story), hook strategy, clarity techniques, emotional beats, the type-enum mapping, and `VO_MODE`. The video's sequence comes from **narrative design, not the input text's paragraph order** — reorder, merge, omit, compress. As a **soft guide**, consult the role→blueprint menu in `../hyperframes-animation/blueprints-index.md`: for each beat, write the voiceover in the shape its candidate blueprint implies and tag that candidate `blueprint:` id when one fits. Teaching truth still decides which beats exist — never force a beat to fit a blueprint, and never invent a beat just because a proven shape is available. Faceless visuals are invented downstream, so frames do **not** carry an asset inventory: leave `asset_candidates` empty unless the user supplied a real `public/<basename>` image. Use the exact required fields from the storyboard and script references.

After drafting, run the review loop's plan pass — `../../references/review-loop.md` § 1: present the plan as a proposal, and ask the two questions — approve or change, and **sketches first** (recommended) or skip. Feedback arrives as a chat reply; loop until approved. This is a **checkpoint gate** (brief contract § 1): in autonomous mode there is nothing to ask — post the same summary as a heads-up and proceed; sketches collapse into the build, and the one preview question comes at Step 6.

**Gate:** `STORYBOARD.md` exists, every frame has the required narrative fields, `SCRIPT.md` exists when narration is needed, and the user approved the frame-by-frame plan (autonomous: the summary was posted as a heads-up).

---

## Step 3.1: Audio

Use the supplied narration, music, and timing data. Real voice duration overrides estimates. For generated short audio-video clips, use [hyperframes-cli](../hyperframes-cli/GUIDE.md) → Generate media.

---

## Step 4: Frame Visual Design

Goal: Add the visual direction, layout intent, and motion choices to each storyboard frame.

**Sketch the storyboard sheet first (collaborative only).** The moment the plan is approved, run the sketch pass — `../../references/review-loop.md` § 2 (don't wait on Step 3.1; sketches don't use timings): wireframe every frame yourself as a cell of `storyboard.html` (`../hyperframes-creative/references/storyboard-recipe.md` § 3), mark each `built`, pause for the one layout question when every frame is `built`, and revise only the sketches named until the sheet is confirmed. Only then write the visual design below onto the confirmed layouts. In autonomous mode, or when the user chose to skip sketches at Step 3, skip this pass — frames go straight from `outline` to `animated` at Step 5.

Edit `STORYBOARD.md` in place. Do not create another storyboard. Use `frame.md` as source of truth for color, type, layout feel, and style.

Read `references/visual-design.md`, `../hyperframes-animation/blueprints-index.md`, `references/motion-language.md`, and `../hyperframes-animation/rules-index.md`. Use `visual-design.md` for the method (the time-coded shot sequence, the inline Layout vocabulary, and the invented-visual treatment), plus the required `## Video direction` block. Use `../hyperframes-animation/blueprints-index.md` to pick each frame's shot shape. Use `motion-language.md` (the motion vocabulary + the motion doctrine) and `../hyperframes-animation/rules-index.md` (valid rule names) for motion — do not invent motion names.

For every frame, write a **time-coded shot sequence** into `STORYBOARD.md` per `visual-design.md`'s method: pick the frame's blueprint (or compose), instantiate it with THIS frame's **invented** content, and pace each Scene's reveal to the voiceover so the frame develops across its full duration instead of front-loading then freezing. Because the explainer is faceless, `focal`/`roles` name the **invented visual elements** (a hero word, a diagram node, a data-viz series) — you are designing them, not selecting supplied assets. State layout and motion **inline** per Scene (vocabularies in `visual-design.md` and `motion-language.md`). Add one video-wide `## Video direction` block.

Do not change story, script, `transition_in`, or the source text. Do not write HTML in this step. There is **no asset-staging step** — faceless visuals are built in Step 5. If the user supplied a real `public/<basename>` image, reference it by path in the relevant frame's `focal`/`roles`; otherwise nothing to stage.

**Gate:** every frame has a time-coded shot sequence whose reveals are paced to the voiceover (no front-loading); each frame names its invented `focal` and/or `roles`; `## Video direction` exists. Collaborative: the sketch sheet was confirmed.

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

`hyperframes snapshot --at <frame-midpoints>`

`snapshot` stitches the captured frames into one contact sheet (`snapshots/contact-sheet.png`). Glance at it; if nothing is obviously broken, move on — don't linger here.

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

The reusable, domain-agnostic shot shapes live in `../hyperframes-animation/blueprints/` (indexed by `../hyperframes-animation/blueprints-index.md`).

| Read                                                                                                                                                        | When                                                                                                     |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `[../hyperframes/references/brief-contract.md](../../references/brief-contract.md)`                                                                | Gate types, mode derivation from `BRIEF.md`, field semantics.                                            |
| `[../hyperframes-creative/references/story-spine.md](../hyperframes-creative/references/story-spine.md)`                                                    | Step 3: story doctrine — hook language, value-before-evidence, proposal shape, source-traceable visuals. |
| `[../hyperframes-creative/frame-presets/](../hyperframes-creative/frame-presets/)`                                                                          | Step 2: choose and adopt a frame preset.                                                                 |
| `[../hyperframes-creative/references/design-spec.md](../hyperframes-creative/references/design-spec.md)`                                                    | Step 2: apply brand tokens correctly.                                                                    |
| `[references/story-design.md](references/story-design.md)`                                                                                                  | Step 3: plan the explainer story.                                                                        |
| `[../hyperframes-animation/blueprints-index.md](../hyperframes-animation/blueprints-index.md)`                                                              | Step 3: role→blueprint menu. Step 4: pick the shot shape.                                                |
| `[../hyperframes/references/storyboard-format.md](../../references/storyboard-format.md)`                                                          | Step 3: write `STORYBOARD.md`.                                                                           |
| `[../hyperframes/references/script-format.md](../../references/script-format.md)`                                                                  | Step 3: write `SCRIPT.md`.                                                                               |
| `[references/visual-design.md](references/visual-design.md)`                                                                                                | Step 4: write the frame's shot sequence (+ Layout vocabulary).                                           |
| `[references/motion-language.md](references/motion-language.md)`                                                                                            | Step 4: the motion vocabulary + the motion doctrine.                                                     |
| `[references/cut-catalog.md](references/cut-catalog.md)`                                                                                                    | Step 4-5: the cut catalog (worker builds within-frame seams).                                            |
| `[../hyperframes-animation/rules-index.md](../hyperframes-animation/rules-index.md)` + `[../hyperframes-animation/rules/](../hyperframes-animation/rules/)` | Step 5: local rule recipe bodies for the cited motions.                                                  |
