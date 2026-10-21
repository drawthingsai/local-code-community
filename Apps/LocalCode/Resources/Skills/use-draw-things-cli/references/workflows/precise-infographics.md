# Precise infographics

Use for posters and infographics whose chart geometry must encode supplied data.
Image models can print correct values on bars of the wrong length, and adding
proportional wording to the prompt does not reliably fix that. Draw the quantitative
layer in code, composite it into the design, and use an editing model only to blend
its appearance. A standalone data chart needs only plotting tools; a conceptual
explainer without quantitative geometry follows the model's ordinary guidance.

## Data and starting point

Keep source values, labels, units, ordering, baseline, and derived calculations in
a project script or data file, and carry the user's corrections through revisions.
Compute geometry from source values and round displayed labels separately; for
example, speed-up is baseline time divided by measured time. Label the baseline
and which direction is better.

- **Open layout:** render an accurate chart scaffold on the final canvas and edit
  its appearance, or generate the poster first with room reserved for the chart
  and composite the chart into it.
- **Existing composition to keep:** use that image as the base, measure its chart
  region, and replace the chart elements in place.

When model choice is open, use [ERNIE](../models/ernie-image.md) for the poster's
composition and typography and [Qwen Image 2.1](../models/qwen-image-2.1.md) for
editing a scaffold or composite. Read the selected model's reference before
prompting.

## Render the chart

Use the bundled Python runtime's Matplotlib (`Agg` backend) and Pillow; do not
install packages. Set canvas size, plot bounds, axis limits, ticks, row positions,
and label margins explicitly, and start bars at zero on a linear axis. If an
editing pass may follow, build the canvas at dimensions the CLI accepts so the
output can match it without scaling or cropping; resize or pad a copy of an
existing base before measuring it.

Export at fixed pixel dimensions without `bbox_inches="tight"` or automatic layout,
then check the saved image's actual size. Pillow uses a top-left origin; convert
Matplotlib's vertical coordinates deliberately. Render either a full-canvas
transparent layer or a cropped layer with a measured destination box.

Keep the script, the data, and each stage under its own name, for example
`poster-base-01.png`, `chart-01.png`, `composite-01.png`, and `poster-final-01.png`.

## Composite and inspect

Clear obsolete bars, ticks, guides, and values inside bounded regions, then place
the chart. Keep correct existing labels that fit the new geometry and replace the
rest. Account for illustrations that overlap the chart when choosing masks and
layer order. Alpha-composite layers of matching size, or paste a cropped layer at
its measured position; an opaque full-canvas patch pasted at an offset erases
surrounding content.

Open the composite and check the axis, bar endpoints, tick count and spacing,
clipped labels, leftover marks, and the headline, illustrations, and footer. Fix
missing content and wrong geometry here; a texture or ink mismatch can wait for
the editing pass. Skip that pass if the composite already meets the brief.

## Harmonize

Pass the inspected composite, or the scaffold for an open layout, as the single
editing input; separate poster and chart references leave alignment to the model.
Follow the selected model's editing guidance and keep the output dimensions equal
to the input.

## Verify

Check each independently on the delivered file:

- **Content:** labels, values, units, baseline, ordering, and all other required
  copy match the source. Correct printed numbers do not validate the chart.
- **Geometry:** locate the actual axis and ticks and check their spacing. For
  horizontal bars on a linear axis, recover each bar's value from its endpoint as
  `minimum + (x - left) / plot_width * (maximum - minimum)`. For other orientations
  or scales, invert the corresponding axis transformation. Decorative ink,
  hatching, and text can confuse automatic edge detection; inspect crops.
- **Composition:** framing, placement, retained artwork, and text match the base.

Report measured agreement at its real precision: a bar measuring 1.79 is not exact
because its label says 1.80. If geometry fails, fix the composite or tighten the
editing instruction before rerunning; do not deliver a polished but inaccurate
chart.
