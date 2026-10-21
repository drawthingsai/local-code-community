# FLUX.2 Klein 9B

Use descriptive prose for generation and explicit change instructions for editing.

## Scope and model selection

Use the exact 9B model ID reported by `draw-things-cli models list`. Preserve the
user's chosen distilled/base variant and use that model's recommended settings.
Write the complete visual description before generation. Start with narrative prose, putting
the main subject and defining action first, then setting, composition, light,
materials, and the camera or medium. Roughly 40–70 words is a useful
starting point; adjust to the complexity of the request rather than
dropping required details to satisfy a word count.

## Prompt craft

- Attach each attribute and action to its subject. Use explicit spatial relations
  for multiple people or objects.
- Describe the light source, direction, softness, and effect on surfaces. “Soft
  window light from the left” gives a clearer target than “beautiful lighting”.
- Name materials and visible colors. For specified colors, include a color name
  with its `#RRGGBB` value and the object it applies to.
- Describe desired visible properties positively. Replace “no blur” with “sharp
  subject detail”; place omitted objects outside the scene definition. Do not
  build the prompt around a long negative-prompt list.
- Specify photographic parameters when they express the desired view. Avoid
  stacking incompatible lenses, media, and lighting setups.
- For lettering, use double-quoted exact copy and describe font category, weight,
  placement, hierarchy, and contrast. Keep the text language the user requested.

## Layout, color, and text

For multiple subjects, assign each a distinct position and describe their
interaction: who holds what, where they face, and which objects overlap. Establish
foreground, middle distance, and background in a consistent camera view.

Bind exact colors to named surfaces, for example “a matte forest-green #254B39
box with a cream #F6F0E2 label.” Limit competing colors when brand fidelity matters.
Use lighting that leaves the specified surface colors visible.

For typography, give each text span a place and role: headline, supporting line,
label, or footer. Specify one font category, weight, alignment, and contrasting
color per span. Put the most important copy early in the prompt. Use short lines
and sufficient space around letters; preserve every required word when simplifying
the surrounding design. For logos, describe the relationship between the symbol
and lettering so both belong to one composition.

## Editing and references

For editing, source images provide reference conditioning. Do not lower img2img
strength to preserve the source: omit `--strength` and leave it at `1.0`, including
in any supplied generation config. Control what changes and what stays through the
prompt.

For edits, name the change and the properties that must survive it: identity,
pose, camera, layout, object geometry, copy, or background. For example:

```text
Change the jacket to dark forest-green wool, keeping the person's face, hairstyle,
pose, white shirt, camera framing, and street background unchanged. Preserve the
original soft daylight and realistic folds along the sleeves.
```

Pass source images with `--image`. Identify the target precisely when several similar
objects are present: “the red cup on the left,” for example. For a style transfer,
describe the new rendering medium while explicitly preserving pose, layout, and
identity. For text replacement, name the old and new text and retain its position
and treatment. Break a difficult edit into separate passes when the changes are
independent, inspecting the result between passes.

When combining references, identify each by its input order and give it a specific
role: identity, style, setting, or layout. State what to take from each reference
and how those elements should be combined.

## Example

Brief: a landscape image of a small yellow delivery robot waiting at a rainy
crosswalk, with the word 'POST' on its side.

```text
A small yellow delivery robot waits at the edge of a rain-darkened city crosswalk,
its side panel clearly labeled "POST" in bold black sans-serif letters. Low,
three-quarter street-level framing leaves open space ahead of it. Overcast daylight
softly illuminates the painted metal shell, while warm shop-window reflections
stretch across wet asphalt. Documentary photograph with sharp subject detail.
```

## Review

Check subject identity, requested edits, unchanged regions, copy, and color
placement. Correct an ambiguous relationship or conflicting style cue before
adding more adjectives. Keep the seed and settings fixed when comparing prompt
revisions. Use current CLI help and recommended settings for execution.
