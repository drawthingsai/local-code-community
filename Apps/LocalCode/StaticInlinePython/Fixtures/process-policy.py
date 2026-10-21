"""Run with StaticInlinePythonMacOS python3 <this file> (never host Python)."""
import errno
import importlib
import os
import posix
import subprocess
import tempfile
import threading

# Fail before testing native operations if this is accidentally run on a host.
assert subprocess.run.__module__ is None, "Requires the embedded command bridge"


def rejected(call, expected=errno.ENOTSUP):
    try:
        call()
    except OSError as error:
        assert error.errno == expected, error
    else:
        raise AssertionError("unsupported operation returned successfully")


# More than a pipe buffer: synchronous input/capture must not deadlock.
data = b"hello\x00world\n" * 20000
result = subprocess.run(["cat"], input=data, capture_output=True, check=True)
assert result.stdout == data and result.stderr == b""
with tempfile.NamedTemporaryFile(prefix="a 'quote'; $HOME") as source:
    source.write(b"a\r\nb\rc")
    source.flush()
    result = subprocess.run(["cat", source.name], capture_output=True, text=True)
    assert result.stdout == "a\nb\nc"
try:
    subprocess.run(["cat", "/nonexistent-localcode-input"], capture_output=True, check=True)
except subprocess.CalledProcessError as error:
    assert error.returncode != 0 and error.stdout == b"" and error.stderr
else:
    raise AssertionError("check=True did not raise")
rejected(lambda: subprocess.run(["/nonexistent-localcode-command"]), errno.ENOENT)
reader, writer = os.pipe()
os.close(reader)
try:
    result = subprocess.run(["cat"], input=b"closed reader", stdout=writer, stderr=subprocess.PIPE)
    # Some embedded commands treat an early-closing consumer as success. The
    # regression is that this returns a result instead of killing the host.
    assert isinstance(result, subprocess.CompletedProcess)
finally:
    os.close(writer)

for options in ({"shell": True}, {"timeout": 1}, {"cwd": "/"}, {"env": {}},
                {"preexec_fn": lambda: None}, {"pass_fds": ()}, {"start_new_session": True}):
    rejected(lambda: subprocess.run(["true"], **options))


def reject_native_operations():
    rejected(lambda: subprocess.Popen(["cat"], stdin=subprocess.PIPE))
    rejected(lambda: subprocess.check_output(["true"]))
    rejected(lambda: subprocess.call(["true"]))
    rejected(lambda: subprocess.check_call(["true"]))
    rejected(lambda: os.popen("true"))
    for module in (os, posix):
        for name in ("fork", "forkpty", "wait", "wait3", "wait4", "waitpid", "_exit"):
            if not hasattr(module, name):
                continue
            args = {"wait3": (0,), "wait4": (1, 0), "waitpid": (1, 0), "_exit": (0,)}.get(name, ())
            rejected(lambda: getattr(module, name)(*args))
        for name in ("posix_spawn", "posix_spawnp"):
            if hasattr(module, name):
                rejected(lambda: getattr(module, name)("/nonexistent-localcode-command", ["probe"], {}))
        if hasattr(module, "waitid"):
            rejected(lambda: module.waitid(os.P_ALL, 0, os.WEXITED | os.WNOHANG))
        for name, args in (("execv", ("/nonexistent-localcode-command", ["probe"])),
                           ("execve", ("/nonexistent-localcode-command", ["probe"], {})),
                           ("kill", (2147483647, 0)), ("killpg", (2147483647, 0))):
            rejected(lambda: getattr(module, name)(*args))
    rejected(lambda: posix.system("true"))


reject_native_operations()
thread_errors = []


def on_thread():
    try:
        reject_native_operations()
        rejected(lambda: subprocess.run(["true"]))
    except BaseException as error:
        thread_errors.append(error)


thread = threading.Thread(target=on_thread)
thread.start()
thread.join()
assert not thread_errors, thread_errors
assert os.system("true") == 0

# sh/bash invocations reach OSH with their arguments, and shells nest.
result = subprocess.run(["sh", "-c", 'printf "%s|%s|%s" "$#" "$0" "$1"', "probe", "hello"],
                        capture_output=True, text=True, check=True)
assert result.stdout == "1|probe|hello", result
result = subprocess.run(["bash", "-c", 'echo "$BASH_VERSION"; exit 3'],
                        capture_output=True, text=True)
assert result.returncode == 3 and result.stdout.strip(), result
result = subprocess.run(["sh", "-c", "sh -c 'echo nested'; os_status=$?; exit $os_status"],
                        capture_output=True, text=True, check=True)
assert result.stdout == "nested\n", result
assert os.system("sh -c 'exit 0' && bash -c true") == 0
# The shell recurses on the C stack even when this Python thread's stack is small.
assert os.system("f() { if (( $1 > 0 )); then f $(($1-1)); fi; }; f 1000") == 0

try:
    import _posixsubprocess
except ImportError:
    pass  # The iOS archive may omit the native extension altogether.
else:
    reader, writer = os.pipe()
    try:
        rejected(lambda: _posixsubprocess.fork_exec(
            [b"probe"], (b"/nonexistent-localcode-command",), True, (writer,),
            None, None, -1, -1, -1, -1, -1, -1, reader, writer,
            True, False, -1, None, None, None, -1, None))
    finally:
        os.close(reader)
        os.close(writer)

# Public monkeypatches are not the only guard: reloading subprocess must still
# fail before its native spawn/fork path can run, including its pipe setup.
importlib.reload(subprocess)
subprocess._can_fork_exec = True
rejected(lambda: subprocess.Popen(["cat"], stdin=subprocess.PIPE))
print("[StaticInlinePython] process policy passed", flush=True)
