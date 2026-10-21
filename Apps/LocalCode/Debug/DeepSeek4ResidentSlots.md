# DeepSeek4 24 / 40 GiB resident-slot allocations

The 24 and 40 GiB tiers use per-layer allocations fitted on current routed-expert
traces. The existing 8 / 16 / 32 / 48 GiB arrays are unchanged. Slot arrays are
indexed by layer 0 through 42 in `DeepSeek4TextGenerator.swift`.

| Tier | Routed pool GiB | Total slots | Full layers (0-indexed) | Fit expert hit | Leave-one-project-out hit |
|---|---:|---:|---|---:|---:|
| 24 GiB | 18.6525 | 2,726 | None | 82.07% | 81.96% |
| 40 GiB | 34.6479 | 5,040 | 0, 1, 2 | 94.23% | 94.14% |

## Method and selection

The 2026-09-07 analysis reuses the allocator from the SSD-streaming prototype
(commit `625be2d25`): protected-token LRU, capacities 6 through 256, and marginal
expert-miss reduction per extra allocated byte. All six experts selected by a
token are protected during eviction. Slots are not physically compacted.
The budget is the nominal tier minus the historical 5.345 GiB fixed base;
KV, activation, staging, and other process memory are additional, so these tiers
are not hard RSS limits.

Expert costs, including gate/up/down and scales, are 7.90625 MiB for layers 0–1,
6.65625 MiB for 2–36, and 8.78125 MiB for 37–42. These were checked against the
IQ2XXS/IQ2XS/Q2K checkpoint's serialized sizes. The allocator optimizes expert
misses under a byte budget, not byte-weighted physical SSD traffic directly.

Six project histories have equal weight. Each trace prefills 256 saved tokens
and replays the next 1,024 tokens one at a time using the existing generator and
KV state. The first 200 events warm the simulated LRU, leaving 4,944 evaluated
tokens and 1,275,552 expert references. A native replay matched the original
Python simulator on 3,012 miss/all-hit curve checks. Tracing acknowledged every
GPU mailbox, including cache hits; paused replay matched 64 next-token
predictions from normal generation. Trace timings were not used as benchmarks.

The historical 24 GiB list scored 80.37% on this corpus, versus 81.35% for uniform
slots. The selected refit scored 82.07% and 81.96% on held-out-project refits.
At 40 GiB, uniform slots scored 92.61%, and the midpoint of the existing 32/48
lists scored 93.63%. All six held-out refits selected no full layers at 24 GiB
and exactly layers 0–2 at 40 GiB. A separate withheld project scored
82.12% / 93.06% at 24 / 40 GiB.

The selected 40 GiB policy requests an estimated 104.49 MiB per token, compared
with 136.47 for uniform slots and 117.20 for the midpoint. Charging first touches
to its full layers changes its fitted hit rate from 94.233% to 94.188%.
These are logical request estimates, not measured physical SSD bandwidth.
Six projects remain a limited sample, not a universal workload guarantee.
Raw project histories, token traces, and experimental instrumentation are not
included in this integration change.

## Integration and validation

Automatic selection still reserves 32 GiB of physical RAM. It now chooses
24 GiB at 56 GiB physical memory, and 40 GiB at 72 GiB. The 48 GiB cap and
122 GiB physical-memory threshold for disabling streaming are unchanged.
The settings menu uses the existing integer preference and takes effect on the
next model read; no new persistence key or runtime mode is introduced.

24 GiB uses the existing 8 GiB whole-file mapping limit. 40 GiB uses 14 GiB,
like 48 GiB: the relocated full layers end at 9.88321 / 11.85977 / 13.52383 GiB.
No changes to the model builder, backend, or adaptive-prefill policy are needed.

The original integration passed 423 memory-boundary cases, all allocation byte
budgets, raw-value round trips, and full-layer mapping bounds. Thirteen optimized
production runs at M=512/3072/4096 produced the same 64 tokens as the 32 GiB
reference. Those runs used the prototype's clean benchmark probe and external
ccv commit `01607ca0712287a27e46772d3ca4b00d2d121605`, with ANE disabled and
64 warmup tokens. They were not cold-SSD tests: no purge was performed, and
`F_NOCACHE` does not remove already cached pages. Timings varied, including an
initial slow 40 GiB run that did not reproduce in two order-balanced repeats.
