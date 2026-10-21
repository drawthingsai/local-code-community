# CodeAgent Scheduling

- Status: Implemented
- Scope: Local Code cooperative CodeAgent pause, resume, hibernation, and foreground/background scheduling
- Last verified: 2026-08-31

## Goal

Replace the current stop-and-switch behavior for local CodeAgents with cooperative pause and
automatic resume. A paused CodeAgent unwinds its synchronous `ask` call so the existing serial
generation queue can run another CodeAgent. Resuming calls an explicit, lightweight `resume`
method, which continues from continuation data kept privately by the concrete CodeAgent.

The design applies to local CodeAgents only. Remote chat agents are out of scope.

## Existing Entities Retained

- `CodeAgent`
- `CodeAgentResult`
- `CodeAgentProgress`
- `Qwen3_5CodeAgent`
- `DeepSeek4CodeAgent`
- `TextGenerator` and its existing `ModelBuilder` reuse
- The existing serial generation queue
- The Qwen and DeepSeek context-cache implementations
- `ProjectQueuedItem` for prompts submitted while a thread has an unfinished turn

The design does not introduce a new TextGenerator runtime or change ownership of
`DynamicGraph`, `StreamContext`, or `ModelBuilder`.

## New Entities

Add a continuation decision returned by the existing CodeAgent progress callback:

```swift
public enum ContinuationState {
  case `continue`
  case pause
  case abort
}
```

Add one progress state for the natural suspension point after a tool has started but before a
blocking wait:

```swift
public enum CodeAgentProgress: Sendable {
  case prefill([ToolCall], Int, Int)
  case generate(CodeAgentResult)
  case toolsWait(CodeAgentResult)
  case compact([ToolCall], Int, Int)
}
```

`toolsWait` is a scheduler distinction, not a separate UI presentation. `AgentScheduler` forwards
the actual `.toolsWait` progress case when the corresponding thread is selected; `ChatWorkflow`
handles its result payload through the same rendering path as `generate`. Keeping the case visible
to non-UI callers also lets the command-line harness inject a scheduling event at the exact natural
suspension point.

Add one `AgentScheduler` for the currently loaded local `TextGenerator`. It serializes model use,
chooses which CodeAgent runs next, and owns the logical turn across multiple `ask` / `resume`
invocations.

Each concrete CodeAgent also gains its own private `SuspensionState`. This type is an
implementation detail: it is not declared by the `CodeAgent` protocol and is not inspected by
`AgentScheduler`.

## CodeAgent Protocol Changes

Keep the existing `ask` method and result type. Change only the progress callback result from
`Bool` to `ContinuationState`, then add `resume` and `hibernate`:

```swift
public protocol CodeAgent: AnyObject {
  // Existing properties remain unchanged.

  func ask(
    _ prompt: String, projectPath: String?, workspacePath: String?,
    webSearchProvider: WebSearchProvider,
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult

  func resume(
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult

  func hibernate(threadId: Int64) throws

  // Existing stopping helpers remain unchanged.
}
```

`ask` starts a new turn and requires that no private suspension exists. `resume` requires a
private suspension, consumes it, and continues the same turn. It does not accept the prompt,
project paths, provider, or other invocation inputs because those belong to the private
`SuspensionState`.

The callback decisions mean:

- `.continue`: continue the current invocation.
- `.pause`: capture a resumable private state and return from `ask` or `resume` without applying
  normal stop finalization.
- `.abort`: preserve the current user-stop behavior, including any model-specific graceful
  stopping and final result construction.

`hibernate` is valid only after an invocation returned because of `.pause`. All CodeAgent methods
are invoked on the serial generation queue, so `hibernate` cannot race a running `ask` or
`resume`. The scheduler supplies the existing project-local thread identifier. The private
suspension already contains `projectPath`, so `(projectPath, threadId)` identifies the persistent
record without introducing another suspension identifier. The operation throws so the unfinished
turn is not marked durable unless its continuation record was written. Completed KV chunks have
already been written through the existing context-cache path; any remaining tokens are part of the
continuation record and are reconstructed by prefill.

## Private SuspensionState

The concrete Qwen and DeepSeek agents define separate private suspension representations. Each
one retains the existing local values required to re-enter its generation loop, including as
applicable:

- Invocation inputs such as project path, workspace path, and web-search provider
- The current outer-loop phase: prefill, decode, compaction, or tool wait
- Current user / continuation tokens and partial generated tokens
- Accumulated thinking, output, log, and tool-call history
- Compaction bridge state and queued continuation tokens
- Tool calls, responses, and any live wait object
- The token/cache boundary required by the next TextGenerator invocation

The private state is the single continuation representation for both hot pause and hibernation.
Hot pause keeps it and the KV cache in memory. In the first implementation, hibernation persists
the exact token tail and continuation state alongside the normal completed KV-cache checkpoints;
cold resume restores the last completed checkpoint and prefills the remaining tail. A later cache
optimization can serialize the partial KV tail directly without changing the scheduler or
CodeAgent APIs.

## AgentScheduler

`ChatWorkflow` no longer dispatches `codeAgent.ask` directly. It submits one logical turn through
`AgentScheduler.ask(...)` with the same prompt, invocation context, UI progress closure, and final
completion closure.

Scheduler activation and `set(filePath:estimatedKVCacheSize:)` configure model metadata as before.
The send and resume paths retain their existing selected generator on the scheduler when scheduling
its first turn. `ChatWorkflow` checks the active scheduler, retiring schedulers, and the selected
wrapper, in that order, before constructing a generator. Matching uses the resolved model file path. Selecting
A → B → A therefore reuses A's shared `Storage` while its scheduler remains resident or retires,
without reading a running CodeAgent's mutable generator. The template remains available through
hibernation; scheduler teardown transfers its final release to the generation queue.

For each generation slice, `AgentScheduler` invokes either:

- `codeAgent.ask(...)` for a new logical turn, or
- `codeAgent.resume(...)` for a suspended logical turn.

In addition to `ask`, foreground selection, Stop, and hibernation, the scheduler exposes two
narrow synchronous lookups for app integration:

```swift
func residentCodeAgent(projectPath: String, threadId: Int64) -> (any CodeAgent)?
func residentProjectWorkspace(projectPath: String) -> SQLiteWorkspace?
```

These return existing entities directly and do not introduce a registry, lease, or public
scheduler-entry type. Project paths are canonicalized the same way as `ChatWorkflow.openProject`.
The scheduler's small request-state lock protects these lookups because the generation queue may
be occupied inside a synchronous CodeAgent invocation.

It wraps the CodeAgent progress callback to:

1. Record the latest progress and partial result for that project/thread.
2. Forward progress to ChatWorkflow only when that project/thread is currently selected.
3. Honor a Stop request for the selected foreground logical turn and return `.abort` once the
   existing model-specific graceful-stop boundary is reached.
4. Return `.pause` when another CodeAgent should run first.
5. Otherwise use `.continue`.

The scheduler remembers when its wrapper returned `.pause`, so the CodeAgent protocol does not
need to expose a state property. When the invocation returns after `.pause`, the scheduler keeps
the logical turn open, chooses another agent, and later invokes `resume`.

The user-facing scheduler operation is `stop(codeAgent)`, not `abort(codeAgent)`. `abort` remains
only the internal `ContinuationState` delivered to the concrete CodeAgent after the current
`canStopImmediately` / `isCapReachedForStopping` policy allows finalization. Stop applies to the
selected foreground CodeAgent; background scheduling and model replacement use `.pause`.

The selected foreground thread always has priority and continues through its tool waits. With no
foreground work, background logical turns run in FIFO order. A background turn normally keeps the
model until it completes a turn or reaches a natural tool-wait suspension point; it is also paused
at the next ordinary progress boundary whenever foreground work appears.

Scheduling order also determines which paused CodeAgent is least valuable to keep hot. When a
hot-cache limit or memory pressure requires eviction, hibernate the agent that the scheduler
would otherwise schedule last rather than maintaining an independent LRU policy.

Each TextGenerator supplies a conservative static KV-cache estimate: 7 GiB for Qwen3.5 at the
suggested roughly 100K-token context, covering the 27B configuration, and 4 GiB for DeepSeek 4
Flash at roughly 400K tokens. The scheduler reads the checkpoint size directly from its file path
and computes its fixed hot limit as:

```
max(1, floor((physicalMemory - modelFileSize) / estimatedKVCacheSize) - 2)
```

The foreground CodeAgent is always hot. Background entries admitted to the hot set continue using
the existing scheduling rules, while cold entries do not rotate into that set merely because a hot
entry pauses at a tool wait. When a foreground promotion exceeds the cap, the scheduler hibernates
the nonforeground hot entry that occurs last in its FIFO. When a completed background entry is
released, the oldest cold entry is promoted into the open slot. A hibernated entry retains its
lightweight CodeAgent and private in-memory suspension while its KV tensors are released; this
allows the same scheduler to call `resume` directly without reconstructing the agent.
An idle foreground may remain hot in addition to the configured limit so that it cannot prevent an
unfinished background turn from making progress; the two-cache reserve in the limit calculation
provides headroom for this case.

## Tool Calls as Scheduling Points

After launching a tool and before the existing blocking wait, the CodeAgent first polls with
`group.wait(timeout: .now())`.

- If the group has completed, consume the response immediately without yielding.
- If the group is still pending, invoke the progress callback with `.toolsWait(currentResult)`.
- `.continue` preserves the blocking wait. This is the foreground behavior.
- `.pause` retains the live tool wait and response storage in `SuspensionState`, then returns from
  the CodeAgent invocation. This allows another background FIFO entry to run.
- `.abort` preserves the existing abort behavior.

On `resume`, the CodeAgent reaches the same tool-wait phase, performs the same zero-timeout poll,
and reports `.toolsWait` again only when the tool remains pending. While another agent is more
important, the scheduler can repeatedly return `.pause`. When no other agent should run first, it
returns `.continue` and permits the existing wait. No separate public tool-completion API is
required.

Background generation keeps the model through ordinary prefill / generation callbacks. It yields
only for foreground preemption or at `.toolsWait`. If all background entries are currently waiting
on tools, the scheduler polls them once in FIFO order and then lets the oldest one block, avoiding
a zero-timeout polling loop.

A lone background entry may likewise block in the existing bounded tool wait. If foreground work
arrives after that blocking wait begins, it starts after the tool finishes. Local file operations,
HTTP operations, and the hard timeout on bash execution keep this delay bounded, and accepting it
avoids a timer, tool-completion callback, or asynchronous-task runtime in the scheduler.

## Thread Switching and UI State

Thread or project selection changes the scheduler's foreground priority instead of stopping the
current CodeAgent. At the next progress boundary, the scheduler returns `.pause`, the current
CodeAgent unwinds, and the selected CodeAgent starts or resumes. A foreground CodeAgent that has
already entered a blocking tool wait does not yield until that tool returns; this follows the
foreground-priority rule.

The scheduler retains the CodeAgent, its project Workspace, and the latest progress and partial
result per project/thread. Background progress must never directly update the visible conversation.
When a running, paused, or idle-resident background thread becomes selected, ChatWorkflow reclaims
the existing CodeAgent and project Workspace from the scheduler, renders the retained partial state
when the turn is unfinished, and routes future progress normally.

Input and generation controls are derived from the selected thread's scheduled logical turn, not
from one workflow-global generation flag. Stopping affects only the selected logical turn.

## Project Workspace Ownership

Do not add a general Workspace registry. The existing project-list scan may briefly open a second
`SQLiteWorkspace` for read-only access; that is acceptable. Existing rename/delete paths already
reuse the selected project's Workspace instead of opening it again.

The new case is a project or thread retained by `AgentScheduler` after it moves to the background.
Each scheduler entry therefore retains the exact `SQLiteWorkspace` used by that CodeAgent. Before
`ChatWorkflow.openProject` creates a Workspace or reconstructs a CodeAgent, it asks the current
`AgentScheduler` for the `(canonical project path, threadId)`:

- If the scheduler has the thread, reuse its CodeAgent and project Workspace. Do not reconstruct
  the agent from history and do not open `metadata.sqlite3` again.
- If the scheduler has another thread from the same project, reuse that entry's project Workspace
  while constructing/restoring the requested thread's CodeAgent.
- If the scheduler has no entry for the project, follow the existing Workspace-open path.

Inactive-project mutations in `SettingsWorkflow` make the same narrow consultation before calling
`openExistingProjectWorkspace`: use the Workspace retained by `AgentScheduler` when that project is
background-active and do not shut down that borrowed Workspace; otherwise keep the existing
temporary open/mutate/shutdown path. No change is needed for the read-only project-list scan.

When switching away from a project with scheduled work, `ChatWorkflow` transfers Workspace
ownership to the scheduler rather than calling `shutdown`. When no selected workflow or scheduler
entry retains that Workspace, the existing shutdown behavior applies. Security-scoped URL access
must likewise remain active while a scheduled background agent still uses the project.

## Queued Prompts

Queued prompts remain associated with their existing project/thread through `ProjectQueuedItem`.
When a logical turn completes, `ChatWorkflow` checks queued items for that turn's thread even if it
is in the background and submits the next prompt to the same scheduler. A queued prompt makes that
thread runnable without requiring it to be selected. Queue lookup and assistant persistence use
the logical turn's original project workspace and thread identifier, never whichever project
happens to be visible when the turn completes.

The selected foreground thread and its queued turns retain priority. A completed background turn
with more queued input returns to the end of the background FIFO before its next turn begins.
After assistant persistence finds no queued continuation, `ChatWorkflow` calls
`AgentScheduler.markAsCompleted`. A completed foreground CodeAgent remains resident while selected;
once it becomes background, the scheduler releases the CodeAgent while retaining any project
Workspace and security-scoped access still owned by the scheduler. A turn with queued input is not
marked completed.

## Hibernation and Cold Resume

`hibernate` operates on an already-created private `SuspensionState`:

1. If one tool invocation has already started and remains in flight, synchronously wait for that
   tool and record its response. Do not launch the next tool.
2. Reuse completed context-cache chunks already stored in `.localc/context_cache.sqlite3`; persist
   the exact remaining token tail as part of the private suspension so cold resume can prefill it.
3. Persist the private suspension under the existing project-local `threadId`.
4. Release the hot KV state. The matching-model scheduler may retain the lightweight CodeAgent as
   a cold entry; retiring the entire scheduler removes it.

Consequently, hibernation never serializes a live `DispatchGroup` and cold restoration never
replays a tool that had already started. Switching models may wait for that one in-flight tool to
finish before the old scheduler can be discarded.

The existing model-filename-based cache identity remains sufficient. Sampling RNG state is not
persisted; output after a cold resume may diverge from uninterrupted generation.

On project/thread restoration, the persisted suspension distinguishes an unfinished generated turn
from the existing editable-draft case. The existing project-local `threadId` identifies the record,
and the stored model filename must match the active thread model. Reconstruct the model-specific
CodeAgent with its private suspension, register it when the matching TextGenerator is active, and
invoke `resume` automatically in the first implementation. A later UI iteration will leave the turn
suspended until the user explicitly taps Resume.

Switching models hibernates resident CodeAgents from the old scheduler before replacing it. A
hibernated CodeAgent is not managed by an `AgentScheduler` until its matching TextGenerator is
active again.

## Command-Line Integration Harness

The `generator-reuse` scenario runs without model weights. It checks scheduler retention,
reuse during scheduler retirement, and final release on the generation queue:

```sh
bazel run //Apps/LocalCode:AgentSchedulerHarness -- --scenario generator-reuse
```

Add a host `swift_binary` target named `AgentSchedulerHarness` under `Apps/LocalCode`. This is a
self-checking integration executable, not an app target and not a model-free unit test. It loads a
real `DeepSeek4TextGenerator`, constructs real `DeepSeek4CodeAgent` instances, creates the same
serial generation queue used by `ChatWorkflow`, and runs them through a real `AgentScheduler`.
Only the UI actions are scripted by the harness.

Like `DeepSeek4GeneratorProbe`, the Bazel target compiles the required UI-free Agent, tool,
TextGenerator, and context-cache source files directly alongside
`Debug/AgentSchedulerHarness.swift`; it does not depend on `LocalCodeLib`, which includes UIKit app
sources. The target adds the existing host tool-runtime dependencies plus `SQLiteDflat` for the
real project Workspace.

The executable takes an explicit checkpoint path, following the existing DeepSeek probes:

```text
bazel run //Apps/LocalCode:AgentSchedulerHarness -- \
  --model-path /path/to/deepseek_4_flash_0731_i2x.ckpt \
  --scenario hot-preempt
```

Use `--scenario capped-hot` to force the hot limit to one and verify that foreground promotion
persists the displaced CodeAgent before the new foreground starts, then automatically readmits and
resumes it after the slot is released. It also submits three background turns under the one-agent
cap and verifies that completion releases each slot to the next cold FIFO entry.

Other useful options are `--project-path`, `--workspace-path`, `--pause-after-tokens`,
`--thinking-budget`, `--timeout`, and `--print-progress`. The harness defaults to deterministic
generation and a zero thinking budget for bounded, reproducible scheduling checks. It creates a
temporary project and real `SQLiteWorkspace` when no project path is supplied.

Scheduling stimuli are injected synchronously from real progress callbacks, based on token counts
or `.toolsWait`, rather than wall-clock sleeps. This makes the switch point reproducible even though
model execution time varies. A bounded watchdog remains to turn a hung scenario into a nonzero
exit instead of leaving the command running indefinitely.

The first scenarios are:

1. `hot-preempt`: run an uninterrupted deterministic baseline, then run the same prompt again;
   select a second real CodeAgent after a fixed token count, let it finish or stop gracefully, and
   verify the first agent resumes and produces the same final tokens as the baseline.
2. `capped-hot`: force one hot slot, hibernate the displaced background agent before the promoted
   foreground starts, then readmit and resume the cold agent after the slot is released; also verify
   that completed background turns admit cold FIFO entries one at a time.
3. `fifo`: submit several real agents with no foreground work and verify completion order. Ordinary
   background generation is not time-sliced.
4. `foreground-tool-wait`: make the foreground agent launch a bounded bash tool and enqueue another
   agent at `.toolsWait`; verify the second agent does not generate until the foreground tool wait
   returns.
5. `background-tool-wait`: enqueue another agent when a background agent reports `.toolsWait`;
   verify the waiting agent pauses, FIFO work runs, and the first agent later resumes without
   replaying the tool.
6. `stop`: request Stop after a fixed generated-token count and verify graceful-stop continuation,
   exactly one completion, and no effect on other resident agents.
7. `resident-restore`: while one thread is background-active and again after it becomes idle,
   verify `residentCodeAgent` returns the identical object and `residentProjectWorkspace` returns
   the identical Workspace for canonical-equivalent project paths.
8. `queued-continuation`: persist a completed assistant turn, consume FIFO `ProjectQueuedItem`
   rows into one token-native user node, resubmit on the same real CodeAgent, and verify the second
   assistant turn and queue deletion.
9. `hibernate`: pause resident agents, synchronously finish an in-flight tool if present, hibernate
   them, verify the scheduler no longer reports them resident, and verify the suspension/cache
   records exist.
10. `hibernate-tool-wait`: pause a real agent at `.toolsWait`, request hibernation, synchronously
   finish the bounded tool, and verify the durable suspension record is written without replaying
   the tool call.

The harness records a compact ordered event trace containing foreground changes, progress kind,
token counts, completions, and scheduler lookups. Each scenario asserts structural behavior and
prints `PASS scenario=<name>` only after all invariants hold. It does not assert particular natural
language, except that deterministic uninterrupted and pause/resume runs must have identical token
results. The capped hibernation scenario checks persistence, readmission, completion, and suspension
cleanup rather than token identity because sampling RNG state is intentionally not persisted.
Tool-wait scenarios assert that the real model produced a tool call and fail clearly if it
did not.

Cold resume requires a second process to prove that no live Swift object is carrying state. Expose
it as two harness phases using the same project path and thread identifier:

```text
bazel run //Apps/LocalCode:AgentSchedulerHarness -- \
  --model-path /path/to/model.ckpt --project-path /tmp/scheduler-project \
  --scenario cold-resume-prime

bazel run //Apps/LocalCode:AgentSchedulerHarness -- \
  --model-path /path/to/model.ckpt --project-path /tmp/scheduler-project \
  --scenario cold-resume-finish
```

The prime phase pauses and hibernates, writes the expected deterministic baseline result, and exits.
The finish phase creates a new TextGenerator and concrete CodeAgent from the persisted suspension,
calls `resume`, and compares the final tokens with that baseline. This scenario will also force us
to make the concrete DeepSeek hibernated-agent restoration entry point explicit; it does not
require adding suspension state to the `CodeAgent` protocol.

## Core Invariants

- At most one `CodeAgent.ask` or `CodeAgent.resume` executes on the generation queue at a time.
- `.pause` always causes the current synchronous invocation to unwind.
- Only `resume` continues a private suspension; `ask` always starts a new logical turn.
- `hibernate` is called only after a pause has returned from the current invocation.
- `.abort` remains distinct from `.pause` and retains current stop semantics.
- `AgentScheduler` owns scheduling and UI routing but never interprets private suspension data.
- Hot pause and hibernation use the same private continuation representation.
- Remote agents remain outside this design.

## DeepSeek4CodeAgent Implementation Shape

`DeepSeek4CodeAgent.ask` currently keeps the whole logical turn in local variables inside one
`graph.withStream` / `graph.withNoGrad` invocation. The implementation is split without changing
its external generation semantics:

1. `ask` snapshots the current settings, tokenizes the new prompt, constructs a private
   `SuspensionState`, and enters a shared private run loop.
2. `resume` takes the existing private `SuspensionState` and enters the same loop.
3. The run loop switches between model generation and sequential tool execution. Existing
   compaction values remain fields of the same state rather than becoming scheduler-visible state.
4. `.pause` stores the current phase on the agent and returns the current `CodeAgentResult` without
   forced think-end / EOS finalization or compaction rollback.
5. `.abort` continues through the existing graceful-stop and forced-terminal-token path.
6. Normal turn completion commits the current segment to `prefixTokens`, produces the final result,
   and clears the private suspension.

The `DeepSeek4TextGenerator.decode` callback also returns `ContinuationState`. At a decode callback,
the reported token has already been evaluated into KV but the next token has not yet been sampled.
For `.pause`, the generator performs that one bounded sample and returns the sampled token as an
unevaluated pending token. `resume` evaluates that pending token and continues. For a partial
prefill pause, the suspension instead records the evaluated input length and resumes with the
remaining input. No RNG state is captured.

Internal structural stops take precedence over a scheduler pause at the same token. If a token
completes a tool-call block or reaches the model-specific compaction stopping boundary, DeepSeek
finishes that small structural transition first, then suspends at the resulting stable phase. This
prevents a sampled pending token from carrying generation past a completed tool-call block.
