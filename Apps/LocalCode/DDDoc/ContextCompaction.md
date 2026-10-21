# Context Compaction

- Status: Implemented
- Scope: Qwen 3.5 local context compaction and provider-backed remote-agent compaction
- Last verified: 2026-08-23

## Context and ownership

Context compaction is model-family-specific behavior owned by the model's
`CodeAgent`, rather than a model-independent history or chat-workflow policy. A
`CodeAgent` already owns the model's prompt grammar, tokenizer, reasoning
format, tool-call protocol, and continuation behavior, so it also decides how
context can be reduced without breaking those semantics.

This document records context-compaction behavior by model family. It currently
documents the policy implemented by `Qwen3_5CodeAgent` for the Qwen 3.5 family,
which for Local Code includes Qwen 3.6 and the upcoming Qwen 3.8. As compaction
for other model families is implemented, their behavior will be added here in
separate model-family sections.

The trigger lengths and token budgets documented for the Qwen 3.5 family are
current implementation settings, not permanent API or persistence contracts,
and are expected to become configurable. The general strategy can guide
compaction in other `CodeAgent` implementations, but each model family must
choose its own thresholds, token parsing, removal policy, checkpoint prompt,
and continuation flow.

## Qwen 3.5-family compaction strategy

For the Qwen 3.5 family, compaction operates on the token prefix used to
continue generation, not on the completed transcript shown to the user. Its
purpose is to preserve enough working context for the agent to continue the
current task while keeping that model-facing prefix within a useful context
budget. User and assistant transcript entries remain available in Project
History even when their original continuation context has been reduced or
replaced.

Qwen compaction is progressive. It first rewrites the token prefix
deterministically by removing older thinking sections, replacing oversized
tool responses with recoverable previews, and, at higher effort, removing
completed tool-call and tool-response pairs. Tokens that remain in the prefix
stay exact. When those reductions cannot create enough room, a model-generated
context checkpoint summarizes the working state and rebuilds the continuation
prefix around that summary and a retained window of recent conversation. This
delays semantic summarization until structural reduction is insufficient.

Compaction is an internal continuation transition, not a separate user-visible
conversation turn. It may run before a new prompt is processed or while the
agent is working through generation and tool use. After rebuilding its prefix,
`Qwen3_5CodeAgent` resumes the pending prompt or unfinished task automatically;
`ChatWorkflow` may show compaction progress, but the temporary checkpoint
prompts and bridge exchange do not become transcript messages.

## Deterministic token-prefix compaction

Deterministic compaction treats the Qwen continuation prefix as a sequence of
chat-message segments delimited by Qwen's `<|im_start|>` token. Within those
segments it recognizes Qwen thinking and tool-response blocks from their
special-token boundaries. It copies retained token ranges directly instead of
decoding and retokenizing ordinary conversation content, and exposes low- and
high-effort policies over the same model-specific structure.

Completed thinking sections are treated as transient working traces rather
than the durable result of a turn. Low-effort compaction removes them from
retained messages except when a message is immediately followed by a tool
response, preserving the reasoning attached to that tool invocation.
High-effort compaction preserves thinking only in the most recent retained
message. If a thinking block has no matching end boundary, the compactor leaves
the unmatched remainder unchanged rather than guessing where it ends.

High-effort compaction additionally removes completed tool exchanges as whole
pairs. When an assistant message is followed by a message containing its tool
response, both message segments are removed so the retained prefix never
contains only one side of the exchange. This reclaims tool-heavy context while
leaving later conversation in exact token form; the structured tool-call
record remains available to the transcript even though the exchange no longer
participates in model continuation.

Oversized tool responses are externalized rather than simply discarded. The
compactor writes the full decoded response atomically to
`.localc/tool_responses/<sha256>.md`, using a content-derived filename, and
replaces the response body in the model prefix with a bounded head-and-tail
preview plus that project-relative path. The preview tells the agent to use the
`read` tool when it needs the complete response, preserving recoverability
without keeping the full payload in active context.

Tool-response externalization is best-effort. If no usable project path is
available, the artifact directory cannot be created, or the atomic write
fails, compaction retains the original tool-response tokens instead of
inserting an unusable reference. Identical response text resolves to the same
SHA-256-derived artifact path.

## Model-generated context checkpoints

A context checkpoint is the Qwen 3.5 family's semantic fallback when
structural compaction no longer leaves enough working room.
`Qwen3_5CodeAgent` asks Qwen to produce a concise handoff summary for another
language model, covering current progress, key decisions, constraints and user
preferences, remaining work, and critical data or references needed to
continue. The summary preserves task state rather than attempting to reproduce
the old conversation verbatim.

After generating the handoff, the agent retains a bounded window of the most
recent conversation in exact token form instead of replacing the entire
prefix with the summary. It walks backward in two-message turn units and keeps
the set closest to the configured history budget, so a request and its response
are retained together. The handoff summary carries forward the older task state
that no longer fits in that exact recent window.

The generated handoff is normalized before it becomes continuation state. The
agent removes generation terminators, decodes the remaining output as text,
retokenizes it with the safe tokenizer, and prepends fixed framing that tells
the next model instance how to use the handoff. It then supplies that framed
summary as a user message after the retained recent window, preventing
generated special-token text from becoming unintended Qwen chat structure.

The framed handoff is followed by an assistant bridge generated with thinking
disabled. This creates a complete Qwen user-and-assistant exchange that
incorporates the handoff into the rebuilt prefix without spending another
reasoning budget. The bridge is retained as model continuation state but is not
presented as a new transcript response.

What runs after the bridge depends on why checkpointing began. When a new
request arrives and the existing prefix is already above the checkpoint
threshold, the agent holds that request aside, checkpoints the existing
conversation first, and then processes the original request against the
rebuilt prefix. If checkpointing interrupted an unfinished generation or tool
loop, it issues the fixed prompt "Continue the unfinished task." If the
completed response only needed to compact context for the next request, the
checkpoint ends after the bridge and returns the already completed response.

Checkpoint construction is all-or-nothing with respect to continuation state.
Before starting the handoff, the agent keeps the pre-checkpoint prefix. If
generation is stopped during the handoff summary or bridge, it restores that
prefix, clears the model caches and tool-call parser state, and does not expose
the partial checkpoint as the new continuation. Only a completed checkpoint
can replace the previous prefix.

## Trigger lifecycle and current operating values

Qwen compaction is triggered by token pressure rather than by message count or
persisted database size. Context-limit decisions measure the Qwen system prompt
together with the active continuation prefix and, during generation, the
tokens being produced. A separate counter tracks how many continuation tokens
have accumulated since the last compaction so the agent can perform lower-cost
maintenance before it reaches the hard-context path. Whenever compaction
rewrites the prefix, the agent invalidates its KV and draft caches and resets
that accumulation counter.

At the start of each `ask`, the agent first checks whether the existing system
prompt and continuation prefix already exceed the context-checkpoint
threshold. If they do, it holds the new request aside and checkpoints the
existing conversation before processing it. Otherwise, once the accumulation
counter reaches the low-effort threshold, it performs deterministic low-effort
compaction before appending the new request. A checkpoint therefore takes
priority when the restored or accumulated prefix is already beyond its
checkpoint boundary.

Before each normal decode, the agent caps Qwen's thinking allowance to the
remaining room below the agent-visible context limit after reserving `8,192`
tokens for generation, while preserving at least one thinking token when
thinking is enabled. The checkpoint bridge runs with thinking disabled. The
thinking hard stop is therefore independent of deterministic and semantic
compaction thresholds: changing when compaction occurs does not silently change
the reasoning budget.

During generation, crossing the high-pressure boundary does not immediately
truncate the model's output. The agent waits until no complete or incomplete
tool call is pending, then stops at a newline when one is available or after at
most 60 additional generated tokens. If needed, it closes an open thinking
section and the assistant message before applying high-effort compaction. This
preserves a structurally valid Qwen turn before the agent resumes or
checkpoints the unfinished task.

After a pressure-induced safe stop, the agent applies high-effort deterministic
compaction and reevaluates the resulting prefix. If the compacted system prompt
and prefix fit below the checkpoint threshold, it resumes with "Continue the
unfinished task." If they remain above that threshold, it creates a
model-generated checkpoint first and issues the same continuation prompt after
the bridge.

Long tool-driven requests also receive maintenance between model turns: when
tokens accumulated since the last compaction exceed twice the low-effort
threshold, the agent applies low-effort compaction before continuing the loop.
Separately, after an assistant response finishes with no further tool call, a
prefix still above the high-effort threshold receives high-effort compaction;
if that result remains above the checkpoint threshold, the agent completes a
checkpoint for use by the next request.

These thresholds are not one ascending severity ladder. The agent-visible
context limit governs reporting and the dynamic thinking hard stop, while the
larger generator limit is defensive capacity that is not advertised as usable
agent context. The generation safe-stop boundary controls active interruption,
and the lower checkpoint threshold is evaluated before a new request or after
deterministic high-effort reduction. The checkpoint threshold is intentionally
lower than the high-effort threshold: high-effort compaction must create useful
headroom, or the agent escalates to semantic checkpointing.

### Current Qwen 3.5 context values

| Setting | Current value | Applied as |
| --- | ---: | --- |
| Generator hard ceiling | `262,144` tokens | Rejects prefill beyond the model runtime's defensive capacity. |
| Agent-visible context | `131,072` tokens | Reported to the UI and used to calculate the per-decode thinking allowance. |
| Low-effort maintenance | `32,768` tokens | At least this many prefix tokens accumulated since the last compaction at the start of an `ask`. |
| In-loop low-effort maintenance | `65,536` tokens | More than this many tokens accumulated during a long multi-turn/tool loop. |
| Context-checkpoint threshold | `81,920` tokens | More than this many system-plus-prefix tokens before a new request or after high-effort compaction. |
| High-effort threshold | `98,304` tokens | More than this many system-plus-prefix tokens after a completed response triggers deterministic high-effort compaction. |
| Thinking generation reserve | `8,192` tokens | Reserved below the agent-visible context limit when calculating the effective thinking budget. |
| Active-generation pressure boundary | `126,976` tokens | More than this many tokens across current context and generated output initiates a safe stop. |
| Safe-stop continuation cap | `60` tokens | Maximum additional output allowed while looking for a newline after pressure is detected. |
| Retained recent-history budget | `16,360` tokens | Target for exact paired conversation turns retained during checkpoint rebuilding. |

### Current Qwen 3.5 tool-response values

| Setting | Current value | Applied as |
| --- | ---: | --- |
| Immediate read preview | More than `8,192` tokens | A newly returned `read` response is replaced by a bounded preview without creating another response artifact. |
| Immediate externalization | More than `32,768` tokens | A single newly returned non-`read` tool response is externalized before it is appended to the active tool loop. |
| Compaction-time externalization | More than `2,048` body tokens | An existing tool-response block is externalized during either low- or high-effort deterministic compaction. |
| Preview line limit | `40` lines per side | At most the first and last 40 lines are considered for the preview. |
| Preview token limit | `512` tokens per side | The retained head and tail are each capped independently before the artifact reference is inserted. |

Deterministic compaction no longer has the originating tool-call metadata, so
an inline `read` response between `2,049` and `8,192` tokens can still be
externalized later when compaction runs. Keeping the lower compaction-time
threshold preserves the intended effectiveness of low-effort maintenance.

## Remote-agent compaction strategy

`RemoteAgent` compacts provider-neutral content blocks and keeps completed tool
exchanges atomic. Its pressure threshold is derived from the selected model's
context and output limits, the configured compaction percentage, and a
15-percent compaction reserve. Runtime token estimates remain session state.

Before summarizing, it bounds oversized tool results, retains a recent tail,
and reduces older thinking and completed tool exchanges. These request-time
reductions do not rewrite Project History. If they are insufficient, the
selected model receives a separate tool-free checkpoint request; invalid or
insufficiently smaller checkpoints are rejected.

`RemoteChatSession` writes an incremental `log_plaintext` entry when the prior
transcript remains intact and a complete entry otherwise. Complete entries set
the assistant node's existing `compacted` flag. `ChatWorkflow` stores only this
text-native representation for a remote assistant node; it does not derive or
persist `log_tokens`. A later switch to local generation converts the remote
continuation in memory without rewriting that node.

## Persistence and workflow boundaries

`Qwen3_5CodeAgent` reports compaction at the durable assistant-result boundary.
Without compaction, `Result.logTokens` contains only the continuation tokens
appended during the current `ask`, and `Result.compacted` remains false. If any
deterministic rewrite or context checkpoint changes the prefix, the result
instead carries the agent's complete current prefix in `logTokens` and sets
`compacted` to true. The separately returned `outputTokens` still contain only
the assistant response intended for the visible transcript.

`ChatWorkflow` stores that result only in the assistant history node's
token-native fields. During
restoration, `ProjectHistoryManager` concatenates ordinary assistant logs in
order, but clears the previously accumulated continuation whenever it
encounters a node marked `compacted` and starts again from that node's full
checkpoint. Later ordinary logs append to the checkpoint. This preserves the
compacted Qwen prefix across project reopen without rewriting or deleting the
earlier transcript nodes.

The ownership boundary remains narrow. `Qwen3_5CodeAgent` decides when and how
to compact, interprets Qwen token structure, creates tool-response artifacts,
and returns either an incremental log or a checkpoint. `ChatWorkflow` supplies
project and tool context, renders compaction progress, and saves the completed
result. `ProjectHistoryManager` implements only model-neutral ordered-log and
checkpoint-replacement semantics; it does not parse or transform Qwen context.

Deterministic prefix rewriting runs synchronously inside the agent and does
not create a transcript or progress item. While a model-generated handoff or
bridge is running, the agent emits `.compact` progress events using the same
prefill and generation statistics path as ordinary work. `ChatWorkflow`
renders those events as transient "Compacting..." state; only the final
assistant result is eligible for persistence.

Once an externalized tool-response path is included in an incremental log or
compacted checkpoint, that project-local artifact becomes part of the durable
continuation state and must remain available across project reopen. The
current implementation does not garbage-collect these content-addressed
files. Any future cleanup policy must determine reachability from persisted
continuation logs before removing an artifact.

## Durable invariants and evolution

Qwen-specific compaction policy remains with `Qwen3_5CodeAgent`. Its message
delimiters, thinking and tool tokens, retention rules, handoff prompt, bridge
behavior, and thresholds must not be moved into `ChatWorkflow` or
`ProjectHistoryManager` as universal compaction logic. A future model-family
implementation may reuse general concepts, but it defines and documents its
own mapping from those concepts to the model's context format.

When compaction triggers become configurable, they remain model-family policy
inputs rather than fields required to decode Project History. The current
values remain the Qwen 3.5-family defaults. Configuration must preserve enough
separation for the checkpoint target to sit below the active-generation
pressure boundary and for the retained recent-history budget to leave room for
the handoff and subsequent work. Restoring an existing incremental log or
checkpoint must not depend on the threshold values that were active when it
was written.

Rewriting an existing continuation prefix invalidates both the current
in-memory model caches and its incremental relationship to the previously
persisted log. Every such rewrite therefore clears the in-memory KV and draft
caches and must be persisted as a full checkpoint; the agent must never emit
only a post-compaction suffix against the old history. This cache invalidation
is a proactive correctness measure: the project-local context cache remains
available and can restore matching prefix checkpoints from disk, so clearing
current memory does not inherently require recomputing the entire retained
prefix. Creating a shortened representation of a newly returned tool response
before it is first appended does not rewrite prior context and may remain an
ordinary incremental log.

## Source of truth and verification

[`Qwen3_5CodeAgent.swift`](../Sources/Agent/Qwen3_5CodeAgent.swift) is the
source of truth for trigger ordering, checkpoint states, continuation
behavior, and the incremental-versus-checkpoint result contract.
[`Qwen3_5CodeAgent+Compact.swift`](../Sources/Agent/Qwen3_5CodeAgent+Compact.swift)
is the source of truth for deterministic message rewriting and tool-response
artifacts.
[`Qwen3_5ContextCache.swift`](../Sources/Models/Qwen3_5ContextCache.swift),
[`ChatWorkflow`](../Sources/Chat/ChatWorkflow.swift), and the
[Project History decision record](ProjectHistoryPersistence.md) define the
adjacent disk-cache, presentation, and persistence boundaries. Changes to
those behaviors or current operating values update this Qwen family section in
the same change.

[`RemoteContext.swift`](../../../Libraries/RemoteAPI/Sources/RemoteContext.swift) and
[`RemoteAgent.swift`](../../../Libraries/RemoteAPI/Sources/RemoteAgent.swift) define remote
compaction. [`RemoteChatSession`](../Sources/RemoteAPI/RemoteChatSession.swift)
maps its result to the existing Project History checkpoint contract.

Existing
[`ProjectHistoryManagerTests`](../../../Libraries/ProjectHistoryManager/Tests/ProjectHistoryManagerTests.swift)
coverage verifies that a persisted compacted assistant node replaces earlier
token-prefix logs during restoration. It does not directly exercise Qwen
thinking removal, tool-pair removal, artifact externalization, trigger
transitions, or handoff generation. This documentation change is verified by
checking its repository links and Markdown whitespace, building
`//Apps/LocalCode:LocalCode` for iOS arm64, and running
`//Libraries/ProjectHistoryManager:ProjectHistoryManagerTests`; adding focused
CodeAgent compaction tests remains outside this task.

`RemoteAPITests` covers remote checkpoint replacement, context-limit recovery,
atomic tool exchanges, and transcript serialization.

Focused verification:

```sh
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
bazel test //Libraries/ProjectHistoryManager:ProjectHistoryManagerTests
bazel test //Libraries/RemoteAPI:RemoteAPITests
```
