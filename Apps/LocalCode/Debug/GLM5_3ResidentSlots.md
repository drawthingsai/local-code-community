# GLM-5.3-Flash resident-slot allocations

`expertResidentSlotsForGLM5_3` in `GLM5_3TextGenerator.swift` sets the decode expert pool of each
sparse layer (3 through 44) per weights-streaming tier. They were fitted on 2026-11-11 for
`glm_5.3_flash_i4x.ckpt` (IQ3_XXS gate / up, Q4_K down, Q8_0 head). They replace the 2026-11-07
fit for the 2-bit checkpoint, whose experts were 6.65625 MiB.

## Budget

Every routed expert is 11.53125 MiB (12,091,392 B: gate, up, down and row scales) in every layer,
so a tier's budget is a slot count. The checkpoint stores every other text weight first, embedding
first, and the loader maps and pins (mlocks) that prefix whole: 9,877,086,584 B (9.20 GiB). That
covers attention and KDA, the embedding, the Q8_0 head, the shared experts, the dense MLP, mHC,
routers and norms. The vision tower loads separately, only with images. A tier's pool is the tier
minus 9.20 GiB:

| Tier | Pool slots | Calibration hit | Held-out category | Uniform slots | Decode hit | Decode reads per token |
|---|---:|---:|---:|---:|---:|---:|
| 8 GiB | 336 (8 per layer) | 19.1% | 19.1% | 19.1% | 26.6% | 2,845 MiB |
| 16 GiB | 600 | 29.3% | 29.3% | 26.0% | 36.6% | 2,455 MiB |
| 24 GiB | 1,312 | 43.5% | 43.4% | 41.3% | 49.7% | 1,948 MiB |
| 32 GiB | 2,024 | 53.1% | 53.0% | 52.8% | 58.8% | 1,596 MiB |
| 40 GiB | 2,732 | 61.0% | 61.0% | 60.5% | 66.1% | 1,313 MiB |
| 48 GiB | 3,444 | 67.9% | 67.9% | 66.8% | 72.4% | 1,069 MiB |
| 56 GiB | 4,156 | 73.8% | 73.8% | 72.4% | 77.7% | 864 MiB |
| 64 GiB | 4,864 | 78.8% | 78.8% | 77.2% | 82.0% | 696 MiB |
| 72 GiB | 5,576 | 83.1% | 83.0% | 82.3% | 85.8% | 551 MiB |

- **8 GiB:** cannot hold even the other text weights, so it keeps only the routing width, 8 slots per layer, and claims 12.98 GiB.
- **72 GiB:** streams like the others. The whole checkpoint is 146.47 GiB, and only **Disabled** loads every weight.
- **Full layers:** no tier keeps a layer fully resident. A full layer would also pin every layer stored before it, since the banks follow in layer order.

The bigger experts give each tier 42% fewer slots than the 2-bit checkpoint had, so hit rates are lower at every tier: 82.0% against 95.9% decode hit at 64 GiB.

## Method

**Corpus.** ds4's imatrix calibration set (`gguf-tools/imatrix/dataset`, 4,690 records), rendered with the GLM 5.3 template (`render_glm53_flash.py`): 2.52M tokens.
- Every record appears twice, as think and nothink with the same text, so only the think records count.
- System spans (mostly repeated tool schemas, never decoded) are skipped.
- That leaves 912K tokens, 77% of them source-code prompts.

**Trace.** Each prompt prefills from empty state with this checkpoint, through `GLM5_3CausalLM` with a routing output added. The output records every token's 8 experts in every sparse layer.
- The routing depends on the quantization: on the same tokens, only 66% of the top-8 picks match the 2-bit checkpoint's trace. So the trace was redone, not reused.

**Simulation.** The kept tokens run through one pool per layer in corpus order, as one long session; the first 1,000 only warm it.
- The simulator replays ccv's policy exactly (`MoEWeightsStreamingKernel.cpp`).
- A miss evicts the oldest slot not reused since it loaded, then the oldest reused slot, never one the token uses. At most 90% of the pool counts as reused.
- Pool sizes run from 8 to 284 in steps of 4, plus 288, per layer.

**Allocation.** Because experts cost the same, a dynamic program over layers minimizes total misses for each slot budget exactly.

**Stickiness**, on average over layers: a token shares 1.48 of its 8 experts with the previous token on the corpus (0.22 by chance), and 2.12 in decoded text. Layers 3 to 6 are the least sticky (0.4 to 0.6), so they get the fewest slots at 16 and 24 GiB, and the most from 48 GiB up.

## Validation

- **Held-out categories:** leaving one category out, refitting on the others and scoring it changes the hit rate by at most 0.1 points.
- **Decode:** 60 prompts stratified over categories, each sampled for up to 1,024 tokens at T=1 with min-p 0.01, as thinking decodes (33,186 tokens).
  - The calibration plans score 2.7 to 7.5 points higher there than on the corpus, more at small tiers.
  - They are within 0.8 points of plans refitted on the decode trace.
- **Runtime:** `GLM5_3Generate --weights-streaming`, AIME case, 1,024 tokens, serial.
  - Fully resident: 58.8 tok/s.
  - Streaming at 72 / 64 / 56 / 48 / 40 / 32 / 24 / 16 / 8 GiB: 30.8 / 28.9 / 27.3 / 25.8 / 24.4 / 23.2 / 22.0 / 20.5 / 19.6 tok/s.
  - With the DFlash2 drafter at 64 GiB (4 rows a step under streaming): 33.1 tok/s, 2.68 tokens a step.
  - Every tier produces the same 1,024 tokens as the resident run.
  - The checkpoint was in the page cache (256 GiB machine), so expert loads did not read the SSD, and these are upper bounds.
- **Prefill:** streaming loads every expert a prefill chunk touches, so a 269-token prefill drops from 794 to about 52 tok/s at every tier.

The traces, simulator and fit are in `benchmark-results/glm5_3-streaming-i4x-20261111/`.
