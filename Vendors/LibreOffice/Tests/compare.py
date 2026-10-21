"""Compare the verified tiny PDF fixtures across native graphics backends."""
import argparse
import json
import pathlib
import re
import subprocess

from PIL import Image, ImageChops, ImageStat
from pypdf import PdfReader


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=pathlib.Path, required=True)
    parser.add_argument("--candidate", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    results = []
    for stem in ["input document", "input workbook", "input slides"]:
        paths = [root / f"{stem}.pdf" for root in [args.reference, args.candidate]]
        pdfs = [PdfReader(path) for path in paths]
        text = [" ".join(" ".join(page.extract_text() for page in pdf.pages).split()) for pdf in pdfs]
        assert text[0] == text[1], (stem, text)
        assert len(pdfs[0].pages) == len(pdfs[1].pages), stem
        fonts = []
        for path in paths:
            output = subprocess.check_output(["pdffonts", str(path)], text=True)
            fonts.append(sorted({re.sub(r"^[A-Z]{6}\+", "", line.split()[0])
                                 for line in output.splitlines()[2:] if line.strip()}))
        with Image.open(args.reference / f"{stem}.png") as first, Image.open(args.candidate / f"{stem}.png") as second:
            assert first.size == second.size, (stem, first.size, second.size)
            diff = ImageChops.difference(first.convert("RGB"), second.convert("RGB"))
            gray = diff.convert("L")
            histogram = gray.histogram()
            results.append({"fixture": stem, "pages": len(pdfs[0].pages), "textEqual": True,
                            "referenceFonts": fonts[0], "candidateFonts": fonts[1],
                            "firstPageSize": first.size,
                            "firstPageMeanAbsoluteRGBDifference": sum(ImageStat.Stat(diff).mean) / 3,
                            "firstPageFractionPixelsDifferenceOver16": sum(histogram[17:]) / (first.width * first.height)})
    args.output.write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
