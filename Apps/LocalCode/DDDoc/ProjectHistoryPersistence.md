# Project History Persistence

- Status: Implemented
- Scope: Local Code Project History and adjacent queued prompts
- Last verified: 2026-08-06

## Context and decision

Every Local Code conversation is created in the context of an active project.
Its messages and model context describe work performed against that project,
so the durable conversation is project-owned data rather than app-global chat
history.

Each project stores its Project History in
`<project>/.localc/metadata.sqlite3`, opened through Dflat as a
`SQLiteWorkspace`. The database contains thread metadata and ordered history
nodes. Queued prompts are stored beside them as adjacent persistent state but
do not become history until the normal send path consumes them.

The app-wide `Application Support/config.sqlite3` stores the selected-project
bookmark and other app state, but it does not own the project's conversation
records. Keeping the history with the project makes context ownership
explicit; database isolation and portability are useful consequences, not the
primary reason for the design.

## Persistent model

Project History is modeled as a thread index and an ordered node log.
`ProjectThread` makes conversations discoverable, while `ProjectHistoryNode`
stores the durable data for each user or assistant turn. `ProjectQueuedItem`
stores pending input alongside the history until the normal send path turns it
into a user node.

The three `.fbs` files are the source of truth for these persisted record
types. Bazel's `dflatc` rule compiles each `root_type` into the typed Swift
atoms, query fields, builders, and change requests used with
`SQLiteWorkspace`. Those generated APIs form the read and write path for
Project History.

| Schema | Persistent responsibility |
| --- | --- |
| [`project_thread.fbs`](../../../Libraries/ProjectHistoryManager/Sources/project_thread.fbs) | One catalog record per conversation thread: project-local identity, title, model, and recent-activity metadata. |
| [`project_history.fbs`](../../../Libraries/ProjectHistoryManager/Sources/project_history.fbs) | One ordered user or assistant node: transcript content and continuation state in exactly one token-native or text-native representation, plus structured tool metadata, draft-recovery pointers, and compaction state. |
| [`project_queued_item.fbs`](../../../Libraries/ProjectHistoryManager/Sources/project_queued_item.fbs) | One pending prompt: its thread, FIFO position, and raw text until the normal send path consumes it. |

### `ProjectThread`

`ProjectThread` is the project-local catalog entry for one conversation. It
supplies the identity and summary metadata used to list a project's
conversations and restore the model associated with a selected thread.

| Field | Meaning |
| --- | --- |
| `id` | Monotonic project-local primary key. `ProjectHistoryManager` allocates one greater than the largest persisted or pending thread ID. |
| `title` | Display name initialized from the first non-empty line of the first user prompt and editable through thread rename. |
| `created_at` | Creation-sequence marker. The current contract stores the same monotonic sequence value as `id`. |
| `updated_at` | Latest history-node `datetime`. It drives recency ordering, with `id` as the tie-breaker, and remains unchanged by rename. |
| `model` | Persisted local model identity used to select the tokenizer and chat template. Remote assistant entries carry their provider and model identity in `log_plaintext`. |
| `turn_count_since_last_review` | Completed user-turn counter for memory-review cadence. Incremented with the assistant-node write; reset after successful review or halved after a stopped review, without changing recency. Defaults to zero, including on older thread records. |

### `ProjectHistoryNode`

`ProjectHistoryNode` is the durable ordered entry for a user prompt or an
assistant result. Its composite primary key is `(thread_id, datetime)`:
`thread_id` associates the entry with a conversation, while `datetime`
identifies and orders it. `ProjectHistoryManager` chooses the greater of
wall-clock milliseconds and the latest project node plus one, giving newly
written nodes a strictly increasing project-wide order.

`ProjectHistoryNode` is the source of truth for conversation persistence. The
normal send path writes every accepted user prompt and completed assistant
turn as a node. A node uses exactly one representation family. Token-native
nodes use `tokens` and, for assistant nodes, `log_tokens`; `plaintext` and
`log_plaintext` remain absent. Text-native nodes use `plaintext` and, for
assistant nodes, `log_plaintext`; both token arrays remain empty. Local
generation writes the token form and remote generation writes the text form.
A thread may contain nodes from both families after a backend switch, but no
individual node duplicates its content or continuation state across families.

In the local generation workflow, `tokens` contains safely tokenized prompt
content for a user entry and generated output tokens for an assistant entry.
`log_tokens` contains the exact model-context sequence produced for a
completed assistant turn, including chat framing and tool exchanges. That
assistant sequence already covers its preceding user prompt, so user entries
keep `log_tokens` empty.

An assistant node with `compacted == true` establishes a new
continuation-state checkpoint. The [Context Compaction](ContextCompaction.md)
decision record describes how model-specific agents produce these checkpoints.
A regular assistant node contributes an incremental log, while a compacted
node contains the workflow's complete current continuation state. Token-native
restoration applies this rule to `log_tokens` and `embed_spans`, and passes the
result to the selected agent as its prefix; text-native restoration applies the same
rule to `log_plaintext`. Transcript display continues to use each node's
`tokens` or `plaintext`.

| Field | Meaning |
| --- | --- |
| `thread_id`, `datetime` | Composite identity and project-wide chronological order. |
| `role` | `User` or `Assistant`. |
| `tokens`, `plaintext` | Node-specific transcript content. Exactly one is populated according to the workflow that produced the node. |
| `log_tokens`, `log_plaintext` | Assistant continuation state in the same representation family as its transcript content. A regular entry is incremental; a compacted entry is a complete checkpoint. User entries leave both empty. |
| `embed_spans` | Ordered embedding ranges relative to this node's `log_tokens`, each with `start`, `length`, 32-byte file SHA-256 `digest`, and `kind`. Missing on older records means an empty list. |
| `tool_calls` | Structured function names and deterministically ordered parameters used to render local tool activity. Remote tool calls and results remain in `log_plaintext`. |
| `text_edits`, `text_lineage` | User-entry pointers into `TextHistoryManager`, used to restore an unanswered prompt to its editing position; `-1` represents an unavailable pointer. |
| `compacted` | Selects incremental-versus-checkpoint interpretation for the node's populated continuation field. |
| `duration` | Elapsed assistant-generation time in seconds. Zero means unavailable. |

Image inputs are file paths. `EmbedsFileStore` copies each encoded file to
`<project>/.localc/cas/<lowercase SHA-256 hex>` before the agent uses it. The digest
hashes the file contents before image decoding or resizing; no normalized PNG or
path is stored in `embed_spans`. Repeated references share the CAS file. CAS files
are independent of KV checkpoints and remain available after the source path is
removed or overwritten in place. A hard link is used only when the copy fails.

`ProjectHistoryManager.context(threadId:)` returns both tokens and spans. It offsets
each incremental node's spans by the preceding token count and resets both arrays
at a compacted node. Agent suspension, temporary state, and compaction preserve the
same pairing. Text edits rebase spans; retained-context cuts keep complete media
spans. Image prefill resolves the CAS file only when KV restoration has not already
covered those positions. The decoder validates its file digest and position count;
small numerical differences from reprocessing the same file are accepted.

The nested `ToolCall` and `ToolCallparameter`
values belong to their parent node; they are not independent project records.

`RemoteTranscriptCodec` stores versioned, provider-neutral content in a remote
assistant node's `log_plaintext`; it is not a separate history store. It does
not derive or persist `log_tokens` for that node.

### `ProjectQueuedItem`

`ProjectQueuedItem` stores a prompt submitted while generation is already
active for a thread. Its composite primary key is `(thread_id, datetime)`:
`thread_id` associates the prompt with its conversation, and `datetime`
preserves FIFO order. `text` keeps the raw prompt until the normal send path
creates a user history node.

| Field | Meaning |
| --- | --- |
| `thread_id` | Thread that will receive the pending input. |
| `datetime` | Queue identity and ascending consumption order within the thread. |
| `text` | Raw prompt text awaiting the normal send path. |

`ChatWorkflow` writes queued items directly through the generated Dflat change
requests and subscribes to the active thread's queue in ascending order. When
generation becomes idle, it joins the pending texts in FIFO order and hands
the combined prompt to the normal send path. During restoration, it combines
queued text with any recoverable unanswered user prompt in the composer. Queue
rows are deleted after their text has been handed into one of those flows.

Queue operations remain in `ChatWorkflow` because queued prompts are workflow
state; `ProjectHistoryManager` owns thread and history-node policy.

## Save and restore behavior

When Local Code opens an active project, `ChatWorkflow` creates the project's
`.localc` directory and `metadata.sqlite3` file as needed, opens the file as a
Dflat `SQLiteWorkspace`, and constructs `ProjectHistoryManager` over that
workspace. The active workspace stays open while the project is selected and
is shut down when the workflow switches projects or terminates. Project
discovery and inactive-thread rename operations open an existing project
database temporarily and close it after reading or updating it.

The per-project workspace dictionary stores navigation state under
`selected_thread_identifier`. A valid thread ID selects that conversation,
`-1` selects the new-thread draft, and a missing or stale ID resolves to the
most recently active thread. This state lives with the project's thread set
and is restored when the database reopens.

`ProjectHistoryManager` persists thread metadata and history-node changes on
the main queue. An operation that changes conversation activity writes the
affected `ProjectThread` and `ProjectHistoryNode` in one Dflat transaction,
keeping the thread index aligned with its ordered history.

| Event | Persistent result |
| --- | --- |
| First send in a new thread | Allocate the next thread ID and node `datetime`; create the thread with its title and local model identity; create the first user node; commit the thread and node together; then select the new thread. |
| User send in an existing thread | Capture the user content and `TextHistoryManager` edit/lineage pointers; append a user node; update the thread's `updated_at`; commit both together. |
| Assistant completion | Persist the assistant transcript representation, continuation log, structured tool calls, and `compacted` state; update `updated_at`; commit both together. Streaming partial output remains transient UI state. |
| Resend of a restored unanswered prompt | Replace the trailing user node's content and editing pointers, assign it a new monotonic `datetime`, and update `updated_at` in the same transaction. |
| Thread rename | Update `title` while preserving conversation activity time and local model identity. |

Restoration resolves the selected thread and reads its nodes in ascending
`datetime` order. Each workflow consumes native nodes directly and converts
non-native nodes in memory when a thread has crossed a backend boundary;
conversion does not rewrite or augment completed nodes. Both representation
readers reset at a compacted node. Restoration fails closed when a compacted
node has no readable continuation in its selected representation. Transcript
display uses `plaintext` when present and otherwise decodes `tokens`.

A trailing user node represents a recoverable unanswered prompt because the
user write precedes the durable assistant-completion boundary. The workflow
places that prompt in the composer, seeks its `text_edits` and `text_lineage`
position when available, and records the node identity so the next send
replaces it. Pending queued text is combined with the recovered prompt in FIFO
order and removed from the queue after it has been handed into the composer
flow.

The rendered transcript contains the completed portion of the conversation;
the recoverable trailing prompt is presented through the composer.

## Durable invariants

`ProjectThread.model` identifies the local model used by token-native fields.
Remote provider/model identity belongs to remote entries in `log_plaintext`.
Model switching converts a missing representation in memory and does not
rewrite completed nodes. Each subsequent turn is persisted only in the newly
selected backend's native representation. A remote session may require its
next text-native assistant entry to be a complete checkpoint after converting
token-native history.

`log_tokens` and `log_plaintext` participate in one logical continuation chain,
but an assistant node populates at most one of them. They do not establish
separate revisions or compaction boundaries. The one `compacted` flag applies
to whichever continuation field the node uses.

Dflat commits `performChanges` asynchronously, while `ProjectHistoryManager`
exposes each accepted thread or node change immediately. The manager
serializes its public operations on the main queue and overlays versioned
thread and node caches on persisted fetches until each transaction completes.
A completion clears only the cache entry carrying its write version, and a
temporary node tombstone hides the previous composite key during
unanswered-prompt replacement.

## Schema evolution and verification

Project History schemas persist inside project directories and can outlive the
app version that created them. Schema changes therefore preserve the meaning
and decoding of existing project databases.

- Add new FlatBuffers fields at the end with an optional value or a compatible
  default.
- Preserve existing field positions, types, enum raw values, and primary-key
  definitions.
- Deprecate an old persisted field in place; introduce any replacement as a
  new field.
- Treat a primary-key or continuation-representation semantic change as an
  explicit data migration.
- Update this decision record when a schema field gains new semantics or a
  workflow begins using a previously inactive representation field.

The [schemas](../../../Libraries/ProjectHistoryManager/Sources) and
[`ProjectHistoryManager`](../../../Libraries/ProjectHistoryManager/Sources/ProjectHistoryManager.swift)
define the persistence layer;
[`ChatWorkflow`](../Sources/Chat/ChatWorkflow.swift) owns project lifecycle,
save/restore orchestration, and queued prompts;
[`SettingsWorkflow`](../Sources/Settings/SettingsWorkflow.swift) consumes
thread metadata for project navigation.
[`ProjectHistoryManagerTests`](../../../Libraries/ProjectHistoryManager/Tests/ProjectHistoryManagerTests.swift)
verifies persistence across reopen, composite-key ordering, unanswered-user
replacement, token-prefix compaction, exclusive token-native and text-native
node writes, structured tool calls, selected-thread behavior, rename, and
queued-item ordering and deletion.
Focused verification:

```sh
bazel test //Libraries/ProjectHistoryManager:ProjectHistoryManagerTests
```
