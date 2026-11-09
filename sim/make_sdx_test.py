"""Build sdx_roms.hex for tb_mtx_sdx.vhd: a 32 KB image that is loaded through the ROM loader path of the core:
    0x0000  the "OS ROM": a small Z80 test program (it runs from reset)
    0x2000  BASIC page (zeros)         0x4000  ASSEM page (zeros)
    0x6000  the SDX ROM page: a pattern, byte i = (3 * i + 1) mod 256
The program pages in ROM 3 and ROM 5, checks them, then drives the SDX controller through ports 10h..14h the way the
SDX driver does, and reports everything it reads to port E0h (an unused port that the testbench watches)."""
import os
HERE = os.path.dirname(os.path.abspath(__file__))

code = bytearray()
fix = []          # (position, label) for 16 bit absolute addresses
rel = []          # (position, label) for relative jumps
labels = {}


def b(*v): code.extend(v)
def label(n): labels[n] = len(code)
def ld_sp(n): b(0x31, n & 255, n >> 8)
def ld_a(n): b(0x3E, n)
def out_n(p): b(0xD3, p)
def in_n(p): b(0xDB, p)
def ld_mem_a(n): b(0x32, n & 255, n >> 8)
def ld_a_mem(n): b(0x3A, n & 255, n >> 8)
def and_n(n): b(0xE6, n)
def xor_n(n): b(0xEE, n)
def ld_hl(n): b(0x21, n & 255, n >> 8)
def ld_b(n): b(0x06, n)
def ld_hl_a(): b(0x77)
def ld_a_hl(): b(0x7E)
def inc_hl(): b(0x23)
def ld_a_b(): b(0x78)
def halt(): b(0x76)
def jr(op, lab): b(op); rel.append((len(code), lab)); b(0)
def djnz(lab): jr(0x10, lab)
def jr_z(lab): jr(0x28, lab)
def jr_nz(lab): jr(0x20, lab)
def report(): out_n(0xE0)                       # OUT (E0),A

OUT0, FDC_CMD, FDC_TRK, FDC_SEC, FDC_DAT, FDC_CTL = 0x00, 0x10, 0x11, 0x12, 0x13, 0x14

ld_sp(0xF000)
# ---- paging: ROM 3 is the SDX ROM (slot 3), ROM 5 is nothing
ld_a(0x30); out_n(OUT0)                         # RELCPMH 0, ROM 3, RAM page 0
ld_a_mem(0x2000); report()                      # first byte of the SDX ROM
ld_a_mem(0x2001); report()
ld_a_mem(0x3FFF); report()                      # last byte
ld_a(0x50); out_n(OUT0)                         # ROM 5
ld_a_mem(0x2000); report()                      # open bus: FF
ld_a(0x00); out_n(OUT0)                         # back to ROM 0
# ---- the controller: drive A, motor on and ready, double density
ld_a(0x1C); out_n(FDC_CTL)
in_n(FDC_CTL); report()                         # READY and the jumper: 30
ld_a(0x08); out_n(FDC_CMD)                      # restore, head load
in_n(FDC_CMD); report()                         # 24
ld_a(3); out_n(FDC_DAT)
ld_a(0x18); out_n(FDC_CMD)                      # seek to track 3
in_n(FDC_CMD); report()                         # 20
# read track 3 side 0 sector 5: 256 bytes, DRQ polled before each byte as the ROM does
ld_a(5); out_n(FDC_SEC)
ld_a(0x80); out_n(FDC_CMD)
ld_b(0)
label('r1'); in_n(FDC_CTL); and_n(0x80); jr_z('r1'); in_n(FDC_DAT); report(); djnz('r1')
in_n(FDC_CMD); report()                         # 00 after the sector
# write sector 6 with i xor 55h
ld_a(6); out_n(FDC_SEC)
ld_a(0xA0); out_n(FDC_CMD)
ld_b(0)
label('w1'); in_n(FDC_CTL); and_n(0x80); jr_z('w1'); ld_a_b(); xor_n(0x55); out_n(FDC_DAT); djnz('w1')
label('w2'); in_n(FDC_CMD); and_n(0x01); jr_nz('w2')      # busy until the block is written back
in_n(FDC_CMD); report()                         # 00
# read sector 6 back
ld_a(6); out_n(FDC_SEC)
ld_a(0x80); out_n(FDC_CMD)
ld_b(0)
label('r2'); in_n(FDC_CTL); and_n(0x80); jr_z('r2'); in_n(FDC_DAT); report(); djnz('r2')
# and its neighbour in the same block, sector 5, must be untouched
ld_a(5); out_n(FDC_SEC)
ld_a(0x80); out_n(FDC_CMD)
ld_b(0)
label('r3'); in_n(FDC_CTL); and_n(0x80); jr_z('r3'); in_n(FDC_DAT); report(); djnz('r3')
ld_a(0xA5); report()                            # the end marker
halt()

for pos, lab in rel:
    d = labels[lab] - (pos + 1)
    assert -128 <= d <= 127, (lab, d)
    code[pos] = d & 255

os_rom = bytearray(8192)
os_rom[:len(code)] = code
img = bytearray(os_rom) + bytearray(8192) + bytearray(8192) + bytearray((3 * i + 1) & 255 for i in range(8192))
open(os.path.join(HERE, 'sdx_roms.hex'), 'w').write('\n'.join('%02X' % x for x in img) + '\n')
print('program: %d bytes; image %d bytes written to sdx_roms.hex' % (len(code), len(img)))
