# Remaining length specialization with dynamic M enabled

**Historical handoff:** see [DynamicCValidation.md](DynamicCValidation.md) for validation against
`1e671f5e`, resolved major kernel issues, remaining tile/edge strategies, and benchmark noise.
[PrefillPipelineMisses.md](PrefillPipelineMisses.md) identifies additional reproduced routine
misses from a deeper audit of every remaining pipeline creation.

Handoff for the ccv kernel changes, 2026-09-07. Scope: the DeepSeek V4 Flash and Qwen 3.5/3.8
prefill paths, including Qwen MTP. No dependency kernels were changed by the warm-up work.

The Swift flag is `DynamicGraph.flags.insert(.disableMFAGEMMSpecializingM)`; the C flag is
`CCV_NNC_DISABLE_MFA_GEMM_SPECIALIZING_M`. Both generators set it for chunks shorter than
`chunkedPrefillMaxLength`. Full 4,096-token chunks retain specialized M.

The new warm-up keeps the context sweep and then runs fresh, disposable tails of 7, 512,
and `chunkedPrefillMaxLength - 1` tokens, reusing real loaded weights. Qwen also executes MTP
with its extra initial row. Tails are filtered to the requested warm-up length and valid
model/chunk limits. They run once, with cancellation checks, rather than repeating the 64K sweep.

## Source locations

All `lib/...` paths below are relative to the **ccv repository**. The exact dependency inspected
here is available at:

`/Users/liu/workspace/draw-things/bazel-draw-things/external/ccv`

This is Bazel-managed dependency source; make fixes in the ccv checkout and update the dependency
through the normal workflow. Line numbers below refer to the inspected version.

## Confirmed in dynamic-M prefill measurements

Measured on M5 Max, optimized build, ANE disabled, fully resident DeepSeek i2x and Qwen 27B i4x
real weights. Each cold trial used a fresh `QWEN_METAL_ENTRY_NONCE` with `MetalCompilationProbe.m`.
Warm-up covered 4K plus the new representative tails, followed by a previously unseen **1,536-token**
full-model prefill. The flag is enabled during that partial prefill. Both repeated outputs matched.
Fresh entry names isolate generated shader compilation; this is not a complete system-cache reset.

### 1. `int8_matmul` and `quantize_activation`: length-derived batched strides

**Observed in DeepSeek. Highest-priority GEMM leak.** One new `int8_matmul` took 0.589 s, plus
0.006 s for its activation quantizer, despite M being absent from the function constants.

Source:

- `lib/nnc/mfa/kernels/NAInt8MatMulDescriptor.cpp:25`: equality/hash still include batch strides,
  `packedABatchStride`, and `aScaleBatchStride` with `loadM=true`.
- Same file, lines 107–139: M is omitted, but constants 15/19/21 still encode A, A-scale,
  and packed-A batch strides. Both matmul and quantizer are created here.
- `lib/nnc/mfa/ccv_nnc_mfa_scaled_gemm.cpp`: construct and encode the corresponding descriptors
  and activation layouts. Preserve interleaved source/output layouts when making strides dynamic.

Diagnostic constants for the same `N=1024, K=4096` pipeline:

| Warm-up / prompt rows | M constant | Packed-A stride | A-scale stride | Leading A / C |
| ---: | --- | ---: | ---: | --- |
| 7 | absent | 28,672 | 7 | 32,768 / 8,192 |
| 512 | absent | 2,097,152 | 512 | 32,768 / 8,192 |
| 4,095 | absent | 16,773,120 | 4,095 | 32,768 / 8,192 |
| 1,536 | absent | 6,291,456 | 1,536 | 32,768 / 8,192 |

The latter row still requires a new pipeline because `stridePackedA=M*K` and `strideAScale=M`.
Also audit the analogous batch-stride constants in `GEMMDescriptor.cpp` and
`NAMatMulDescriptor.cpp`; these related paths were inspected, not separately reproduced here.

### 2. `normalization`: source/destination batch strides

**Observed in both models.** Qwen created seven normalization pipelines (~0.034 s pipeline
creation, with additional library compilation); DeepSeek created three (~0.019 s).

Source:

- `lib/nnc/cmd/norm/mps/ccv_nnc_rmsnorm_mps.m:148`: forwards `loadM`, but lines 152–153 set
  batch strides using `max(existingStride, channel_count * sequence_count)`.
- `lib/nnc/mfa/kernels/NormalizationDescriptor.cpp:6`: dynamic M removes `sequenceCount` from
  equality/hash, while `srcBatchStride` and `dstBatchStride` remain exact keys (lines 19–20, 40).
- `lib/nnc/mfa/kernels/NormalizationKernel.cpp:364`: both strides are emitted into shader source
  as constants. Sequence count is already read at runtime with `loadM` (line 402).

Remove the length dependence from unused strides for unbatched cases, or pass the necessary
strides at runtime for batched cases. Audit the shared LayerNorm caller as well.

### 3. `attention`: query rows and KV columns

**Observed in both models.** A new dense attention pipeline took 0.144 s for Qwen and 0.279 s
for DeepSeek at the unseen tail length.

Source:

- `lib/nnc/mfa/ccv_nnc_mfa_attention.cpp:425`: NA attention sets `loadC` only for unmasked,
  non-varlen cases with `R <= 4`; it does not derive this from the dynamic-M flag.
- `lib/nnc/mfa/kernels/NAAttentionDescriptor.cpp:7`: query rows R remain exact; KV columns C
  remain exact unless `loadC` is enabled. Function constants are set around lines 176–178.
- Related `AttentionDescriptor.cpp` (generic) and `NAInt8AttentionDescriptor.cpp` (int8 attention)
  also retain length dimensions. These variants are code-inspected follow-up cases, not separate
  measured backend comparisons.

Audit descriptor/hash keys, function constants, generated tile/edge handling, masks, and batch
strides together. The existing `loadC` path still distinguishes some tile/edge/split-KV variants;
removing a descriptor key alone does not make those variants interchangeable.

### 4. `sparse_indexed_attention`: query count T and index width K

**Observed in DeepSeek.** Two new pipelines totaled 0.981 s at the 1,536-token tail.

Source:

- `lib/nnc/mfa/ccv_nnc_mfa_sparse_indexed_attention.cpp:242`: NA and generic paths already set
  `loadRows=true`, so dense/sparse KV row counts themselves are runtime values.
- `lib/nnc/mfa/kernels/NASparseIndexedAttentionDescriptor.cpp:12`: T and K remain exact keys.
  Constants T and K are still set at lines 62 and 68. Check `SparseIndexedAttentionDescriptor.cpp`
  for the generic counterpart.
- App builder: `Libraries/SwiftLLM/Sources/Models/DeepSeek4.swift`, compressed-attention path,
  shapes causal indices as `[tokenLength, max(plan.totalRowCount, 1)]`.

For ratio-128 compression, K grows 32, 64, 96, ... at successive 4K context boundaries.
This is why a 4K warm-up leaves later full-chunk sparse-attention compilations even though M
stays 4,096. Handle runtime T/K and the index row stride; `loadRows` alone is insufficient.

### 5. `enumerate`: indexer shortcut lengths and offset

**Observed in DeepSeek.** A new pipeline took ~0.005 s at the unseen tail length.

Source:

- `lib/nnc/mfa/kernels/ScaledDotProductArgPartitionEnumerateDescriptor.cpp:8`: T, C, and
  `queryOffset` remain equality/hash keys; constants are set at lines 46–51.
- `lib/nnc/mfa/ccv_nnc_mfa_scaled_dot_product_arg_partition.cpp:49`: this is the indexer
  shortcut when C is at most `kth`, so short prompts may exercise it instead of score/top-k.

Make the query count, available compressed rows, and causal offset runtime inputs together.

## Additional length-dependent indexer family found in code

### 6. `index_score`, `topk_serial`, `topk_tile`, `topk_merge`

DeepSeek's 1,536-token measurement used `enumerate`, so it did not measure new score/top-k
compilations in the full model. These pipelines were exercised during longer warm-up passes.

- `lib/nnc/mfa/kernels/NAScaledDotProductArgPartitionDescriptor.cpp:11`: T remains an exact
  descriptor/hash key and is constant 0 (line 65), shared by all four pipeline creations.
- `ScaledDotProductArgPartitionDescriptor.cpp` has the same issue for the generic backend.
- `lib/nnc/mfa/ccv_nnc_mfa_scaled_dot_product_arg_partition.cpp:234`: both paths already use
  `loadC=true`; C and query offset are runtime inputs on those paths. Do not mistake them for
  the remaining T specialization. Tile selection can also change with T/C.

## Do not classify every first-prefill creation as a length bug

- Qwen's ordinary dynamic-M GEMMs were reused at 1,536 tokens, including MTP. No new
  `int8_matmul` appeared in its measured full-model prefill.
- `gated_delta` already omits sequence length with `loadM=true`; no new one appeared in this run.
- Small-M versus ordinary matmul dispatch, the 4,096-row size bucket, and FP16 versus BF16
  remain distinct intentionally. The new warm-up samples these; do not merge unrelated kernels.
- Argmax/fence helpers and selected-expert dequantization appeared in the full model but do
  not by themselves establish prompt-length specialization. Argmax's column count here is
  vocabulary size. Strided copies created during model setup precede the partial-chunk flag.
- MPSGraph fallback compilation and untested devices/residency policies are outside this inventory.

## Reproduction and verification

Build and injection commands are in `PrefillWarmupProbe.md`. Use `--warmup-tokens 4096
--prefill-tokens 1536 --prefill-repeats 2` to reproduce the dynamic-M tail handoff. For later
context, also test a partial tail after several full chunks and vary the final tail length.
Use unique shader nonces for cold timing comparisons; reuse a nonce only for inexpensive
descriptor/stride inspection. The diagnostic now prints matmul batch strides and leading dimensions.

Captured logs on this machine:

- `/tmp/qwen-dynamic-m-coverage.log`: cold Qwen trial.
- `/tmp/ds4-dynamic-m-coverage.log`: cold DeepSeek trial.
- `/tmp/ds4-dynamic-m-strides.log`: same DeepSeek nonce, additional stride instrumentation.

After kernel changes, verify output parity and reduced pipeline creation across several unseen
tail lengths, context offsets, and the small/ordinary dispatch boundaries. Check batch and mask
layouts before removing any stride/length cache key. Retain specialized full-chunk coverage
until production chooses to use dynamic M there too.
