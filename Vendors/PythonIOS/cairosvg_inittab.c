#include <Python.h>

extern PyObject *PyInit__cffi_backend(void);
extern PyObject *PyInit__ffi(void);

int ios_python_register_cairosvg(void) {
    static int registered = 0;
    if (registered) {
        return 0;
    }
    int status = PyImport_AppendInittab("_cffi_backend", PyInit__cffi_backend);
    status |= PyImport_AppendInittab("cairocffi._ffi", PyInit__ffi);
    if (status == 0) {
        registered = 1;
    }
    return status;
}
