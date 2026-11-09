"""Build tb_mtx_osdrom.vhd: the OSD route to ROM 2 in the whole core, as it happens on the MiSTer.

The OS, BASIC and ASSEM ROMs are sent through rtl/mtx_romload.sv as boot.rom (ioctl index 0), the machine boots to BASIC, then
OSD -> Load ROM 2 is done with a 16KB file of the two Pascal chips (ioctl index 2), the machine restarts (reset while the file
is loading, as in MTX512.sv: reset_core includes rom_loading) and ROM 2 is typed on the keyboard. The screen text goes to
rom2_text.txt like make_rom2_test.py does.

    python make_osdrom_test.py [pascal11|pascal14|newword] [index byte of the file, hex, default 02: 42 for a .bin file]
    FAST=1 SDX=1 LOADER=1 TB=tb_mtx_osdrom.vhd python build_sim.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SET = sys.argv[1] if len(sys.argv) > 1 else 'pascal14'
IDX = sys.argv[2] if len(sys.argv) > 2 else '02'

# make_rom2_test.py writes rom2_roms.hex (OS, BASIC, ASSEM, filler for the SDX ROM, the chips) and a bench to start from
subprocess.run([sys.executable, os.path.join(HERE, 'make_rom2_test.py'), SET], check=True, stdout=subprocess.DEVNULL)
lines = open(os.path.join(HERE, 'rom2_roms.hex')).read().split()
assert len(lines) == 65536
nchips = 4 if SET == 'newword' else 2
open(os.path.join(HERE, 'osd_boot.hex'), 'w').write('\n'.join(lines[:24576]) + '\n')
f2 = lines[32768:32768 + 8192 * nchips]
open(os.path.join(HERE, 'osd_f2.hex'), 'w').write('\n'.join(f2) + '\n')
print('osd_boot.hex 24576 bytes, osd_f2.hex %d bytes' % len(f2))

tb = open(os.path.join(HERE, 'tb_mtx_rom2.vhd')).read()
tb = tb.replace('tb_mtx_rom2', 'tb_mtx_osdrom')


def rep(a, b):
    global tb
    assert a in tb, a[:70]
    tb = tb.replace(a, b, 1)


rep("  signal logging : std_logic := '0';", """  signal logging : std_logic := '0';
  component mtx_romload
    port
      (
      clk : in std_logic;
      ioctl_download, ioctl_wr : in std_logic;
      ioctl_index : in std_logic_vector(7 downto 0);
      ioctl_addr : in std_logic_vector(26 downto 0);
      ioctl_dout : in std_logic_vector(7 downto 0);
      rom_loading : out std_logic;
      rom_waddr : out std_logic_vector(16 downto 0);
      rom_we : out std_logic;
      os_ok, basic_ok, sdx_ok : out std_logic;
      rom2_ok : out std_logic_vector(3 downto 0)
      );
  end component;
  signal ioctl_dl, ioctl_wr_s : std_logic := '0';
  signal ioctl_idx : std_logic_vector(7 downto 0) := x"00";
  signal ioctl_a : std_logic_vector(26 downto 0) := (others => '0');
  signal ioctl_d : std_logic_vector(7 downto 0) := (others => '0');
  signal ld_os_ok, ld_basic_ok, ld_sdx_ok : std_logic;
  signal ld_rom2_ok : std_logic_vector(3 downto 0);
  signal reset_ext : std_logic := '1';""")
rep('rom2_ok => "0011"', 'rom2_ok => ld_rom2_ok')
rep("  main : process", """  loader : mtx_romload
    port map (clk => CLOCK_50, ioctl_download => ioctl_dl, ioctl_wr => ioctl_wr_s, ioctl_index => ioctl_idx,
              ioctl_addr => ioctl_a, ioctl_dout => ioctl_d, rom_loading => rom_loading, rom_waddr => rom_waddr, rom_we => rom_we,
              os_ok => ld_os_ok, basic_ok => ld_basic_ok, sdx_ok => ld_sdx_ok, rom2_ok => ld_rom2_ok);
  rom_wdata <= ioctl_d;
  -- as in MTX512.sv: the machine is held in reset while a ROM file is loading and until the OS and BASIC are in
  RESET <= reset_ext or rom_loading or (not ld_os_ok) or (not ld_basic_ok);

  main : process""")
# the procedure that sends a file the way hps_io does, ahead of the process body
a = tb.index("  begin\n    RESET <= '1';\n    wait for 1 us;\n    rom_loading <= '1';")
b = tb.index("    wait until idle_s >= 2 for 12 sec;")
new_body = '''  begin
    reset_ext <= '1';
    wait for 1 us;
    send(x"00", "osd_boot.hex", 24576);                  -- boot.rom as the firmware sends it at core start
    reset_ext <= '0';
    wait until idle_s >= 2 for 12 sec;
    report "BASIC idle at " & time'image(now);
    wait for 100 ms;
    report "Load ROM 2 at " & time'image(now) & ", rom2_ok before " & integer'image(to_integer(unsigned(ld_rom2_ok)));
    send(x"%s", "osd_f2.hex", %d);                       -- OSD -> Load ROM 2
    report "loaded, rom2_ok " & integer'image(to_integer(unsigned(ld_rom2_ok)));
    wait for 900 ms;                                     -- the machine restarts and boots
''' % (IDX, 8192 * nchips)
proc = '''    procedure send(idx : std_logic_vector(7 downto 0); fname : string; n : integer) is
      file ff : text;
      variable ll : line;
      variable bb : std_logic_vector(7 downto 0);
      variable k : integer := 0;
    begin
      file_open(ff, fname, read_mode);
      wait until rising_edge(CLOCK_50);
      ioctl_idx <= idx; ioctl_dl <= '1'; ioctl_wr_s <= '0'; ioctl_a <= (others => '0');
      while k < n loop
        readline(ff, ll); hread(ll, bb);
        wait until rising_edge(CLOCK_50);
        ioctl_a <= std_logic_vector(to_unsigned(k, 27)); ioctl_d <= bb; ioctl_wr_s <= '1';
        wait until rising_edge(CLOCK_50);
        ioctl_wr_s <= '0';
        k := k + 1;
      end loop;
      wait until rising_edge(CLOCK_50);
      ioctl_dl <= '0';
      file_close(ff);
      wait for 1 us;
    end procedure;
'''
tb = tb[:a] + proc + new_body + tb[b:]
# the rest of main waited for the BASIC prompt again: it is there already
open(os.path.join(HERE, 'tb_mtx_osdrom.vhd'), 'w').write(tb)
print('tb_mtx_osdrom.vhd written for %s, file index %s' % (SET, IDX))
