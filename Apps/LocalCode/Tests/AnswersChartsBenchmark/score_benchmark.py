#!/usr/bin/env python3
"""Score artifacts and artist-level replay evidence; visual review is separate."""
from __future__ import annotations

import argparse
import functools
import hashlib
import json
import math
import re
import struct
import xml.etree.ElementTree as ET
from pathlib import Path

from run_benchmark import CASES

REVENUE_LABELS = [
    "Enterprise platform subscriptions", "Professional implementation services",
    "Managed data operations", "Security and compliance packages",
    "Analytics and reporting add-ons", "Developer productivity extensions",
    "Training and enablement programs", "Premium customer support",
]
REVENUES = [985000, 870000, 760000, 650000, 540000, 430000, 320000, 210000]
MONTHS = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
ACTUAL = [120000, 128000, 135000, 141000, 149000, 155000, 162000, 170000, 178000, 187000, 196000, 208000]
PLANNED = [125000, 130000, 134000, 140000, 148000, 156000, 164000, 171000, 180000, 188000, 198000, 210000]
CHANNELS = ["Organic search", "Paid social", "Partner referrals", "Email", "Events"]
SHARES = [35, 25, 20, 15, 5]
POINTS = [[10000, 72000], [14000, 88000], [18000, 97000], [22000, 121000],
          [26000, 134000], [30000, 151000], [34000, 165000], [38000, 181000],
          [42000, 190000], [46000, 214000]]
IMAGE_PATTERN = re.compile(r"!\[[^\]]+\]\((outputs/charts/[^)]+\.png)\)")


@functools.lru_cache(maxsize=1)
def qwen_token_bytes() -> dict[int, bytes]:
    # Same byte mapping as Libraries/Tokenizer/Sources/Tiktoken.swift.
    visible = list(range(33, 127)) + list(range(161, 173)) + list(range(174, 256))
    missing = [value for value in range(256) if value not in visible]
    decoder = {chr(value): value for value in visible}
    decoder.update({chr(256 + index): value for index, value in enumerate(missing)})
    path = Path(__file__).resolve().parents[4] / "Libraries/BinaryResources/Resources/vocab_qwen3.5.json"
    vocabulary = json.loads(path.read_text(encoding="utf-8"))
    return {value: bytes(decoder[char] for char in key) for key, value in vocabulary.items()}


def decode_tool_responses(tokens: list[int], vocabulary: dict[int, bytes]) -> list[str]:
    """Decode only tool-response spans, never assistant reasoning or the rest of the transcript."""
    responses = []
    current = None
    for token in tokens:
        if token == 248066:  # <tool_response> in the production Qwen tokenizer.
            if current is not None:
                raise ValueError("nested tool-response boundary")
            current = bytearray()
        elif token == 248067:
            if current is None:
                raise ValueError("unmatched tool-response boundary")
            responses.append(current.decode("utf-8").strip("\n"))
            current = None
        elif current is not None:
            current.extend(vocabulary[token])
    if current is not None:
        raise ValueError("incomplete tool-response span")
    return responses


def recorded_tool_calls(result: dict) -> tuple[list[dict], str]:
    calls = result.get("toolCalls", [])
    if all(call.get("response") is not None for call in calls):
        return calls, "structured toolCalls"
    # The frozen September 9 CLI omitted ToolCall.response but preserved the
    # complete unresumed, uncompacted conversation. Fail closed on a mismatch.
    if result.get("model") != "qwen_3.8_27b_i4x.ckpt":
        raise ValueError("missing structured tool responses for an unsupported model")
    responses = decode_tool_responses(result["prefixTokens"], qwen_token_bytes())
    if len(responses) != len(calls):
        raise ValueError("tool-response count differs from call history; cannot align evidence")
    return [dict(call, response=response) for call, response in zip(calls, responses)], "prefixTokens recovery"


def check_data(case: str, axes: dict) -> bool:
    """Compare plotted artists, never source-code numeric substrings."""
    if case == "revenue-bar":
        return (axes["bars"] == [{"orientation": "horizontal", "values": REVENUES}]
                and axes["yticks"] == REVENUE_LABELS and not axes["lines"]
                and not axes["scatter"] and not axes["pie_percentages"])
    if case == "monthly-line":
        lines = axes["lines"]
        return (len(lines) == 2 and sorted(line["y"] for line in lines) == sorted([ACTUAL, PLANNED])
                and all(line["x"] in (MONTHS, list(range(12))) for line in lines)
                and axes["xticks"] == MONTHS and not axes["bars"] and not axes["scatter"])
    if case == "channel-pie":
        percentages = axes["pie_percentages"]
        labels = "\n".join(axes["texts"] + axes["legend"])
        return (len(percentages) == 5
                and all(math.isclose(a, b, abs_tol=1e-4) for a, b in zip(percentages, SHARES))
                and all(label in labels for label in CHANNELS)
                and not axes["bars"] and not axes["lines"] and not axes["scatter"])
    if case == "spend-scatter":
        return (axes["scatter"] == [POINTS] and axes["xscale"] == axes["yscale"] == "linear"
                and not axes["lines"] and not axes["bars"] and not axes["pie_percentages"])
    raise ValueError(case)


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as source:
        data = source.read(24)
    if len(data) != 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("invalid PNG signature or IHDR")
    return struct.unpack(">II", data[16:24])


def score_case(case_root: Path, case: str, replay_root: Path) -> dict:
    errors = []
    result_path = case_root / "result.json"
    if not result_path.is_file():
        return {"case": case, "automated_passed": False, "errors": ["missing result.json"]}
    result = json.loads(result_path.read_text(encoding="utf-8"))
    runner = json.loads((case_root / "runner.json").read_text(encoding="utf-8"))
    if runner.get("status") != "completed" or runner.get("return_code") != 0:
        errors.append("CLI did not exit successfully")
    if (runner.get("prompt") != CASES[case]
            or (case_root / "prompt.txt").read_text(encoding="utf-8").strip() != CASES[case]):
        errors.append("recorded prompt differs from the fixed case")
    if result.get("model") != runner.get("model"):
        errors.append("result model differs from requested model")
    if result.get("stoppedAtTokenLimit"):
        errors.append("generation hit the token limit")
    if result.get("interrupted"):
        errors.append("generation was interrupted")
    tool_calls, response_source = recorded_tool_calls(result)
    commands = [call["request"].get("parameters", {}).get("command", {}).get("value", "")
                for call in tool_calls if call["request"].get("function") == "bash"]
    for command in commands:
        for forbidden in ("pip install", "curl ", "wget ", "PYTHONPATH", "site-packages"):
            if forbidden in command:
                errors.append(f"unsupported probing/install command: {forbidden}")
    project = case_root / "project"
    final_text = result.get("finalText", "")
    if case == "quadratic-limitation":
        if list(project.glob("outputs/charts/*")) or IMAGE_PATTERN.search(final_text):
            errors.append("limitation case created or claimed chart artifacts")
        if commands:
            errors.append("limitation case invoked bash")
        if not final_text.strip():
            errors.append("missing limitation response")
        # The request for missing domain/sampling inputs is judged in manual review.
    else:
        pngs = list(project.glob("outputs/charts/*.png"))
        svgs = list(project.glob("outputs/charts/*.svg"))
        matches = IMAGE_PATTERN.findall(final_text)
        if len(matches) != 1 or not (project / matches[0]).is_file():
            errors.append("final answer must embed an existing project-relative PNG")
        elif len(pngs) == 1 and (project / matches[0]).resolve() != pngs[0].resolve():
            errors.append("inline image points to a different file than the verified chart")
        if len(pngs) != 1 or len(svgs) != 1:
            errors.append(f"expected one PNG and SVG, found {len(pngs)} and {len(svgs)}")
        else:
            width, height = png_size(pngs[0])
            if width < 800 or height < 450:
                errors.append(f"PNG is too small: {width}x{height}")
            if ET.parse(svgs[0]).getroot().tag != "{http://www.w3.org/2000/svg}svg":
                errors.append("SVG root element is invalid")
        if not any((call.get("response") or "").splitlines()[1:3] == ["status=completed", "exit=0"]
                   for call in tool_calls
                   if call["request"].get("function") in ("bash", "bash_wait", "bash_status")):
            errors.append("no successful shell completion recorded")
        inspection_path = replay_root / case / "inspection.json"
        if not inspection_path.is_file():
            errors.append("missing artist-level replay evidence")
        else:
            inspection = json.loads(inspection_path.read_text(encoding="utf-8"))
            script = project / "outputs/chart_task.py"
            if hashlib.sha256(script.read_bytes()).hexdigest() != inspection["script_sha256"]:
                errors.append("replayed script differs from agent script")
            figures = inspection["figures"]
            if len(figures) != 1 or len(figures[0]["axes"]) != 1:
                errors.append("expected exactly one saved figure with one axes")
            else:
                if not check_data(case, figures[0]["axes"][0]):
                    errors.append("plotted values, labels or chart type differ from the case")
                if len(pngs) == 1 and hashlib.sha256(pngs[0].read_bytes()).hexdigest() != figures[0]["png"]["sha256"]:
                    errors.append("replayed PNG differs from the agent's saved PNG")
    return {"case": case, "automated_passed": not errors,
            "duration_seconds": result.get("durationMilliseconds", 0) / 1000,
            "reported_statistics": {
                # Preserve the selected binary's values. Older snapshots used a
                # rolling token average; current CLI builds report a turn total.
                "scope": "as-reported-by-cli",
                "generated_tokens": result.get("generatedTokens"),
                "context_used_tokens": result.get("contextUsedTokens"),
                "context_window_tokens": result.get("contextWindowTokens"),
            },
            "tool_call_count": len(tool_calls), "errors": errors,
            "tool_response_source": response_source,
            "manual_review_required": "layout, units, labels/series association, summary, limitation behavior"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("results", type=Path)
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    summary = []
    skill_hashes = set()
    cli_hashes = set()
    for case in CASES:
        try:
            summary.append(score_case(args.results / case, case, args.replay))
            record = json.loads((args.results / case / "runner.json").read_text(encoding="utf-8"))
            skill_hashes.add(record["skill_sha256"])
            cli_hashes.add(record["cli_sha256"])
        except (OSError, ValueError, KeyError, ET.ParseError) as error:
            if summary and summary[-1]["case"] == case:
                summary[-1]["automated_passed"] = False
                summary[-1]["errors"].append(str(error))
            else:
                summary.append({"case": case, "automated_passed": False, "errors": [str(error)]})
    if len(skill_hashes) != 1 or not all(re.fullmatch(r"[0-9a-f]{64}", digest) for digest in skill_hashes):
        for item in summary:
            item["automated_passed"] = False
            item["errors"].append("all cases must use one recorded frozen skill hash")
    if len(cli_hashes) != 1 or not all(re.fullmatch(r"[0-9a-f]{64}", digest) for digest in cli_hashes):
        for item in summary:
            item["automated_passed"] = False
            item["errors"].append("all cases must use one recorded frozen CLI hash")
    text = json.dumps(summary, indent=2) + "\n"
    if args.output:
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if all(item["automated_passed"] for item in summary) else 1


if __name__ == "__main__":
    raise SystemExit(main())
