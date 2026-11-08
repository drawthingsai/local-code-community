# DeepSeek 4.1 Flash resident-slot allocations

`expertResidentSlotsForDeepSeek4_1` in `DeepSeek4_1TextGenerator.swift` sets the decode expert
pool of each of the 40 layers per weights-streaming tier. They were fitted on 2026-11-07 for
`deepseek_4.1_flash_1017_i2x.ckpt` (built as
`deepseek_4.1_flash_1017_i2xxs_w2q2k_sweep172gb_lgain_ds4_trailer.ckpt`, 172,970,156,032 bytes).
The previous tables were fitted for the 0910 checkpoint and are replaced.

## Budget

The checkpoint stores every text weight but the routed banks first, embedding first, and the
loader maps and pins (mlocks) that prefix whole: 9,809,818,048 bytes (9.14 GiB). The routed banks
follow in layer order. A routed expert (gate, up, down and scales) takes 9.35 MiB in most layers
and 10.58, 11.11 or 12.34 MiB in the layers with larger formats, so the budget is bytes. A
tier's pool is the tier minus 9.14 GiB; 8 GiB shares the 16 GiB pool, as before.

| Tier | Pool | Slots | Calibration hit | Held-out category | Uniform pools | Decode hit | Decode reads per token |
|---|---:|---:|---:|---:|---:|---:|---:|
| 16 GiB | 6.86 GiB | 700 | 51.6% | 51.6% | 50.9% | 55.2% | 1,079 MiB |
| 24 GiB | 14.86 GiB | 1,520 | 68.6% | 68.6% | 67.9% | 70.0% | 722 MiB |
| 32 GiB | 22.86 GiB | 2,344 | 78.3% | 78.2% | 77.7% | 78.8% | 513 MiB |
| 40 GiB | 30.86 GiB | 3,164 | 84.5% | 84.4% | 83.8% | 84.5% | 374 MiB |
| 48 GiB | 38.86 GiB | 3,980 | 88.7% | 88.6% | 88.0% | 88.4% | 279 MiB |
| 56 GiB | 46.86 GiB | 4,800 | 91.6% | 91.5% | 91.0% | 91.4% | 208 MiB |
| 64 GiB | 54.86 GiB | 5,624 | 93.7% | 93.6% | 93.2% | 93.6% | 156 MiB |
| 72 GiB | 62.86 GiB | 6,436 | 95.2% | 95.2% | 94.8% | 95.2% | 117 MiB |

No tier keeps a layer fully resident. A full layer would also pin every layer stored before it,
since the loader maps the file up to the last tensor it loads whole.

The previous tables assumed 9.35 MiB for every expert. Priced with this checkpoint's sizes they
take more than their tier at every size, which is where their slightly higher hit rates come from:

| Tier | Previous pool | Previous calibration hit | Previous decode hit | New pool | New decode hit |
|---|---:|---:|---:|---:|---:|
| 16 GiB | 7.40 GiB | 53.1% | 56.4% | 6.86 GiB | 55.2% |
| 24 GiB | 15.94 GiB | 70.1% | 71.4% | 14.86 GiB | 70.0% |
| 32 GiB | 24.44 GiB | 79.5% | 80.0% | 22.86 GiB | 78.8% |
| 40 GiB | 33.01 GiB | 85.5% | 85.7% | 30.86 GiB | 84.5% |
| 48 GiB | 41.54 GiB | 89.5% | 89.6% | 38.86 GiB | 88.4% |
| 56 GiB | 50.11 GiB | 92.3% | 92.4% | 46.86 GiB | 91.4% |
| 64 GiB | 58.62 GiB | 94.3% | 94.3% | 54.86 GiB | 93.6% |
| 72 GiB | 66.56 GiB | 94.8% | 94.9% | 62.86 GiB | 95.2% |

## Method

As for GLM-5.3 (`GLM5_3ResidentSlots.md`). The corpus is ds4's imatrix calibration set rendered
for V4.1 (`gguf-tools/imatrix/dataset/rendered_prompts_deepseek41_flash.txt`). Only the 2,345
think records were traced (each record also appears as nothink with the same text): 1.44M tokens,
prefilled from empty state through `DeepSeek4_1TextGenerator` with bounded replay off, so every
layer routes every token, with the routing outputs of `DeepSeek4_1CausalLM(outputRouting:)`.
System spans, mostly repeated tool schemas that are never decoded, are skipped: 911K tokens run
through one pool per layer in corpus order, the first 1,000 only warming it.

The simulator replays ccv's pool policy (`MoEWeightsStreamingKernel.cpp`) for pools of 8 to 380
experts in steps of 4, plus 384. Slots go, from the smallest pools, to the step that saves the
most misses per byte and still fits, so the larger experts get fewer slots where they save less.

A token shares 1.64 of its 6 experts with the previous one on the corpus and 1.92 in decoding,
against 0.09 by chance.

## Validation

- Leaving one category out, refitting on the others and scoring it changes the hit rate by at most
  0.1 points.
- Decode: the same 60 prompts as GLM-5.3, each sampled for up to 1,024 tokens with thinking at T=1
  and min-p 0.01 (40,891 tokens; the agent records end with a finished turn and decode nothing).
  The plans score within 0.25 points of plans refitted on the decode trace.
