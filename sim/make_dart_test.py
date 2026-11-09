"""Build dart_roms.hex and tb_mtx_dart.vhd (from tb_mtx_sdx.vhd) for a whole-machine test of the Communications board: the real Z80
core, mtx.vhd, the CTC giving the baud rate clock and the DART. The bench loops each channel's transmit line back to its receive
line; the program sets up the CTC (channels 1 and 2 in counter mode with a time constant of 1: a clock pulse for every 4MHz/13
pulse) and the DART (x16 clock, 8 bits, 1 stop bit, no parity, the same setup as the MTX OS uses), sends five bytes on each
channel, reads them back and reports them on port E0h. The bench checks the bytes and that the bit time on the transmit line is
that of 4MHz/13/16 = 19230.8 baud (52.0 us).

    python make_dart_test.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
code = bytearray()
rel = []
labels = {}


def b(*v): code.extend(v)
def label(n): labels[n] = len(code)
def jr(op, lab): b(op); rel.append((len(code), lab)); b(0)
def ld_a(n): b(0x3E, n)
def out_n(p): b(0xD3, p)
def in_n(p): b(0xDB, p)
def report(): out_n(0xE0)


BYTES = [0x55, 0xA3, 0x00, 0xFF, 0x7E]
b(0x31, 0x00, 0xF0)                                           # LD SP,F000
# the baud rate clocks: CTC channels 1 and 2, counter mode, time constant 1
for port in (0x09, 0x0A):
    ld_a(0x45); out_n(port)                                   # no interrupt, counter mode, time constant follows
    ld_a(0x01); out_n(port)
for name, ctl, dat in (('A', 0x0E, 0x0C), ('B', 0x0F, 0x0D)):
    ld_a(0x18); out_n(ctl)                                    # WR0: channel reset
    ld_a(0x04); out_n(ctl); ld_a(0x44); out_n(ctl)            # WR4: x16 clock, 1 stop bit, no parity
    ld_a(0x03); out_n(ctl); ld_a(0xC1); out_n(ctl)            # WR3: receiver enable, 8 bits
    ld_a(0x05); out_n(ctl); ld_a(0x68); out_n(ctl)            # WR5: transmitter enable, 8 bits
    for k, v in enumerate(BYTES):
        ld_a(v); out_n(dat)                                   # send the byte
        label('w%s%d' % (name, k))
        in_n(ctl); b(0xE6, 0x01); jr(0x28, 'w%s%d' % (name, k))      # wait for RR0 bit 0: a character has arrived
        in_n(dat); report()
ld_a(0xA5); report()
b(0x76)                                                       # HALT

for pos, lab in rel:
    d = labels[lab] - (pos + 1)
    assert -128 <= d <= 127, (lab, d)
    code[pos] = d & 255
rom = bytearray(8192)
rom[:len(code)] = code
img = bytes(rom) + bytes(8192) * 3
open(os.path.join(HERE, 'dart_roms.hex'), 'w').write('\n'.join('%02X' % x for x in img) + '\n')
print('program %d bytes; dart_roms.hex written' % len(code))

tb = open(os.path.join(HERE, 'tb_mtx_sdx.vhd')).read()
tb = tb.replace('tb_mtx_sdx', 'tb_mtx_dart').replace('sdx_roms.hex', 'dart_roms.hex')


def rep(a, c):
    global tb
    assert a in tb, a[:70]
    tb = tb.replace(a, c, 1)


rep("  signal slot5_s : std_logic := s5;", """  signal slot5_s : std_logic := s5;
  signal tx_a, tx_b : std_logic;                 -- each channel's transmit line is looped back to its receive line
  type tm_t is array (0 to 15) of time;
  signal edges_a : tm_t := (others => 0 ns);
  signal n_edges : integer := 0;""")
rep("sdx_en => '1', sdx_slot5 => slot5_s,", "sdx_en => '1', sdx_slot5 => slot5_s, dart_rx_a => tx_a, dart_rx_b => tx_b, dart_tx_a => tx_a, dart_tx_b => tx_b,")
rep("  main : process", """  -- the first edges of the first character on channel A: the bit times
  edge_a : process (tx_a)
  begin
    if n_edges < 16 and now > 0 ns and (tx_a = '0' or tx_a = '1') and (tx_a'last_value = '0' or tx_a'last_value = '1') then   -- real edges only: not the U to 1 step at reset
      edges_a(n_edges) <= now;
      n_edges <= n_edges + 1;
    end if;
  end process;

  main : process""")
a = tb.index("    pos := 0;\n    if SLOT5 = 0 then")
z = tb.index('    if errors = 0 then report "SDX MACHINE TEST PASSED"')
checks = '''    chk(nrep = 11, "number of reports: " & integer'image(nrep));
''' + ''.join('''    chk(rep(%d) = x"%02X", "channel A: byte %d echoed");
''' % (k, v, k) for k, v in enumerate(BYTES)) + ''.join('''    chk(rep(%d) = x"%02X", "channel B: byte %d echoed");
''' % (5 + k, v, k) for k, v in enumerate(BYTES)) + '''    chk(rep(10) = x"A5", "end marker");
    -- the bit time on channel A's transmit line: the first byte is 55h, so after the start bit every bit is the opposite of the last
    -- and every edge is one bit time after the one before: the edges after the first.
    for k in 2 to 8 loop
      chk(edges_a(k) - edges_a(k - 1) > 51500 ns and edges_a(k) - edges_a(k - 1) < 52500 ns,
          "bit time on channel A: " & time'image(edges_a(k) - edges_a(k - 1)) & ", want 52.0 us (4MHz/13/16 = 19230.8 baud)");
    end loop;
    report "bit time on channel A: " & time'image(edges_a(5) - edges_a(4)) & " (edges seen: " & integer'image(n_edges) & ")";
'''
tb = tb[:a] + checks + tb[z:]
tb = tb.replace('SDX MACHINE TEST PASSED', 'DART TEST PASSED').replace('SDX MACHINE TEST FAILED', 'DART TEST FAILED')
open(os.path.join(HERE, 'tb_mtx_dart.vhd'), 'w').write(tb)
print('tb_mtx_dart.vhd written')
