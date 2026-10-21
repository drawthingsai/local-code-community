# Local Code CLI

Build with `bazel build //Apps/LocalCode:LocalCodeCLI` using the repository's Darwin
workspace and Bazel configuration. A fresh macOS checkout needs `WORKSPACE` and
`.bazelrc` symlinked to `WORKSPACE.darwin` and `.bazelrc.darwin`, and the Node/Python/Lean
Git LFS payloads downloaded. Run through Bazel or keep the executable's runfiles
with it; the embedded runtimes and built-in skills are required for agent work.

## Commands

```sh
bazel run //Apps/LocalCode:LocalCodeCLI -- models

bazel run //Apps/LocalCode:LocalCodeCLI -- auth login --provider anthropic
bazel run //Apps/LocalCode:LocalCodeCLI -- auth status --provider anthropic

bazel run //Apps/LocalCode:LocalCodeCLI -- local-agent \
  --model qwen_3.8_27b_i4x.ckpt \
  --project /path/to/project \
  --message 'Review the parser and fix the failing tests.' \
  --reasoning-effort high --thinking-budget 65536 \
  --trace --result-json /path/to/run.json

bazel run //Apps/LocalCode:LocalCodeCLI -- local-agent \
  --model qwen_3.8_27b_i4x.ckpt \
  --project /path/to/project \
  --resume /path/to/run.json \
  --message 'Now check the other edge cases.' \
  --result-json /path/to/continued.json

bazel run //Apps/LocalCode:LocalCodeCLI -- remote-agent \
  --provider anthropic --model YOUR_MODEL \
  --project /path/to/project --prompt-file request.txt \
  --reasoning-effort high --trace --result-json /path/to/remote-run.json
```

```sh
bazel run -c opt //Apps/LocalCode:LocalCodeCLI -- speedometer \
  --model qwen_3.8_27b_i4x.ckpt --result-json /path/to/speed.json
```

`local-agent` accepts every model in the app's `LLMZoo`, by file identifier or
display name. It uses the same Qwen and DeepSeek generators, tokenizers, coding
agents, compaction, reasoning-effort mapping, and deterministic sampling policy.
Checkpoints default to the app's model directory (`~/Documents/Models` for the
CLI); use `--models-dir` or `--model-store` to select another location. The latter
must contain a checkpoint matching the selected model's architecture.

`speedometer` takes Model Speed's readings: a 4,096-token prefill and a 128-token
decode at 0, 4K, 8K, and so on up to 512K tokens of context, as far as the model's
context window and the machine's memory allow. As in llama-bench, both are labeled
with the context already in use: the decode runs after only a short prompt, not after
the 4K one. `--context-length` picks other lengths,
in multiples of 4096. The context is a fixed agent session reading the bundled Python
standard library. The first run for a model prefills it once into
`speed_context_cache.sqlite3` under Caches (`--cache` moves it); later runs restore each
length from there, once for each, so only the 4K prefill and the decode are timed. Each
reading's prefill starts after a 20-second cool-down, so the heat of the warm-up, a context build,
or the reading before it doesn't slow it; the seconds column includes that wait. Thinking and
sampling follow `--thinking-budget` and `--deterministic`, as for the agents.

For DeepSeek, `--weights-streaming 8|16|32|48|0` selects the expert memory policy;
zero disables streaming. Its default follows `DeviceCapability`. The default
prefill chunk size follows the app's memory policy, and can be overridden with
`--chunked-prefill-max-length`. `--no-deterministic` selects stochastic sampling.

Both agents accept `--message` or `--prompt-file` (exactly one); `--prompt-file -`
reads stdin. `--workspace` controls `/home` and ancestor skill discovery and must
contain the project. Without it, the project is also the workspace. Both paths
use the app's file tools, OSH/Python/Node/npm, Lean/Z3, project-memory editing,
date/time, and web tools. Automatic memory injection is disabled for CLI turns.
`--web-search-provider disabled` disables search. `--web-search-provider kagi`
requires `KAGI_API_KEY`; `--web-search-provider brave` requires `BRAVE_API_KEY`.
Either can use the variable named by `--web-search-api-key-environment` instead.

For remote image input, select direct OpenRouter and a model whose catalog lists
image input and tool support. Attach files with repeatable `--image` options:

```sh
bazel run //Apps/LocalCode:LocalCodeCLI -- remote-agent \
  --provider openrouter --model google/gemini-3-flash-preview \
  --project /path/to/project --message 'Describe the image precisely.' \
  --image /path/to/screenshot.png --result-json /path/to/vision-run.json
```

The remote `read` tool can also inspect `.png`, `.jpg`, `.jpeg`, `.webp`, and `.gif`
files in permitted directories when using OpenRouter, in both the app and CLI.
Line options are ignored for image reads. Each image is limited to 10 MiB; direct
OpenRouter requests are limited to 32 MiB including base64 overhead. Unsupported
or invalid image files return a tool error. The selected model must itself support
vision; choosing OpenRouter does not add vision to a text-only model.

Image bytes are embedded in saved conversations, so `--resume` works even if the
original image changes or is removed. Result JSON files therefore contain the
images as well as the text. Compaction sends retained visual evidence as images,
not base64 text. The managed Local Code router and the other remote adapters do
not yet accept images. Screenshot capture and mouse/keyboard control are separate
from this image-input capability.

Relative CLI paths resolve against the caller's original working directory,
including under `bazel run`, and stay stable if an embedded command changes its
working directory.

Project instructions, `.agents/skills`, built-in skills, and customized
`.localc/templated_system_prompt_*.md` files use the app's loaders. Built-in skill
paths resolve through `/app_bundle` for both native file tools and shell tools.

`auth login --provider anthropic` opens the Claude browser sign-in flow and
waits for its local callback. `openai` uses the ChatGPT device-code
flow. Both require the default official endpoint. `--no-browser` prints the URL
for manual opening. Sign-in times out after 15 minutes and supports SIGINT/SIGTERM.
Credentials are stored using the app's Keychain format; `remote-agent` refreshes
expired OAuth tokens before a request. `auth status` reports saved credentials
and expiry without claiming that server authentication has been verified.
`auth logout --provider anthropic` removes only that endpoint's saved credentials.
These commands manage Local Code credentials, independently of Claude Code's login.

Remote provider keys come from `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`OPENROUTER_API_KEY`, or `LOCAL_CODE_API_KEY`, overridable with
`--api-key-environment`. A nonempty environment key takes precedence over saved
credentials. An explicitly selected key variable must be populated; it never
silently falls back to another account. Without a key override, saved Keychain
credentials are used. The `openai` provider uses sign-in only; use
`openai-compatible` for an API key and custom endpoint. The `localcode` provider
requires `--base-url`.
For custom OpenAI-compatible endpoints, select a key with `--api-key-environment`,
use a saved credential for that exact URL, or pass `--no-auth` (which sends no
authorization header and cannot be combined with `--api-key-environment`). An ambient
`OPENAI_API_KEY` is used automatically only for `api.openai.com`; it is never sent to a
custom server.

Compatible base URLs can be a server root, an API prefix such as `/v1`, or the full
`/v1/chat/completions` URL. Only `api.openai.com` defaults to `/v1`; include `/v1` for
local servers that need it. HTTPS certificate validation remains enabled. HTTP is
accepted only for localhost, `.local` hostnames, loopback IPs, RFC 1918 IPv4 addresses,
and IPv6 unique-local addresses; it is unencrypted, so use it only on trusted networks.
Redirects across schemes, hosts, or ports are rejected for all providers; enter the
final API URL directly.

Remote limits are discovered from provider metadata unless both
`--context-window-tokens` and `--maximum-output-tokens` are supplied. Compatible servers
that omit limits or lack a model-detail route use fallback limits of 16384 context and
2048 output tokens. These are assumptions, not measured capacity; set the overrides
when the model's limits are known. Reported contexts below 4096 tokens fail metadata
validation. Authentication, TLS, and network failures still fail the request.

## Results and continuation

Final assistant text goes to stdout; `--trace` sends progress to stderr. The
embedded runtime may also write diagnostics to stderr.

`--result-json` atomically writes a run record. Local records include the model,
project, timestamps, output tokens, structured tool calls, token/context counts,
stop flags, and complete `prefixTokens`. Compaction replaces that prefix with the
agent's checkpoint instead of appending it to stale history. Remote records keep
the existing `provider`, `model`, `baseURL`, `project`, timing, `finalText`, `error`,
`requests`, and `state` fields; `state` retains the transcript and context
calibration, including structured tool results and provider reasoning metadata.

`--resume` reads the corresponding agent's result file. The model and project
must match; remote runs also require the same provider and endpoint. Specify
`--result-json` again to save the continued conversation (the same filename is
allowed). These explicit CLI snapshots are separate from the app's project
history database.

SIGINT/SIGTERM request cooperative cancellation and save the result when the
agent returns, exiting with status 130/143. A local token-limit stop also saves
the result and exits nonzero. The limit and `generatedTokens` accumulate across
model calls, including tool rounds and compaction. Local GPU operations must reach
their next cancellation boundary. Remote cancellation closes the pending transcript
and saves it immediately. Embedded background jobs belong to their CLI process and
end when it exits; they do not become persistent services. The executable flushes
its output and uses `_Exit` after saving the run so unfinished embedded threads
cannot race C++ global destruction during shutdown.

The `generate` command runs raw generation, TTFT, generation timing, MTP
generation, and MTP draft-acceptance benchmarks. It is the default subcommand,
so existing `LocalCodeCLI --variant ...` invocations still work. Use
`generate --help` or `<command> --help` for the full argument lists. Keeping
benchmark options on this subcommand lets agent options such as `--model-store`,
`--trace`, and `--queue-watermark` reach the selected agent.

## Parity review

The execution gaps addressed in this change are:

| Previous CLI gap | Current behavior |
| --- | --- |
| Local mode only ran raw Qwen benchmarks | `local-agent` runs the app's Qwen and DeepSeek tool loops |
| Model list and architecture support drifted from the app | `models` and local model selection use `LLMZoo` |
| Local reasoning, sampling, and memory policies unavailable | CLI options feed the existing app implementations |
| Remote reasoning selection ignored | The selected effort reaches `makeChatProvider` |
| No continued conversations | Both agents restore their result JSON |
| Missing skills, editable prompt templates, and workspace selection | Shared loaders and explicit project/workspace paths |
| Node/npm and virtual-child setup missing | Shared signed npm archive preparation and Node preload |
| Bundled skill paths failed outside an app bundle | Shared resource discovery covers bundles, the checkout, and runfiles |
| Invalid benchmark token counts could trigger a precondition | Argument validation rejects them before loading checkpoints |
| Relative CLI paths depended on Bazel/runfiles and subsequent shell directory changes | Paths use a captured caller directory |

This change covers agent execution and remote sign-in. Model downloading,
app-database history browsing and backend switching, queued
prompts, and multi-conversation foreground/background scheduling still belong to
the app and are not exposed by these CLI commands. The CLI does not currently
provide an interactive terminal chat loop or a SwiftPM executable product.

## Verification

```sh
bazel test //Apps/LocalCode:CLIParityTests \
  //Apps/LocalCode:LocalPathResolverTests \
  //Apps/LocalCode:FileToolsTests \
  //Apps/LocalCode:SkillCatalogTests \
  //Apps/LocalCode:SystemPromptTemplateTests \
  //Apps/LocalCode:EnvironmentContextTests \
  //Apps/LocalCode:ProjectMemoryTests \
  //Apps/LocalCode:ProjectContextTests \
  //Apps/LocalCode:SystemPromptSectionTests \
  //Apps/LocalCode:ShellCommandParserTests \
  //Apps/LocalCode:ToolCallParserTests \
  //Apps/LocalCode:CheckSmtToolTests \
  //Apps/LocalCode:DeepSeek4TranscriptTests \
  //Libraries/RemoteAPI:RemoteAPITests \
  //Libraries/WebSearch:WebSearchTests
bazel test //Libraries/SwiftLLM:Qwen3_5TextGenerationTests
python3 -m unittest discover -s Apps/LocalCode/Tests/AnswersChartsBenchmark -p test_benchmark.py
bazel build //Apps/LocalCode:LocalCodeCLI
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

The focused CLI tests exercise OAuth callbacks/timeouts, Keychain credential
selection, refresh and logout, argument validation, model selection, prompt and
workspace handling, remote transcript restoration, local resume validation,
bundled skill resolution, native file/memory/job tools, actual Python/Node/npm
and Lean/Z3 execution through `bash`, and complete remote tool-and-resume cycles.
In-process API fixtures exercise all four providers and the official OpenAI
Responses endpoint through the production factory, including metadata discovery,
failure snapshots, and SIGINT/SIGTERM. Image regressions cover multipart OpenRouter
requests, complete tool batches, image snapshots across resume, path permissions,
compaction, and unsupported-provider errors. The GPU regression target creates a tiny
random checkpoint and checks single-token generation, partial-handler stopping,
MTP generation, and MTP draft acceptance without downloading weights.
They use a custom XCTest entry point because `ios_system` interposes `exit()` and
`_exit()`; the runner preserves Bazel's test discovery/filtering and XML reporting
and terminates with `_Exit()` using the recorded test result.

On 2026-09-09, the CLI and iOS app builds passed, along with 221 tests across
the 15 CPU test targets, three tests in the GPU regression target, and nine
chart benchmark tooling tests.
Live checks used the installed Qwen 3.8 27B i4x checkpoint and covered:

- Help/model listing, checkpoint overrides, prompt files and stdin, workspace
  paths, validation errors, and trace output.
- A complete write/read tool loop, saved JSON with tool responses, continuation,
  token-budget stops, and SIGINT/SIGTERM snapshots with exit statuses 130/143.
- Python, Node, npm/npx, Lean/Z3, Lean archive discovery, background command
  completion, local HTTP page fetching, and live DuckDuckGo search.
- Raw generation, generation timing, TTFT, MTP generation, and draft acceptance,
  including single-token prompts, 32 generated tokens, and four draft depths
  across multiple starting positions.

After rebasing onto `9bd7dc57d`, a live revenue-bar case also checked the newly
merged chart skill with the current CLI. It completed in 92.8 seconds of agent
time with 1,563 generated tokens and five structured tool responses. Independent
embedded-Python replay verified all eight plotted labels/values and reproduced
the original PNG byte-for-byte; PNG/SVG validation and visual review passed.
The scorer now retains the selected CLI's reported counters without labeling
current cumulative token totals as the older snapshot's rolling averages.

The subsequent [functional and performance evaluation](../Tests/CLIFunctionalBenchmark/Evaluation-2026-09-09.md)
passed 143 final CLI process runs using native Claude OAuth and the installed
Qwen checkpoint, plus 238 regression/tooling tests. It includes per-case timings,
real npm/npx script execution, saved conversations, limits, cancellation, live
compaction and MTP token equivalence. The evaluation found and fixed direct shell
builtin dispatch and a process-shutdown race. The CLI and iOS app builds pass.

Other model sizes and live DeepSeek inference require additional checkpoints.
Other remote-provider accounts and Kagi were not live tested; their argument and
provider paths are covered by fixtures. The evaluation report preserves initial
failures, timing outliers and the distinction between tool and model-answer errors.
