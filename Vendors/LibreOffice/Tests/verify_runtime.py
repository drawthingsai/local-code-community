"""Verify the private SVP archive through its standalone and concurrent native hosts."""
import argparse
import json
import os
import pathlib
import subprocess
import sys
from xml.sax.saxutils import escape

from pypdf import PdfReader


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--office", type=pathlib.Path, required=True)
    parser.add_argument("--reference", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    office = args.office.resolve(strict=True)
    reference = args.reference.resolve(strict=True) if args.reference else None
    probe = office.parent / "office-probe"
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    scripts = pathlib.Path(__file__).resolve().parent
    cache = root / "font-cache"
    cache.mkdir()
    environment = dict(os.environ)
    environment.pop("FONTCONFIG_FILE", None)

    def run(script, *arguments):
        subprocess.run([sys.executable, str(scripts / script), *map(str, arguments)],
                       env=environment, check=True)

    run("verify.py", "--office", office, "--output", root / "conversions")
    # A supplied font must work without system-font discovery; otherwise a
    # platform-gated no-op can silently fall back to bundled OpenSymbol.
    empty_fonts = root / "empty-fonts.conf"
    empty_fonts.write_text("<fontconfig><cachedir>" + escape(str(cache)) + "</cachedir></fontconfig>\n")
    font_pdf = root / "explicit-font.pdf"
    subprocess.run([str(office), "convert", "--input", str(root / "conversions/input slides.pptx"),
                    "--output", str(font_pdf), "--font-file", "/System/Library/Fonts/Supplemental/Arial.ttf"],
                   env=dict(environment, FONTCONFIG_FILE=str(empty_fonts)), check=True, timeout=30)
    fonts = subprocess.check_output(["pdffonts", str(font_pdf)], text=True)
    assert "ArialMT" in fonts and "OpenSymbol" not in fonts, fonts
    assert "Native office presentation" in PdfReader(font_pdf).pages[0].extract_text()
    (root / "explicit-font.txt").write_text(fonts)
    if reference:
        run("compare.py", "--reference", reference, "--candidate", root / "conversions",
            "--output", root / "comparison.json")
    for mode in ["owner", "threads", "concurrent", "queued"]:
        arguments = [] if mode == "owner" else ["--cycles", "3", "--large-cycles", "0", "--timeout", "30"]
        run("probe.py", "--office", probe, "--fixtures", root / "conversions",
            "--output", root / mode, "--mode", mode, *arguments)
    print(json.dumps({"passed": True, "output": str(root)}))


if __name__ == "__main__":
    main()
