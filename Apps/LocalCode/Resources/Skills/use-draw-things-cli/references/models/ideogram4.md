# Ideogram 4

Ideogram 4 uses a structured JSON caption. Describe the whole image, its visual
treatment, the setting, and each distinct subject or text element using the schema
below. Save the caption as the generation prompt.

## Caption construction

Choose the actual output dimensions first. Describe the scene globally, then
separate the background from distinct foreground subjects and text elements.
Preserve exact user copy, object counts, specified relationships, and visual style.
One coherent subject is one object element: describe a person's clothes and pose
inside that person's `desc`, rather than generating separate anatomy elements.

Use these model-input fields:

| Field | Content |
| --- | --- |
| `high_level_description` | Observational summary of the whole image, ideally within 50 words |
| `style_description` | Optional style, lighting, medium, and palette object |
| `compositional_deconstruction` | Required object containing `background`, then `elements` |

Set the output width and height through CLI generation settings. Plan composition
for those dimensions and keep the caption limited to the fields above.

## Key ordering and types

Preserve insertion order when writing JSON; do not alphabetically sort keys.

- With photographic style: `aesthetics`, `lighting`, `photo`, `medium`, optional
  `color_palette`. Set `medium` to `photograph`.
- With non-photographic style: `aesthetics`, `lighting`, `medium`, `art_style`,
  optional `color_palette`.
- Use exactly one of `photo` and `art_style` when a style object is present.
- Composition order: `background`, `elements`.
- Object element order: `type`, optional `bbox`, `desc`, optional `color_palette`.
- Text element order: `type`, optional `bbox`, `text`, `desc`, optional `color_palette`.
- Element `type` is `obj` or `text`. Descriptions and literal text are strings.

`bbox` is optional. When layout matters, use integer coordinates in the order
`[y_min, x_min, y_max, x_max]`, normalized to `0...1000`, with origin at the top
left. The first axis is **y**. A wide title across the upper part of an image might
use `[80, 100, 220, 900]`. Boxes express placement; they are not pixel crops or
guarantees of exact geometric reproduction. Account for the actual aspect ratio
when planning boxes and leave sufficient space for text.

Palettes use uppercase `#RRGGBB` values: up to 16 in the style object and up to 5
per element. Use the field name `color_palette`.

## Text and scene discipline

Put the exact visible characters in each text element's `text`. Describe its font,
weight, color, line arrangement, and relation to nearby subjects in `desc`.
Preserve accents and scripts as literal UTF-8. Use `\n` inside the JSON string
for an intentional line break. Do not add visible quotes unless the user wants
quote characters rendered. Prose references to copy may use single quotes.

Write `background` as the scene's setting: architecture, ground, sky, atmosphere,
and shared lighting. Floor texture, puddles, reflections, and ground shadows belong
there. Give individually placeable things—people, furniture, equipment, plants,
and loose props—their own object elements. This keeps the floor a receding surface
and prevents focal subjects from being duplicated in the setting.

Keep a subject's parts together. Describe clothing and pose within the person;
an open door and exposed interior within the car; a featured fish and its display
bowl as one unified subject. A prominent wall-mounted sign or picture can be
anchored briefly in the background and described as the first element, behind
foreground objects. Treat that as the same object in both descriptions.

Keep object descriptions focused on physical identity, material, color, pose,
orientation, and relationships. About 30–60 words usually suffices. Put shared
lighting and camera/render properties in the global description or style fields.
Use definite choices: one material, one color, one type category and weight. Anchor
placements to named objects or clear frame regions.

Preserve all enumerated content: each requested menu item, date, label, name, and
number needs its actual text. Describe distinct required visual units separately.
Complete an underspecified creative scene with coherent details, while preserving
explicit minimalism, empty space, exact copy, and object counts. Use supplied facts
for factual signage and product claims.
An instruction for a transparent-looking background does not establish that the
exported file has an alpha channel; verify the actual output if alpha is required.

## Worked caption

Brief: a portrait botanical market poster with exactly '春日市集' and
'SATURDAY 10–5', cream background, green illustration, readable hierarchy.

```json
{
  "high_level_description": "A portrait botanical market poster with two clearly separated text lines and a central illustration of spring leaves.",
  "style_description": {
    "aesthetics": "restrained botanical print, generous margins",
    "lighting": "even diffuse light across the paper",
    "medium": "graphic_design",
    "art_style": "flat green botanical illustration with fine contour lines",
    "color_palette": ["#F6F0E2", "#254B39", "#87A878"]
  },
  "compositional_deconstruction": {
    "background": "An unmarked warm cream paper field with ample breathing room around the headline, illustration, and footer.",
    "elements": [
      {"type": "text", "bbox": [80, 100, 220, 900], "text": "春日市集", "desc": "Large dark-green Chinese headline, centered, with strong readable strokes and generous character spacing."},
      {"type": "obj", "bbox": [300, 170, 730, 830], "desc": "A single botanical arrangement of spring branches with fresh green leaves, fine hand-drawn contours and flat color, contained between the two text areas."},
      {"type": "text", "bbox": [820, 140, 900, 860], "text": "SATURDAY 10–5", "desc": "Centered dark-green sans-serif footer, smaller than the headline, with crisp legible characters."}
    ]
  }
}
```

## Prepare and generate

Save the authored caption to a project file. Run the bundled preparation script,
resolving its path relative to this skill's root:

```sh
python "$APP_BUNDLE/Skills/use-draw-things-cli/scripts/prepare_ideogram_prompt.py" \
  caption.json --output prompt.json
```

It validates caption structure and writes compact UTF-8 JSON, retaining field
order and explicit layout boxes. It removes `aspect_ratio` if present and refuses
to overwrite an existing output. Fix reported warnings before generation.
Validation checks format, not artistic quality or prompt adherence.

Pass the resulting file to `draw-things-cli generate --prompt-file prompt.json`,
with an exact discovered model ID and explicit output path. Use the CLI's current
help for valid dimensions and sampling controls. Keep caption JSON separate from
`--config-json`.

Inspect every required text span and the hierarchy of the final image. For crowded
copy, adjust boxes, line breaks, and surrounding detail. For duplicated subjects,
remove duplicate descriptions from background/elements. Preserve exact text when
revising style or placement.
