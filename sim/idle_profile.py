"""Where does the Z80 spend its time at the BASIC prompt (waiting for a key), with and without the SDX loaded, and while a
BASIC program runs? The histogram of instruction fetch addresses (4K pages and the busiest 16 byte blocks)."""
import collections
import sys

sys.path.insert(0, '.')
import mtx_emu as e
from test_sdx import key, typ, last

ROM = '<folder with boot.rom, boot1.rom, boot2.rom>/boot3.rom'
SYS = '<project>/refs/memu_src/mfloppy/andy_sys.mfloppy'


def profile(m, frames, label):
    hist = collections.Counter()
    orig = m.cpu.step

    def step():
        hist[m.cpu.PC] += 1
        orig()
    m.cpu.step = step
    m.run(frames)
    m.cpu.step = orig
    tot = sum(hist.values())
    pages = collections.Counter()
    blocks = collections.Counter()
    for pc, n in hist.items():
        pages[pc >> 12] += n
        blocks[pc >> 4] += n
    print('%s: %d instructions in %d frames' % (label, tot, frames))
    print('   by 4K page: ' + ', '.join('%X000 %.1f%%' % (p, 100.0 * n / tot) for p, n in sorted(pages.items(), key=lambda x: -x[1])[:5]))
    print('   busiest 16 byte blocks: ' + ', '.join('%04X %.1f%%' % (b << 4, 100.0 * n / tot) for b, n in blocks.most_common(6)))
    lo = min(pc for pc, n in hist.items() if n > tot / 500)
    hi = max(pc for pc, n in hist.items() if n > tot / 500)
    print('   addresses used by more than 0.2%% of fetches: %04X..%04X' % (lo, hi))


m = e.MTX(None)
m.run(300)
profile(m, 100, 'BASIC prompt, no SDX')

sysdisc = bytearray(open(SYS, 'rb').read())
m = e.MTX(None, sdx_rom=ROM, floppies=(sysdisc, None), sdx_slot=3)
m.run(80)
typ(m, 'ROM 3', 400)
profile(m, 100, 'BASIC prompt after ROM 3')

typ(m, '10 FOR I=1 TO 100000: A=A+1: NEXT I', 30)
key(m, [e.LAYOUT['R']]); key(m, [e.LAYOUT['U']]); key(m, [e.LAYOUT['N']]); key(m, [e.LAYOUT[chr(10)]], hold=10, gap=10)
m.run(60)
profile(m, 60, 'a BASIC program running')
