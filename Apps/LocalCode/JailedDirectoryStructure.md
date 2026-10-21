# Local Code jailed directory structure

- Status: Rejected
- Scope: The in-process `ios_system`, NodeMobile, and PythonIOS command backend
- Last updated: 2026-07-24

This design is retained as historical rationale. Local Code will not construct
a virtual filesystem or an application-level jail. The selected real-path
environment and directory aliases are documented in
[`DirectoryEnvironment.md`](DirectoryEnvironment.md).

The virtual design was rejected because enforcing it consistently would
require filesystem integration across OSH, static commands, Node/libuv,
CPython, and their native libraries. The app already has a platform sandbox,
and exposing the configured workspace through real paths keeps the embedded
runtimes interoperable without that additional layer.

## Summary

Local Code should expose one stable virtual filesystem to OSH, statically
registered commands, NodeMobile, and PythonIOS. The virtual filesystem is
rooted in explicit capabilities supplied by Local Code; it must not expose
Darwin paths and must not depend on the process-wide current directory.

The jail boundary is the configured workspace, not only the active project.
This is intentional: commands may inspect or modify sibling projects when that
is useful. The active project determines `HOME` and the initial working
directory.

The app-wide cache temporary directory is also intentionally mounted. It is
shared across projects, may be purged by the operating system, and must not
provide access to the rest of the app's Library directory.

## User-visible namespace

| Virtual path | Backing resource | Access |
| --- | --- | --- |
| `/` | Synthetic root directory | List and traverse |
| `/home` | Configured Local Code workspace | Read/write |
| `/home/<project-relative-path>` | Active project | Initial working directory and `HOME` |
| `/tmp` | App `Library/Caches/tmp` directory | Read/write |
| `/usr/bin` | `ios_system` static command registry | List and execute |
| `/dev/null` | Synthetic null device | Read/write |
| `/.runtime/...` | Explicit bundled runtime resources | Read-only |

The synthetic root is not writable. `ls /` should expose only the configured
mounts. It must not reveal the application container, the Darwin root, or host
paths used to back a mount.

The project path is its actual path relative to the configured workspace, not
a sanitized display name. For the common case it is
`/home/<project-directory-name>`. Nested projects retain their relative
components. If the workspace root itself is the active project, `HOME` and the
initial working directory are `/home`.

An active project must be the workspace root or one of its descendants. If a
standalone external project is supported without a separately authorized
workspace, that project becomes the workspace root and is exposed as `/home`;
Local Code must not infer and grant access to its host parent directory.

## Path behavior

At the start of a command:

```text
HOME=/home/<active-project>
PWD=/home/<active-project>
TMPDIR=/tmp
```

For a workspace-root project, `HOME=/home` and `PWD=/home`.

Expected navigation includes:

```text
cd ~          -> active project
cd /home      -> workspace root
cd ..         -> virtual parent, never a host parent
cd /tmp       -> shared app cache temporary directory
cd /          -> synthetic root
```

`..` follows the virtual namespace. In particular, `/tmp/..` is `/`, not the
host parent of `Library/Caches/tmp`. Walking above `/` remains at `/`.

An absolute symlink target is interpreted in the virtual namespace. A relative
symlink target is interpreted relative to the symlink's virtual parent.
Following a symlink must never escape the mount selected by the resolved
virtual target.

The `/tmp` mount is intentionally shared between projects. It is appropriate
for temporary downloads, compiler scratch data, and disposable caches. It is
not durable storage and Local Code may prune it. The resolver must prevent
symlinks, `..`, open directory descriptors, rename, or link operations from
escaping from `/tmp` into the rest of `Library/Caches`.

The direct `ios_system(int argc, const char *const argv[])` API receives
already-tokenized arguments and preserves a literal `~`. Tilde expansion is a
shell operation performed by OSH using `HOME`.

## Environment paths

All paths visible to command code must use the virtual namespace. Host backing
paths must not appear in `process.env`, `os.environ`, error messages, `pwd`,
`process.cwd()`, `os.getcwd()`, `realpath`, or tool output.

The intended environment includes:

| Variable | Virtual value |
| --- | --- |
| `HOME` | Active project under `/home`, or `/home` for the workspace-root project |
| `PWD` | Current virtual working directory |
| `TMPDIR` | `/tmp` |
| `PATH` | Active project `node_modules/.bin`, other approved workspace bins, then `/usr/bin` |
| `NPM_CONFIG_CACHE` | Active project `.localc/node/cache` |
| `PIP_PREFIX` | Active project `.localc/python` |
| `PYTHONUSERBASE` | Active project `.localc/python` |
| `XDG_CACHE_HOME` | Active project `.localc/cache` |
| `XDG_CONFIG_HOME` | Active project `.localc/config` |
| `XDG_DATA_HOME` | Active project `.localc/share` |
| `XDG_STATE_HOME` | Active project `.localc/state` |
| `PYTHONHOME` and runtime resource paths | Read-only paths below `/.runtime` |

`PIP_PREFIX` keeps runtime installs inside the active project's
`.localc/python` tree while allowing pip to satisfy dependencies from both the
project and the bundled Python environment. `PIP_TARGET` is not used because
pip treats target installs as isolated and ignores already-installed bundled
distributions. If a project installs a different version of a bundled
pure-Python package, the project copy shadows it; pip must not uninstall the
read-only bundled copy.

`NODE_PATH` remains unnecessary for normal project-local `node_modules`
resolution.

Python reuses its main interpreter. When the path context changes, its
environment refresh must update these variables, refresh managed `sys.path`
entries, invalidate import caches, and clear cached temp-directory selection
such as `tempfile.tempdir`.

## Security and compatibility boundary

This jail provides a consistent workspace namespace inside the app's existing
platform sandbox. It is not an OS process boundary and does not protect the app
from memory corruption in embedded native code.

The filesystem policy must nevertheless apply consistently to:

- OSH built-ins, expansion, globbing, and redirection;
- every statically registered `ios_system` command;
- Node module loading, `fs`, `process.cwd()`, `process.chdir()`, Workers, and
  supported native built-ins;
- Python imports, `_io`, `os`, `pathlib`, `tempfile`, `mmap`, threads, and
  bundled native extensions; and
- both endpoints of create, remove, rename, hard-link, and symbolic-link
  operations.

A JavaScript preload, Python audit hook, string-prefix test, or shell-only path
rewrite is useful for diagnostics but is not an enforcement boundary. A path
rejected by `cd` must not remain accessible through Node `fs`, Python `open`,
or shell redirection.

Native addons and native executables installed into a project remain outside
the supported iOS execution model. Pure JavaScript, WebAssembly, pure Python,
and native libraries compiled into the application still need the same
filesystem policy.

## Path context

Replace process-global mini-root state with an opaque, reference-counted path
context owned by each `ios_system` session. Conceptually it contains:

```c
typedef struct ios_path_context ios_path_context;

typedef struct {
  const char *workspace_host_path;
  const char *active_project_relative_path;
  const char *temporary_host_path;
  const ios_runtime_mount *runtime_mounts;
  size_t runtime_mount_count;
} ios_path_context_configuration;
```

The real API should use opaque handles and explicit creation, retain, release,
and session-attachment functions. It must not use environment variables or
process-global mutable state to select a workspace.

Each directory-backed mount is opened once as a verified directory descriptor.
The context stores:

- the virtual mount table and operation permissions;
- verified root directory descriptors for `/home`, `/tmp`, and runtime mounts;
- the active project's virtual path;
- the current virtual working directory;
- descriptor-to-virtual-path metadata needed by `fchdir`, `dup`, and related
  operations; and
- immutable capability identity used when work crosses runtime threads.

The Darwin process current directory should remain an implementation detail and
should not change for each shell command. Relative path resolution uses the
context's virtual working directory. `chdir` updates the virtual cwd, and
`getcwd` returns it.

## Resolver operations

The core API should resolve an operation, not merely return an unchecked host
string:

```c
typedef enum {
  IOS_PATH_READ,
  IOS_PATH_WRITE,
  IOS_PATH_CREATE,
  IOS_PATH_REMOVE,
  IOS_PATH_METADATA,
  IOS_PATH_LIST,
  IOS_PATH_EXECUTE,
} ios_path_operation;
```

File APIs should prefer a verified parent descriptor plus a final component,
or return an already opened descriptor. Returning a host path and opening it
later reintroduces time-of-check/time-of-use races.

Resolution proceeds as follows:

1. Resolve a relative input against the virtual cwd; absolute inputs start at
   the synthetic root.
2. Normalize virtual `.` and `..` components without consulting host paths.
3. Select the longest matching virtual mount.
4. Check the requested operation against the mount permissions.
5. Traverse the backing directory from its verified root descriptor.
6. Use `openat`, `fstatat`, `readlinkat`, and related descriptor-relative APIs
   with no-follow behavior for each component.
7. Expand symlinks in the virtual namespace, cap expansion depth, and restart
   mount selection when an absolute target changes mounts.
8. Validate the existing parent for a create operation and independently
   resolve both endpoints for rename and link operations.
9. Return the verified descriptor operation or fail closed with an appropriate
   POSIX error.

Apple platforms do not provide Linux `openat2`. Symlink traversal therefore
needs an explicit component walker. Plain `realpath` followed by a string
prefix comparison is insufficient and remains vulnerable to component-prefix
mistakes and races.

Cross-mount hard links and renames should return `EXDEV`, matching normal mount
semantics. Copying between `/home` and `/tmp` remains supported.

Synthetic entries need explicit behavior:

- `/`, `/usr`, `/usr/bin`, `/dev`, and `/.runtime` provide synthesized
  directory metadata and enumeration.
- `/usr/bin/<command>` provides executable metadata and dispatches through the
  static command registry; it is not an ordinary readable host executable.
- `/dev/null` returns a descriptor with normal null-device behavior.
- runtime mounts expose only declared read-only resources.

## Local Code integration

Local Code already owns an explicit configured workspace bookmark and an active
project URL. BashTool currently receives only `projectPath`; that is
insufficient for the `/home` contract.

The command execution dependency should carry:

- the authorized workspace URL or security-scoped bookmark;
- the active project path relative to that workspace;
- the app cache temporary URL;
- the approved runtime resource mounts; and
- the command streams, timeout, and cancellation state.

The workspace must not be inferred from `projectURL.deletingLastPathComponent()`.
For an external workspace, Local Code must keep its security-scoped resource
access active for the complete lifetime of the Bash job and all virtual
children. The path context retains only the capability it was explicitly
given.

The active project is validated as the workspace itself or a descendant before
the context is created. Canonicalizing the host paths is useful for capability
setup, but user operations still go through descriptor-rooted resolution.

## `ios_system`, OSH, and static commands

Add the path context to `sessionParameters` and remove filesystem policy from
the global `miniRoot` and `allowedPaths` variables. The existing APIs may
remain temporarily while callers migrate, but the final implementation should
have one canonical path-context API.

The command thread attaches its session context before entering OSH or a
registered command. Threads created by `ios_system` inherit a retained
reference and release it on exit.

The filesystem shim needs context-aware forms of at least:

- `open`, `openat`, `creat`, `fopen`, and `freopen`;
- `stat`, `lstat`, `fstatat`, `access`, and directory enumeration;
- `mkdir`, `rmdir`, `unlink`, `rename`, `link`, `symlink`, and `readlink`;
- `chmod`, `utimensat`, and other supported metadata mutation;
- `chdir`, `fchdir`, `getcwd`, and `realpath`; and
- `dup`, `dup2`, `close`, and descriptor bookkeeping where virtual directory
  identity must survive descriptor operations.

OSH and every registered utility must be compiled against this shim. This is
what covers redirection and globbing as well as explicit command arguments.
Calls made by unrelated app threads bypass the shim or run with no attached
path context and retain normal app behavior.

## NodeMobile integration

Extend `node_mobile_command_options` with the opaque retained path-context
handle. `NodeRuntimeHost` should stop changing the process cwd through
`WorkingDirectoryScope`; it should attach the supplied virtual cwd to the
disposable Node Environment.

The Node integration must be native:

- route libuv filesystem requests through the path resolver;
- make `uv_cwd` and `uv_chdir` use the virtual cwd;
- retain and propagate the context through libuv filesystem worker requests;
- make Workers inherit the originating context;
- ensure the module loader and `fs.realpath` return virtual paths; and
- inventory native built-ins such as SQLite and give direct filesystem users a
  resolver-aware VFS or equivalent adapter.

The existing virtual-child preload remains responsible for process-free child
semantics, but it is not the filesystem jail. Native `.node` addons remain
unsupported, which materially narrows the native bypass surface.

Runtime resources needed by Node and npm should be mounted read-only below
`/.runtime/node` or supplied through trusted descriptors. They must not require
granting project code a host bundle path.

## PythonIOS integration

Pass the same retained path context into each Python invocation and associate
it with the active interpreter. Rebuild CPython and bundled native extensions
so their filesystem entry points use the resolver-aware POSIX shim.

Coverage must include:

- CPython `_io`, `posix`, import, bytecode cache, `mmap`, and tempfile paths;
- Python-created threads and filesystem calls made from those threads;
- bundled native extension modules that accept path strings; and
- direct native libraries such as SQLite, which need a resolver-aware VFS
  rather than a Python-only wrapper.

Python audit hooks can assert and log expected operations during development,
but they cannot enforce the jail against C extensions. Similarly, replacing
`builtins.open` would not cover imports, `os`, `mmap`, or native code.

The reusable main interpreter must update virtual environment paths and clear
path-derived caches whenever the context changes. Subinterpreters inherit the
invocation's context and release it when destroyed.

Python's bundled standard library, packages, certificates, and data files are
read-only runtime mounts below `/.runtime/python`.

## Phased implementation

### Phase 1: resolver library

- Add the opaque path context, mount model, operation policy, and
  descriptor-rooted component walker.
- Implement synthetic root enumeration and virtual normalization.
- Unit-test the resolver directly with temporary host directories.
- Keep current host paths visible while the resolver matures.

### Phase 2: Local Code capability plumbing

- Pass the configured workspace capability and active project relative path
  through ChatWorkflow, the agent, ToolsRegistry, BashTool, and BashJob.
- Keep external workspace security scope active for the job lifetime.
- Configure `/tmp` from the existing app `Library/Caches/tmp`.
- Attach one context to each `ios_system` session.

### Phase 3: OSH and registered commands

- Replace mini-root cwd checks with virtual cwd operations.
- Route shell redirection, globbing, and static utility filesystem calls
  through the shim.
- Add synthetic `/usr/bin` and `/dev/null`.
- Run the shell and escape test matrix while still logging host/virtual
  translations internally.

### Phase 4: NodeMobile

- Extend the native options ABI with the path context.
- Integrate the resolver with libuv, Node cwd APIs, Workers, the module loader,
  and supported native built-ins.
- Validate npm, npx, project bins, esbuild Wasm, Vite, and VitePress.

### Phase 5: PythonIOS

- Rebuild CPython and native extensions against the path shim.
- Cover imports, file APIs, tempfile, SQLite, mmap, and Python threads.
- Validate project switching in the reused interpreter.

### Phase 6: virtual-path cutover

- Set `HOME`, `PWD`, `TMPDIR`, `PATH`, Python paths, npm paths, XDG paths, and
  runtime paths to their virtual values.
- Make `pwd`, Node, and Python report identical virtual paths.
- Fail closed on raw Darwin absolute paths.
- Remove the legacy mini-root and allowed-path policy after all callers use the
  path context.

The virtual namespace should not be exposed partially. In particular, do not
special-case only OSH's `cd /tmp` or `cd /home`; Node and Python must observe
the same mapping in the same release.

## Validation matrix

Validation must cover macOS, iOS Simulator, and an iOS device where applicable.

### Namespace and environment

- `pwd`, `cd /`, `cd /home`, `cd ~`, `cd /tmp`, and repeated `..`;
- workspace-root and child-project initial directories;
- `HOME`, `PWD`, `TMPDIR`, `PATH`, Python, npm, and XDG variables; and
- identical results from OSH, `process.cwd()`, and `os.getcwd()`.

### Filesystem operations

- relative and absolute read, write, create, append, truncate, and remove;
- redirection, globbing, directory enumeration, and realpath;
- mkdir/rmdir, rename, hard link, symbolic link, and both endpoints;
- file descriptor-relative operations, dup/fchdir, and directories renamed
  after opening; and
- expected `EXDEV` behavior across `/home` and `/tmp`.

### Escape resistance

- `..` above every mount root;
- absolute and relative symlinks targeting another mount or a host path;
- component-prefix collisions such as `workspace` versus `workspace-other`;
- rename and link destination escapes;
- symlink replacement races during create and open;
- attempts to use real `/private`, app container, bundle, and cache paths; and
- attempts to escape `/tmp` into its host parent.

### Runtime behavior

- Node `fs`, `path`, `os.tmpdir`, module resolution, Workers, virtual children,
  npm install, npm exec, npx, Vite, esbuild Wasm, and VitePress;
- Python `open`, `os`, `pathlib`, `tempfile`, imports, pip target, SQLite,
  mmap, threads, native extensions, and project switching; and
- shell/static commands including `ls`, `find`, `cp`, `mv`, `rm`, `mkdir`,
  `ln`, `stat`, `touch`, redirection, and command lookup.

No escape test may fall back to an unchecked host operation after resolver
failure.
