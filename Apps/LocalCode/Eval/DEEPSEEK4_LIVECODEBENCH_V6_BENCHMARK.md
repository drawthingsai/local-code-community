# DeepSeek 4 LiveCodeBench v6 evaluation

This harness evaluates DeepSeek 4 on the 175-task LiveCodeBench v6 `test6` subset with the
production deterministic policy:

| Phase | Selection |
| --- | --- |
| Thinking | Gumbel sampling, temperature 1, min-p 0.01 |
| Answer | Argmax (temperature 0) |

The harness uses `DeepSeek4TextGenerator` without an eval-specific sampling API.

## Files

| File | Purpose |
| --- | --- |
| `Apps/LocalCode/Debug/DeepSeek4LiveCodeBenchV6EvalCLI.swift` | Generation and resumable JSONL output |
| `Apps/LocalCode/Eval/download_livecodebench_v6.sh` | Download and verify the pinned dataset |
| `Apps/LocalCode/Eval/score_deepseek4_livecodebench_v6.py` | Official-checker adapter and report generation |
| `Apps/LocalCode/Eval/score_deepseek4_livecodebench_v6.sh` | Isolated Docker scoring entry point |
| `Apps/LocalCode/Eval/LiveCodeBenchEval.Dockerfile` | Minimal official-checker image |

Case indices and `--start` are zero-based after sorting by `question_id`, matching the official
runner.

## Pinned inputs

| Input | Revision |
| --- | --- |
| LiveCodeBench source | `28fef95ea8c9f7a547c8329f2cd3d32b92c1fa24` |
| `livecodebench/code_generation_lite` | `0fe84c3912ea0c4d4a78037083943e8f0c4dd505` |
| `test6.jsonl` SHA-256 | `bb4c364f71921c4495a6ad15abe1a927350b720009f4933e2e71f8af0f6fd1f5` |

The pinned `test6.jsonl` contains 175 tasks: 43 easy, 52 medium, and 80 hard. The `v6`
configuration means only `test6.jsonl`; `release_v6` is cumulative and is not used.

Download the dataset. It contains hidden tests and must not be committed:

```sh
Apps/LocalCode/Eval/download_livecodebench_v6.sh \
  Apps/LocalCode/Eval/LiveCodeBenchV6.jsonl
```

Clone and pin the official checker separately:

```sh
git clone https://github.com/LiveCodeBench/LiveCodeBench.git \
  /absolute/path/to/LiveCodeBench
git -C /absolute/path/to/LiveCodeBench checkout \
  28fef95ea8c9f7a547c8329f2cd3d32b92c1fa24
```

## Generation

The prompt follows LiveCodeBench's `DeepSeekR1` code-generation template and appends `<think>`.
Default budgets are 65,536 thinking tokens and 65,536 answer tokens. The default base seed is 42;
each task uses `baseSeed + caseIndex` for its stochastic thinking trajectory.

Build the CLI:

```sh
bazel build -c opt //Apps/LocalCode:DeepSeek4LiveCodeBenchV6EvalCLI
```

Run a single-task smoke test:

```sh
bazel-bin/Apps/LocalCode/DeepSeek4LiveCodeBenchV6EvalCLI \
  --model-path /absolute/path/to/deepseek_4_flash.ckpt \
  --dataset Apps/LocalCode/Eval/LiveCodeBenchV6.jsonl \
  --output-jsonl /absolute/path/to/results/lcb-v6-smoke.jsonl \
  --start 0 \
  --limit 1
```

Run the full standard subset by omitting `--start` and `--limit`:

```sh
bazel-bin/Apps/LocalCode/DeepSeek4LiveCodeBenchV6EvalCLI \
  --model-path /absolute/path/to/deepseek_4_flash.ckpt \
  --dataset Apps/LocalCode/Eval/LiveCodeBenchV6.jsonl \
  --output-jsonl /absolute/path/to/results/lcb-v6-seed42.jsonl
```

Each task writes one `thinking` record followed by one `answer` record. Records are synchronized to
disk individually. If a run is interrupted, repeat the identical command with `--resume`; the CLI
validates the dataset position, seed, and budgets before reusing records. Without `--resume`, it
refuses to overwrite a non-empty result.

If thinking reaches the forced `</think>` boundary, the harness writes a zero-token answer record
with `stopReason: forced_thinking_boundary` and proceeds immediately to the next task. This avoids
spending time on an answer derived from truncated reasoning. The scorer reports and excludes these
tasks from Pass@1. A natural EOS before `</think>` remains an ordinary failed generation.

## Isolated official scoring

Generated Python is untrusted. Do not run the Python scorer directly on the host. The shell entry
point verifies the pinned LiveCodeBench revision, builds a minimal image, disables networking,
drops capabilities, uses a read-only root filesystem, and limits memory and process count.

```sh
Apps/LocalCode/Eval/score_deepseek4_livecodebench_v6.sh \
  /absolute/path/to/LiveCodeBench \
  Apps/LocalCode/Eval/LiveCodeBenchV6.jsonl \
  /absolute/path/to/results/lcb-v6-seed42.jsonl \
  /absolute/path/to/results/lcb-v6-seed42-score.json
```

Optional fifth and sixth arguments set evaluator process count and per-test timeout. Defaults are
8 processes and 6 seconds. The score artifact includes Pass@1, extraction and syntax-valid rates,
outcome and difficulty breakdowns, token averages, per-task official metadata, excluded forced
thinking cases, and dataset/generation/upstream fingerprints.
