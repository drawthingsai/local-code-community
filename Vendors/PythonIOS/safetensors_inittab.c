#include <Python.h>

extern PyObject *PyInit__safetensors_rust(void);

/*
 * PyO3 0.28 does not advertise subinterpreter support by default.
 * ios_system keeps extension compatibility checks enabled for recursive
 * own-GIL interpreters, so CPython rejects safetensors there while normal
 * main-interpreter commands can reuse it safely.
 */
int ios_python_register_safetensors(void) {
    static int registered = 0;
    if (registered) {
        return 0;
    }
    int status = PyImport_AppendInittab(
        "safetensors._safetensors_rust",
        PyInit__safetensors_rust);
    if (status == 0) {
        registered = 1;
    }
    return status;
}
