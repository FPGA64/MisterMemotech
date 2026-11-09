"""The SDX in the software MTX: the real SDX ROM in ROM slot 5, the floppy controller on ports 10..14 and a real SDX
disc image. ROM 5 puts the SDX commands (USER ...) into BASIC."""
import sys
sys.path.insert(0, '.')
import mtx_emu as e

SDX_ROM = '<project>/refs/memu_src/roms/sdx.rom'
DISC_A = '<project>/refs/memu_src/mfloppy/andy_sys.mfloppy'
DISC_B = '<project>/refs/memu_src/mfloppy/games.mfloppy'


def key(m, ks, shift=False, hold=8, gap=6):
    if shift:
        m.keys = {e.SHIFT}; m.run(4)
        m.keys = {e.SHIFT} | set(ks); m.run(hold)
        m.keys = {e.SHIFT}; m.run(3)
    else:
        m.keys = set(ks); m.run(hold)
    m.keys = set(); m.run(gap)


KEYS_SHIFT = {'"': '2'}


# shifted characters, from the keyboard grid in rtl/mtx_kbd.vhd: the key and SHIFT
SHIFTED = {'"': 11, '*': 55, '=': 5, '+': 45, '?': 65, '<': 64, '>': 74}


def typ(m, text, frames=120):
    for ch in text:
        if ch in SHIFTED: key(m, [SHIFTED[ch]], shift=True)
        else: key(m, [e.LAYOUT[ch.upper()]])
    key(m, [e.LAYOUT[chr(10)]], hold=10, gap=10)
    m.run(frames)


def last(m, n=8):
    return [r for r in m.screen() if r.strip()][-n:]


def machine(trace=None):
    a = bytearray(open(DISC_A, 'rb').read())
    b = bytearray(open(DISC_B, 'rb').read())
    m = e.MTX(None, sdx_rom=SDX_ROM, floppies=(a, b))
    if trace: m.fdc.trace = trace
    m.run(80)
    return m


if __name__ == '__main__':
    log = []
    m = machine(log.append)
    typ(m, 'ROM 5', 200)
    print('ROM 5   ->', last(m, 4))
    log.clear()
    typ(m, 'USER DIR', 3000)
    print('USER DIR ->')
    for r in last(m, 14): print('   ', r)
    print('%d FDC port accesses; first 40:' % len(log))
    for l in log[:40]: print('   ', l)
