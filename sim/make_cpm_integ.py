"""Turn tb_mtx_cpm.vhd (make_cpm_test.py) into tb_mtx_integ.vhd: the way the MiSTer does it.

  - the four boot files come through rtl/mtx_romload.sv with the ioctl indexes the firmware uses (boot.rom 00, boot1.rom 40,
    boot2.rom 80, boot3.rom C0), boot3.rom being the 24576 byte file of the private package (SDX ROM, character ROM, CP/M PROM)
  - the machine starts with OSD "Disc ROM" = SDX BASIC and runs to the BASIC prompt
  - then "Disc ROM" is switched to CP/M while the machine runs, with the reset MTX512.sv makes for that (about 21 ms)
  - after RUN_MS the picture of the 80 column board is written to cpm_frame.txt (check it with check_cpm_frame.py)

    python make_cpm_test.py && python make_cpm_integ.py
    FAST=1 SDX=1 LOADER=1 TB=tb_mtx_integ.vhd python build_sim.py
    vsim -c -quiet work.tb_mtx_integ -do "run -all; quit -f"
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
NL = chr(10)
ROOT = os.path.join(HERE, '..', '..')
D = os.path.join(ROOT, 'release_work', 'MTX512_SD', 'games', 'MTX512')
B3 = os.environ.get('BOOT3', os.path.join(ROOT, 'release', 'private', 'sd', 'games', 'MTX512', 'boot3.rom'))


def hexfile(name, data):
    open(os.path.join(HERE, name), 'w').write(chr(10).join('%02X' % x for x in data) + chr(10))


for n, f in (('integ_b0.hex', 'boot.rom'), ('integ_b1.hex', 'boot1.rom'), ('integ_b2.hex', 'boot2.rom')):
    d = open(os.path.join(D, f), 'rb').read()
    assert len(d) == 8192
    hexfile(n, d)
b3 = open(B3, 'rb').read()
assert len(b3) == 24576, len(b3)
hexfile('integ_b3.hex', b3)

tb = open(os.path.join(HERE, 'tb_mtx_cpm.vhd')).read()
tb = tb.replace('tb_mtx_cpm', 'tb_mtx_integ')


def rep(a, b):
    global tb
    assert a in tb, a[:70]
    tb = tb.replace(a, b, 1)


rep("  signal rom_hi_s : std_logic := '0';", """  signal rom_hi_s : std_logic := '0';
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
      rom_waddr_hi : out std_logic;
      rom_we : out std_logic;
      os_ok, basic_ok, sdx_ok, cpm_ok : out std_logic;
      rom2_ok : out std_logic_vector(3 downto 0);
      cg_we : out std_logic;
      cg_addr : out std_logic_vector(12 downto 0);
      cg_ok : out std_logic
      );
  end component;
  signal ioctl_dl, ioctl_wr_s : std_logic := '0';
  signal ioctl_idx : std_logic_vector(7 downto 0) := x"00";
  signal ioctl_a : std_logic_vector(26 downto 0) := (others => '0');
  signal ioctl_d : std_logic_vector(7 downto 0) := (others => '0');
  signal ld_os_ok, ld_basic_ok, ld_sdx_ok, ld_cpm_ok, ld_cg_ok : std_logic;
  signal ld_rom2_ok : std_logic_vector(3 downto 0);
  signal reset_ext : std_logic := '1';
  signal sel_rst_s : std_logic := '0';
  signal cpm_sel_s : std_logic := '0';""")
rep("sdx_en => '1', sdx_slot5 => slot5_s, sdx_relog => relog_s, cpm_sel => '1', cpm_ok => '1', rom_waddr_hi => rom_hi_s,",
    "sdx_en => ld_sdx_ok, sdx_slot5 => slot5_s, sdx_relog => relog_s, cpm_sel => cpm_sel_s, cpm_ok => ld_cpm_ok, rom_waddr_hi => rom_hi_s, rom2_ok => ld_rom2_ok,")
rep("col80_en => '1',", "col80_en => ld_cg_ok,")
rep("  main : process", """  loader : mtx_romload
    port map (clk => CLOCK_50, ioctl_download => ioctl_dl, ioctl_wr => ioctl_wr_s, ioctl_index => ioctl_idx,
              ioctl_addr => ioctl_a, ioctl_dout => ioctl_d, rom_loading => rom_loading, rom_waddr => rom_waddr,
              rom_waddr_hi => rom_hi_s, rom_we => rom_we,
              os_ok => ld_os_ok, basic_ok => ld_basic_ok, sdx_ok => ld_sdx_ok, cpm_ok => ld_cpm_ok, rom2_ok => ld_rom2_ok,
              cg_we => cg_we_s, cg_addr => cg_addr_s, cg_ok => ld_cg_ok);
  rom_wdata <= ioctl_d;
  cg_data_s <= ioctl_d;
  -- as in MTX512.sv: held in reset while a ROM file loads, until the OS and BASIC are in, and after a change of the Disc ROM
  RESET <= reset_ext or rom_loading or (not ld_os_ok) or (not ld_basic_ok) or sel_rst_s;

  main : process""")
# the sending procedure, as the firmware does it
rep("    function img_at(i : integer) return integer is begin", """    procedure send(idx : std_logic_vector(7 downto 0); fname : string; n : integer) is
      file ff : text;
      variable ql : line;
      variable bb : std_logic_vector(7 downto 0);
      variable q : integer := 0;
    begin
      file_open(ff, fname, read_mode);
      wait until rising_edge(CLOCK_50);
      ioctl_idx <= idx; ioctl_dl <= '1'; ioctl_wr_s <= '0'; ioctl_a <= (others => '0');
      while q < n loop
        readline(ff, ql); hread(ql, bb);
        wait until rising_edge(CLOCK_50);
        ioctl_a <= std_logic_vector(to_unsigned(q, 27)); ioctl_d <= bb; ioctl_wr_s <= '1';
        wait until rising_edge(CLOCK_50);
        ioctl_wr_s <= '0';
        q := q + 1;
      end loop;
      wait until rising_edge(CLOCK_50);
      ioctl_dl <= '0';
      file_close(ff);
      wait for 1 us;
    end procedure;
    function img_at(i : integer) return integer is begin""")
a = tb.index("    RESET <= '1';\n    wait for 1 us;\n    rom_loading <= '1';")
z = tb.index("    wait for RUN_MS * 1 ms;")
new = '''    reset_ext <= '1';
    wait for 1 us;
    send(x"00", "integ_b0.hex", 8192);
    send(x"40", "integ_b1.hex", 8192);
    send(x"80", "integ_b2.hex", 8192);
    send(x"C0", "integ_b3.hex", 24576);
    report "boot files in: os_ok " & std_logic'image(ld_os_ok) & " basic_ok " & std_logic'image(ld_basic_ok) & " sdx_ok " & std_logic'image(ld_sdx_ok) &
           " cpm_ok " & std_logic'image(ld_cpm_ok) & " cg_ok " & std_logic'image(ld_cg_ok);
    chk(ld_sdx_ok = '1' and ld_cpm_ok = '1' and ld_cg_ok = '1', "the loader did not flag the SDX ROM, the CP/M PROM and the character ROM");
    reset_ext <= '0';
    wait until idle_s >= 2 for 12 sec;
    report "BASIC idle at " & time'image(now) & " with the SDX ROM selected";
    chk(idle_s >= 2, "the OS did not reach the BASIC prompt with Disc ROM = SDX BASIC");
    wait for 100 ms;
    report "OSD Disc ROM -> CP/M";
    cpm_sel_s <= '1';
    sel_rst_s <= '1';
    wait for 21 ms;
    sel_rst_s <= '0';
'''
tb = tb[:a] + new + tb[z:]
# TYPE=1: after CP/M is up, type on the keyboard through the PS/2 route (key_ready/key_stroke/key_code of mtx_kbd), at a normal speed:
# b, Shift+; (a colon), RET, then d i r RET, and a BackSpace test. Each key is held KEY_MS (default 100 ms), with 60 ms between: the screen
# should end up with A>b: and B>dir and the listing, each letter once.
if os.environ.get('TYPE') == '1':
    KEY_MS = int(os.environ.get('KEY_MS', '100'))
    rep("key_ready => '0', key_stroke => '0', key_code => (others => '0'),", "key_ready => kr, key_stroke => ks, key_code => kc,")
    rep("  signal rom_hi_s : std_logic := '0';", "  signal rom_hi_s : std_logic := '0';" + NL + "  signal kr, ks : std_logic := '0';" + NL + "  signal kc : std_logic_vector(9 downto 0) := (others => '0');")
    typing = """    -- typing, as the MiSTer sends it: a key event is one pulse of key_ready, key_stroke 0 = pressed, 1 = released
    for c in 0 to 9 loop
      case c is
        when 0 => kc <= "00" & x"32";      -- b
        when 1 => kc <= "00" & x"4c";      -- ;  (with Shift: a colon)
        when 2 => kc <= "00" & x"5a";      -- Enter
        when 3 => kc <= "00" & x"23";      -- d
        when 4 => kc <= "00" & x"43";      -- i
        when 5 => kc <= "00" & x"2d";      -- r
        when 6 => kc <= "00" & x"2d";      -- r again
        when 7 => kc <= "00" & x"66";      -- BackSpace: one r goes
        when 8 => kc <= "00" & x"5a";      -- Enter
        when others => kc <= "00" & x"5a"; -- Enter
      end case;
      if c = 1 then
        kc <= "00" & x"12"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 30 ms;       -- left shift down
        kc <= "00" & x"4c";
      end if;
      ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0';
      wait for KEY_MS_ * 1 ms;
      ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0';
      if c = 1 then
        wait for 30 ms;
        kc <= "00" & x"12"; ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0';                         -- left shift up
      end if;
      wait for 60 ms;
      if c = 2 or c = 8 then wait for 800 ms; end if;                                               -- a command takes a moment
    end loop;
    wait for 1500 ms;
""".replace('KEY_MS_', str(KEY_MS))
    if os.environ.get('TYPEKEYS'):
        codes = os.environ['TYPEKEYS'].split(',')
        lines = ['    -- typing the codes ' + ' '.join(codes)]
        for c in codes:
            if c == 'ret':
                c = '5a'
            if c == 'wait':
                lines.append('    wait for 1500 ms;')
                continue
            lines.append('    kc <= "00" & x"%s"; ks <= \'0\'; kr <= \'1\'; wait for 5 us; kr <= \'0\'; wait for %d ms;' % (c, KEY_MS))
            lines.append('    ks <= \'1\'; kr <= \'1\'; wait for 5 us; kr <= \'0\'; wait for 60 ms;')
        lines.append('    wait for 1500 ms;')
        typing = NL.join(lines) + NL
    marker = "    grab_req <= '1';"
    assert marker in tb
    tb = tb.replace(marker, typing + marker, 1)
open(os.path.join(HERE, 'tb_mtx_integ.vhd'), 'w').write(tb)
print('tb_mtx_integ.vhd written')
