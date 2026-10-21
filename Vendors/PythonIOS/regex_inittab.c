#include <Python.h>

extern PyObject *PyInit__regex(void);

/*
 * regex uses a legacy single-phase extension module with process-global
 * state. ios_system keeps extension compatibility checks enabled for
 * recursive own-GIL interpreters, so CPython rejects regex there while
 * normal main-interpreter commands can reuse it safely.
 */
int ios_python_register_regex(void) {
    static int registered = 0;
    if (registered) {
        return 0;
    }
    int status = PyImport_AppendInittab("regex._regex", PyInit__regex);
    if (status == 0) {
        registered = 1;
    }
    return status;
}
