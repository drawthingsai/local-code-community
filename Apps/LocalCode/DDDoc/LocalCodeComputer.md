# Local Code Computer

- Status: Proposed; product decisions agreed 2026-10-17 and 2026-10-18. A UI prototype, the menu and the approval panel on sample data, is in `Apps/LocalCodeComputer` (2026-10-26).
- Scope: a macOS menu-bar companion that runs Local Code's Bash tool on the user's Mac
- Last verified: 2026-10-26 (Seatbelt profile experiments on macOS 27.0.1, build 26A434)

## Context and decision

Local Code's Bash tool runs in process through `ios_system` and OSH. There are no real child processes, so the user's toolchains, compilers, package managers, daemons, and native executables are out of reach ([TerminalBench compatibility](../TerminalBenchCompatibilityHandoff.md), [JavaScript project support](../JavaScriptProjectSupport.md)). The Mac build ships through the Mac App Store, so it is App Sandboxed, and anything it spawns inherits that sandbox.

Local Code Computer is a second app on the same Mac, downloaded separately. It has no window. A menu-bar item (the tray) lists running work, and an approval panel is its only prompt. Local Code sends it Bash calls. Computer runs each call in the user's own zsh environment under a Seatbelt profile. Anything that needs more than that profile allows waits for the user's approval in Computer's panel.

The Seatbelt profile is the security boundary. Command analysis decides only whether a call needs more than the default sandbox, and whether a stored rule already covers it.

The agent is not treated as an adversary, but it makes mistakes. Escalation, approval, and review exist to catch those mistakes and keep escalation in the user's hands; they do not try to stop an agent that deliberately works around them. Known escapes of that kind are accepted:

- A rule approves every option after its prefix, including options that run programs, such as `git fetch --upload-pack` and `find -exec`.
- Rules ignore the working directory, so a rule for `git push` also matches in a nested repository, whose hooks and config the sandbox can write.

[Containerized Command Execution](../ContainerizedCommandExecution.md) lists a helper application as a non-goal, because a Linux VM can run inside the Catalyst process. That reasoning does not cover this case: the user's own Mac toolchains can only be reached from a process outside the App Sandbox. Computer becomes a third backend under the `CommandExecutionBackend` seam that document proposes, beside `ios_system` and the VM.

## Agreed decisions

| Question | Decision |
| --- | --- |
| Do commands that fit the default sandbox need approval? | No. They run without asking. Approval is only for escalation. |
| Distribution | Local Code ships through the Mac App Store. Computer is a separate download: Developer ID signed, notarized, hardened runtime, not App Sandboxed. |
| Scope | Same Mac only. iPhone, iPad, and remote Macs are out of scope. |
| Shell | The user's `/bin/zsh`. Commands are analyzed with tree-sitter-bash, which is approximate for zsh by design. |
| Escalation | Analysis flags known needs before running. The model may also request a tier with a justification, usually after a sandbox denial. |
| GPU | A separate tier, approved once per project. |
| Backend switching | A thread can move between Computer and the in-process backend, but not while one of its jobs is running. |
| Updates | Computer updates itself with Sparkle. |
| Approve for me | A per-project mode, turned on in Computer's menu, in which a reviewer model approves the calls it judges safe and sends the rest to the user. It never denies. It can approve every tier, within Computer's hard limits. It also reviews calls that stored rules cover, at a stricter cutoff. The reviewer model is pplx-decider-flash. |
| Interactive programs | Not supported, matching the in-process backend. Jobs get stdin from `/dev/null`, and the model gets no tools specific to Computer. |

## One call, end to end

```text
Local Code (Mac App Store, Catalyst)            Local Code Computer (menu bar)
model → bash {command, escalation?}
BashJob → Computer backend ── socket ──▶        verify the caller's code signature
                                                analyze → simple commands → tier
                                                tier > sandbox, no rule? ─▶ approval panel
"Waiting for approval in Local Code Computer" ◀─   (Bash timeout paused)
                                                spawn sandbox-exec -p <tier profile>
                                                  /bin/zsh -f -c "<command>"   (new session)
stdout/stderr files, read by offset ◀────────   output written in the shared container
bash_wait / bash_status                         tray lists the job
bash_stop ──────────────────────────────▶       SIGTERM the group, SIGKILL after 3 s
exit status, stop reason, denial hint ◀──────
```

1. Local Code sends `run` with the job id, command, project root, working directory, timeout, and the optional escalation request with its justification.
2. Computer checks that the working directory resolves inside the project root or a permitted folder.
3. Computer analyzes the command and works out the grants it needs: what analysis requires plus what the model requested.
4. Any grant beyond the default sandbox needs a stored rule or an approval. Local Code reports the wait and pauses the Bash timeout through `BashUserInteraction`.
5. Computer spawns the job in a new session, with stdin from `/dev/null` and stdout/stderr going to files it opened.
6. Local Code reads output by offset, as it reads its temp files today. OSC 1337 image extraction is unchanged.
7. On exit, Computer reports the status, the stop reason, and whether the sandbox denied something.

A denial returns to the model as a finished job with a stop reason, such as "The user denied network access for `git push`." Stopping a job in Local Code while it waits withdraws the approval request.

## Permission tiers

| Tier | Grants | Approval |
| --- | --- | --- |
| Sandbox (default) | Writes to the project root, permitted folders, a per-job `TMPDIR`, the project's cache folder (open question), and a few named items in the per-user temp folder. Reads everything except secrets. No network, no GPU. | never |
| GPU | Adds the GPU: IOKit user clients for the GPU and IOSurface, and the Metal compiler service. | once per project |
| Network | Adds outbound network, and servers on this Mac: binding and accepting connections. When every network command in the call is `git`, `ssh`, or `scp`, it also opens the credentials they need. | rule or panel |
| Unsandboxed | Anything the user can do. | rule or panel |

GPU and Network are independent: a call can hold either or both. Unsandboxed covers both.

Analysis rejects `sudo`; root is out of scope.

Profile requirements:

- Base `(deny default)` with explicit allows. `process-fork`, `process-exec`, `sysctl-read`, and same-sandbox `signal` are allowed.
- Mach lookups use an allowlist built by experiment ([Verified profile](#verified-profile)). It never includes LaunchServices, Apple Events, the pasteboard, or WindowServer: `open` and `osascript` hand work to processes outside the sandbox.
- Secret reads are denied in the default tier: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/Library/Keychains`, `~/.config/gh`, `~/.git-credentials`, `~/.npmrc`, `~/.pypirc`, `~/.docker/config.json`, `~/.kube`, `~/.config/gcloud`, and browser profiles and cookies. A sandboxed job could otherwise copy a token into the project for a later approved `git push`, or a network-tier `npm install` could run a postinstall script that reads it. The network tier opens the subset that `git`, `ssh`, and the osxkeychain credential helper need, and only when every network command in the call is `git`, `ssh`, or `scp`: `~/.ssh`, the ssh agent's socket, `~/Library/Keychains`, and the Security services. Other network calls, such as `curl` and `npm install`, get the network without credentials, and the ssh agent's socket stays closed to them.
- The GPU tier adds the `AGXDeviceUserClient` and `IOSurfaceRootUserClient` IOKit clients and the `com.apple.MTLCompilerService` XPC service. PyTorch MPS and MLX both run with them. A GPU denial often does not look like an error: PyTorch reports MPS as unavailable and runs on the CPU, while MLX fails with "No Metal device available". Computer's exit report must say that the sandbox blocked the GPU. The Metal shader cache in the per-user cache folder stays closed, so shaders compile again in each job.
- Inside the project, git's hooks and config stay read-only, and so do the files that point git at other hooks and config: `hooks`, `config`, `config.worktree`, and `commondir`, at the top of `.git` and in the git directories under `.git/modules` and `.git/worktrees`, and `.git` itself when it is a file. A sandboxed write there would run with full access during the next approved unsandboxed `git commit` (hooks, `core.hooksPath`, `core.fsmonitor`). Protecting only `hooks` and `config` is not enough: with a planted `.git/commondir`, git read the config and hooks of another directory, and a commit ran a hook from there. The rule matches these names with a regular expression, so renaming `.git/hooks` and creating a new one is denied too. Git commands that write config need escalation.
- Some tools ignore `TMPDIR` and write to the per-user temp folder (`/var/folders/…/T`): Foundation's atomic saves stage in `TemporaryItems`, swift-driver under SwiftPM's build service makes `TemporaryDirectory.*`, and the JVM writes `hsperfdata_<user>` and Bazel's `bazel-jni.*`. Only those names are writable. The rest of the folder stays closed, because xcrun keeps its tool lookup cache there (`xcrun_db`), and every tier reads it.
- Computer's own state, rules, and profiles live in its Application Support folder, outside every writable root. The socket and job output in the shared container are not writable from the sandbox; jobs write through inherited file descriptors.
- Profiles are passed with `-p` and parameterized with `-D` (project root, permitted folders, job temp directory, home).

Tools that apply their own Seatbelt fail inside ours with `sandbox_apply: Operation not permitted` (exit 71). SwiftPM's manifest sandbox and Bazel's Darwin sandbox do this. Bazel also writes its output base outside the project and leaves a server running. Analysis classifies such commands as unsandboxed up front, so the user is asked before a confusing failure.

Unsandboxed builds run whatever the agent wrote into the project, which neither the user nor the reviewer can judge from the command. So the first choice is to turn off the tool's own sandbox and run the build inside ours: `swift build --disable-sandbox`, and Bazel with `--spawn_strategy=local` and an `--output_user_root` in a permitted folder. The Bazel server outlives the job, so each tier gets its own output root, and a server started at one tier never serves a call from a lower one. Builds that work this way move to the default or network tier in the known-needs table; the rest stay unsandboxed.

- **SwiftPM:** `swift build --disable-sandbox` builds and runs in the default tier.
- **Bazel:** needs the network tier, because its client talks to its server over localhost. It also needs `--repo_env=TMPDIR=…` and `--action_env=TMPDIR=…`, because it removes `TMPDIR` from repository rules and actions, and clang then falls back to the closed per-user temp folder. Its output root and temp folder go in the project's cache folder. With these, a genrule builds. A `cc_binary` fails the same way it does unsandboxed, because Bazel 7.6.1's C toolchain rejects the Xcode 27 SDK.

Denial reports come from the unified log. Each job's profile tags its denials with `(deny default (with message "<tag>"))`, and the same tag goes on every explicit deny. Computer runs one `log stream` for as long as it runs, with the predicate `eventMessage CONTAINS "<session suffix>"`, and assigns each denial to its job by the tag. The stream needs to be running before the job starts.

- **Not `log show`:** it missed most denials that the stream reported.
- **Not stderr:** stderr is not a usable signal. PyTorch prints nothing, Foundation says "You don't have permission", and pip says "Permission denied".
- **Classification:**
    - GPU user clients and the Metal compiler service suggest the GPU tier.
    - `network-outbound`, including the mDNSResponder socket, suggests the network tier.
    - A write outside the writable roots names the path.
    - Lookups that tools make and do without are ignored: LaunchServices, DiskArbitration, FSEvents, analytics, and `/dev/tty`. So are cache and telemetry writes outside the roots.

## Command analysis

Computer embeds the tree-sitter C runtime and the tree-sitter-bash grammar, built with Bazel. Analysis turns one `command` string into a list of simple commands. Each has a literal argv or is marked dynamic.

A simple command is dynamic, and no rule can match it, when it contains:

- a parse error anywhere in the tree;
- an expansion in the command name position: `$VAR`, `$(…)`, backticks, globs;
- `eval`, `source`, `.`, or process substitution;
- zsh syntax that tree-sitter-bash does not model:
    - a word starting with `=`: zsh replaces `=name` with the path of `name`, so `echo =====` fails with `==== not found`;
    - an unquoted `(` inside a word: glob qualifiers such as `*(e:…:)` run code;
    - `${(` parameter flags.

Wrappers are unwrapped to the command they run: `env`, `command`, `builtin`, `exec`, `nohup`, `time`, `nice`, `timeout`, and `bash`/`sh`/`zsh -c`, whose string is parsed recursively. `xargs`, `find -exec`/`-execdir`/`-ok`, and `git -c`/`--exec-path` keep their command name but are dynamic in their arguments.

Commands run as `/bin/zsh -f -c`. `-f` skips the user's rc files, so aliases and functions cannot make the argv that runs differ from the analyzed one. The environment comes from a snapshot of the user's login shell (`zsh -l -i`), taken when Computer launches and refreshed from the tray. The snapshot carries `PATH` and Homebrew variables. Shell functions such as `nvm` do not carry over.

A known-needs table, kept as data in Computer, maps argv prefixes to the tier they need:

| Tier | Prefixes |
| --- | --- |
| Network | `git push`, `git fetch`, `git pull`, `git clone`, `curl`, `npm install`, `bazel` with `--spawn_strategy=local` |
| Unsandboxed | `bazel` without `--spawn_strategy=local`; `swift build`, `swift test`, and `swift run` without `--disable-sandbox`; `xcodebuild`, `brew`, `open`, `osascript` |

Commands not in the table run in the default sandbox. GPU use is not visible in the argv (`python3 train.py`), so the GPU tier comes from the model's request, usually after a denial hint.

## Approval and rules

The approval panel is a non-activating floating panel attached to the menu-bar item. It shows:

- the project and the working directory;
- the command;
- each simple command that needs more than the sandbox, and why;
- each simple command that would run with the grant without needing it;
- the model's justification.

Several pending approvals queue in the same panel.

The buttons are **Deny**, **Allow once**, and **Always allow `<prefix>` here**. The last is absent when any simple command is dynamic. For GPU, the last button is **Always allow GPU in this project** instead. It covers every command in the project, dynamic ones included, because the GPU grant opens no files or network. For the unsandboxed tier, the panel says the command runs project code with full access: approving `make` or `npm test` approves whatever the project contains.

A rule is a project root, a grant (network or unsandboxed), and an argv prefix as tokens; GPU is granted per project instead. A grant applies to the whole invocation, so every simple command in it runs with the grant, not only the one that needed it. An invocation is covered only when every simple command in it is covered for each grant the invocation gets: GPU from the project's GPU grant, network or unsandboxed from a rule whose prefix matches. An unsandboxed rule also covers network and GPU. The exception is a short list of utilities that cannot use the network or run other programs, such as `cd`, `echo`, `cat`, `grep`, `head`, `tail`, and `wc`. So `cd web && npm test` and `swift build 2>&1 | tail -50` match rules for `npm test` and `swift build`, while a rule for `git push` does not give the network to `npm publish` in `git push && npm publish`. Matching is token-wise on the analyzed argv, never on the command string. A string prefix would let `git push && curl … | sh` through. Rules live in Computer's Application Support, keyed by the project's resolved path. The tray offers Forget rules for this project.

Only Computer's own UI creates rules. Outside Approve for me, only Computer's own UI approves. In Approve-for-me projects, the reviewer also checks calls that rules cover. Local Code, and the model behind it, can request a tier but cannot approve one.

## Approve for me

Approve for me is a per-project mode in which a reviewer model approves the calls it judges safe and sends the rest to the user. It also reviews calls that a stored rule covers, as a check on a rule matching a call the user would not have wanted. The user turns it on for a project in Computer's menu; Local Code cannot turn it on. The menu-bar icon shows when the mode is on. The setting is keyed by the project's resolved path, like rules.

```text
needs a grant
     │
     ├─ a rule covers it ─ Approve for me off ─────────────────▶ run
     │                     │ on
     │                     ▼
     │             review at the rule cutoff ─ flagged / error / timeout ─▶ panel
     │                     │ approve
     │                     ▼
     │                    run
     │
     └─ no rule ─ Approve for me off ──────────────────────────▶ panel
                  │ on
                  ▼
          Computer's hard limits ─ always ask ─────────────────▶ panel
                  │
                  ▼
          review at the main cutoff ─ flagged / error / timeout ─▶ panel
                  │ approve
                  ▼
               run once
```

- **Who reviews:** Computer has no model.
    - It sends `review` to Local Code and waits for a `verdict`: approve, or ask the user with the reviewer's top concern.
    - The review is a separate short conversation. It is not a temporary ask (`CodeAgent.ask(temporary: true)`), because that runs on top of the agent's context, including the tool output that may have steered the agent.
    - A local reviewer runs while the agent waits on its tool call ([CodeAgent Scheduling](CodeAgentScheduling.md), "Tool Calls as Scheduling Points").
    - The reviewer model is pplx-decider-flash-v1.2, a 4.5B fine-tune of Qwen3.5-4B (Apache-2.0). It answers one `concern` question about the command, given as JSON with the user's request. It approves a call that needs approval when P(none) is at least 0.430, and a call that a stored rule covers when P(none) is at least 0.093; otherwise it asks the user. In the [local eval](../Eval/CLEF_MONITORINGBENCH_BENCHMARK.md), these cutoffs flag 5% and 1% of other steps.
    - Local Code runs it with SwiftLLM's `PerplexityDeciderFlashDecision`, from a 4.0 GB checkpoint that uses Unsloth's Qwen3.5-4B UD-Q6_K_XL tensor types with `.hadamard256`. It scores the same as F16 on the local eval.
- **What it sees:**
    - the user's own messages in the thread;
    - the command and Computer's analysis of it (simple commands, the grants they need, and why);
    - the agent's justification, labelled as the requester's claim.

  It never sees tool output, file contents, web pages, or the agent's reasoning.
- **Hard limits:** Computer enforces these whatever the verdict says.
    - A reviewer approval covers one call. Only the user creates rules.
    - Dynamic or unparsed commands are never approved for the unsandboxed tier.
    - `launchctl`, `crontab`, `osascript`, `security`, and `defaults write` always go to the user: they persist beyond the job or change system settings.
    - An error, a timeout, or an unreadable verdict goes to the panel.
- **Flagged calls:** the reviewer never denies. A flagged call opens the panel with the reviewer's top concern, such as "outside the user's request". A denial there comes from the user and returns to the model as usual.
- **Blind spot:** the reviewer judges the command, not the project code it runs. An unsandboxed `make` or `npm test` approves whatever the agent wrote, which is why builds move into the sandbox where they can (see Permission tiers).
- **Audit:** the menu does not list approvals made for the user. Where they are recorded, with the reviewer's P(none), is an open question.
- **Trust:** Computer verifies that a verdict comes from the signed Local Code app, but it cannot verify the review itself. The user accepts that trade by turning the mode on in Computer.

## Processes and the tray

Each job is spawned with `posix_spawn` and `POSIX_SPAWN_SETSID`, so it gets its own session and process group. Stop sends `SIGTERM` to the group and `SIGKILL` after 3 seconds. The unsigned ASan Catalyst build already spawns and kills this way (`Apps/LocalCodeCatalyst/Support/ios_system/ios_system.swift`).

Processes that call `setsid` themselves leave the group: the Bazel server, `nohup` jobs, development servers. macOS has no cgroups. While a job runs, Computer snapshots its process tree. After the job ends, descendants that are still alive are listed in the tray under Left running, each with Kill. This is best effort.

The menu-bar icon shows idle, running, or waiting for approval. Its menu lists:

- pending approvals, which open the panel;
- running jobs, each with the first line of the command, the project, elapsed time, a tier badge, and Kill;
- processes left running, each with the job that started it and when that job finished;
- each project, with Approve for me and Forget rules for this project;
- Reload environment and Quit.

The menu does not list finished jobs or the reviewer's approvals.

Quitting Computer stops its jobs, so Quit asks first when jobs are running.

## Connection and launch

Both apps claim the same team-prefixed App Group. Computer listens on a Unix domain socket in the group container and writes job output files there. Keep the socket name short: `sun_path` holds 104 bytes, including the home directory part of the path.

For each connection, Computer reads the peer's audit token (`LOCAL_PEERTOKEN`) and checks its code signature: Apple anchor, Local Code's bundle identifier, and the team identifier. Development builds need a debug override. Localhost TCP is not used, since any local process could connect, including our own sandboxed jobs.

Messages are length-prefixed JSON. Local Code sends `run`, `stop`, and `withdraw`. Computer sends `waiting`, `started`, `exited`, and the full job list. In Approve-for-me projects, Computer also sends `review`, and Local Code answers with `verdict`. Local Code mirrors the job list into `BashJobRegistry.runningJobs`, sending the full state on every change. Settings → Activities → Processes then shows and stops Computer jobs as it does today.

Local Code opens Computer with a custom URL scheme. When the scheme is unavailable, it links to the download page. On first launch, Computer registers itself as a login item with `SMAppService.mainApp`.

## Updates

Computer updates itself with Sparkle 2 from an EdDSA-signed appcast. Computer is not sandboxed, so Sparkle's XPC installer services are not needed. The relaunch for an update waits until no job is running and no approval is pending.

Local Code updates through the Mac App Store and Computer through Sparkle, so either can be newer. The connection starts with a protocol version handshake. When the versions are incompatible, Local Code uses the in-process backend and tells the user which app to update.

## Main app integration

- **Backend:** a `CommandExecutionBackend` that talks to Computer. It is used when Local Code runs on a Mac, Computer is connected, and the user turned it on. Otherwise Bash uses the in-process backend.
- **Switching:**
    - The backend is chosen at each `bash` call.
    - A thread switches only when none of its jobs is running. Until then, new calls stay on the backend of its running jobs.
    - `bash_wait`, `bash_status`, and `bash_stop` always go to the backend that started the job.
    - `BashJobRegistry` allocates job ids across both backends.
    - If Computer disconnects, its jobs end with the stop reason "Local Code Computer disconnected."
- **Prompt:** switching must not change the prompt, so the KV prefix survives.
    - The Mac runtime section describes both backends: zsh, the user's toolchains, the tiers, and how to request escalation.
    - Each `bash` result names the backend that ran it. `remoteMacSystemPrompt` in `Sources/RemoteAPI/RemoteSystemPrompt.swift` already allows for a tool that reports a different backend.
    - The local tool schema is in `Sources/Agent/SystemPrompt.swift`.
- **Schema:** on the Mac, `bash` always has `escalation` (a list of `"gpu"`, `"network"`, and `"unsandboxed"`) and `justification`, so the schema never changes on a switch. The in-process backend reports them as unsupported.
- **Filesystem:** Bash and the file tools must see the same files ([TerminalBench compatibility](../TerminalBenchCompatibilityHandoff.md), "One task filesystem for every tool"). On the same Mac they do, because Computer opens the project path directly. Folders granted through `permit` become extra writable roots for that project.
- **Privacy prompts:** macOS attributes Computer's child processes to Computer, so Desktop, Documents, and Downloads prompts name Local Code Computer.

## Platform facts

Verified on macOS 27.0.1 (26A434) on 2026-10-17:

- `/usr/bin/sandbox-exec` ships and enforces a profile. A write inside the writable root succeeded, a write outside failed with "operation not permitted", and DNS failed under `(deny network*)`.
- A sandbox cannot be applied inside another: `sandbox_apply: Operation not permitted`, exit 71.
- zsh expands `=word`: `echo =====` fails with `==== not found`.

Verified on the same Mac on 2026-10-26, by running `sandbox-exec` with the [Verified profile](#verified-profile) from a terminal:

- **Default tier:** these run with the default tier's Mach allowlist:
    - git: commit, branch, checkout, stash, and gc;
    - clang, make, CMake, and swiftc;
    - `swift build --disable-sandbox`;
    - python3 with a venv and multiprocessing;
    - node and `npm test`;
    - go.
- **Network tier without credentials:** `curl`, `git ls-remote` over HTTPS, `npm view`, and `pip install mlx` work. `ssh` fails, because the keys, `known_hosts`, and the agent are closed.
- **Network tier with credentials:** `ssh -T git@github.com` and `git ls-remote` over SSH work. `git push` was not run.
- **GPU tier:** PyTorch MPS and MLX run on the GPU. Without it, PyTorch silently uses the CPU and MLX fails to import.
- **Hand-offs:** these fail in every tier but unsandboxed:
    - `open`, because LaunchServices is closed;
    - Apple Events to other apps, with error -10827;
    - `pbcopy`;
    - `launchctl list` and `launchctl submit`.
- **Denial reports:**
    - `log stream` reported every denial, each followed by its `with message` tag on the next line. Predicates with `CONTAINS` and with `ENDSWITH`, as Anthropic's [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) uses, both matched.
    - `log show` missed most denials.
    - The stream was tested as an admin user.

[sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) (`@anthropic-ai/sandbox-runtime` 0.0.81, Apache-2.0) wraps `sandbox-exec` the same way. Its default profile allows LaunchServices, the Security services, and distributed notifications, which none of the commands above needed. It protects only `.git/hooks` and `.git/config` from writes, which misses the `commondir` redirect.

`sandbox-exec` is marked deprecated in its man page, so keep the backend replaceable.

Not yet verified; these are the next experiments:

1. A child spawned by a Mac App Store build inherits App Sandbox. This is the premise for a separate app; it comes from Apple documentation and has not been re-checked.
2. A Mac App Store app and a Developer ID app share a team-prefixed App Group container without a privacy prompt, and both can use a socket in it.
3. The peer code-signing check accepts the Mac App Store build of Local Code and rejects other processes.
4. Computer reads projects inside Local Code's container without the "access data from other apps" prompt. This is expected for apps from the same team.
5. The osxkeychain credential helper reads a GitHub token in the network tier with credentials. This Mac has no HTTPS credential for GitHub, so only the denial without credentials was checked.
6. `log stream` reports sandbox denials when Computer runs as a standard user.
7. App Review accepts a Mac App Store app that links to a separately downloaded companion (guideline 2.4.5), given that Local Code works without it.

## Open questions

- **Cache writes:** allow a fixed list of tool caches (`~/.npm`, `~/.cache`, `~/Library/Caches/<tool>`), or redirect caches to a per-project folder through environment variables. The first risks poisoning shared caches; the second costs cold caches.
    - The experiments used the second. These variables point into a cache folder for the project, outside the project, that every tier of the project uses: `XDG_CACHE_HOME`, `CLANG_MODULE_CACHE_PATH`, `GOCACHE`, `GOMODCACHE`, `npm_config_cache`, and `PIP_CACHE_DIR`. Bazel takes its output root and temp folder there by flag.
    - A cache that every tier of one project shares carries the project's own trust: the project's code already runs in every tier. A shared cache would let one project's sandboxed job affect other projects and Xcode.
    - swiftc failed without the redirect, because its clang module cache was closed. Tools without an override, such as SwiftPM's manifest cache and Go's telemetry, fail to write and carry on.
- **Local servers:** the experiments give binding, accepting, and connecting on this Mac to the network tier, so a development server needs it. The default tier could allow binding and accepting, so the browser could reach a server. Tests that connect to the server also need outbound localhost, which reaches local databases and other services as well.
- **Reviewer memory:** the reviewer checkpoint takes 4.0 GB beside the agent's model. Keep it loaded while any project has Approve for me on, or load it for each review and pay the load time.
- **Reviewer threshold:** pplx-decider-flash was chosen on 2026-10-18 at 5% of other steps flagged, and 1% for calls that rules cover; 5% to 10% is still under consideration for the main cutoff. No public eval matches the reviewer's input: user messages, one command, its analysis, and a justification, judged approve or ask the user.
    - The closest public reference is [MonitoringBench with its benign set](https://lesswrong.com/posts/bdBoH23TCTFZkkfqp/releasing-benign-trajectories-for-monitoringbench): bash, with 550 attack and 550 benign trajectories. As whole-trajectory monitors, Qwen 3.8 27B scores TPR 0.860 / FPR 0.204 and DeepSeek V4 Flash scores 0.485 / 0.031; the threshold is not stated.
    - [R-Judge](https://github.com/Lordog/R-Judge) and [ASSEBench](https://github.com/Astarojth/AgentAuditor-ASSEBench) add cases that pair the user's request with injected instructions.
    - [Claude Code auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode) uses the same reviewer input (user messages and tool calls, with assistant messages and tool outputs stripped). Its eval sets are not public.
    - [Local per-action eval](../Eval/CLEF_MONITORINGBENCH_BENCHMARK.md) on 2,442 MonitoringBench attack steps against other steps from the same runs: pplx-decider-flash with the JSON state catches 47% of attacks at 5% of other steps blocked and 58% at 10%. Counting only the 58% of attack steps whose command shows the attack, it catches 74% and 85%. On an M5 Max, the quantized Swift checkpoint takes about 0.3 s for a review of the median 1,600 tokens when that length has run before, and about 0.75 s for a new length, because some kernels still compile per length. pplx-decider (27B), asked only `concern`, catches 55% and 61%, and 85% and 91% of the visible ones, at about 3.4 s. Clef (27B) catches 43% and 61% at about 4 s; Clef-flash catches 32% and 45%. None is good enough to approve unsandboxed commands alone.

## Invariants

- The Seatbelt profile is the boundary. Analysis never lowers the tier a call needs; it only decides whether to ask.
- Nothing runs above the default sandbox without one of these: a matching rule, an approval in Computer's own UI, or a reviewer approval in a project where the user turned on Approve for me in Computer. In Approve-for-me projects, a matching rule also needs the reviewer's approval or the user's.
- The model can request a tier but cannot approve one. Local Code approves only through the reviewer, and only in Approve-for-me projects. It never creates rules, changes profiles, or turns the mode on.
- The reviewer never sees tool output, file contents, web pages, or the agent's reasoning. Computer's hard limits apply whatever it decides.
- Nothing writable from the default sandbox is executed by, or read as policy for, a higher tier, except the project and its cache folder: rules, profiles, the project's git hooks and config and the files that redirect git to others, and shared caches such as `xcrun_db`.
- Dynamic or unparsed commands never match a stored rule.
- A grant covers the whole invocation, so a rule covers it only when every simple command in it, apart from the inert utilities, matches a rule for that grant.
- Every job runs in its own session, and stop signals the whole group.
- A job stays on the backend that started it. A thread switches backends only when none of its jobs is running.
- Bash and the file tools see the same filesystem.

## Verified profile

The profile from the 2026-10-26 experiments. A job's profile is the default tier, followed by the GPU and network sections it was granted. Later rules win, so the credentials section reopens what the default tier denies.

Computer writes `@TAG@` per job, and passes these parameters with `-D`:

- `HOME`: the user's home folder.
- `PROJECT`: the project root, resolved.
- `PROJECT_RE`: the project root, escaped for a regular expression.
- `JOB_TMP`: the job's `TMPDIR`.
- `CACHE`: the project's cache folder.
- `USER_TEMP_RE`: the resolved per-user temp folder (`/private/var/folders/…/T`), escaped.

Permitted folders would join `PROJECT` in the write rule; the experiments had none.

Default tier:

```scheme
(version 1)
(deny default (with message "@TAG@"))

; Processes: run anything, but only signal and inspect our own sandbox.
(allow process-exec process-fork)
(allow process-info* (target same-sandbox))
(allow signal (target same-sandbox))
(allow mach-priv-task-port (target same-sandbox))
(allow sysctl-read)
(allow user-preference-read)
(allow ipc-posix-shm ipc-posix-sem)
(allow system-info (info-type "vfs.disk-space"))

; User and group lookups, notify(3), the per-user folder lookup, logging, and power management.
; Bazel aborts without the power management client and service.
(allow mach-lookup
  (global-name "com.apple.system.opendirectoryd.libinfo")
  (global-name "com.apple.system.opendirectoryd.membership")
  (global-name "com.apple.system.notification_center")
  (global-name "com.apple.bsd.dirhelper")
  (global-name "com.apple.logd")
  (global-name "com.apple.diagnosticd")
  (global-name "com.apple.PowerManagement.control"))
(allow iokit-open-user-client (iokit-user-client-class "RootDomainUserClient"))

; Reads: everything except secrets.
(allow file-read*)
(deny file-read* (with message "@TAG@")
  (subpath (string-append (param "HOME") "/.ssh"))
  (subpath (string-append (param "HOME") "/.aws"))
  (subpath (string-append (param "HOME") "/.gnupg"))
  (literal (string-append (param "HOME") "/.netrc"))
  (subpath (string-append (param "HOME") "/Library/Keychains"))
  (subpath (string-append (param "HOME") "/.config/gh"))
  (literal (string-append (param "HOME") "/.git-credentials"))
  (literal (string-append (param "HOME") "/.npmrc"))
  (literal (string-append (param "HOME") "/.pypirc"))
  (literal (string-append (param "HOME") "/.docker/config.json"))
  (subpath (string-append (param "HOME") "/.kube"))
  (subpath (string-append (param "HOME") "/.config/gcloud"))
  (subpath (string-append (param "HOME") "/Library/Cookies"))
  (subpath (string-append (param "HOME") "/Library/Safari"))
  (subpath (string-append (param "HOME") "/Library/Application Support/Google/Chrome"))
  (subpath (string-append (param "HOME") "/Library/Application Support/Firefox")))

; Writes: the project, the job's TMPDIR, the project's cache folder, and harmless devices.
(allow file-write* (subpath (param "PROJECT")) (subpath (param "JOB_TMP")) (subpath (param "CACHE")))
(allow file-write-data file-ioctl
  (literal "/dev/null") (literal "/dev/zero") (literal "/dev/dtracehelper"))
(allow file-ioctl (literal "/dev/random") (literal "/dev/urandom"))

; Git hooks, config, and the files that redirect git to other hooks and config stay read-only, at
; the top of .git and in submodule and worktree git directories. Matching by name also covers renames.
(deny file-write* (with message "@TAG@")
  (literal (string-append (param "PROJECT") "/.git"))
  (regex (string-append "^" (param "PROJECT_RE")
    "/\.git/(modules/.+/|worktrees/[^/]+/)?(hooks(/.*)?|config|config\.worktree|commondir)$")))

; Tools that ignore TMPDIR: Foundation's atomic saves, swift-driver under SwiftPM's build service,
; and the JVM. The rest of the per-user temp folder stays closed; it holds xcrun_db.
(allow file-write* (regex (string-append "^" (param "USER_TEMP_RE")
  "/(TemporaryItems|TemporaryDirectory\.[^/]+|hsperfdata_[^/]+|bazel-jni\.[^/]+)(/|$)")))
```

GPU:

```scheme
(allow iokit-open-user-client
  (iokit-user-client-class "AGXDeviceUserClient")
  (iokit-user-client-class "IOSurfaceRootUserClient"))
(allow mach-lookup (xpc-service-name "com.apple.MTLCompilerService"))
```

Network:

```scheme
; Outbound IP connections, DNS through mDNSResponder, and servers on this Mac. Other Unix sockets,
; such as the ssh agent, stay closed. Dual-stack sockets bind as ::ffff:127.0.0.1, which "localhost"
; does not match.
(allow system-socket (socket-domain AF_INET) (socket-domain AF_INET6) (socket-domain AF_UNIX))
(allow network-outbound (remote ip "*:*"))
(allow network-outbound (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
(allow network-bind (local ip "*:*"))
(allow network-inbound (local ip "*:*"))
(allow mach-lookup
  (global-name "com.apple.SystemConfiguration.DNSConfiguration")
  (global-name "com.apple.SystemConfiguration.configd")
  (global-name "com.apple.trustd.agent"))
```

Network credentials, when every network command in the call is `git`, `ssh`, or `scp`:

```scheme
(allow file-read* (subpath (string-append (param "HOME") "/.ssh")))
(allow network-outbound
  (remote unix-socket (regex #"^/private/var/run/com\.apple\.launchd\.[^/]+/Listeners$")))
(allow mach-lookup (global-name "com.apple.dnssd.service"))
; The osxkeychain credential helper. Not yet verified with a stored credential.
(allow file-read* (subpath (string-append (param "HOME") "/Library/Keychains")))
(allow mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd.xpc"))
```

Jobs also get these environment variables, so caches land in the project's cache folder: `TMPDIR`, `XDG_CACHE_HOME`, `CLANG_MODULE_CACHE_PATH`, `GOCACHE`, `GOMODCACHE`, `npm_config_cache`, and `PIP_CACHE_DIR`.
