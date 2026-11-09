"""Audit every .mtx in the TOSEC collection: is it a complete, self-consistent MTX tape image?

For a BASIC tape the system variables say how big each part must be:
    18                                header: FF, 15 byte name, STKLIM
    0xFB4B - STKLIM                   system variables (these include any machine code above STKLIM)
    ARRTOP - 0x4000                   BASIC program (ARRTOP at FACC, 16 bit)
    CALCST - VARNAM                   BASIC variables (CALCST FA81, VARNAM FA7B)
so a good file is exactly that long. A file with the right header but a different length is truncated
or has extra data. Files with no usable header cannot be loaded by LOAD at all.

Usage: mtx_audit.py [collection folder]
"""
import glob
import os
import struct
import sys
import zipfile

ROOT = sys.argv[1] if len(sys.argv) > 1 else '<TOSEC collection folder>/'


def w(d, off):
    return d[off] | (d[off + 1] << 8)


def audit(name, d):
    if len(d) < 20:
        return 'TINY', 'file is only %d bytes' % len(d)
    if d[0] == 0xF2 and d[1] == 0xF8 and d[2:4] == b'\x59\x02':
        return 'NOT A TAPE', 'SDX BASIC .BAS file (no tape header)'
    if d[0] != 0xFF:
        return 'NOT A TAPE', 'starts %02X, not FF (RUN file or raw data?)' % d[0]
    nm = d[1:16]
    printable = all(32 <= c < 127 for c in nm)
    stk = w(d, 16)
    if not printable:
        return 'NO HEADER', 'name field is not text (%s): headerless dump, LOAD cannot use it' % nm[:6].hex()
    n_sys = 0xFB4B - stk
    if n_sys < 0x259 - 0x200 or n_sys > 0xFFFF:
        return 'BAD HEADER', 'STKLIM %04X is not sensible' % stk
    if 18 + n_sys > len(d):
        return 'TRUNCATED', 'STKLIM %04X needs %d bytes of system variables, file has only %d after the header' % (stk, n_sys, len(d) - 18)
    sv = d[18:18 + n_sys]

    def var(addr):
        return w(sv, addr - stk)

    arrtop = var(0xFACC) | (sv[0xFACE - stk] << 16)      # ARRTOP is the SIZE of the program, 24 bit
    calcst, varnam = var(0xFA81), var(0xFA7B)
    prog = arrtop
    vars_ = calcst - varnam
    if prog > 0xB000 or vars_ < 0 or vars_ > 0x4000:
        return 'ODD', 'sizes from the system variables look wrong: program %d, variables %d' % (prog, vars_)
    expect = 18 + n_sys + prog + vars_
    if expect == len(d):
        return 'GOOD', 'exact: 18 + %d sysvars + %d program + %d variables' % (n_sys, prog, vars_)
    if expect > len(d):
        return 'SHORT', 'its own header asks for %d bytes, file has %d (%d short)' % (expect, len(d), expect - len(d))
    return 'EXTRA', 'its own header asks for %d bytes, file has %d (%d more)' % (expect, len(d), len(d) - expect)


rows = []
for fname in sorted(os.listdir(ROOT)):
    folder = os.path.join(ROOT, fname)
    for zname in sorted(os.listdir(folder)):
        zp = os.path.join(folder, zname)
        if not zname.lower().endswith('.zip'):
            continue
        z = zipfile.ZipFile(zp)
        for i in z.infolist():
            if i.filename.lower().endswith('.mtx'):
                v, why = audit(i.filename, z.read(i))
                rows.append((os.path.basename(folder).split(' (')[0], i.filename, v, why))

from collections import Counter
c = Counter(r[2] for r in rows)
print('.mtx files audited: %d' % len(rows))
for k, n in c.most_common():
    print('  %-11s %3d' % (k, n))
print()
for verdict in ('GOOD', 'SHORT', 'EXTRA', 'TRUNCATED', 'NO HEADER', 'BAD HEADER', 'ODD', 'NOT A TAPE', 'TINY'):
    sel = [r for r in rows if r[2] == verdict]
    if not sel:
        continue
    print('== %s (%d)' % (verdict, len(sel)))
    for grp, fn, v, why in sel:
        print('  %-26s %-58s %s' % (grp.replace('Memotech MTX - ', ''), fn[:58], why[:100]))
    print()
