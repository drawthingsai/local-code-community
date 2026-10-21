"""Generate the statically linked Cairo CFFI extension at build time."""

import runpy
import sys
from pathlib import Path

from cffi import FFI


constants = runpy.run_path(sys.argv[1])
# The upstream ABI declarations include Windows and legacy Quartz entry points.
# Our compiled binding exposes the common image/PDF/PS/SVG API used by CairoSVG.
headers = constants["_CAIRO_HEADERS"].split("typedef void* HDC;")[0]
builder = FFI()
builder.cdef(headers)
builder.cdef('''
extern "Python" cairo_status_t _pythonios_cairo_read(void *, unsigned char *, unsigned int);
extern "Python" cairo_status_t _pythonios_cairo_write(void *, const unsigned char *, unsigned int);
extern "Python" void _pythonios_cairo_destroy(void *);
''')
builder.set_source("cairocffi._ffi", '''
#include <cairo.h>
#include <cairo-pdf.h>
#include <cairo-ps.h>
#include <cairo-svg.h>
''')
builder.emit_c_code(str(Path(sys.argv[2])))
