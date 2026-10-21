# Local Code Containerized Command Execution

- Status: Proposed
- Scope: Local Code on macOS through Mac Catalyst
- Last updated: 2026-07-17

## Summary

Local Code should support a Linux container as an optional command-execution
environment on Apple silicon Macs running macOS 26 or later. This is an
additional backend for the existing Bash tools, not a replacement for the
current in-process `ios_system` and PythonIOS environment.

The container runtime will execute in the Local Code process. A native-macOS
Swift library will use `Virtualization.framework`, either through Apple's
Containerization libraries or through a narrower implementation based on the
same architecture. The library will be statically linked into the Mac Catalyst
application using macOS/Mac Catalyst target-variant objects. Local Code will not
launch the `container` CLI, a helper executable, or an XPC service.

The existing backend remains the default:

- iOS and iPadOS continue to use `ios_system` and PythonIOS exclusively.
- Mac Catalyst continues to use `ios_system` and PythonIOS unless the user
  explicitly selects containerized Linux execution.
- Selecting containerized execution when it is unavailable produces an
  availability error. It must not silently fall back to `ios_system`, because
  the two environments have different isolation and compatibility properties.

## Motivation

The current Bash implementation in
[`BashTools.swift`](Sources/Agent/BashTools.swift) runs commands through
`ios_system` inside the application process. This is portable to iOS and
provides a useful embedded Unix and Python environment, but it cannot provide a
complete Linux userspace or arbitrary native Linux packages.

On supported Macs, a VM-backed Linux environment can provide:

- normal Linux binaries, package managers, and toolchains;
- stronger separation between executed code and the application;
- a writable environment that can retain project-specific dependencies;
- normal Linux process, signal, and exit-status behavior; and
- the same Local Code Bash tool contract used by the current backend.

Apple's
[Containerization](https://github.com/apple/containerization/tree/2a591c2aeed6ff0cc70f00a5a8bf06b112b433c2)
project demonstrates the relevant runtime architecture: a lightweight Linux VM,
an OCI root filesystem, `vminitd` communicating over vsock, virtio-fs host
shares, and APIs for executing and controlling Linux processes. Its
[sandboxy example](https://github.com/apple/containerization/tree/2a591c2aeed6ff0cc70f00a5a8bf06b112b433c2/examples/sandboxy)
also demonstrates the specific coding-agent pattern of mounting a workspace
into a cached, isolated Linux environment.

## Goals

- Preserve the existing Bash tool interface and job lifecycle.
- Keep `ios_system` and PythonIOS as a complete, supported backend.
- Add containerized Linux execution only on the Mac Catalyst path.
- Keep all runtime control inside the Local Code process.
- Share the selected project directory with the guest at a stable path.
- Stream stdout and stderr into the existing incremental job response.
- Preserve exit codes, timeouts, explicit cancellation, and application
  termination cleanup.
- Cache expensive runtime resources so subsequent container starts are fast.
- Keep the application-facing backend contract independent of Apple's
  Containerization API surface.

## Non-goals

- Replacing `ios_system` or PythonIOS.
- Supporting Linux containers on iPhone or iPad.
- Integrating or invoking Apple's `container`, `cctl`, or `sandboxy` command-line
  tools.
- Shipping a separate command runner, helper application, daemon, or XPC
  service.
- Exposing Containerization or Virtualization types to the main Catalyst Swift
  target.
- Providing Docker API or Docker Compose compatibility.
- Supporting Intel Macs. The application may retain an Intel Catalyst slice,
  but the container backend will report unavailable there.
- Designing the final network-filtering user interface in the first
  implementation.

## Feasibility Findings

Experiments were performed on an arm64 Mac running macOS 26.5.1 and Xcode 26.3,
using Containerization commit
`2a591c2aeed6ff0cc70f00a5a8bf06b112b433c2`.

### Native code can run in the Catalyst process

A normal object compiled only for macOS is rejected by the Catalyst linker
because its Mach-O `LC_BUILD_VERSION` identifies only the macOS platform. This
is a build metadata issue, not a runtime prohibition.

Swift supports a zippered macOS/Mac Catalyst object directly:

```text
-target arm64-apple-macosx26.0
-target-variant arm64-apple-ios26.0-macabi
```

Clang provides the corresponding target-variant option:

```text
-target arm64-apple-macosx26.0
-darwin-target-variant arm64-apple-ios26.0-macabi
```

Objects produced this way contain both `MACOS` and `MACCATALYST` build-version
records. They retain macOS compilation conditions, so they can import
`Virtualization` and compile code guarded by `#if os(macOS)`, while remaining
acceptable inputs to the Catalyst link.

### Virtualization works in-process

A native Swift wrapper importing `Virtualization` was compiled with the target
variant, linked directly into a Catalyst executable, packaged in a signed app
bundle with application sandbox and virtualization entitlements, and executed
outside the development sandbox.

The process reported:

```text
swift_virtualization_supported=1
swift_virtualization_status=0
```

The second result is successful `VZVirtualMachineConfiguration` validation.
This confirms that the Catalyst process can call the native wrapper and use
Virtualization without a helper process.

### The Containerization library can cross the same boundary

The complete upstream `Containerization` target and its transitive Swift,
C, and C++ dependencies were compiled successfully. The target was then rebuilt
with macOS/Mac Catalyst target-variant flags. A temporary C-callable entry point
using the real `ContainerManager` was statically linked into a Catalyst
executable.

The signed Catalyst application executed the entry point successfully:

```text
containerization_manager_status=0
```

The linked probe was approximately 47.6 MB. This is an upper-bound data point
from a broad static dependency closure, not a final estimate for Local Code.

SwiftPM did not rebuild 31 vendored zstd objects with the target-variant
metadata. Their macOS platform records were removed for the final experimental
link. A production Bazel target must compile these objects with the Clang
target-variant option instead. No source-level incompatibility was found.

The experiments did not boot a complete guest with a real kernel, init
filesystem, OCI root filesystem, virtio-fs workspace, and network. That is the
remaining runtime proof required by the prototype described below.

## Architecture

```text
BashTool / BashJobRegistry
             |
          BashJob
             |
     CommandExecutionBackend
        /                 \
ios_system backend   containerized Linux backend
                            |
                 LocalCodeContainerRuntime
                 (in-process native library)
                            |
               Containerization-style runtime
                            |
                 Virtualization.framework
                            |
                    lightweight Linux VM
```

There is no process or IPC boundary in this design.

### Backend selection

Introduce one canonical backend selection:

```swift
enum CommandExecutionBackendKind {
  case iosSystem
  case containerizedLinux
}
```

The backend kind is supplied explicitly when constructing a job or its
execution dependency, with `.iosSystem` as the default. It must not be selected
through a process-global environment variable.

The existing job registry continues to own job IDs, status, output offsets,
timeouts, and retention. Execution-specific state moves behind a backend
contract. The first implementation should preserve the current serial command
policy even though a Linux container could execute multiple processes
concurrently.

### Native runtime boundary

`LocalCodeContainerRuntime` is compiled with macOS as its primary target and
Mac Catalyst as its target variant. It owns all Containerization,
Virtualization, vmnet, kernel, image, VM, and Linux process types.

The Catalyst-facing interface uses a small C or Objective-C-compatible ABI with
opaque runtime, environment, and process handles. Operations that are
inherently asynchronous use completion callbacks; the boundary must not use
semaphores or dispatch groups to simulate synchronous behavior.

The boundary needs operations equivalent to:

- query availability and return a diagnostic reason;
- prepare or open a project environment;
- execute a command with stdout and stderr callbacks;
- signal or cancel an executing command;
- shut down or reset an environment; and
- release all runtime state during application termination.

This boundary prevents the main Catalyst target from importing
`Virtualization`, and it avoids coupling Local Code to unstable upstream Swift
types.

### Environment lifecycle

The runtime lazily creates one warm environment per active project:

1. Resolve the cached Linux kernel and init filesystem.
2. Resolve or prepare the selected OCI base image and root filesystem.
3. Clone a writable project environment from the prepared base.
4. Configure a `LinuxContainer` with a long-lived idle process.
5. Mount the host project read-write at `/workspace`.
6. Create and start the container.
7. Reuse the running container for subsequent Bash jobs.
8. Stop it when the project closes, after an idle limit, or when the
   application terminates.

Kernel, init filesystem, OCI content, and prepared base root filesystems are
shared caches. The writable environment is project-specific and can persist
across application launches. It should live in Local Code's application
support directory rather than inside the source tree. The project itself
remains the source of truth for workspace files.

The product should eventually provide an explicit reset operation for the
project's Linux environment.

### Command lifecycle

For each Bash job, the backend asks the running container to create a
`LinuxProcess` with:

```text
arguments: ["/bin/sh", "-lc", command]
working directory: "/workspace"
stdout: Local Code stdout writer
stderr: Local Code stderr writer
```

The process is started, awaited, and deleted after completion. Its Linux exit
status becomes the existing Bash job exit code.

A Containerization `Writer` adapter appends data to the same stdout and stderr
files already consumed by `BashJob`. This retains current output rendering,
incremental offsets, and response formatting.

Cancellation sends an appropriate signal through `LinuxProcess.kill(_:)`.
If the process does not exit within a short grace period, the backend sends a
non-catchable kill signal. If descendant processes survive or process cleanup
fails, the backend tears down and recreates the project container before
accepting another command.

Timeouts use this same cancellation path. A cancelled Swift task alone is not
sufficient because it does not guarantee that the guest process has stopped.

### Availability

Containerized execution is available only when all of the following are true:

- the application is running as Mac Catalyst;
- the host architecture is arm64;
- the host is running macOS 26 or later;
- Virtualization reports support;
- required application entitlements are present; and
- required runtime resources are installed or can be obtained.

The option is hidden or disabled on unsupported platforms. An explicit
containerized selection that later becomes unavailable returns an actionable
error rather than executing through a different backend.

If Local Code continues to ship a universal Catalyst application, the
x86_64 build should link a small stub implementation of the native ABI. The
stub reports unsupported and does not link Containerization or Virtualization.
The arm64 implementation links the real runtime.

### Runtime resources

Containerized execution requires more than the host library:

- an arm64 Linux kernel compatible with the selected runtime;
- the init filesystem containing `vminitd`;
- an OCI base image or prepared ext4 root filesystem; and
- storage for content, prepared bases, and per-project writable images.

These resources should be versioned independently from the application so a
runtime update can invalidate only incompatible cache layers. Downloads must
be resumable and verified by digest. Initial setup progress and disk usage must
be visible to the user before the backend is selected for a command.

The first prototype may use fixed development resources. Production resource
selection, updates, and cleanup should reuse existing Local Code download
infrastructure where practical.

### Networking

The first prototype runs without guest networking. Workspace operations and
preinstalled tools do not require it, and this keeps the initial security
boundary measurable.

A later phase may add explicit policies such as:

- no network;
- host-filtered network with an allowlist; or
- unrestricted guest network.

Containerization alone does not imply HTTP-level filtering. If Local Code
adopts a host proxy similar to sandboxy, access to services listening on the
host must be evaluated separately. Host credentials, SSH agents, and other
host sockets are never mounted or forwarded by default.

## Build and Packaging

The Catalyst application must not compile the runtime as an ordinary Catalyst
Swift module. Instead:

1. Compile the runtime Swift targets with macOS as the primary target and
   Mac Catalyst as the target variant.
2. Compile every transitive C, C++, and assembly object with the equivalent
   Clang target variant.
3. Produce a static archive exposing only the Local Code runtime ABI.
4. Link that archive into the arm64 Catalyst application slice.
5. Link the required host frameworks and libraries, including
   `Virtualization`, vmnet when networking is enabled, and libarchive when the
   selected implementation needs it.
6. Sign the application with the application sandbox and virtualization
   entitlements.

The required entitlement keys established by the probe are:

```text
com.apple.security.app-sandbox
com.apple.security.virtualization
```

Any entitlement required by the eventual vmnet mode must be identified by the
networking prototype rather than assumed by the command backend.

CI should inspect representative archive members with `vtool` and fail if an
arm64 implementation object has only a macOS platform record. Production
builds must not rely on deleting Mach-O platform records as the experiment did
for zstd.

The application may retain an older deployment target, but this must be
verified on the oldest supported macOS release. Frameworks and symbols newer
than that target must be weak-linked where necessary and protected by
availability checks. The application must launch normally even when the
container backend cannot be used.

## Security Model

The Linux VM prevents guest processes from directly seeing arbitrary host
files. Local Code deliberately exposes:

- the selected project directory as a read-write virtio-fs mount; and
- only the runtime resources needed to boot and execute the environment.

Project files are not protected from a command the user asks Local Code to run.
The isolation goal is to prevent that command from automatically gaining
access to the rest of the host or the Local Code process.

No host home directory, application data, keychain material, environment
secrets, SSH agent, or developer credentials are forwarded by default.
Networking is disabled unless the user selects a policy that enables it.

Production signing must be tested using the intended distribution profile.
The successful ad-hoc signed experiment establishes technical feasibility but
does not answer App Store review or entitlement-policy questions.

## Prototype Plan

The first implementation is a focused runtime probe, not a user-facing backend:

1. Add an arm64 target-variant static runtime and an x86_64 unavailable stub.
2. Package fixed development kernel, init, and root filesystem resources.
3. Boot a container from a Catalyst test application with networking disabled.
4. Mount a temporary host workspace at `/workspace`.
5. Validate:
   - `pwd` and environment variables;
   - stdout and stderr streaming;
   - successful and unsuccessful exit codes;
   - reading, creating, and modifying workspace files;
   - execution of Python and a representative build tool;
   - timeout and manual cancellation;
   - cleanup of descendant processes;
   - repeated commands in one warm environment;
   - environment persistence and explicit reset; and
   - application termination while a command is running.
6. Measure cold preparation, VM boot, warm command latency, memory, and disk
   usage.
7. Repeat with the intended production signing configuration.
8. Verify that the application still launches and uses `ios_system` on older
   supported macOS versions and on Intel.

Only after this probe passes should `BashJob` receive the backend abstraction
and the user-facing selection be added.

## Implementation Choice After the Prototype

The Local Code-facing architecture does not depend on whether the native
runtime:

- vendors and uses Apple's Containerization libraries directly;
- maintains a small patch set around those libraries; or
- implements only the required Virtualization, virtio-fs, vsock, and process
  lifecycle internally.

Direct use of the library is the fastest way to validate behavior and avoids
reimplementing its guest protocol. Its current dependency closure and evolving
API are costs. The opaque Local Code ABI is intentionally the stable boundary
that permits a narrower implementation later without changing Bash tools or
persisted backend selection.

## Alternatives Rejected

### Launch the `container` CLI

This adds an unnecessary executable, process lifecycle, command serialization,
and output transport. Local Code needs the runtime capability, not the CLI.

### Add a native helper executable or XPC service

The target-variant experiments demonstrate that native Swift,
Virtualization, and Containerization code can run inside the signed Catalyst
process. A helper would add packaging and IPC complexity without solving a
technical requirement.

### Replace `ios_system`

The existing backend is required on iOS and remains useful on macOS for low
startup cost and bundled Python behavior. Containerized Linux is an option with
different compatibility, resource, and isolation characteristics.

### Compile Containerization as ordinary Catalyst source

Containerization's macOS code imports frameworks and uses compilation
conditions not exposed to a normal Catalyst target. Compiling it as native
macOS with a Catalyst target variant preserves those conditions while
producing link-compatible objects.

## Open Questions

- Should project writable root filesystems persist indefinitely or be evicted
  after an inactivity period?
- Which kernel, init filesystem, and base image should be the supported
  production combination?
- What maximum CPU, memory, and disk defaults should Local Code apply?
- Is direct upstream Containerization use acceptable for application size and
  update cadence, or should the production runtime be narrowed?
- Which networking policies should be exposed after the no-network prototype?
- What signing and distribution constraints apply to the virtualization
  entitlement for each intended release channel?
