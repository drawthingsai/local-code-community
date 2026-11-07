# Routed Expert Gain Correction (lgain)

- Status: Implemented as an offline checkpoint pass. Applied to DeepSeek 4.1 Flash 1017 (2026-10-24) and
  GLM-5.3-Flash (2026-11-07).
- Scope: low-bit routed-expert banks of s4nnc trailer checkpoints (IQ2_XXS or Q2_K gate and up, Q2_K or
  IQ3_XXS down)
- Last verified: 2026-11-07

## Context and decision

At about 2 bits per weight, our quantizer shrinks routed-expert projections in a consistent direction. The
least-squares gain of a quantized gate or up output against the FP32 output is about 0.89: 0.887 for
DeepSeek 4.1 1017 `i2xxs_w2q2k`, and 0.89–0.91 in every MoE layer of GLM-5.3 `i2x`. This shrinkage reaches the
residual stream through every routed expert.

We correct it with two scalars per MoE layer:
- `c_gu` multiplies every gate and every up row of the layer's routed experts;
- `c_d` multiplies every down row.

Both are fitted against an FP32 reference on calibration rows that are never used for evaluation. They are
baked into the FP32 row scales of a copy of the checkpoint, so the runtime, the tensor format and the codes are
unchanged. Baked files carry an `_lgain` tag before the trailer suffix, for example
`glm_5.3_flash_i2x_lgain_trailer.ckpt` and `deepseek_4.1_flash_1017_i2xxs_w2q2k_lgain_ds4_trailer.ckpt`.

## Why per-layer gains fitted per stage

The shape of the correction comes from DeepSeek 4.1 1017 experiments. Model KLD was measured on Wiki10k dev
rows 0:2048 with only the routed experts swapped, against 0.4629 for the stored checkpoint.

| correction | KLD | finding |
| --- | ---: | --- |
| per-row weight-space gain `‖W‖² / ⟨Wq, W⟩` on all projections (≈ ×1.13 gate/up, ×1.09 down) | 0.4701 | worse |
| constants ×1.13 gate/up and ×1.09 down together | 0.4688 | worse |
| gate/up ×1.12 only | 0.3963 | better |
| down ×1.09 only | 0.4217 | better |
| derived per-layer `c_gu` + `c_d` (this document) | 0.3898 | best |
| derived per-row gains, cross-validated shrinkage | 0.3937 | no better than per-layer (+0.0038 ± 0.0047) |

The findings that shaped the procedure:
- **Each half helps alone, but stacking overshoots.** Down's apparent shrinkage mostly compensates for gate and
  up shrinkage upstream, so correcting both against the weights counts it twice. Each stage is therefore fitted
  against its own FP32 reference: gate/up against the reference hidden, and down with the reference hidden as
  its input.
- **SwiGLU compounds the shrinkage.** The hidden `silu(g)·u` is shrunk through both factors, so the gain that
  minimizes hidden error sits above the linear least-squares gain (about 1.03) and below a full undo (about 1.13).
  It is found by search on the hidden error, not computed in closed form.
- **Per-layer is the granularity.** Per-row gains reduced cross-validated fit error by only 0–10% and did not
  move model KLD.
- **Fitting on separate rows loses nothing.** The per-layer gains derived only from fit rows (0.3898) matched a
  schedule tuned on the dev rows themselves (0.3873).

## Data protocol

These rules are what make the reported numbers trustworthy. Do not relax them for a new checkpoint.

- **Corpus.** Wiki10k is one continuous 10,000-token context of stratified WikiText-2 validation excerpts. The
  source text is `independent-wikitext2-stratified-10000.source-text.txt` from the DeepSeek 1017 Wiki10k
  preparation. Each model uses its own tokenizer and document start: DeepSeek uses explicit BOS id 0; GLM uses
  `[gMASK]<sop>`, then the first 9,998 text tokens.
- **Rows 0:2048 are the development set.** They are scored once per final candidate, never searched over.
- **Rows 2048:10000 are the fit set.** Gains are derived only from these rows.
- **Fix the procedure before scoring.** Grid, granularity and formulas are fixed before any dev statistic
  exists. Choices such as granularity or shrinkage are settled by cross-validation inside the fit rows.
- **Derive per checkpoint.** Gains depend on the codes and the format of each bank, so every checkpoint gets its
  own. A mix checkpoint that copies tensors byte for byte from two sources may reuse each source's per-layer
  gains, as long as a layer's gate and up come from the same source.
- **Keep the hold-out untouched.** The SFT validation conversations run once on final candidates, never to
  choose between variants.

## Procedure

### 1. FP32 reference and capture

Run the model in FP32 with the original weights over the 10,000-token context. For each MoE layer, save:
- `x`: the routed-expert input (the post-attention normalized hidden, which feeds both router and experts);
- the top-k expert ids;
- the routing weights exactly as applied to expert outputs, including normalization and the routed scaling
  factor.

Also save the reference logits for the dev rows.

The reference must reproduce the official implementation's math, not our runtime's. For GLM-5.3, the engine
runs the official transformers `glm5_next` decoder layers one layer at a time over the whole sequence:
- each layer's weights come from the HF FP8 checkpoint, dequantized with its 128×128 block scales;
- attention is SDPA with the DSA mask, and experts use the eager loop.

Over the first 4 layers this loop is bit-exact against the full `Glm5NextTextModel` forward. With one layer
resident, a 45-layer pass over 10,000 tokens takes 18 minutes on an M5 Ultra, bound by reading weights from
the external drive. Only the current layer and the prefetched next one are resident.

### 2. Derive `c_gu` and `c_d`

For each MoE layer, accumulate over every routed (token, expert) pair in the fit rows, in float64. Notation:
- `L` is the model's SwiGLU limit (10 for both models);
- `r` is the pair's routing weight;
- `W` are the original FP32 weights; `Q` are the bank decoded from the checkpoint.

```
g0 = x·W_gateᵀ    u0 = x·W_upᵀ    h0 = r · silu(min(g0, L)) · clamp(u0, −L, L)
gq = x·Q_gateᵀ    uq = x·Q_upᵀ

c_gu = argmin over c of Σ ‖r · silu(min(c·gq, L)) · clamp(c·uq, −L, L) − h0‖²
       grid 0.90 to 1.25 in steps of 0.01, then a parabola through the minimum and its two neighbours

c_d  = Σ ⟨Q_down·h0, W_down·h0⟩ / Σ ‖Q_down·h0‖²     (least squares, reference hidden h0 as input)
```

Write one JSON per layer with:
- both gains and the bank formats they were derived for;
- the fit-row errors before and after;
- the linear least-squares gains of gate and up;
- the hidden-error curve over the grid.

### 3. Bake

Clone the source checkpoint (`cp -c`, so the copy shares blocks on APFS) as `TARGET.part`. Then multiply the
FP32 row scales of every routed bank: gate and up by `c_gu[L]`, down by `c_d[L]`.

Each bank stores its packed codes first. The code payload is `experts × rows × ⌈cols / group⌉ × bits / 8`
bytes, padded to 128 bytes. The `experts × rows` FP32 row scales follow, flagged by
`datatype & 0xFF000 == 0x04000`. Group sizes:

| format | type id | elements per group | bits per group |
| --- | --- | ---: | ---: |
| IQ2_XXS | `0x8A1EB2` | 32 | 64 |
| Q2_K | `0x8A1EAD` | 16 | 42 |
| IQ3_XXS | `0x8A1EB1` | 8 | 28 |

Before renaming `.part` to the target name, verify two things:
- every scale equals the source scale times the factor (float32 multiply);
- every byte outside the scale regions equals the source, by a full streaming compare that also hashes the
  target.

Record the factors, the old and new scale hashes and the target sha256 in a report. Every
gain is a factor on top of the stored scales, so always bake from an unbaked source. Re-deriving on an
already-baked file would stack corrections.

### 4. Evaluate once

Use the swap engine: the FP32 reference with only the routed-expert weights replaced by the decoded banks of
a checkpoint. Shared experts, attention, router and head stay original.
- Score KL(reference ‖ variant) over the full vocabulary, plus top-1 agreement, on the dev rows.
- Report the paired per-row difference against the stored checkpoint, with its standard error over rows and
  the two half means.
- Evaluate the baked file itself, so the result covers the bytes that ship.

One pass can carry several expert variants that share every other weight, so the evaluation needs a single
read of the original weights: the stored checkpoint, the baked one, and original experts as a self-check.

**Self-check.** Original experts through the evaluation engine should reproduce the reference:
- DeepSeek's SFT engine reproduced its stored reference logits exactly (KLD 0.0 on every row).
- GLM gave a mean KLD of 1.5e-5 (median row 5e-11). This comes from running 2,048 rows instead of 10,000,
  which changes how FP32 sums are ordered. It is under 0.01% of the effect being measured.

## Results

Wiki10k dev rows 0:2048, FP32 swap engine. "Stored" is the checkpoint as converted.

| checkpoint | stored KLD / top-1 | lgain KLD / top-1 | paired |
| --- | --- | --- | --- |
| DeepSeek 4.1 1017 `i2xxs_w2q2k` (160.5 GB text) | 0.4629 / 77.44% | 0.3898 / 79.25% | −0.073 ± 0.007 |
| DeepSeek 4.1 1017 `q2k_w2i3xxs` (208.6 GB text) | 0.2285 / 84.23% | 0.2191 / 84.23% | |
| GLM-5.3-Flash `i2x` (96.1 GB) | 0.4219 / 75.44% | 0.3681 / 77.49% | −0.054 ± 0.006 |

For reference, Unsloth UD-IQ2_XXS of DeepSeek 4.1 1017 scores 0.2755 on the same rows.

Derived ranges:
- **DeepSeek `i2xxs_w2q2k`, `c_gu`:** 1.08–1.11 at L0–7, 1.06–1.07 at L8–25, 1.03–1.05 at L26–39.
- **DeepSeek `q2k_w2i3xxs`, `c_gu`:** about 0.6 of the baseline's excess over 1.
- **DeepSeek `c_d`:** 1.005–1.015, except at L36–39: 1.06–1.07 on Q2_K, about 1.02 on IQ3_XXS.
- **GLM `c_gu`:** 1.024–1.116 (mean 1.049). The first MoE layer (L3) is the largest; its hidden error falls
  0.0568 → 0.0155.
- **GLM `c_d`:** 0.989–1.013.

The gains do the most in early layers and on the lower-bit checkpoint. On DeepSeek, the fitted hidden error
fell 24–86% at L0–7 against 2–5% at L26–32, and the 160 GB endpoint gained −0.073 KLD against −0.009 for the
208 GB donor.

## Invariants

- Only routed-expert FP32 row scales change. Codes, layout, every other tensor and the checkpoint size stay
  byte-identical, so no runtime or loader change is needed.
- Gains belong to one checkpoint's banks. Requantizing, changing the imatrix or the rounding, or changing a
  layer's format invalidates them. Re-derive from fit rows, and bake from the new unbaked source.
- Dev rows are scored once per final candidate, and the SFT hold-out runs only on final candidates.
- A baked file is accepted only after the byte-level verification passes. Its sha256 and report travel with it.

## Applying to a new checkpoint

1. Confirm the routed banks use a format with FP32 row scales, and confirm which bank is gate and which is up.
   Compare decoded experts with the originals: matching projections give about 0.3 relative error, crossed
   ones above 1.
2. Build or reuse an FP32 reference engine from the official implementation. Check it against the reference
   model forward on a few layers before trusting it.
3. Capture expert inputs, routing and dev logits over Wiki10k with the model's own tokenizer and document start.
4. Derive per-layer `c_gu` / `c_d` on rows 2048:10000 and bake into an `_lgain` clone.
5. Run one dev pass with the stored file, the baked file and original experts, then report KLD, top-1 and the
   paired difference.

## Tooling

The tooling lives in `benchmark-results/`, which is ignored by git:
- **DeepSeek 4.1 1017:**
  `benchmark-results/deepseek4_1-1017-wiki10k-resweep-20261022/gain-bias-diagnosis/`. Its
  `QUANTIZER_GAIN_BIAS_HANDOFF.md` records the full investigation, and `scripts/` holds `derive_gain.py`,
  `bake_gain.py`, `swap_scaled.py` and the decoder `libds4dec.dylib`.
- **GLM-5.3-Flash:** `benchmark-results/glm5_3-flash-gain-20261107/`. It contains `README.md` and
  `scripts/run_all.sh`, which runs `run_model.py` (the layer-outer FP32 engine, with `--capture` and multiple
  expert variants per pass), `derive_gain.py`, `bake_gain.py` and `score.py`.

## Open questions

- No native-runtime KLD or generation check of the baked GLM file was run in the session that produced it.
- The remaining DeepSeek gap to UD-IQ2_XXS is attributed to activation-aware rounding on UD's side. Their
  errors are anti-aligned with the input covariance. Our GPTQ/LDLQ-style gate/up rounding, using a Hessian from
  chat-prompt calibration, tied the baseline once a gain was applied. It is shelved, not ruled out; a
  Wiki-inclusive Hessian is the untested next step. Any rounding change produces new banks, which need their
  own gains.
