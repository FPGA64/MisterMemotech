"""Build sdxfmt_roms.hex (and tb_mtx_sdxfmt.vhd from tb_mtx_sdx.vhd) for a whole-machine test of FORMAT in the real controller
code (rtl/sdx_fdc.sv): the real Z80 core and mtx.vhd, a test program as the OS ROM, and the formatter's own byte stream
(fmt_stream.bin, captured from the real SDX ROM's USER FORMAT by capture_fmt_stream.py).

The program formats track 5, side 0 and then side 1 with that stream (the track and side in the ID fields patched in RAM),
reads the address marks back with READ ADDRESS, and reads a formatted sector. It reports on port E0h; the bench checks the
reports and the disc image on the "card": every sector of track 5, both sides, must be E5, the neighbouring tracks untouched.

    python make_sdx_fmt_test.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
stream = open(os.path.join(HERE, 'fmt_stream.bin'), 'rb').read()
if stream[-1] != 0xF7:
    stream = stream[:stream.rindex(0xF7) + 1]          # the capture can end with the next command's data register write
N = len(stream)
ids = [i + 1 for i in range(N - 5) if stream[i] == 0xFE and stream[i + 5] == 0xF7]      # offset of the C byte of every ID field
assert len(ids) == 16, len(ids)

code = bytearray()
fix = []
rel = []
labels = {}


def b(*v): code.extend(v)
def label(n): labels[n] = len(code)
def call(lab): b(0xCD); fix.append((len(code), lab)); b(0, 0)
def jr(op, lab): b(op); rel.append((len(code), lab)); b(0)
def ld_hl_label(lab): b(0x21); fix.append((len(code), lab)); b(0, 0)
def ld_a(n): b(0x3E, n)
def out_n(p): b(0xD3, p)
def in_n(p): b(0xDB, p)
def report(): out_n(0xE0)


STREAM_AT = 0x0400
IDOFF_AT = STREAM_AT + N + 2          # 16 words

CMD, TRK, SEC, DAT, CTL = 0x10, 0x11, 0x12, 0x13, 0x14

b(0x31, 0x00, 0xF0)                                   # LD SP,F000
ld_a(0x1C); out_n(CTL)                                # drive 0, motor on and ready, double density, side 0
ld_a(0x08); out_n(CMD); call('wait_idle')             # restore
ld_a(5); out_n(DAT); ld_a(0x18); out_n(CMD); call('wait_idle')      # seek to track 5


def format_side(side):
    b(0x21, STREAM_AT & 255, STREAM_AT >> 8)          # LD HL,stream
    b(0x11, 0x00, 0xC0)                               # LD DE,C000
    b(0x01, N & 255, N >> 8)                          # LD BC,N
    b(0xED, 0xB0)                                     # LDIR: the stream goes to RAM, where its ID fields are patched
    b(0x0E, side)                                     # LD C,side
    call('patch')
    ld_a(0xF4); out_n(CMD)                            # WRITE TRACK
    b(0x21, 0x00, 0xC0)                               # LD HL,C000
    b(0x11, N & 255, N >> 8)                          # LD DE,N
    call('stream')
    call('wait_idle')
    in_n(CMD); report()                               # status after the format: 00


def read_address():
    ld_a(0xC0); out_n(CMD)
    b(0x06, 6)                                        # LD B,6
    label('ra%d' % len(labels))
    me = len(code)
    in_n(CTL); b(0xE6, 0x80); jr(0x28, 'ra%d' % (len(labels) - 1))
    in_n(DAT); report()
    b(0x10); rel.append((len(code), 'ra%d' % (len(labels) - 1))); b(0)      # DJNZ
    call('wait_idle')
    in_n(CMD); report()


format_side(0)
read_address()
ld_a(0x1E); out_n(CTL)                                # side 1
format_side(1)
read_address()
# a formatted sector, read back through the normal path: track 5, side 1, sector 3
ld_a(3); out_n(SEC); ld_a(0x80); out_n(CMD)
b(0x06, 0x00)                                         # LD B,0 (256 bytes)
label('rs')
in_n(CTL); b(0xE6, 0x80); jr(0x28, 'rs')
in_n(DAT); report()
b(0x10); rel.append((len(code), 'rs')); b(0)
call('wait_idle')
in_n(CMD); report()
ld_a(0xA5); report()
b(0x76)                                               # HALT

label('wait_idle')                                    # until the busy bit of the status is clear
in_n(CMD); b(0xE6, 0x01); jr(0x20, 'wait_idle')
b(0xC9)

label('stream')                                       # HL = bytes, DE = count: one byte per DRQ, stop when the command is done
label('s1')
in_n(CTL); b(0xE6, 0x80); jr(0x20, 'send')
in_n(CMD); b(0xE6, 0x01); jr(0x28, 'sdone')
jr(0x18, 's1')
label('send')
b(0x7E); out_n(DAT)                                   # LD A,(HL); OUT (13),A
b(0x23); b(0x1B)                                      # INC HL; DEC DE
b(0x7A); b(0xB3); jr(0x20, 's1')                      # LD A,D; OR E; JR NZ
label('sdone')
b(0xC9)

label('patch')                                        # C = the side: set the track (5) and side in all 16 ID fields
b(0x06, 16)
ld_hl_label('idoff')
label('pl')
b(0x5E, 0x23, 0x56, 0x23)                             # LD E,(HL); INC HL; LD D,(HL); INC HL
b(0xE5)                                               # PUSH HL
b(0x21, 0x00, 0xC0); b(0x19)                          # LD HL,C000; ADD HL,DE
b(0x36, 5); b(0x23); b(0x71)                          # LD (HL),5 ; INC HL ; LD (HL),C
b(0xE1)                                               # POP HL
b(0x10); rel.append((len(code), 'pl')); b(0)
b(0xC9)
labels['idoff'] = IDOFF_AT

for pos, lab in fix:
    code[pos] = labels[lab] & 255
    code[pos + 1] = labels[lab] >> 8
for pos, lab in rel:
    d = labels[lab] - (pos + 1)
    assert -128 <= d <= 127, (lab, d)
    code[pos] = d & 255

assert len(code) < STREAM_AT, len(code)
rom = bytearray(8192)
rom[:len(code)] = code
rom[STREAM_AT:STREAM_AT + N] = stream
for k, off in enumerate(ids):
    rom[IDOFF_AT + 2 * k] = off & 255
    rom[IDOFF_AT + 2 * k + 1] = off >> 8
assert IDOFF_AT + 32 < 8192
img = bytes(rom) + bytes(8192) * 3
open(os.path.join(HERE, 'sdxfmt_roms.hex'), 'w').write('\n'.join('%02X' % x for x in img) + '\n')
print('program %d bytes, stream %d bytes at %04X, id table at %04X; sdxfmt_roms.hex written' % (len(code), N, STREAM_AT, IDOFF_AT))

# ---- the bench: tb_mtx_sdx.vhd with the checks of this program
tb = open(os.path.join(HERE, 'tb_mtx_sdx.vhd')).read()
tb = tb.replace('tb_mtx_sdx', 'tb_mtx_sdxfmt').replace('sdx_roms.hex', 'sdxfmt_roms.hex')
tb = tb.replace('wait until cpu_halt = \'1\' for 200 ms;', 'wait until cpu_halt = \'1\' for 900 ms;')
a = tb.index('    pos := 0;\n    if SLOT5 = 0 then')
z = tb.index('    if errors = 0 then report "SDX MACHINE TEST PASSED"')
checks = '''    chk(nrep = 274, "number of reports: " & integer'image(nrep));
    chk(rep(0) = x"00", "status after formatting side 0");
    chk(rep(1) = x"05" and rep(2) = x"00" and rep(4) = x"01", "READ ADDRESS side 0: track 5, side 0, length 1");
    chk(unsigned(rep(3)) >= 1 and unsigned(rep(3)) <= 16, "READ ADDRESS side 0: sector number");
    chk(rep(7) = x"00", "status after READ ADDRESS side 0");
    chk(rep(8) = x"00", "status after formatting side 1");
    chk(rep(9) = x"05" and rep(10) = x"01" and rep(12) = x"01", "READ ADDRESS side 1: track 5, side 1, length 1");
    chk(rep(15) = x"00", "status after READ ADDRESS side 1");
    for n in 0 to 255 loop
      chk(rep(16 + n) = x"E5", "formatted sector 3 of track 5 side 1, byte " & integer'image(n));
    end loop;
    chk(rep(272) = x"00", "status after reading the formatted sector");
    chk(rep(273) = x"A5", "end marker");
    -- the image on the card: every sector of track 5, both sides, is E5; the neighbours are untouched
    for sd in 0 to 1 loop
      for s in 1 to 16 loop
        for n in 0 to 255 loop
          chk(img0(secoff(5, sd, s) + n) = x"E5", "image: track 5 side " & integer'image(sd) & " sector " & integer'image(s) & " byte " & integer'image(n));
        end loop;
      end loop;
    end loop;
    for sd in 0 to 1 loop
      for n in 0 to 255 loop
        chk(img0(secoff(4, sd, 16) + n) = std_logic_vector(to_unsigned(img_at(secoff(4, sd, 16) + n), 8)), "image: track 4 side " & integer'image(sd) & " sector 16 changed, byte " & integer'image(n));
        chk(img0(secoff(6, sd, 1) + n) = std_logic_vector(to_unsigned(img_at(secoff(6, sd, 1) + n), 8)), "image: track 6 side " & integer'image(sd) & " sector 1 changed, byte " & integer'image(n));
      end loop;
    end loop;
'''
tb = tb[:a] + checks + tb[z:]
tb = tb.replace('SDX MACHINE TEST PASSED', 'SDX FORMAT TEST PASSED').replace('SDX MACHINE TEST FAILED', 'SDX FORMAT TEST FAILED')
# T40 = 1: a 320K disc of 40 tracks (SDX type 03) instead of the 640K disc of 80 tracks (type 07)
assert 'generic (SLOT5 : integer := 0);' in tb
tb = tb.replace('generic (SLOT5 : integer := 0);', 'generic (SLOT5 : integer := 0; T40 : integer := 0);')
tb = tb.replace("  signal slot5_s : std_logic := s5;", """  signal slot5_s : std_logic := s5;
  function t40v return std_logic_vector is begin if T40 = 1 then return "01"; else return "00"; end if; end function;
  function blks return integer is begin if T40 = 1 then return 640; else return 1280; end if; end function;""")
assert 'd_t40 => "00"' in tb
tb = tb.replace('d_t40 => "00"', 'd_t40 => t40v').replace('d_blks0 => std_logic_vector(to_unsigned(1280, 23)), d_blks1 => std_logic_vector(to_unsigned(1280, 23))', 'd_blks0 => std_logic_vector(to_unsigned(blks, 23)), d_blks1 => std_logic_vector(to_unsigned(blks, 23))')
assert 'to_unsigned(blks, 23)' in tb
open(os.path.join(HERE, 'tb_mtx_sdxfmt.vhd'), 'w').write(tb)
print('tb_mtx_sdxfmt.vhd written')
