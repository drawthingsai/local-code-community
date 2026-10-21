---
name: office-xlsx
description: Read, create, and modify Excel workbooks (.xlsx), including data, formulas, formatting, and pandas analysis, and transform CSV/TSV tables. Use for spreadsheet inputs or deliverables. Load before running Office commands. Data and formula tasks skip visual inspection; inspect only for formatting or layout needs. Use only bundled LibreOffice unless the user explicitly opts out; without that opt-out, do not search for another LibreOffice executable.
---

# Excel workbooks

Follow an explicit user or applicable AGENTS.md requirement for an environment or library. Otherwise use the bundled `python3` command with openpyxl and pandas. Do not install packages or discover a system Python for the default workflow. Report a missing dependency only when it prevents the requested operation.

Keep scripts, working files, and outputs in the task workspace. The runtime and skill directory are shared read-only resources. Save to a new workbook unless the user requests an in-place edit.

## Read and modify

For a read-only question or diagnosis, inspect the relevant cells, formulas, labels, types, and dependencies without rewriting or exporting the input.

Use `openpyxl` for existing XLSX workbooks and targeted cell or style changes. Load with `data_only=False` when formulas must survive. Inspect sheet names, the affected cell types, formulas, styles, merged ranges, and referenced ranges before editing. Check the saved file by reopening it, including unchanged content that the request requires preserving.

Preserve number formats, dimensions, freeze panes, tables, data validation, conditional formatting, named ranges, and chart references that intersect the edit. Extend only the affected structures. `insert_rows` moves cells but does not update dependent formulas, table ranges, conditional formatting, or chart references; update those explicitly and compare the saved result with the source.

Use pandas for data analysis and transformations. A DataFrame is not the workbook: exporting it over an existing file can lose sheets, formulas, charts, and formatting. Write analysis results back to the intended ranges with openpyxl. `XlsxWriter` can create new workbooks, but cannot read or modify existing ones.

Keep inputs and consequential assumptions in labeled cells, and express derived values as formulas with the intended relative and absolute references. Keep chart source data visible and auditable. Read [the openpyxl recipes](openpyxl-recipes.md) when examples of cross-sheet formulas, style preservation, native charts, or CSV/TSV handling would help.

For a new workbook, the selected Python environment can write editable values, styles, and formulas directly:

```python
from openpyxl import Workbook
from openpyxl.styles import Font

workbook = Workbook()
sheet = workbook.active
sheet.title = "Revenue"
for row in [("Quarter", "Revenue"), ("Q1", 12), ("Q2", 18), ("Total", "=SUM(B2:B3)")]:
    sheet.append(row)
for cell in sheet[1]:
    cell.font = Font(bold=True)
sheet.column_dimensions["A"].width = 18
sheet.column_dimensions["B"].width = 18
workbook.save("report.xlsx")
```

Preserve numbers, dates, booleans, and identifiers as the intended cell types; formatting is not a type conversion. For modifications, load the existing file with `openpyxl.load_workbook("input.xlsx", data_only=False)`, change the requested ranges, and save a separate result. Avoid a DataFrame round trip when workbook features must survive.

Writing a formula does not calculate its result. openpyxl and XlsxWriter do not evaluate Excel formulas; `data_only=True` returns stored cached values that may be absent or stale. Read the native command capabilities as described below. When it supports `recalculate`, use `office recalculate --input report.xlsx --output recalculated.xlsx` to save formulas and refreshed cached results to a new workbook. Reopen that result with both `data_only=False` and `data_only=True` to check formulas and calculated values against the requested logic. Recalculation does not validate business logic or guarantee Excel-specific feature compatibility. Without a recalculation engine, state the limit; do not replace requested formulas with constants or report old cached values as newly calculated results.

Do not rename `.xls`, `.xlsb`, encrypted files, or macro-enabled files to `.xlsx`. They need an appropriate supported operation. `keep_vba=True` can preserve VBA package content in an XLSM workflow, but does not execute or edit macros and does not guarantee every advanced workbook feature survives. Preserve the original and verify such requirements explicitly.

## CSV and TSV

Use pandas or the standard `csv` module for tabular analysis and transformations. Preserve the intended delimiter, headers, encoding, quoting, dates, missing values, and row grain. Read identifiers such as account IDs, ZIP codes, and values with leading zeroes as text. A missing value used as zero in a calculation need not become zero in the exported source column.

Reopen each CSV/TSV output with the intended parsing rules and check its schema, row count, identifiers, missing values, representative records, and key totals against the requested transformation. Use these data checks for CSV/TSV files and the workbook checks below for XLSX outputs. Do not pass CSV/TSV inputs to the OOXML checkers or native `office` command.

## Check and deliver

Use `read` with `whole=true` and `raw=true` to read [the shared checker](../scripts/check_office.py), then `write` its unchanged contents to `outputs/check_office.py`. The bundled skill path is readable by file tools, not ordinary Python paths. Run the project copy with the bundled interpreter:

```text
python3 outputs/check_office.py <workbook.xlsx> --out outputs/checks.json
```

It checks ZIP/XML integrity and internal relationships, and reports sheet names, populated-cell counts, and formula counts. Repeated `--contains TEXT` arguments check string cells and sheet names, and `--count N` checks sheet count. `--contains` excludes numeric cells and does not validate formula results; verify those separately with openpyxl. The checker does not calculate formulas or judge workbook appearance. Compare relevant values, types, formulas, styles, and totals with the task's source data.

For deeper workbook inspection, [verify_workbook.py](../scripts/verify_workbook.py) optionally reports selected cells' formulas, cached values, types, and formats, plus tables, merged ranges, validation, conditional formatting, and chart references. Use it when those properties matter to the edit or diagnosis; it is not an additional required pass for every workbook. Copy it unchanged into `outputs/verify_workbook.py` using `read` and `write`, as for the shared checker, then run:

```sh
python3 outputs/verify_workbook.py \
  --project-root . outputs/result.xlsx \
  --expect-sheet Inputs --expect-sheet Summary \
  --cell 'Summary!A1' --cell 'Summary!D8'
```

This helper reports properties and obvious error tokens. Compare its report with the source and expected results; it does not prove that edits preserved the workbook, calculate formulas, or establish visual fidelity.

For data and formula tasks, deliver after structural and data checks pass. Skip preview rendering and visual inspection, and do not add an unrequested caveat that visual inspection was omitted. Basic styling such as bold headers or number formats does not itself require visual inspection. Formula recalculation is independent of rendering and remains necessary when calculated results must be refreshed.

Inspect relevant regions when the task concerns formatting, layout, chart appearance, print layout, or a known display problem. Before generating inspection images, establish that the current model accepts images. If it does not, finish structural and data checks and report the requested visual check as unavailable; do not rasterize unreadable previews, retry `view`, or choose a second model. Export requested images or PDFs even when visual inspection is unnecessary.

A successful command or image read does not prove that a preview contains workbook content. For a populated range, a fully transparent or uniformly blank image is a renderer failure, not evidence that the workbook needs fixing. Stop all visual QA for that workbook immediately; do not try a wider range, another sheet, a different DPI, or another output format. Check suspicious previews with the bundled Pillow library, compositing RGBA onto white before comparing pixels. Do not create diagnostic workbooks, repeatedly retry rendering, modify print settings, or convert to PDF solely to investigate a failed preview. Preserve the requested workbook changes, finish structural and data checks, and report the visual check as unavailable. Only change print areas or scaling when the user requests printed layout.

## LibreOffice operations

Use the bundled LibreOffice binaries unless the user explicitly asks not to use them. Without that explicit opt-out, never search for or invoke system LibreOffice, `soffice`, an application-installed binary, or a downloaded replacement. If the bundled CLI is unavailable or fails, report that failure instead of substituting another executable.

Run the bundled native `office` command through Bash, starting with `office capabilities --json` once when an Office operation is needed. Do not search PATH, guess a package directory, use `npx`, or install a renderer. For worksheet rendering, select an exact sheet name and the relevant cell range:

```sh
office render --input report.xlsx --output-dir preview-v1 --sheet Summary --range A1:D20 --dpi 144
```

For a user-requested PDF export, use `office convert --input report.xlsx --output report.pdf`. PDF conversion is not a fallback for failed visual QA.

Use `--sheet`/`--range` for worksheets, not `--pages`. Direct worksheet images cover cell regions; PDF pages follow print settings and are not worksheet numbers. Include chart/drawing regions explicitly. Read the manifest's image paths, fragment rectangles, and missing-font diagnostics; large regions may split across images. Outputs must be new directories/files. Reuse previews for the same saved workbook and inspect additional regions only when needed. Check widths, formats, clipping, and charts; set print areas/scaling when printed layout is requested. Render each relevant region once. Rerender only after requested source changes; an empty or failed preview ends visual checking for the whole workbook.

If required rendering is unavailable or fails, preserve the usable workbook and report the inspection or export limit. Do not search for COM automation, install conversion packages, or build another renderer for routine QA. Preview rendering does not refresh the original workbook's formula caches or certify native Excel appearance. Deliver once the requested data and applicable checks pass.

Link the actual final file with an ordinary project-relative Markdown link. Keep that file in place and omit intermediate scripts, previews, and QA reports unless requested.
