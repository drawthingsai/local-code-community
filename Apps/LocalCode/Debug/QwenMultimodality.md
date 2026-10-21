# Qwen multimodality integration

Mirrors the Qwen-side image input, persistence, and replay behavior of `5ec2c48c39f3e3d5434eba45f70ab0d8a2388ccb`, with Qwen-specific chunked prefill and rotary positioning. View, typed tool content, and cross-model/remote media conversion are outside this change.

## Design

- Reuse `EmbedSpan`, `EmbedsFileStore`, and media-aware prefix hashing. Original encoded files are copied into CAS; history retains logical image-pad tokens and digest spans.
- Target and MTP always receive `[preTokens, injected, postTokens]`. The same embedding layer handles both text inputs. Empty inputs use `.NHWC`, shape `[0]`.
- Preserve ordinary chunk/checkpoint endpoints, subdividing before a second image when necessary, including MTP's shifted input. Images may cross checkpoints.
- Build rotary tensors once per image during prefill and copy each overlapping slice into the chunk's overall rotary tensor. Only the scalar `ropeDelta` survives in cache checkpoints and suspension state. No new `ProjectHistoryNode` field is needed.
- Decode image orientation, then reuse Qwen's existing smart resize and `ccv_resample` preprocessing. Load the vision tower lazily from the main checkpoint.
- Carry image spans through direct input, history restoration, temporary sessions, suspension, compaction, and CLI resume. Existing text tool results are unchanged.
- `ask` silently skips image paths that cannot be inserted or loaded, continuing with the text and remaining valid images. If a persisted image or vision weights cannot be loaded during replay, decode terminates quietly before changing the next chunk’s caches; there is no image-failure flag or special retry suspension.

## Additional adaptation found during validation

Qwen's causal convolution requires an explicit `Hint(stride: [1, 1])`. Automatic convolution hint inference can infer a larger stride for tiny chunks. A model initially executed with a long chunk can hide this because subsequent model absorption retains that hint. The regression starts with a four-token mixed chunk and crosses two injected regions with two- and three-token chunks, comparing logits and recurrent state against full prefill.

No ccv memory-arena or graph-absorption patch was necessary.

## Validation

Passing Bazel targets:

```sh
bazel test -c opt --features=swift.enable_testing \
  //Libraries/SwiftLLM:Qwen3_5TextGenerationTests \
  //Apps/LocalCode:Qwen3_5MultimodalTests \
  //Apps/LocalCode:DeepSeek4TranscriptTests \
  //Apps/LocalCode:FileToolsTests \
  //Libraries/ProjectHistoryManager:ProjectHistoryManagerTests
bazel build -c opt --features=swift.enable_testing \
  //Apps/LocalCode:LocalCodeCLI //Apps:Qwen3_5Converter \
  //Apps/LocalCode:AgentSchedulerHarness
bazel build -c opt --features=swift.enable_testing \
  //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

Tests cover target/MTP input composition, tiny-chunk recurrent parity, rectangular-image M-RoPE parity including mid-image restoration, cache tensors and scalar offsets, media identity in hashing, compaction, extensionless CAS decoding, missing vision weights, suspension, and silent skipping of missing/malformed images in both Qwen and DeepSeek `ask` paths.

Local Qwen 3.8 27B i4x inference with MTP and a synthetic red/blue image verified direct images, replay, two images in one turn, and restoration inside either image. Normal execution used `--chunked-prefill-max-length 257 --disable-mfa-apple-neural-engine`; the two-image runs answered with the correct colors. Separate target-only runs also completed correctly.

After removing View and the typed-content/transcript-conversion work, all five suites were rerun. A fresh two-image CLI turn answered "Red, blue" and its resumed turn answered "Blue", retaining both digest spans.

A follow-up checkpoint beyond both images resumed with the CAS image temporarily unavailable and still answered correctly, confirming that fully cached image prefixes do not require image decoding.

### Shader-validation limitation

With `MTL_SHADER_VALIDATION=1`, the full-model two-image restore produced incorrect output and invalid cached state without reporting a shader violation. Repeating the same restore under normal execution, from the same valid earlier checkpoint, completed correctly. This instrumentation-specific discrepancy remains unresolved; shader validation is not claimed as passing. Use a separate disposable context cache for instrumentation runs.
