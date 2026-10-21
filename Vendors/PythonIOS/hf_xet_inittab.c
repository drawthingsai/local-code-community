#include <Python.h>

extern PyObject *PyInit_hf_xet(void);

/*
 * PyO3 0.29 does not advertise per-interpreter-GIL support. ios_system keeps
 * extension compatibility checks enabled for its recursive own-GIL
 * interpreters, so CPython rejects hf_xet there while normal main-interpreter
 * commands can reuse it safely.
 */
int ios_python_register_hf_xet(void) {
    static int registered = 0;
    if (registered) {
        return 0;
    }
    int status = PyImport_AppendInittab("hf_xet.hf_xet", PyInit_hf_xet);
    if (status == 0) {
        registered = 1;
    }
    return status;
}
