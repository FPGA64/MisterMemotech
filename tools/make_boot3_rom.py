"""Make boot3.rom for the 80 column board and CP/M: the SDX ROM, the board's character ROM and the CP/M bootstrap PROM in one file.

    python make_boot3_rom.py boot3.rom --sdx sdx.rom --font 80char_0743.hex --prom SDX_98E7.BIN

  --sdx    an ordinary SDX ROM, 8192 bytes (SDX BASIC and the USER commands)
  --font   the 80 column board's character ROM, 8192 bytes: the graphics ROM, then the alpha ROM. A binary file, or an
           Intel HEX file (as the 80char_0743 download is).
  --prom   the SDX CP/M bootstrap PROM, 8192 bytes (it starts with the MTX ROM signature 08 07 06 05 04 03 02 01)
  Either of --sdx and --prom may be left out: the one that is given is then used in both places (so the OSD entry
  "Disc ROM" works either way, but there is only one of the two systems).

The file is 24576 bytes: the SDX ROM, the character ROM, the CP/M PROM. The core puts them in the SDX ROM slot, the character
ROM of the 80 column board and a page of its own; OSD -> Disc ROM (SDX BASIC or CP/M) says which of the two ROMs answers in the
SDX slot, and the 80 column board is fitted when the character ROM has arrived. With the CP/M PROM chosen the machine
starts CP/M from disc A when it is reset (no BASIC prompt first). The files are your own; nothing is supplied with the core.
Python 3, no other packages.
"""
import argparse
import hashlib
import os
import sys

SIZE = 8192


def read_ihex(text):
    mem = {}
    base = 0
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        if not line.startswith(':'):
            sys.exit('line %d is not Intel HEX' % n)
        b = bytes.fromhex(line[1:])
        if len(b) < 5 or len(b) != b[0] + 5 or (sum(b) & 255) != 0:
            sys.exit('line %d: bad record or checksum' % n)
        kind = b[3]
        if kind == 0:
            addr = base + (b[1] << 8) + b[2]
            for i, v in enumerate(b[4:4 + b[0]]):
                mem[addr + i] = v
        elif kind == 2:
            base = ((b[4] << 8) + b[5]) << 4
        elif kind == 4:
            base = ((b[4] << 8) + b[5]) << 16
        elif kind == 1:
            break
    if not mem:
        sys.exit('no data in the HEX file')
    top = max(mem) + 1
    return bytes(mem.get(i, 0) for i in range(top))


def load(path, what):
    d = open(path, 'rb').read()
    if d[:1] == b':' and all(c < 128 for c in d[:64]):
        d = read_ihex(d.decode('ascii', 'replace'))
    if len(d) != SIZE:
        sys.exit('%s (%s) is %d bytes: it must be exactly %d' % (path, what, len(d), SIZE))
    return d


def main():
    ap = argparse.ArgumentParser(description='make a boot3.rom (SDX ROM + 80 column character ROM + CP/M PROM)')
    ap.add_argument('out')
    ap.add_argument('--sdx', help='an ordinary SDX ROM')
    ap.add_argument('--prom', help='the SDX CP/M bootstrap PROM')
    ap.add_argument('--font', required=True, help='the character ROM (binary or Intel HEX)')
    ap.add_argument('--force', action='store_true', help='overwrite the output file')
    a = ap.parse_args()
    if not a.sdx and not a.prom:
        sys.exit('give --sdx (an SDX ROM) or --prom (the CP/M PROM), or both')
    if os.path.exists(a.out) and not a.force:
        sys.exit('%s exists (use --force to overwrite it)' % a.out)
    sdx = load(a.sdx or a.prom, 'the SDX ROM' if a.sdx else 'the CP/M PROM')
    prom = load(a.prom or a.sdx, 'the CP/M PROM' if a.prom else 'the SDX ROM')
    font = load(a.font, 'the character ROM')
    for name, d in (('SDX ROM', sdx), ('CP/M PROM', prom)):
        if d[:2] != bytes([0x08, 0x07]):
            print('warning: the %s does not start with the MTX ROM signature 08 07 06 05 04 03 02 01, so the core will not switch it on' % name)
    out = sdx + font + prom
    open(a.out, 'wb').write(out)
    print('wrote %s: %d bytes (SDX ROM %d, character ROM %d, CP/M PROM %d), MD5 %s' % (a.out, len(out), len(sdx), len(font), len(prom), hashlib.md5(out).hexdigest()))


if __name__ == '__main__':
    main()
