# Prefill pipeline misses: causes and fixes

## Current API

`warmupPrefill(graph:) -> Bool` runs a fixed short schedule on temporary model/cache state.
Each CodeAgent accepts the workflow's graph/stream, configures the inference backend, and owns
the no-grad scope, stream join, and tensor collection.
`decode` unconditionally disables C specialization and restores the caller's flags in `defer`.
Full 4096/2048-token chunks still specialize M; only partial chunks enable dynamic M.
DeepSeek's production `decode` has no warm-up-specific loader, sampling branches, or state.
The only changes there are the C scope and the first-partial-input M scope. Warm-up compiles
shape placeholders, strictly loads remapped real weights, and invokes ordinary decode on the
shallow generator. Placeholder inputs are never executed.

The current schedules and probe commands are in [PrefillWarmupProbe.md](PrefillWarmupProbe.md).
The inventories and measurements below predate this API simplification unless stated otherwise.

## Parameterless API validation (ccv 9638fc38)

Optimized probe and full LocalCode app builds pass. Real Qwen 27B i4x with MTP and Qwen 4B
non-MTP prefill tests have zero new pipelines, with 4096 and 2048 chunk sizes respectively.
Qwen's repeated 1536-token prompt still returns `[7, 488, 1, 248046]`; DeepSeek's repeated
17920-token prompt still returns `[1238, 73, 21004, 7355, 32157, 476, 71163, 370]`.
C remains enabled as a *dynamic dimension* through decoding, and the incoming flags are
restored after every call. Full-chunk stochastic DeepSeek prefill also passed with no new
pipelines. The trace sees specialized GEMM M=4096 (and routed M=24576) as well as runtime M.

DeepSeek's final fixed schedule covers all three index-score tiles: T < 1024; T >= 1024 with
C <= 1024; and T >= 1024 with C > 1024. Here T is query token count and C is compressed KV
rows. The fresh 4095-token pass is necessary even with 2048-token chunks: 2047 fresh tokens
produce only 511 compressed rows, taking the enumeration shortcut instead of index scoring.
The large-cache partial pass is split into 512 and chunk-size-minus-513 queries, covering both
query-size tiles without increasing that cached pass's total token count.

All tested index-score, attention, GEMM, dequantization, copy, and sampling coverage gaps are
resolved. One intermittent redundant `cmul` creation remains with specialized M; see point 6.
The 2048 streamed / 3584 prompt, 4096 resident / 3584 prompt, and 4096 resident / 8704 prompt
runs had zero new prefill pipelines. A 17920 prompt created one `cmul` in one process and zero
in the detailed rerun. Do not call this reliably zero-creation until point 6 is fixed.

Logs/reports: `/tmp/prefill-simple-results.json` (includes the earlier missing indexer tile),
`/tmp/prefill-simple-tiles-results.json` (final schedule), `/tmp/prefill-simple-cmul-results.json`.
Final build: `/tmp/prefill-simple-tiles-build.log`. Timings are instrumented coverage checks,
not throughput benchmarks; nonce reuse in the last runs permits system compiler-cache hits.

The original inventory below was observed on M5 Max, optimized build, real Qwen 3.8 27B i4x and DeepSeek V4 Flash i2x weights,
runtime C enabled for prefill, specialized full 4K chunks and dynamic-M partial chunks.
The warm-up is 8K plus representative tails, including DeepSeek's cached tail. The subsequent
full-model prompt is 17,920 tokens, ending with a 1,536-token partial chunk. This inventory
counts pipeline creation, including redundant creation that hits Apple's compiler cache.

**All observed leftovers below are routine model paths or checkpoint layouts. None is an
unusual shape that should be dismissed solely on that basis.** The 0.116 s reported earlier
was a cost measurement, not a completeness criterion. The expensive recurring attention/GEMM
misses are resolved, but the warm-up is not yet free of all subsequent pipeline creation.

## App-side fixes (2026-09-07)

Points 1, 2, and 5 are implemented in the generators. Point 3 is supplied by ccv commit
`ec48ad13`; this task makes no ccv edits. Point 4 remains a ccv-side multiplication gap.

* DeepSeek reads each layer's three expert-bank codecs from store metadata, keeping coverage
  separate by projection and fully resident versus streamed execution. It starts with four
  representatives and replaces a redundant layer of the same attention/router kind, or adds a
  layer when necessary. With the tested fully resident i2x checkpoint, it selects 0, 1, 2, 37.
  All layer parameters are remapped to the real source layer; residency lookup uses the shallow
  model's index so streamed policies remain aligned with its remapped configuration.
* Dynamic M now surrounds the first partial chunk's token and rotary-copy preparation too.
  The prior flags are restored before model compilation and callbacks.
* Qwen warms actual terminal argmax and CPU transfer, including MTP selection and two-token
  readback. Non-MTP terminal prefill has its own builder sharing the loaded real parameters:
  changing the Swift context tuple alone does not rebuild a ModelBuilder for identical input
  shapes. Reusing the interior builder had returned hidden state in slot 0, bypassing the
  one-query terminal graph and selecting over hidden width instead of vocabulary width. The
  sampling helper now asserts `[1, vocabularySize]`. Both generators also warm min-p max/mask/gumbel operations for reasoning and
  stochastic answers; Qwen's draft path includes log-sum-exp. These run once per M mode.

Optimized probe and full LocalCode app builds passed. With ccv `ec48ad13`, an 8,192-token
runtime-C warm-up followed by a 17,920-token prefill (including its unseen 1,536-token tail)
produced these results:

| Model | New prefill pipelines after warm-up | Repeated generation |
| --- | --- | --- |
| DeepSeek V4 Flash i2x, fully resident | 2 `ndArrayIdentity` pipelines, both point 4 | Same eight tokens as the previous control |
| Qwen 3.8 27B i4x with MTP | 0 | Same first token, 248046 (EOS) |

Both runs repeated twice and checked flag restoration at prefill/decode callbacks. DeepSeek's
prefix was `[1238, 73, 21004, 7355, 32157, 476, 71163, 370]`. Logs are
`/tmp/prefill-app-fixes-{ds4,qwen}.log`; the compact report is
`/tmp/prefill-app-fixes-results.json`. These instrumented runs validate coverage, not throughput.

Additional regression checks passed:

* Streamed DeepSeek (8 GiB policy), C specialization enabled: 512-token warm-up and repeated
  512-token prefill plus eight decoded tokens; no new prefill pipelines. This checks real layer
  remapping/residency and flag restoration, not coverage at larger contexts.
* Non-MTP Qwen 3.5 4B i8x: corrected terminal builder, 2K chunks, 4K warm-up and repeated
  1,536-token prefill plus eight decoded tokens; zero new prefill pipelines and unchanged output.
* DeepSeek reasoning prefill at 1,536 tokens after 8K warm-up: only the two point-4 pipelines.
* Qwen 27B stochastic answer prefill at 1,536 tokens after 8K warm-up: zero new prefill pipelines.
* Final MTP Qwen 27B rerun after the terminal-builder correction: 8K warm-up followed by
  17,920-token prefill; zero new pipelines and the same EOS token.

Reports: `/tmp/prefill-app-fixes-edges-results.json` and `/tmp/prefill-terminal-fix-results.json`.
The first report includes the initial non-MTP diagnostic that exposed the terminal-builder issue;
its final corrected result is in the second report. Final optimized probe and app build log:
`/tmp/prefill-terminal-fix-build.log`.

The numbered sections below preserve the original captured shapes and causes for reference.

## 1. DeepSeek selected-expert dequantization: checkpoint coverage miss

Two descriptor variants each create `dequantize_8i_rowwise_x_selected` and
`dequantize_8i_rowwise_x_selected_plan` (four pipeline calls total).

| Missing variant | Expert bank shape `[experts, output, input]` | First occurrence |
| --- | --- | --- |
| Q2_K gate/up | `[256, 2048, 4096]` | Layers 37–42 |
| IQ3_XXS down | `[256, 4096, 2048]` | Layers 37–42 |

Both have 256 routing bins. The first four warmed layers cover IQ2_XS and IQ2_XXS gate/up
banks and Q2_K down banks. They do not cover Q2_K in the gate/up shape or IQ3_XXS down.
This was verified from captured shader sources/constants and the real checkpoint's metadata;
it is exactly why the actual quantized weights matter. Neither variant depends on prompt length.

Captured constants (indices per `Dequantize8iRowwiseXDescriptor.cpp:267`):

* Q2_K gate/up: row length 4096, group size 16, groups/row 256, rows/expert 2048,
  experts/bins 256, scale bytes/expert 8192.
* IQ3_XXS down: row length 2048, group size 8, groups/row 256, rows/expert 4096,
  experts/bins 256, scale bytes/expert 16384.

**Implemented in representative weight selection:** include these real expert banks. For this checkpoint,
layer 37 has the same compressed-128 attention and standard-router structure as layer 3, so
mapping the fourth representative layer to real layer 37 retains a four-layer warm-up. The
selection inspects actual expert codec metadata, with projection shapes fixed by the model
configuration, rather than assuming a fixed index always covers everything. This specifically
covers expert-bank formats; arbitrary format variation in other weights is outside that selector. Extending the first four layers to 64K cannot help.

Sources: `Apps/LocalCode/Sources/Models/DeepSeek4TextGenerator.swift:257,875`,
`Libraries/SwiftLLM/Sources/Models/DeepSeek4.swift:151`, and ccv
`lib/nnc/mfa/kernels/Dequantize8iRowwiseXDescriptor.cpp:165`.

## 2. DeepSeek compressor rotary copies: input-preparation flag scope miss

Three `strided_copy` pipelines, FP16 and vectorized by four, with runtime row count:

| Routine input copy | Rows at the tested tail | Columns | Source row stride | Destination row stride |
| --- | ---: | ---: | ---: | ---: |
| Ratio-4 attention compressor rotary | 384 | 512 | 2048 | 512 |
| Ratio-128 attention compressor rotary | 12 | 512 | 65536 | 512 |
| Ratio-4 indexer compressor rotary | 384 | 128 | 512 | 128 |

The later prefill chunk creates these copies inside the dynamic-M flag scope. During each
warm-up tail, however, `firstInputs = modelInputs(...)` runs **before** that scope and is reused
by the first chunk. Therefore the warm-up creates specialized-row copies, not the runtime-row
versions. Captured warm-up constants include element count at index 2; the missing pipelines
omit that constant and load it at runtime. Columns and row strides are the same normal layouts.

**Implemented in input preparation:** apply the partial-chunk M policy before constructing `firstInputs`
(and restore the incoming flags afterward), consistently for warm-up and real first-chunk
prefill. The existing 512/4095 tails can then cover these three variants. Keep fixed headroom
compilation and decoding flag ownership explicit; no additional 64K sweep or copy kernel is needed.

Sources: `Apps/LocalCode/Sources/Models/DeepSeek4TextGenerator.swift:615,823,930,938`,
ccv `lib/nnc/cmd/util/mps/ccv_nnc_util_mps.m:409`, and
`lib/nnc/mfa/kernels/StridedCopyDescriptor.cpp:7,57`.

## 3. DeepSeek weighted swish: redundant pipeline cache key

One `swish_mul` pipeline is recreated with **the same library and function constants** as
two calls during warm-up: clamp = 10, row width = 2048, and runtime element count.

`SegmentedSwiGLU` supplies `length = M*N`, `weightCount = M`, `weighted = true` and `loadM = true`.
The pipeline needs the fixed row width `N = 2048`; however `SwishMulDescriptor` still hashes
and compares both exact length and weight count for weighted operations. An unseen token count
therefore misses the application cache even though the resulting specialized Metal function is
identical. This is a real redundant creation, not an unusual tensor shape.

**Fix in ccv:** for weighted dynamic-M operations, key on the effective row width
`length / weightCount` instead of exact `length` and `weightCount`. Preserve precision,
vectorization, gradient/output-mask, clamp/scale, and other code-generating distinctions.
Update equality and hash together. Test different M with the same N for reuse, and different
N for separation and numerical correctness.

Sources: ccv `lib/nnc/mfa/kernels/SwishMulDescriptor.cpp:22,34,92` and
`lib/nnc/mfa/ccv_nnc_mfa_segmented_scaled_swiglu.cpp:92`.

## 4. DeepSeek MPS identity names: ordinary multiplication without a dynamic-M backend

Two `ndArrayIdentity` creations come from `CCV_NNC_MUL_FORWARD`, not the MFA strided-copy
path. Capturing the active MPS NDArray inputs/output and the full stack identifies:

| Model operation | Logical shapes, slowest dimension first |
| --- | --- |
| Embedding hyperconnection broadcast | `[1536,1,4096] * [1,4,1] -> [1536,4,4096]` |
| Ratio-4 indexer rolling-pool multiplication | `[384,128,8] * [384,128,8] -> [384,128,8]` |

All tensors are FP16. The latter is `weights .* paddedKV` before reduction; 384 is the
emitted row count for this 1536-token chunk, 128 is the indexer head dimension, and 8 is the
two-window ratio-4 pooling width. These are standard DeepSeek operations.

`_ccv_nnc_mul_forw` always uses MPSGraph for binary multiplication. That graph is keyed by
tensor shapes/layouts and does not consume the MFA dynamic-M flag. The internal Metal entry
name alone was insufficient to identify this; it does not mean these are merely copy helpers.

**Fix in ccv or the model operator:** provide a runtime-M multiply/broadcast path for these
ordinary layouts, or fuse them into an appropriate existing model operation. A narrowly scoped
MFA fast path can cover the embedding broadcast and contiguous pooling multiply while keeping
the general MPSGraph fallback. Verify both broadcast indexing and pooling numerical parity.
Warming more fixed tail lengths would only cover more framework variants, not solve this gap.

Sources: `Libraries/SwiftLLM/Sources/Models/DeepSeek4.swift:441,942`, ccv
`lib/nnc/cmd/blas/mps/ccv_nnc_mul_mps.m:18,61`.

## 5. Qwen sampling and transfer: terminal warm-up omission

Two argmax pipelines (`argmax_partition`, `argmax_merge_partitions`) use fixed vocabulary
width 248320, partition size 4096 and 61 partitions. Three fast-fence pipelines have no
function constants. Their stacks lead respectively to `Functional.argmax` and `.toCPU()`.

The shallow warm-up computes real logits but discards them, so it never exercises final token
selection and GPU-to-CPU transfer. Those are normal operations on every completed greedy prefill.

**Implemented in warm-up:** select a token from real terminal logits and transfer it to CPU once,
including the MTP sampling/transfer path when present. This covers these fixed variants without
extending the context sweep. The warm-ups now also execute the normal max/mask/gumbel/log-sum-exp helpers for
stochastic/reasoning paths. Those modes were not measured in the original greedy-prefill inventory.

Sources: `Apps/LocalCode/Sources/Models/Qwen3_5TextGenerator.swift:309,636,651,654,697`.

## Evidence and scope

* `/tmp/prefill-helper-details-ds4.log`, `/tmp/prefill-helper-details-qwen.log`: shader constants,
  source identifiers, and call stacks; both full prefills passed.
* `/tmp/prefill-ndarray-details.log`: exact MPS logical shapes and full caller stacks; passed.
* Generated sources: `/tmp/prefill-helper-sources-{ds4,qwen}/` and `/tmp/prefill-ndarray-sources/`.
* The diagnostic is `MetalCompilationProbe.m`, with `METAL_PROBE_DUMP_DIR` set to an existing
  directory. Shape tracing and stack capture add overhead; these runs are not throughput tests.

No ccv kernel fixes or the above representative-weight/sampling changes were made by this audit.
The already-added cached DeepSeek tail fixes the separate indexer tile miss. Remaining bounded
attention edge/split strategies and the unobserved generic transposed-A GEMM case are listed in
`DynamicCValidation.md`; they are distinct from these reproduced routine misses.

## 6. CMul unused stride metadata: intermittent redundant pipeline creation in ccv

This is a ccv-side cache-key correctness bug, not another prompt-length interval to warm.
In `lib/nnc/cmd/blas/mps/ccv_nnc_cmul_mps.m`, the broadcast path allocates local `astride`,
`bstride`, and `cstride` arrays without initialization. It fills entries only below the squeezed
rank `nd`, then unconditionally copies entries 1, 2, and 3 into the MFA parameters. At rank 3,
entry 3 is uninitialized; at rank 2, entries 2 and 3 are uninitialized. Similar code appears in
the backward paths. Dimension arrays also have unconditional reads before unused dimensions
are zeroed and should be initialized or copied only within bounds.

`CMulDescriptor` hashes/compares all three stride slots when `loadM == false`, even when its
`value` rank class means some of those slots never enter the shader. Stack contents can therefore
change the cache key without changing a function constant. With dynamic M the descriptor ignores
these strides, so this affects specialized full prefill chunks and decoding. Enabling dynamic M
for full chunks would only hide the bug and would violate the intended full-chunk policy.

Evidence: `/tmp/prefill-simple-tiles-4k-large-c.log` has one extra `cmul` in the first 4096-token
chunk. The detailed rerun `/tmp/prefill-simple-tiles-cmul-details.log` has no extra prefill call,
but its warm-up creates the same source/constants twice. Decoding creates the same head-512
source and constants 42 times. The repeated decode constants are `{0:256,1:64,2:512,3:0,4:512}`;
the repeated warm-up variant additionally has `{5:32768,6:512,7:32768}`. Neither shader uses the
unused stride slots being hashed. The diagnostic now captures `cmul` details too.

**Fix in ccv:** zero-initialize the local dimension/stride arrays or copy only initialized active
entries, consistently in forward/backward paths. Canonicalize unused descriptor fields, and key
only on fields used by the selected rank class, updating equality and hash together. Repeating
identical specialized-M broadcasts across fresh processes and during decoding should reuse a
single pipeline regardless of surrounding stack activity. No ccv edits were made by this task.
