"""The SDX CP/M bootstrap PROM, the 80 column board model and a real CP/M system disc, in the software MTX.

    python run_cpm_model.py [slot 3|5] [frames after ROM n]
"""
import sys
sys.path.insert(0, '.')
import mtx_emu as e
import test_sdx as t

ROM = '<project>/refs/col80_cpm/SDX_98E7.rom'
DISC = '<project>/refs/memu_src/mfloppy/andy_sys.mfloppy'
slot = int(sys.argv[1]) if len(sys.argv) > 1 else 3
frames = int(sys.argv[2]) if len(sys.argv) > 2 else 600

a = bytearray(open(DISC, 'rb').read())
m = e.MTX(None, sdx_rom=ROM, floppies=(a, None), sdx_slot=slot, col80=True)
m.run(80)
t.typ(m, 'ROM %d' % slot, frames=40)
for i in range(frames // 60):
    m.run(60)
    print('+%4d frames: PC=%04X iobyte=%02X col80 writes %d reads %d fdc cmds %s' % ((i + 1) * 60, m.cpu.PC, m.iobyte, m.col.writes, m.col.reads,
          getattr(m.fdc, 'ncmd', '?')))
print('--- the 80 column board:')
print('\n'.join(l for l in m.col.text() if l.strip()))
print('--- the VDP screen (last lines):')
print('\n'.join(r for r in m.screen() if r.strip())[-400:])
print('crtc registers:', m.col.crtc)
print('first accesses:', m.col.log[:40])
import collections
h = collections.Counter(m.col.atr[i] for i in range(1920))
print('attribute bytes in the visible 1920 cells:', {hex(k): v for k, v in h.most_common(8)})
print('ascii in cells with attribute != most common:', [(i, hex(m.col.atr[i]), hex(m.col.asc[i])) for i in range(1920) if m.col.atr[i] != h.most_common(1)[0][0]][:10])
cur = ((m.col.crtc[14] & 0x3F) << 8) | m.col.crtc[15]
print('cursor address', cur, 'row', cur // 80, 'col', cur % 80, 'cursor start/end lines', m.col.crtc[10] & 31, m.col.crtc[11] & 31, 'blink mode bits', (m.col.crtc[10] >> 5) & 3)
