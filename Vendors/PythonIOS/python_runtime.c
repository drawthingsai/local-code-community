#include "python_runtime.h"

#include <Python.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>

extern PyObject *PyInit__wrapper(void);

static int python_ios_process_audit(const char *event, PyObject *args, void *context) {
    // These native operations would act on the host app, or mix OS PIDs with
    // ios_system's command identifiers. The subprocess.run and os.system bridges do not
    // invoke them. C audit hooks cover every interpreter and Python thread.
    const char *blocked[] = {
        "subprocess.Popen", "_posixsubprocess.fork_exec", "os.fork", "os.forkpty",
        "os.posix_spawn", "os.exec", "os.system", "os.kill", "os.killpg", NULL
    };
    for (const char **name = blocked; *name; name++) {
        if (strcmp(event, *name) == 0) {
            errno = ENOTSUP;
            PyErr_SetFromErrno(PyExc_OSError);
            return -1;
        }
    }
    return 0;
}

int python_ios_initialize(char *error_message, size_t error_message_capacity) {
    if (error_message_capacity > 0) {
        error_message[0] = '\0';
    }
    if (PyImport_AppendInittab("curl_cffi._wrapper", PyInit__wrapper) < 0) {
        if (error_message_capacity > 0)
            snprintf(error_message, error_message_capacity, "Unable to register curl_cffi");
        return 1;
    }
    if (PySys_AddAuditHook(python_ios_process_audit, NULL) < 0) {
        if (error_message_capacity > 0)
            snprintf(error_message, error_message_capacity, "Unable to install embedded process policy");
        return 1;
    }

    PyConfig config;
    PyConfig_InitPythonConfig(&config);

    // Match Py_InitializeEx(0)'s embedding behavior while retaining the
    // PyStatus result instead of terminating the calling thread on failure.
    config.install_signal_handlers = 0;
    config.configure_c_stdio = 0;
    config.parse_argv = 0;
#ifdef __APPLE__
    // ios_system owns the command's stdin/stdout/stderr. CPython's iOS
    // os_log replacement would bypass those streams and is redundant here.
    config.use_system_logger = 0;
#endif

    PyStatus status = Py_InitializeFromConfig(&config);
    int result = 0;
    if (PyStatus_Exception(status)) {
        result = 1;
        if (error_message_capacity > 0) {
            if (PyStatus_IsExit(status)) {
                snprintf(
                    error_message,
                    error_message_capacity,
                    "CPython requested exit with status %d",
                    status.exitcode);
            } else if (status.func != NULL && status.err_msg != NULL) {
                snprintf(
                    error_message,
                    error_message_capacity,
                    "%s: %s",
                    status.func,
                    status.err_msg);
            } else if (status.err_msg != NULL) {
                snprintf(error_message, error_message_capacity, "%s", status.err_msg);
            } else {
                snprintf(error_message, error_message_capacity, "unknown CPython initialization error");
            }
        }
    }
    PyConfig_Clear(&config);
    return result;
}
