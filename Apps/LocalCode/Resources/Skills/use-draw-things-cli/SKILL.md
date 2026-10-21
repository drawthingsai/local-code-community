---
name: use-draw-things-cli
description: Generate and edit images or create videos with draw-things-cli. Use for model selection, model-specific prompting, reference-image workflows, and creative video production, including assets for websites, presentations, and other projects.
---

# Use Draw Things CLI

Use the available `draw-things-cli` command for requested image and video generation.

For a clear generation or editing request, proceed directly without asking the
user to reconfirm. For edits, inspect the source images before generating and use
the actual source files as inputs. Resolve attached images to accessible files; if
a required source is unavailable, ask for it rather than silently generating a
replacement from text alone. For a new image, omit image inputs unless the user
requests reference conditioning or a linked workflow prepares one.

## CLI usage

Read the running CLI's help before use, then inspect the relevant command:

```sh
draw-things-cli --help
draw-things-cli models --help
draw-things-cli generate --help
```

Use `<command> --help` for further subcommand details. The running CLI's help is
the source of truth for available commands, flags, defaults, and constraints.
Discover models with `draw-things-cli models list` and use an exact model ID from
the output. Use the user's chosen model and execution backend when specified;
inspect current help for cloud or remote setup and authentication when needed.

Prefer the 8-bit S (`i8x`) variant of the selected model when available for faster
generation, unless the user specifies a different quantization.

## Allow generation to finish

Image generation can take a few minutes to finish; video can take considerably
longer. Be patient. Local generation unloads the local text model to free memory.
Resuming the assistant repeatedly to check progress can reload that model and
compete with generation for memory. Finish prompt preparation and input inspection
before launching, then give the generation job time to run.

Set `refresh_sec: 120` on the initial `bash` call and subsequent `bash_wait` calls
for the returned job. Use the longest permitted wait if the environment imposes
a shorter limit. A refresh interval is not a deadline: omit `timeout_sec` unless
a deliberate runtime limit is needed.

Avoid frequent `bash_status` queries, unrelated assistant work, or concurrent local
generation while it runs. A quiet interval alone is not evidence of failure: do
not restart, duplicate, or cancel the job just because output has not appeared yet.
Resume inspection and reporting after completion, or investigate when the job
reports an error.

## Image model selection

When the user has not chosen a model, select one based on the task. Read the
selected model's linked reference before writing or revising its prompt. All
listed models support text-to-image generation; FLUX.2 and Qwen also support
image editing. Preferred uses guide selection without limiting a model to those
subjects or styles.

| Model and reference | Workflows | Preferred use |
| --- | --- | --- |
| [ERNIE Image / Turbo](references/models/ernie-image.md) | Generation | Dense text rendering, including posters and infographics |
| [FLUX.2 Klein 9B](references/models/flux2-klein-9b.md) | Primarily editing | Image editing |
| [Qwen Image 2.1](references/models/qwen-image-2.1.md) | Generation and editing | Native transparency; generation and editing at 2K resolution or higher |
| [Ideogram 4](references/models/ideogram4.md) | Generation | Controlled placement of objects and text using bounding boxes |
| [Krea 2 Raw / Turbo](references/models/krea2.md) | Generation | General image generation, including photoreal scenes; high aesthetics and diverse art styles |

For editing tasks that combine subjects from multiple reference images, try
Qwen Image 2.1 if FLUX.2 Klein 9B does not produce the requested result.

When a model offers a Turbo variant, use Turbo by default for fast iteration.
Use its other variants only when the user explicitly requests them.

Honor the user's chosen model. When selecting one, account for available models
and device resources.
For other models, use their available guidance and the CLI's recommended settings.

## Precise infographics

For posters and infographics whose chart geometry must match supplied data, read
[Precise infographics](references/workflows/precise-infographics.md) before
generating or revising.

## MiniMax H3 video references

Use H3 FL2VA for text-only generation, first-frame animation, or first/last-frame
animation; all three use the same checkpoint. Use Ref2VA for image-content or
audio references.

Read [H3 prompting](references/minimax-h3/prompting.md) for every H3
generation. For a specialized creative task, also read the matching workflow:

| Request | Workflow |
| --- | --- |
| Minimalist product advertisement | [Minimalist product ad](references/minimax-h3/workflows/minimalist-product-ad-generator.md) |
| Stylized narrative animation | [3D animation short](references/minimax-h3/workflows/3d-animation-short-generator.md) |
| Brand, product, website, or app promotion | [Brand promo](references/minimax-h3/workflows/brand-promo-video-generator.md) |
| Two-player game menu or intro | [Co-op game intro](references/minimax-h3/workflows/co-op-game-intro-generator.md) |
| Hand-drawn animation in a live-action setting | [Handdrawn live video](references/minimax-h3/workflows/handdrawn-live-video-generator.md) |
| Music video with lyric typography | [Music video](references/minimax-h3/workflows/music-video-subtitle-generator.md) |
| Editorial paper-cutout explainer | [Paper collage](references/minimax-h3/workflows/paper-collage-explainer-generator.md) |
| Layered paper diorama / educational stop motion | [Papercraft explainer](references/minimax-h3/workflows/papercraft-stop-motion-explainer.md) |

Load only the references relevant to the requested output. A request for one image
or a prompt does not require a full video production workflow. For still-image
assets within a video workflow, use the corresponding image model reference.

## Execution and review

Start with the selected model's recommended settings; override them when the task
requires it. If a cloud generation fails because the account
cannot cover it, the environment offers an Add funds action; tell the user, and offer
a smaller request (size, frames, or steps) or local generation. To report a request's
size, run the same command with `--estimate`, which prints its compute units without
generating. Use `--prompt-file` for long or structured prompts. Prompt JSON is
distinct from `--config-json`, which controls generation settings.

Unless the user specifies another destination, save media directly in the current
project folder, for example `--output ./image.png`. Always specify `--output` and
use `pwd` to confirm the folder. In Local Code, `~` is the workspace root; a project
named `project-1` directly under it is accessible as `~/project-1` through the
sandbox's virtual path mapping.

Keep prompts in the project and preserve user-provided originals. Save revisions
under new filenames so earlier versions stay available. After completion,
verify the reported files exist and inspect results against the brief, especially
exact text, identity, layout, and continuity. Keep confirmed constraints through
revisions; change the part responsible for the observed failure.
Include the resulting image or video in the reply using the
environment's supported media embedding syntax and the actual output path.
