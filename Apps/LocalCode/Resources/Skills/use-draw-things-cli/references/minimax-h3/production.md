# Shared production workflow

Use this workflow when a deliverable needs several assets or clips and a final
edit. Write each generation prompt using [H3 prompting](prompting.md).

## Scope and project records

Start from the requested deliverable: prompt, still, one clip, or assembled film.
Record the brief, aspect ratio, duration, exact copy, visual constraints, references,
and intended audio. Reuse information already provided. Ask only for missing
information that materially affects the result, and carry existing authorization
through the requested production.

Keep a compact plan in the selected project when work spans multiple assets or
clips. Record source paths and roles, final prompts, model IDs, relevant settings,
shot order, actual durations, and generated output paths. Preserve user originals.
Use meaningful filenames such as `shot-01-prompt.txt`, `shot-01.mp4`, and
`edit-plan.md`. When revising an asset, record its current path and use that version
in subsequent prompts and assembly.

## Prepare only the assets the job needs

Separate identity references, scene references, composition/keyframes, and typography
plans. A multi-panel review sheet is not automatically an appropriate video input:
the model may animate the grid and labels. Generate or extract the actual full-frame
shot asset when needed. Choose an available image model using its dedicated guide.

Inspect inputs and anchors before generation. Keep product identity, character
appearance, clothing, aspect ratio, palette, and recurring props consistent. For
products or interfaces, use real supplied details and legible source copy; obtain
essential missing facts rather than inventing specifications or business claims.

Choose the input mode and attach the corresponding image or audio files using the
current CLI interface. Use FL2VA with no images for text-only generation, one clean
opening frame for first-frame animation, or opening and ending frames in that order
for first/last-frame animation. Use Ref2VA for identity/content or audio references.
Record which role each asset serves.

## Generate and assemble

For each clip, translate the creative plan into the appropriate H3 prompt structure.
Use the actual duration for shot timing. Longer stories need separate clip plans,
continuity handoffs, and an editing timeline; generating files alone does not produce
an assembled film. Keep reruns focused on observed failures and within the requested
scope rather than launching an open-ended search for variants.

If assembly is part of the request, inspect the available editing tools and use
them to join clips, conform timing, handle audio, and export the deliverable.
Where a required editing tool is unavailable, finish the useful
assets and give a precise account of the remaining assembly limitation.

For an exact supplied soundtrack, use one master track on the final timeline.
H3 audio references influence generated audio; they do not guarantee verbatim
reuse. Mix one continuous music bed across the edit, lower it beneath dialogue and
important effects, and preserve useful clip sounds with deliberate transitions.

## Inspect and deliver

Review representative frames at the opening, important actions/cuts, and ending;
watch motion and listen to audio when the available tools permit. Check exact text,
identity, object interaction, scene continuity, clip boundaries, and soundtrack
timing. Verify output files and media metadata. State any review limitation clearly.

Return the requested artifact and its location, with concise notes on meaningful
deviations. Keep prompts and source records available for revision. Do not call a
storyboard a video, separate shots a finished film, or a concept animation a working
application or game.
