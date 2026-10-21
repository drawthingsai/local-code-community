---
name: motion-graphics
description: >
  A short, design-led motion graphic where motion is the message — kinetic
  typography, stat count-up, chart/data-viz hit, logo sting / brand lockup,
  lower-third / callout / social overlay. Usually under 10s (up to ~30s), no
  narration or live-action subject; renders to MP4 or transparent overlay.
  Longer / narrated / multi-scene → general-video. Unclear → hyperframes.
---

# motion-graphics

> **The front door is [hyperframes](../../SKILL.md).** This skill makes a **short, design-led, unnarrated motion graphic** (motion is the message; ~under 10s, no voice-over). Anything longer, narrated, or multi-scene — or any uncertainty → read [hyperframes](../../SKILL.md) first: the intent layer owns every route decision.

This workflow is **autonomous by design** — at most one clarifying question, then build through verification without intermediate review. The intent layer ([hyperframes](../../SKILL.md) → `references/intent-interview.md`) routes here directly without run-shape questions; a storyboard and companion session add little to a piece this short. Rendering is still user-gated: after checks and proof snapshots pass, ask the canonical “preview first, or render?” question from `../../references/brief-contract.md`. When a `BRIEF.md` exists, read it before any clarifying question.

A short design-led motion graphic. **Asset-first**: decide the asset strategy and source real material _before_ designing the shot, then design the shot around what you have, then compose with animation rules and blueprints. All artifacts go to `PROJECT_DIR = videos/<project-name>/` (created in Step 0); all paths below are relative to it.

## Categories

Pick the category that matches the supplied content. The shared motion vocabulary lives in `references/motion-vocabulary.md`.

| Category | Intent |
| --- | --- |
| `kinetic-type` | punchy line / quote / title, motion-first text |
| `stat` | single hero number / count-up + ring |
| `charts` | bar / line / pie / race / % from data |
| `logo-reveal` | logo sting / brand lockup (user logo) |
| `lower-thirds` | name / title bars, callouts, social overlays |

Read the matching `categories/<id>/module.md` for its planning and build rules.

## Flow

### Step 0 — Initialize

cwd is the agent workspace root; write all artifacts under `PROJECT_DIR = videos/<project-name>/`. `<project-name>`: use the dir the user gave, else a short kebab-case name from the intent (`<subject>-motion`). Not the workspace basename or a timestamp.

Only when `$PROJECT_DIR/hyperframes.json` is absent:

```bash
PROJECT_DIR="${MOTION_GRAPHICS_DIR:-videos/<project-name>}"
hyperframes init "$PROJECT_DIR" --non-interactive --example=blank
```

**Constraints:** never `hyperframes init` in the workspace root; never nest another `hyperframes/` inside `PROJECT_DIR`; every Bash command  is a `(cd "$PROJECT_DIR" && ...)` subshell — never bare `cd`.

### Step 1 — Plan

Classify the request and write a one-paragraph shot brief in `shot-plan.json`: category, content, duration, and asset needs.

### Step 2 — Source

Stage supplied assets under `assets/` and record them in `assets/index.md`. Use [hyperframes-cli](../hyperframes-cli/GUIDE.md) → Generate media for images, image edits, and short audio-video clips. Pure code/text categories (e.g. `kinetic-type`, most `charts`/`stat`) have no asset needs and skip straight from plan to design.

### Step 3 — Design

Design the shot **around the available assets**: pick the `hyperframes-animation` rules/blueprints, the layout, the motion, and beats. Finalize `shot-plan.json`.

### Step 4 — Build

Read the category's `module.md`, `references/motion-vocabulary.md`, and the selected animation recipes. Output `compositions/index.html` honoring the HF contract (paused GSAP timeline on `window.__timelines`, `class="clip"` + stable ids, `tl.seek(0)`, deterministic). Mount it as a sub-composition from the project's root `index.html`.

### Step 5 — Verify

```bash
(cd "$PROJECT_DIR" && hyperframes lint .)
(cd "$PROJECT_DIR" && hyperframes check .)
(cd "$PROJECT_DIR" && hyperframes snapshot --at <proof-times>)
```

Choose proof times that show the opening state, signature move, and final hold. Inspect the generated contact or snapshot sheet before continuing. On `lint`, `check`, or snapshot failure, make one in-place fix pass, then rerun the failed gate. Never change a fixed duration merely to hide a defect.

### Step 6 — Approve and render (Bash)

Ask one question: “preview first, or render?” If the user chooses preview, open the preview and return to the same approval gate after revisions:

```bash
(cd "$PROJECT_DIR" && hyperframes preview --foreground --no-open)
```

Render only after an explicit render answer. Prepare the [compiled export page](../hyperframes-cli/references/preview-render.md#render) in `$PROJECT_DIR`, then run:

```bash
(cd "$PROJECT_DIR" && html2video .hyperframes-export.htm --output ./renders/video.mp4)
# transparent overlay variant: --format mov --alpha
```

Verify the output exists, is non-empty, and has the intended duration. The final handoff names the artifact, actual duration, composition or frame id, proof times, and the inspected contact or snapshot sheet. Flags live in [hyperframes-cli](../hyperframes-cli/GUIDE.md) → `references/preview-render.md`.

## Resume table

| State                                                    | Continue from              |
| -------------------------------------------------------- | -------------------------- |
| no `shot-plan.json`                                      | Step 1 (plan)              |
| `shot-plan.json` has `asset_needs`, no `assets/`         | Step 2 (source)            |
| `shot-plan.json` final, no `compositions/index.html`     | Step 3/4 (design+build)    |
| `compositions/index.html` exists, proof snapshots absent | Step 5 (verify)            |
| checks and proof snapshots pass, no approved render      | Step 6 (approval)          |
| approved render exists                                   | verify output, then report |
