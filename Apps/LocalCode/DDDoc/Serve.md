# Serve

Status: prototype.

Serve lets other apps on a Mac use a local model through an OpenAI-compatible Responses API. It has
its own place on the rail, on the Mac only: a settings page with a toggle and a model picker, and a
page over the chat showing what is being served.

## Decisions

### Serving exists while its toggle is on

`ChatWorkflow` creates `ServeController` when the Responses API toggle turns on, at launch if it was
left on, and drops it when the toggle turns off. Nothing is set up for someone who never serves.
`ServeController` watches the model it serves itself. Dropping it stops the listener and closes
every connection: a request in progress ends at its next token, and still tells its scheduler it's
done, so the scheduler lets go of the agent and goes idle.

### A request is a `CodeAgent` turn

`ResponsesAgent` conforms to `CodeAgent`, so `AgentScheduler` runs requests alongside the chat. That
gives serving the scheduler's guarantees without a second coordinator: one agent on the generation
queue at a time, the foreground chat turn goes first, the hot limit applies, and activity keeps the
Mac awake and the model loaded.

The real agents can't back this API. They own the system prompt, run tools themselves and compact the
context; a client sends its own instructions and tools, and runs those tools. So `ask` ignores its
prompt and project, and takes the request from `nextRequest`, set before the turn is submitted.

Being a turn without being a thread takes these:

- `askDetached` and `resumeDetached` submit a turn with no project. It holds no `SQLiteWorkspace`,
  appears in no thread list, and still counts toward `isIdle`.
- The scheduler's progress callback only reaches the foreground, and `stop` only works from it. The
  agent is never the foreground, so it writes to the client and handles disconnects by itself.
- Turns aren't `temporary`, because the scheduler aborts those when it evicts them, which would fail a
  request for lack of memory. `hibernate` drops the KV cache and keeps the request and tokens in
  memory; `resume` rebuilds from the context cache and carries on.
- Retiring a scheduler removes its entries with no completion. `ChatWorkflow` hands the turn to the
  new scheduler through `ServeController.scheduler(_:didRetireInFavorOf:)`, or the client would hang.
- A finished turn leaves the scheduler, whose idle unload then can't reach the agent's KV cache, so
  `unloadIdleModels` unloads it separately.

### An agent per conversation

A KV cache lives in its agent, and the weights are shared, so N agents cost one set of weights and N
KV caches. Clients send nothing that says which conversation a request belongs to, and a follow-up's
input has grown since the last request, so hashing it wouldn't find anything either. A request goes to
the idle agent whose tokens it continues, the longest if there are several. Comparing 206K tokens
takes 0.07 ms.

`ServeController` asks for the served model's generator once and every agent's adapter copies it,
as copies share the weights. The chat looks there too, so switching it to the served model doesn't
load that model again.

That needs the tokens before an agent is chosen, so tokenizing moved off the generation queue, where it
held up the chat. It runs at about 4 µs per token on Qwen and 5 µs on DeepSeek, on one core.

A request with no match, or whose match is busy, gets a new agent, which restores what it can from the
context cache. On a 32K-token conversation the first token takes about 30s with nothing cached, 5s from
the context cache, which rounds down to a multiple of 4,096 tokens, and 1s from the KV cache.

### Eight agents, expired by 2Q

`ServeController` keeps at most 8 agents, running or idle, each with a KV cache. It's a fixed number
rather than a share of the scheduler's hot limit: serving while chatting is the exception, so Serve
doesn't ask the scheduler how much room the chat leaves. A request that continues none of the idle
agents gets a new one, which takes an idle agent's place once there are 8, and waits while all 8 are
running.

Conversations that never came back expire first, oldest first, and then the ones that did, least
recently used first. So a one-off request, like a client naming its thread, can't push out a
conversation in use. There's no ghost list: a conversation that expired comes back as new.

### Requests take turns

The models can't batch. `ServeController` runs up to 8 requests at once, one per agent, keeps up to
128 more waiting, and answers 429 past that.

The agent yields from inside, at a progress callback as a thread does while its tools run: when its
slice is up and another request is underway, it reports `timeSliceEnded`, and pauses if the scheduler
says to. The slice can only end at a callback, so it applies to generation; a prefill can only stop
between chunks of 4,096 tokens, which take 3 to 5 seconds on a 27B model.

Only other requests are reason to yield, so a background chat turn doesn't pre-empt a request by
itself, and chat scheduling is what it was. A request that yields for another can still land behind a
background chat turn in the scheduler's FIFO, which then runs until its own next tool wait. Ending a
slice doesn't count as waiting for tools, or a thread whose tools are running would see everyone else
waiting and hold the queue for as long as they take.

The slice is 1 second. Against one client, 2 or 4 clients on a 27B model lost at most about 8% of
throughput at 1 second and 3% at 2, and rounds of the same test differed by about 10%. The longest
stall a client saw was about 1.2s and 3.3s with 2 and 4 clients at 1 second, and twice that at 2.
Conversations of 30K tokens cost no more to switch between: 2 clients got 19.2 tok/s at 1 second and 18
at 2, against 18.5 to 22 for one.
DeepSeek 4.1 takes turns too, now that a `decode` call builds its rotary rows 512 positions at a time
instead of out to the KV cache's capacity: 2 clients got 13.3 tok/s together against 15.3 for one,
and two conversations alternating continued their KV caches on 8 of 8 follow-ups.

The chat always goes first. A foreground turn pauses every request at its next callback and keeps the
model while it waits on tools, so a long chat turn stalls API clients. Streaming clients get SSE
comments in the meantime; a non-streaming client may hit its own timeout.

### `NWListener`, on 127.0.0.1 or 0.0.0.0

`Libraries/HTTPServer` returns each response whole, so it can't stream. `StreamingHTTPServer` is a small
HTTP/1.1 server on Network.framework with no new dependency: one request per connection, and a stream
ends when its connection closes. `ResponsesTransport` keeps the Responses code from depending on it.

It listens with no API key on port 11435, one above Ollama's so the two can serve on one Mac, and at
127.0.0.1 unless 0.0.0.0 is picked. Both can be changed, as Draw Things offers for its API server,
and changing either restarts the listener, which ends the requests on it.
Ollama, LM Studio, llama.cpp's server and Jan all default to loopback too, and LM Studio and Jan
ask for a key once other devices can reach them.

Anything on the Mac can reach 127.0.0.1, web pages included, so it refuses a non-loopback `Origin`
(a page's request) and, on 127.0.0.1, a non-loopback `Host` (DNS rebinding). On 0.0.0.0 any host is
already welcome, so only pages are refused.

### Assistant turns render as the model writes them

A client replays the conversation with each request. A request continues the KV cache only when its
tokens start with exactly the tokens the KV cache holds, so replaying an assistant turn has to produce
what the model generated. `Qwen3_5CodeAgent.parse` frames tool calls differently, so
`Qwen3_5ResponsesModelAdapter` renders assistant turns itself, down to the opening it uses with no
thinking.

Thinking has to come back too. Reasoning items carry it in `content` and in `encrypted_content`, which
here is only base64, for clients that replay nothing else.

Tool schemas are JSON with sorted keys, so the same tools always make the same tokens.

### The context cache is shared with the workspace root

The cache is `<workspace folder>/.localc/context_cache.sqlite3`, the same file as root project threads.
Its keys are prefix hashes with no thread in them, so stateless requests hit it without any mapping,
and both writers are on the generation queue.

### The page plots trends from memory

`ServeMetrics` keeps a sample every 2 seconds for 5 minutes and the last 30 requests, and is gone when
the app quits. The rates come from token counts between samples, not from the agent's statistics, so
the chart dips while a request waits behind the chat. Time per request splits into waiting, prompt
processing and token generation from progress updates on the main queue, so it is good to a few tenths
of a second.

Memory is the footprint plus the pages mapped from files, for the whole app including the chat. The
footprint has the KV caches and not the weights, as they are mapped from disk, and the resident size
has the weights and not the KV caches, as Metal holds them. One 15K-token KV cache adds about 1.3 GB.

Each thing keeps its color on every chart: prompt processing orange and token generation blue like the
Model Speed page, cache aqua, memory lavender, and waiting gray.

## Limits

- No `previous_response_id`, `conversation`, structured output or images: these return 400.
- `tool_choice` other than `none` behaves as `auto`, since nothing can force a call.
- Hosted and custom tools are dropped, and `temperature` only matters at 0.
- There is no compaction. Input over the model's limit returns `context_length_exceeded`.
- `reasoning.effort` is ignored. Thinking follows the app's Thinking Budget, as in the chat, and 0
  turns it off.

## Known gaps

- The model picker only lists downloaded models, as there's no way yet to download one from there.
- The cache has no eviction. One 48K-token prompt wrote 4.5 GB, and API traffic is more varied than a
  chat.
- The hot limit is computed from one model. Serving a different model from the chat's can hold both
  sets of weights and both KV caches at once. Room is made for the served model only when it's first
  asked for, so the chat's model loading again later stays loaded beside it.
- KV reuse needs parameters in sorted order, as the render sorts them and `ToolCall` doesn't keep their
  order. A model writing them in another order falls back to the context cache.
- A model that ends its turn without closing its thinking, which DeepSeek 4 Flash sometimes does, gets
  a `</think>` on replay that it never wrote, so the next turn falls back to the context cache. It also
  means the client gets its answer as reasoning, with no text.
- On 0.0.0.0 anything on the network can use the model, with no key, over plain HTTP.
- Serve's 8 agents don't count toward the scheduler's hot limit once their turns end, so serving
  while chatting can keep more KV caches in memory than the limit allows for.
- The hot limit counts KV caches at a fixed estimate. For Qwen that's 7 GB, and at about 80 KB per token
  a full 131K-token cache would be more than that.
- The page shows one request at a time, however many are underway.

## Verifying

- `bazel test //Apps/LocalCode:ResponsesServeTests`
- `bazel run //Apps/LocalCode:AgentSchedulerHarness -- --scenario detached-yield` checks that a thread
  with running tools doesn't hold up requests that yield. It needs no model.
- `bazel run //Apps/LocalCode:ResponsesServeProbe -- --model-path <ckpt> --family <family> --cache-project-path <dir>`
  serves a real model with no UI. `SIGUSR1` runs a fake foreground chat turn, `SIGUSR2` retires the
  scheduler, `SIGHUP` turns serving off as the toggle does, and `--hot-limit 1` makes that chat turn
  evict the request. `--ip 0.0.0.0` and `--port` set what the settings page would.
