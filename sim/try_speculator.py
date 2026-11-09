"""Try the original Speculator program (SPEC1.mtx) in the Python MTX with a model of the Speculator board.

The board model is written from Speculator_Schematic.pdf, separately from rtl/mtx_speculator.vhd, so the two can be
compared. Usage:  python try_speculator.py [board|noboard] [path to a .mtx]
"""
import os
import sys

import mtx_emu as e

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC1 = os.path.join(HERE, '..', '..', 'refs', 'speculator', 'programs', 'speculator_program', 'SPEC1.mtx')


def bit(a, n):
    return (a >> n) & 1


class Board:
    """The 6116 behind the IC3/IC4 decode. a = the full 16 bit I/O address, rd = True for a read cycle."""

    def __init__(self):
        self.ram = bytearray(2048)
        self.nmien = 0
        self.nmisel = 0

    @staticmethod
    def ramcs(a):
        return (bit(a, 6) and bit(a, 5)) or (a & 0x1F) == 0x1F

    @staticmethod
    def keyio(a, rd):
        if (a & 0x7E) != 0x7E or bit(a, 0):
            return False
        # port 7E (A7 = 0) when written, port FE (A7 = 1) when read
        return (not bit(a, 7) and not rd) or (bit(a, 7) and rd)

    def index(self, a, rd):
        """RA3..RA0 as the nets are at the RAM: each RAn is pulled low by its IC4 product."""
        k = self.keyio(a, rd)
        hi = [bit(a, 8 + i) for i in range(8)]            # A8 .. A15
        a8, a9, a10, a11, a12, a13, a14, a15 = hi
        p0 = a15 and (not a14 or (a13 and (not a12 or (a11 and (not a10 or (a9 and not a8))))))
        p1 = a15 and a14 and (not a13 or not a12 or (a11 and a10 and (not a9 or not a8)))
        p2 = a15 and a14 and a13 and a12 and (not a11 or not a10 or not a9 or not a8)
        ra0 = 0 if (k and p0) else 1
        ra1 = 0 if (k and p1) else 1
        ra2 = 0 if (k and p2) else 1
        ra3 = 0 if (k or (not bit(a, 7) and bit(a, 0))) else 1
        return (ra3 << 3) | (ra2 << 2) | (ra1 << 1) | ra0

    def addr(self, a, rd):
        return ((a & 0x7F) << 4) | self.index(a, rd)

    def read(self, a):
        if self.ramcs(a):
            return self.ram[self.addr(a, True)]
        return None

    def write(self, a, v):
        if (a & 0xFF) == 0xFF:
            self.nmien = v & 1
            self.nmisel = (v >> 1) & 1
        if self.ramcs(a):
            self.ram[self.addr(a, False)] = v


class SpecMTX(e.MTX):
    def __init__(self, *a, board=True, **k):
        super().__init__(*a, **k)
        self.board = Board() if board else None
        self.probes = []                       # (kind, port) for every access in the board's decode ranges
        self.nmi_count = 0
        self.nmi_wait = 0
        self.int_was = False

    def in_(self, port, hi=0):
        a = (hi << 8) | (port & 0xFF)
        if self.board is not None:
            v = self.board.read(a)
            if v is not None:
                self.probes.append(('in', a, v))
                return v
        elif (port & 0x60) == 0x60 or (port & 0x1F) == 0x1F:
            self.probes.append(('in', a, 0xFF))
        return super().in_(port, hi)

    def out(self, port, v, hi=0):
        a = (hi << 8) | (port & 0xFF)
        if self.board is not None:
            self.board.write(a, v)
        if (port & 0x60) == 0x60 or (port & 0x1F) == 0x1F:
            self.probes.append(('out', a, v))
        super().out(port, v, hi)

    def run(self, frames, per_frame=14000, stop=None):
        cpu = self.cpu
        for _ in range(frames):
            for _ in range(per_frame):
                c = self.ctc
                if not c['ctrl'] & 0x40 and c['tc'] and not c['want_tc']:
                    c['acc'] = c.get('acc', 0) + self.tstep()
                    per = c['tc'] * (256 if c['ctrl'] & 0x20 else 16)
                    if c['acc'] >= per:
                        c['acc'] -= per
                        if c['ctrl'] & 0x80: self.irq = True
                # the board sees the falling edge of /INT: here, the moment the CTC raises its request
                if self.irq and not self.int_was and self.board is not None and self.board.nmien:
                    if self.board.nmisel: self.nmi_wait = 1        # immediate: before the next instruction
                    else: self.nmi_wait = 2                         # about 1.5us later: one or two instructions on
                self.int_was = self.irq
                if self.nmi_wait:
                    self.nmi_wait -= 1
                    if self.nmi_wait == 0:
                        self.nmi_count += 1
                        cpu.halted = False
                        cpu.iff2 = cpu.iff1
                        cpu.iff1 = 0
                        cpu.push(cpu.PC)
                        cpu.PC = 0x66
                if self.irq and cpu.iff1 and not cpu.ei_delay:
                    self.irq = False
                    cpu.halted = False
                    cpu.iff1 = cpu.iff2 = 0
                    cpu.push(cpu.PC)
                    cpu.PC = cpu.rd16(((cpu.I << 8) | self.ctc['vec']) & 0xFFFF)
                if cpu.ei_delay: cpu.ei_delay -= 1
                if cpu.halted and not self.irq:
                    break
                cpu.step()
                self.instr += 1
            self.vdp_frame()
            if stop and stop(self): return True
        return False


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'board'
    path = sys.argv[2] if len(sys.argv) > 2 else SPEC1
    stream = open(path, 'rb').read()
    m = SpecMTX(stream, board=(mode == 'board'))
    m.run(400)
    print('mode', mode, 'file', os.path.basename(path), len(stream), 'bytes')
    print(chr(10).join(m.screen()[:6]))
    for ch in 'LOAD ':
        m.press([e.LAYOUT[ch]], 6)
    for _ in range(2):                              # the quote: SHIFT first, then 2, held longer
        m.keys = {e.SHIFT}; m.run(3)
        m.keys = {e.SHIFT, e.LAYOUT['2']}; m.run(8)
        m.keys = set(); m.run(6)
    m.press([e.LAYOUT[chr(10)]], 6)
    m.run(300)
    print('loaded: sp=%d/%d PC=%04X' % (m.sp, len(stream), m.cpu.PC))
    print(chr(10).join(m.screen()[-3:]))
    m.probes.clear()
    for i in range(10):
        m.run(60)
        print('RUN +%3d frames: PC=%04X iobyte=%02X vdp1=%02X probes=%d nmi=%d' %
              ((i + 1) * 60, m.cpu.PC, m.iobyte, m.vdp_regs[1], len(m.probes), m.nmi_count))
    print(chr(10).join(m.screen()))
    seen = {}
    for kind, a, v in m.probes:
        seen.setdefault((kind, a & 0xFF), []).append(v)
    print('ports the program touched in the board ranges (kind, port): count, first values')
    for (kind, p), vs in sorted(seen.items()):
        print('  %-3s %02X  x%-5d %s' % (kind, p, len(vs), ' '.join('%02X' % x for x in vs[:6])))
    if m.board is not None:
        print('NMIEN %d NMISEL %d' % (m.board.nmien, m.board.nmisel))


if __name__ == '__main__':
    main()
