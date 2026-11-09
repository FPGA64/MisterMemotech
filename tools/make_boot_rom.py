"""Put the MTX ROMs you have into one boot.rom for the core, including ROM 2 (for example HiSoft Pascal).

    python make_boot_rom.py boot.rom --os os.rom --basic basic.rom [--assem assem.rom] [--sdx sdx.rom] [--rom2 pascal0.rom pascal1.rom]

The core reads boot.rom into its ROM memory in 8K sections, in this order:

    section 0   OS ROM         (0000)
    section 1   BASIC (ROM 0)  (2000)
    section 2   ASSEM (ROM 1)
    section 3   the SDX ROM    (ROM 3, or ROM 5 with the OSD setting)
    section 4-7 ROM 2, sub-pages 0 to 3

A ROM you do not have is filled with FF bytes. The SDX card is only switched on when section 3 holds a ROM that starts with
the MTX ROM signature (08 07 06 05 04 03 02 01), so filler there does no harm. The file stops after the last section you gave.
Each ROM file must be 8192 bytes or less (it is padded with FF); --rom2 takes one to four files, one per sub-page (HiSoft
Pascal is two: pascal0.rom and pascal1.rom, sub-pages 0 and 1).

The files are your own; nothing is supplied with the core. Python 3, no other packages.
"""
import argparse
import hashlib
import os
import sys

SECTION = 8192


def load(path):
    d = open(path, 'rb').read()
    if len(d) > SECTION:
        sys.exit('%s is %d bytes: a ROM is at most %d bytes (for ROM 2 give one file per 8K sub-page)' % (path, len(d), SECTION))
    return d + b'\xff' * (SECTION - len(d))


def main():
    ap = argparse.ArgumentParser(description='make a boot.rom for the MTX512 core')
    ap.add_argument('out')
    ap.add_argument('--os', required=True)
    ap.add_argument('--basic', required=True)
    ap.add_argument('--assem')
    ap.add_argument('--sdx')
    ap.add_argument('--rom2', nargs='+', default=[], metavar='FILE')
    ap.add_argument('--force', action='store_true', help='overwrite the output file')
    a = ap.parse_args()
    if os.path.exists(a.out) and not a.force:
        sys.exit('%s exists (use --force to overwrite it)' % a.out)
    if len(a.rom2) > 4:
        sys.exit('ROM 2 has four sub-pages: at most four files after --rom2')
    sections = [('OS', a.os), ('BASIC (ROM 0)', a.basic), ('ASSEM (ROM 1)', a.assem), ('SDX ROM', a.sdx)]
    sections += [('ROM 2 sub-page %d' % i, f) for i, f in enumerate(a.rom2)]
    # the file ends after the last section that was given; the ones before it that were not given are FF
    last = max(i for i, (n, f) in enumerate(sections) if f)
    out = bytearray()
    for i, (name, f) in enumerate(sections[:last + 1]):
        if f:
            d = load(f)
            print('section %d  %-16s %s  (%d bytes)' % (i, name, f, os.path.getsize(f)))
        else:
            d = b'\xff' * SECTION
            print('section %d  %-16s filler (FF)' % (i, name))
        if name == 'SDX ROM' and f and d[:2] != bytes([0x08, 0x07]):
            print('  warning: this does not start with the MTX ROM signature 08 07 06 05 04 03 02 01, so the core will not switch the SDX card on')
        out += d
    if len(a.rom2) > 0 and not a.sdx:
        print('(no SDX ROM: section 3 is filler, the SDX card stays off)')
    open(a.out, 'wb').write(out)
    print('wrote %s: %d bytes, MD5 %s' % (a.out, len(out), hashlib.md5(out).hexdigest()))


if __name__ == '__main__':
    main()
