# GLM-5.3-Flash resident-slot allocations

`expertResidentSlotsForGLM5_3` in `GLM5_3TextGenerator.swift` sets the decode expert pool of
each sparse layer (3 through 44) per weights-streaming tier. They were fitted on 2026-11-07 for
`glm_5.3_flash_i2x_lgain_trailer.ckpt` (IQ2_XXS gate / up, Q2_K down).

## Budget

Every routed expert is 6.65625 MiB (gate, up, down and row scales) in every layer, so a tier's
budget is a slot count. The checkpoint stores every other text weight first, embedding first, and
the loader maps and pins (mlocks) that prefix whole: 9.79 GiB, of which attention and KDA take
5.84, the embedding 1.18, the FP16 head 1.18 and shared experts 0.99. The vision tower loads
separately, only with images. A tier's pool is the tier minus 9.79 GiB:

| Tier | Pool slots | Calibration hit | Held-out category | Uniform slots | Decode hit | Decode reads per token |
|---|---:|---:|---:|---:|---:|---:|
| 8 GiB | 336 (8 per layer) | 19.4% | 19.4% | 19.4% | 26.6% | 1,643 MiB |
| 16 GiB | 952 | 37.9% | 37.8% | 35.4% | 44.5% | 1,242 MiB |
| 24 GiB | 2,184 | 55.5% | 55.5% | 55.5% | 61.5% | 862 MiB |
| 32 GiB | 3,416 | 68.2% | 68.2% | 67.3% | 73.2% | 600 MiB |
| 40 GiB | 4,644 | 77.8% | 77.8% | 76.5% | 81.7% | 409 MiB |
| 48 GiB | 5,876 | 85.1% | 85.0% | 83.6% | 87.9% | 270 MiB |
| 56 GiB | 7,108 | 90.5% | 90.4% | 89.7% | 92.5% | 168 MiB |
| 64 GiB | 8,336 | 94.4% | 94.4% | 93.6% | 95.9% | 93 MiB |
| 72 GiB | 9,568 | 97.2% | 97.2% | 96.4% | 98.1% | 43 MiB |

The 8 GiB tier cannot hold even the other text weights, so it keeps only the routing width, 8
slots per layer, and claims 11.97 GiB. The 72 GiB tier loads every weight, as DeepSeek V4's
does, and claims the whole 89.47 GiB checkpoint, so it is picked only where that fits; its row
above is the fit, which no tier uses (it decoded only 1.4 to 2.4 tok/s faster than the 64 GiB plan
with the checkpoint cached). No streaming tier keeps a layer fully resident. A full layer would also pin every layer stored before it, since the banks
follow in layer order.

## Method

The corpus is ds4's imatrix calibration set (`gguf-tools/imatrix/dataset`, 4,690 records)
rendered with the GLM 5.3 template (`render_glm53_flash.py`): 2.52M tokens. Every record
appears twice, as think and nothink with the same text, so only the think records count, and
system spans (mostly repeated tool schemas, never decoded) are skipped: 912K tokens, 77% of them
source-code prompts. Each prompt prefilled from empty state with a routing output added to
`GLM5_3CausalLM`, which records every token's 8 experts in every sparse layer.

The kept tokens run through one pool per layer in corpus order, as one long session, and the
first 1,000 only warm it. The simulator replays ccv's policy exactly
(`MoEWeightsStreamingKernel.cpp`). A miss evicts the oldest slot not reused since it loaded,
then the oldest reused slot, never one the token uses. At most 90% of the pool counts as reused.
Pool sizes 8 through 284 in steps of 4, plus 288, per layer. Because experts cost the same, a
dynamic program over layers then minimizes total misses for each slot budget exactly.

Stickiness, on average over layers: a token shares 1.51 of its 8 experts with the previous token
on the corpus (0.22 by chance), and 2.12 in decoded text. Layers 3 to 6 are the least sticky
(0.5 to 0.6), so they get fewer slots than the others at 16 GiB and more from 32 GiB up.

## Validation

- Leaving one category out, refitting on the others and scoring it changes the hit rate by at most
  0.1 points.
- Decode: 60 prompts stratified over categories, each sampled for up to 1,024 tokens at T=1 with
  min-p 0.01, as thinking decodes (35,285 tokens). The calibration plans score 1 to 7 points
  higher there than on the corpus (more at small tiers), and within 0.9 points of plans refitted
  on the decode trace.
- Policy: ccv's policy beats plain LRU by 0.1 to 2.7 points, and the dynamic pool beats pinning
  each layer's most frequent experts (fitted in sample) by about 10 points at every size.
- Runtime, measured with plans fitted before the embedding counted (181 more slots per tier; the
  hit rates above moved 0.3 to 3 points) (`GLM5_3Generate --expert-resident-slots`, AIME case,
  1,024 tokens): fully resident
  65.6 tok/s; streaming at 72 / 64 / 56 / 48 / 32 / 16 GiB 48.8-49.8 / 47.4 / 44.3 / 39.6 / 33.0
  / 27.7 tok/s, and after a 20K prompt 49.4 / 48.0 / 45.1 / 40.5 / - / 28.4. The
  checkpoint was in the page cache (256 GiB machine), so expert loads did not read the SSD and
  these are upper bounds. Every streaming plan produces the same text, which leaves the fused
  path after 446 characters because the shared expert runs unfused.

Streaming loads every expert a prefill chunk touches, so a 269-token prefill drops from
1,012 to about 100 tok/s at every tier.
