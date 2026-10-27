#!/usr/bin/env python3 -I
"""Flag references that treat a thread-local variable as an ordinary global.

Usage: tlvcheck.py OBJECT_DIR...

A __thread variable's Mach-O symbol is its TLV descriptor. A translation unit
that declares it without __thread (for example `extern char ebuf[];`) still
links, but reads the descriptor as data. Such references use page/GOT
relocations instead of ARM64_RELOC_TLVP_LOAD_*.
"""
import os
import re
import subprocess
import sys

objects = []
for root in sys.argv[1:]:
    for directory, _, names in os.walk(root):
        objects += [os.path.join(directory, name) for name in names if name.endswith('.o')]

thread_locals = set()
for path in objects:
    output = subprocess.run(['nm', '-m', path], capture_output=True, text=True).stdout
    for line in output.splitlines():
        if '(__DATA,__thread_vars)' in line and 'external' in line:
            thread_locals.add(line.split()[-1])

problems = 0
for path in objects:
    # Only references this object leaves undefined resolve to another
    # object's definition; local symbols may reuse a name.
    undefined = set(subprocess.run(['nm', '-u', path], capture_output=True, text=True).stdout.split())
    output = subprocess.run(['objdump', '--reloc', path], capture_output=True, text=True).stdout
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 3:
            continue
        kind, symbol = fields[1], fields[2]
        # Calls (BRANCH26) only share a name; they cannot read the variable.
        if symbol in thread_locals and symbol in undefined and 'TLVP' not in kind and 'BRANCH' not in kind:
            print(f'{path}: {kind} {symbol}')
            problems += 1
print(f'{len(objects)} objects, {len(thread_locals)} thread-local symbols, {problems} non-TLV references')
sys.exit(1 if problems else 0)
