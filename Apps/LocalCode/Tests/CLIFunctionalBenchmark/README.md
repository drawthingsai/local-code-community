# Local Code CLI functional evaluation

This harness runs real CLI processes sequentially, checks saved transcripts and
file effects, and records wall-clock time separately from the CLI's agent and
provider-request timings. Remote stages use Claude Sonnet 4.6 through Local
Code's saved Anthropic credentials. They consume account usage. Sign in with
`LocalCodeCLI auth login --provider anthropic` first.

Build `//Apps/LocalCode:LocalCodeCLI`, then run each stage with the same binary:

```sh
python3 Apps/LocalCode/Tests/CLIFunctionalBenchmark/benchmark.py \
  --cli /absolute/path/to/LocalCodeCLI \
  --output /tmp/local-code-evaluation \
  --stage surface
```

Stages:

- `surface`: command help, installed/missing model listing, saved auth status,
  and invalid-argument/error boundaries.
- `remote`: prompts, every shared tool, embedded runtimes, live DuckDuckGo,
  local HTTP page fetching, metadata discovery, reasoning options, skills,
  and saved conversation continuation.
- `remote-controls`: templates, ancestor and bundled skills, round/output caps,
  SIGINT/SIGTERM during shell execution, tool failures, and a live Claude
  compaction request over a clearly synthetic saved history.
- `local`: installed Qwen 3.8 27B i4x inference, shared tools, continuation,
  configuration overrides, token caps, and cancellation.
- `raw`: raw Qwen generation, generation timing, TTFT, and MTP generation and
  draft acceptance. Also pass `--tokenizer-dir` pointing to `vocab.json` and
  `merges.txt`. The raw `qwen3.6-27b` variant shares this checkpoint's shape.

`--model-store` overrides the default local checkpoint under `~/Documents/Models`.
`--filter` selects case names containing a substring. Run only one inference
stage at a time and avoid builds during timing. The harness exits nonzero on a
failed assertion and keeps both successful and failed attempts; rerunning never
overwrites earlier logs. Inspect failures before classifying them: an incorrect
model answer, a harness assertion, a provider failure, and a CLI bug are different
outcomes.

Each stage appends to `*-results.jsonl`; per-attempt directories contain stdout,
stderr and the resumable JSON record. Results identify the executable SHA-256.
No credentials are copied into the report. Test files stay under the chosen
output directory. Local inference can create a large `.localc/context_cache.sqlite3`
there; remove that test cache after all CLI processes have finished if disk space
is needed. Background tools belong to their CLI process and end when it exits.

Most tool cases are functional samples, not statistically powered latency studies.
Short text replies and selected raw generation modes have repeated measurements.
Provider/network latency and local cache/compilation effects remain in the
measurements; the harness does not claim a controlled cold-cache experiment.
Auth refresh/logout and unavailable providers/models require the separate
fixture tests or additional credentials/checkpoints.
