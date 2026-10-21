# Memory

- Status: First local memory-enabled draft implemented; remaining design details below
- Scope: Local Code local and remote agents
- Updated: 2026-09-08
- Prompt comparison: [DS4, DSH, Qwen, Hermes, and OpenCode](MemoryPromptStudy.md)

This is the working implementation design for Local Code memory. It records
the decisions from the discussion and proposes concrete behavior for the
remaining details. Subsequent discussion should update this document in place.

## 1. Decisions and draft defaults

The following decisions are settled:

1. Both memory files belong to the selected project.
2. The paths are `<project>/.localc/USER.md` and
   `<project>/.localc/MEMORY.md`.
3. `USER.md` describes the user, their preferences, and their expectations in
   this project. `MEMORY.md` contains durable project and environment facts.
4. The Markdown files are the source of truth. Reading and editing these
   files is the persistence implementation.
5. Keep the implementation small. A database of memory records, an embedding
   index, entry UUIDs, and a separate memory service are unnecessary here.
6. Memory review is a temporary, serialized use of the active agent. Disable
   compaction for the entire review and its tool loop, then restore the position
   immediately before the review message and reuse the existing prefix KV.
7. Serial execution is chosen to reduce KV memory usage. The current fork path
   duplicates KV state; shared prefix ownership through a radix tree is a
   possible future cache architecture, not a prerequisite for this feature.
8. The dedicated memory-tool interface uses plaintext responses, consistent
   with existing tools for DS4 and Qwen. Each call has one optional `action`:
   `append`, `remove`, or `replace`; omitting `action` reads the selected file.

### Current discussion: ask(..., temporary: Bool)

The current working direction is to finish the active user turn, then call
`codeAgent.ask(reviewPrompt, temporary: true, ...)` on the same agent. Extend
the existing ask API with a `temporary` argument rather than adding a separate
review method. The agent owns temporary execution and restoration. Memory
review supplies its own internal prompt, tool policy, and UI presentation.
The workflow hides that internal user prompt and shows assistant feedback
as a separate item, introduced by the requested presentation:

```text
Reviewing Memory...
```

This label uses the localized `reviewing_memory_dot` key. Add the divider only
when tool activity or nonempty assistant feedback is available below it; an
empty body has no extra newlines.

The additional ask is temporary. The agent captures the conversation/cache
position before appending its internal user message. Run review and all of its
tool calls with compaction disabled. When review ends, discard that entire suffix
and restore the captured position. Subsequent real user turns continue from
the completed active task, using its existing KV state.

The review is therefore visible as assistant feedback without becoming part
of future model context. Successfully written memory files remain changed.
The review feedback row is removed on every completion path, including Stop.
No review feedback is retained in the UI, continuation logs, or restored history.

This replaces the earlier proposed detached, invisible reviewer as the
preferred execution path. Review runs every ten completed user turns per
conversation. Queued user work takes priority; a due review is deferred until
that work finishes.

The memory tool is a separate question. An `ask` tells the model to inspect
the conversation and decide what to remember. A file-writing operation saves
the resulting decision. The model can use either the existing file tools or
a dedicated `memory` tool to perform that write. Calling `ask` itself does not
save the model's answer into `USER.md` or `MEMORY.md`.

The first draft uses the dedicated tool. Its purpose is to offer a small file-edit API
with target selection, capacity checks, matching, and atomic file replacement.
Its arguments describe one action, and its response is plaintext. It does not
perform a second model inference or replace the review prompt. Section 5
records the agreed interface used by this draft. Generic file tools keep their
existing protection of project metadata.

An alternative considered during discussion used existing file tools:

```text
ask(internalReviewPrompt, temporary: true)
  → read .localc/USER.md and .localc/MEMORY.md
  → edit/write only the files that need a durable change
  → assistant reports what was saved, or "Nothing to save."
```

The current generic write/edit tools protect `.localc`, so this option needs
a narrow permission path for these two filenames. It does not require opening
all project metadata for editing. The first draft keeps those protections and implements memory capacity/format
checks in the dedicated tool. The review lifecycle and UI remain independent
of that choice.

The first draft implements the dedicated memory tool, safe frozen prompt inclusion,
refresh when the memory setting changes or semantic compaction succeeds, and
display-only review every ten completed user turns in local DS4/Qwen conversations.
A workspace setting enables memory by default. The shared tool registry also
exposes explicit memory operations to remote providers. Remote app conversations
load the same memory context during preparation and honor the memory setting.
Automatic remote review remains future work.

The rest of this document records the contract and remaining design details.
The local first draft implements the defaults below; remote review and additional
measurements are identified as future work.

| Detail | First draft |
| --- | --- |
| File encoding | UTF-8 |
| Entry separator | A line containing exactly `§` |
| `USER.md` budget | 1,375 Unicode scalar values in the serialized entry body |
| `MEMORY.md` budget | 2,200 Unicode scalar values in the serialized entry body |
| Prompt inclusion | Both files, in full when valid and within budget |
| Prompt role | Qwen: system context; DS4: memory after project context in the first user message's system reminder |
| Write API | Dedicated `memory` tool in section 5 |
| Mutation | One `append`, `remove`, or `replace` per call, saved atomically |
| Read API | `memory` with `target` and no `action` |
| Tool response | Plaintext result or `Error: …`, with current contents when available |
| Matching | Literal substring identifying exactly one entry |
| Ordinary write visibility | File changes immediately; existing system prompt stays fixed |
| Automatic prompt refresh | Fresh agent construction, memory-setting changes at ask entry, and successful semantic context checkpoint |
| Automatic review | Every ten completed user turns per conversation, foreground or background; defer for queued user work |
| Agent API | `ask(..., temporary: Bool)`; normal calls pass false, memory review passes true |
| Review execution | Temporary ask on the same agent, with restoration owned by the agent |
| Review suspension | Carry review mode and its original restore point through suspension/resume; restore only on terminal completion |
| Review compaction | Conversation compaction disabled throughout review; normal tool-result preview/externalization remains enabled |
| Review KV ownership | Reuse active buffers; retain prefix KV, discard review suffix, restore overwritten model-specific state |
| Review continuation | No review prompt, tool exchange, or feedback enters subsequent model context or continuation logs |
| Review UI | Hide internal user prompt; show localized `Reviewing Memory...` while running, adding `\n---\n` only before nonempty feedback, then remove the row |
| Editing interface | Ordinary files and tool feedback; dedicated memory-tool UI is optional |

Only the two Markdown files contain remembered knowledge. A small lock file
used for concurrent writes is an implementation artifact, like a temporary
file used for atomic replacement.

## 2. Project ownership and paths

Example project layout:

```text
MyProject/
├── AGENTS.md
├── Sources/
└── .localc/
    ├── USER.md
    ├── MEMORY.md
    ├── memory.lock
    ├── metadata.sqlite3
    ├── context_cache.sqlite3
    └── ...
```

Resolve these paths from the project's root URL captured when the conversation
is created. A tool must use that captured project, even if the user switches
the visible UI to another project while the tool is running. A shell command's
working directory does not change where memory is stored.

Do not search parent directories, the home directory, another worktree, or
another project's `.localc` directory for memory. Do not inherit a global
`USER.md`. Two projects may independently record different preferences for the
same person, and neither file overrides the other across project boundaries.

All conversations in one project share these two files. They may have
different already-rendered memory in their active prompts because they began
at different times. Sharing the files does not imply synchronously rewriting
every conversation's prompt after an edit.

Path behavior:

| Situation | Behavior |
| --- | --- |
| Neither file exists | Start with empty memory; ordinary project use continues |
| One file exists | Load that file; the other target is empty |
| First successful addition | Create `.localc` if needed, then create only the selected target |
| Empty read | Do not create a Markdown file or directory just to represent emptiness |
| Remove the last entry | Persist an empty file; no special deletion operation is required |
| Project has no usable root URL | Omit memory and return `project_unavailable` for a memory tool call |
| Project is read-only | Read memory when possible; return a write error for mutations |
| Project is moved | The files move with it; the host resolves the new project URL |
| Project is copied | The copied files are the new project's starting memory |
| Separate Git worktrees | Each worktree uses its own `.localc` directory |

Use the same canonical project identity for path resolution, writer exclusion,
and review cancellation. Reject a memory target or `.localc` directory that
resolves through a symlink outside the selected project. The tool accepts a
target enum, so the model never supplies an arbitrary destination path.

Project locality also means `USER.md` travels with an exported or shared
project if `.localc` is included. Project-local does not mean app-private.
Do not automatically commit, synchronize, or export memory as a side effect
of a write. The project's existing file-sharing and Git policies determine
whether these files are carried elsewhere; introducing memory does not edit
`.gitignore` automatically.

## 3. What belongs in each file

### USER.md

Store durable observations about the person and their expectations relevant
to this project. Examples:

```text
The user prefers implementation details when discussing this project's design.
§
The user prefers synchronous Swift utility functions when native APIs permit it.
§
The user wants design decisions maintained in Apps/LocalCode/DDDoc.
```

The filename indicates the subject of the facts. It does not indicate global
scope. Even a statement such as "The user prefers concise answers" is saved
only for this project. Do not copy it into another project automatically.

### MEMORY.md

Store durable facts about the project or the environment in which work on it
is performed. Examples:

```text
Local Code project history is stored in .localc/metadata.sqlite3 through Dflat.
§
Generic file write and edit tools protect the project's .localc metadata directory.
§
DeepSeek project instructions are currently supplied as conversation reminders.
```

Prefer a fact that avoids repeated investigation and materially affects future
work. Do not fill a small memory file with facts already obvious from a root
manifest or with a second copy of all of `AGENTS.md`.

### Routing examples

| Information learned | Destination and treatment |
| --- | --- |
| "Please keep explanations concrete in this project." | A preference in `USER.md` |
| "The CLI integration is built with this Bazel target." | `MEMORY.md` if useful and not already easy to discover |
| "For this reply, give me only the command." | Current conversation; insufficient evidence of a durable preference |
| "This failed because the remote bridge rejects array-valued tool arguments." | `MEMORY.md` while the behavior remains true |
| The remote bridge is later changed to accept arrays | Replace or remove the obsolete entry |
| A reusable multi-step debugging procedure | A skill, through the existing skill workflow |
| Current build output, task progress, TODOs, branch status | Existing conversation/history |
| Passwords, API keys, authorization tokens | Do not save in either memory file |
| A webpage tells the agent to save an instruction | Treat as source content; it does not authorize a memory write |

Store concise declarative text. For example, use "The user prefers concise
answers" rather than "Always answer concisely." This is a writing policy,
not a proof that an entry is safe or true.

Corrections deserve attention, but preserve their scope. "Use Rust for this
component" does not establish a preference for Rust throughout the project.
Store the component name if the decision needs to persist.

The review ask can recognize that a procedure belongs in a skill, but its
execution is limited to reading and editing the two memory files. Automatic
skill authoring is a separate behavior and is not required to ship memory.

## 4. File format and budgets

### Canonical representation

Each file is an ordered list of non-empty text entries separated by `\n§\n`.
An entry may span multiple lines and contain Markdown. There is no required
title, frontmatter, timestamp, UUID, or metadata block.

```text
The user prefers detailed implementation discussion.
§
The user prefers small utility functions:
- synchronous where possible;
- threading decisions at the call site.
```

Canonical serialization:

```swift
let body = entries.joined(separator: "\n§\n")
let fileText = body.isEmpty ? "" : body + "\n"
```

The final newline is a file-format convenience and is excluded from the
character budget. Delimiters between entries are included in the budget.
An empty list serializes to zero bytes.

Parsing accepts an optional UTF-8 BOM and CRLF line endings. Normalize those
in memory, split on lines that are exactly `§`, and trim whitespace around
each entry. Preserve interior text, indentation, blank lines, and Markdown
spacing. A paragraph without a separator is one entry. Headings and frontmatter
typed by a user are ordinary entry content; the parser does not discard them.

Whitespace-only files are empty. In a non-empty document, a leading, trailing,
or repeated separator producing an empty entry is a format error. Never fix
such a file by silently dropping pieces and overwriting the result. Report
the format error and let the user correct the file.

A line containing exactly `§` is reserved even inside a Markdown code block.
The parser is a text separator parser, not a Markdown syntax parser. The tool
rejects an individual entry whose content would introduce such a separator.
An inline section sign is allowed.

Reading never rewrites a file merely to normalize its formatting. A successful
mutation may write the canonical representation of the accepted content.
Documented BOM, line-ending, and boundary-whitespace normalization is allowed;
discarding unrecognized content is not.

### Counting

Use `body.unicodeScalars.count` for the proposed limits. This gives an explicit
character definition, including for Chinese text, combining marks, and emoji.
Swift `String.count`, UTF-8 byte count, and token count are different measures.
The tool response reports the same count used by validation.

Proposed budgets are 1,375 for `user` and 2,200 for `memory`, initially matching
the small-file scale in the Hermes study. Keep them as explicit implementation
defaults. There is no environment-variable configuration path in this draft.

Check capacity after applying the requested action to a temporary list. Each
successful mutation must leave a body within budget. If an append would exceed
the limit, first replace an entry with a shorter version or remove an obsolete
entry, then append in a separate call. Each successful call persists its own
change; later failure does not undo it. The implementation does not truncate
an entry or silently evict another entry. The model chooses what to change.

The size limit is also an inference budget: an over-budget manually edited
file is omitted from automatic prompt injection, with a diagnostic for that
target. The other valid target still loads. A memory tool read may return the
over-budget contents to help the model choose a replacement or removal that
brings the body within budget. If one action cannot do so, use bounded manual
repair; the tool does not persist an over-budget intermediate result.

Apply a separate 64 KiB UTF-8 read limit per file and 64 KiB argument limit per
tool call to prevent accidental large-file input. Read at most the limit plus
one byte before deciding the file is too large. Above that limit, report an
error and require ordinary bounded file inspection/manual repair; do not
return the entire file or attempt automatic rewriting.

There is no semantic deduplication during loading. Exact duplicate additions
through the tool are no-ops. Duplicates introduced by manual editing stay
visible, and ambiguous replacement/removal fails instead of selecting an
arbitrary entry. The model may consolidate semantically similar entries when
it can uniquely identify them.

## 5. The memory tool

This section specifies the dedicated tool used by the first draft: one action
per call with plaintext responses. Existing file tools remain available for
ordinary files; they do not gain a general project-metadata write exception.

### What it does and why it might help

The model calls a tool when it needs the host app to perform an operation.
Here the operation is just reading or editing one of two Markdown files.
For example, the model requests appending a preference; Swift code opens
`.localc/USER.md`, makes the edit, checks the budget, saves it, and returns
success or an error. There is no separate LLM inside the tool.

Its useful differences from an ordinary file edit are:

- The target determines the path, so the model need not supply it.
- The host can consistently reject over-budget or ambiguous edits.
- A successful response includes the complete current small file.

The costs are another tool schema, parser/registry integration, and an
entry-based format the model must learn. Existing `read`/`edit`/`write` can
perform the same basic persistence. If ordinary edits plus a narrow memory-file
validation path are sufficient, the dedicated tool is unnecessary for the
first version.

Regardless of the choice, review still happens through the follow-up `ask`.
This tool is an option for how that ask saves its decisions.

### Name, target, and arguments

The canonical name is `memory`. The model chooses `target: "user"` or
`target: "memory"`. Both targets resolve within the captured project root.
All supplied argument values are strings; `action` is optional.

Read the selected file by omitting `action`:

```json
{"target":"user"}
```

Append an entry:

```json
{"target":"memory","action":"append","content":"This project uses Bazel for builds."}
```

Remove an entry:

```json
{"target":"memory","action":"remove","old_text":"The old CLI entry point"}
```

Replace an entire entry:

```json
{"target":"memory","action":"replace","old_text":"This project uses Bazel","content":"Build the Local Code app with bazel build //Apps/LocalCode:LocalCode."}
```

| Field | Contract |
| --- | --- |
| `target` | Required; exactly `user` or `memory` |
| `action` | Optional; omission means read; when supplied, exactly `append`, `remove`, or `replace` |
| `content` | Required non-empty entry for `append`/`replace`; absent for read/`remove` |
| `old_text` | Required non-empty selector for `replace`/`remove`; absent for read/`append` |

Reject unknown fields, unsupported action/target values, non-string values,
and invalid field combinations. An omitted action is the read form; an
explicit invalid value must not silently become a read. The schema advertises
only the three mutation values for `action`; do not introduce an explicit
`read` alias. There is no array of actions or alternate mutation spelling.

These JSON examples describe request arguments. Local models use their existing
tool-call grammar to supply the same strings. The tool response itself is
plaintext, following existing Local Code file tools and the user's preference
for DS4 and Qwen. No JSON response envelope or double-encoded arguments are
needed.

### Read behavior

A call with only `target` reads the current file, even when the frozen prompt
contains an old version, the target is empty, or review execution permits only
the memory tool. It does not modify the file, its timestamp, or the active
system prompt. A missing file is an empty target and is not created by reading.
Report an unreadable file as an error, not as empty memory.

### Mutation semantics

Apply one action to the freshly read list:

- `append`: append a normalized entry. If the exact normalized entry already
  exists, report that it is already present and keep its original position.
- `replace`: find the entry containing `old_text` and replace the entire entry
  at its current position with `content`.
- `remove`: find the entry containing `old_text` and remove that entire entry.

`old_text` uses a case-sensitive literal substring match, with no regex,
case folding, or Unicode normalization. Match against entries, not against
the joined file text. Two occurrences within one entry still identify one
entry. Occurrences in two different entries are ambiguous.

If there are zero matching entries, report that no entry matches. If there are
multiple matching entries, report the count and ask for a longer selector that
identifies one entry. Do not fall back to fuzzy matching, index-based guessing,
or modifying every match.

The replacement text replaces the whole entry, not the substring. This must
be prominent in the tool description to avoid accidentally dropping the rest
of an entry when the model supplies only a short replacement fragment.

Validate the candidate representation and capacity before writing. On failure,
leave the file intact. A call that produces the same logical entries is a no-op
and does not rewrite the file just to change formatting. Successful mutations
use atomic file replacement; separate calls are independent, even within one
ask. A later error or temporary-ask reset does not undo an earlier saved edit.

Moving a fact from `USER.md` to `MEMORY.md` requires two calls. Append to the
destination successfully before removing the source; failure of the second
call leaves a duplicate that can be repaired. There is no cross-file transaction.

### Plaintext successful responses

Return a short result line, the current usage, and the complete current body.
For example, the append above returns:

```text
Appended to .localc/MEMORY.md.
35 / 2200 characters used.

Current contents:
This project uses Bazel for builds.
```

A read of that file returns:

```text
Read .localc/MEMORY.md.
35 / 2200 characters used.

Current contents:
This project uses Bazel for builds.
```

Replacement and removal use the result lines `Replaced entry in …` and
`Removed entry from …`. A duplicate append reports `Entry already present in
…; no changes.` A replacement with identical content reports `No changes to
…`. Calculate usage from the body using the Unicode-scalar rule in section 4;
the result line, usage, and `Current contents:` label are not counted.

Preserve entry text, line breaks, and separators in the returned body. Do not
JSON-escape it or also return a duplicate entries array. For an empty target,
report `0 / <limit> characters used.` and `No entries.` instead of a contents
block. When the file is absent, say so explicitly, for example
`.localc/USER.md does not exist; no entries.`

Report successful writes only after file replacement succeeds. The response
is the foreground model's immediate view of the edit. Do not also inject a
synthetic user message announcing the same update. The active system prompt
remains unchanged; document that behavior in the tool description.

### Plaintext failure responses

Use the existing file-tool convention, `Error: <explanation>`. Give enough
information to correct the call, for example:

```text
Error: old_text matches 2 entries in .localc/MEMORY.md. Use a longer substring that identifies one entry.
No changes were written by this call.
```

For a capacity failure:

```text
Error: Appending would use 2240 / 2200 characters in .localc/MEMORY.md.
No changes were written by this call. Shorten or remove an existing entry before appending.
```

When the current file is valid and below the hard read limit, follow the error
with its current usage and `Current contents:` block, using the same format as
a successful read. This gives the model fresh selectors and content for retry.
Clearly distinguish rejected candidate usage from current-file usage. Never
present the rejected candidate body as persisted content. If the file cannot
be read safely, return only the error and relevant path.

Swift implementation errors should use a dedicated `Error`/`LocalizedError`
enum, covering invalid arguments, unavailable project, invalid path/encoding/
format, excessive file size, missing or ambiguous entry, capacity, busy lock,
concurrent modification, and failed write. These are internal error cases;
the model receives their plaintext descriptions. Any remote `isError` metadata
is separate from the response text. Review cancellation/freshness failures
are host-side review outcomes, described below.

## 6. File editing and concurrent writers

The per-call algorithm below belongs to the dedicated tool. Path
protection, current-content checks, and atomic file replacement also apply
when using ordinary file tools. Atomic replacement protects one write; it
does not make a sequence of calls a transaction.

The implementation can be synchronous file functions and a small tool
adapter. It does not need to keep a process-wide mutable entry list. Every
mutation starts from the selected target's current file contents.

Proposed write sequence:

```text
validate arguments and captured project path
    ↓
acquire exclusive project memory writer lock
    ↓
read current target bytes
    ↓
parse and apply the requested action in memory
    ↓
validate final capacity and representation
    ↓
check that the target has not changed since the read
    ↓
atomically replace target with complete new contents
    ↓
release lock and return result
```

Use a stable `.localc/memory.lock` for cooperating writers across app windows,
CLI processes, and review turns. Do not lock the target file's inode and
then replace that inode; other writers must continue to contend on the same
lock. Keep the lock file in place instead of unlinking it after each operation.

Use a bounded/nonblocking acquisition and return a plaintext busy error when
another writer owns the lock. The utility does not sleep or create a dispatch
queue to wait. The tool's caller can retry later. File operations run on the
tool execution owner's appropriate executor, outside the UI main thread.

The lock serializes cooperating writes to both targets. Reads can use atomic
file snapshots without acquiring a writer lock, so loading memory in a
read-only project does not need to create `memory.lock`. There is no promise
that a read of both files represents one cross-file transaction.

Write a temporary file in the target's directory and replace the destination
atomically. Preserve the last valid destination on failure and clean up
temporary files owned by the failed operation. A process crash must leave the
old complete file or the new complete file. This draft does not claim
distributed locking or stronger power-loss durability than the platform's
chosen atomic-file primitive supplies.

A manual editor or shell command may not participate in the lock. Recheck
the original bytes/existence before replacement and report that the file
changed if an external edit is observed. This reduces accidental overwrites;
it does not eliminate the final race with a non-cooperating writer. The design
does not promise conflict-free concurrent manual editing or multi-device sync.

For ordinary cooperating foreground writers, locking and rereading avoid
lost updates. If two conversations add different facts, the second addition
is applied to the first writer's result. If another writer removed the entry
being replaced, the selector fails. The tool does not automatically reinterpret
a failed replacement as an addition.

### Relationship to generic file tools

`FileTools.swift` currently prevents generic `write`/`edit` operations under
the project's `.localc` metadata directory. Preserve protection of unrelated
metadata. There are two implementation options:

- Dedicated tool: leave the generic tools' protection unchanged and give
  `memory` its fixed-filename write path.
- Existing file tools: allow operations on exactly `.localc/USER.md` and
  `.localc/MEMORY.md` for the captured project, with the chosen memory validation
  rules. Keep all other `.localc` targets protected.

Read access can use the existing file tools. Manual editing through the user's
editor is an external file change. The file-tool option retains ordinary edit
semantics. Neither option makes a sequence of calls atomic. Both options
should reread current contents and avoid blind rewrites from the frozen
system-prompt copy. Existing shell capabilities are not converted into a
filesystem sandbox by this policy.

## 7. Model instructions and prompt placement

### Combined memory guidance and saved notes

The memory-tool introduction and the inserted file bodies form one section,
rendered by `MemoryContext.emitSections`. Do not maintain a separate stable
memory tutorial and a second snapshot-only block. The tool schema stays in
its existing location and describes operations, arguments, matching, and results.
The combined section describes when and why to use memory, its project scope,
and how to interpret the saved observations.

The [comparative prompt study](MemoryPromptStudy.md) records pinned upstream
sources and distinguishes model serialization from harness policy. Its
[combined section](MemoryPromptStudy.md#3-combined-introduction-and-inserted-format)
records the implemented wording and exact file-body format.
Its [tool description](MemoryPromptStudy.md#5-what-stays-in-the-tool-schema)
keeps the agreed plaintext interface and read-by-omission behavior.
Comments beside the runtime prompt definitions preserve their sources and rationale.

`MemoryContext` remains a typed context value following the existing
project/environment context types. Qwen expands `{{MEMORY_CONTEXT}}` inside
the system body. DS4 emits the same combined section below project context
inside the existing user-role system reminder. Tool schemas keep their existing
backend-specific placement.

The section has this structure; the study supplies the complete prose:

```text
# Memory

[project scope, memory-tool behavior, and interpretation guidance]

## USER.md — .localc/USER.md (1375 character limit)
[USER entries separated by a standalone § line]

## MEMORY.md — .localc/MEMORY.md (2200 character limit)
[MEMORY entries separated by a standalone § line]
```

Use plain Markdown headings, with Memory as the section name. The introduction
explains its project-local scope; no memory-specific XML wrapper is needed.

Render targets in a fixed order: USER, then MEMORY. Empty valid targets render
`(empty)` so the model knows both targets exist conceptually. Usage may be
included if calculated from the loaded body and kept fixed with that block.
Do not include a current timestamp, file modification time, or random ID.

Invalid/unreadable/over-budget targets render a short unavailable marker and
produce a host diagnostic. Do not inject a malformed file's raw contents.
Missing files are normal empty targets, not diagnostics.

For local models, emit the entire section with `allowsSpecialTokens = false`,
using the existing safe tokenizer path. Literal model control-token strings in
a file must remain text, never conversation structure. DS4's existing reminder
renderer still escapes `</system-reminder>` in its contents; memory has no
separate closing delimiter to escape.

Quoting, safe tokenization, and declarative wording have distinct purposes:
safe tokenization protects chat structure; quoting and instructions tell the
model how to interpret content. None is a reliable semantic poisoning detector.
Do not promise a "safe prompt" merely because a scanner accepted a file.

### Exact placement by backend

| Backend | Proposed placement |
| --- | --- |
| Qwen 3.5 family | `{{MEMORY_CONTEXT}}` inside the system body, after project instructions and before the existing system-message terminator |
| DeepSeek 4 | After the first actual user message, memory comes after project context inside the existing `<system-reminder>`; skills/environment remain in the initial instruction block |
| Remote providers | Expand `{{MEMORY_CONTEXT}}` in the system content, after runtime/project context; retain actual user messages unchanged |

Do not add a separate synthetic foreground user message for ordinary prompt
inclusion. DS4's existing transcript parser hides its system reminder from
visible user input. A memory-only project still gets a reminder even when no
`AGENTS.md` or fallback file exists. Tool schemas retain their backend-specific
existing placement.

### User-edited system prompt templates

Local Code already saves editable `templated_system_prompt_*.md` files under
`.localc`. Add the new placeholder to Qwen's built-in template. Existing unmodified
templates can follow `SystemPromptTemplate`'s normal refresh behavior.

For a user-edited Qwen template without `{{MEMORY_CONTEXT}}`, do not rewrite the
template or append memory after a model's closing chat delimiter. Proposed
behavior is to omit automatic memory injection and automatic review for that
agent, issue a diagnostic, and explain how to insert the placeholder. Explicit
memory-tool calls remain available through its supported tool schema. DS4
inclusion follows its project-reminder path and does not depend on a placeholder
in the editable initial instruction template.

Reject multiple memory placeholders as a template configuration error for
memory inclusion rather than duplicating the same file block. Expand the
placeholder once from the template itself; never recursively expand placeholder
strings found inside file contents. In particular, the local section emitters
must not reinterpret memory text as skill, environment, or reasoning placeholders.

## 8. Loading and the active prompt

There are two ordinary representations:

```text
Disk: .localc/USER.md and .localc/MEMORY.md
Model: a frozen MemoryContext rendered into the backend's prompt context
```

The latter is the frozen copy. Both local agents retain
`memoryContext: MemoryContext`, a `Codable`, `Equatable`, `Sendable` value with
USER and MEMORY contents, `.empty`, loading, rendering, and instance
`emitSections` semantics. It is an ordinary context value, not a store or live
file cache. Suspension payloads retain that same value. Reasoning-setting changes
reuse it when rebuilding other prompt sections. Changing the memory setting
explicitly loads or clears it at the next ask boundary.

File helpers may return temporary parsed arrays and usage information. They
do not retain live entries between calls. The file is authoritative for the
next read, and the existing system prompt is authoritative for exactly what
was supplied at the start of this inference epoch.

### Lifecycle table

| Event | Read files? | Change active prompt? | Notes |
| --- | --- | --- | --- |
| First agent for a new conversation | If enabled | Build it | Caller passes loaded context or `.empty` |
| Next ask with the same memory setting | No | No | Reuse existing memory block |
| Next ask with a changed memory setting | If enabling | Yes | Load current files or clear the block before starting the ask |
| Foreground `memory` read | Selected target | No | Fresh result is returned as a tool response |
| Foreground `memory` mutation | Selected target under writer lock | No | Successful result contains updated target |
| Another conversation changes a file | No automatic read | No | Existing agent keeps its copy |
| Manual external file edit | No automatic read | No | Observed at the next defined refresh |
| Deterministic context reduction | No | No | Removing thinking/tool history does not change memory |
| Memory review, including its tool loop | Read files through tools as needed | No refresh within the loop | Apply the ask's setting before capturing the restore point; disable compaction and restore the temporary suffix afterward |
| Successful semantic context checkpoint | If enabled | Yes, as part of checkpoint adoption | See the checkpoint contract below |
| Cancelled/failed semantic checkpoint | Staged reads may have occurred | Restore old block | Do not partly adopt a checkpoint |
| Hot scheduler pause/resume | No | No | Same suspended inference state |
| Hibernate/resume preserving the same logical agent | No | No | Preserve the block needed for continuation |
| Cold reopen from completed history | If enabled | Build a fresh prompt | Existing history is restored against current memory |
| Cold restoration of an unfinished suspended turn | Restore its captured block | Preserve that turn's original prompt | Defer reading current files until the turn reaches a safe refresh boundary |
| Model/provider switch creating a fresh agent | If enabled | Build a fresh prompt | Render for the selected backend |
| Reasoning setting changes within the same agent | No memory read | Rebuild other sections as needed | Use the retained memory block |
| User explicitly requests a memory refresh | Yes, at a safe boundary | Yes | Refresh must not alter a partially decoded turn |

Viewing another thread is not itself a memory refresh if that thread's agent
is retained. Discarding it and later constructing a new agent is a refresh.
This distinction is an implementation-visible lifecycle rule, not a promise
that memory refresh happens on every UI navigation.

Cold reopening from completed history deliberately uses the current files
rather than persisting historical copies of memory inside `metadata.sqlite3`.
The restored visible transcript remains unchanged. This design supports useful
continuation, not byte-identical reproduction of every historical model request
after restart.

Restoring an unfinished suspended turn is a separate case. Both local agents
already serialize suspension state, including partially generated context.
Include the captured rendered memory block in that existing suspension payload
so restoration cannot combine a partly decoded turn with newly read memory.
For checkpoint suspensions, preserve both the original and staged blocks needed
for rollback. This is cached inference state alongside the suspended tokens;
the two Markdown files remain the source of truth for subsequent fresh loading.

After cold suspension restoration completes the interrupted turn, refresh at
the next safe boundary. For older suspension payloads written before memory
support, absence of the memory field means that suspended turn used no memory
block. Use that empty block until the safe boundary instead of retroactively
injecting the current files into a partially decoded response.

### Explicit corrections and forgetting

An explicit correction in the current conversation is already in model
context. The agent should apply it immediately and update the appropriate
file. Ordinary correction does not require rebuilding the system prompt in
the middle of the tool loop.

An explicit request to forget an entry uses the ordinary `remove` operation.
If a review is running, the request waits in the normal queue until review
finishes or the user explicitly stops it. The successful tool result confirms
the file no longer contains the entry. The current conversation should obey
the forgetting request even though its original prompt copy is older.

The `remove` arguments do not distinguish explicit forgetting from automatic
curation. Therefore the first file-tool implementation does not infer a special
cross-conversation invalidation from every removal. Other retained agents keep
their prompt copies until their normal refresh boundary. An explicit host
refresh can be used when the user wants the active prompt copies updated as
well. Do not describe removal alone as immediate erasure from every active
conversation. Review is not allowed to continue committing from its old input
after the cancellation boundary.

This does not erase the original statement from conversation history, tool
results, existing cache files, backups, or Git history. "Forget this saved
memory" and "delete every historical occurrence of this information" are
different operations. Do not claim the latter after deleting an entry.

There is no new persisted tombstone list in the initial format. Within this
conversation, serial execution keeps the current review from committing after
the subsequent forgetting request. The flat files do not enforce a permanent
ban on re-extraction from history. The review prompt must honor later forgetting
requests, and the extraction input
must preserve those requests. A stronger permanent exclusion feature would
need a separate explicit design.

### Refresh requests

Provide an internal host operation to request refresh, usable by a later memory
editor or refresh control. A dedicated UI button is optional; automatic
foreground file editing does not require one. There is no model-facing
`refresh` action in the file-edit tool, and a natural-language request does not
reach this host operation merely by calling `remove`. The product entry point
for explicit refresh remains open for iteration.

Refresh at the next point where no model call or tool exchange is in flight.
If the rendered text is unchanged, keep the current tokens and caches. If it
changes, rebuild the relevant system content and invalidate in-memory caches
whose prefix depended on the old system tokens. Preserve the existing
conversation continuation; a file edit does not itself rewrite history.

Normal file edits do not broadcast this invalidation. Explicit host refresh
is an intentional exception to cache stability.

## 9. Semantic compaction integration

This section applies to ordinary user-task execution. The entire temporary
memory-review ask, including its tool-result continuations and completion,
disables both deterministic and semantic compaction. Review never enters the
conversation refresh/checkpoint paths below. New tool results still use the
ordinary preview/externalization path; that does not rewrite the retained
conversation prefix.

Local Code has both deterministic context reduction and model-generated
semantic checkpoints. Only the latter is a proposed automatic memory refresh
boundary. This avoids filesystem reads and prompt churn whenever old thinking
or a tool exchange is removed.

Implemented local checkpoint sequence:

1. Generate the handoff summary and bridge using the existing system prompt.
2. If either stage is cancelled, use the existing prefix rollback; memory has
   not changed, so no separate staged memory block is necessary.
3. After the bridge succeeds, load current project memory once as `MemoryContext`.
4. Compare it with the frozen value. If unchanged, do nothing. If changed,
   Qwen rebuilds its system tokens; DS4 rebuilds and replaces the combined
   memory/project reminder at its existing position in the compacted prefix.
   Invalidate in-memory caches before continuing under the accepted checkpoint.
   This comparison is part of step 3, not a separate refresh trigger.
5. Persist the frozen `MemoryContext` with ordinary suspension state
   so cold resume does not accidentally load a newer file version.

This deliberately adopts memory after bridge acceptance, keeping the initial
implementation inside the existing success/rollback paths. Deterministic
conversation reduction does not refresh memory. If a file cannot be loaded,
use its unavailable marker and emit a diagnostic without failing the task.

### Review history and comparisons with other frameworks

Hermes places `AGENTS.md` in its context tier, before the volatile tier containing
skills, `MEMORY.md`, and `USER.md`. This keeps more changeable content later for
prefix-cache reuse. Our project-context-before-memory order follows that placement.
Source: [Hermes prompt assembly implementation](https://github.com/NousResearch/hermes-agent/blob/main/agent/system_prompt.py#L596-L633).

Temporary review removes its own ask, tool exchanges, and final response from
the active model continuation. It does not remove the real conversation it
reviewed. Saved facts are usually already supported by that retained history;
the main missing information is which entries the reviewer chose to save or
edit. The files are immediately readable through the memory tool. Automatic
prompt adoption still waits for a fresh agent or successful semantic compaction.

Claude Code documents a similar cache boundary: auto memory belongs to project
context, which changes at session start, `/clear`, or `/compact`, rather than
on every ordinary turn. This supports deferring prompt refresh, but does not
establish that Claude uses our temporary-ask/KV restoration mechanism.
Source: [Claude Code prompt caching](https://code.claude.com/docs/en/prompt-caching).

LangChain Deep Agents documents background consolidation by a separate agent
that reads recent conversations and merges useful facts into persistent memory.
Its comparison lists availability in the next conversation as a background
consolidation tradeoff. This separates review execution from the foreground
conversation; the documentation does not specify our same-agent rollback.
Source: [Deep Agents memory](https://docs.langchain.com/oss/python/deepagents/memory#background-consolidation).

Letta offers a different policy: background sleep-time agents share memory
blocks with the main agent, and attached agents see updated block contents.
That favors immediate memory visibility; adopting it locally would require
handling prefix-cache invalidation whenever those blocks change.
Source: [Letta SDK memory and sleep-time agents](https://docs.letta.com/api/typescript).

Remote checkpointing has a different shape. After a remote checkpoint is
validated and before the next ordinary model request, adopt new rendered
memory with the accepted transcript. Keep the old memory if checkpointing
fails. `Libraries/RemoteAPI` should accept host-supplied prompt refresh data
through an explicit checkpoint boundary; it should not learn about `.localc`
paths or read project files itself. The current `RemoteAgent.systemPrompt` is
immutable, so this is a real API change, not existing behavior to rely on.

The existing history contract still determines whether a result stores an
incremental continuation or a full checkpoint. Memory text is not copied into
the history database as a second source of truth. Token-based context-cache
keys must include the changed system token prefix through their normal token
hashing; never reuse a KV state solely because the project/thread ID matches.

There is no special pre-compaction "save memory now" user message. The
foreground tool and post-turn reviewer are the extraction paths. Compaction
refreshes facts already saved to files; it does not guarantee that every
durable fact in the discarded context was extracted first.

## 10. Foreground memory behavior

The foreground agent can save memory during ordinary work. It should prefer
a write when the user explicitly asks to remember something or corrects a
durable misunderstanding. It can also save a stable project observation when
doing so is likely to avoid repeated investigation.

Example trajectory:

```text
SYSTEM: existing instructions and frozen project memory
USER: For this project, I want both memory files under .localc.
ASSISTANT: memory(target="memory", action="append", content="Both memory files belong under this project's .localc directory.")
TOOL: Appended to .localc/MEMORY.md.
      (Usage and complete current contents follow as plaintext.)
ASSISTANT: Both files will live in this project's .localc directory.
```

No second extraction model is involved. The memory tool validates the file
operation; the foreground model decides which fact deserves persistence.

The policy is useful discretion, not a requirement to write after every user
message. Avoid turning the current task into a profile just because the
model completed something. A single preference about one answer stays in
the current turn unless the user makes its durability clear.

For an explicit "remember this" request, a file write happens in the
foreground without waiting for the periodic reviewer. If it fails, the
assistant reports the failure and does not imply that the fact was saved.
For opportunistic writes, failure should not derail otherwise successful
project work; the assistant may retry with a smaller entry or leave
the fact in conversation history.

The examples in this section use the dedicated tool. Existing file
tools can provide these foreground writes instead if selected.

Use the existing tool-call presentation for foreground writes, including a
short subtitle identifying the target, such as "Updating project memory" or
"Updating project user notes." The tool result is part of the ordinary tool
exchange. A separate approval prompt is not part of this draft.

## 11. Post-turn review using the same agent

### Execution sequence

Finish the active user task, retain its completed context/KV state, and borrow
that same agent for a temporary review ask. Review may append temporary
messages and cache entries, but it does not commit a new conversation turn.

```text
Real user prompt
    ↓
ask(realUserPrompt)
    ↓
stream and save the normal assistant answer
    ↓
if review is eligible and no real user work is queued:
    capture the position BEFORE the review user message
    disable compaction and conversation persistence for review
    if the thread is displayed, show a transient assistant item headed "Reviewing Memory..."
    ↓
codeAgent.ask(reviewPrompt, temporary: true, ...) on the same KV buffers
    ↓
read current memory files; edit them if useful
continue any tool exchanges with compaction still disabled
    ↓
stream assistant review feedback into that item
    ↓
settle tool/GPU work; restore the captured position and prefix state
discard ALL review messages and continuation output
    ↓
remove the transient review UI; reenable ordinary turn behavior
next real user ask reuses the existing prefix KV
```

The saved position is after the completed user-task answer and before any
review framing, internal user text, or review assistant tokens. It is not the
beginning of the original user task, nor the beginning of the final review
model call after tool execution.

### General temporary ask API

Implementation status: `CodeAgent.ask` and both local backends now support
`temporary: Bool`. The concrete agents default to false, and the scheduler
continues to pass false for ordinary turns. Temporary calls support in-memory
pause/resume and restore before returning a terminal result. Hibernation
cancels them instead of saving them. The local workflow now schedules reviews
every ten completed user turns, with only the memory tool allowed and separate
assistant feedback. Ordinary returned logs remain unchanged; the workflow
does not persist review output.

Verified with the Local Code iOS app build and the DS4
`AgentSchedulerHarness --scenario temporary` regression: completion, tool wait,
pause/resume/abort, hibernation, full returned results without durable suspension,
and a subsequent normal answer/result log matching the baseline while reusing prefix KV.
The Qwen backend was compiled but has not had model-backed validation in this
implementation pass.

Extend `CodeAgent.ask` with `temporary: Bool`. The model/agent execution owns
capturing and restoring context; the caller supplies the prompt and chooses
whether that ask should commit conversation state. There is one ask engine
and no separate `review()` public API.

An illustrative protocol signature, following the current argument surface:

```swift
func ask(
  _ prompt: String, isMemoryEnabled: Bool, temporary: Bool,
  allowedTools: Set<ToolsRegistry.Tool>?, threadId: Int64,
  projectPath: String?, workspacePath: String?,
  webSearchProvider: WebSearchProvider,
  progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
) -> CodeAgentResult
```

Normal call sites pass `temporary: false`. Memory review passes
`temporary: true` with its internal review prompt. Keep this explicit in the
protocol/call-site integration; a convenience default is optional, while the
ordinary behavior remains false.

```swift
// Existing user-task behavior.
codeAgent.ask(userPrompt, isMemoryEnabled: isMemoryEnabled, temporary: false, /* existing context/progress */)

// Same execution engine, with temporary context and agent-owned restoration.
codeAgent.ask(memoryReviewPrompt, isMemoryEnabled: true, temporary: true, /* existing context/progress */)
```

These calls illustrate the distinction rather than compilable complete call
sites. Apply the explicit memory setting first, then establish temporary state
before the remaining ask startup code. A setting change belongs to the next
ask's starting context; temporary restoration returns to that context. Within
the temporary operation, disable compaction and automatic prompt refresh.
The flag belongs to this execution; do not expose it as a mutable global or
agent setting that callers must remember to undo.

`temporary` has a specific engine-level meaning:

| `temporary: false` | `temporary: true` |
| --- | --- |
| Ordinary continuation behavior | Temporary suffix restored away on terminal completion |
| Normal compaction and refresh policy | Conversation compaction and automatic prompt refresh disabled for the entire ask/tool loop; no additional capacity policy |
| Normal result eligible for continuation persistence | Full result returned; caller decides whether to persist it; no durable temporary suspension |
| Tool-result preview/externalization | Same ordinary tool-result processing |
| Token-prefix KV cache reads/writes | Same cache reads/writes; entries can remain after restoration |
| Ordinary pause/resume | Pause/resume retains temporary mode and its original restore point |
| Existing KV execution | Reuse prefix KV in place; retain only necessary overwritten-state backups |

The flag does not select a review prompt, hide a user message, add a
`Reviewing Memory...` header, schedule another ask, or choose tool permissions.
Those are memory-review workflow decisions. `ChatWorkflow` tracks which agents
are reviewing memory for presentation and completion handling. The scheduler
has no review-purpose field. Only the agent owns KV positions, backup lifetime,
and terminal restoration.

Use `isCompactionDisabled` explicitly at conversation-compaction entry points.
Its value is derived from temporary execution and retained through the agent's
restore state across pause/resume. Do not add temporary-only input admission,
output-reserve checks, or decode cutoffs when compaction is disabled. Normal
generation behavior and working-state/result updates continue unchanged.

In particular, temporary context does not imply read-only execution or undo
external side effects. A completed file write remains completed. Memory
review separately restricts tools to the two memory files; another temporary
use may have a different permitted tool set.

### Future /btw and /sidechat uses

The same flag can support an optional question beside the current task:
borrow the current context, answer using the existing cache, then resume the
main conversation at its original position. Its prompt and feedback may both
be visible even though they are not retained in the main model continuation.
Visibility is independent of `temporary`.

`/btw` and `/sidechat` are not currently supported. This document does not add
those commands, prescribe their UI, or decide their tool permissions. It
keeps the engine API general enough for them. If a future side conversation
needs its own lasting history or concurrent inference, that requires additional
product/cache work; the boolean alone does not provide it.

The first implementation admits only one active or suspended ask per agent.
Do not start a second temporary ask while the first is suspended, and do not
nest them. A future command handler must go through the same scheduler and
respect that ownership boundary.

### Suspension carries the temporary contract

The current local agents can return from `ask` while paused, retain a
`SuspensionState`, and later continue through `resume`. Therefore a temporary
ask cannot rely on a stack-local saved position and unconditional `defer`:
that defer would rewind the context on a cooperative yield while the execution
is still in progress.

Keep the original restore point as a private property on each concrete agent,
outside its serializable `SuspensionState`. The same agent survives an in-memory
pause, so the restore point remains available to `resume`. Its presence also
encodes the mode:

```swift
// Stored on each concrete agent.
private var suspensionState: SuspensionState?
private var temporaryState: TemporaryState?
```

This keeps runtime tensor snapshots out of `Codable` entirely. `SuspensionState`
uses synthesized encoding/decoding without a custom `CodingKeys` list.

`TemporaryState` is execution-local restoration data. It contains the original
token/cache position, counters/reminder state, and ownership of the limited
mutable-state backups described below. Each model keeps fields appropriate
to its own cache layout. The public boolean selects whether to initialize
this property; it stays set across suspension/resume and is cleared after
terminal restoration, including hibernation cancellation.

Retain a single outer restore point for the entire temporary ask, including
all tool rounds. Do not take a new one after each tool response or resume.
Tensor backups remain owned while suspended; temporary locals in the initial
call are insufficient. There is no need for a `review`-specific snapshot type
when these requirements apply equally to other temporary uses.

| Event | Temporary state and restoration |
| --- | --- |
| `ask(..., temporary: true)` starts | Require no active/suspended ask; capture original state once before appending the temporary message |
| Tool wait or cooperative pause | Retain `temporaryState` and temporary suffix; return progress without resetting |
| `resume(...)` | Continue the same operation and inherited mode; no new boolean or recaptured boundary is needed |
| Further tool rounds/pauses | Keep the original restore point and compaction suppression |
| Normal completion | Settle work, restore once, clear temporary state, then report terminal completion |
| Stop or failure | Use the same restoration path; completed external side effects remain |
| Next normal `ask(..., temporary: false)` | Admit after restoration with no temporary suffix or mode left over |

Conversation compaction checks use `isCompactionDisabled`. Prompt refresh and
suspension-record writes/removal consult the agent's `temporaryState`, including
branches reached only through `resume`. Ordinary result construction and tool
output processing do not depend on temporary mode. Tool permissions and whether
to persist the returned result belong to the caller's policy, which must also
survive suspension. A wrapper-local boolean lost on the initial method return
is insufficient.

Reuse the existing scheduler distinction between pause and completion. A
returned partial `CodeAgentResult` is not evidence that the temporary ask
finished. Terminal restoration belongs in the state machine's common finish
path before the scheduler admits the next ask. Keep restoration exactly once,
and keep its state alive until tool/GPU writes settle.

If initialization fails before the suspended state is installed, the entry
path must restore anything already changed. If the operation pauses, it must
not perform that cleanup. These are distinct exits from the public call.

Return the ordinary `CodeAgentResult`, including its `logTokens`; temporary
execution does not filter result fields. The memory-review caller avoids the
normal history-write path and discards the returned continuation data after
using the feedback. It also prevents visible review output from being converted
back into model input by another code path. The agent independently restores
its original context and skips durable suspension writes.

### Cooperative suspension versus disk hibernation

Temporary mode and the restore point must survive in-memory pause/resume on
the agent. Persisting a temporary ask across process termination is a separate
optional feature.
Current suspension structs are `Codable`, but runtime tensor backups do not
belong in the ordinary conversation suspension payload by default.

For the initial policy, allow cooperative pause/resume but cancel and restore
a temporary ask before hibernation saves the user's thread or releases its
model. Keep runtime backups in the agent's private `temporaryState` property.
Guard the suspension persistence entry point before encoding: keeping
snapshots outside the payload alone does not prevent saving the temporary
conversation suffix as a normal user turn.

If durable temporary suspension is added later, encode the mode and enough
original-boundary state to restore correctly, including non-token backups or
a defined reconstruction source. Older ordinary suspension payloads decode
as non-temporary. A payload marked temporary but missing a usable restore point
must not resume as normal work. No new durable format is required for the
current memory-review flow.

Only one execution owns the agent at a time. Start review after the preceding
ask and its completed-answer persistence finish. Start another real ask only
after review has restored the pre-review state, including on Stop or failure.

For remote providers, preserve the same temporary context semantics by saving
and restoring the local request/transcript state. Do not claim client control
of provider-owned KV. A provider conversation/response identifier advanced by
review must not become the continuation identifier of the next real user turn.
The local KV savings are the primary reason for this execution design.

### Eligibility and cadence

The app-wide workspace dictionary stores `is_memory_enabled` as a Bool, defaulting
to true when absent. Settings presents a Memory section with an Enable switch and
localized title/detail, using the same `SettingsSwitchItem` layout as Draw Things.
The section is shown for local models. `SettingsWorkflow` writes the dictionary
from the toggle callback and observes it to update the displayed value.

The settings detail reads: "Remember your preferences and useful details about
each project, so you don't have to repeat yourself in future conversations."
This follows the user-facing emphasis in [Hermes's memory overview](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory/)
on remembering preferences/projects and [Qwen's auto-memory introduction](https://qwenlm.github.io/qwen-code-docs/en/users/features/memory/)
on avoiding repeated explanations. The UI explains the benefit; storage and
review cadence remain implementation details documented here.

Disabling memory stops new review scheduling and excludes the memory tool from
new ordinary asks. Already-running asks retain their tool policy. Memory files
are retained. At agent construction, the caller reads the setting once and passes
a plain `MemoryContext`: loaded from the project when enabled, otherwise `.empty`.
Each subsequent `ask` receives `isMemoryEnabled` as an explicit Bool. The agent
compares it with `!memoryContext.isEmpty`; a change loads current files when
enabling or clears the context when disabling. An unchanged value reuses the
snapshot without reading disk. Loaded empty files have `(empty)` placeholders,
so they still represent enabled memory. The setting is applied before a temporary
ask captures its restore point. Successful semantic compaction rereads files only
when the retained context indicates memory is enabled. Suspension/resume keeps
that context; there is no provider closure or separately persisted setting.
Review eligibility checks the workspace setting; the review ask loads memory if
needed. `CodeAgent` does not expose its internal memory-context state.

`ProjectMemory.memoryReviewInterval` sets the cadence to ten completed user turns
per conversation. Persist
`turnCountSinceLastReview` on `ProjectThread`, updated through
`ProjectHistoryManager`. Increment it alongside persistence of a successfully
completed ordinary user turn, in the same transaction, even when memory is
disabled or the agent has no memory context. A count of ten or more
means review is due. Queued user work defers review without clearing the count;
a completed review, including "Nothing to save", resets it. A stopped review
halves the current count using integer division, including when its result is
empty. A finished review with an empty result leaves the count unchanged.
Review itself never advances it.

The count belongs to the existing persisted thread object, so agent eviction,
model replacement, view recreation, and process restart do not lose it. Do not
introduce a separate memory-review object to own this state, or infer it from
assistant-history length modulo ten. The workflow reads the persisted field
instead of retaining its own counter. The appended FlatBuffers field defaults
to zero for existing threads; historical turns are not backfilled.

`appendAssistant(..., incrementTurnCountSinceLastReview: true)` increments the
field in the same transaction as the assistant node. The local completion path
passes true for a successfully completed turn, independently of memory settings
or the presence of memory context. Skipping or deferring review does not pause or
reset the count; other history writes leave it unchanged. Review completion uses
`setThreadTurnCountSinceLastReview(id:turnCountSinceLastReview:)` with zero for
a finished, nonempty result or half the current count for a stopped review.
The setter updates only the counter and preserves thread recency and transcript history.

The location of the post-turn scheduling decision remains under discussion.
That is separate from counter ownership: it reads the thread's persisted count
and submits an ordinary temporary ask when eligible. `ChatWorkflow` continues
to own presentation; no memory-specific scheduling priority is introduced.

The post-turn check should require:

- The completed turn was a real user task, not a memory review, compaction
  bridge, tool continuation, or other internal turn.
- The user task completed successfully; review does not follow a Stop action
  or an interrupted generation automatically.
- The normal answer has been finalized before its review item is created.
- No real user request for this conversation is already pending.
- The project still exists and the selected agent can access its memory files.

A review completion never triggers another review. The scheduler uses ordinary
foreground priority, pause/resume, and Stop behavior for all asks. A review does
not require every other conversation to be idle, and a foreground change does
not automatically cancel it. `ChatWorkflow` owns the review presentation state.
New input in that conversation uses the normal queue. The user can explicitly
press Stop to cancel review. Hibernation cancels temporary asks because they
cannot be persisted; this behavior depends only on `temporary`, not on memory review.

Review eligibility does not depend on whether the thread is displayed. Both
foreground and background user-turn completion paths process queued user work
first, then attempt review before releasing the agent. The review must use the
current scheduler; a retiring scheduler receives no new asks. Only the visible
thread's input state and feedback row are updated. Opening a running background
review shows its transient row; completion removes that row if it is displayed.
New asks clear the scheduler's cached progress from the previous turn so a queued
review cannot display the preceding answer as review feedback.

If different scheduling priorities become useful later, introduce general QoS
support: most user work would use `userInitiated`, and memory review could use
`utility` or `background`. QoS would express scheduling priority independently
of temporary context, tool permissions, and review presentation. Keep ordinary
scheduling for this draft; no QoS API or memory-specific priority policy is needed now.

Skip/defer review when the user has already queued more work. Reconsider it
after that real work completes. The persisted count already records that review
is due; no separate pending flag, review cursor, or project-wide periodic worker
is needed. Do not create a retry loop after review failure or keep the app/CLI
alive merely to finish maintenance.

### What the next ask sees

The model already has the conversation it just participated in. Append a
synthetic user-role request identifying this as internal memory review, then
let it read the current `.localc/USER.md` and `.localc/MEMORY.md`. That fresh
read matters because the files may differ from the frozen system-prompt copy.
An empty file, a missing file, and a read error must remain distinguishable.

Use normal complete tool exchanges. Review calls the dedicated memory tool;
its per-ask allowlist is retained across suspension, and the agents reject
other tool calls before dispatch. A write must succeed before the assistant
claims something was saved.

Do not concatenate all historical roles into a new summary just to issue
review. Do not rerun skill selection on the synthetic review text as if the
user had requested a new coding task. The internal prompt explicitly limits
review to memory maintenance.

### Conversation compaction is disabled for the whole review

The review policy begins before the internal message is appended and ends
only after restoration. It applies to the first ask, every tool call/result,
subsequent model calls, and any automatic work at review completion.

During this interval, disable:

- low/high-effort deterministic rewriting of the conversation prefix;
- semantic handoff/checkpoint generation and bridge messages;
- automatic memory/system-prompt refresh tied to checkpointing;
- post-response compaction and capacity-recovery retries that compact context.

Tool-result preview/externalization continues normally. Although some existing
helpers call this "compaction," they prepare a new tool response rather than
rewrite the retained conversation. Their behavior does not depend on
`isCompactionDisabled` or `temporaryState`.

Disabling conversation compaction also means not enforcing an additional
agent-level capacity policy. Do not reject a temporary ask because it lacks a
reserved output budget, stop decoding at an added context threshold, or add a
review-specific suffix allowance. The generator continues with its ordinary
behavior. Restore the original state whenever the ask terminates.

Review token accumulation must not advance normal counters such as
`tokensSinceLastCompact` after restoration. Neither a synthetic review prompt
nor its file results should cause the next real turn to compact earlier.

### Why serialize: KV memory usage

The intended memory shape is one active prefix plus the temporary review
suffix. The current fork approach duplicates KV states, even when both
conversations initially have identical text. Serial execution avoids keeping
a second copy of the large prefix cache for an occasional maintenance pass.

```text
Before review:       [ completed task prefix P ]
During review:       [ completed task prefix P ][ temporary review suffix R ]
After restoration:   [ completed task prefix P ]
Next real turn:      [ completed task prefix P ][ new user turn U ... ]
```

The storage used for `R` can become spare capacity reused by the next turn.
Logical truncation need not zero or deallocate it; no attention mask, position,
length, or state may let the next turn read stale review data.

Conceptually, peak memory is the active KV allocation, any required growth
for the review suffix, and limited backup of state that review would overwrite.
It is not two independent full prefix KV allocations. Buffer growth may have
its own transient allocation cost, which should be measured. Merely executing
two separately allocated agents one after another would not realize the same
saving.

A radix-tree or similar shared-prefix KV manager could make future forks share
prefix storage. That is not implemented in the current design and is not
required here. Use serial temporary review with explicit restoration now.

### What must be restored

Capture cheap continuation metadata and the model-specific state needed to
return to the pre-review position. Do not deep-copy the whole KV cache.

| State | Restoration requirement |
| --- | --- |
| Conversation tokens/messages | Remove everything beginning at the saved review-message boundary |
| System prompt and settings | Keep the original rendered memory, system tokens, reasoning configuration, and tool schema |
| Logical and evaluated lengths | Restore the actual saved token/cache offsets; never claim unevaluated tokens are cached |
| Prefix KV entries | Keep existing backing storage and valid prefix rows; review suffix rows become unused |
| Mutable recurrent/window state | Preserve and restore only the state review overwrites |
| Draft/speculative state | Restore boundary state or reset only affected draft state through a defined backend path |
| Parsers and tool execution | Drop review-only parser/output state; wait for or cancel dispatched work before reuse |
| Compaction/reminder counters | Restore the pre-review values and pending ordinary-turn behavior |
| Continuation logs | Do not commit any review `logTokens`, `log_plaintext`, or checkpoint |
| Memory files | Retain actual successful file writes; they are the intended persistent effect |
| Review UI | Finish independently of restored model context |

Record both the logical message boundary and actual evaluated-cache position.
If normal execution has a pending final token that has not yet been evaluated,
retain that distinction or materialize the normal tail before taking the
review boundary. Moving a length field alone must not advertise missing KV
rows as valid. No full-prefix prefill is needed when the retained prefix state
is valid and only an ordinary short pending tail needs evaluation.

A Swift array or struct copy containing tensor references does not necessarily
protect mutable tensor contents. Preserve overwritten state with actual copies
of the affected tensors/slices, while continuing to share the large prefix KV
buffers in place. Settle GPU writes before restoring or releasing those copies.

### Current backend details to verify

The restoration contract is simple, but the current caches contain more than
append-only attention rows:

- Qwen 3.5 has ordinary attention KV plus convolution and recurrent state for
  linear-attention layers. `updateLinearCaches` in
  [`Qwen3_5TextGenerator.swift`](../Sources/Models/Qwen3_5TextGenerator.swift)
  updates those state tensors in place. Retain their boundary values; rewinding
  the token index alone cannot undo those updates. Handle MTP/draft state too.
- DeepSeek 4's
  [`KVCache`](../Sources/Models/DeepSeek4TextGenerator.swift) has raw/compressed
  KV, compressor input state, indexer KV, and several lengths. Its
  `compactCachesIfNeeded` moves raw-window and compressor-input contents even
  without a conversation checkpoint. Preserve the bounded windows and any
  boundary rows that can be overwritten, then restore their positions/lengths.
  Disabling conversation compaction alone does not disable these storage moves.
- Both code agents currently clear caches when expected offsets disagree, and
  some Stop paths clear them as well. Review restoration must put offsets and
  backing state back consistently before the next ask. Do not route successful
  restoration through a general `resetSuspensionCaches` or whole-KV reset.

These are requirements for implementing the user's proposed reuse, not reasons
to switch back to a full fork. Prefer bounded model-state preservation over
copying all KV tensors. Test review lengths that cross storage-page, compression,
and speculative-decoding boundaries so short successful examples do not hide
state-restoration errors.

On every exit, including model error, capacity exhaustion, cancelled tools,
and Stop, restore from the same outer boundary. If a backend cannot establish
valid preserved state after an exceptional failure, clear/rebuild safely and
report that fallback in diagnostics; never reuse uncertain KV. Such recovery
is a fallback, not the normal memory/performance path or a claimed success of
KV restoration.

## 12. Review presentation, prompt, and history

### User-visible presentation

While review is running in the displayed thread, the user-facing sequence is:

```text
USER
Please use detailed explanations for design discussions in this project.

ASSISTANT
I will include the implementation details and tradeoffs when discussing designs.

ASSISTANT — memory review
Reviewing Memory...
---
Saved your preference for detailed design explanations in .localc/USER.md.
```

The app does not show a user bubble containing the internal review request.
Only the new assistant feedback item is visible for that follow-up ask.
Remove this entire item when review finishes, stops, or fails. The completed
user-task answer stays in place; no "review finished" or "review stopped" message
replaces the temporary item. Background review does not append a row to another
thread's visible conversation.

The host owns the localized `Reviewing Memory...` label and separator. Show the
label alone as soon as review begins, before the model emits text. Add the
separator when tool activity or assistant feedback is nonempty, and preserve
the original completed task answer above. The model
does not have to generate the heading correctly, and the heading is not
prepended to model context or raw generated tokens.

With no tool activity or assistant text, render exactly the localized label,
including its ellipsis, without a divider or trailing newlines. With content,
render `label + "\n---\n" + content`. Whitespace-only assistant output counts as
empty. The same label is used for initial display, prefill, and reopening an
active background review.

Use the existing assistant streaming/tool-feedback components within that
item. Do not expose the hidden prompt through a transient placeholder, queued
prompt preview, retry bubble, or restored user message. This rule concerns UI
presentation; the internal request exists only in the temporary review context
and is removed at restoration.

During review, stream assistant text and tool progress under the heading. Only
report confirmed writes, and do not dump the entire memory file into feedback by
default. Completion removes the row regardless of the result or whether any
write succeeded. It does not generate fallback status text. Successfully saved
files remain on disk after the row disappears.

The exact collapse behavior, animation, and whether tool details start
expanded remain UI choices. The heading, hidden user prompt, separate assistant
item, and visible progress are the current discussion direction.

### Internal review prompt

The [comparative study's review prompt](MemoryPromptStudy.md#4-temporary-review-prompt)
records the implemented text for the dedicated memory tool. The revised questions
follow Hermes's focus: personal details and preferences for USER, and expectations
about assistant behavior and working style for MEMORY. This replaced the broader
project-facts question after an off-target result in a conversation. The reviewer
reads both current files, makes worthwhile changes, and briefly reports the result. The combined Memory
section supplies general policy; the tool contract supplies editing rules
and specific failure handling.

The review uses the conversation already in context; ten completed turns is
the scheduling threshold, not a promise that all ten turns remain verbatim
after earlier compaction. Never save the synthetic review instruction as a
new durable user expectation. The app supplies the review heading.

The combined memory section supplies the general policy and file budgets;
the tool schema supplies operation semantics. Keep host execution scoped to
`memory` through `allowedTools`. Broader tools do not execute during review,
although their schemas remain in the frozen prompt. This does not require
rewriting the prompt to hide tools or enabling generic edits to `.localc`.

`ProjectMemory.reviewPrompt` includes comments linking the Hermes sources and
explaining the two-file adaptation. The study retains the comparison and the
DS4/Qwen inference fixtures still needed to evaluate memory quality.

### Persistence versus display

Review context and its UI row are temporary. The context is removed when the
saved pre-review boundary is restored; the completion handler removes the row.
No finished or stopped review feedback remains visible or returns on reopening.

| Representation | Review behavior |
| --- | --- |
| Live UI during review | Transient assistant feedback under `Reviewing Memory...` when displayed; internal prompt hidden |
| UI after review | Review row removed on success, Stop, or failure; original answer preserved |
| Model context during review | Temporary internal user request plus review assistant/tool exchanges |
| Model context after review | Exactly the pre-review continuation; no review suffix |
| Persistent continuation logs | No review prompt, tool exchange, answer, or checkpoint |
| Memory files | Facts successfully saved remain on disk |

Do not pass review completion through the normal `appendAssistant` persistence
path with its `logTokens` or `log_plaintext`. The ordinary ask result can be
used to render feedback, but the review suffix must be discarded. Do not retain
an orphaned tool result, assistant answer, or synthetic request in the normal
conversation log.

Do not add a persisted review-feedback record or history schema. The view removes
only the trailing transient assistant item, preserving completed messages and
their identities. If the user has switched away, there is no review row to remove
from the currently displayed thread.

Derive the heading from the workflow/display purpose rather than generated
prose. Never prepend host UI decorations to model tokens. Review does not
advance the real user-turn cadence, edit lineage, or conversation continuation
checkpoint. Review does not create completion notifications or unread feedback;
the ordinary user-task answer retains its existing notification/unread behavior.

A process exit during review restores the last completed real conversation
from its ordinary logs. Do not persist the temporary review suspension over
that conversation's recovery state. Successfully saved memory files remain
saved, even if feedback did not finish displaying before exit.

## 13. New input, stopping, and concurrent edits

### Incoming user work

A new real user request uses the ordinary busy-agent queue:

1. Keep the new user input queued as real user work.
2. Let the current review finish. Sending a message does not request Stop or
   change the review's UI state. The user can explicitly press Stop to cancel it.
3. Wait for current tool/GPU work to settle, then restore the saved pre-review
   position and model-specific state.
4. Remove any visible review row, then issue the queued real user
   `ask` against the original continuation and reusable prefix KV.

Do not call `ask` twice concurrently on one agent. Do not discard a suspended
review's state and immediately reuse its mutable caches for a new request.
Use the outer review restoration path after cancellation. No synthetic closing
message or assistant bridge has to be committed to make the discarded suffix
valid. The next real ask only needs the intact original prefix. Keep the
workflow's review state until its completion handler runs, so feedback stays
on the display-only path. The agent's temporary state owns compaction disabling
and context restoration.

If real work is already queued when the active task finishes, skip the review
ask entirely. If the user presses Stop during review, stop review and do not
immediately schedule it again. A stopped review halves `turnCountSinceLastReview`
using integer division, even if some writes completed or the result is empty.
For example, ten becomes five, and the next completed answer advances it to six.
A finished, nonempty review result resets the count to zero. Review is revisited
only at a later eligible real-turn boundary.

A completed file write is not undone merely because review was stopped later.
A cancelled model request is not evidence that a dispatched file operation
failed. Base feedback on actual operation completion and prevent late writes
through the review execution gate.

### Concurrent project edits

Sequential review removes same-conversation overlap. Other conversations,
manual editors, and processes can still change the project-local files.
Read current contents immediately before editing, use the selected tool's
stale-edit/matching checks, and keep atomic replacement for each successful
write. Do not replace a whole file using only an old system-prompt copy.

With the dedicated memory tool, the lock-and-reread behavior in section 6
applies. With file tools, use the existing read/tag or unique-old-text edit
flow; a whole-file `write` needs a current-content check in its memory-file
path to avoid overwriting unrelated changes since the read. A failed stale
edit should trigger a fresh read or stop the review, not a blind retry.

The earlier detached-review design proposed comparing both files against a
review-wide snapshot before every write. That is no longer required as a
separate background-review mechanism. Any stronger concurrent-edit guarantees
should be implemented in the chosen file-writing path and reused consistently.

### Bounded maintenance

The generator retains its ordinary behavior while conversation compaction is
disabled; temporary execution adds no capacity policy. The calling review
workflow should stop after the model reports changes or no changes. Any
additional time or tool-round budget belongs to that workflow and remains a
tuning question; the earlier four-request/60-second defaults were provisional
and should not prevent a slow local model from completing a simple review.

Stop, new-user priority, no recursive reviews, and no unrelated file/tool work
are required behavior. These controls belong to the workflow/dispatch path
that already owns the ask. A separately scheduled reviewer service is not
necessary for this proposal.

## 14. Concrete Swift integration

### File logic

The Foundation-based `Sources/Agent/ProjectMemory.swift` contains:

- `ProjectMemory.Target` (`user`, `memory`) defining the fixed filename and budget;
- synchronous read/parse/serialize/update functions;
- dedicated errors and plaintext tool-response formatting.

`Sources/Agent/MemoryContext.swift` owns the frozen context value, file loading,
deterministic rendering, and `emitSections`. File mutations remain independent
of the active context value.

`Sources/Agent/MemoryTool.swift` validates the existing `ToolCall.Request`
arguments, selects a read or mutation, and returns plaintext through the normal
tool completion callback. There is no separate mutation model or response encoder.

These are file utilities. Do not introduce a long-lived `MemoryStore`, shared
mutable entry cache, database target, or queue-owning manager just to hold
the two strings. Small value types for parsing results and operation arguments
are fine where they prevent duplicated logic.

Keep threading with existing callers. The synchronous utility acquires a
bounded file lock and returns/throws. A `MemoryTool` adapter can fit the
existing `invoke(completion:)` convention and execute the operation through
the tool execution owner's executor. Do not simulate synchronous file calls
using semaphores or create an independent dispatch hierarchy inside utilities.

### Tool registration and argument transport

This subsection describes the dedicated `memory` tool used by the first draft.
With existing file tools, keep their schemas and implement the narrow
metadata-write exception and validation path instead.

| Source | Required integration |
| --- | --- |
| [`ToolsRegistry.swift`](../Sources/Agent/ToolsRegistry.swift) | Add `memory` to `Tool`, `toolType`, `Invocation`, `tool`, `subtitle`, `invoke`, and `parse` |
| [`SystemPrompt.swift`](../Sources/Agent/SystemPrompt.swift) | Add the schema and stable guidance to the supported local model prompt/tool surfaces |
| [`RemoteToolSchema.swift`](../Sources/RemoteAPI/RemoteToolSchema.swift) | Add the native remote function schema; keep its registry-alignment precondition valid |
| [`RemoteToolsBridge.swift`](../Sources/RemoteAPI/RemoteToolsBridge.swift) | Reuse string argument transport; preserve omitted action as read and reject invalid supplied values; return plaintext memory results and errors |
| [`Qwen3_5ToolCallParser.swift`](../Sources/Agent/Qwen3_5ToolCallParser.swift) | Verify optional action and string arguments survive the model-specific grammar and partial parsing |
| [`DeepSeek4ToolCallParser.swift`](../Sources/Agent/DeepSeek4ToolCallParser.swift) | Verify the same arguments through DSML string parameters |
| [`ToolCallParser.swift`](../Sources/Agent/ToolCallParser.swift) | Reuse `ToolCall.Request.Parameter(string: true, value: text)` for all supplied memory arguments |

The flat string arguments fit the existing local parsers and remote bridge;
there is no array/object transport extension for this API. Define `target`
as required and `action` as optional in each schema. Validate required and
forbidden fields for each action in the common memory parser. Missing action
must reach it as an omitted parameter, with no injected mutation default.

The remote bridge currently drops null-valued parameters. For `memory`, reject
supplied non-string values before that conversion so `action: null` cannot
accidentally turn into a read. Keep this validation scoped to the memory schema.
An unknown action or invalid field combination also returns a plaintext error.
The bridge's existing JSON error helper must not wrap memory argument failures
in a JSON response; use the same plaintext convention for these failures as
for errors during memory execution. Remote error metadata can still accompany
the text without changing the model-facing body.

Use the existing `invoke(completion:)` string result for plaintext output;
there is no response JSON encoder. Test quotes, newlines, Unicode, and tool
syntax delimiters inside entry text, plus omitted action on both DS4 and Qwen.
Keep the exposed arguments and plaintext result conventions identical across
local and remote models. Transport serialization may escape a result string
on the wire; the tool-message body seen by the model remains ordinary text.

### Prompt construction and refresh

| Source | Required integration |
| --- | --- |
| [`ChatWorkflow+TranscriptConversion.swift`](../Sources/Chat/ChatWorkflow+TranscriptConversion.swift) | Capture project memory when constructing local agents, alongside project/environment inputs |
| [`Qwen3_5CodeAgent.swift`](../Sources/Agent/Qwen3_5CodeAgent.swift) | Render safe memory sections; apply the memory setting at ask entry, retain the block through suspension, and refresh on accepted compaction |
| [`DeepSeek4CodeAgent.swift`](../Sources/Agent/DeepSeek4CodeAgent.swift) | Include memory after project context in the existing user-role reminder; update it for memory-setting changes and accepted compaction, and retain it through suspension |
| [`SystemPromptTokenization.swift`](../Sources/Agent/SystemPromptTokenization.swift) | Reuse the existing special-token boundary handling |
| [`SystemPromptTemplate.swift`](../Sources/Agent/SystemPromptTemplate.swift) | Preserve editable-template behavior and diagnose missing/duplicate memory placeholders |
| [`RemoteSystemPrompt.swift`](../Sources/RemoteAPI/RemoteSystemPrompt.swift) | Add memory rendering to remote prompt construction |
| [`RemoteChatProvider.swift`](../Sources/RemoteAPI/RemoteChatProvider.swift) | Capture a block at actual agent creation; coordinate safe refresh and preserve it on reuse |
| [`RemoteAgent.swift`](../../../Libraries/RemoteAPI/Sources/RemoteAgent.swift) | Add an explicit host-supplied refresh boundary for accepted semantic checkpoints |

`RemoteChatProvider.prepare` currently constructs environment context when
deciding whether an agent can be reused. Do not put freshly read memory into
that equality comparison on every ordinary prepare call; that would rebuild
the agent whenever a file changes and violate the frozen-prompt contract.
Reuse the existing agent's captured block until a defined refresh boundary.

Local reasoning-effort changes also rebuild system tokens. Use the same
retained memory block for those rebuilds. All prompt paths must respect the
same lifecycle, even if their underlying string/token assembly differs.

### Review wiring

Add `temporary: Bool` to the existing
[`CodeAgent.ask`](../Sources/Agent/CodeAgent.swift) protocol method and thread
it through scheduler dispatch and both local agents. Existing normal call
sites pass false; review supplies its internal prompt with true. The agent
owns restoration across ask/resume, while the workflow owns UI. Review cadence
belongs to the persisted thread; placement of the scheduling decision is open.

[`ChatWorkflow.swift`](../Sources/Chat/ChatWorkflow.swift) currently appends a
real user node and bubble before `scheduleLocalTurn`, then appends/persists the
assistant result in its completion path. Review uses the same agent execution,
but must bypass those ordinary input and continuation-persistence side effects.

For a review turn:

1. Finish and persist the normal real-user reply.
2. If the thread is displayed, append a transient assistant feedback item with
   the host's review label. Background review uses the same eligibility rules.
3. Schedule `codeAgent.ask(reviewPrompt, temporary: true, ...)` without a real
   user node or user bubble.
4. Inside the agent, capture the pre-review boundary and required overwritten
   state, then run ask with its temporary state installed.
5. Retain that state across all tool exchanges and cooperative suspensions;
   the scheduler continues them through the existing `resume(...)` entry point.
6. On terminal success, Stop, or failure, the agent settles work and restores
   the captured state before it reports completion.
7. The workflow removes any visible review row and drops review continuation output;
   successful file edits remain. It never performs a separate KV rewind.

Do not commit review through the existing `appendAssistant(logTokens: ...)`
branch. Do not call `scheduler.markAsCompleted` in a way that lets a queued
real ask reuse the agent before restoration finishes. Preserve the normal
answer's visible item and persistent checkpoint independently of review UI.

[`AgentScheduler.swift`](../Sources/Agent/AgentScheduler.swift) still serializes
execution on this agent. It carries the caller's temporary flag into initial
ask dispatch; `resume` inherits that state instead of defaulting back to false.
A yielded review keeps its workflow completion closure and presentation state.
Agent-owned restoration replaces any need for a second review agent or full
KV copy. Foreground work uses the normal cooperative pause/resume path. If
memory pressure requires releasing the model, resume a suspended temporary
ask for cancellation and completion before ordinary hibernation; do not leave
a cancelled ask marked resumable or save its suffix in the parent's suspension
record. This applies to every temporary ask.

Both local agents use `isCompactionDisabled` at conversation-compaction entry
points: ask startup, generation-triggered checkpoints, and post-response
cleanup. Keep normal tool-result processing, working-state updates, and returned
results. Add no capacity policy for disabled compaction. Carry the original
restore point in the agent's private `temporaryState` across pauses and tool waits. Cleanup runs
on terminal completion, not whenever `ask` or `resume` yields. Restore
original counters, system reminder flags, parser state, and cache lengths as
well as the message prefix. Audit cancellation paths that currently clear
caches so an otherwise valid review does not unnecessarily
throw away the parent's KV.

[`Qwen3_5TextGenerator.swift`](../Sources/Models/Qwen3_5TextGenerator.swift) and
[`DeepSeek4TextGenerator.swift`](../Sources/Models/DeepSeek4TextGenerator.swift)
need narrowly scoped state preservation/restoration where they update state
in place. Full-attention prefix rows remain in the same tensors. Handle
recurrent/window/compressor and draft boundary state explicitly. The existing
context-cache stores may help recover after exceptional failure, but writing
and reloading a full prefix checkpoint is not the intended review path.

Keep ordinary `ContextCache` reads and writes enabled during temporary asks.
KV entries are keyed by the model file name and exact token-prefix hash, so
entries created during review can remain on disk and be reused when that
prefix matches. They do not commit a conversation turn, and restoring the
agent's in-memory boundary does not require deleting them. Pass the ordinary
project path to the cache regardless of `temporaryState`.

The same store also holds a separate `suspension/<threadId>/state` record.
Continue suppressing writes/removal of that record during temporary execution:
it describes which conversation to resume, so saving the temporary suffix
there would overwrite the real conversation's recovery state. Temporary mode
affects conversation persistence, not the token-prefix cache.

The model-specific agents dispatch tools internally. Pass `allowedTools: [.memory]`
on the review ask so only memory operations execute. The allowlist remains in
suspension state; no review-purpose flag is passed to the agent. Reject late
calls once restoration begins. Restore normal permissions only after
review operations settle. The same constraints apply to the remote bridge.

For remote execution, stage the request/transcript changes as temporary and
disable every compaction/recovery path for the review tool loop. Restore the
original transcript, request linkage, and context accounting afterward. Use
the prior provider continuation identifier for the next real turn when one
exists. If a provider path cannot support that isolation, keep review disabled
for that path until an explicit implementation exists; do not silently retain
review in conversation history.

[`project_history.fbs`](../../../Libraries/ProjectHistoryManager/Sources/project_history.fbs)
does not need a new persisted model turn or feedback record for review. The
transient row exists only during execution and is removed at completion.

### CLI parity

Local Code CLI entry points with a selected project should use the same path,
format, and tool behavior. They read project memory at agent creation and
write through the same helper. The remote CLI needs the new remote prompt
input and tool schema too. Automatic review in a short-lived CLI process is
best-effort and must not keep the process alive after its user task completes.

This concerns Local Code agents. It does not change the image-generation
Draw Things CLI or its configuration files.

## 15. Walkthroughs and expected outcomes

### A. Starting a project without memory

1. Create a conversation with project root `/Projects/Example`.
2. Both paths are absent; render two empty target sections.
3. Continue the user's task normally.
4. No memory Markdown file is created until a non-empty successful mutation.

### B. Saving a preference, then starting another conversation

1. Conversation A starts with empty USER.
2. User expresses a durable preference for detailed design explanations.
3. A calls `memory(target: "user", action: "append", content: ...)`.
4. The file is written and the returned tool result contains the entry.
5. A's system tokens remain identical to their pre-write value.
6. Conversation B starts in the same project and loads the new entry.
7. A conversation in another project remains unaffected.

### C. Capacity and separate mutations

1. MEMORY is near 2,200 characters.
2. An append would exceed the limit; return a plaintext capacity error and
   leave the file unchanged.
3. The model replaces a verbose entry with a shorter complete entry. If that
   result fits, save the replacement atomically and return current contents.
4. The model appends the new fact in another call. Save it only if it fits.
5. If that append still fails, the earlier successful replacement remains.
   Each call owns its change; there is no rollback across calls.

### D. Old prompt, fresh edit

1. Conversation A's prompt contains entry X.
2. Conversation B replaces X with Y in the file.
3. A attempts to replace X using an old selector.
4. The tool rereads the file and returns a plaintext error saying no entry
   matches `old_text`, followed by current contents containing Y.
5. A reconsiders its intended edit using Y. No hidden fuzzy merge occurs.

### E. Memory update during compaction

1. Foreground saves entry Y while its prompt still contains X.
2. A semantic checkpoint starts with the old prompt.
3. After the handoff, the checkpoint stages memory containing Y.
4. Successful bridge completion adopts the new block.
5. If the bridge is cancelled, restore X with the old prefix for the current
   agent; Y remains correctly saved on disk for the next refresh.

### F. Temporary review and incoming real user work

1. An eligible active user turn finishes and its normal answer is saved.
2. Capture its message/cache position N; show the localized `Reviewing Memory...`
   label, adding a divider only when tool activity or assistant text is available.
3. Run the internal ask and its tool exchanges on the same KV allocation with
   compaction disabled. Temporary review tokens extend beyond N.
4. A new real user prompt arrives and stays queued while review continues.
5. When review finishes or the user explicitly presses Stop, settle in-flight
   work and restore N plus the required model-specific mutable state.
   Successful earlier writes remain; a stopped review halves the count.
6. Remove the review row, then ask the real user prompt using the existing prefix
   KV. Review text and tool results are absent from that model request.
7. The normal successful-review path performs the same restoration before
   returning to idle. Neither completion path recursively schedules review.

### G. Manually edited or broken file

1. A user edits USER in an external editor.
2. Existing agents keep their captured block until a refresh boundary.
3. On refresh, valid edits load. A malformed or over-budget target is marked
   unavailable; the file remains untouched for inspection.
4. MEMORY continues to load if it is valid.
5. A tool never reports a successful save after a parse, capacity, or write
   failure.

### H. Reopening after termination

1. The app terminates after a memory write succeeded.
2. Project history restores through its existing token/text continuation path.
3. The fresh agent reads current USER and MEMORY from that project.
4. Saved facts survive; review runs only at eligible turn boundaries; no
   separate review thread appears in the conversation list.

## 16. Verification plan for implementation

This document does not require running inference or building the app merely
to edit the design. The checks below are acceptance criteria for later code.

### File and tool tests

Action/target-specific cases apply to the dedicated tool. For
existing file tools, test their current edit semantics plus the narrow memory
path exception, chosen capacity/format checks, and stale-write handling.

Add focused tests using temporary project directories and the synchronous
file helpers. Cover observable behavior rather than duplicating helper code.

| Area | Required cases |
| --- | --- |
| Paths | Both targets in one project's `.localc`; no parent/home fallback; another project unchanged; reject escaping symlinks |
| Creation | Missing read does not create files; first append creates selected target; removing the last entry leaves an empty file |
| Format | Multiline entries; BOM/CRLF normalization; empty file; empty-entry format errors; inline `§`; reserved delimiter rejection |
| Preservation | Manual headings/content preserved; loads do not rewrite; rejected operations leave original bytes unchanged |
| Unicode | ASCII, Chinese, emoji, combining sequences; counts use Unicode scalars consistently |
| Matching | Zero/one/multiple matching entries; two matches inside one entry; literal case-sensitive matching; whole-entry replacement |
| Actions | Omitted action reads; only append/remove/replace accepted when present; reject null, empty, unsupported action and invalid field combinations |
| Atomicity | One action either saves completely or leaves original bytes; later call failure does not undo earlier success; no cross-target transaction claims |
| Capacity | Each saved mutation fits; rejected append leaves bytes unchanged; shorten then append uses two independent calls |
| Duplicates | Exact append no-op; existing order retained; semantic duplicates receive no automatic rewrite |
| Errors | Invalid request JSON/types/fields; argument/file byte limits; read/write failures; no success response before commit |
| Responses | Plaintext success/read/no-op/error across local and remote paths; current contents unescaped; usage matches body; empty and missing targets clear; rejected candidate never shown as saved |
| Concurrency | Two cooperating writers retain both additions; stale selector fails; writer lock remains stable across replacement |
| External edits | Observed byte change causes refusal; no claim that non-cooperating races are fully prevented |

### Prompt and lifecycle tests

Use fixed templates and a deterministic tokenizer fixture or existing prompt
tests. Assert exact string/token behavior:

1. Both files appear once in the intended system body and never as new real
   user messages.
2. File text containing chat delimiters remains safe-tokenized content.
3. Placeholder-like strings inside memory are not recursively expanded.
4. A successful ordinary write leaves the existing system tokens unchanged.
5. A new agent loads the written contents.
6. Reasoning-setting changes retain the prior memory block.
7. Hot resume and hibernation preserve the block, including cold restoration
   of unfinished suspension state and missing fields in older payloads.
8. Deterministic compaction does not reload memory.
9. Semantic checkpoint success adopts staged memory; cancellation restores
   the previous prompt and continuation together.
10. Explicit refresh changes memory only at a safe inference boundary.
11. A missing/duplicate placeholder in a custom template receives the specified
    diagnostic instead of placing text outside the system body.
12. Remote ordinary preparation does not recreate an agent because a memory
    file changed; explicit refresh/checkpoint paths do update it.
13. Changing the ask's memory flag loads or clears the block, including repeated
    off/on transitions with no project context. An unchanged flag does not load
    newer disk contents. A temporary ask captures its restore point after applying
    the flag, and suspension/resume preserves that same context.

### Review tests

Use a fake model and controlled tools for workflow behavior, plus backend
cache tests for restoration correctness:

- An eligible user completion starts review on the same agent only after
  the original answer and its continuation are finalized.
- Capture the position before the internal review message, not before the
  original task or only before the last tool-result continuation.
- `ask(..., temporary: true)` owns initialization/restoration; callers never
  manipulate cache offsets or backups. A partial return from `ask` or `resume`
  does not trigger terminal cleanup.
- `temporary: false` preserves ordinary ask/compaction/persistence behavior;
  a temporary ask followed by a normal one does not leak its mode.
- The flag alone does not select a review prompt, label/hide UI, restrict tools
  to memory, or roll back file writes. Those belong to the calling workflow.
- A non-review test prompt can use temporary execution and be discarded in
  exactly the same way, without introducing `/btw` or `/sidechat` commands.
- Pause before/after prefill, during decode, and around tool waits; resume each
  path with the same temporary state, original restore point, and live backups.
- Multiple pause/resume cycles keep compaction disabled, do not recapture a
  later boundary, and perform exactly one restoration at terminal completion.
- Cancel a suspended review and verify restoration before normal scheduling.
  Hibernation must not encode a review as an ordinary user suspension.
- Keep compaction disabled at ask startup, through every tool call/result,
  during context-pressure handling, and at review completion.
- Disabled compaction adds no input-reserve rejection or decoding cutoff.
  Ordinary tool-result preview/externalization remains enabled.
- Temporary asks return normal result fields, including `logTokens`, while
  restoring the agent context. The review workflow does not persist those logs.
- After no-op, successful edits, Stop, tool failure, or model failure, original
  prefix tokens/messages, system content, counters, and valid KV offsets are
  restored. Next real input contains no review prompt, tools, or answer.
- The next real ask reuses the retained KV buffers without a second full
  prefix allocation or a full-prefix prefill on the normal successful path.
- Stale review suffix rows cannot be attended to after rewinding or after
  the next user request grows through those positions.
- Qwen convolution/recurrent and draft/speculative boundary state restore
  correctly; DeepSeek raw windows, compressor inputs, indexer/compressed
  boundary rows, and their lengths restore correctly.
- Exercise reviews crossing allocation pages, raw-window movement, compression
  boundaries, tool rounds, and speculative acceptance boundaries.
- Compare next-token logits or deterministic continuation against an otherwise
  identical run with no review, keeping the system prompt fixed. If sampling
  uses a persistent random stream, preserve its boundary state or isolate review
  sampling so a random-stream difference does not masquerade as cache damage.
- No review continuation, checkpoint, or suspension is persisted as real
  history. Cold reopen restores the completed real conversation while retaining
  actual saved USER/MEMORY edits.
- Queued real work skips/defers review. New work during review stays queued until
  review finishes or the user explicitly stops it and restoration completes;
  it never runs concurrently on that agent.
- `Reviewing Memory...` appears before streaming starts; the internal user prompt
  stays hidden; the normal answer remains a separate completed UI item.
- The label is localized and includes an ellipsis. An empty body shows only
  that label, without a divider or extra newlines; tool or text content adds
  the divider before the body.
- The review row disappears on success, Stop, and failure; no completed feedback
  is saved or restored. The ordinary answer remains in place.
- Eligible background threads schedule reviews after draining queued user work.
  Opening an active review shows its transient row; background completion does
  not alter the displayed conversation or its input state.
- Review executes only the selected memory-file operations; late calls cannot
  write after the review execution gate closes.
- Completed writes remain saved and are reported accurately even when later
  review steps fail. A no-op performs no file write.
- Review completion never triggers review or advances user-turn cadence.
- Remote review restores original transcript/request linkage and does not
  compact or retain temporary exchanges as the next real request's prefix.

Measure peak KV bytes and copied tensor bytes as well as correctness. The
acceptance goal is one retained prefix with a bounded temporary suffix and
necessary state backup, rather than a duplicated fork. State the measured
backup size and any allocation-growth peak for each model family.

Use a small extraction-quality set separately: durable preference, one-off
request, correction, obsolete project fact, procedure, quoted malicious
instruction, explicit forgetting, and nothing to save. Measure false additions
and review cost when choosing cadence; no-review-equivalent cache behavior
alone does not establish useful memory selection.

### Existing integration checks

Run the affected focused tests plus:

```sh
bazel test //Apps/LocalCode:SystemPromptSectionTests
bazel test //Apps/LocalCode:ProjectMemoryTests
bazel test //Apps/LocalCode:SystemPromptTemplateTests
bazel test //Apps/LocalCode:ToolCallParserTests
bazel test //Apps/LocalCode:FileToolsTests
bazel test //Libraries/RemoteAPI:RemoteAPITests
bazel build //Apps/LocalCode:LocalCode --ios_multi_cpus=arm64
```

Run `//Libraries/ProjectHistoryManager:ProjectHistoryManagerTests` if completion
or history wiring changes. The focused file/tool tests are
`//Apps/LocalCode:ProjectMemoryTests`; the model-backed review, cancellation,
and hibernation scenario is `//Apps/LocalCode:AgentSchedulerHarness --scenario memory`.

### First draft validation (2026-09-07)

- After removing scheduler `purpose`, four mock-agent checks passed against
  the scheduler source: foreground changes alone keep the ask running;
  foreground work pauses/resumes it; hibernation and eviction cancel an already
  suspended temporary ask through its completion path. Workflow and harness
  syntax checks passed. The subsequent LocalCode and AgentSchedulerHarness
  rebuild passed after the dependency API fix, using the updated pinned
  dependencies with `--override_repository=s4nnc= --override_repository=ccv=`.
  Those command-line flags bypass the older local dependency overrides without
  changing `.bazelrc.local`.
- All seven listed focused test targets passed, including ten project-memory
  cases and the project-history tests.
- LocalCode, LocalCodeCLI, and AgentSchedulerHarness built successfully with
  `--ios_multi_cpus=arm64`.
- The DS4 `memory` harness scenario passed using the installed flash model:
  initial project memory was read from the prompt, review saved a durable user
  preference using only memory calls, and the original context token boundary
  was restored. Stop and hibernation both cancelled review without leaving an
  active or persisted suspension. Normal conversation then continued correctly.
- Qwen integration is compile-verified; its model-backed review and UIKit
  interaction have not been exercised in this pass. Extraction-quality sets,
  compaction-refresh runtime coverage, and exact KV backup measurements remain
  follow-up validation.

### Typed context and DS4 placement validation (2026-09-08)

- Replaced string-valued memory state with `MemoryContext` in both local agents,
  including suspension encoding and normal context section emission.
- DS4 emits memory after project context in its existing user-role reminder;
  environment remains in the initial instruction block. Accepted compaction
  replaces the reminder, while ordinary review leaves it frozen.
- Five focused targets passed: ProjectMemoryTests, ProjectContextTests,
  DeepSeek4TranscriptTests, SystemPromptSectionTests, and EnvironmentContextTests
  (31 test cases total). The actual DS4 tokenizer exposed an extra opening
  newline that broke delimiter matching; the regression passes after keeping
  that delimiter stable.
- LocalCode and AgentSchedulerHarness built with `--ios_multi_cpus=arm64`, using
  the default pinned dependencies after `.bazelrc.local` was removed. The real
  model review scenario was not rerun for this placement change.

### Persisted review counter validation (2026-09-08)

- Added `ProjectThread.turnCountSinceLastReview` as an appended FlatBuffers
  field, with zero as the default for existing threads. Regenerated the SwiftPM
  data models using the repository script.
- All 18 ProjectHistoryManager tests passed, including counter persistence
  across project reopen and model changes, independent counts per thread, and
  reset without changing history or thread recency.
- LocalCode and AgentSchedulerHarness built with `--ios_multi_cpus=arm64`.

## 17. Implementation sequence

1. **Write through the dedicated memory tool.** Implement target selection,
   plaintext results, literal entry matching, and atomic writes independently
   of temporary model execution.
2. **Files and initial prompt loading.** Implement project-local path/format/
   budget rules and frozen prompt loading for local/remote models.
3. **General temporary ask and suspension.** Add `temporary: Bool` to ask.
   Keep `TemporaryState` on the agent across pause/resume; disable compaction,
   prompt refresh, and disk suspension writes for the whole temporary operation.
   Use `isCompactionDisabled` without extra capacity checks; keep normal tool
   previews/externalization and returned results. Keep review prompt/UI/tool
   policy and result persistence in the caller.
4. **KV restoration.** Reuse prefix tensors, preserve only overwritten state,
   discard the review suffix on every exit, and validate the next normal ask
   against a no-review baseline. Do not add a full KV fork.
5. **Review UI and Stop behavior.** Show labeled assistant feedback while
   hiding internal user input; queue new work until restoration completes.
6. **Coverage and measurement.** Test storage-boundary cases, remote request
   restoration, restart behavior, and peak cache usage at the ten-turn cadence
   and review budgets.

Successfully saved facts remain in the Markdown files. Review's model context
is discarded, and its display feedback is removed on completion. Future shared-
prefix KV management can change the execution tradeoff without changing these
memory-file semantics.

## 18. Points to revisit in discussion

Project-local USER/MEMORY paths, serialized temporary review, compaction being
disabled throughout its tool loop, restoration to the pre-review boundary,
and reuse of existing prefix KV are now the working contract. Review feedback
is visible under the host's label only while review runs; its internal prompt stays hidden.
The dedicated tool uses plaintext responses and one optional
`action`: `append`, `remove`, or `replace`, with omission meaning read.
These details remain open:

| Topic | Current proposal | Reason to revisit |
| --- | --- | --- |
| Writing memory | Dedicated `memory` tool implemented | Ordinary file tools keep metadata protection |
| Entry format | `§`-separated text implemented | Evaluate whether the delimiter is convenient for manual edits |
| Capacity | USER 1,375; MEMORY 2,200 Unicode scalars, provisional | Decide enforcement and evaluate useful size |
| Review cadence | Persist `turnCountSinceLastReview` on `ProjectThread`; review at ten or more eligible completed user turns | No separate review-state object; scheduling decision placement remains open |
| Scheduling priority | Ordinary scheduling now; general QoS only if needed later | Most user work would be `userInitiated`; review could be `utility` or `background` |
| Review UI | Hidden internal prompt; labeled feedback while running, removed at completion | Confirm collapse behavior and tool-detail presentation |
| Agent API | `ask(..., temporary: Bool)` owns temporary execution and terminal restoration | Thread through normal/review call sites and scheduler dispatch; keep UI and tool policy separate |
| Suspension | Private agent `temporaryState` retains mode, original restore point, and backups across pause/resume, outside Codable | Initial hibernation cancels/restores; durable temporary suspension is separate |
| Future uses | API can support `/btw` or `/sidechat` without committing main context | Commands, presentation, and tool permissions are not implemented or specified here |
| Backend restoration | Preserve required recurrent/window/compressor/draft state at the saved boundary | Determine exact slices and measure backup bytes; no full KV duplication |
| Review capacity | No additional capacity policy when compaction is disabled | Ordinary generator behavior; no temporary-only reserve check or decode cutoff |
| Review budgets | Ordinary generator behavior, with no added review cap | Any future maintenance limit needs separate discussion and measurement |
| Normal compaction refresh | Semantic checkpoints on real user tasks only | Review cannot enter that refresh path |
| Explicit forgetting | Remove saved entries; keep review cancellation ordered with writes | Historical data and permanent exclusion remain separate concerns |
| Custom templates | Qwen requires one memory placeholder; DS4 uses its user-role reminder | Preserve editable initial instructions |

A radix-tree or similar shared-prefix KV manager is future work. Its absence
is why this design serializes review on the active cache instead of forking a
second cache. Do not make that future architecture a dependency of memory.

As decisions settle, update the relevant section and this table in the same
edit. Keep the Hermes study as background; this document is the source of
truth for the Local Code design we are iterating on.
