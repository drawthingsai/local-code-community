---
name: office-docx
description: Create, read, edit, and check Word documents (.docx), including reports, letters, and formatted tables. Use when a DOCX file is an input or requested deliverable. Load this skill before running Office commands. Use only bundled LibreOffice unless the user explicitly opts out; without that opt-out, do not search for another LibreOffice executable.
---

# Word documents

Use `python-docx` for DOCX creation and ordinary edits. Follow an explicit user or applicable AGENTS.md requirement for a project environment or another library. Otherwise use the bundled `python3` command with python-docx. Do not install packages or discover a system Python for the default workflow. Report a missing dependency only when it prevents the requested operation.

Keep source scripts, intermediate files, and final documents in the task workspace; the runtime and this skill directory are read-only resources. Use the user's requested language and preserve an existing document's design unless a redesign is requested.

## Create and edit

For existing files, inspect paragraphs, runs, tables, sections, headers, and footers before changing the affected content. Save to a new file unless the user requests an in-place edit. Replacing a paragraph's `.text` destroys its run formatting; change the relevant runs when formatting must survive. Reconstructing the whole document can lose features outside python-docx's supported editing API.

Use paragraph styles for headings and body text. Size tables for the section that contains them, and account for merged cells and nested tables. Chinese, Japanese, and Korean text may need an explicit `w:eastAsia` font assignment in addition to `run.font.name`; font names alone do not establish glyph availability or rendered appearance.

For a new document, use the selected Python executable:

```python
from docx import Document

document = Document()
document.add_heading("Project report", level=0)
document.add_paragraph("Summary", style="Heading 1")
document.add_paragraph("The requested findings go here.")
document.save("report.docx")
```

python-docx does not paginate or render documents. Do not represent ordinary replacement, colored text, or comments as tracked changes. When real revisions or unsupported OOXML features matter, preserve their package parts and verify the requested operation rather than silently discarding them.

## Check and deliver

Use `read` with `whole=true` and `raw=true` to read [the shared checker](../scripts/check_office.py), then `write` its unchanged contents to `outputs/check_office.py`. The bundled skill path is readable by file tools, not ordinary Python paths. Run the project copy with the bundled interpreter:

```text
python3 outputs/check_office.py <document.docx> --out outputs/checks.json
```

It checks ZIP/XML integrity and internal relationships, and reports paragraphs, logical table dimensions, and sections. Optional `--contains TEXT` arguments assert required text. A successful structural check does not verify pagination, clipping, fonts, or visual appearance. Compare the summary and reopened document with the user's request, including unchanged content that matters to an edit.

Render for a requested image/PDF deliverable or an actionable layout check. Before generating images only for inspection, establish that the current model accepts images. If image input is unavailable, finish structural and content checks and state that visual layout was not inspected; do not generate unreadable previews, retry `view`, or choose a second model.

Use the bundled LibreOffice binaries unless the user explicitly asks not to use them. Without that explicit opt-out, never search for or invoke system LibreOffice, `soffice`, an application-installed binary, or a downloaded replacement. If the bundled CLI is unavailable or fails, report that failure instead of substituting another executable.

Run the bundled native `office` command through Bash, starting with `office capabilities --json` once when an Office operation is needed. Do not search PATH, guess a package directory, use `npx`, or install a renderer. Direct rendering avoids an intermediate PDF:

```sh
office render --input report.docx --output-dir preview-v1 --pages 1,3 --dpi 144
office convert --input report.docx --output report.pdf
```

Choose pages relevant to the requested edit; inspect all pages when whole-document layout is required. Batch selected pages in one call and use the returned manifest's page count, image paths, and missing-font diagnostics. Output directories and converted files must be new. Reuse images for the same saved document; render again only after a source change, for an unrendered page, or to diagnose a concrete failure. Check page breaks, clipped text, headings, and table widths. Do not repeatedly export unchanged documents or infer visual overflow solely from guessed text geometry.

If rendering is unavailable or rendering fails, preserve the usable source and report the inspection limit. Do not search for COM automation, install conversion packages, or build another rendering pipeline for routine QA. LibreOffice pagination can differ from Microsoft Word. Once the requested content and applicable checks pass, deliver the document.

Link the actual final file with an ordinary project-relative Markdown link. Keep that file in place and omit intermediate scripts, previews, and QA reports unless requested.
