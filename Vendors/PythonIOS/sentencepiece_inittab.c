#include <Python.h>

extern PyObject *PyInit__sentencepiece(void);

/*
 * pybind11 3.0 defaults extension modules to
 * Py_MOD_MULTIPLE_INTERPRETERS_NOT_SUPPORTED. ios_system therefore uses
 * SentencePiece in its persistent main interpreter, while recursive own-GIL
 * interpreters reject it through CPython's extension compatibility check.
 */
int ios_python_register_sentencepiece(void) {
    static int registered = 0;
    if (registered) {
        return 0;
    }
    int status = PyImport_AppendInittab(
        "sentencepiece._sentencepiece",
        PyInit__sentencepiece);
    if (status == 0) {
        registered = 1;
    }
    return status;
}
