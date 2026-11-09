"""Build rom3_roms.hex (the real OS, BASIC, ASSEM and SDX ROMs, from your own boot*.rom files) and tb_mtx_rom3.vhd (from
tb_mtx_sdx.vhd) for a whole-machine test of mtx_autorom: the real Z80 core, mtx.vhd, the real OS and BASIC ROMs boot to the
prompt, the bench pulses sdx_relog (as the menu does when a disc is mounted) and checks that the OS itself then selects ROM 3
(OUT (0) with the ROM bits 011), which it only does because ROM 3 was typed on the keyboard matrix.

    python make_rom3_test.py [folder with boot.rom boot1.rom boot2.rom boot3.rom]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..', '..', 'release_work', 'MTX512_SD', 'games', 'MTX512')
img = b''.join(open(os.path.join(D, n), 'rb').read() for n in ('boot.rom', 'boot1.rom', 'boot2.rom', 'boot3.rom'))
assert len(img) == 32768, len(img)
open(os.path.join(HERE, 'rom3_roms.hex'), 'w').write('\n'.join('%02X' % x for x in img) + '\n')
print('rom3_roms.hex written (%d bytes)' % len(img))

tb = open(os.path.join(HERE, 'tb_mtx_sdx.vhd')).read()
tb = tb.replace('tb_mtx_sdx', 'tb_mtx_rom3').replace('sdx_roms.hex', 'rom3_roms.hex')


def rep(a, b):
    global tb
    assert a in tb, a[:60]
    tb = tb.replace(a, b, 1)


rep("  signal slot5_s : std_logic := s5;", "  signal slot5_s : std_logic := s5;\n  signal relog_s : std_logic := '0';\n  signal rom3_n  : integer := 0;                 -- OUT (0) with the ROM bits 011: ROM 3 selected\n  signal rom3_t  : time := 0 ns;")
rep("sdx_en => '1', sdx_slot5 => slot5_s,", "sdx_en => '1', sdx_slot5 => slot5_s, sdx_relog => relog_s,")
# a second spy: writes to port 0
rep("  main : process", """  spy0 : process (clk_cpu_o)
    alias a_s    is << signal .tb_mtx_rom3.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_rom3.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_rom3.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_rom3.dut.WR_n   : std_logic >>;
    variable prev : std_logic := '1';
  begin
    if rising_edge(clk_cpu_o) then
      if iorq_s = '0' and wr_s = '0' and prev = '1' and a_s(7 downto 0) = x"00" and do_s(7) = '0' and do_s(6 downto 4) = "011" then
        rom3_n <= rom3_n + 1;
        rom3_t <= now;
      end if;
      prev := wr_s or iorq_s;
    end if;
  end process;

  main : process""", )
a = tb.index("    wait until cpu_halt = '0' for 2 ms;")
z = tb.index('    if errors = 0 then report "SDX MACHINE TEST PASSED"')
new = '''    -- the OS boots to the BASIC prompt; the autorom watches the CPU and sees it idle
    wait until idle_s >= 2 for 12 sec;
    report "BASIC idle at " & time'image(now) & " (idle windows seen: " & integer'image(idle_s) & ")";
    chk(idle_s >= 2, "the autorom never saw BASIC idle: the OS did not reach its prompt, or the keyboard wait loop is elsewhere");
    wait for 100 ms;
    n0 := rom3_n;                                   -- the OS probes the ROM slots at start-up, so ROM 3 has been selected before
    t0 := now;
    -- a disc is mounted: the menu would pulse sdx_relog
    wait until rising_edge(CLOCK_50);
    relog_s <= '1';
    wait until rising_edge(CLOCK_50);
    relog_s <= '0';
    wait until rom3_n > n0 for 3 sec;
    report "ROM 3 selected after the trigger: " & integer'image(rom3_n - n0) & " time(s), " & time'image(rom3_t - t0) & " after it";
    chk(rom3_n > n0, "the OS did not select ROM 3 after the keys ROM 3 RET were typed");
    chk(rom3_t - t0 > 400 ms and rom3_t - t0 < 1500 ms, "ROM 3 selected at the wrong time: " & time'image(rom3_t - t0));
    wait for 500 ms;
    n0 := rom3_n;
    wait for 1500 ms;
    chk(rom3_n = n0, "ROM 3 selected again with nothing typed");
'''
tb = tb[:a] + new + tb[z:]
tb = tb.replace("    variable pos : integer;", "    variable pos : integer;\n    variable n0 : integer;\n    variable t0 : time;\n    alias idle_s is << signal .tb_mtx_rom3.dut.U_AUTOROM.idle_wins : integer range 0 to 3 >>;")
tb = tb.replace('SDX MACHINE TEST PASSED', 'ROM 3 TYPIST MACHINE TEST PASSED').replace('SDX MACHINE TEST FAILED', 'ROM 3 TYPIST MACHINE TEST FAILED')
open(os.path.join(HERE, 'tb_mtx_rom3.vhd'), 'w').write(tb)
print('tb_mtx_rom3.vhd written')
