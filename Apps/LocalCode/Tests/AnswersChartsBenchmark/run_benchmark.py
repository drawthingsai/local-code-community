#!/usr/bin/env python3
"""Run the answers-charts cases through LocalCodeCLI local-agent."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import signal
import shutil
import subprocess
import time
from pathlib import Path


CASES = {
    "revenue-bar": (
        "Use $answers-charts. Create one polished bar chart ranking these eight revenue "
        "categories. Preserve every exact label and value: Enterprise platform subscriptions "
        "$985,000; Professional implementation services $870,000; Managed data operations "
        "$760,000; Security and compliance packages $650,000; Analytics and reporting add-ons "
        "$540,000; Developer productivity extensions $430,000; Training and enablement programs "
        "$320,000; Premium customer support $210,000. Use a layout that keeps the long category "
        "labels readable. Title it Revenue ranking and describe it as exact revenue by category."
    ),
    "monthly-line": (
        "Use $answers-charts. Create one polished line chart of actual versus planned monthly "
        "revenue. Preserve all 12 months and both series: Jan 120000/125000, Feb 128000/130000, "
        "Mar 135000/134000, Apr 141000/140000, May 149000/148000, Jun 155000/156000, Jul "
        "162000/164000, Aug 170000/171000, Sep 178000/180000, Oct 187000/188000, Nov "
        "196000/198000, Dec 208000/210000, where each pair is actual/planned dollars. Title it "
        "Monthly revenue."
    ),
    "channel-pie": (
        "Use $answers-charts. Create one polished pie chart for acquisition channel share: Organic "
        "search 35%, Paid social 25%, Partner referrals 20%, Email 15%, Events 5%. Preserve the "
        "five exact labels and percentage points. Title it Acquisition mix and state that the "
        "shares total 100%."
    ),
    "spend-scatter": (
        "Use $answers-charts. Create one polished scatter chart of ad spend versus revenue for "
        "these ten exact dollar observations: 10000/72000, 14000/88000, 18000/97000, "
        "22000/121000, 26000/134000, 30000/151000, 34000/165000, 38000/181000, "
        "42000/190000, 46000/214000. The first number is ad spend and the second is revenue. "
        "Title it Ad spend vs revenue."
    ),
    "quadratic-limitation": (
        "Use $answers-charts. Create a chart of the mathematical function y = x². Do not invent "
        "or sample x/y measurements. If required plotting inputs are missing, briefly explain the "
        "limitation and request them instead of creating artifacts."
    ),
}


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--model", default="qwen_3.8_27b_i4x.ckpt")
    parser.add_argument("--model-store", type=Path, required=True)
    parser.add_argument("--skills-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--thinking-budget", type=int, default=2048)
    parser.add_argument("--maximum-generated-tokens", type=int, default=8192)
    parser.add_argument("--chunked-prefill-max-length", type=int, default=1024)
    parser.add_argument("--timeout", type=float, default=1800)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    selected_cases = args.case or list(CASES)
    output_root = args.output.resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        raise SystemExit("--timeout must be finite and positive")
    existing = [name for name in selected_cases if (output_root / name).exists()]
    if existing:
        raise SystemExit(f"Refusing to reuse case directories: {', '.join(existing)}")
    skill_path = args.skills_directory.resolve() / "answers-charts/SKILL.md"
    skill_hash = hashlib.sha256(skill_path.read_bytes()).hexdigest()
    cli_hash = file_sha256(args.cli.resolve())
    failures = []

    for case_name in selected_cases:
        if file_sha256(args.cli.resolve()) != cli_hash:
            raise SystemExit("CLI changed during the benchmark; use a frozen binary")
        case_root = output_root / case_name
        project = case_root / "project"
        project.mkdir(parents=True)
        skills = project / ".agents/skills"
        shutil.copytree(args.skills_directory.resolve(), skills)
        if hashlib.sha256((skills / "answers-charts/SKILL.md").read_bytes()).hexdigest() != skill_hash:
            raise SystemExit("Skill changed during the benchmark; use a frozen snapshot")
        prompt_path = case_root / "prompt.txt"
        result_path = case_root / "result.json"
        prompt_path.write_text(CASES[case_name] + "\n", encoding="utf-8")
        command = [
            str(args.cli.resolve()),
            "local-agent",
            "--model",
            args.model,
            "--model-store",
            str(args.model_store.resolve()),
            "--project",
            str(project),
            "--workspace",
            str(project),
            "--prompt-file",
            str(prompt_path),
            "--result-json",
            str(result_path),
            "--thinking-budget",
            str(args.thinking_budget),
            "--reasoning-effort",
            "medium",
            "--web-search-provider",
            "disabled",
            "--disable-mfa-apple-neural-engine",
            "--queue-watermark",
            "128",
            "--maximum-generated-tokens",
            str(args.maximum_generated_tokens),
            "--chunked-prefill-max-length",
            str(args.chunked_prefill_max_length),
            "--trace",
        ]
        started = time.monotonic()
        record = {"case": case_name, "prompt": CASES[case_name], "model": args.model,
                  "command": command, "cli_sha256": cli_hash, "skill_sha256": skill_hash,
                  "status": "running", "return_code": None}
        record_path = case_root / "runner.json"
        record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        print(f"RUN {case_name}: {case_root}", flush=True)
        with (case_root / "stdout.txt").open("w") as stdout, (case_root / "stderr.txt").open("w") as stderr:
            try:
                process = subprocess.Popen(command, stdout=stdout, stderr=stderr)
            except OSError as error:
                record.update(status="failed", error=str(error),
                              duration_seconds=time.monotonic() - started)
                record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
                print(f"FAILED {case_name}: could not start CLI: {error}", flush=True)
                return 1
            def stop(_signum, _frame):
                raise KeyboardInterrupt
            previous_handler = signal.signal(signal.SIGTERM, stop)
            try:
                process.wait(timeout=args.timeout)
                record["status"] = "completed" if process.returncode == 0 and result_path.is_file() else "failed"
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                record["status"] = "timeout" if isinstance(error, subprocess.TimeoutExpired) else "interrupted"
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    # A GPU driver can leave a killed process stuck exiting. Do not wait forever.
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        record["unreaped_pid"] = process.pid
            finally:
                signal.signal(signal.SIGTERM, previous_handler)
                record["return_code"] = process.returncode
                record["duration_seconds"] = time.monotonic() - started
                record_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        elapsed = record["duration_seconds"]
        status = record["status"].upper()
        print(f"{status} {case_name} {elapsed:.2f}s", flush=True)
        if record["status"] != "completed":
            failures.append(case_name)
            if record["status"] in ("interrupted", "timeout"):
                break

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
