#!/usr/bin/env python3
"""Score DeepSeek 4 generations with the official LiveCodeBench checker.

Generated programs are untrusted. Run this script only through
score_deepseek4_livecodebench_v6.sh, which supplies an isolated container.
"""

from __future__ import annotations

import argparse
import ast
import base64
import hashlib
import json
import os
import pickle
import statistics
import zlib
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from lcb_runner.evaluation.compute_code_generation_metrics import codegen_metrics
from lcb_runner.lm_styles import LMStyle
from lcb_runner.utils.extraction_utils import extract_code


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--generations", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--num-process-evaluate", type=int, default=8)
    parser.add_argument("--timeout", type=int, default=6)
    parser.add_argument("--allow-incomplete", action="store_true")
    args = parser.parse_args()
    if args.num_process_evaluate <= 0:
        parser.error("--num-process-evaluate must be positive")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    return args


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_generation_records(
    path: Path, allow_incomplete: bool
) -> tuple[
    list[str],
    list[str],
    dict[str, dict[str, Any]],
    dict[str, dict[str, Any]],
]:
    thinking: dict[str, dict[str, Any]] = {}
    answers: dict[str, dict[str, Any]] = {}
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            record = json.loads(line)
            if record.get("schemaVersion") != 2:
                raise ValueError(
                    f"line {line_number}: unsupported schemaVersion "
                    f"{record.get('schemaVersion')!r}"
                )
            question_id = record["questionID"]
            if record["phase"] == "thinking":
                if question_id in thinking:
                    raise ValueError(f"duplicate thinking record for {question_id}")
                thinking[question_id] = record
            elif record["phase"] == "answer":
                if question_id in answers:
                    raise ValueError(f"duplicate answer record for {question_id}")
                answers[question_id] = record
            else:
                raise ValueError(
                    f"line {line_number}: unknown phase {record['phase']!r}"
                )

    if allow_incomplete:
        complete_question_ids = sorted(set(thinking) & set(answers))
    else:
        missing = sorted(set(thinking) - set(answers))
        extra = sorted(set(answers) - set(thinking))
        if missing or extra:
            raise ValueError(
                "answer records do not match thinking records; "
                f"missing={missing[:8]} extra={extra[:8]}"
            )
        complete_question_ids = sorted(thinking)
    if not complete_question_ids:
        raise ValueError("no complete questions found")

    base_seeds = {answers[question_id]["baseSeed"] for question_id in complete_question_ids}
    if len(base_seeds) != 1:
        raise ValueError(f"expected one base seed, found {sorted(base_seeds)}")
    for question_id in complete_question_ids:
        thinking_record = thinking[question_id]
        answer_record = answers[question_id]
        if answer_record["thinkingTokenCount"] != thinking_record["thinkingTokenCount"]:
            raise ValueError(f"thinking-token mismatch for {question_id}")
        if answer_record["forcedThinkingBoundary"] != thinking_record[
            "forcedThinkingBoundary"
        ]:
            raise ValueError(f"forced-boundary mismatch for {question_id}")

    forced_question_ids = [
        question_id
        for question_id in complete_question_ids
        if thinking[question_id]["forcedThinkingBoundary"]
    ]
    evaluated_question_ids = [
        question_id
        for question_id in complete_question_ids
        if not thinking[question_id]["forcedThinkingBoundary"]
    ]
    if not evaluated_question_ids:
        raise ValueError("no naturally completed thinking records to score")
    return evaluated_question_ids, forced_question_ids, answers, thinking


def decode_private_tests(value: str) -> list[dict[str, Any]]:
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        decoded = pickle.loads(zlib.decompress(base64.b64decode(value.encode("utf-8"))))
        return json.loads(decoded)


def load_evaluation_samples(
    path: Path, selected_question_ids: set[str]
) -> dict[str, tuple[str, dict[str, Any]]]:
    samples: dict[str, tuple[str, dict[str, Any]]] = {}
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            problem = json.loads(line)
            question_id = problem["question_id"]
            if question_id not in selected_question_ids:
                continue
            public_tests = json.loads(problem["public_test_cases"])
            private_tests = decode_private_tests(problem["private_test_cases"])
            tests = public_tests + private_tests
            metadata = json.loads(problem["metadata"])
            sample = {
                "input_output": json.dumps(
                    {
                        "inputs": [test["input"] for test in tests],
                        "outputs": [test["output"] for test in tests],
                        "fn_name": metadata.get("func_name"),
                    }
                )
            }
            if question_id in samples:
                raise ValueError(f"duplicate dataset question_id {question_id}")
            samples[question_id] = (problem["difficulty"], sample)
    missing = selected_question_ids - set(samples)
    if missing:
        raise ValueError(f"generation question IDs missing from dataset: {sorted(missing)}")
    return samples


def main() -> None:
    if os.environ.get("LCB_EVAL_IN_CONTAINER") != "1":
        raise SystemExit(
            "Refusing to execute generated programs outside the isolated scoring container. "
            "Use score_deepseek4_livecodebench_v6.sh."
        )
    args = parse_args()
    dataset_path = Path(args.dataset)
    generation_path = Path(args.generations)
    output_path = Path(args.output)
    question_ids, forced_question_ids, answer_records, thinking_records = (
        load_generation_records(generation_path, args.allow_incomplete)
    )
    samples_by_id = load_evaluation_samples(dataset_path, set(question_ids))

    extracted = {
        question_id: extract_code(
            answer_records[question_id]["output"], LMStyle.DeepSeekR1
        )
        for question_id in question_ids
    }
    evaluation_samples = [samples_by_id[question_id][1] for question_id in question_ids]
    generations = [[extracted[question_id]] for question_id in question_ids]
    _, official_results, official_metadata = codegen_metrics(
        evaluation_samples,
        generations,
        k_list=[1],
        num_process_evaluate=args.num_process_evaluate,
        timeout=args.timeout,
    )

    scores = []
    per_task = []
    outcomes = Counter()
    by_difficulty: dict[str, list[bool]] = {}
    syntax_valid_count = 0
    for task_index, question_id in enumerate(question_ids):
        test_results = official_results[task_index][0]
        passed = bool(test_results) and all(result > 0 for result in test_results)
        scores.append(passed)
        code = extracted[question_id]
        try:
            ast.parse(code)
            syntax_valid = bool(code)
        except SyntaxError:
            syntax_valid = False
        syntax_valid_count += int(syntax_valid)
        metadata = json.loads(official_metadata[task_index][0])
        outcomes["passed" if passed else metadata.get("error_message", "failed")] += 1
        difficulty = samples_by_id[question_id][0]
        by_difficulty.setdefault(difficulty, []).append(passed)
        per_task.append(
            {
                "questionID": question_id,
                "caseIndex": answer_records[question_id]["caseIndex"],
                "difficulty": difficulty,
                "passed": passed,
                "codeExtracted": bool(code),
                "syntaxValid": syntax_valid,
                "thinkingTokens": thinking_records[question_id]["thinkingTokenCount"],
                "answerTokens": answer_records[question_id]["generatedTokenCount"],
                "stopReason": answer_records[question_id]["stopReason"],
                "officialMetadata": metadata,
            }
        )

    correct = sum(scores)
    summary = {
        "correct": correct,
        "total": len(question_ids),
        "passAt1": correct / len(question_ids),
        "codeExtractionRate": sum(bool(extracted[value]) for value in question_ids)
        / len(question_ids),
        "syntaxValidRate": syntax_valid_count / len(question_ids),
        "meanThinkingTokens": statistics.fmean(
            thinking_records[value]["thinkingTokenCount"] for value in question_ids
        ),
        "meanAnswerTokens": statistics.fmean(
            answer_records[value]["generatedTokenCount"] for value in question_ids
        ),
        "stopReasons": dict(
            Counter(answer_records[value]["stopReason"] for value in question_ids)
        ),
        "outcomes": dict(outcomes),
        "byDifficulty": {
            difficulty: {
                "correct": sum(values),
                "total": len(values),
                "passAt1": sum(values) / len(values),
            }
            for difficulty, values in sorted(by_difficulty.items())
        },
    }
    result = {
        "schemaVersion": 1,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "dataset": "LiveCodeBench code_generation_lite v6",
        "datasetSHA256": file_sha256(dataset_path),
        "generationSHA256": file_sha256(generation_path),
        "liveCodeBenchRevision": os.environ.get("LCB_REVISION", "unknown"),
        "baseSeed": answer_records[question_ids[0]]["baseSeed"],
        "selection": {
            "thinkingTemperature": 1,
            "thinkingMinP": 0.01,
            "answerTemperature": 0,
        },
        "evaluatedQuestionCount": len(question_ids),
        "excludedForcedThinkingCount": len(forced_question_ids),
        "excludedForcedThinkingQuestionIDs": forced_question_ids,
        "summary": summary,
        "perTask": per_task,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
        handle.write("\n")
    print(
        json.dumps(
            {
                "evaluatedQuestionCount": len(question_ids),
                "excludedForcedThinkingCount": len(forced_question_ids),
                "summary": summary,
                "output": str(output_path),
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
