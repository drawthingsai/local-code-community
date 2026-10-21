"""Embed the command bridge without maintaining a second escaped Python source."""
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text(
    "static const char ios_python_subprocess_source[] =\n"
    + "\n".join(json.dumps(line, ensure_ascii=True) for line in source.splitlines(True))
    + ";\n"
)
