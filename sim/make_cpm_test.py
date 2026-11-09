"""Build tb_mtx_cpm.vhd and its data files for a whole-machine test of CP/M with the 80 column board:

  - the real Z80 core, mtx.vhd (the 80 column board in it), sdx_fdc, the real OS, BASIC, ASSEM and SDX ROMs (your boot.rom, boot1.rom,
    boot2.rom, boot3.rom) and the SDX CP/M bootstrap PROM in its own page (refs/col80_cpm/SDX_98E7.rom, test use only), selected
    in the place of the SDX ROM as OSD "Disc ROM" = CP/M does
  - the 80 column board's character ROM (refs/col80_cpm/dl/80char_0743.bin), loaded through cg_we like mtx_romload does
  - disc A = a CP/M system disc (refs/memu_src/mfloppy/andy_sys.mfloppy)
  - the PROM starts itself at power-on and boots CP/M from the disc (there is no BASIC prompt in between)
  - after RUN_MS the bench writes the picture the board made (cpm_frame.txt: 640 x 480, one character per pixel) and
    cpm_ports.txt (the 80 column port writes it saw)

    python make_cpm_test.py
    FAST=1 SDX=1 TB=tb_mtx_cpm.vhd python build_sim.py
    vsim -c -do "run -all; quit -f" tb_mtx_cpm
    python check_cpm_frame.py
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
D = os.path.join(ROOT, 'release_work', 'MTX512_SD', 'games', 'MTX512')
PROM = os.path.join(ROOT, 'refs', 'col80_cpm', 'SDX_98E7.rom')
CG = os.path.join(ROOT, 'refs', 'col80_cpm', 'dl', '80char_0743.bin')
DISC = os.path.join(ROOT, 'refs', 'memu_src', 'mfloppy', 'andy_sys.mfloppy')
RUN_MS = int(os.environ.get('RUN_MS', '5000'))

# the SDX slot holds the real SDX ROM; the CP/M PROM is in its own page (page 16) and is the one selected (cpm_sel = 1, as OSD
# "Disc ROM" = CP/M does it). CPMSEL=0 selects the SDX ROM instead (and then nothing starts by itself: BASIC runs).
CPMSEL = os.environ.get('CPMSEL', '1')
img = b''.join(open(os.path.join(D, n), 'rb').read() for n in ('boot.rom', 'boot1.rom', 'boot2.rom', 'boot3.rom'))
open(os.path.join(HERE, 'cpm_page.hex'), 'w').write(chr(10).join('%02X' % x for x in open(PROM, 'rb').read()) + chr(10))
assert len(img) == 32768, len(img)
open(os.path.join(HERE, 'cpm_roms.hex'), 'w').write('\n'.join('%02X' % x for x in img) + '\n')
cg = open(CG, 'rb').read()
assert len(cg) == 8192
open(os.path.join(HERE, 'cpm_cg.hex'), 'w').write('\n'.join('%02X' % x for x in cg) + '\n')
disc = open(DISC, 'rb').read()
assert len(disc) == 655360, len(disc)
open(os.path.join(HERE, 'cpm_disc.hex'), 'w').write('\n'.join('%02X' % x for x in disc) + '\n')
print('cpm_roms.hex, cpm_cg.hex, cpm_disc.hex written')

tb = open(os.path.join(HERE, 'tb_mtx_sdx.vhd')).read()
tb = tb.replace('tb_mtx_sdx', 'tb_mtx_cpm').replace('sdx_roms.hex', 'cpm_roms.hex')


def rep(a, b):
    global tb
    assert a in tb, a[:60]
    tb = tb.replace(a, b, 1)


# the disc image is the CP/M disc
rep("""    variable m : img_t;
  begin
    for i in 0 to 655359 loop
      if drv = 0 then m(i) := std_logic_vector(to_unsigned((i * 7 + (i / 256) * 13) mod 256, 8));
      else            m(i) := std_logic_vector(to_unsigned((i * 5 + (i / 512) * 3 + 1) mod 256, 8)); end if;
    end loop;
    return m;""", """    variable m : img_t;
    file df : text open read_mode is "cpm_disc.hex";
    variable dl : line;
    variable db : std_logic_vector(7 downto 0);
  begin
    for i in 0 to 655359 loop
      readline(df, dl); hread(dl, db);
      m(i) := db;
    end loop;
    return m;""")
rep("  signal slot5_s : std_logic := s5;", """  signal slot5_s : std_logic := s5;
  signal relog_s : std_logic := '0';
  signal cg_we_s : std_logic := '0';
  signal rom_hi_s : std_logic := '0';
  signal cg_addr_s : std_logic_vector(12 downto 0) := (others => '0');
  signal cg_data_s : std_logic_vector(7 downto 0) := (others => '0');
  constant RUN_MS : integer := %d;
  signal grab_req : std_logic := '0';
  signal frame_state : integer := 0;                 -- 0 idle, 1 waiting for a frame to start, 2 capturing, 3 done
  type frame_t is array (0 to 307199) of std_logic_vector(2 downto 0);
  shared variable frame : frame_t := (others => "000");
  signal nport : integer := 0;
  type pl_t is array (0 to 32767) of std_logic_vector(15 downto 0);
  signal portlog : pl_t := (others => (others => '0'));""" % RUN_MS)
rep("sdx_en => '1', sdx_slot5 => slot5_s,", "sdx_en => '1', sdx_slot5 => slot5_s, sdx_relog => relog_s, cpm_sel => '@CPMSEL@', cpm_ok => '1', rom_waddr_hi => rom_hi_s,\n      col80_en => '1', video_sel => \"00\", cg_we => cg_we_s, cg_addr => cg_addr_s, cg_data => cg_data_s,")
# the picture the board makes, one frame
rep("  main : process", """  grab : process (Clk_Video)
    variable x, y : integer := 0;
    variable pvs, phb : std_logic := '0';
  begin
    if rising_edge(Clk_Video) then
      if frame_state = 0 and grab_req = '1' then frame_state <= 1; end if;
      if frame_state = 1 and vs = '1' and pvs = '0' then frame_state <= 2; x := 0; y := 0; end if;
      if frame_state = 2 then
        if vs = '1' and pvs = '0' then
          frame_state <= 3;
        elsif vb = '0' and hb = '0' then
          if x < 640 and y < 480 then frame(y * 640 + x) := vgar(0) & vgag(0) & vgab(0); end if;
          x := x + 1;
        end if;
        if hb = '1' and phb = '0' then
          if x > 0 then y := y + 1; end if;
          x := 0;
        end if;
      end if;
      pvs := vs;
      phb := hb;
    end if;
  end process;

  -- every write to the 80 column ports (30h to 33h, 38h, 39h): port and data
  spy0 : process (clk_cpu_o)
    alias a_s    is << signal .tb_mtx_cpm.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_cpm.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_cpm.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_cpm.dut.WR_n   : std_logic >>;
    variable prev : std_logic := '1';
  begin
    if rising_edge(clk_cpu_o) then
      if iorq_s = '0' and wr_s = '0' and prev = '1' and
         (a_s(7 downto 0) = x"30" or a_s(7 downto 0) = x"31" or a_s(7 downto 0) = x"32" or a_s(7 downto 0) = x"33" or
          a_s(7 downto 0) = x"38" or a_s(7 downto 0) = x"39") then
        if nport < 32768 then portlog(nport) <= a_s(7 downto 0) & do_s; end if;
        nport <= nport + 1;
      end if;
      prev := wr_s or iorq_s;
    end if;
  end process;

  main : process""")
rep("    variable pos : integer;", """    variable pos : integer;
    file pf : text open read_mode is "cpm_page.hex";
    file cf : text open read_mode is "cpm_cg.hex";
    file fo : text;
    variable ll : line;
    variable ch : std_logic_vector(2 downto 0);
    alias idle_s is << signal .tb_mtx_cpm.dut.U_AUTOROM.idle_wins : integer range 0 to 3 >>;
    alias dbg_a is << signal .tb_mtx_cpm.dut.A : std_logic_vector(15 downto 0) >>;""")
rep("""    wait until rising_edge(CLOCK_50);
    rom_loading <= '0';
    report "loaded " & integer'image(i) & " bytes";""", """    -- the CP/M PROM into its own page (bit 17 of the ROM memory address)
    i := 0;
    rom_hi_s <= '1';
    while not endfile(pf) loop
      readline(pf, l); hread(l, b);
      wait until rising_edge(CLOCK_50);
      rom_waddr <= std_logic_vector(to_unsigned(i, 17));
      rom_wdata <= b; rom_we <= '1';
      wait until rising_edge(CLOCK_50);
      rom_we <= '0';
      i := i + 1;
    end loop;
    rom_hi_s <= '0';
    wait until rising_edge(CLOCK_50);
    rom_loading <= '0';
    report "loaded " & integer'image(i) & " bytes";
    -- the character ROM, as mtx_romload does it: one cg_we pulse a byte
    i := 0;
    while not endfile(cf) loop
      readline(cf, ll); hread(ll, b);
      wait until rising_edge(CLOCK_50);
      cg_addr_s <= std_logic_vector(to_unsigned(i, 13)); cg_data_s <= b; cg_we_s <= '1';
      wait until rising_edge(CLOCK_50);
      cg_we_s <= '0';
      i := i + 1;
    end loop;
    report "character ROM loaded, " & integer'image(i) & " bytes";""")
a = tb.index("    -- the program ends with HALT after reporting A5h")
z = tb.index('    if errors = 0 then report "SDX MACHINE TEST PASSED"')
DBG = os.environ.get('DBG') == '1'
new = '''    -- the CP/M bootstrap PROM in ROM 3 starts itself at power-on: the machine boots CP/M from disc A with no BASIC prompt in between
    wait for RUN_MS * 1 ms;
    report "after " & integer'image(RUN_MS) & " ms: block reads " & integer'image(blk_reads) & ", 80 column port writes " & integer'image(nport);
    grab_req <= '1';
    wait until frame_state = 3 for 100 ms;
    chk(frame_state = 3, "no frame came from the 80 column board (is the video selected? has the CRTC been programmed?)");
    file_open(fo, "cpm_frame.txt", write_mode);
    for y in 0 to 479 loop
      ll := null;
      for x in 0 to 639 loop
        ch := frame(y * 640 + x);
        case ch is
          when "000" => write(ll, character'('.'));
          when "100" => write(ll, character'('R'));     -- (the bits are red, green, blue)
          when "010" => write(ll, character'('G'));
          when "001" => write(ll, character'('B'));
          when "110" => write(ll, character'('Y'));
          when "101" => write(ll, character'('M'));
          when "011" => write(ll, character'('C'));
          when others => write(ll, character'('W'));
        end case;
      end loop;
      writeline(fo, ll);
    end loop;
    file_close(fo);
    file_open(fo, "cpm_ports.txt", write_mode);
    for k in 0 to nport - 1 loop
      if k < 32768 then
        ll := null;
        hwrite(ll, portlog(k)(15 downto 8)); write(ll, ' '); hwrite(ll, portlog(k)(7 downto 0));
        writeline(fo, ll);
      end if;
    end loop;
    file_close(fo);
'''
if DBG:      # DBG=1: no waiting for BASIC: look at what the CPU is doing after 2 s and write the 80 column port log
    new = '''    wait for 2 sec;
    report "DEBUG 2 s: A=" & integer'image(to_integer(unsigned(dbg_a))) & " idle_s=" & integer'image(idle_s) & " 80 col port writes " & integer'image(nport) & " halt=" & std_logic'image(cpu_halt);
    wait for 50 ms;
    report "DEBUG 2.05 s: A=" & integer'image(to_integer(unsigned(dbg_a)));
    wait for 3 ms;
    report "DEBUG 2.053 s: A=" & integer'image(to_integer(unsigned(dbg_a)));
    wait for 11 ms;
    report "DEBUG 2.064 s: A=" & integer'image(to_integer(unsigned(dbg_a)));
    std.env.finish;
'''
tb = tb[:a] + new + tb[z:]
tb = tb.replace('SDX MACHINE TEST PASSED', 'CPM BENCH FINISHED').replace('SDX MACHINE TEST FAILED', 'CPM BENCH FAILED')
tb = tb.replace('@CPMSEL@', CPMSEL)
open(os.path.join(HERE, 'tb_mtx_cpm.vhd'), 'w').write(tb)
print('tb_mtx_cpm.vhd written, RUN_MS', RUN_MS)
