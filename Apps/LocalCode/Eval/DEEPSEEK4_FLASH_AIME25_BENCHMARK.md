# DeepSeek V4 Flash AIME 2025 benchmark

This is the canonical local quality benchmark for DeepSeek V4 Flash SQLite checkpoints. Run it
from the Draw Things repository root on a Mac with enough unified memory for the checkpoint. Run
only one checkpoint process at a time; these models can use 80 GB or more.

## Files

| File | Purpose |
| --- | --- |
| `Apps/LocalCode/Debug/DeepSeek4AIME25EvalCLI.swift` | Generation, progress reporting, scoring, and JSONL output |
| `Apps/LocalCode/Eval/AIME2025.jsonl` | Ordered 30-case dataset containing only questions and expected answers |
| `Apps/LocalCode/BUILD` | `DeepSeek4AIME25EvalCLI` Bazel target |

Case indices and `--start` are zero-based. “Case 13” means row 14 of the dataset.

## Runtime revision

Use the dependency revisions pinned by the current main branch. Do not use local ccv or s4nnc
overrides for checkpoint comparisons. At the time this harness was finalized, main pinned:

| Component | Revision |
| --- | --- |
| Draw Things | `fa34a128f55fa2a7ac8455f7c86b94f143d9968a` |
| s4nnc | `e1c44b219df7c274001c901a2c32ccbe525c9d7d` |
| ccv | `8e8d360d2cd914456d7be22b0af73b8bfcb46c6d` |

These revisions include the RMSNorm synchronization fixes, next-token fix, and native Gumbel
argmax support. Record `git rev-parse HEAD` with every published run. A later main revision is
acceptable when its normal dependency pins are used.

## Dataset and scoring

Validate the dataset before a long run:

```sh
test "$(wc -l < Apps/LocalCode/Eval/AIME2025.jsonl | tr -d ' ')" = 30
jq -s -e 'length == 30 and all(.[]; (.question | type == "string") and (.expectedAnswer | type == "string"))' Apps/LocalCode/Eval/AIME2025.jsonl
```

Every question uses this prompt:

```text
<｜begin▁of▁sentence｜>You are solving a hard benchmark question. Reason carefully. The final answer must follow the requested format exactly.<｜User｜>{question}

Solve the problem. At the end, write exactly one final line in this format and do not write anything after it:
Answer: <integer><｜Assistant｜><think>
```

The scorer finds the first `</think>` token and searches only the text after it for a complete
`Answer: <integer>` line. Expected and extracted answers are normalized as integers before exact
comparison. A number inside the thinking section does not count as an answer.

Each case receives a fresh KV cache and a disabled project context cache. A multi-case invocation
keeps the model and graph loaded but does not reuse another case’s cache.

## Build

Build the optimized binary without dependency overrides:

```sh
bazel build -c opt //Apps/LocalCode:DeepSeek4AIME25EvalCLI
test -x bazel-bin/Apps/LocalCode/DeepSeek4AIME25EvalCLI
```

Use the built binary for long runs so compilation time is not included in model timing.

## Canonical settings

The CLI defaults are the production benchmark settings:

| Setting | Default |
| --- | ---: |
| First case | `0` |
| Number of cases | `30` |
| Thinking budget | `65536` |
| Total generated-token limit | `66048` |
| DynamicGraph concurrency | `1` |
| Queue watermark | `128` |
| Token selection | deterministic argmax |

The extra 512 generated tokens allow `</think>` and the final answer after a forced thinking
boundary. NAX remains enabled. The CLI disables only the separate MFA Apple Neural Engine path.

The required arguments are `--model-path` and `--output-jsonl`. Use absolute paths for both so the
checkpoint and artifact are unambiguous.

## Run one case

Case 13 with canonical argmax settings:

```sh
bazel-bin/Apps/LocalCode/DeepSeek4AIME25EvalCLI \
  --model-path /absolute/path/to/deepseek_4_flash_0731_i2x.ckpt \
  --output-jsonl /absolute/path/to/results/case13.jsonl \
  --start 13 \
  --limit 1
```

Override limits only when the run is deliberately testing another budget:

```sh
bazel-bin/Apps/LocalCode/DeepSeek4AIME25EvalCLI \
  --model-path /absolute/path/to/deepseek_4_flash_0731_i2x.ckpt \
  --output-jsonl /absolute/path/to/results/case13_100k.jsonl \
  --start 13 \
  --limit 1 \
  --thinking-budget 100000 \
  --max-new-tokens 100512
```

The output file is truncated when a run starts. Always use a new artifact path for a rerun.

## Run all 30 cases

Omit `--start` and `--limit` to use their full-suite defaults:

```sh
bazel-bin/Apps/LocalCode/DeepSeek4AIME25EvalCLI \
  --model-path /absolute/path/to/deepseek_4_flash_0731_i2x.ckpt \
  --output-jsonl /absolute/path/to/results/full30.jsonl
```

For interruption recovery, use non-overlapping ranges and separate output files. A completed case
is written as one complete JSONL line; the in-progress case has no result line.

## Gumbel argmax

Use native Gumbel argmax only for an explicit sampling experiment:

```sh
bazel-bin/Apps/LocalCode/DeepSeek4AIME25EvalCLI \
  --model-path /absolute/path/to/deepseek_4_flash_0731_i2x.ckpt \
  --output-jsonl /absolute/path/to/results/case4_gumbel.jsonl \
  --start 4 \
  --limit 1 \
  --gumbel-argmax
```

Add `--seed 42` to reproduce the same sampled trajectory. A seed is rejected unless
`--gumbel-argmax` is also present. The CLI seeds both `DynamicGraph` and its GPU stream context.

Argmax and Gumbel results are different evaluation modes and must be reported separately. Gumbel
can heal a greedy repetition trajectory without demonstrating that the checkpoint solves the case
under canonical argmax.

## Output

The CLI prints progress every 512 generated tokens and writes one JSON object per completed case.
The important fields are:

| Field | Meaning |
| --- | --- |
| `caseIndex` | Zero-based dataset index |
| `expectedAnswer`, `extractedAnswer`, `score` | Exact scoring result |
| `promptTokenCount` | Tokenized prompt length |
| `generatedTokenCount` | All generated tokens |
| `thinkingTokenCount` | Tokens before `</think>`, or all tokens if it never appeared |
| `stopReason` | `answer`, `max_new_tokens`, `max_post_thinking_tokens`, or `eos` |
| `durationSeconds`, `generatedTokensPerSecond` | Runtime measurements |
| `generatedTokenIDs`, `output` | Complete trajectory for auditing |

A natural pass has `score == 1`, `stopReason == "answer"`, and `thinkingTokenCount < 65536`.
A correct answer at exactly 65,536 thinking tokens is a forced-boundary pass and must be labeled
separately.

Print a compact result table with:

```sh
jq -r '[.caseIndex, .expectedAnswer, (.extractedAnswer // "nil"), .score, .thinkingTokenCount, .generatedTokenCount, .stopReason, .durationSeconds] | @tsv' /absolute/path/to/results.jsonl
```

Summarize a complete run with:

```sh
jq -s '
  sort_by(.caseIndex) |
  {
    correct: (map(.score) | add),
    total: length,
    naturalCorrect: (map(select(.score == 1 and .stopReason == "answer" and .thinkingTokenCount < 65536)) | length),
    forcedBoundaryCorrect: (map(select(.score == 1 and .thinkingTokenCount == 65536)) | length),
    failures: map(select(.score == 0) | {caseIndex, expectedAnswer, extractedAnswer, thinkingTokenCount, stopReason})
  }
' /absolute/path/to/full30.jsonl
```

## Reruns and determinism

Maintain one authoritative artifact for each checkpoint, case, runtime revision, budget, and token
selection mode. A later deliberate rerun supersedes an earlier run only when those settings match.
Do not count every matching file because that double-counts reruns.

Compare complete token trajectories rather than final answers alone:

```sh
jq -c '.generatedTokenIDs' /absolute/path/to/run1.jsonl | shasum -a 256
jq -c '.generatedTokenIDs' /absolute/path/to/run2.jsonl | shasum -a 256
```

For Gumbel, repeat with the same explicit seed. Runtime and throughput may differ even when token
IDs are identical.

## Reporting checklist

Record:

- absolute checkpoint path or checksum;
- Draw Things revision and its pinned s4nnc and ccv revisions;
- zero-based case indices;
- thinking and total-generation limits;
- concurrency and queue watermark;
- argmax or Gumbel argmax, plus seed when present;
- expected and extracted answers;
- thinking-token count and stop reason;
- natural or forced-boundary classification;
- which reruns are authoritative;
- whether the result covers a subset or all 30 cases.
