"""Generate upstream curl_cffi's API-mode binding without downloading host libraries."""
import sys
from pathlib import Path
import cffi

source, output, cffi_version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
if cffi.__version__ != cffi_version:
    sys.exit(f'Use CFFI {cffi_version} to match the bundled _cffi_backend; found {cffi.__version__}')
builder = cffi.FFI()
builder.cdef((source / "ffi/cdef.c").read_text())
builder.set_source("curl_cffi._wrapper", '#include "shim.h"')
builder.emit_c_code(str(output))
