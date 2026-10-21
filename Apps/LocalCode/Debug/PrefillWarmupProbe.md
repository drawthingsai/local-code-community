# Prefill warm-up verification

Build the optimized probe and app:

```sh
bazel build -c opt //Apps/LocalCode:PrefillWarmupProbe //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

Both generators expose `warmupPrefill(graph:) -> Bool`. Each CodeAgent exposes
`warmupPrefill(_:graph:streamContext:) -> Bool`, applies its inference backend settings, enters
the supplied stream and no-grad scopes, then joins the stream and collects tensors without
vacuuming the pipeline cache. ChatWorkflow supplies its existing graph and stream. The generator
strictly loads real checkpoint weights and runs a fixed short schedule on temporary model/cache
state. It does not create a graph/stream or manage warm-up synchronization and collection.
The model instance supplies the checkpoint, configuration, chunk size, and expert residency
policy; there are no warm-up length or C-specialization arguments. A false return reports an
incomplete weight load/warm-up.

Both `decode` methods unconditionally insert `.disableAttentionSpecializingC` at entry and restore
the incoming flags with `defer`. This applies to prefill and decoding. M remains specialized for
full `chunkedPrefillMaxLength` chunks (4096 or 2048); shorter chunks enable dynamic M. DeepSeek also
applies that partial-chunk policy while preparing its first token/rotary inputs.

Fixed schedules:

* Qwen: two full chunks, then fresh 7-, 512-, and `chunkedPrefillMaxLength - 1`-token prefills.
  Load real linear-attention layer 0 and full-attention layer 3. Non-MTP terminal prefill uses a
  separate builder sharing those weights; MTP loads the real BF16 drafter. Terminal greedy and
  stochastic sampling/readback are covered in both M modes.
* DeepSeek: enough full chunks to exceed 4096 cached tokens (8192 for 4K chunks, 6144 for 2K),
  followed by cached 512-token and `chunkedPrefillMaxLength - 513`-token tails, then fresh
  4095- and 7-token prefills. Splitting the cached tail covers T below and above 1024 with
  more than 1024 compressed KV rows. The fresh 4095-token pass covers T >= 1024 with at most
  1024 compressed KV rows; for 2K chunks, it is one full chunk followed by a 2047-token tail.
  A fresh 2047-token pass alone would take the enumeration shortcut and miss that score tile.
  Checkpoint expert codecs select representative real layers (0, 1, 2, 37 for the tested i2x file).
  Compile-only shape placeholders expose parameters for the strict read; those inputs are never
  executed. The loaded shallow generator then uses ordinary `decode`, including its real terminal
  sampling. Different passes exercise greedy, reasoning, and stochastic answer selection without
  repeating a context sweep. `decode` has no warm-up-specific state or branches.

The app checks the selected model for warm-up on the main queue three seconds after workflow
initialization, and immediately after explicit local model selection (after download succeeds if
needed). ChatWorkflow records each checkpoint path in a process-wide set when warm-up is queued
or a local ask is scheduled. An ask within the startup delay therefore makes the delayed check
skip that model, as does a previous warm-up or selection in another workflow. Warm-up runs on the
existing inference queue without work-item cancellation; once queued, the next turn waits for it
to finish.

Example:

```sh
bazel-bin/Apps/LocalCode/PrefillWarmupProbe --model qwen3.6-27b \
  --model-path /path/to/qwen_3.8_27b_i4x_trailer.ckpt --warmup true \
  --prefill-tokens 17920 --prefill-repeats 2 --disable-mfa-apple-neural-engine
```

Use `--model deepseek-v4-flash` with its actual checkpoint and `--weights-streaming
8|16|32|48|none`. Other Qwen variants are `qwen3.5-4b` and `qwen3.5-9b`. The 27B selection
uses the shared architecture; the file path selects the actual real checkpoint.

Probe options:

* `--warmup true|false` (default true): run the exact production warm-up, or skip it for a control.
* `--prefill-tokens 0..65536`, `--prefill-repeats 1..8`: full-model prompt size and repetitions.
* `--chunk-length 2048|4096`: use the same chunk size in warm-up and full inference.
* `--decode-tokens 0..32`: optionally continue decoding; EOS may end generation early.
* `--thinking-budget 128` or `--deterministic false`: exercise reasoning/stochastic sampling.
* `--queue-watermark 128`, `--disable-mfa-apple-neural-engine`: control the inference environment.
* `--synchronize-chunks`: join work at callbacks for completed-chunk timing.

The probe checks that C is disabled inside inference callbacks, dynamic M is restored between
chunks, and all incoming flags are restored when each method returns. It resets its stream seed
to 42 before each full-model run and compares returned tokens across repetitions. Each repetition
gets fresh KV state and keeps the loaded full-model weights. The probe supplies a separate warm-up graph and stream to verify pipeline reuse across graphs;
the app reuses the workflow's graph and stream through its CodeAgent wrapper.

`prefill_seconds` includes setup/loading; `execution_seconds` measures the prefill loop.
`generation_seconds` includes decoding and is not a prefill benchmark. Compilation tracing and
synchronized callbacks add overhead. Use an idle GPU and identical options for timing comparisons.

For pipeline traces:

```sh
xcrun clang -O2 -dynamiclib -framework Foundation -framework Metal -framework MetalPerformanceShaders \
  Apps/LocalCode/Debug/MetalCompilationProbe.m -o /tmp/MetalCompilationProbe.dylib
QWEN_METAL_ENTRY_NONCE=unique_trial_identifier DYLD_INSERT_LIBRARIES=/tmp/MetalCompilationProbe.dylib \
  bazel-bin/Apps/LocalCode/PrefillWarmupProbe --model qwen3.6-27b \
  --model-path /path/to/qwen_3.8_27b_i4x_trailer.ckpt --prefill-tokens 17920
```

The nonce gives generated kernels fresh entry names; it does not clear system caches or affect
precompiled libraries. Set `METAL_PROBE_DUMP_DIR` to an existing directory to capture shader
sources, selected constants/stacks, and MPS NDArray shapes. The diagnostic is not linked into the
app. [PrefillPipelineMisses.md](PrefillPipelineMisses.md) records coverage and prior misses.

The measurements and commands below are historical, predating the parameterless API and the
always-dynamic-C policy. Removed probe options in those historical examples are not aliases.

## Optimized measurements (2026-09-07)

Measured on an M5 Max with 128 GiB RAM, using real `qwen_3.8_27b_i4x_trailer.ckpt`
and `deepseek_4_flash_0731_i2x.ckpt` checkpoints. All runs reported `swift_optimized=true`;
chunk length was 4,096, queue watermark was 128, ANE was disabled, and DeepSeek used
`--weights-streaming none`. Each cold/warm measurement used a separate process.

The Qwen filename denotes a mixed-quantization checkpoint: its metadata identifies layer 0's
MLP gate as Q4_K, its up/down projections as Q5_K, and layer 3's query projection as Q5_K.
The loader preserves these per-tensor formats; this is not a uniformly four-bit model.

Times below are the generator's prefill-loop durations. Warm-up covers 65,536 tokens and
is additional work completed before the measured full-model prefill.

| Model | Prompt tokens | Without warm-up | After warm-up | Warm-up cost |
| --- | ---: | ---: | ---: | ---: |
| DeepSeek V4 Flash i2x | 4,096 | 4.54 s (902 tok/s) | 4.96 s (825 tok/s) | 8.19 s |
| DeepSeek V4 Flash i2x | 16,384 | 30.46 s (538 tok/s) | 26.15 s (626 tok/s) | 10.71 s |
| Qwen 3.8 27B i4x | 4,096 | 6.25 s (655 tok/s) | 6.52 s (628 tok/s) | 22.66 s |
| Qwen 3.8 27B i4x | 16,384 | 28.45 s (576 tok/s) | 26.60 s (616 tok/s) | 20.34 s |

Qwen's first 4,096-token run without warm-up took 17.17 seconds. The table uses a later
fresh-process repeat: it reached 6.25 seconds even without in-process warm-up, showing that
filesystem or persistent shader-cache effects confound the first comparison. Warm-up setup
was 0.07 seconds for Qwen and 0.33–0.36 seconds for DeepSeek; lazy materialization may still
occur during the sweep or full prefill.

All paired first tokens matched (DeepSeek: 17 at 4K, 65 at 16K; Qwen: 248046 at 4K, 1 at 16K).
Full wall times at 16K were 32.42/28.10 seconds for DeepSeek and 28.82/26.96 seconds for
Qwen, without/with warm-up respectively, excluding the warm-up itself.

These initial comparisons showed no improvement at 4K and modest reductions at 16K;
they did not establish a repeatable speedup. Later measurements below reproduced Qwen's expected
throughput without changing its production execution path. Warm-up shifts work into idle time;
its first-ever-use benefit cannot be judged from these system-cache-warm comparisons.
Do not use the earlier unoptimized probe timings as performance evidence.

## Qwen throughput investigation

The same optimized generator, real checkpoint, 4,096-token chunks, queue watermark, and ANE setting
subsequently exceeded the 900–1,000 tok/s reference. No model or production loader fix was needed to
obtain the following results:

| Control | Execution time | Throughput |
| --- | ---: | ---: |
| Original timing implementation, fresh process, 4K | 3.84 s | 1,067 tok/s |
| Whole-file loader, three 4K prefills on one generator | 3.50–3.70 s | 1,108–1,169 tok/s |
| Previous `fread` loader, three 4K prefills | 3.39–3.67 s | 1,117–1,210 tok/s |
| Whole-file loader, eight consecutive 4K prefills | 3.42–3.98 s | 1,028–1,199 tok/s |
| After a 64K warm-up sweep, three 4K prefills | 3.89–4.21 s | 972–1,053 tok/s |
| Whole-file loader, two synchronized 16K prefills | 18.44 / 20.59 s | 889 / 796 tok/s |

The `fread` control added 2.49 seconds of first-run setup versus 0.14 seconds with whole-file
mapping. Its execution times overlap those of whole-file mapping, ruling out that recent loader
change as an explanation for the earlier large drop. The temporary loader change was reverted.
Running DeepSeek's large checkpoint immediately before Qwen also failed to reproduce the drop:
Qwen's three 4K prefills took 3.80, 3.66, and 3.79 seconds.

Context length does affect throughput. In the first synchronized 16K run, successive 4K chunks
took 3.41, 4.13, 4.99, and 5.89 seconds. Thus a short-prompt rate cannot be used as a constant
rate across longer contexts. Eight fixed-length repeats drifted modestly but remained above
1,000 tok/s; the system reported nominal thermal state. The 64K warm-up completed in 14.09 seconds
and did not reproduce the earlier 600 tok/s full-model rate.

All controls preserved the expected first tokens. The observed recovery also occurs with the
original timing implementation, so it is not an artifact of the added repeat/progress diagnostics.
Those repeat runs did not reproduce the original 600 tok/s readings. The controlled compiler-cache
experiment below subsequently reproduced this range and identified a missing warm-up path.
The original runs did not capture compilation timings, so their exact historical cache state
cannot be reconstructed. Compare against the reference's exact prompt length as well.

## Controlled cold-cache reproduction and MTP fix

`MetalCompilationProbe.m` is a standalone macOS diagnostic, not part of the app target. It times
Metal library and compute-pipeline creation inside the CLI process. With a new
`QWEN_METAL_ENTRY_NONCE`, it renames generated `kernel void` entry points and their corresponding
function lookups, preserving shader computations while assigning fresh compiler-cache identities.
It does not clear shared caches or affect another process. Precompiled libraries and other runtime
caches are unaffected, so this isolates generated MFA pipeline compilation rather than simulating
every aspect of a first-ever OS/app launch.

```sh
xcrun clang -O2 -dynamiclib -framework Foundation -framework Metal -framework MetalPerformanceShaders \
  Apps/LocalCode/Debug/MetalCompilationProbe.m -o /tmp/MetalCompilationProbe.dylib
QWEN_METAL_ENTRY_NONCE=unique_identifier_for_this_trial \
  DYLD_INSERT_LIBRARIES=/tmp/MetalCompilationProbe.dylib \
  bazel-bin/Apps/LocalCode/PrefillWarmupProbe --model qwen3.6-27b \
  --model-path /path/to/qwen_3.8_27b_i4x_trailer.ckpt \
  --disable-mfa-apple-neural-engine --warmup-tokens 4096 \
  --prefill-tokens 4096 --prefill-repeats 2
```

Use a distinct nonce for each cold comparison (letters, digits, underscores). Reusing a nonce
allows persistent shader-cache reuse. Timing kinds are 0 = library creation, 1 = pipeline from
function, and 2 = pipeline from descriptor. `metal_matmul_shape` records the NAX matmul's
M/N/K specialization constants.

For diagnostic shape/caller tracing, set `METAL_PROBE_DUMP_DIR` to an existing directory.
The probe writes generated Metal sources there and emits `metal_pipeline_detail` JSON for
copy, selected-expert dequantization, swish, sampling, and fence pipelines. For MPS identity
pipelines it also captures logical NDArray shapes using a runtime-guarded diagnostic hook.
This is never linked into the app. Do not use traced wall times for performance comparisons.

| Controlled case | First 4K prefill | Repeat | Compilation during first prefill |
| --- | ---: | ---: | ---: |
| Fresh entry points, no warm-up | 13.31 s | 3.35 s | 9.99 s |
| Fresh entry points, old 4K shallow warm-up | 6.13 s (668 tok/s) | 3.26 s | 2.70 s |
| Fresh entry points, old 64K shallow warm-up | 7.15 s | 3.88 s | 2.88 s |
| Fresh entry points, fixed 4K warm-up including real MTP | 3.47 s (1,179 tok/s) | 3.48 s | 0.053 s |

The missing work was MTP prefill specialization. Production prepends the initial hidden row,
making its first chunk 4,097 rows. The old warm-up only ran the main decoder. Two remaining
`int8_matmul` pipelines accounted for 2.33 seconds in the 6.13-second reproduction:

- `M=4097, N=5120, K=10240`: MTP's embedding/hidden projection (`mtp.fc`), 1.58 seconds.
- `M=4097, N=1024, K=5120`: the MTP attention K/V projection shape, 0.75 seconds.

The fix runs `Qwen3_5MTP` with production BF16 inputs and actual checkpoint codecs, including
the extra initial row and subsequent ordinary-size chunks. Strict loading prevents fallback to
initialized drafter weights. Cleanup still preserves the compiled pipelines. The expensive MTP
compilation now occurs during warm-up; only small sampling/helper pipelines remained cold in the
controlled first prefill. All first tokens matched their controls.

Validation after the fix: optimized probe and app builds, a complete 65,536-token MTP sweep and
16K full-model handoff, 2,048-token chunks with a one-token tail, cancellation at 4,096 tokens,
and a real non-MTP Qwen 4B checkpoint. The complete sweep with already populated system shader
caches took 16.44 seconds. Longer-context attention cost still applies independently of compilation.

## DeepSeek controlled cold-cache verification

The same fresh-entry-point experiment confirms that the existing four-layer DeepSeek warm-up
is useful for first use. These optimized runs used the real `deepseek_4_flash_0731_i2x.ckpt`,
4,096-token chunks, no expert streaming, queue watermark 128, and ANE disabled. Each process
used a distinct nonce; both full-model runs in each process produced first token 17.

| Controlled case | First 4K prefill | Repeat | Compilation during first prefill |
| --- | ---: | ---: | ---: |
| Fresh entry points, no warm-up | 20.43 s (201 tok/s) | 4.38 s (934 tok/s) | 13.26 s |
| Fresh entry points, four-layer 64K warm-up | 4.48 s (913 tok/s) | 4.65 s (881 tok/s) | 0.024 s |

The complete cold 64K warm-up took 25.58 seconds, including 20.94 seconds in Metal library
and pipeline creation. It also specialized sparse indexed attention at later prefill intervals,
so its compilation work exceeds that of a single cold 4K prompt. The subsequent full model
had only two small selected-row dequantization pipelines and their library left to create;
no additional DeepSeek warm-up implementation change was needed for this tested configuration.

Full wall time, including full-model setup, fell from 22.06 to 6.13 seconds, excluding the
preceding warm-up. Thus warm-up moves the first-use stall into idle startup time; it does not
reduce total elapsed time if the user waits for the entire sweep before submitting a prompt.
As with the Qwen experiment, fresh generated shader identities isolate compilation, without
simulating a completely cold filesystem or resetting all system caches. Other expert residency
policies and arbitrary prompt shapes may require additional pipelines.

### Does DeepSeek need the whole 64K sweep?

A follow-up compared a 4K warm-up with a 64K warm-up, each using fresh generated shader
identities, then prefilling the same 16K prompt with synchronized chunk boundaries. Other
settings matched the preceding experiment, and both first tokens were 65.

| Warm-up coverage | Warm-up time | Compilation during 16K prefill | 16K execution |
| --- | ---: | ---: | ---: |
| 4,096 tokens | 13.69 s | 2.047 s | 19.82 s |
| 65,536 tokens | 25.71 s | 0.026 s | 20.08 s |

After the 4K-only warm-up, compilation by full-model chunk was 0.025 seconds for 0–4K,
0.947 seconds for 4K–8K, 0.545 seconds for 8K–12K, and 0.530 seconds for 12K–16K.
The second chunk created attention/index-score kernels as well as sparse attention; the
next two created only a new sparse-attention pipeline. The full sweep removed all those
later-chunk creations. Total execution times overlapped despite this compilation reduction,
so these runs establish pipeline coverage, not an end-to-end 16K throughput improvement.

The compressed-attention builder shapes causal indices as
`[tokenLength, max(plan.totalRowCount, 1)]`. For ratio-128 compression, the index width grows
32, 64, 96, and so on at successive 4K boundaries. The Metal descriptor still specializes
on that width (`K`), even though dense/sparse KV row counts are supplied at runtime. Thus
warming only 4K cannot cover every later interval with the current kernels.

The first 4K therefore captures most of the cold-start benefit. Continuing to 64K is useful
for avoiding smaller compilation stalls in longer prompts, but adds about 12 seconds of
startup work in this cold-cache comparison. Keeping the remainder opportunistic and
cancellable is preferable to making a short prompt wait for the entire sweep.

## Dynamic-M tail validation

After adding the explicit tail passes, optimized probe and app builds passed. Both models
completed full 65,536-token sweeps, 2,048-token chunks with a one-token tail, cancellation after
4,096 tokens, and cancellation before weight loading. A real non-MTP Qwen 4B checkpoint also
passed warm-up and full-model handoff. Cold shader-identity trials with real Qwen 27B i4x and
DeepSeek i2x weights produced matching tokens across repeated 1,536-token full prefills.
Qwen reused its warmed dynamic-M GEMMs; DeepSeek retained a length-derived batched-stride
specialization, documented alongside attention/indexer/normalization follow-ups in
`DynamicMLengthSpecializations.md`.
