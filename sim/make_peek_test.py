"""Build tb_mtx_peek.vhd: the real OS and BASIC boot in the whole core with the expansion RAM in the (modelled) SDRAM, then the
bench types   PRINT PEEK (64122)   RET  and writes the screen text to peek_text_<ram>.txt.

The Memotech "Memory Extensions: Fitting & Testing" booklet says to test an extension with PRINT PEEK (64122) after a reset:
an MTX512 shows 2 with 32K, 3 with 64K and 5 with 128K added (an MTX500 shows 1, 2, 4), so one unit per 32K of extension and
a plain MTX512 shows 1. The 256KB of the core's 320K setting should therefore show 1 + 256/32 = 9.

    python make_peek_test.py RAM_EXP [folder with boot.rom boot1.rom boot2.rom]       (RAM_EXP is 0 or 1)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
EXP = sys.argv[1] if len(sys.argv) > 1 else '1'
D = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'release_work', 'MTX512_SD', 'games', 'MTX512')

img = b''.join(open(os.path.join(D, n), 'rb').read() for n in ('boot.rom', 'boot1.rom', 'boot2.rom'))
assert len(img) == 24576
img += b'\xff' * (32768 - len(img))
open(os.path.join(HERE, 'peek_roms.hex'), 'w').write('\n'.join('%02X' % x for x in img) + '\n')

# the xram test generator already knows how to put the SDRAM next to the machine: take its bench as the base
base = open(os.path.join(HERE, 'tb_mtx_xram.vhd')).read()
tb = base.replace('tb_mtx_xram', 'tb_mtx_peek').replace('xram_roms.hex', 'peek_roms.hex')


def rep(a, b):
    global tb
    assert a in tb, a[:70]
    tb = tb.replace(a, b, 1)


# the base bench has a fixed RAM_EXP generic and its own checks; keep the machine and the SDRAM, replace main
rep("key_ready => '0', key_stroke => '0', key_code => (others => '0'),", "key_ready => kr, key_stroke => ks, key_code => kc,")
rep("  signal slot5_s : std_logic := s5;", """  signal slot5_s : std_logic := s5;
  signal kr, ks : std_logic := '0';
  signal kc : std_logic_vector(9 downto 0) := (others => '0');
  type txt_t is array (0 to 16383) of character;
  signal txt : txt_t := (others => ' ');
  signal ntxt : integer := 0;
  signal logging : std_logic := '0';""")
rep("  main : process", """  spy1 : process (clk_cpu_o)
    alias a_s    is << signal .tb_mtx_peek.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_peek.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_peek.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_peek.dut.WR_n   : std_logic >>;
    variable prev : std_logic := '1';
    variable v : integer;
  begin
    if rising_edge(clk_cpu_o) then
      if iorq_s = '0' and wr_s = '0' and prev = '1' and a_s(7 downto 0) = x"01" and logging = '1' then
        v := to_integer(unsigned(do_s));
        if ntxt < 16384 then
          if v >= 32 and v < 127 then txt(ntxt) <= character'val(v); else txt(ntxt) <= '.'; end if;
        end if;
        ntxt <= ntxt + 1;
      end if;
      prev := wr_s or iorq_s;
    end if;
  end process;

  main : process""")
a = tb.index("    pos := 0;\n    if SLOT5 = 0 then") if "    pos := 0;\n    if SLOT5 = 0 then" in tb else tb.index("    wait until cpu_halt = '0' for 2 ms;")
h = tb.index("    -- the program ends with HALT") if "    -- the program ends with HALT" in tb else a
z = tb.index('    if errors = 0 then report "MEMORY MAP TEST PASSED"')
codes = [('4d', 0), ('2d', 0), ('43', 0), ('31', 0), ('2c', 0), ('29', 0), ('4d', 0), ('24', 0), ('24', 0), ('42', 0), ('29', 0),
         ('46', 1), ('36', 0), ('25', 0), ('16', 0), ('1e', 0), ('1e', 0), ('45', 1), ('5a', 0)]       # PRINT PEEK (64122) RET
lines = []
for code, sh in codes:
    if sh: lines.append("    ks <= '0'; kr <= '1'; kc <= \"00\" & x\"12\"; wait for 5 us; kr <= '0'; wait for 30 ms;")
    lines.append("    kc <= \"00\" & x\"%s\"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 70 ms;" % code)
    lines.append("    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 50 ms;")
    if sh: lines.append("    kc <= \"00\" & x\"12\"; ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 40 ms;")
new = '''    wait until idle_s >= 2 for 12 sec;
    report "BASIC idle at " & time'image(now);
    chk(idle_s >= 2, "the OS did not reach the BASIC prompt");
    wait for 100 ms;
    logging <= '1';
''' + '\n'.join(lines) + '''
    wait for 800 ms;
    file_open(fo, "peek_text.txt", write_mode);
    k := 0;
    while k < ntxt and k < 16384 loop
      l := null;
      for j in 0 to 79 loop
        if k < ntxt and k < 16384 then write(l, txt(k)); k := k + 1; end if;
      end loop;
      writeline(fo, l);
    end loop;
    file_close(fo);
'''
tb = tb[:min(a, h)] + new + tb[z:]
rep("    variable errors : integer := 0;", "    variable errors : integer := 0;\n    file fo : text;\n    alias idle_s is << signal .tb_mtx_peek.dut.U_AUTOROM.idle_wins : integer range 0 to 3 >>;")
tb = tb.replace('MEMORY MAP TEST PASSED', 'PEEK BENCH FINISHED').replace('MEMORY MAP TEST FAILED', 'PEEK BENCH FAILED')
open(os.path.join(HERE, 'tb_mtx_peek.vhd'), 'w').write(tb)
print('tb_mtx_peek.vhd written, RAM_EXP generic to be set to', EXP)
