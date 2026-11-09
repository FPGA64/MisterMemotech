"""A small MTX in Python: Z80 + the real OS/BASIC ROMs + the real INOUT overlay + a .mtx stream.

It is only a test rig. It exists to run BASIC's own LOAD against a .mtx file with the exact overlay
machine code that is in the FPGA (rtl/mtx_overlay.vhd), and to see where a bad file gets stuck.

Models: the memory map (rtl/memory_map.vhd), the keyboard matrix, VDP status/interrupt flag, CTC channel 0
(the 50Hz interrupt) and the ports 8E/8F stream. Nothing else.

Usage as a module:  m = MTX(stream_bytes); m.boot(); m.type_line('LOAD ""'); m.run_frames(n)
"""
import os
import re
import sys

import sdx_fdc
import col80_model

HERE = os.path.dirname(os.path.abspath(__file__))
ROMDIR = os.path.join(HERE, '..', '..', 'release_work', 'MTX512_SD', 'games', 'MTX512')

S, Z, Y, H, X, P, N, C = 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01
PAR = [P if bin(i).count('1') % 2 == 0 else 0 for i in range(256)]


def overlay_bytes():
    t = open(os.path.join(HERE, '..', 'rtl', 'mtx_overlay.vhd')).read()
    body = t[t.index('constant rom'):t.index('signal off')]
    return bytes(int(h, 16) for h in re.findall(r'x"([0-9A-Fa-f]{2})"', body))


def overlay_base():
    t = open(os.path.join(HERE, '..', 'rtl', 'mtx_overlay.vhd')).read()
    return int(re.search(r'constant BASE : integer := 16#([0-9A-Fa-f]+)#', t).group(1), 16)


class Z80:
    def __init__(s, bus):
        s.bus = bus
        s.R = [0] * 8                   # B C D E H L - A
        s.F = 0
        s.alt = [0] * 8
        s.altF = 0
        s.IX = s.IY = 0
        s.SP = 0xFFFF
        s.PC = 0
        s.I = 0
        s.iff1 = s.iff2 = 0
        s.im = 0
        s.halted = False
        s.ei_delay = 0

    # ---- helpers
    def rd16(s, a):
        return s.bus.read(a) | (s.bus.read((a + 1) & 0xFFFF) << 8)

    def wr16(s, a, v):
        s.bus.write(a, v & 0xFF)
        s.bus.write((a + 1) & 0xFFFF, (v >> 8) & 0xFF)

    def push(s, v):
        s.SP = (s.SP - 2) & 0xFFFF
        s.wr16(s.SP, v)

    def pop(s):
        v = s.rd16(s.SP)
        s.SP = (s.SP + 2) & 0xFFFF
        return v

    def fetch(s):
        v = s.bus.read(s.PC)
        s.PC = (s.PC + 1) & 0xFFFF
        return v

    def fetch16(s):
        lo = s.fetch()
        return lo | (s.fetch() << 8)

    def HL(s): return (s.R[4] << 8) | s.R[5]
    def BC(s): return (s.R[0] << 8) | s.R[1]
    def DE(s): return (s.R[2] << 8) | s.R[3]
    def AF(s): return (s.R[7] << 8) | s.F

    def setHL(s, v): s.R[4] = (v >> 8) & 0xFF; s.R[5] = v & 0xFF
    def setBC(s, v): s.R[0] = (v >> 8) & 0xFF; s.R[1] = v & 0xFF
    def setDE(s, v): s.R[2] = (v >> 8) & 0xFF; s.R[3] = v & 0xFF
    def setAF(s, v): s.R[7] = (v >> 8) & 0xFF; s.F = v & 0xFF

    def rp(s, p, pre):                   # BC DE HL/IX/IY SP
        if p == 0: return s.BC()
        if p == 1: return s.DE()
        if p == 2: return s.HL() if pre == 0 else (s.IX if pre == 1 else s.IY)
        return s.SP

    def setrp(s, p, v, pre):
        v &= 0xFFFF
        if p == 0: s.setBC(v)
        elif p == 1: s.setDE(v)
        elif p == 2:
            if pre == 0: s.setHL(v)
            elif pre == 1: s.IX = v
            else: s.IY = v
        else: s.SP = v

    def rp2(s, p, pre):
        return s.AF() if p == 3 else s.rp(p, pre)

    def setrp2(s, p, v, pre):
        if p == 3: s.setAF(v)
        else: s.setrp(p, v, pre)

    def cc(s, c):
        f = s.F
        if c == 0: return not f & Z
        if c == 1: return bool(f & Z)
        if c == 2: return not f & C
        if c == 3: return bool(f & C)
        if c == 4: return not f & P
        if c == 5: return bool(f & P)
        if c == 6: return not f & S
        return bool(f & S)

    # ---- register / memory operand r (0..7) with the DD/FD prefix rules
    def getr(s, i, pre, ea):
        if i == 6: return s.bus.read(ea)
        if pre and i == 4: return ((s.IX if pre == 1 else s.IY) >> 8) & 0xFF
        if pre and i == 5: return (s.IX if pre == 1 else s.IY) & 0xFF
        return s.R[i]

    def setr(s, i, v, pre, ea):
        v &= 0xFF
        if i == 6: s.bus.write(ea, v)
        elif pre and i == 4:
            if pre == 1: s.IX = (s.IX & 0xFF) | (v << 8)
            else: s.IY = (s.IY & 0xFF) | (v << 8)
        elif pre and i == 5:
            if pre == 1: s.IX = (s.IX & 0xFF00) | v
            else: s.IY = (s.IY & 0xFF00) | v
        else: s.R[i] = v

    def ea_for(s, pre):
        if pre == 0: return s.HL()
        d = s.fetch()
        if d & 0x80: d -= 256
        return ((s.IX if pre == 1 else s.IY) + d) & 0xFFFF

    # ---- ALU
    def alu(s, op, v):
        a = s.R[7]
        if op == 0 or op == 1:           # ADD ADC
            c = (s.F & C) if op == 1 else 0
            r = a + v + c
            f = (r & (S | Y | X)) | (H if (a & 15) + (v & 15) + c > 15 else 0)
            f |= P if ((a ^ v ^ 0x80) & (a ^ r) & 0x80) else 0
            f |= C if r > 255 else 0
            r &= 255
            s.F = f | (Z if r == 0 else 0)
            s.R[7] = r
        elif op in (2, 3, 7):            # SUB SBC CP
            c = (s.F & C) if op == 3 else 0
            r = a - v - c
            f = N | (H if (a & 15) - (v & 15) - c < 0 else 0)
            f |= P if ((a ^ v) & (a ^ r) & 0x80) else 0
            f |= C if r < 0 else 0
            r &= 255
            f |= (r & (S)) | (Z if r == 0 else 0)
            if op == 7:
                f |= v & (Y | X)
            else:
                f |= r & (Y | X)
                s.R[7] = r
            s.F = f
        elif op == 4:
            r = a & v; s.R[7] = r; s.F = (r & (S | Y | X)) | H | PAR[r] | (Z if r == 0 else 0)
        elif op == 5:
            r = a ^ v; s.R[7] = r; s.F = (r & (S | Y | X)) | PAR[r] | (Z if r == 0 else 0)
        elif op == 6:
            r = a | v; s.R[7] = r; s.F = (r & (S | Y | X)) | PAR[r] | (Z if r == 0 else 0)

    def inc8(s, v):
        r = (v + 1) & 255
        s.F = (s.F & C) | (r & (S | Y | X)) | (H if (v & 15) == 15 else 0) | (P if v == 0x7F else 0) | (Z if r == 0 else 0)
        return r

    def dec8(s, v):
        r = (v - 1) & 255
        s.F = (s.F & C) | N | (r & (S | Y | X)) | (H if (v & 15) == 0 else 0) | (P if v == 0x80 else 0) | (Z if r == 0 else 0)
        return r

    def add16(s, a, b):
        r = a + b
        s.F = (s.F & (S | Z | P)) | ((r >> 8) & (Y | X)) | (H if (a & 0xFFF) + (b & 0xFFF) > 0xFFF else 0) | (C if r > 0xFFFF else 0)
        return r & 0xFFFF

    def adc16(s, a, b):
        c = s.F & C
        r = a + b + c
        f = ((r >> 8) & (S | Y | X)) | (H if (a & 0xFFF) + (b & 0xFFF) + c > 0xFFF else 0)
        f |= P if ((a ^ b ^ 0x8000) & (a ^ r) & 0x8000) else 0
        f |= C if r > 0xFFFF else 0
        r &= 0xFFFF
        s.F = f | (Z if r == 0 else 0)
        return r

    def sbc16(s, a, b):
        c = s.F & C
        r = a - b - c
        f = N | ((r >> 8) & (S | Y | X)) | (H if (a & 0xFFF) - (b & 0xFFF) - c < 0 else 0)
        f |= P if ((a ^ b) & (a ^ r) & 0x8000) else 0
        f |= C if r < 0 else 0
        r &= 0xFFFF
        s.F = f | (Z if r == 0 else 0)
        return r

    def rot(s, y, v):
        c = s.F & C
        if y == 0: c = v >> 7; r = ((v << 1) | c) & 255
        elif y == 1: c = v & 1; r = (v >> 1) | (c << 7)
        elif y == 2: nc = v >> 7; r = ((v << 1) | c) & 255; c = nc
        elif y == 3: nc = v & 1; r = (v >> 1) | (c << 7); c = nc
        elif y == 4: c = v >> 7; r = (v << 1) & 255
        elif y == 5: c = v & 1; r = (v >> 1) | (v & 0x80)
        elif y == 6: c = v >> 7; r = ((v << 1) | 1) & 255
        else: c = v & 1; r = v >> 1
        s.F = (r & (S | Y | X)) | PAR[r] | c | (Z if r == 0 else 0)
        return r

    def daa(s):
        a = s.R[7]; f = s.F
        lo = 0
        c = f & C
        if (f & H) or (a & 15) > 9: lo = 6
        if c or a > 0x99: lo |= 0x60; c = C
        if f & N:
            h = H if (f & H) and (a & 15) < 6 else 0
            a = (a - lo) & 255
        else:
            h = H if (a & 15) > 9 else 0
            a = (a + lo) & 255
        s.R[7] = a
        s.F = (a & (S | Y | X)) | (f & N) | h | c | PAR[a] | (Z if a == 0 else 0)

    # ---- one instruction
    def step(s):
        bus = s.bus
        if s.halted:
            return
        pre = 0
        op = s.fetch()
        while op == 0xDD or op == 0xFD:
            pre = 1 if op == 0xDD else 2
            op = s.fetch()
        R = s.R
        x = op >> 6; y = (op >> 3) & 7; z = op & 7; p = y >> 1; q = y & 1
        if x == 0:
            if z == 0:
                if y == 0: pass
                elif y == 1:
                    s.altF, s.F = s.F, s.altF
                    R[7], s.alt[7] = s.alt[7], R[7]
                elif y == 2:
                    d = s.fetch(); d = d - 256 if d & 128 else d
                    R[0] = (R[0] - 1) & 255
                    if R[0]: s.PC = (s.PC + d) & 0xFFFF
                else:
                    d = s.fetch(); d = d - 256 if d & 128 else d
                    if y == 3 or s.cc(y - 4): s.PC = (s.PC + d) & 0xFFFF
            elif z == 1:
                if q == 0: s.setrp(p, s.fetch16(), pre)
                else: s.setrp(2, s.add16(s.rp(2, pre), s.rp(p, pre)), pre)
            elif z == 2:
                if p == 0:
                    if q == 0: bus.write(s.BC(), R[7])
                    else: R[7] = bus.read(s.BC())
                elif p == 1:
                    if q == 0: bus.write(s.DE(), R[7])
                    else: R[7] = bus.read(s.DE())
                elif p == 2:
                    a = s.fetch16()
                    if q == 0: s.wr16(a, s.rp(2, pre))
                    else: s.setrp(2, s.rd16(a), pre)
                else:
                    a = s.fetch16()
                    if q == 0: bus.write(a, R[7])
                    else: R[7] = bus.read(a)
            elif z == 3:
                s.setrp(p, s.rp(p, pre) + (1 if q == 0 else -1), pre)
            elif z == 4:
                ea = s.ea_for(pre) if y == 6 else 0
                s.setr(y, s.inc8(s.getr(y, pre, ea)), pre, ea)
            elif z == 5:
                ea = s.ea_for(pre) if y == 6 else 0
                s.setr(y, s.dec8(s.getr(y, pre, ea)), pre, ea)
            elif z == 6:
                ea = s.ea_for(pre) if y == 6 else 0
                s.setr(y, s.fetch(), pre, ea)
            else:
                a = R[7]
                if y == 0:
                    c = a >> 7; R[7] = ((a << 1) | c) & 255; s.F = (s.F & (S | Z | P)) | (R[7] & (Y | X)) | c
                elif y == 1:
                    c = a & 1; R[7] = (a >> 1) | (c << 7); s.F = (s.F & (S | Z | P)) | (R[7] & (Y | X)) | c
                elif y == 2:
                    c = a >> 7; R[7] = ((a << 1) | (s.F & C)) & 255; s.F = (s.F & (S | Z | P)) | (R[7] & (Y | X)) | c
                elif y == 3:
                    c = a & 1; R[7] = (a >> 1) | ((s.F & C) << 7); s.F = (s.F & (S | Z | P)) | (R[7] & (Y | X)) | c
                elif y == 4: s.daa()
                elif y == 5:
                    R[7] = a ^ 255; s.F = (s.F & (S | Z | P | C)) | H | N | (R[7] & (Y | X))
                elif y == 6: s.F = (s.F & (S | Z | P)) | (a & (Y | X)) | C
                else: s.F = (s.F & (S | Z | P)) | (a & (Y | X)) | (H if s.F & C else 0) | (0 if s.F & C else C)
        elif x == 1:
            if op == 0x76:
                s.halted = True
            elif y == 6 or z == 6:
                ea = s.ea_for(pre)
                if y == 6: bus.write(ea, R[z])
                else: R[y] = bus.read(ea)
            else:
                s.setr(y, s.getr(z, pre, 0), pre, 0)
        elif x == 2:
            ea = s.ea_for(pre) if z == 6 else 0
            s.alu(y, s.getr(z, pre, ea))
        else:
            if z == 0:
                if s.cc(y): s.PC = s.pop()
            elif z == 1:
                if q == 0: s.setrp2(p, s.pop(), pre)
                elif p == 0: s.PC = s.pop()
                elif p == 1:
                    for i in range(6): R[i], s.alt[i] = s.alt[i], R[i]
                elif p == 2: s.PC = s.rp(2, pre)
                else: s.SP = s.rp(2, pre)
            elif z == 2:
                a = s.fetch16()
                if s.cc(y): s.PC = a
            elif z == 3:
                if y == 0: s.PC = s.fetch16()
                elif y == 1: s.cb(pre)
                elif y == 2: n = s.fetch(); bus.out(n, R[7], R[7])
                elif y == 3: n = s.fetch(); R[7] = bus.in_(n, R[7])
                elif y == 4:
                    v = s.rd16(s.SP); s.wr16(s.SP, s.rp(2, pre)); s.setrp(2, v, pre)
                elif y == 5:
                    d, h = s.DE(), s.HL(); s.setDE(h); s.setHL(d)
                elif y == 6: s.iff1 = s.iff2 = 0
                else: s.iff1 = s.iff2 = 1; s.ei_delay = 1
            elif z == 4:
                a = s.fetch16()
                if s.cc(y): s.push(s.PC); s.PC = a
            elif z == 5:
                if q == 0: s.push(s.rp2(p, pre))
                elif p == 0:
                    a = s.fetch16(); s.push(s.PC); s.PC = a
                elif p == 2: s.ed()
            elif z == 6:
                s.alu(y, s.fetch())
            else:
                s.push(s.PC); s.PC = y * 8

    def cb(s, pre):
        if pre:
            ea = s.ea_for(pre)
            op = s.fetch()
            x = op >> 6; y = (op >> 3) & 7; z = op & 7
            v = s.bus.read(ea)
            if x == 0:
                r = s.rot(y, v); s.bus.write(ea, r)
                if z != 6: s.R[z] = r
            elif x == 1:
                s.bit(y, v)
            else:
                r = (v & ~(1 << y)) if x == 2 else (v | (1 << y))
                s.bus.write(ea, r)
                if z != 6: s.R[z] = r
            return
        op = s.fetch()
        x = op >> 6; y = (op >> 3) & 7; z = op & 7
        v = s.getr(z, 0, s.HL())
        if x == 0: s.setr(z, s.rot(y, v), 0, s.HL())
        elif x == 1: s.bit(y, v)
        elif x == 2: s.setr(z, v & ~(1 << y), 0, s.HL())
        else: s.setr(z, v | (1 << y), 0, s.HL())

    def bit(s, y, v):
        r = v & (1 << y)
        s.F = (s.F & C) | H | (v & (Y | X)) | (Z | P if r == 0 else 0) | (S if (y == 7 and r) else 0)

    def ed(s):
        R = s.R; bus = s.bus
        op = s.fetch()
        x = op >> 6; y = (op >> 3) & 7; z = op & 7; p = y >> 1; q = y & 1
        if x == 1:
            if z == 0:
                v = bus.in_(R[1], R[0])
                if y != 6: R[y] = v
                s.F = (s.F & C) | (v & (S | Y | X)) | PAR[v] | (Z if v == 0 else 0)
            elif z == 1:
                bus.out(R[1], 0 if y == 6 else R[y], R[0])
            elif z == 2:
                if q == 0: s.setHL(s.sbc16(s.HL(), s.rp(p, 0)))
                else: s.setHL(s.adc16(s.HL(), s.rp(p, 0)))
            elif z == 3:
                a = s.fetch16()
                if q == 0: s.wr16(a, s.rp(p, 0))
                else: s.setrp(p, s.rd16(a), 0)
            elif z == 4:
                a = R[7]
                r = (0 - a) & 255
                s.F = N | (r & (S | Y | X)) | (H if (a & 15) else 0) | (P if a == 0x80 else 0) | (C if a else 0) | (Z if r == 0 else 0)
                s.R[7] = r
            elif z == 5:
                s.PC = s.pop(); s.iff1 = s.iff2
            elif z == 6:
                s.im = [0, 0, 1, 2, 0, 0, 1, 2][y]
            else:
                if y == 0: s.I = R[7]
                elif y == 1: pass
                elif y == 2:
                    R[7] = 0x55; s.F = (s.F & C) | (R[7] & (S | Y | X)) | (s.iff2 and P or 0)
                elif y == 3:
                    R[7] = 0x55; s.F = (s.F & C) | (R[7] & (S | Y | X)) | (s.iff2 and P or 0)
                elif y == 4:                        # RRD
                    hl = s.HL(); m = s.bus.read(hl); a = R[7]
                    bus.write(hl, ((a & 15) << 4) | (m >> 4)); R[7] = (a & 0xF0) | (m & 15)
                    s.F = (s.F & C) | (R[7] & (S | Y | X)) | PAR[R[7]] | (Z if R[7] == 0 else 0)
                elif y == 5:                        # RLD
                    hl = s.HL(); m = s.bus.read(hl); a = R[7]
                    bus.write(hl, ((m << 4) & 0xF0) | (a & 15)); R[7] = (a & 0xF0) | (m >> 4)
                    s.F = (s.F & C) | (R[7] & (S | Y | X)) | PAR[R[7]] | (Z if R[7] == 0 else 0)
        elif x == 2 and z < 4 and y >= 4:
            s.block(y, z)

    def block(s, y, z):
        R = s.R; bus = s.bus
        inc = 1 if y in (4, 6) else -1
        rep = y >= 6
        while True:
            if z == 0:                              # LDI/LDD
                v = bus.read(s.HL()); bus.write(s.DE(), v)
                s.setHL(s.HL() + inc); s.setDE(s.DE() + inc); s.setBC(s.BC() - 1)
                s.F = (s.F & (S | Z | C)) | (P if s.BC() else 0)
                again = rep and s.BC() != 0
            elif z == 1:                            # CPI/CPD
                v = bus.read(s.HL()); a = R[7]; r = (a - v) & 255
                s.setHL(s.HL() + inc); s.setBC(s.BC() - 1)
                s.F = (s.F & C) | N | (r & S) | (Z if r == 0 else 0) | (H if (a & 15) < (v & 15) else 0) | (P if s.BC() else 0)
                again = rep and s.BC() != 0 and r != 0
            elif z == 2:                            # INI/IND
                v = bus.in_(R[1], R[0]); bus.write(s.HL(), v)
                s.setHL(s.HL() + inc); R[0] = (R[0] - 1) & 255
                s.F = (s.F & C) | N | (Z if R[0] == 0 else 0)
                again = rep and R[0] != 0
            else:                                   # OUTI/OUTD
                v = bus.read(s.HL()); R[0] = (R[0] - 1) & 255
                bus.out(R[1], v, R[0])
                s.setHL(s.HL() + inc)
                s.F = (s.F & C) | N | (Z if R[0] == 0 else 0)
                again = rep and R[0] != 0
            if not again:
                return
            s.bus.tick(1)


class MTX:
    def __init__(s, stream=None, overlay=True, unlimited_stream=False, sdx_rom=None, floppies=(None, None), sdx_slot=5, col80=False):
        d = lambda n: open(os.path.join(ROMDIR, n), 'rb').read()
        s.os = bytearray(d('boot.rom'))
        s.basic = bytearray(d('boot1.rom'))
        s.assem = bytearray(d('boot2.rom'))
        # paged ROM slots 0..7 (the manual: R2,R1,R0 = bits 6..4 of the page port); only the fitted ones answer
        s.roms = {0: s.basic, 1: s.assem}
        s.fdc = None
        if sdx_rom is not None:
            s.roms[sdx_slot] = bytearray(open(sdx_rom, 'rb').read())      # the SDX ROM: ROM slot 3 (the card) or 5
            s.fdc = sdx_fdc.SdxFdc()
            for n, img in enumerate(floppies):
                if img is not None: s.fdc.mount(n, img)
        s.col = col80_model.Col80() if col80 else None      # the 80 column board (ports 30h to 39h)
        s.ram = [bytearray(0x2000) for _ in range(8)]
        s.iobyte = 0
        s.stream = bytes(stream) if stream is not None else b''
        s.sp = 0
        s.mounted = stream is not None
        if s.mounted and overlay:
            ov = overlay_bytes()
            s.os[overlay_base():overlay_base() + len(ov)] = ov
        s.cpu = Z80(s)
        s.keys = set()
        s.drive = 0xFF
        s.vdp_latch = None
        s.vdp_regs = [0] * 8
        s.vram = bytearray(16384)
        s.vaddr = 0
        s.vpre = 0
        s.frame_flag = 0
        s.ctc = {'vec': 0, 'ctrl': 0, 'tc': 0, 'cnt': 0, 'want_tc': False}
        s.irq = False
        s.instr = 0
        s.frames = 0
        s.rewinds = 0
        s.io_8e = 0
        s.map()
        s.trace_ops = None
        s.eof_waits = 0
        s.nm_req = []              # the name asked for, sent by the overlay to port 8D
        s.no_data = 0              # port 8D: 1 = the name asked for is not the one on the tape
        s.nodata_count = 0
        s.save_on = True           # a save image is mounted
        s.saved = bytearray()      # what SAVE has sent to port 8E
        s.save_starts = 0
        s.rng = None

    def tstep(s):
        return 7 if s.rng is None else s.rng.randint(3, 11)

    def map(s):
        io = s.iobyte
        r = [None] * 8
        w = [None] * 8
        for b in range(8):
            a14 = b >> 1
            if b >= 6:
                r[b] = w[b] = s.ram[b & 1]
            elif not io & 0x80:
                if b == 0: r[b] = s.os
                elif b == 1:
                    r[b] = s.roms.get((io >> 4) & 7)
                else:
                    sel = ((io & 15) << 2) | a14
                    pg = {2: 2, 1: 4, 6: 6}.get(sel)
                    if pg is not None: r[b] = w[b] = s.ram[pg + (b & 1)]
            else:
                sel = ((io & 15) << 2) | a14
                pg = {0: 6, 1: 4, 2: 2}.get(sel)
                if pg is not None: r[b] = w[b] = s.ram[pg + (b & 1)]
        s.rmap, s.wmap = r, w

    def read(s, a):
        m = s.rmap[a >> 13]
        return 0xFF if m is None else m[a & 0x1FFF]

    def write(s, a, v):
        m = s.wmap[a >> 13]
        if m is not None: m[a & 0x1FFF] = v

    def tick(s, n):
        pass

    # ---- I/O
    def sense(s):
        s5 = 0xFF; s6 = 0x03
        for k in s.keys:
            row, col = divmod(k, 10)
            if not (s.drive >> row) & 1:
                if col < 8: s5 &= ~(1 << col) & 0xFF
                else: s6 &= ~(1 << (col - 8)) & 0xFF
        return s5, s6

    def in_(s, port, hi=0):
        p = port & 0xFF
        if p == 0x02:
            v = 0x80 if s.frame_flag else 0
            s.frame_flag = 0; s.vdp_latch = None
            return v
        if p == 0x01:
            v = s.vpre
            s.vpre = s.vram[s.vaddr & 0x3FFF]; s.vaddr = (s.vaddr + 1) & 0x3FFF; s.vdp_latch = None
            return v
        if s.col is not None and 0x30 <= p <= 0x39: return s.col.in_(p)
        if p == 0x03: return 0x03
        if p == 0x04: return 0
        if p == 0x05: return s.sense()[0]
        if p == 0x06: return s.sense()[1]
        if 0x08 <= p <= 0x0B: return 0
        if p == 0x8E:
            if s.sp < len(s.stream):
                v = s.stream[s.sp]; s.sp += 1
                return v
            return 0xFF
        if s.fdc is not None and 0x10 <= p <= 0x14:
            return s.fdc.in_(p)
        if p == 0x8D:
            return s.no_data
        if p == 0x8F:
            # as the core (mtx_tape.sv): past the end of the file the stream stays ready (bit 0) and answers FF on
            # port 8E; bit 1 = end of file. Bit 2 (a block is being saved) is never set here. eof_waits counts the
            # status polls made at the end.
            if s.sp >= len(s.stream):
                s.eof_waits += 1
                return 0x03
            # bit 1 also says "the next byte is not FF": a header chunk then starts the tape again
            return 0x03 if s.stream[s.sp] != 0xFF else 0x01
        return 0xFF

    def out(s, port, v, hi=0):
        p = port & 0xFF
        if p == 0x00:
            s.iobyte = v; s.map()
        elif p == 0x01:
            s.vram[s.vaddr & 0x3FFF] = v; s.vpre = v; s.vaddr = (s.vaddr + 1) & 0x3FFF; s.vdp_latch = None
        elif p == 0x02:
            if s.vdp_latch is None: s.vdp_latch = v
            else:
                if v & 0xC0 == 0x80: s.vdp_regs[v & 7] = s.vdp_latch
                else:
                    s.vaddr = ((v & 0x3F) << 8) | s.vdp_latch
                    if not v & 0x40:
                        s.vpre = s.vram[s.vaddr & 0x3FFF]; s.vaddr = (s.vaddr + 1) & 0x3FFF
                s.vdp_latch = None
        elif s.col is not None and 0x30 <= p <= 0x39:
            s.col.out(p, v)
        elif p == 0x05:
            s.drive = v
        elif 0x08 <= p <= 0x0B:
            if p == 0x08 or True:
                ch = p - 8
                c = s.ctc
                if ch != 0: return
                if c['want_tc']:
                    c['tc'] = v or 256; c['cnt'] = c['tc']; c['want_tc'] = False
                elif v & 1:
                    c['ctrl'] = v
                    if v & 4: c['want_tc'] = True
                    if v & 2: c['cnt'] = c['tc']
                else:
                    c['vec'] = v & 0xF8
        elif s.fdc is not None and 0x10 <= p <= 0x14:
            s.fdc.out(p, v)
        elif p == 0x8D:
            s.name_byte(v)
        elif p == 0x8E:
            if s.save_on: s.saved.append(v)
        elif p == 0x8F:
            if v & 1: s.sp = 0; s.rewinds += 1
            if v & 2:
                s.saved = bytearray(); s.save_starts += 1

    def name_byte(s, v):
        """The overlay sends the 15 characters of the name asked for. When the 18 byte header of a tape has just gone
        by (18 bytes taken since the stream started) the name on the tape is compared: exact, ignoring case, and a
        blank name asks for any tape. A mismatch is reported on port 8D and the tape is rewound."""
        if not s.nm_req: s.no_data = 0
        s.nm_req.append(v)
        if len(s.nm_req) < 15: return
        rq, s.nm_req = s.nm_req, []
        if s.sp != 18: return
        tn = list(s.stream[1:16])
        bad = False
        if rq[0] >= 0x21:
            for q in range(15):
                if (rq[q] | 0x20) != (tn[q] | 0x20):
                    bad = rq[q] >= 0x21 or tn[q] >= 0x21
                    break
                if rq[q] < 0x21: break
        if bad:
            s.no_data = 1; s.nodata_count += 1
            s.sp = 0

    # ---- running
    def vdp_frame(s):
        s.frames += 1
        s.frame_flag = 1
        if s.vdp_regs[1] & 0x20:
            c = s.ctc
            if c['ctrl'] & 0x40 and not c['want_tc'] and c['tc']:
                c['cnt'] -= 1
                if c['cnt'] <= 0:
                    c['cnt'] = c['tc']
                    if c['ctrl'] & 0x80: s.irq = True

    def run(s, frames, per_frame=14000, stop=None):
        cpu = s.cpu
        for _ in range(frames):
            for _ in range(per_frame):
                c = s.ctc
                if not c['ctrl'] & 0x40 and c['tc'] and not c['want_tc']:
                    # timer mode: tc * (256 or 16) clocks, about 7 clocks per instruction
                    c['acc'] = c.get('acc', 0) + s.tstep()
                    per = c['tc'] * (256 if c['ctrl'] & 0x20 else 16)
                    if c['acc'] >= per:
                        c['acc'] -= per
                        if c['ctrl'] & 0x80: s.irq = True
                if s.irq and cpu.iff1 and not cpu.ei_delay:
                    s.irq = False
                    cpu.halted = False
                    cpu.iff1 = cpu.iff2 = 0
                    cpu.push(cpu.PC)
                    cpu.PC = cpu.rd16(((cpu.I << 8) | s.ctc['vec']) & 0xFFFF)
                if cpu.ei_delay: cpu.ei_delay -= 1
                if cpu.halted and not s.irq:
                    break
                cpu.step()
                s.instr += 1
            s.vdp_frame()
            if stop and stop(s): return True
        return False

    KEYS = {}

    def press(s, ks, frames=4):
        s.keys = set(ks)
        s.run(frames)
        s.keys = set()
        s.run(frames)

    def screen(s):
        base = (s.vdp_regs[2] & 15) << 10
        rows = []
        for r in range(24):
            line = bytes(s.vram[(base + r * 40 + c) & 0x3FFF] for c in range(40))
            rows.append(''.join(chr(b) if 32 <= b < 127 else '.' for b in line).rstrip())
        while rows and not rows[-1]: rows.pop()
        return rows


# keyboard matrix positions k(row*10+col) for the characters used on the command line
LAYOUT = {
    '1': 0, '3': 1, '5': 2, '7': 3, '9': 4, '-': 5,
    '2': 11, '4': 12, '6': 13, '8': 14, '0': 15,
    'W': 21, 'R': 22, 'Y': 23, 'I': 24, 'P': 25,
    'Q': 30, 'E': 31, 'T': 32, 'U': 33, 'O': 34,
    'S': 41, 'F': 42, 'H': 43, 'K': 44,
    'A': 50, 'D': 51, 'G': 52, 'J': 53, 'L': 54,
    'X': 61, 'V': 62, 'N': 63,
    'Z': 70, 'C': 71, 'B': 72, 'M': 73,
    ' ': 78, '\n': 56,
    '.': 74, ',': 64, '/': 65, ';': 45, ':': 55,        # from the grid in rtl/mtx_kbd.vhd
}
SHIFT = 60


def type_line(m, text, hold=3):
    for ch in text:
        if ch == '"':
            m.press([SHIFT, LAYOUT['2']], hold)
        else:
            m.press([LAYOUT[ch.upper()]], hold)
    m.press([LAYOUT['\n']], hold)
