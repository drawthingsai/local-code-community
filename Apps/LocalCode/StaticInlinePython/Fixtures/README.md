# Embedded process policy regression

From the repository root:

```sh
bazel build //Apps/LocalCode:StaticInlinePythonMacOS
BUILD_WORKSPACE_DIRECTORY="$PWD" bazel-bin/Apps/LocalCode/StaticInlinePythonMacOS python3 "$PWD/Apps/LocalCode/StaticInlinePython/Fixtures/process-policy.py"
```

Run the Python fixture only with the embedded harness. It checks rejection of
native Popen, fork, forkpty, posix_spawn, exec, wait, kill, and native system
operations, including calls from another Python thread, reloaded subprocess,
and the private fork_exec extension. It also checks that os.system still works,
that run handles input/capture larger than a pipe buffer, and that an output pipe
with no reader does not terminate the host.

The supported Python surface is synchronous `subprocess.run` for registered
commands: argument vectors, input, inherited/file/DEVNULL stdio, captured output,
text decoding, and `check`. Input and capture use temporary files. Shell mode,
timeouts, custom cwd/env, and other Popen options raise ENOTSUP. Calls from
Python-created threads also raise ENOTSUP because those threads do not own an
ios_system command session. Other subprocess convenience APIs remain unsupported.

This is a native macOS harness, not a Catalyst app. Its clipboard commands are
stubs; it cannot validate UIKit clipboard behavior or permissions.
