# Qwen 3.8 27B AIME 2025 benchmark

This is the canonical local quality benchmark for Qwen 3.8 27B SQLite checkpoints. It mirrors the
DeepSeek4 AIME25 benchmark contract while running the production `Qwen3_5TextGenerator` and
`Qwen3_5ContextCache` implementations from LocalCode.

## Files

| File | Purpose |
| --- | --- |
| `Apps/LocalCode/Eval/QwenAIME25EvalCLI.swift` | Generation, progress reporting, scoring, and JSONL output |
| `Apps/LocalCode/Eval/AIME2025.jsonl` | Shared ordered 30-case dataset |
| `Apps/LocalCode/BUILD` | `QwenAIME25EvalCLI` Bazel target |

Case indices and `--start` are zero-based. “Case 14” means row 15 of the dataset.

## Benchmark contract

The Qwen and DeepSeek4 evaluators share:

- the committed 30-case dataset and `expectedAnswer` schema;
- the system and user instructions, including the final `Answer: <integer>` line;
- exact integer normalization and scoring only after the first end-of-thinking token;
- fresh per-case KV and disabled project context caches;
- strict range validation, progress every 512 tokens, and one JSON object per completed case;
- concurrency `1`, queue watermark `128`, and the separate MFA Apple Neural Engine path disabled.

Qwen uses its native chat control tokens:

```text
<|im_start|>system
You are solving a hard benchmark question. Reason carefully. The final answer must follow the requested format exactly.<|im_end|>
<|im_start|>user
{question}

Solve the problem. At the end, write exactly one final line in this format and do not write anything after it:
Answer: <integer><|im_end|>
<|im_start|>assistant
<think>
```

The streaming stop check requires a line terminator after the integer. This prevents a tokenized
prefix such as `Answer: 7` from prematurely stopping an intended `Answer: 70`. A final answer
immediately followed by EOS is scored after the generator returns.

## Qwen-specific settings

| Setting | Default |
| --- | ---: |
| First case | `0` |
| Number of cases | `30` |
| Thinking budget | `65536` |
| Total generated-token limit | `81920` |
| DynamicGraph concurrency | `1` |
| Queue watermark | `128` |
| Thinking selection | temperature 1, min-p 0.05 |
| Answer selection | argmax (temperature 0) |
| Base seed | `42` |

Qwen retains 16,384 tokens beyond the forced thinking boundary because its answer section can be
substantially longer than DeepSeek4's. MTP is selected automatically from the checkpoint by the
production generator. The evaluator uses the production `deterministic: true` policy, which samples
thinking but uses argmax for answering. Task `i` uses `baseSeed + i`; `--seed` overrides the base
seed. Both the graph and GPU stream are seeded for each case. The evaluator does not offer answer
temperature variants.

## Build

Build the optimized binary and use it directly for timed runs:

```sh
bazel build -c opt //Apps/LocalCode:QwenAIME25EvalCLI
test -x bazel-bin/Apps/LocalCode/QwenAIME25EvalCLI
```

## Run one case

```sh
bazel-bin/Apps/LocalCode/QwenAIME25EvalCLI \
  --model-path /absolute/path/to/qwen_3.8_27b_i4x.ckpt \
  --output-jsonl /absolute/path/to/results/case14.jsonl \
  --start 14 \
  --limit 1
```

## Run all 30 cases

Omit `--start` and `--limit` to use the full-suite defaults:

```sh
bazel-bin/Apps/LocalCode/QwenAIME25EvalCLI \
  --model-path /absolute/path/to/qwen_3.8_27b_i4x.ckpt \
  --output-jsonl /absolute/path/to/results/full30.jsonl
```

The output file is truncated when a run starts. Use separate output files for non-overlapping
ranges when recovering from an interruption.

## Output and reporting

The JSONL schema matches the DeepSeek4 evaluator: `caseIndex`, answers and score, prompt/generated/
thinking token counts, duration and throughput, stop reason, complete token IDs, and decoded output.

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
    naturalCorrect: (map(select(.score == 1 and .thinkingTokenCount < 65536)) | length),
    forcedBoundaryCorrect: (map(select(.score == 1 and .thinkingTokenCount == 65536)) | length),
    failures: map(select(.score == 0) | {caseIndex, expectedAnswer, extractedAnswer, thinkingTokenCount, stopReason})
  }
' /absolute/path/to/full30.jsonl
```

Record the absolute checkpoint path or checksum, base seed, and `git rev-parse HEAD` with every
published run. Older aligned runs made before this sampler change used argmax throughout and must
be distinguished from current sampled-thinking runs.

## Historical artifact compatibility

Older Qwen eval artifacts used private `/private/tmp/aime2025-*.jsonl` inputs, a boxed-answer prompt,
and a scorer that could fall back to the last integer anywhere in the decoded output. Their scores
remain useful historical evidence, but they are not directly comparable to runs from this aligned
benchmark. Establish a new baseline before comparing checkpoints with this evaluator.
