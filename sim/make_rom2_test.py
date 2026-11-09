"""Build rom2_roms.hex (the real OS, BASIC, ASSEM and a set of ROM 2 chips) and tb_mtx_rom2.vhd (from tb_mtx_sdx.vhd) for a
whole-machine test of ROM 2: the real Z80 core, mtx.vhd and the real OS and BASIC ROMs boot to the prompt, the bench types
ROM 2 and RET on the keyboard (the PS/2 input of mtx_kbd), and writes every byte the program then sends to the VDP data port
(port 1) to rom2_text.txt as ASCII, so the screen text of the ROM can be read.

    python make_rom2_test.py SET [folder with boot.rom boot1.rom boot2.rom]

SET is pascal11, pascal14 or newword. The ROM chips are read from the zips in refs/primrosebank_roms/dl.
"""
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
SET = sys.argv[1] if len(sys.argv) > 1 else 'pascal11'
D = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, 'release_work', 'MTX512_SD', 'games', 'MTX512')
DL = os.path.join(ROOT, 'refs', 'primrosebank_roms', 'dl')

SETS = {
    'pascal11': ('1984_Hisoft_Pascal.zip', ['pascal0.rom', 'pascal1.rom']),
    'pascal14': ('HisoftPascal14.zip', ['rom0_pascal_1.4.BIN', 'rom1_pascal_1.4.BIN']),
    'newword': ('NewWord.zip', ['NEWWORD0.ROM', 'NEWWORD1.ROM', 'NEWWORD2.ROM', 'NEWWORD3.ROM']),
}
zname, members = SETS[SET]
zf = zipfile.ZipFile(os.path.join(DL, zname))
chips = [zf.read(m) for m in members]
assert all(len(c) == 8192 for c in chips)

img = b''.join(open(os.path.join(D, n), 'rb').read() for n in ('boot.rom', 'boot1.rom', 'boot2.rom'))
assert len(img) == 24576, len(img)
img += b'\xff' * 8192                                  # no SDX ROM
for c in chips: img += c
img += b'\xff' * (65536 - len(img))
open(os.path.join(HERE, 'rom2_roms.hex'), 'w').write('\n'.join('%02X' % x for x in img) + '\n')
ok = format((1 << len(chips)) - 1, '04b')
print('rom2_roms.hex written (%d bytes), set %s, rom2_ok %s' % (len(img), SET, ok))

XRAM = os.environ.get('XRAM') == '1'        # base the bench on the one with the SDRAM next to the machine (run it with -GRAM_EXP=1)
if XRAM:
    tb = open(os.path.join(HERE, 'tb_mtx_xram.vhd')).read()
    tb = tb.replace('tb_mtx_xram', 'tb_mtx_rom2').replace('xram_roms.hex', 'rom2_roms.hex')
else:
    tb = open(os.path.join(HERE, 'tb_mtx_sdx.vhd')).read()
    tb = tb.replace('tb_mtx_sdx', 'tb_mtx_rom2').replace('sdx_roms.hex', 'rom2_roms.hex')


def rep(a, b):
    global tb
    assert a in tb, a[:60]
    tb = tb.replace(a, b, 1)


rep("key_ready => '0', key_stroke => '0', key_code => (others => '0'),", "key_ready => kr, key_stroke => ks, key_code => kc,")
if XRAM:
    import re
    tb, n = re.subn(r'rom2_ok => "[01]{4}"', 'rom2_ok => "%s"' % ok, tb)
    assert n == 1
else:
    rep("sdx_en => '1', sdx_slot5 => slot5_s,", "sdx_en => '0', sdx_slot5 => slot5_s, rom2_ok => \"%s\"," % ok)
rep("  signal slot5_s : std_logic := s5;", """  signal slot5_s : std_logic := s5;
  signal kr, ks : std_logic := '0';
  signal kc : std_logic_vector(9 downto 0) := (others => '0');
  signal rom2_n : integer := 0;                  -- OUT (0) with the ROM bits 010: ROM 2 selected
  signal rom2_t : time := 0 ns;
  type txt_t is array (0 to 16383) of character;
  signal txt : txt_t := (others => ' ');
  signal ntxt : integer := 0;
  signal logging : std_logic := '0';""")
rep("  main : process", """  spy0 : process (clk_cpu_o)
    alias a_s    is << signal .tb_mtx_rom2.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_rom2.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_rom2.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_rom2.dut.WR_n   : std_logic >>;
    variable prev : std_logic := '1';
    variable v : integer;
  begin
    if rising_edge(clk_cpu_o) then
      if iorq_s = '0' and wr_s = '0' and prev = '1' then
        if a_s(7 downto 0) = x"00" and do_s(7) = '0' and do_s(6 downto 4) = "010" then
          rom2_n <= rom2_n + 1;
          rom2_t <= now;
        end if;
        if a_s(7 downto 0) = x"01" and logging = '1' then
          v := to_integer(unsigned(do_s));
          if ntxt < 16384 then
            if v >= 32 and v < 127 then txt(ntxt) <= character'val(v); else txt(ntxt) <= '.'; end if;
          end if;
          ntxt <= ntxt + 1;
        end if;
      end if;
      prev := wr_s or iorq_s;
    end if;
  end process;

  main : process""")
a = tb.index("    pos := 0;\n    if SLOT5 = 0 then") if "    pos := 0;\n    if SLOT5 = 0 then" in tb else tb.index("    wait until cpu_halt = '0' for 2 ms;")
z = tb.index('    if errors = 0 then report "MEMORY MAP TEST PASSED"' if XRAM else '    if errors = 0 then report "SDX MACHINE TEST PASSED"')
new = '''    wait until idle_s >= 2 for 12 sec;
    report "BASIC idle at " & time'image(now);
    chk(idle_s >= 2, "the OS did not reach the BASIC prompt");
    wait for 100 ms;
    n0 := rom2_n;
    logging <= '1';
    -- type  ROM 2  RET  on the keyboard: PS/2 set 2 scan codes R 2D, O 44, M 3A, space 29, 2 1E, Enter 5A
    for c in 0 to 5 loop
      case c is
        when 0 => kc <= "00" & x"2d";
        when 1 => kc <= "00" & x"44";
        when 2 => kc <= "00" & x"3a";
        when 3 => kc <= "00" & x"29";
        when 4 => kc <= "00" & x"1e";
        when others => kc <= "00" & x"5a";
      end case;
      ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0';       -- key_stroke is 0 for a press (mtx_kbd keeps 0 = pressed)
      wait for 70 ms;
      ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0';
      wait for 50 ms;
    end loop;
    wait until rom2_n > n0 for 2 sec;
    chk(rom2_n > n0, "the OS did not select ROM 2 after ROM 2 RET was typed");
    report "ROM 2 selected " & integer'image(rom2_n - n0) & " time(s)";
    wait for RUN_MS * 1 ms;
    report "VDP data bytes after typing: " & integer'image(ntxt);
    file_open(fo, "rom2_text.txt", write_mode);
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
h = tb.index("    -- the program ends with HALT after reporting A5h")
assert h < a or True
a = min(a, h) if h < a else a
tb = tb[:min(a, h)] + new + tb[z:]
rep("    variable errors : integer := 0;", "    variable errors : integer := 0;\n    file fo : text;\n    variable n0 : integer;")
rep("  main : process\n    file f", "  main : process\n    file f") if False else None
tb = tb.replace('SDX MACHINE TEST PASSED', 'ROM 2 BENCH FINISHED').replace('SDX MACHINE TEST FAILED', 'ROM 2 BENCH FAILED').replace('MEMORY MAP TEST PASSED', 'ROM 2 BENCH FINISHED').replace('MEMORY MAP TEST FAILED', 'ROM 2 BENCH FAILED')
tb = tb.replace("alias idle_s is << signal .tb_mtx_sdx.dut", "alias idle_s is << signal .tb_mtx_rom2.dut")
if 'idle_s is' not in tb:
    rep("    variable errors : integer := 0;", "    variable errors : integer := 0;\n    alias idle_s is << signal .tb_mtx_rom2.dut.U_AUTOROM.idle_wins : integer range 0 to 3 >>;")
if 'RUN_MS' in tb and 'constant RUN_MS' not in tb:
    rep("  signal kr, ks : std_logic := '0';", "  constant RUN_MS : integer := %d;\n  signal kr, ks : std_logic := '0';" % int(os.environ.get('RUN_MS', '1500')))
open(os.path.join(HERE, 'tb_mtx_rom2.vhd'), 'w').write(tb)
print('tb_mtx_rom2.vhd written')
