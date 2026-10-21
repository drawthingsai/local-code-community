# Local Code CLI correctness and performance evaluation

Measured on September 9, 2026 (America/Los_Angeles; records use UTC).

The final executable passed **143/143 process runs** across the
available CLI commands, shared tools and tested error boundaries. The earlier
passes exposed two CLI bugs, both fixed and retested. A separate initial Claude
answer misread a correctly fetched heading; that model error is retained below.
Unavailable providers and model checkpoints are explicitly excluded from live coverage.

## Environment and method

- Apple M5 Max, 48 GiB RAM, macOS 26.6.2; Swift 6.2.4; Bazel fastbuild.
- Local checkpoint: `qwen_3.8_27b_i4x.ckpt`; remote: Claude Sonnet 4.6 using
  native Local Code OAuth saved in Keychain. A real authentication probe returned
  `LOCAL_CODE_AUTH_OK`; no credentials were exported.
- Executable SHA-256: `35e1fa1342290a003ab99096571411cad187ca35bea5436d60127f7126366d9e`.
- Source base: `eea44f37d1d2c1fc9d90967e8ec294a471c49831` plus this PR's auth, shell dispatch and
  shutdown changes. Exact measured source hashes are in the JSON evidence.
- Inference ran sequentially in fresh processes. Filesystem/model caches were
  retained, including the shared local project's context cache. This is not a
  controlled cold-start or sustained-load experiment. Ordinary host and network
  variability remains in the results.
- Wall time includes process startup, setup, model requests, tools and result
  writing. Provider time is the sum of saved request durations. The remainder
  includes orchestration and tool execution; it is not a pure tool microbenchmark.
- Assertions check exit codes, saved tool-call/result linkage, file bytes, returned
  content, continued history and cancellation/error snapshots. Most individual
  tools have one final sample; timing differences between them are not statistical rankings.

## Main performance observations

- Claude plain replies: **1.058 (1.051–1.111) seconds**, three final samples.
- Local plain replies: **8.145 (7.935–15.352) seconds**, three final samples.
  The first local process included more cache/initialization work; later processes
  reused filesystem and project context caches.
- SIGINT/SIGTERM during an active remote shell tool: **3.9–8.9 ms**
  from signal delivery to process exit, three runs per signal. All returned 130/143
  with valid saved cancellation records.
- Raw 32-token generation: median decode-loop speed **14.28 tokens/s**.
  MTP: **16.41 tokens/s**, or **1.15×** the decode-loop speed
  in this short sample. Compare whole-process times below before drawing a latency conclusion.
- 256-token TTFT: **3886.454 ms** median over five measured
  runs after one warmup. TTFT is the CLI's reported in-process benchmark metric.
- The first remote custom-template run after rebuilding took 15.513 seconds,
  including 8.451 seconds outside agent execution. A prior rebuild also had a
  slow first request. These outliers are retained; the current evidence does not
  establish whether paging, runtime setup, Keychain or other host load caused them.

## Command surface

Help covers the root command, generate, models, both agents, auth and all auth
subcommands. Model listing checks the installed checkpoint and an empty override
directory. Auth status checks the saved OAuth credential. Invalid arguments are
expected to exit 64 before inference. The complete individual cases are in the JSON.

| Case | Result | Runs | Wall seconds: median (range) |
| --- | --- | ---: | ---: |
| help-root | Pass | 5 | 0.080 (0.076–0.081) |
| help-generate | Pass | 5 | 0.078 (0.075–0.082) |
| help-models | Pass | 5 | 0.081 (0.078–0.082) |
| help-local-agent | Pass | 5 | 0.081 (0.079–0.083) |
| help-remote-agent | Pass | 5 | 0.081 (0.081–0.081) |
| help-auth | Pass | 5 | 0.081 (0.080–0.081) |
| help-auth-login | Pass | 5 | 0.081 (0.077–0.081) |
| help-auth-status | Pass | 5 | 0.081 (0.076–0.081) |
| help-auth-logout | Pass | 5 | 0.081 (0.078–0.081) |

| Case | Result | Runs | Wall seconds: median (range) |
| --- | --- | ---: | ---: |
| models-installed | Pass | 1 | 0.081 |
| models-empty-directory | Pass | 1 | 0.081 |
| auth-status | Pass | 1 | 0.136 |
| prompt-conflict | Pass | 1 | 0.082 |
| stdin-empty | Pass | 1 | 0.077 |
| checkpoint-missing | Pass | 1 | 0.079 |
| model-unknown | Pass | 1 | 0.079 |
| budget-invalid | Pass | 1 | 0.076 |
| thinking-invalid | Pass | 1 | 0.078 |
| prefill-invalid | Pass | 1 | 0.081 |
| streaming-qwen | Pass | 1 | 0.081 |
| workspace-outside | Pass | 1 | 0.079 |
| key-override-missing | Pass | 1 | 0.076 |
| kagi-key-missing | Pass | 1 | 0.081 |
| remote-context-invalid | Pass | 1 | 0.076 |
| remote-rounds-invalid | Pass | 1 | 0.082 |
| remote-compaction-invalid | Pass | 1 | 0.082 |
| auth-custom-endpoint | Pass | 1 | 0.079 |
| auth-unsupported-provider | Pass | 1 | 0.082 |
| raw-zero | Pass | 1 | 0.083 |
| raw-modes-conflict | Pass | 1 | 0.082 |

## Remote functionality, one case at a time

Memory covers append/read/replace/read/remove/read. Shell cases include direct
formatting, pipelines and redirection; embedded runtimes include Python, Node,
npm/npx, Lean and Z3. Web search uses live DuckDuckGo; page fetching uses a local
HTTP fixture with known content. Disabled search is absent from the supplied tool
list. Resume verifies context recall, atomic replacement of the same saved file,
and rejection of another project.

| Case | Result | Runs | Wall seconds: median (range) | Provider seconds: median |
| --- | --- | ---: | ---: | ---: |
| plain-text | Pass | 3 | 1.058 (1.051–1.111) | 0.907 |
| prompt-file | Pass | 1 | 0.899 | 0.763 |
| stdin | Pass | 1 | 0.887 | 0.712 |
| write | Pass | 1 | 2.170 | 2.014 |
| read | Pass | 1 | 2.247 | 2.062 |
| more | Pass | 1 | 3.535 | 3.352 |
| edit | Pass | 1 | 5.491 | 5.311 |
| search | Pass | 1 | 5.378 | 5.199 |
| list | Pass | 1 | 3.695 | 3.537 |
| datetime | Pass | 1 | 3.214 | 3.032 |
| memory | Pass | 1 | 10.550 | 10.348 |
| bash-printf | Pass | 1 | 2.183 | 2.019 |
| bash-echo | Pass | 1 | 2.296 | 2.015 |
| bash-shell | Pass | 1 | 2.722 | 2.299 |
| python | Pass | 1 | 3.602 | 3.256 |
| node | Pass | 1 | 2.823 | 2.475 |
| npm | Pass | 1 | 2.780 | 2.402 |
| npx | Pass | 1 | 3.157 | 2.831 |
| lean | Pass | 1 | 4.018 | 3.181 |
| z3 | Pass | 1 | 2.453 | 2.129 |
| check-smt | Pass | 1 | 4.180 | 3.991 |
| job-wait | Pass | 1 | 10.006 | 9.769 |
| job-stop | Pass | 1 | 7.116 | 6.909 |
| search-disabled | Pass | 1 | 2.190 | 1.987 |
| search-live | Pass | 1 | 4.626 | 3.711 |
| webfetch | Pass | 1 | 2.802 | 2.590 |
| metadata-auto | Pass | 1 | 1.648 | 0.985 |
| reasoning-medium | Pass | 1 | 1.631 | 1.450 |
| reasoning-high | Pass | 1 | 1.328 | 1.174 |
| reasoning-max | Pass | 1 | 0.902 | 0.739 |
| runtime-ios-system | Pass | 1 | 3.154 | 2.845 |
| project-and-skill | Pass | 1 | 9.815 | 9.335 |
| resume-initial | Pass | 1 | 2.540 | 2.341 |
| resume-same-file | Pass | 1 | 0.887 | 0.726 |
| resume-wrong-project | Pass | 1 | 0.137 | — |
| package-npm-run | Pass | 1 | 3.241 | 2.862 |
| package-npx-local | Pass | 1 | 5.434 | 4.873 |

## Remote controls and failure handling

Round/output limits intentionally return nonzero. A one-round cap prevents the
pending tool from running and saves a paired error result. Missing-file and
nonmatching-edit cases preserve the expected error and leave files intact.
Compaction uses a synthetic saved conversation and a **real Claude checkpoint
request**; it verifies a shorter transcript and retention of the important marker.

| Case | Result | Runs | Wall seconds: median (range) | Provider seconds: median |
| --- | --- | ---: | ---: | ---: |
| custom-template | Pass | 1 | 15.513 | 7.055 |
| ancestor-skill | Pass | 1 | 10.197 | 9.735 |
| builtin-skill | Pass | 1 | 2.623 | 2.442 |
| round-cap | Pass | 1 | 1.535 | 1.351 |
| output-cap | Pass | 1 | 18.725 | 18.569 |
| remote-SIGINT | Pass | 3 | 2.080 (2.062–2.422) | 1.932 |
| remote-SIGTERM | Pass | 3 | 2.129 (2.128–2.260) | 1.990 |
| missing-file | Pass | 1 | 2.059 | 1.906 |
| edit-no-match | Pass | 1 | 3.271 | 3.088 |
| missing-key-boundary | Pass | 1 | 0.147 | — |
| live-compaction-synthetic-history | Pass | 1 | 6.889 | 6.747 |

## Local agent

The live local path verifies tool use and saved responses, continuation, model
file/display-name selection, explicit checkpoint/directory overrides, stdin,
workspace selection, reasoning/sampling/prefill/queue/MFA options, token limits,
and signal cancellation. Detailed combinatorial behavior remains covered by the
fixture/unit suite rather than an exhaustive live parameter sweep.

| Case | Result | Runs | Wall seconds: median (range) |
| --- | --- | ---: | ---: |
| plain-local | Pass | 3 | 8.145 (7.935–15.352) |
| local-tools | Pass | 1 | 19.198 |
| local-resume | Pass | 1 | 8.417 |
| local-stdin-options | Pass | 1 | 15.307 |
| local-token-cap | Pass | 1 | 13.123 |
| local-SIGINT | Pass | 1 | 4.427 |
| local-SIGTERM | Pass | 1 | 4.419 |

## Raw generation and MTP

The default shorthand and explicit generate command both work. The comparison
uses the same eight-token repeated prompt and 32-token output budget for ordinary
and MTP generation. Separate one-token-prompt MTP samples are retained under
`mtp-one-token`. Greedy-equivalence cases compare all 32 generated token IDs.
Draft acceptance tests four depths across four starting positions. Numeric raw
metrics and all timings are included in the JSON evidence.

| Case | Result | Runs | Wall seconds: median (range) |
| --- | --- | ---: | ---: |
| default-generate-trace | Pass | 1 | 13.297 |
| generation-timing | Pass | 3 | 14.207 (14.046–15.364) |
| ttft | Pass | 1 | 31.376 |
| mtp-one-token | Pass | 3 | 12.119 (11.459–13.241) |
| mtp-draft-depth | Pass | 1 | 11.303 |
| mtp-generate | Pass | 3 | 14.005 (13.663–14.038) |
| greedy-equivalence-reference | Pass | 1 | 13.458 |
| greedy-equivalence-mtp | Pass | 1 | 13.950 |

## Findings and fixes

1. **Standalone shell builtins failed.** `printf PRINTF_OK` returned command not
   found because the direct argv route bypassed OSH. Dispatch now uses the direct
   path only for registered ios_system commands. Real regressions cover formatting,
   redirection, `test`, and `false`; the final live printf case passes.
2. **Cancellation could crash during process exit.** SIGTERM saved the correct
   JSON but exited with SIGSEGV. The crash report showed OSH using a C++ regex
   while normal exit destroyed global state. The CLI now flushes stdout/stderr
   and uses `_Exit` after persisting the run, avoiding that teardown race. Six
   live signal runs pass on the final binary.
3. **Auth needed CLI integration and stable Keychain selection.** Added login,
   status and logout, saved-credential selection and refresh. Capturing the
   original macOS Keychain prevents embedded commands' HOME changes from breaking
   later credential reads. OAuth state is now independent of the PKCE verifier.
4. **One model-answer error.** The first webfetch response correctly contained
   `# WEB_FETCH_73`, but Claude described the following paragraph as the heading.
   An explicit request to quote the heading passed on subsequent runs. This was
   not a transport or HTML extraction failure.

Initial harness expectations were corrected separately: disabled websearch is
removed from the tool list, a one-round budget stops before the requested tool,
and saved cancellations use `cancelled`. Negative numeric values use
`--thinking-budget=-1`. Original attempts remain available in the local evidence.

## Limits and reproduction

Verification also passed 229 XCTest cases across 16 Bazel targets and nine chart
benchmark tooling tests (238 total). The final all-target invocation reused
Bazel's passing results; the changed CLI/auth/shell integration had already been
rebuilt and executed in the focused verification. Local Code CLI and the iOS
Local Code app both build successfully.

Live inference was limited to the installed Qwen checkpoint and authenticated
Anthropic account. DeepSeek/other Qwen sizes, OpenAI/OpenRouter/Local Code router
accounts, Kagi, ChatGPT device login, and real token-expiry refresh were not live
tested here. OAuth timeout/state rejection/refresh/logout and other provider
formats are covered by injected API/isolated Keychain tests. The user's actual
Claude credential was not logged out during evaluation.

See [the harness instructions](README.md) and [machine-readable results](evaluation-2026-09-09.json).
Full local stdout/stderr, snapshots, original failures and the crash report are
under `/tmp/local-code-functional-benchmark-20260909` and the macOS diagnostic log.
