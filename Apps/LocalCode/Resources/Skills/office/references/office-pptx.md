---
name: office-pptx
description: Create, read, edit, and check PowerPoint presentations (.pptx), including slide text, tables, images, and charts. Use when a PPTX file is an input or requested deliverable. Load this skill before running Office commands. Use only bundled LibreOffice unless the user explicitly opts out; without that opt-out, do not search for another LibreOffice executable.
---

# PowerPoint presentations

Follow an explicit user or applicable AGENTS.md requirement for an environment or library. Otherwise use the bundled `python3` command with python-pptx. Do not install packages or discover a system Python for the default workflow. Report a missing dependency only when it prevents the requested operation.

Keep scripts and output files in the task workspace. The runtime and skill directory contain shared read-only resources. Match the requested slide language and the supplied presentation's design when editing it.

## Create and edit

Use `python-pptx` to inspect or modify an existing presentation. Inspect slide layouts, text runs, images, tables, and charts before editing. Change only the requested content, preserve mixed text formatting, and save to a new file unless the user requests an in-place edit. Rebuilding slides can discard unsupported animation, SmartArt, or other extension content.

For a new deck, use `python-pptx` with editable text, tables, and charts. Use local image assets rather than network-dependent image URLs. Set slide dimensions, text sizes, and chart data explicitly.

A minimal editable deck, run with the selected Python executable:

```python
from pptx import Presentation
from pptx.chart.data import CategoryChartData
from pptx.enum.chart import XL_CHART_TYPE
from pptx.util import Inches, Pt

presentation = Presentation()
presentation.slide_width = Inches(13.333)
presentation.slide_height = Inches(7.5)
slide = presentation.slides.add_slide(presentation.slide_layouts[6])
title = slide.shapes.add_textbox(Inches(0.6), Inches(0.4), Inches(12), Inches(0.8))
run = title.text_frame.paragraphs[0].add_run()
run.text = "Quarterly report"
run.font.size = Pt(30)
data = CategoryChartData()
data.categories = ["Q1", "Q2"]
data.add_series("Revenue", [12, 18])
slide.shapes.add_chart(XL_CHART_TYPE.COLUMN_CLUSTERED,
                       Inches(0.8), Inches(1.6), Inches(11.5), Inches(4.8), data)
presentation.save("report.pptx")
```

Use `Inches` or `Cm` for positions and sizes and `Pt` for font sizes. To edit a generated title while retaining its other slides and charts:

```python
from pptx import Presentation

presentation = Presentation("report.pptx")
for shape in presentation.slides[0].shapes:
    if shape.has_text_frame and shape.text == "Quarterly report":
        shape.text_frame.paragraphs[0].runs[0].text = "Quarterly results"
presentation.save("report-edited.pptx")
```

Check that text and images fit the slide dimensions, titles form a useful sequence, and chart labels agree with source values. A native chart's embedded workbook is part of the deliverable and must contain the intended data. Library support for writing PPTX is not a rendering engine or a guarantee that every PowerPoint feature survives editing.

## Check and deliver

Use `read` with `whole=true` and `raw=true` to read [the shared checker](../scripts/check_office.py), then `write` its unchanged contents to `outputs/check_office.py`. The bundled skill path is readable by file tools, not ordinary Python paths. Run the project copy with the bundled interpreter:

```text
python3 outputs/check_office.py <presentation.pptx> --out outputs/checks.json
```

It checks ZIP/XML integrity and internal relationships and reports slide count and extracted text. Use repeated `--contains TEXT` arguments for required slide text and `--count N` for a requested slide count; `--contains` excludes chart text and speaker notes. Reopen the file to check the requested edits, chart data, and notes. Structural success does not establish text fit, alignment, readable contrast, or rendering fidelity.

Render for requested images/PDFs or an actionable layout check. Before generating images only for inspection, establish that the current model accepts images. If it does not, finish structural and content checks and state that visual layout was not inspected; do not rasterize slides the model cannot read, retry `view`, or choose a second model.

Use the bundled LibreOffice binaries unless the user explicitly asks not to use them. Without that explicit opt-out, never search for or invoke system LibreOffice, `soffice`, an application-installed binary, or a downloaded replacement. If the bundled CLI is unavailable or fails, report that failure instead of substituting another executable.

Run the bundled native `office` command through Bash, starting with `office capabilities --json` once when an Office operation is needed. Do not search PATH, guess a package directory, use `npx`, or install a renderer. Render slides directly:

```sh
office render --input report.pptx --output-dir preview-v1 --pages 1,3,4 --dpi 144
office convert --input report.pptx --output report.pdf
```

Batch affected slides in one call; inspect every slide for a new deck or a whole-deck design review. Read the returned manifest and selected image paths, including missing-font diagnostics. Outputs must be new directories/files. Retain and reuse previews for the same saved source; rerender only after edits, for missing slides, or to diagnose a concrete failure. Check clipping, alignment, contrast, and chart labels. Do not substitute guessed geometry for visual evidence or repeat successful exports of unchanged slides.

If rendering is unavailable or fails, retain the usable source and report the inspection limit. Do not search for COM automation, install conversion packages, or build another renderer for routine QA. LibreOffice previews do not certify pixel-identical PowerPoint or Keynote output, animation, or media playback. Deliver once the requested content and applicable checks pass.

Link the actual final file with an ordinary project-relative Markdown link. Keep that file in place and omit intermediate scripts, previews, and QA reports unless requested.
