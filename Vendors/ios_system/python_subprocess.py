"""Synchronous subprocess.run for registered commands; OS process APIs stay disabled.

Input and captured output use temporary files. There is no streaming child,
custom environment/directory, shell mode, or timeout support.
"""
import contextlib
import ctypes
import errno
import os
import posix
import subprocess
import tempfile


def install(execute_address):
    execute = ctypes.CFUNCTYPE(
        ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_char_p),
        ctypes.c_int, ctypes.c_int, ctypes.c_int, use_errno=True)(execute_address)
    original_run = subprocess.run
    saved_operations = []

    def unsupported(*args, **kwargs):
        raise OSError(errno.ENOTSUP, "OS process operations are unavailable in embedded Python")

    def run(args, *, input=None, capture_output=False, check=False,
            stdin=None, stdout=None, stderr=None, text=None, encoding=None,
            errors=None, universal_newlines=None, timeout=None, shell=False, **kwargs):
        if shell or timeout is not None or kwargs:
            raise OSError(errno.ENOTSUP, "subprocess.run only supports synchronous registered commands and stdio")
        if input is not None and stdin is not None:
            raise ValueError("stdin and input arguments may not both be used")
        if capture_output:
            if stdout is not None or stderr is not None:
                raise ValueError("stdout and stderr arguments may not be used with capture_output")
            stdout = stderr = subprocess.PIPE
        if text is not None and universal_newlines is not None and bool(text) != bool(universal_newlines):
            raise ValueError("text and universal_newlines disagree")
        text_mode = bool(text or universal_newlines or encoding or errors)
        if text_mode:
            encoding = encoding or subprocess._text_encoding()
            errors = errors or "strict"
        argv = [args] if isinstance(args, (str, bytes, os.PathLike)) else list(args)
        if not argv:
            raise ValueError("subprocess.run requires a command")
        argv = [os.fsencode(arg) for arg in argv]
        if any(b"\0" in arg for arg in argv):
            raise ValueError("embedded null byte")
        native_argv = (ctypes.c_char_p * (len(argv) + 1))(*argv, None)

        with contextlib.ExitStack() as stack:
            def stream(value, mode):
                if value is None:
                    return -1, None
                if value == subprocess.PIPE:
                    file = stack.enter_context(tempfile.TemporaryFile())
                    return file.fileno(), file
                if value == subprocess.DEVNULL:
                    file = stack.enter_context(open(os.devnull, mode))
                    return file.fileno(), None
                fd = value if isinstance(value, int) else value.fileno()
                if fd < 0:
                    raise ValueError("invalid stream descriptor")
                return fd, None

            input_fd, input_file = stream(subprocess.PIPE if input is not None else stdin, "rb")
            output_fd, output_file = stream(stdout, "wb")
            error_fd, error_file = (-2, None) if stderr == subprocess.STDOUT else stream(stderr, "wb")
            if input is not None:
                input_file.write(input.encode(encoding, errors) if text_mode else input)
                input_file.seek(0)
            status = execute(len(argv), native_argv, input_fd, output_fd, error_fd)
            if status < 0:
                code = ctypes.get_errno()
                raise OSError(code, os.strerror(code), os.fsdecode(argv[0]))
            captured = []
            for file in (output_file, error_file):
                if file is None:
                    captured.append(None)
                    continue
                file.seek(0)
                data = file.read()
                if text_mode:
                    data = data.decode(encoding, errors).replace("\r\n", "\n").replace("\r", "\n")
                captured.append(data)
            result = subprocess.CompletedProcess(args, status, *captured)
            if check:
                result.check_returncode()
            return result

    subprocess.run = run
    # Native process creation is also rejected by the runtime's C audit hook.
    # Block Popen before it allocates pipes; wait and _exit have no audit events.
    for module, names in (
        (subprocess, ("Popen", "check_output")),
        (os, ("wait", "waitpid", "wait3", "wait4", "waitid", "_exit")),
        (posix, ("wait", "waitpid", "wait3", "wait4", "waitid", "_exit")),
    ):
        for name in names:
            if hasattr(module, name):
                saved_operations.append((module, name, getattr(module, name)))
                setattr(module, name, unsupported)

    def restore():
        subprocess.run = original_run
        for module, name, value in saved_operations:
            setattr(module, name, value)

    return restore
