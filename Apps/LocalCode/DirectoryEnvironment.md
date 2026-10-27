# Local Code directory environment

- Status: Implemented
- Scope: BashTool commands launched through `ios_system` and agent file tools
- Last updated: 2026-10-25

## Contract

Local Code exposes real filesystem paths from the app's platform sandbox. It
does not construct a virtual root or an additional application-level jail.

For a configured workspace and active project, every new Bash job starts with:

```text
HOME=<configured workspace path>
PWD=<active project path>
TMPDIR=<app Library/Caches/tmp path>
```

The active project must be the workspace itself or a descendant. When the
workspace itself is selected as the project, `HOME` and the initial `PWD` are
the same path.

Project-local package paths remain based on the active project. This includes
the project `node_modules/.bin`, npm cache, Python user base, pip target, and
managed Python import path. `NODE_PATH` is not needed for ordinary
project-local Node resolution.

The settings workflow keeps the configured workspace authorized while it is
selected. Bash jobs therefore need only the workspace path and can access
sibling projects through `HOME`.

## Home and temporary directories

`~` is the one name for the workspace. OSH expands an unquoted `~` from
`HOME`, as other shells do, and Python, Node, and git read `HOME` directly.
OSH leaves a quoted `~` literal, so `"~/a b"` names a directory called `~`;
write `~/"a b"` instead. There is no `/home` alias.

`$TMPDIR` is the one name for temporary files. There is no `/tmp` alias: in
the app sandbox `/tmp` is not writable, and on a Mac host it is a different
directory from `$TMPDIR`.

The file tools accept `~`, `$HOME`, and `$TMPDIR` at the start of a path, so a
path copied from a Bash command resolves to the same file. They report
workspace paths outside the active project as `~/<path>` and temporary paths
as `$TMPDIR/<path>`, which work unchanged in Bash. A `/tmp/<path>` request
fails with a message that names `$TMPDIR/<path>`, and Bash output that mentions
`/tmp` gets a hint with the real `$TMPDIR` path.

SSH and curl keep per-project state: `SSH_HOME` and `CURL_HOME` are
`<project>/.localc`, so keys, `known_hosts`, the SSH config, `.curlrc`, and
`.netrc` are not shared between projects. In Bash, refer to them through
`$SSH_HOME/.ssh` rather than `~/.ssh`, which is the workspace's.

## App bundle alias

The direct `ios_system` `cd` command recognizes one convenience:

| `cd` input | Real destination |
| --- | --- |
| `cd /app_bundle` | Application resource directory |
| `cd /app_bundle/<path>` | Application resource directory `<path>` |

Alias matching observes component boundaries: `/app_bundleish` is an ordinary
absolute path.

The alias is expanded before `ios_system` updates its logical current directory.
Consequently, `pwd` reports the real destination path rather than
`/app_bundle`. `cd`, `cd ~`, and `cd "$HOME"` all go to the real workspace.

The application bundle is read-only. A successful `cd` through `/app_bundle`
prints `Warning: this directory is read-only.` to stdout.

Apart from `cd`, only the commands that resolve path arguments themselves
accept the alias: `office`, `ffmpeg`, `ffprobe`, `hyperframes`, `html2video`,
`draw-things-cli`, `z3`, `lean`, and `check_lean`. The shell does not rewrite
ordinary arguments, redirections, glob patterns, or paths interpreted inside
Node and Python. Use `$APP_BUNDLE/path` when a real absolute pathname is
required. After changing into the alias, relative filesystem operations
naturally use the real destination.

## Runtime behavior

NodeMobile and PythonIOS need no filesystem patching for this model:

- Node receives the real current directory and synchronizes `PWD` before each
  invocation.
- Python refreshes `HOME` and `PWD` in its reused interpreter environment.
- Both runtimes receive the real `TMPDIR`.
- `process.cwd()`, `os.getcwd()`, OSH `pwd`, and `PWD` agree on real paths.

`cd /` and all other absolute paths retain their normal Darwin meaning,
subject to the app sandbox. There is no synthetic `/.runtime` mount.

Each BashTool call creates a fresh OSH evaluation and resets its initial
working directory to the active project. Directory changes persist within a
single shell command, including command chains, but not across separate Bash
jobs.

## Additional folder access

In the app, `permit "<directory>"` opens a folder picker at the requested path.
The user must select that directory. Relative paths use the Bash job's current
directory; ordinary shell expansion and quoting apply. Already permitted
directories do not prompt again. Cancelling the picker returns a failure without
saving access. Stopping the Bash job dismisses its pending picker.

The app saves a security-scoped bookmark and restores access on subsequent
launches. Grants apply to Bash and every file tool (`read`, `more`, `write`,
`edit`, `search`, and `list`), across projects and turns. The command prints the
canonical absolute path to use with these tools. File tools keep their `~`,
`$HOME`, `$TMPDIR`, and `/app_bundle` prefixes; other absolute paths must fall
inside a known or permitted directory. Unknown absolute paths fail rather than
being interpreted relative to the project.

Kit's **Permitted Folders** section starts with an **Enable** switch, on by default.
Turning it off hides the folder rows, releases active grants, and makes `permit`
refuse requests. Bookmarks and individual folder choices are preserved. Turning
it back on restores the list and reactivates enabled grants.

Each folder has a dropdown containing its full path and **Disabled**, plus a
minus button. Disabled retains the bookmark but releases its active grant;
`permit` refuses requests for that folder and its descendants until the user
re-enables it in Kit. The minus button permanently removes the saved bookmark
and its disabled setting. The switch and disabled choices persist across launches
under `is_permit_enabled` and `disabled_permitted_directories` respectively.

Disabling or removing one grant does not remove access provided by another grant
or by the configured workspace. The OS can retain picker-provided access in the
running process until the app restarts, including for Bash commands.

Picker waiting time is excluded from the Bash timeout and the turn's working
duration through the turn's `BashUserInteraction` intervals. Draw Things model
downloads and generation also suspend the Bash timeout and refresh waits, but
continue counting toward working duration. Bash uses `systemInteractionInterval`,
which includes all intervals; working duration uses only `userInteractionInterval`.
Explicit stop and download / generation cancellation remain available.
