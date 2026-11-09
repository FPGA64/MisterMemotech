"""Build spec_roms.hex for tb_mtx_spec.vhd: a 32 KB ROM image loaded through the ROM loader path of the core.
The "OS ROM" (0x0000) is a small Z80 program that exercises the Speculator board through real I/O cycles:
  border cell (OUT FE / IN 7E), three keyboard rows (OUT (C) / IN (C) with B as the row select),
  then CTC channel 1 interrupts in IM 2 with the NMI handler at 0066 counting NMIs and the IM 2 handler at 0200
  counting interrupts: immediate NMI, delayed NMI, and NMI disabled.
Everything it learns goes out on port D0h, which the bench watches."""
import os
HERE = os.path.dirname(os.path.abspath(__file__))

code = bytearray()
rel = []
labels = {}


def b(*v): code.extend(v)
def label(n): labels[n] = len(code)
def jr(op, lab): b(op); rel.append((len(code), lab)); b(0)
def report(): b(0xD3, 0xD0)                      # OUT (D0),A
def out_n(p): b(0xD3, p)
def ld_a(n): b(0x3E, n)
def ld_a_mem(n): b(0x3A, n & 255, n >> 8)
def ld_mem_a(n): b(0x32, n & 255, n >> 8)


def main():
    b(0x31, 0x00, 0xF0)                          # LD SP,F000
    b(0xAF); ld_mem_a(0xC000); ld_mem_a(0xC001)  # counters
    # --- the border cell: Spectrum OUT (FE),A and Speculator IN A,(7E) are the same RAM cell
    ld_a(0x1D); out_n(0xFE); b(0xDB, 0x7E); report()                      # expect 1D
    # --- keyboard rows: OUT (C),A at port 7E with B as the row select, IN A,(C) at port FE with the same B
    b(0x01, 0x7E, 0xFE); ld_a(0xA1); b(0xED, 0x79)                        # B=FE (row 0) <- A1
    b(0x06, 0xFD);       ld_a(0xA2); b(0xED, 0x79)                        # B=FD (row 1) <- A2
    b(0x06, 0x7F);       ld_a(0xA8); b(0xED, 0x79)                        # B=7F (row 7) <- A8
    b(0x0E, 0xFE)                                                         # C=FE
    b(0x06, 0xFD); b(0xED, 0x78); report()                                # expect A2
    b(0x06, 0xFE); b(0xED, 0x78); report()                                # expect A1
    b(0x06, 0x7F); b(0xED, 0x78); report()                                # expect A8
    # --- interrupts: IM 2, CTC channel 1 counts the 0.3MHz input (an interrupt every 100 counts, vector table entry at C102)
    #     (channel 0 is not used: this CTC model starts its counters at 0, so the first VDP interrupt would take 256 frames)
    b(0xED, 0x5E)                                                         # IM 2
    ld_a(0xC1); b(0xED, 0x47)                                             # LD I,A
    b(0x21, 0x00, 0x02); b(0x22, 0x02, 0xC1)                              # LD HL,0200 ; LD (C102),HL
    ld_a(0x00); out_n(0x08)                                               # CTC vector base 00 (written to channel 0)
    ld_a(0xC5); out_n(0x09)                                               # ch1: interrupt, counter, TC follows
    ld_a(100);  out_n(0x09)                                               # time constant 100
    for nmi_mode in (0x03, 0x01, 0x00):                                   # immediate, delayed, disabled
        ld_a(nmi_mode); out_n(0xFF)
        b(0xAF); ld_mem_a(0xC000); ld_mem_a(0xC001)
        b(0xFB)                                                           # EI
        label('s%d' % nmi_mode)
        ld_a_mem(0xC001); b(0xFE, 0x01); jr(0x38, 's%d' % nmi_mode)       # wait for one interrupt (settles a pending one)
        b(0xF3)                                                           # DI
        b(0xAF); ld_mem_a(0xC000); ld_mem_a(0xC001)                       # count from zero
        b(0xFB)                                                           # EI
        label('w%d' % nmi_mode)
        ld_a_mem(0xC001); b(0xFE, 0x05); jr(0x38, 'w%d' % nmi_mode)       # CP 5 ; JR C,wait
        b(0xF3)                                                           # DI
        ld_a_mem(0xC000); report()                                        # NMIs seen
        ld_a_mem(0xC001); report()                                        # interrupts seen
    ld_a(0xA5); report()
    b(0x76)                                                               # HALT


main()
for pos, lab in rel:
    d = labels[lab] - (pos + 1)
    assert -128 <= d <= 127, (lab, d)
    code[pos] = d & 255

rom = bytearray(8192)
rom[0:3] = bytes([0xC3, 0x80, 0x00])                                      # JP 0080
nmi = bytes([0xF5, 0x3A, 0x00, 0xC0, 0x3C, 0x32, 0x00, 0xC0, 0xF1, 0xED, 0x45])   # PUSH AF; LD A,(C000); INC A; LD (C000),A; POP AF; RETN
rom[0x66:0x66 + len(nmi)] = nmi
isr = bytes([0xF5, 0x3A, 0x01, 0xC0, 0x3C, 0x32, 0x01, 0xC0, 0xDB, 0x02, 0xF1, 0xFB, 0xED, 0x4D])  # ... IN A,(02); POP AF; EI; RETI
rom[0x200:0x200 + len(isr)] = isr
rom[0x80:0x80 + len(code)] = code
assert 0x80 + len(code) < 0x200, len(code)
img = bytes(rom) + bytes(8192) * 3
open(os.path.join(HERE, 'spec_roms.hex'), 'w').write('\n'.join('%02X' % x for x in img) + '\n')
print('program %d bytes at 0080, image %d bytes written to spec_roms.hex' % (len(code), len(img)))
