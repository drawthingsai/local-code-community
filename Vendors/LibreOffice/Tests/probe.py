"""Exercise a retained Office runtime and validate every output in one process.

Uses the tiny fixtures produced by verify.py; creates larger synthetic inputs.
Memory samples come from TASK_VM_INFO inside the C++ process, not Python.
"""
import argparse
import hashlib
import json
import pathlib
import random
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET
import zipfile

from docx import Document
from docx.shared import Inches as WordInches
from openpyxl import Workbook
from PIL import Image
from pptx import Presentation
from pptx.util import Inches
from pypdf import PdfReader


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--office", type=pathlib.Path, required=True)
    parser.add_argument("--fixtures", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--mode", choices=["main", "owner", "threads", "concurrent", "queued"], default="main")
    parser.add_argument("--cycles", type=int, default=30)
    parser.add_argument("--large-cycles", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    assert args.cycles > 0 and args.large_cycles >= 0
    office = args.office.resolve(strict=True)
    fixtures = args.fixtures.resolve(strict=True)
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    outputs = root / "outputs"
    outputs.mkdir()
    medium = root / "inputs"
    medium.mkdir()
    cases = [
        ("writer", "convert", fixtures / "input document.docx", "pdf", 2, "Second page sentinel"),
        ("calc-pdf", "convert", fixtures / "input workbook.xlsx", "pdf", 2, "Native office workbook"),
        ("impress", "convert", fixtures / "input slides.pptx", "pdf", 1, "Native office presentation"),
        ("calc", "recalculate", fixtures / "input workbook.xlsx", "xlsx", None, None),
    ]
    large = []
    if args.large_cycles:
        generator = random.Random(42)
        presentation = Presentation()
        for index in range(20):
            image = Image.frombytes("RGB", (1600, 900), generator.randbytes(1600 * 900 * 3))
            image_path = medium / f"image-{index}.jpg"
            image.save(image_path, quality=80)
            slide = presentation.slides.add_slide(presentation.slide_layouts[6])
            slide.shapes.add_picture(str(image_path), Inches(0), Inches(1), width=Inches(10))
            slide.shapes.add_textbox(Inches(0.5), Inches(0), Inches(9), Inches(1)).text = f"Large presentation slide {index + 1}"
        presentation.save(medium / "large.pptx")
        document = Document()
        for index in range(50):
            if index:
                document.add_page_break()
            document.add_heading(f"Large document page {index + 1}", 1)
            document.add_paragraph("A repeated conversion fixture with text, a table and an image. " * 8)
            table = document.add_table(rows=6, cols=4)
            for row_index, row in enumerate(table.rows):
                for col_index, cell in enumerate(row.cells):
                    cell.text = f"Page {index + 1}, cell {row_index}:{col_index}"
            document.add_picture(str(medium / f"image-{index % 20}.jpg"), width=WordInches(4))
        document.save(medium / "large.docx")
        workbook = Workbook()
        sheet = workbook.active
        sheet.title = "Data"
        sheet.append(["Index", "Price", "Quantity", "Amount", "Double", "Triple", "Running", "Average"])
        for row in range(2, 10002):
            sheet.append([row - 1, 19, 3, f"=B{row}*C{row}", f"=D{row}*2",
                          f"=D{row}*3", f"=SUM(D$2:D{row})", f"=AVERAGE(D{row}:F{row})"])
        workbook.save(medium / "large.xlsx")
        large = [
            ("large-writer", "convert", medium / "large.docx", "pdf", 50, "Large document page 50"),
            ("large-impress", "convert", medium / "large.pptx", "pdf", 20, "Large presentation slide 20"),
            ("large-calc", "recalculate", medium / "large.xlsx", "xlsx", None, None),
        ]
    rows = []
    checks = []

    def append(case, label=None, sheet="-", status=0, cancel="-"):
        name, operation, source, extension, pages, phrase = case
        output = outputs / f"{len(rows):04d}-{name}.{extension}"
        rows.append([label or name, operation, str(source), str(output), sheet, str(status), cancel])
        checks.append((case, output, status))

    # Warm-up all modules, then observe accumulation over repeated tiny requests.
    for cycle in range(args.cycles):
        for case in cases:
            append(case, f"small-{cycle:03d}-{case[0]}")
    if args.mode != "concurrent":
        corrupt = medium / "corrupt.docx"
        with zipfile.ZipFile(corrupt, "w") as archive:
            archive.writestr("unrelated.txt", "Not an Office document")
        append(("corrupt", "convert", corrupt, "pdf", None, None), status=1)
        append(("missing-sheet", "convert", cases[3][2], "csv", None, None), sheet="NotASheet", status=1)
        append(cases[0], "cancel-loaded", status=130, cancel="loaded")
        append(cases[2], "cancel-saved", status=130, cancel="saved")
        append(cases[0], "recovery-writer")
    for cycle in range(args.large_cycles):
        for case in large:
            append(case, f"large-{cycle:03d}-{case[0]}")
    # Small jobs after the largest document show the retained working set.
    for cycle in range(10):
        for case in cases:
            append(case, f"after-{cycle:03d}-{case[0]}")
    inputs = {path for case, _, _ in checks for path in [case[2]]}
    hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
    manifest = root / "manifest.tsv"
    manifest.write_text("".join("\t".join(row) + "\n" for row in rows))
    program = office.parent.parent / "office/Frameworks"
    report_path = root / "memory.jsonl"
    started = time.monotonic()
    with (root / "stdout.log").open("w") as stdout, (root / "stderr.log").open("w") as stderr:
        process = subprocess.run([str(office), "--memory-probe", str(manifest), str(report_path),
                                  str(program), args.mode], stdout=stdout, stderr=stderr, timeout=args.timeout)
    assert process.returncode == 0, (process.returncode, root / "stderr.log")
    shutil.rmtree(root / "runtime")
    records = [json.loads(line) for line in report_path.read_text().splitlines()]
    commands = sorted([r for r in records if r["event"] == "command"], key=lambda r: r["index"])
    assert len(commands) == len(rows)
    owner_threads = {phase["threadID"] for command in commands for phase in command["phases"]}
    assert len(owner_threads) == 1, owner_threads
    ns = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    for record, (case, output, status) in zip(commands, checks):
        assert record["status"] == status, record
        result = json.loads(record["result"])
        assert result["ok"] == (status == 0), record
        if status:
            assert not output.exists(), output
            continue
        assert output.stat().st_mode & 0o777 == 0o600
        if case[3] == "pdf":
            pdf = PdfReader(output)
            assert len(pdf.pages) == case[4], (output, len(pdf.pages), case[4])
            text = "\n".join(page.extract_text() for page in pdf.pages)
            assert case[5] in text, output
        elif case[3] == "xlsx":
            with zipfile.ZipFile(output) as archive:
                if case[0] == "large-calc":
                    xml = ET.fromstring(archive.read("xl/worksheets/sheet1.xml"))
                    expected = {"D10001": 57, "G10001": 570000, "H10001": 114}
                else:
                    xml = ET.fromstring(archive.read("xl/worksheets/sheet2.xml"))
                    expected = {"B2": 105, "B3": 210}
                cells = {cell.attrib["r"]: cell for cell in xml.findall(".//s:c", ns)}
                for cell, value in expected.items():
                    assert cells[cell].find("s:f", ns) is not None, (output, cell)
                    assert float(cells[cell].find("s:v", ns).text) == value, (output, cell)
    assert not list(outputs.glob(".office-*")), "Per-command scratch leaked"
    assert not (root / "runtime").exists(), "Probe host failed to remove its profile"
    for path, expected in hashes.items():
        assert hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest() == expected
    summary = {
        "passed": True, "mode": args.mode, "commands": len(commands),
        "wallSeconds": time.monotonic() - started,
        "inputBytes": {str(path): path.stat().st_size for path in inputs},
        "baseline": records[0]["memory"], "idle": records[-1]["memory"],
        "maxSampledRSS": max(r["sampledPeakRSS"] for r in commands),
        "maxSampledFootprint": max(r["sampledPeakFootprint"] for r in commands),
        "firstCycleClosed": commands[3]["after"],
        "lastSmallCycleClosed": commands[args.cycles * 4 - 1]["after"],
        "memoryReport": str(report_path),
    }
    (root / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
