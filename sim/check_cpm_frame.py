"""Read cpm_frame.txt (the 640 x 480 picture the 80 column board made in tb_mtx_cpm.vhd, one character a pixel: . is black, R G B Y M C W
the colours) and turn it back into text with the character ROM, then compare with what the CP/M boot should show.

    python check_cpm_frame.py [frame file] [expected text file]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FRAME = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'cpm_frame.txt')
CG = os.path.join(HERE, '..', '..', 'refs', 'col80_cpm', 'dl', '80char_0743.bin')

font = open(CG, 'rb').read()
rows = [l.rstrip('\n') for l in open(FRAME)]
assert len(rows) == 480 and all(len(r) == 640 for r in rows), (len(rows), set(len(r) for r in rows))

glyph = {}
for ch in range(32, 127):
    glyph[tuple(font[0x1000 + ch * 16 + k] for k in range(10))] = chr(ch)
glyph_inv = {tuple(b ^ 0xFF for b in k): v for k, v in glyph.items()}

lines = []
unknown = 0
colours = {}
doubled_ok = True
for r in range(24):
    s = ''
    for c in range(80):
        cell = []
        for k in range(10):
            a = rows[r * 20 + 2 * k][c * 8:c * 8 + 8]
            b = rows[r * 20 + 2 * k + 1][c * 8:c * 8 + 8]
            if a != b:
                doubled_ok = False
            cell.append(a)
            for p in a:
                if p != '.':
                    colours[p] = colours.get(p, 0) + 1
        bits = tuple(int(''.join('0' if p == '.' else '1' for p in row), 2) for row in cell)
        if bits in glyph:
            s += glyph[bits]
        elif bits in glyph_inv:
            s += glyph_inv[bits]          # the cursor
        else:
            s += '?'
            unknown += 1
    lines.append(s.rstrip())
print('\n'.join(lines))
print('---')
print('lines shown twice:', doubled_ok, '| cells that are not a character:', unknown, '| pixel colours:', colours)
text = '\n'.join(lines)
ok = True
for want in ('MTX Bootstrap Prom', 'Ram Test - OK', 'MTX 59K Memotech', 'A>'):
    f = want in text
    ok = ok and f
    print('  %-28s %s' % (want, 'found' if f else 'MISSING'))
print('PASS' if ok and doubled_ok and unknown == 0 else 'FAIL')
