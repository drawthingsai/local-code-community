---
name: hyperframes
description: >
  Author and edit motion graphics and timed HTML compositions: animated typography, charts,
  UI, logos, captions, overlays, slideshows, interactive decks, and footage edits. Also use
  it to check how an existing HyperFrames project looks at any moment, or to inspect,
  diagnose, validate, preview, or render it.
  For generated footage with subject actions, scene evolution, or camera movement through
  an imagined scene, use draw-things-cli, including for stylized animation.
---

# HyperFrames entry point

Workflow and domain links open this skill’s internal guides. Read the linked `GUIDE.md` directly; resolve its local resource paths relative to that guide’s directory.

Run the supplied `hyperframes` command directly for project operations. Export video with `html2video` using the [compiled export page](guides/hyperframes-cli/references/preview-render.md#render).

HyperFrames **renders video from HTML** — a composition is an HTML file whose DOM declares timing with `data-*` attributes, whose animation runtime is seekable, and whose media playback is owned by the framework. The full authoring contract lives in [hyperframes-core](guides/hyperframes-core/GUIDE.md); read it before writing composition HTML. Brief, storyboard, review, production contracts live in this skill's `references/`.

## Choose the primary workflow

For fresh creation, choose from what must be created before starting the intent interview or initializing a project. Honor the user's explicit tool or framework choice.

- Use [Draw Things](../use-draw-things-cli/SKILL.md) for generated footage: subject performance, physical interactions, scene evolution, and camera movement through an imagined scene, including stylized animation. Follow that skill directly when generation is the primary task.
- Use HyperFrames for authored graphic animation and composition: typography, charts, UI, slides, logos, diagrams, captions, and precisely timed graphic elements or footage edits.
- For mixed requests, use Draw Things for generated footage and HyperFrames for any separate composition work. Effects that belong within the generated scene can be included in the generation prompt.

## 1. Start from project state

Apply the first matching row; do not evaluate lower state rows:

| State                                                                                                                         | Action                                                                                                                                                                                                                                 |
| ----------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Specific operation on an existing HyperFrames project: inspect, diagnose, validate, preview, render, publish, or batch-render | Perform only that operation. Skip intent and workflow routing; load [hyperframes-cli](guides/hyperframes-cli/GUIDE.md) and any required domain skills.                                                                                                                 |
| Specific edit to an existing project                                                                                          | Make the edit. Do not run the intent layer. To know what is on a project's timeline (tracks, clips, starts, ends, what plays), run `hyperframes timeline [--json]` instead of reading `index.html` and every sub-composition file. |
| `BRIEF.md` exists                                                                                                             | Read `workflow` and `flow`. Execute that workflow; `flow: companion` always executes in [general-video](guides/general-video/GUIDE.md). Ask no brief questions.                                                                                                      |
| No brief, but `hyperframes.json` or `STORYBOARD.md` exists                                                                    | Resume from project files and recorded preferences. Infer the owning workflow from existing artifacts. If it cannot be determined uniquely, ask one routing-only question; do not run the intent interview.                            |
| Fresh creation                                                                                                                | Run the intent layer — `references/intent-interview.md` — then route once using § 2's table.                                                                                                                                           |

## 2. Route fresh creation

Use the first matching row. Match the requested **deliverable**, not a word or file type mentioned in passing.

| Priority | Request                                                                                                            | Workflow                   |
| -------- | ------------------------------------------------------------------------------------------------------------------ | -------------------------- |
| 1        | Author a presentation, pitch deck, or navigable interactive deck                                                   | [slideshow](guides/slideshow/GUIDE.md)               |
| 2        | Add plain captions or subtitles to existing talking-head footage without changing it                               | [embedded-captions](guides/embedded-captions/GUIDE.md)       |
| 3        | Create an explicitly short, unnarrated motion graphic, typically under 10s                                     | [motion-graphics](guides/motion-graphics/GUIDE.md)         |
| 4        | Market or showcase a website, product site, app, or company from a supplied brief or assets                      | [product-launch-video](guides/product-launch-video/GUIDE.md)    |
| 5        | Explain a topic, article, or notes with invented visuals                            | [faceless-explainer](guides/faceless-explainer/GUIDE.md)      |
| 6        | Other authored compositions or footage edits                                                                              | [general-video](guides/general-video/GUIDE.md)           |

Before finalizing the route, read `references/routes/<workflow>.md` — one small file per route: the canonical input/output/trigger contract plus that route's interview entry. If the candidate does not satisfy its contract, continue routing instead of forcing the match. Read only the matched route's file.

### Resolve common ambiguities

- A short animated title, logo sting, stat hit, chart hit, or standalone lower-third is [motion-graphics](guides/motion-graphics/GUIDE.md) when it is unnarrated and motion is the message. A static title card, narrated sequence, longer montage, or custom loop is [general-video](guides/general-video/GUIDE.md).
- An explicitly short motion graphic may use supplied text or a screenshot as source material. A product promo is [product-launch-video](guides/product-launch-video/GUIDE.md).
- "I want a storyboard" changes the review process, not the workflow. With no other routing signal, use [general-video](guides/general-video/GUIDE.md). A confirmed sketched `storyboard.html` may itself be the requested deliverable; the review loop defines that stop point.
- Specialized narrative workflows support up to about 3 minutes and are strongest around 30–90s. Route a clearly longer piece to [general-video](guides/general-video/GUIDE.md). Length never overrides an explicit deck, caption, or overlay deliverable.

## 3. Route once, then leave

For fresh creation the intent layer (`references/intent-interview.md`) runs the full conversation — triage, pitch round, must-haves, run-shape, hand-off — and **ends by writing `BRIEF.md`. The brief is the only routing artifact the workflow reads**; nothing later re-opens this skill or the interview. Answer every later "what did the route require?" from `BRIEF.md`.

## 4. Load domain guides on demand

| Need                                                                                                                                        | Guide                    |
| ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| Composition structure, timing attributes, tracks, variables, determinism                                                                    | [hyperframes-core](guides/hyperframes-core/GUIDE.md)      |
| Motion rules, scene blueprints, transitions, runtime adapters                                                                               | [hyperframes-animation](guides/hyperframes-animation/GUIDE.md) |
| Design specs, concept, palette, typography, narration, beat planning                                                                        | [hyperframes-creative](guides/hyperframes-creative/GUIDE.md)  |
| Init, lint, check, snapshots, preview, render, or diagnostics                                                | [hyperframes-cli](guides/hyperframes-cli/GUIDE.md)       |

Domain guides never take ownership of the end-to-end deliverable. Load only what the active workflow needs.
