# Krea 2

Use for Krea 2 Raw and Turbo. Write one cohesive natural-language paragraph that
preserves the brief and makes its visual treatment concrete.

## Write a coherent visual description

Long, detailed descriptions can improve
control, while simple ideas can work with short prompts. Match the amount of
detail to the brief; do not expand an already clear prompt just to make it longer.

Build one cohesive paragraph around the subject and its action, then composition,
environment, medium, lighting, materials, and atmosphere. Keep every attribute
attached to its owner. A worn red chair and a blue jacket should remain visibly
different objects, not a detached list of colors and textures.

Keep expansion faithful to the request:

- Preserve the original subjects, actions, colors, and spatial relationships.
- Keep an explicitly requested medium: a photograph remains a photograph, a
  drawing remains a drawing, and a 3D render remains a 3D render.
- Add grounded rendering detail where it supports the request. Do not invent new
  props, people, animals, narrative events, or highly specific clothes and colors
  that the brief does not support.
- For a detailed prompt, polish lightly rather than redesigning the scene.
- Keep planning internal. The generation input is the finished prose paragraph,
  without JSON, bullets, a rationale, or planning tags.

## Useful visual specificity

Name the visible behavior of light and materials: overcast light on a matte painted
surface, a narrow highlight on polished metal, translucent backlit leaves, or
coarse ink on cream paper. Relate detail to the desired image instead of adding
unrelated prestige adjectives.

For photographs, use viewpoint, framing, depth of field, and focus to establish
what the viewer should notice. For illustration, name the mark-making and color
treatment: flat fills, dry brush, halftone, stipple, thin contours, or broad shapes.
Describe intentional negative space when the image must accommodate other content.
Do not change a requested centered view merely to make the composition more dramatic.

For visible text, put the exact words in double quotes and specify where and how
they appear. Preserve the requested language and spelling. A typography cue must
not replace the literal text.

## Examples

Brief: a close-up of a green glass bottle on a limestone ledge, morning window
light, photographic, no added props.

```text
A close-up photograph of one green glass bottle standing on a pale limestone
ledge beside a window. Soft morning light passes through the translucent glass,
casting a muted green patch across the stone. The camera sits level with the
bottle's lower shoulder, with the bottle sharply focused and the plain background
gently softened. The quiet composition leaves open space around the silhouette
and shows the small natural pores of the limestone.
```

Brief: a flat illustration of a red bicycle against a blue wall, with a small sign
reading 'REPAIR SHOP'.

```text
A flat-color illustration of a red bicycle leaning against a blue wall, shown
from the side with both wheels fully visible. Thin dark contour lines define the
frame, spokes, and handlebars. A small rectangular sign fixed to the wall above
the bicycle reads "REPAIR SHOP" in clear cream-colored sans-serif letters. Broad
untextured color areas and a restrained ground shadow keep the arrangement simple
and make the red frame stand out against the blue background.
```

These examples illustrate the method; retain the user's own details and composition
when they differ.

## Variant and CLI handoff

Select Raw or Turbo from the actual model list and use that checkpoint's
recommended settings. Raw is the undistilled model; Turbo uses a distilled sampling
path. Retain the chosen variant's sampling defaults when revising the prompt.

Write the finished paragraph as UTF-8 text and pass it through `--prompt-file`.

Check subject/attribute ownership, medium, requested text, and fidelity to the
brief. If the result drifts, remove unsupported embellishment and tighten the
relationship causing the error. For weak style, make the relevant material,
lighting, or mark-making more concrete without adding unrelated content.
