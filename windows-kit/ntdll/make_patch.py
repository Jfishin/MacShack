#!/usr/bin/env python3
"""The ntdll detour as data for the device (host/WindowsKit.swift, applyPatch): the byte ranges where the patched file
differs from the original, with both files' sha256. The device checks the original's hash, writes the ranges, and
checks the result's.

    make_patch.py <original> <patched> <path under the engine folder>     JSON on stdout
"""
import hashlib
import json
import sys

if len(sys.argv) != 4:
    raise SystemExit(__doc__)
original, patched = open(sys.argv[1], 'rb').read(), open(sys.argv[2], 'rb').read()
if len(original) != len(patched):
    raise SystemExit('the patched file has another size: not a byte patch')
writes, i = [], 0
while i < len(original):
    if original[i] == patched[i]:
        i += 1
        continue
    j = i
    while j < len(original) and original[j] != patched[j]:
        j += 1
    writes.append({'offset': i, 'bytes': patched[i:j].hex()})
    i = j
json.dump({'file': sys.argv[3], 'original': hashlib.sha256(original).hexdigest(),
           'result': hashlib.sha256(patched).hexdigest(), 'writes': writes}, sys.stdout, indent=1)
print()
