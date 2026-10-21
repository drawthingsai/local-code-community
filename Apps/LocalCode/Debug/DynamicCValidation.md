# Dynamic M/C validation (2026-09-07)

The tested kernel implementation is ccv `1e671f5e`. The later `88a8224e` commit adds Git LFS
tracking for precompiled blobs and does not change the tested kernels. Tests use optimized
builds on an M5 Max with 128 GiB, real Qwen 3.8 27B i4x and DeepSeek V4 Flash i2x checkpoints,
4,096-token chunks, queue watermark 128, ANE disabled, and fully resident DeepSeek weights.
The final app build also picks up ongoing local precompiled-attention/GEMM blob updates in ccv;
the timing and original numerical experiments used the saved `1e671f5e` binaries.

**Current policy:** C specialization is unconditionally disabled throughout both `decode`
methods, with incoming flags restored by `defer`. Full prefill chunks still specialize M;
partial chunks use dynamic M. `warmupPrefill(graph:)` uses fixed short representative lengths;
each CodeAgent configures and synchronizes warm-up on the supplied graph and stream. The C opt-in and 64K warm-up default have been removed at the user's
request. The timing comparisons below are historical; this policy change is not a new claim of
measured throughput parity.

**Latest completeness update:** the parameterless API and fixed schedules pass optimized
real-weight checks with ccv `9638fc38`, including the multiplication fix. The original five
misses are addressed. An intermittent redundant specialized-M `cmul` pipeline remains because
unused stride slots can contain uninitialized values in ccv's cache key. See point 6 in
[PrefillPipelineMisses.md](PrefillPipelineMisses.md) for evidence and the proposed ccv fix.
The numerical/timing experiments below predate these changes unless stated otherwise.

## Local dependency wiring

`Dependencies/s4nnc` is a repo-local checkout of the app's pinned `b80bfc82d`, with
`DynamicGraph.EnableBits.disableAttentionSpecializingC` exposed and included in `allCases`.
Both are necessary: the Swift flag setter iterates `allCases`, so constructing an unknown
raw option bit silently fails to enable the corresponding C flag.

The ignored `.bazelrc.local` overrides `s4nnc` to this checkout and `ccv` to
`/Users/liu/workspace/ccv`. Dependency pins in `WORKSPACE` and SwiftPM are unchanged; publishing
this integration requires publishing/updating those dependencies through the normal workflow.

## Correctness

34 focused optimized ccv tests passed with both dynamic flags enabled (`0x380`, including ANE
disabled): attention sinks, causal/masked attention, rectangular/odd NA attention, quantized
attention with non-tile-multiple KV lengths, sparse indexed attention, index score/top-K,
RMSNorm, and interleaved batched int8 matmul. Logs are `/tmp/dynamic-c-numeric-{0..6}.log`
and `/tmp/dynamic-c-interleaved-tests.log`. This is a focused selection, not the full ccv suite.

Repeated real-model 17,920-token prefills produced matching first tokens with C specialization
enabled and disabled: Qwen `248046`, DeepSeek `1238`. Token agreement supplements the numerical
tests; it does not establish bitwise equality of every intermediate tensor.

## Compilation coverage

These measurements use `MetalCompilationProbe.m` and fresh generated shader entry names.
Counts identify cache coverage; measured compiler time can still vary with concurrent work.

* Qwen: 8,192-token warm-up plus fresh dynamic-M tails of 7, 512, and 4,095 left **zero** new
  attention, matmul, or normalization pipelines during the following 17,920-token prefill,
  including its unseen 1,536-token tail. Only argmax/fence helpers remained (0.065 s including
  their library creation). Log: `/tmp/qwen-dynamic-c-enabled-shortwarm.log`.
* DeepSeek: even a 4,096-token warm-up removed the recurring sparse-attention compilations
  as compressed index width grew. The old dynamic-M int8 stride and normalization leaks also
  disappeared. Remaining misses were bounded indexer tile variants: one at the second full
  chunk, and one at the long-context dynamic-M tail. Log: `/tmp/ds4-dynamic-c-shortwarm.log`.
* DeepSeek control with C specialization retained: after an 8,192-token warm-up, sparse
  attention still compiled at 12K, 16K, and the final partial chunk (about 0.60–0.72 s each).
  Log: `/tmp/ds4-dynamic-c-off-control.log`.

The initial `/tmp/qwen-dynamic-c-shortwarm.log` used the old Swift raw-option workaround and
actually had C specialization enabled. It must not be treated as a dynamic-C measurement.
The subsequent confirmed experiments used the C API directly and checked the actual flag bit.

The proper local Swift wrapper subsequently completed instrumented 64K sweeps for both models.
Between 8K and 64K there were no new attention, indexer, GEMM, or normalization pipelines. DeepSeek
created only its terminal argmax/fence helpers at the last chunk. Both models then passed repeated
1,536-token prefills followed by decoding, checking original flag restoration at every callback.
Qwen reached EOS after `[7, 488, 1, 248046]`; DeepSeek returned
`[7, 8, 9, 10, 11, 200, 12, 13]`. Logs: `/tmp/{qwen,ds4}-dynamic-c-scoped64.log`.

## Remaining length-dependent choices

The original handoff in `DynamicMLengthSpecializations.md` describes the older dependency.
Its major attention, indexer, matmul-stride, and normalization issues are addressed in the
tested local ccv implementation. The deeper audit in `PrefillPipelineMisses.md` found additional
weighted-swish and MPS multiplication gaps. Dynamic dimensions also still permit a bounded set
of length-dependent algorithm choices:

* `ccv_nnc_mfa_scaled_dot_product_arg_partition.cpp:19`: index score selects 4 SIMD groups
  for `T >= 1024, C <= 1024`, and 2 for `T >= 1024, C > 1024`. Ratio-4 compression crosses
  this boundary after the first 4K chunk. A fresh-cache dynamic-M tail cannot cover the latter.
* `NAAttentionDescriptor.cpp`: tile dimensions, R/C remainder handling, `checkCEdge1`, and
  split-KV strategy remain part of the pipeline key. `NAInt8AttentionDescriptor.cpp` similarly
  retains its kernel descriptor and row remainder category. Runtime lengths must not erase
  distinctions that change generated code or launch configuration.
* R=1 attention already loads C dynamically on its existing path, with separate direct and
  split-KV strategies. Enabling the new flag globally is not required for that behavior.
* `GEMMDescriptor.cpp`, `NAMatMulDescriptor.cpp`, and `NAInt8MatMulDescriptor.cpp` retain the
  `M < 4096` versus `M >= 4096` strategy category, in addition to the small-M dispatch paths.
  This is why representative tails, including Qwen MTP's extra row, remain necessary.
* Separate source-inspected fallback case: generic `GEMMDescriptor.cpp:14,35` only coarsens M
  when A is not transposed. A transposed-A generic GEMM still keys on exact M even with `loadM`.
  This was not an observed miss in the tested M5 model paths and is not covered by the 64K result.

An 8K sweep plus selected fresh and cached tails is the candidate replacement for a 64K sweep.
It must be validated against the actual strategy variants; runtime M/C does not imply a single
universal pipeline for all shapes, cache offsets, residency policies, or quantization formats.

## Timing noise

An uninstrumented A/B/B/A experiment uses the same optimized executable, real weights, 8K
warm-up, 8K full prefills, and three repetitions per process. The first repetition is excluded
from steady-state comparisons. Actual startup flag bits and first-token agreement are checked.

This run encountered substantial drift: DeepSeek's C-specialized control went from 11–12 s
to 16 s. A separate `/tmp/compile-dynamic-metals.py` process was concurrently running multiple
Metal compilers. Therefore these observations do not establish a runtime regression or parity.
Raw observations are saved in `/tmp/dynamic-c-abba.json` and the corresponding per-trial logs.
Compilation coverage and numerical correctness remain useful independently of this noisy timing.

| 8K prefill, repetitions 2–3 across two processes per mode | Specialized C median (range) | Runtime C median (range) |
| --- | ---: | ---: |
| Qwen 27B i4x | 17.276 s (17.216–17.480) | 17.823 s (17.456–18.028) |
| DeepSeek i2x | 14.164 s (11.365–16.478) | 15.726 s (13.507–21.890) |

Qwen's approximately 3.2% difference could be an execution cost; it is not established as either
a regression or noise. DeepSeek's drift prevents a useful estimate. After the Metal compiler
job ended, another attempt encountered an Xcode build: the specialized-C DeepSeek control reached
19.884–29.432 s. That attempt was stopped rather than collecting more contaminated comparisons
(`/tmp/dynamic-c-quiet-abba-ds4-0.log`). No thermal warning was reported by `pmset -g therm`;
that does not prove constant GPU clocks or absence of other GPU work.

## Integration and reproduction

The optimized probe and full app build passed together:

```sh
bazel build -c opt //Apps/LocalCode:PrefillWarmupProbe //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

The final warm-up adds one cached DeepSeek tail before its fresh-cache tails, reusing the real
4-layer KV state. This specifically covers `T >= 1024, C > 1024` with dynamic M. Progress and
cancellation still refer to the main sweep; tail work does not extend the reported sweep count.

The final 8K DeepSeek warm-up, including that cached tail, was followed by a 17,920-token
full-model prefill with an unseen 1,536-token final chunk. **No new attention, indexer, matmul,
or normalization pipelines were created.** Remaining creations were selected-row dequantization,
copy/identity, and swish helpers, totaling 0.116 s of measured compilation calls. Extending the
full-chunk sweep does not cover these remaining variants. Their exact causes and proposed fixes
are in `PrefillPipelineMisses.md`; their small cost is not a reason to leave the coverage incomplete.
Log: `/tmp/ds4-dynamic-c-final-disabled.log` (`disabled` means
C specialization is disabled, so runtime C is enabled).

The matching C-specialized control produced the same eight generated DeepSeek tokens:
`[1238, 73, 21004, 7355, 32157, 476, 71163, 370]`. Both checked that the original execution flags
were restored at every prefill/decode callback. The final probe prints `prefill_dynamic_c`
separately from `execution_flags`: the C flag is scoped inside prefill, so it is deliberately
absent from the startup/global flag value in this comparison.

For an execution-cost comparison, use the same command with `enabled` and `disabled`, in
A/B/B/A order. Run without `DYLD_INSERT_LIBRARIES`, retain weights across repetitions, discard
the first repetition, and ensure no other build or GPU job starts during the measurements:

```sh
bazel-bin/Apps/LocalCode/PrefillWarmupProbe --model deepseek-v4-flash \
  --model-path /Users/liu/Documents/Models/deepseek_4_flash_0731_i2x.ckpt \
  --weights-streaming none --disable-mfa-apple-neural-engine --synchronize-chunks \
  --warmup-tokens 0 --prefill-tokens 8192 --prefill-repeats 4 \
  --attention-specializing-c disabled
```

Use `--warmup-tokens 8192 --prefill-tokens 17920` to exercise short warm-up coverage, and
`--decode-tokens 8` to check the transition to decoding. The latter reports total generation
time and is a correctness check, not a comparable prefill throughput measurement.
