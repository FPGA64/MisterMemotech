"""Structural check of a .mtx BASIC tape file: header, system variables, then BASIC lines.

A BASIC line is  [length LE16, includes itself] [line number LE16] [tokens ...] [0xFF].
The program starts at file offset 18 + (0xFB4B - STKLIM) and has to walk cleanly, line after line,
with ascending line numbers, to the end of the program area.

Usage: mtx_check.py file.mtx [...]
"""
import struct
import sys


def check(path):
    d = open(path, 'rb').read()
    out = ['%s: %d bytes' % (path.replace('\\', '/').split('/')[-1], len(d))]
    if d[0] != 0xFF:
        return out + ['  not a tape file (first byte %02X)' % d[0]]
    name = d[1:16].decode('latin-1').rstrip()
    stklim = struct.unpack('<H', d[16:18])[0]
    n_sys = 0xFB4B - stklim
    out.append('  name "%s", STKLIM %04X, system variables %d bytes' % (name, stklim, n_sys))
    pos = 18 + n_sys
    if pos > len(d):
        return out + ['  file too short for its system variables']
    start = pos
    lines = 0
    last = -1
    ok = True
    while pos + 4 <= len(d):
        ln = struct.unpack('<H', d[pos:pos + 2])[0]
        num = struct.unpack('<H', d[pos + 2:pos + 4])[0]
        if ln < 5 or pos + ln > len(d) or d[pos + ln - 1] != 0xFF or num <= last:
            break
        last = num
        lines += 1
        pos += ln
    prog = pos - start
    out.append('  BASIC program: %d lines, %d bytes, last line number %d' % (lines, prog, last))
    rest = len(d) - pos
    out.append('  after the last BASIC line: %d bytes remain in the file (variables / assembler / extra data)' % rest)
    if lines == 0:
        out.append('  NO BASIC LINES FOUND at offset %d (bytes there: %s)' % (start, d[start:start + 16].hex(' ')))
        ok = False
    return out + (['  structure OK'] if ok else ['  structure PROBLEM'])


if __name__ == '__main__':
    for p in sys.argv[1:]:
        print('\n'.join(check(p)))
        print()
