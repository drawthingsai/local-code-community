# Qwen Image 2.1

Use this reference when preparing prompts for Qwen Image 2.1 with draw-things-cli.
Follow [Text-to-image](#text-to-image) for a new image and
[Editing](#editing) when working from input images. The language, prose style,
and paragraph rules below apply to the image prompt saved with `--prompt-file`.
For transparent assets, also read [Transparent images](#transparent-images).
For charts whose geometry must match supplied data, also read
[Precise infographics](../workflows/precise-infographics.md).

## Setup and model selection

Select the exact Qwen Image 2.1 model ID from `draw-things-cli models list` and use
that checkpoint's recommended sampling settings. Save only the finished description
or editing instruction as UTF-8 plain text and pass it with `--prompt-file`.

Set output dimensions with `--width` and `--height`, using values accepted by the
current CLI. Pass the chosen canvas image as the first `--image`, then either omit
both options to use its resolution, rounded to multiples of 64, or request a size
with its aspect ratio; the CLI warns when the canvas is smaller than the requested
size and has to be scaled up. When `--width` and `--height` don't match the first
image's aspect ratio, there is no canvas and every input is a reference; the CLI
warns about this, which is expected for scene generation. References keep their
full frame.

For edits, inspect the source images and pass them with repeated `--image`
options in the same order as their prompt references. Source images provide
reference conditioning. Keep denoising strength at `1.0`: omit `--strength` and
ensure any supplied generation config also uses `1.0`. Do not lower strength to
preserve the source; describe what changes and what stays in the editing prompt.

Specify `--output` and inspect the generated result for the requested content, exact copy, preserved
identity and regions, and framing.

## Text-to-image

Write the image prompt as a long English description of the finished image, using
the perspective of an observer looking at the frame. Keep it to one paragraph
except for the regional layout case in Step 5. Select the aspect ratio separately.

Prepare the prompt using the eight steps below in order, carrying each decision
through the remaining steps.

### Step 1 — Read the brief and split it in two

Identify what the user has fixed and what they have left open before drafting.

Fixed, and it must survive into your description unchanged: every string of text
they want shown, every named object, every count, every stated colour, every stated
position, and the aspect ratio if they gave one. Copy their text strings character
for character, in their own script, including punctuation and spacing.

A third thing they may give you is an instruction about the job rather than about the
picture — "use double quotes", "no hard-edged blocks", "4K, no noise", "make sure the
text is sharp". Apply these requirements when preparing the prompt and CLI options;
keep process instructions out of the image description.

Open, and you must decide it: everything they did not mention. A three-word request
and a three-hundred-word request both become a description of the same size, so a
short brief means you are inventing most of the frame, not writing less.

### Step 2 — Fix the frame

Decide the orientation from the subject, then pick the ratio.

If the user states a ratio, use it. Otherwise: `3:2` for anything horizontal and
`2:3` for anything vertical — these are the two defaults and cover most images.
Use `1:1` for a square badge, icon, album cover or single centred emblem, `16:9`
for a wide cinematic or presentation frame, `1:2` or `9:16` for a phone screen or a
tall standing banner. `3:4`, `2:1`, `21:9`, `4:3`, `9:21`, `4:5`, `3:1`, `5:4`,
`1:3` exist but only when the subject or the user really calls for them.

Apply the ratio through `--width` and `--height`. Never write a ratio, a resolution, or
a pixel count into the description itself.

### Step 3 — Write the opening sentence

One sentence, around twenty words. Name the medium, the style, the subject, and the
background or palette; usually name the orientation too:

`The image is a ⟨vertical / wide / square / tall⟩ ⟨style⟩ ⟨photograph · poster · illustration · scene · portrait · infographic · close-up · graphic · page · card · sheet · logo⟩ of ⟨subject⟩, ⟨the background and its palette⟩.`

`This is a …` or a bare `A vertical realistic photograph of …` work equally well. The
medium noun is the one part that is never omitted.

The style word goes here — realistic, photorealistic, minimalist, flat-vector,
cinematic, watercolour, isometric, editorial, hand-drawn, 3D-rendered, retro. Name
it once here; you may echo it in the closing sentence.

### Step 4 — Inventory before you write

Before continuing the prompt, identify the following two sets of details.

Every element that will appear, each with a place in the frame: upper-left,
across the top, on the far right, in the lower-third, in the centre, in front of,
behind, tucked into the corner. You will need eight to fourteen such positional
phrases, about ten typically, and they must reach the corners, the edges and the
centre — not cluster in the middle.

Every piece of text that will be legible in the image, in reading order.

### Step 5 — Walk the frame

Now describe it in order. Which order depends on how the frame is filled.

**If the frame is divided into regions** — a poster, a page, an interface, a layout, a
wide scene with several things in it — walk the regions:

1. The background and the surface it sits on — this comes immediately after the
   opening sentence, not at the end.
2. The top band: headline, header bar, sky, ceiling, whatever occupies the top edge.
3. Down and across the body of the frame: left side, then centre, then right side.
   Give each region one or two sentences.
4. The bottom band: footer, foreground, ground plane, base row.

**If one subject fills the frame** — a portrait, a close-up, a single object — walk
the subject instead: the background and how far it falls off, then the subject's pose
and where it is placed in the frame, then head and face, then body and each garment or
surface, then what is held or touching it, then whatever little is left at the edges.
Keep using positional phrases inside the subject — in the upper-left of the frame,
behind the left shoulder, along the lower edge — so the frame stays locatable.

Roughly a third of your sentences should open on the positional phrase itself —
"On the right side of the frame, …", "In the upper-left corner, …", "Across the
lower third, …" — so the reader always knows where they are looking.

Keep it to one paragraph. Break to a new paragraph only when the image is genuinely
built from stacked regions — panels, cards, sections, slides — and then one
paragraph per region, each opening on where that region sits.

### Step 6 — Set every piece of text

Skip this step if nothing in the image is meant to be read — a third of images have
no legible text at all, and inventing signage for them is a mistake.

Otherwise, for each string from your Step 4 list, in reading order, name where it sits,
what it looks like, and what it says: `a bold black headline across the top reads "…"`.

Put the string in straight double quotes, in its own script — Chinese, Russian,
Korean, Japanese and Arabic text stays in Chinese, Russian, Korean, Japanese and
Arabic. Give its weight, colour, case and relative size. Describe a line break as a
second line rather than putting a real newline inside the string. If a mark is not meant
to be read — distant signage, a label behind glass, dense body copy — call it
blurred, indistinct, or too small to read rather than inventing letters. If the image contains a chart
or a table, its axes, tick labels, legend entries, series and cell values are text
too: write them out.

### Step 7 — Give the lighting its own sentence

Every image has light in it, and the description always accounts for it: the source,
its direction, its quality, and the shadows and highlights it leaves. Soft diffused
daylight from a window on the left, hard overhead studio light, warm low sun, flat
even ambient light for a diagram.

Once the contents are placed, give it a sentence of its own — `The lighting is …` —
or, if the light is what makes a particular surface look the way it does, fold it into
that surface's sentence. Either way it is stated explicitly, not left implied.

### Step 8 — Close with the whole frame

End on a single sentence that steps back:

`The overall composition ⟨is / uses / feels⟩ …`

`The composition is …`, `The overall design …`, `The overall mood …`, `The overall
palette …` and `The image has …` are the same move. Cover balance and symmetry, the
palette, the style, and the mood in that one sentence. Write exactly one such
sentence — do not follow it with a second summary.

### Prompt writing rules

**Size.** The description runs about twenty sentences and four to five hundred words,
roughly twenty-five words a sentence. That is the same size whether the brief was three
words or three hundred: a dense frame with many regions and a lot of text runs longer, a
single quiet subject runs shorter, but a thin brief never buys a thin description.

**Observe, don't instruct.** Present tense, third person, declarative. No "you", no
"create", no "make sure", no "the AI should". No quality boosters — no "masterpiece",
"8K", "highly detailed", "award-winning".

**Hedge what you cannot be certain of.** An observer describing a picture says
"appears to be", "likely", "suggesting", and offers a pair — "a notebook
or a tablet", "wood or dark laminate" — when the thing is genuinely ambiguous. Do
this often; it is the natural register here. Be flatly definite only about what the
user fixed.

**Name colours with a modifier, almost never bare.** Deep navy, muted olive, pale
cream, warm terracotta, soft dusty rose, blue-grey, off-white, charcoal, brownish-
green. Hex codes only if the user gave them.

**Give the material, not just the noun.** Brushed metal, matte plastic, glossy
ceramic, coarse linen, weathered wood, frosted glass, grain, scuffs, condensation,
visible brush strokes, paper fibre.

**Enumerate; never summarise.** "Several items" and "various decorations" are not
descriptions. Say what each thing is. Write small counts as words — three, five,
twelve — and if something is partly hidden, say so and describe the visible part.

**People get their observable surface.** Build, posture, where they are looking,
expression, hair, skin tone, and each garment with its colour and material. Age is a
life stage or a decade — a child, a teenager, a young adult, middle-aged, elderly,
in her thirties — never a number of years. If a face is turned away or cropped, say
that instead of describing it.

**Objects by class, not by brand.** A silver laptop, a mirrorless camera, a compact
hatchback — unless the user named the brand. Photographic and design vocabulary is
welcome: shallow depth of field, bokeh, backlit, close-up, negative space,
grid, drop shadow.

**Everything holds together physically.** Shadows fall away from the light, reflections
match what is in front of the surface, scale is consistent between neighbouring
objects, and a surface reacts to what sits on it. If the user asked for something
impossible, describe it as the image shows it and let the rest of the scene stay
coherent around it.

### Prompt language

The description is always in English, whatever language the request arrives in. The
only exception is text shown inside the image, which stays in its own script.


## Editing

Choose the editing prompt's prose language and the image's visible text language
separately.

**(A) Prompt prose language:** Use the following language for the editing instruction outside quoted image text:

- User instruction is in Chinese → write the description in Chinese.
- User instruction is in English → write the description in English.
- User instruction is in any other language (Japanese, Korean, French, Spanish, Thai, etc.) → write the description in English.

**(B) Visible text language:** Choose the language of text rendered in the image, enclosed in double quotes, in this priority order:

1. If the user's instruction gives the exact text to write, OR names a target language for the text (e.g. "改成'夏日特惠'", "把标题写成英文", "add a Japanese title", "write the caption in Thai") → render exactly that text / in exactly that specified language.
2. Otherwise, if the input image already contains text → render in the dominant language of the image's existing text — even when the instruction is written in a different language.
3. Otherwise (the image contains no text and the instruction names no target language) → render in the language of the user's instruction itself — including Japanese, Korean, Thai, Arabic, French, etc.

Worked example: image is mostly Thai, instruction is in English asking to add/redesign a title without giving the exact words or a language → the rendered (quoted) text must be **Thai** (the image's dominant language), while the surrounding description (A) is still written in English.

Two reinforcements on decision (B): all rendered (quoted) text must be **monolingual** — do not mix Chinese and English inside the quotes and do not emit a bilingual pair unless the user explicitly asks for one. And **genre never overrides input language**: a "spec sheet / cinematic data-document / storyboard / technical parameter" look is achieved through layout and typography, NOT by switching rendered labels to English — every header, label, and caption stays in the decided language (standardized units and user-given proper nouns may remain Latin).

Use this section when one or more input images are available. Inspect them and turn
the user's edit request into a precise, actionable editing prompt.

### Core Objective

Write the editing prompt so Qwen Image 2.1 can execute it without guessing — anchored on what the input image(s) actually show, faithful to the user's intent, inventing nothing.

**How much you build is intent-branched.** When the user wants *this picture changed* (a local object/attribute/background edit, a text or UI edit, a quality or style change, a viewpoint/canvas transform), clarify and constrain: say exactly what changes, and let everything else stand. When the user wants *a new picture of this subject* (placing a subject in a new scene, compositing across images, a photo-shoot or poster or infographic built from a reference), construct actively: design the scene, lighting, composition and layout to a professional standard. Scale the elaboration to what was asked — a plain placement stays restrained, a styled shoot or a publication-grade poster is built out fully.

### The Governing Principle — Attribute Disentanglement at Full Strength

**Edit exactly the attribute(s) the user named, push each to a strong and unmistakable degree, and hold everything else at input fidelity.**

Both halves matter, and the two failure modes are symmetric:

- **Leakage** — touching what the user did not name (a sharpen that re-grades color, an upscale that reframes, a style change that drifts a face, an outfit swap that drops an accessory, a background change that "helpfully" cleans up something unmentioned).
- **Under-editing** — an output a viewer could mistake for the unedited input, because the requested change was applied faintly.

Preservation locks **content, never edit strength**. Recognizability is bought by naming what stays fixed, not by holding the effect back.

### What to Anchor, What to Decide

**Anchor on the image.** Every spatial, tonal and contextual claim comes from what is visibly there. If you are unsure a detail exists, leave it out — a preserved element described at a higher level of abstraction is always safer than an invented specific.

**Say what stays, without repainting it.** Name the untargeted content by type, position and role rather than describing its appearance, and prefer one blanket preservation clause over walking the frame. A preservation description reads to the model as a generation instruction: the more concretely you describe something you meant to keep, the more likely it drifts. Describe appearance concretely only for what you are actually changing, or when it is the only way to disambiguate between similar objects.

**Identity is the hardest invariant.** A person's facial identity and the personal accessories that make them recognizable; a product's exact design, markings and count; and the input's rendering medium (photograph, anime, illustration, sketch, 3D render, painting) all survive every edit unless the user explicitly targets them. When identity comes from a reference image, point at that image rather than describing features in words — verbal descriptions make the model regenerate and degrade the likeness.

**Resolve ambiguity, then commit.** Turn vague intent, imprecise spatial reference and unparameterized style words into something concrete and observable. Translate abstract quality language into the visual properties it implies. Where the instruction offers alternatives or contradicts itself, pick the most reasonable reading and state it as a decision. Keep the user's own action verb, spatial relations and described state intact, and treat anything they asked to preserve as absolute. Preserve creative or physically impossible intent rather than correcting it.

**Only what was asked.** Do not add operations the user did not request, and do not clean up unmentioned defects, overlays or clutter however prominent they look. When an edit removes, moves or reveals something, say enough about the newly exposed region that the result stays physically coherent.

**Text in the image is literal.** Whenever readable text will appear in the output, commit to the exact characters — every element, quoted, nothing summarized or abbreviated away. Text you cannot commit to should not be added at all. Match the typography and language the input establishes unless the user asks otherwise. When the operation extends the canvas outward, name it as outpainting explicitly.

**Write it as an instruction.** Lead with the operation, not a description of the finished picture, and write from the perspective of someone holding only the input image(s).

### Prompt preparation and review

Before writing the editing prompt, identify what the image(s) contain (including any visible text), the requested changes, the attributes to preserve, and the output size. Review the completed prompt: every visible element should be either targeted by the edit or covered by a preservation instruction; the requested change should be unmistakable; no unrelated changes should be introduced; and every quoted string should follow language decision (B).

### Image Reference Rules

Pass the input images through repeated `--image` options. Number references in
the same order as those inputs.

For multiple inputs (N ≥ 2), use `<image1>`, `<image2>`, ... in the editing prompt to refer to each input image. Use these tags in place of natural-language references such as "图1", "第一张图", "the first image", or "image A". For a single input, refer to the image naturally ("图像", "图片中", "the image") without a tag.

State each image's role explicitly — which one is the canvas whose composition and untargeted content survive, and which supply material to transfer — and say what is taken from each. For scene generation with no canvas (合影/合照 and the like), all images serve as identity sources. Describe every referenced image individually; never compress several into a range or a group to avoid describing them one by one.


### Output Size Determination

Choose either a target aspect ratio or an input image whose dimensions the output
should follow. Apply a ratio through `--width` and `--height`; to follow an input
image, pass it as the first `--image` and either omit both or keep its aspect
ratio. Keep this separate from the editing prompt.

#### Step 1: Check if the user explicitly specified a size or aspect ratio

Look for any of the following in the user's edit instruction:
- Exact pixel dimensions: "1920x1080", "800×600", "1080p"
- Aspect ratios: "16:9", "4:3", "3:2", "9:16", "1:1"
- Descriptive terms mapped to aspect ratios:
  - "正方形" / "square" / "头像" / "avatar" / "profile picture" / "专辑封面" / "album cover" → "1:1"
  - "横版" / "landscape" / "横屏" / "电脑壁纸" / "desktop wallpaper" / "宽屏" / "widescreen" / "视频封面" / "video thumbnail" / "PPT" / "幻灯片" / "slide" / "演示文稿" → "16:9"
  - "竖版" / "portrait" / "竖屏" / "手机壁纸" / "phone wallpaper" / "手机屏幕" / "Instagram story" / "Stories" / "Reels" / "短视频封面" → "9:16"
  - "手机全面屏" / "全面屏" / "iPhone屏幕" / "iPhone screen" → "18:39"
  - "安卓全面屏" / "Android screen" → "9:20"
  - "超宽" / "ultrawide" / "带鱼屏" → "7:3"
  - "电影画面" / "cinematic" / "电影比例" / "宽银幕" / "cinemascope" → "21:9"
  - "海报" / "poster" → "2:3"
  - "证件照" / "ID photo" / "passport photo" / "小红书" / "Xiaohongshu" → "3:4"
  - "iPad屏幕" / "tablet" / "平板屏幕" → "4:3"
  - "全景图" / "panoramic" / "panorama" → "2:1"
  - "名片" / "business card" → "9:5"
  - "A4" → "5:7" (vertical) or "7:5" (horizontal)
  - "1080p" / "720p" → "16:9"

**High-resolution keywords ("2K", "4K", "8K") are quality descriptors, NOT aspect
ratio indicators.** Determine the ratio from other explicit cues or the input
image. Use 2K-level output resolution by default, including when the request says
"4K" or "8K" without exact pixel dimensions. Honor explicit pixel dimensions within
the CLI's supported sizes.

If the user specified a size or ratio, use it instead of inheriting an input
image's size. Exact pixel dimensions also determine the ratio: 1920:1080 = 16:9.

#### Step 2: If the user did NOT specify any size or ratio

##### Single-image editing (1 input image)

The output should follow the input image's resolution.

**Exception — Single-image scene generation**: If the task generates a new scene
from scratch using the input image only as an identity reference (e.g., "拍一套写真",
"cosplay成X", "穿越到古代"), do NOT follow the input image's ratio — the output is a
new composition, not an edit of the existing image. Instead, choose by scene semantics:

| Scene type | Target ratio |
| --- | --- |
| Portrait / 写真 / half-body | 2:3 |
| Full-body scene / outdoor activity | 3:4 |
| Landscape-oriented scene | 3:2 |
| No clear orientation hint | Follow the input image's ratio |

##### Multi-image editing (N ≥ 2 input images)

Identify the **canvas image** whose composition and framing the output should
follow, then use that image's dimensions by passing it as the first `--image`:

| Edit type | Canvas |
| --- | --- |
| Compositing — transfer subject into a scene ("把A P到B中", "放到", "加入到") | The target scene image |
| Face/head swap ("换脸", "换头") | The body image |
| Clothing swap ("换衣服", "换装") | The person image |
| Style transfer ("画成X的风格", "风格迁移") | The content image, not the style reference |
| Background replacement | The foreground subject image |
| Local object replacement | The original image being edited |
| Scene generation — no canvas ("合影", "合照", "一起变老", "让他们X") | Choose a ratio using the table below |

For **scene generation tasks with no canvas** (合影, 合照, 一起吃饭, etc.), choose by
scene semantics:

| Scene type | Target ratio |
| --- | --- |
| Group photo / 合影 / 合照 | 3:2 |
| Portrait / 写真 | 2:3 |
| Poster / 海报 | 2:3 |
| Desktop wallpaper | 16:9 |
| Phone wallpaper | 9:16 |
| No clear orientation hint | Follow the last input image's ratio |

##### Outpainting (扩图 / 延伸画面)

When the user did NOT specify a target aspect ratio, infer the new ratio from the
extension direction:

- Extend **right only** or **left only**: widen the ratio. E.g., a 1:1 input → 3:2;
  a 3:4 input → 1:1 or 4:3.
- Extend **both left and right**: widen more aggressively. E.g., a 1:1 input → 16:9
  or 2:1.
- Extend **down only** or **up only**: make the ratio taller. E.g., a 1:1 input → 2:3;
  a 16:9 input → 4:3 or 1:1.
- Extend **both up and down**: make the ratio significantly taller. E.g., a 1:1
  input → 9:16.
- Extend **all sides**: keep the original ratio; the image grows uniformly.

As a general rule, estimate the extended area as roughly 30%–50% additional space
in the specified direction(s), then compute the new W:H ratio accordingly.

##### Panoramic generation (全景 / panorama)

| Panoramic type | Target ratio |
| --- | --- |
| Standard panorama / 全景 | 2:1 |
| Wide panorama / 超宽全景 | 3:1 |
| 360° / VR panorama | 2:1 |
| User specified a different ratio | Use the user's specified ratio |

##### Three-view drawings and multi-grid generation (三视图 / 多宫格)

When the user did NOT specify an aspect ratio, do NOT use a fixed default.
Determine it adaptively from:

1. **Subject shape proportion**: a tall standing person is vertically oriented,
   a car is horizontally oriented, a round object roughly square.
2. **Panel layout arrangement**: how the panels are arranged (1×3 horizontal,
   3×1 vertical, 2×2) and the shape of each panel.
3. **Combined ratio**: (single panel W × columns) : (single panel H × rows),
   choosing the ratio that best fits the content without excessive empty space
   or cropping.

Examples:
- Three side-by-side views of a standing person (each panel ~1:3, portrait) →
  overall ratio = 1:1 — do NOT over-widen to 2:1 or 3:1, which would squash each
  portrait panel; use 3:1 only when each panel is itself landscape, e.g., a car.
- Three side-by-side views of a car (each panel ~3:2) → overall ratio = 3:1 or 9:2.
- 2×2 grid of a square object → overall ratio = 1:1.
- 3×3 grid of square panels → overall ratio = 1:1.

### Editing prompt format

- Write the editing prompt as a single continuous paragraph without line breaks or newline characters (`\n`).
- All text that should appear as visible, readable content in the output image must be enclosed in double quotes (""). Descriptive or structural language that does not appear as rendered text should NOT be quoted.
- **Never include any resolution or aspect ratio information in the editing prompt** (e.g., "2:3", "16:9", "1920x1080", "2K", "4K"). Apply resolution and aspect ratio through `--width` and `--height`.
- Write it out in full — no ellipsis, no truncation.
- State requirements affirmatively ("保持背景与输入图完全一致") rather than as prohibitions ("禁止改变背景"). Standard preservation phrasing "保持/保留[X]不变" is fine.
- Be precise and decisive: no hedging, no unresolved alternatives, no vague degree words left unresolved.
- **Check visible text language last:** Review every double-quoted string against language decision (B). No quoted string may mix Chinese and English, form a bilingual pair, or carry a parenthetical translation gloss unless the user explicitly asked. Standardized units and user-given proper nouns may remain Latin.

Retain proper nouns and domain-specific terms in their original language, placed in English double quotes.

### Prepared chart composites

For a composite from [Precise infographics](../workflows/precise-infographics.md),
pass it as the only input and set `--width` and `--height` to its exact dimensions.
Instruct a match of the chart's typography, ink, texture, and background to the
surrounding artwork while keeping its axes, tick spacing, bar endpoints, row
positions, and quoted text unchanged; cover the rest with one preservation clause.

## Transparent images

For native transparency, use this framing around the subject description:

```text
This is an RGBA image with transparency. <your description>. The image has alpha channel and the background is transparent.
```

Save to PNG. For edits to a transparent source, retain its alpha channel.
