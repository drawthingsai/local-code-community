# Remote Access Services

- Status: Implemented. Verified end to end on 2026-10-28 ([Remote Access](RemoteAccess.md#verification)).
- Scope: what an iPhone or iPad asks of a Mac over a Remote Access link, as gRPC services. The room,
  identity, setup and links are in [Remote Access](RemoteAccess.md).

## Context and decision

The calls are a proto `service`, and gRPC is the only thing that writes to a link. Both sides use
generated clients and servers, so a call's shape is defined once and checked at build time. A phone
works in the Mac's own projects and threads, as the Mac does; there are no phone threads run on a Mac.

| Question | Decision |
| --- | --- |
| gRPC library | grpc-swift 1.x, already in the repo for Draw Things' image server. grpc-swift 2 needs iOS 18, and Local Code supports iOS 16. |
| Transport | gRPC's HTTP/2 bytes over the link's data channel (`devicelink/2`). No server listens on any network address. |
| Caller identity | One gRPC server per link on the Mac, so every call is from the link's verified device. A device ID in call metadata could be claimed by another device. |
| Threads | The Mac's are kept on the Mac: a phone opens and continues them in the Mac's projects, and the Mac continues threads a phone worked on. The phone's own threads run there, on a cloud model or on a Mac's model ([Inference](#inference)). |
| A thread's model | Its own, on the Mac: one of the Mac's downloaded models, or a model of a cloud provider set up on the Mac. A phone shows it and can pick another provider and model, as on the Mac; the thread moves with its next message, as on the Mac's composer. |
| The phone's own files | Not streamed to the Mac. The agent's tools on the Mac (Bash, Python, Node, git, search) need a real filesystem, and the app can't mount the phone's. |
| Messages and files | Up to 1 GiB, the limit Draw Things' gRPC services set. Attachments go inline with their message; a file the phone reads comes in 4 MiB chunks. |
| Device access | Account-wide, in the room ([Remote Access](RemoteAccess.md#identity-and-trust)). No per-Mac approvals. |
| The Mac's details | In its signed status in the room, which the picker already reads. No service for them. |
| Files | Only files the thread made: attached to its messages, or written by its turns' write and edit tools. Never the Mac's other files. |
| Interactions | [Later](#interactions-later). A turn that needs someone at the Mac waits for the Mac. |

## Transport

```text
 iPhone or iPad                                          Mac
 ┌──────────────────────────────┐                        ┌───────────────────────────────────┐
 │ generated client             │                        │ provider for this link's device   │
 │   ClientConnection           │                        │   Server (one per link)           │
 │   (.connectedSocket)         │                        │   on tmp/dl-<hex>.s               │
 │        ║ socketpair          │                        │        ║ Unix socket              │
 │   LinkPump ◀═════════════════╪═ data channel ═════════╪═▶ LinkPump                        │
 │   Link (Connector)           │  "devicelink/2"        │   Link (Connector)                │
 └──────────────────────────────┘  HTTP/2 bytes in       └───────────────────────────────────┘
                                   chunks of up to 64 KB
```

- **Sockets.** The phone makes a `socketpair` per link: gRPC's `ClientConnection` gets one end
  (`ConnectionTarget.connectedSocket`), and `LinkPump` moves bytes between the other end and the
  link. The Mac starts a gRPC `Server` per link on a Unix socket named `dl-<6 hex digits>.s` in its
  temporary folder; `LinkPump` connects to it and the file is removed at once. The socket's path has
  to fit in `sun_path`. The provider is made for the link's `VerifiedDevice`, and the server and its
  calls end with the link.
- **Chunks and backpressure.** The channel is ordered and reliable, so each data-channel message is
  just the next run of bytes, up to 64 KB or the link's limit. The pump stops reading its socket
  while more than 1 MB is queued on the link; HTTP/2 flow control handles each call.
- **Liveness.** While a call is open, the phone sends a gRPC keepalive ping every 3 seconds, and 2
  seconds without an answer close the link, so a dead link ends its calls within 5 seconds. The
  phone holds a watch call open while a Mac's projects or one of its threads is on screen; otherwise
  the room says whether the Mac is there. A link with no call open closes.
- **Message size.** 1 GiB each way; over that, `RESOURCE_EXHAUSTED`. gRPC holds a whole message in
  memory on both sides.
- **Resuming.** A gRPC stream ends with its link. Turns belong to the Mac and number their events, so
  the phone opens a new link and watches the thread again from the last message and event it saw.
  While the room shows the Mac online, it retries with backoff (1 to 30 seconds), and at once when
  the Mac comes back.

Alternatives considered: a custom NIO channel over the data channel (more code than a socket pump,
for no gain yet); one server for every link with the caller in metadata (any device could claim to
be another); grpc-swift 2's pluggable transports (iOS 18 and later).

## Access and errors

On every call the Mac checks that the link's device is on the list and allowed
(`PERMISSION_DENIED` otherwise), and it closes a disconnected device's links at once. Calls fail
with a gRPC status code and a message the Mac writes for display; the phone acts only on the code.

| Code | When |
| --- | --- |
| `PERMISSION_DENIED` | The device is disconnected. |
| `NOT_FOUND` | The project, thread or file is gone; the model picked isn't available on the Mac. |
| `FAILED_PRECONDITION` | The Mac has no model selected; it hasn't used a cloud model yet, which asks to share project data first; or it's answering in the thread open on it, when a device picks another model for that thread. |
| `INVALID_ARGUMENT` | An empty message; a file the thread didn't make. |
| `RESOURCE_EXHAUSTED` | A message or file over its limit. |
| `UNAVAILABLE` | The model failed to load; the Mac couldn't start the turn; a new thread's model, or a step's, would have to replace one the Mac is still running. |

A turn that starts and then fails ends with `TurnFinished` (`OUTCOME_FAILED` and the message), not
with a status, so its events up to the failure are kept.

## The Mac's status and models

The Mac's signed `HostStatus` in the room lists every model downloaded on the Mac (a `HostModel` is
an ID and a name), the one its composer runs on (`selected_model_id`), and whether any turn is
running (`ThreadsHub.isBusy`). The Mac publishes it again whenever a model is selected, downloaded
or removed.

Each thread keeps its own model (`ThreadModel`: a provider, empty for the Mac's own models, a model
ID and a name). `WatchThread` sends it after the history, and again when the thread moves to another.
`ListModels` lists what a thread can run on: the Mac's downloaded models, then each cloud provider
set up on the Mac with its cached models and the one picked for it there, and the Mac's selection,
which a new thread starts on. In a Mac's thread, the phone's composer shows the thread's model, and
the model selector lists the Mac's downloaded models under the Mac's name; the phone doesn't offer
the Mac's cloud providers for now. A pick goes with the thread's next message
(`SendMessage.model`), and the thread moves to it then, its history converted as when the Mac's
composer switches models in a thread. Sent to the thread open on the Mac, it moves the Mac's
composer to that model first, as picking it on the Mac does.

The Mac runs one of its own models at a time. A message for a thread on another one waits in the
thread's queue until nothing runs on the loaded model; then the Mac loads the thread's and sends the
queue. The thread open on the Mac keeps its model and loads it again when it next runs. Cloud models
don't wait: the Mac runs a thread's turn on its provider in the background, with the Mac's account,
and reports it like a local turn, as it does for the thread open on it.

## Threads

One service: the Mac's projects and threads, as its drawer lists them, worked on from either device.

| Call | Does |
| --- | --- |
| `WatchProjects` | Every project with its first 20 threads, then the whole list again on every change. |
| `WatchThread` | The thread's history, queue and running turn's events, then every change from either device. From a message and event onward when the phone already has some. |
| `SendMessage` | Starts a turn or queues behind the running one, as the Mac's composer does. To a project, it starts a new thread. With `steer`, it stops the running turn and sends the queue at once. With `model`, the thread moves to that model first. |
| `StopTurn` | Stops the thread's running turn. |
| `RemoveQueuedMessage` | Takes a message out of the queue. |
| `ReadFile` | A file the thread made, in 4 MiB chunks. |
| `ListModels` | The models a thread can run on: the Mac's own, then each cloud provider's set up on the Mac. |

- **IDs.** A project's ID is the hex of the first 16 bytes of SHA-256 over its resolved path, so it's
  stable across launches and the phone never sees the path.
- **As on the Mac.** Messages arrive as the Mac renders them. A new thread's title comes from its
  first message. Turns use the Mac's memory, skills, project context and settings. Attachments are
  copied into the project as the Mac's composer copies them. Watching a thread marks it read. The
  Mac reports progress for threads another device watches even in the background
  (`AgentScheduler.setBackgroundProgressThreads`). Drafts, renaming and deleting stay on the device
  they're done on.
- **Sending into the Mac's composer.** A message to the thread open on the Mac goes through the Mac's
  composer; one to another thread queues behind its turn or starts one in the background. When the
  Mac has moved a thread's unanswered message back into its composer, a phone's message goes with
  it, as a stopped message goes with what was queued behind it. A queued message is steered by
  removing it and sending it again with `steer`.
- **Replaced messages.** When the Mac replaces a message (resending a draft saves a new user node in
  place of the old one), it sends a `ThreadHistory` with the messages after the newest node it still
  has, and the phone drops its own after that one. A watch picks up after the phone's last message
  only while the Mac still has it; otherwise it sends the whole history.
- **Files.** `ReadFile` serves a path only if the thread made it, and only if it resolves inside the
  project after symlinks. Images are files too. The phone fetches the files a thread's messages link
  to or attach (up to 32 MB each, 64 per thread) into a folder of its own, where the chat finds them.
- **On the phone**, each listed Mac's projects are watched while the app is active, since an iPad
  shows the drawer all the time. A Mac's threads open from the drawer.
- **Where Models Run on an iPhone** is never unspecified. With no model to run, as on a thread whose
  model the phone can't run, it takes the first that can answer of: the last used, Remote Access (an
  online Mac's model), Cloud Compute, then any other provider that's set up; Cloud Compute, with its
  sign-in, when none can. "Last used" is where the phone's last message went, or what was last
  picked.

### Turns

A turn is one answer from the agent. One of the Mac's own models serves its local turns, through the
Mac's agent scheduler: the thread open on the Mac goes first, then the others in the order they
asked. Cloud turns run on their providers alongside. Events number from 1
within a turn, and a finished turn's events stay for 10 minutes for a phone that reattaches. Streamed
text, reasoning and counts go at most 10 times a second; phase changes and tool calls go at once.

| Event | Shown on the phone as on the Mac |
| --- | --- |
| `reading`, `compacting` | "Reading… (done/total, time)", "Compacting…" |
| `thinking` | The reasoning so far, trimmed as the think cell trims it, with the token count. |
| `answer` | The answer so far. It can replace itself, since a tool call is taken out of the agent's text. |
| `tool_started`, `tool_finished` | Running tools under the answer, finished ones above it, with their subtitles. |
| `metrics` | Prefill and generation speed, and context used, for Settings. |
| `finished` | Completed, stopped or failed, with the saved answer. `OUTCOME_GONE` when the Mac no longer has the turn a device asked to pick up, as after a restart. |

## Code

- **Phone.** `MacConnection` keeps one link and one `ClientConnection` per Mac, opened when a call
  needs it. `DeviceLinkService` watches each listed Mac's projects and publishes them
  (`macProjects`) for the drawer. `MacThreadController` shows a Mac's thread in the chat and renders
  turns as the Mac renders its own; `ChatWorkflow+MacThreads.swift` handles the composer and the
  model selector.
- **Mac.** `LinkHost` gives each accepted link a `Server` with `ThreadsService`. `ThreadsHub`
  numbers turn events and fans them out, with `ChatWorkflow+Threads.swift` as its backend on the
  paths the Mac's own UI uses. Each project's database is shared: the backend uses the open
  project's or the agent scheduler's, and opens one itself only when neither has it, keeping it open
  while a device watches a thread in it.
- **Protos.** [`threads.proto`](../../../Libraries/DeviceLink/Protos/v2/threads.proto) and
  [`turns.proto`](../../../Libraries/DeviceLink/Protos/v2/turns.proto), package
  `localcode.devicelink.v2`, generated by `Scripts/devicelink/generate_protos.sh`.
  [`room.proto`](../../../Libraries/DeviceLink/Protos/room.proto) stays in `localcode.devicelink.v1`.
  With `swift_prefix = ""`, names avoid clashes: `MessageRole`, `ThreadSummary`, `ProjectSummary`,
  `ThreadHistory`, `QueuedMessages` and `FileAttachment`.

## Inference

The phone's own threads can run on one of a Mac's downloaded models, as the Remote Access provider
in Where Models Run (`RemoteProvider.deviceLink`). The thread, its agent and its tools stay on the
phone, as with a cloud model; only the model runs on the Mac. Its models are `file@device`, listed
from each online Mac's `HostStatus` as "*model* on *Mac*". The model selector lists them in a
section for each Mac, which says when the Mac is answering, and picking one picks its Mac.

| Call | Does |
| --- | --- |
| `Step` | One step of the model over the phone's transcript and tools (the remote agent's own JSON): what it reads, then what it writes as it writes (`[RemoteContentBlock]`), then the result with usage. |

- **On the Mac** (`Qwen3_5Step`), a step reads the Mac's own Qwen prompt, which carries Local Code's
  tools, with the phone's system prompt in the project's place, then the transcript rendered as the
  local agent renders history, and writes the reasoning, answer and tool calls the phone then runs.
  It runs on the generation queue, between the Mac's own turns.
- **Reading.** Each phone thread has a context cache on the Mac, named by a hash, so a step starts
  from the longest prefix it holds and mostly reads what's new.
- **Limits.** Qwen models only, with the Qwen agent's context; others answer
  `FAILED_PRECONDITION`. While the Mac runs another of its models, a step answers `UNAVAILABLE`.
  Images stay links the phone's tools can open.

## Interactions (later)

What a tool can need from the user partway through a turn:

| Kind | Examples | From a phone's turn |
| --- | --- | --- |
| Already granted | Calendar or Photos allowed, a folder permitted, a Local Code Computer rule | No different: the tool goes on |
| Input | A PDF's password | Could be asked on the phone |
| A system permission never asked | Calendar or Photos | Only at the Mac |
| A picker | `permit` for a new folder; the Messages, Mail or Notes folder | Only at the Mac |
| A page | Web search verification in the Mac's browser; the account panel | Only at the Mac |
| An escalation | Local Code Computer's network or unsandboxed tiers | Only at the Mac |

Each is its own `BashToolContext` closure today, sharing only `BashUserInteraction`, which pauses
the Bash timeout. Over a link they can share one shape: an `interaction` turn event (an ID, input or
at-the-Mac, a title and detail from the Mac, and whether to hide what's typed), one `Answer` call
(text, or skip), and an `interaction_resolved` event. Only input carries a value back; a phone can
only skip the rest.

## Open questions

- **Interactions**, from the list above.
- **Reading a Mac's threads while it's offline**, from a read-only copy of the threads the phone
  opened.
- **Notifications on the phone.** Without push, a phone in the background learns a turn finished only
  when it's opened again.
- **Later:** background jobs on the phone, renaming and deleting a Mac's threads from the phone, and
  uploads larger than one message.
