#include <Python.h>

extern PyObject *PyInit_tokenizers(void);

/*
 * PyO3 0.26 does not advertise per-interpreter-GIL support. ios_system keeps
 * extension compatibility checks enabled for its recursive own-GIL
 * interpreters, so CPython rejects tokenizers there while normal
 * main-interpreter commands can reuse it safely.
 */
int ios_python_register_tokenizers(void) {
    static int registered = 0;
    if (registered) {
        return 0;
    }
    int status = PyImport_AppendInittab(
        "tokenizers.tokenizers",
        PyInit_tokenizers);
    if (status == 0) {
        registered = 1;
    }
    return status;
}
