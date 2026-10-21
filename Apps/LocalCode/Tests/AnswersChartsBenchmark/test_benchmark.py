import copy
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from score_benchmark import (ACTUAL, MONTHS, PLANNED, POINTS, check_data, decode_tool_responses,
                             png_size, score_case)
from run_benchmark import CASES


class BenchmarkTests(unittest.TestCase):
    def test_recovers_only_complete_tool_response_spans(self):
        vocabulary = {1: b"\n", 2: b"job=1\nstatus=completed\nexit=0", 3: "verified ✓".encode()}
        tokens = [999, 248068, 888, 248069, 248066, 1, 2, 1, 248067,
                  999, 248066, 1, 3, 1, 248067]
        self.assertEqual(decode_tool_responses(tokens, vocabulary),
                         ["job=1\nstatus=completed\nexit=0", "verified ✓"])
        for broken in ([248066, 1], [248067], [248066, 248066]):
            with self.assertRaises(ValueError):
                decode_tool_responses(broken, vocabulary)
        with self.assertRaises(KeyError):
            decode_tool_responses([248066, 777, 248067], vocabulary)

    def test_canonical_cli_result_completion_and_structured_tool_calls(self):
        case = "quadratic-limitation"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "project").mkdir()
            (root / "prompt.txt").write_text(CASES[case] + "\n")
            runner = {"prompt": CASES[case], "status": "completed", "return_code": 0,
                      "model": "fixture.ckpt"}
            (root / "runner.json").write_text(json.dumps(runner))
            result = {"model": "fixture.ckpt", "finalText": "Which domain should I use?",
                      "stoppedAtTokenLimit": False, "interrupted": False, "toolCalls": [],
                      "generatedTokens": 20, "contextUsedTokens": 100, "contextWindowTokens": 1000}
            result_path = root / "result.json"
            result_path.write_text(json.dumps(result))
            scored = score_case(root, case, root)
            self.assertTrue(scored["automated_passed"])
            self.assertEqual(scored["reported_statistics"], {
                "scope": "as-reported-by-cli", "generated_tokens": 20,
                "context_used_tokens": 100, "context_window_tokens": 1000,
            })
            for flag in ("stoppedAtTokenLimit", "interrupted"):
                changed = dict(result, **{flag: True})
                result_path.write_text(json.dumps(changed))
                self.assertFalse(score_case(root, case, root)["automated_passed"])
            result["toolCalls"] = [{"request": {"function": "bash", "parameters": {
                "command": {"string": True, "value": "pip install matplotlib"}}},
                "response": "bash\nstatus=completed\nexit=0\n"}]
            result_path.write_text(json.dumps(result))
            scored = score_case(root, case, root)
            self.assertFalse(scored["automated_passed"])
            self.assertIn("unsupported probing/install command: pip install", scored["errors"])

    def test_saved_artists_match_source_and_complete_inputs(self):
        for fixture in ("GPT-5.6-Sol", "Qwen-3.8-27B-i4x"):
            root = Path(__file__).parent / fixture
            for case in ("revenue-bar", "monthly-line", "channel-pie", "spend-scatter"):
                with self.subTest(fixture=fixture, case=case):
                    inspection = json.loads((root / f"{case}.inspection.json").read_text())
                    self.assertEqual(hashlib.sha256((root / f"{case}.py").read_bytes()).hexdigest(),
                                     inspection["script_sha256"])
                    self.assertTrue(check_data(case, inspection["figures"][0]["axes"][0]))

    def test_line_checks_every_value_and_month(self):
        axes = {"lines": [{"x": MONTHS, "y": ACTUAL}, {"x": MONTHS, "y": PLANNED}],
                "xticks": MONTHS, "bars": [], "scatter": []}
        self.assertTrue(check_data("monthly-line", axes))
        changed = copy.deepcopy(axes)
        changed["lines"][0]["y"][5] += 1
        self.assertFalse(check_data("monthly-line", changed))
        changed = copy.deepcopy(axes)
        changed["xticks"].reverse()
        self.assertFalse(check_data("monthly-line", changed))

    def test_scatter_rejects_extra_trendline_and_changed_pair(self):
        axes = {"scatter": [POINTS], "xscale": "linear", "yscale": "linear",
                "lines": [], "bars": [], "pie_percentages": []}
        self.assertTrue(check_data("spend-scatter", axes))
        changed = copy.deepcopy(axes)
        changed["scatter"][0][3][1] += 1
        self.assertFalse(check_data("spend-scatter", changed))
        axes["lines"] = [{"x": [1, 2], "y": [3, 4]}]
        self.assertFalse(check_data("spend-scatter", axes))

    def test_missing_results_and_invalid_png_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertFalse(score_case(root, "revenue-bar", root)["automated_passed"])
            image = root / "bad.png"
            image.write_bytes(b"not a PNG")
            with self.assertRaises(ValueError):
                png_size(image)

    def test_runner_timeout_checkpoints_and_does_not_reuse_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = root / "fake-cli"
            cli.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(30)\n")
            cli.chmod(0o755)
            skills = root / "skills/answers-charts"
            skills.mkdir(parents=True)
            (skills / "SKILL.md").write_text("fixture")
            command = [sys.executable, str(Path(__file__).with_name("run_benchmark.py")),
                       "--cli", str(cli), "--model-store", str(root / "model"),
                       "--skills-directory", str(skills.parent), "--output", str(root / "results"),
                       "--case", "quadratic-limitation", "--timeout", "0.1"]
            completed = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(completed.returncode, 1)
            record_path = root / "results/quadratic-limitation/runner.json"
            original_record = record_path.read_bytes()
            record = json.loads(original_record)
            self.assertEqual(record["status"], "timeout")
            self.assertIsNotNone(record["return_code"])
            self.assertNotIn("unreaped_pid", record)
            self.assertEqual(len(record["skill_sha256"]), 64)
            repeated = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(repeated.returncode, 0)
            self.assertIn("Refusing to reuse", repeated.stderr)
            self.assertEqual(record_path.read_bytes(), original_record)

    def test_zero_exit_without_result_is_not_completed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            skills = root / "skills/answers-charts"
            skills.mkdir(parents=True)
            (skills / "SKILL.md").write_text("fixture")
            command = [sys.executable, str(Path(__file__).with_name("run_benchmark.py")),
                       "--cli", "/usr/bin/true", "--model-store", str(root / "model"),
                       "--skills-directory", str(skills.parent), "--output", str(root / "results"),
                       "--case", "quadratic-limitation"]
            completed = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(completed.returncode, 1)
            record = json.loads((root / "results/quadratic-limitation/runner.json").read_text())
            self.assertEqual(record["return_code"], 0)
            self.assertEqual(record["status"], "failed")

    def test_runner_records_startup_failure_instead_of_leaving_running_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = root / "not-executable"
            cli.write_text("fixture")
            skills = root / "skills/answers-charts"
            skills.mkdir(parents=True)
            (skills / "SKILL.md").write_text("fixture")
            command = [sys.executable, str(Path(__file__).with_name("run_benchmark.py")),
                       "--cli", str(cli), "--model-store", str(root / "model"),
                       "--skills-directory", str(skills.parent), "--output", str(root / "results"),
                       "--case", "quadratic-limitation"]
            completed = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(completed.returncode, 1)
            record = json.loads((root / "results/quadratic-limitation/runner.json").read_text())
            self.assertEqual(record["status"], "failed")
            self.assertIsNone(record["return_code"])
            self.assertIn("error", record)
            self.assertIn("duration_seconds", record)


if __name__ == "__main__":
    unittest.main()
