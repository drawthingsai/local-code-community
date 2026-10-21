"""Validate and prepare an Ideogram 4 caption for Draw Things."""

import argparse
import json
from pathlib import Path
import runpy
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("caption", type=Path, help="Authored UTF-8 JSON caption")
    parser.add_argument("--output", required=True, type=Path, help="New prompt file to create")
    args = parser.parse_args()

    try:
        caption = json.loads(args.caption.read_text(encoding="utf-8"))
        if not isinstance(caption, dict):
            raise ValueError("caption must be a JSON object")
        caption.pop("aspect_ratio", None)
        verifier_path = Path(__file__).resolve().with_name("ideogram_caption_verifier.py")
        verifier = runpy.run_path(str(verifier_path))["CaptionVerifier"]()
        warnings = verifier.verify(caption)
        if warnings:
            raise ValueError("caption validation failed:\n  " + "\n  ".join(warnings))
        # Preserve field order and literal non-ASCII text; reject non-JSON numbers.
        prompt = json.dumps(caption, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
        # Encode before opening so invalid Unicode cannot leave a partial file.
        data = (prompt + "\n").encode("utf-8")
        with args.output.open("xb") as output:
            output.write(data)
    except (OSError, ValueError, TypeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1

    print(f"Prepared: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
