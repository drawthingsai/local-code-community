---
name: office
description: Create, read, edit, analyze, and verify Word documents (.docx), PowerPoint presentations (.pptx), Excel workbooks (.xlsx), and CSV/TSV tables. Includes document formatting, slides and charts, spreadsheet data and formulas, tabular transformations, visual checks, recalculation, and PDF/image export. Use when these files are inputs or requested deliverables, not for live Office applications or cloud services.
---

# Office files

Follow the format-specific workflow from authoring and focused edits through checking and delivery:

- Word: [office-docx](references/office-docx.md) for paragraphs, runs, tables, and page layout with `python-docx`.
- PowerPoint: [office-pptx](references/office-pptx.md) for slides, text, tables, images, and charts with `python-pptx`.
- Excel and CSV/TSV: [office-xlsx](references/office-xlsx.md) for workbook creation and edits, data analysis, tabular transformations, formulas, formatting, and recalculation with `openpyxl`, pandas, and `office`.

Read only the relevant reference; load more than one when the task spans formats. Resolve its relative resources from the reference file's directory.

Python libraries create and edit the files. Native `office` supports visual checks by rendering pages, slides, or cell ranges, exports requested formats, and refreshes spreadsheet formula results. Follow each reference's checks: structural and content checks do not establish visual fidelity, and rendering does not validate formula results.

Use the bundled `python3` and native `office` commands through Bash. Python cannot spawn commands; run Office operations in separate Bash calls. Bash starts in the selected project, so keep paths project-relative and put new artifacts under `outputs/` unless the user chooses another location. The filenames in the examples are illustrative.

Prefer one reusable script for inspection, edits, and verification. Use document-library APIs and focused checks. Inspect raw OOXML or library source only when a specific unresolved issue requires it.

Use `view` to inspect rendered images when the current model accepts images. Finish with project-relative Markdown links to the final files.
