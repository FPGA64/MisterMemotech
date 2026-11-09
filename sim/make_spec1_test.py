"""Build tb_mtx_spec1.vhd: the real OS and BASIC boot in the whole core with the Speculator board fitted, the bench presents
SPEC1.mtx on the .mtx stream port (as mtx_tape.sv does), types   LOAD ""  RET   on the PS/2 keyboard path and then lets the
Speculator program run. spec1_log.txt records, with times, the writes to the CTC (ports 08-0B), the VDP register port (02), the
paging port (00) and the NMI port (FF), every interrupt the CPU is given (INT), every NMI the board raises, and a count of
the VDP data port writes (the screen copy).

    python make_spec1_test.py [folder with boot.rom boot1.rom boot2.rom]       RUN_MS=3000 (time to run after the load)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'release_work', 'MTX512_SD', 'games', 'MTX512')
SPEC1 = os.path.join(ROOT, 'refs', 'speculator', 'programs', 'speculator_program', 'SPEC1.mtx')
RUN_MS = int(os.environ.get('RUN_MS', '3000'))

img = b''.join(open(os.path.join(D, n), 'rb').read() for n in ('boot.rom', 'boot1.rom', 'boot2.rom'))
assert len(img) == 24576
img += b'\xff' * (32768 - len(img))
open(os.path.join(HERE, 'spec1_roms.hex'), 'w').write('\n'.join('%02X' % x for x in img) + '\n')

mtx = open(SPEC1, 'rb').read()
N = len(mtx)
rows = []
for i in range(0, N, 16):
    rows.append(', '.join('x"%02X"' % b for b in mtx[i:i + 16]))
agg = ',\n    '.join(rows)

tb = open(os.path.join(HERE, 'tb_mtx_sdx.vhd')).read()
tb = tb.replace('tb_mtx_sdx', 'tb_mtx_spec1').replace('sdx_roms.hex', 'spec1_roms.hex')


def rep(a, b):
    global tb
    assert a in tb, a[:70]
    tb = tb.replace(a, b, 1)


rep("key_ready => '0', key_stroke => '0', key_code => (others => '0'),", "key_ready => kr, key_stroke => ks, key_code => kc,")
rep("mtx_loaded => '0', mtx_ready => '0', mtx_eof => '0', mtx_byte => x\"00\", mtx_pop_t => open, mtx_rewind_t => open,\n      mtx_nm_t => open, mtx_nm_d => open, mtx_nodata => '0',",
    "mtx_loaded => '1', mtx_ready => m_ready, mtx_eof => m_eof, mtx_byte => m_byte, mtx_pop_t => pop_t, mtx_rewind_t => rew_t,\n      mtx_nm_t => open, mtx_nm_d => open, mtx_nodata => '0',")
rep("sdx_en => '1', sdx_slot5 => slot5_s,", "sdx_en => '0', sdx_slot5 => slot5_s, spec_en => '1',")
rep("  signal slot5_s : std_logic := s5;", """  signal slot5_s : std_logic := s5;
  signal kr, ks : std_logic := '0';
  signal kc : std_logic_vector(9 downto 0) := (others => '0');
  -- the .mtx stream: SPEC1.mtx, %d bytes
  constant NB : integer := %d;
  type mimg_t is array (0 to NB - 1) of std_logic_vector(7 downto 0);
  constant MIMG : mimg_t := (
    %s);
  signal pop_t, rew_t : std_logic := '0';
  signal m_ready : std_logic := '1';
  signal m_eof : std_logic := '0';
  signal m_byte : std_logic_vector(7 downto 0) := x"00";
  signal m_idx : integer := 0;""" % (N, N, agg))
rep("  main : process", """  -- the stream source: a byte is taken when pop_t toggles; the next one is ready some clocks later
  stream : process (CLOCK_50)
    variable last_pop : std_logic := '0';
    variable last_rew : std_logic := '0';
    variable hold : integer := 0;
    variable idx : integer := 0;
  begin
    if rising_edge(CLOCK_50) then
      if pop_t /= last_pop then
        last_pop := pop_t; idx := idx + 1; hold := 60; m_ready <= '0';
      elsif rew_t /= last_rew then
        last_rew := rew_t; idx := 0; hold := 60; m_ready <= '0';
      elsif hold > 0 then
        hold := hold - 1;
        if hold = 0 then m_ready <= '1'; end if;
      end if;
      m_idx <= idx;
      if idx < NB then m_byte <= MIMG(idx); m_eof <= '0'; else m_byte <= x"00"; m_eof <= '1'; end if;
    end if;
  end process;

  -- what the machine does, with times: spec1_log.txt
  spy1 : process (clk_cpu_o)
    alias a_s    is << signal .tb_mtx_spec1.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_spec1.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_spec1.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_spec1.dut.WR_n   : std_logic >>;
    alias m1_s   is << signal .tb_mtx_spec1.dut.M1_n   : std_logic >>;
    alias mreq_s is << signal .tb_mtx_spec1.dut.MREQ_n : std_logic >>;
    file lf : text open write_mode is "spec1_log.txt";
    variable pc : integer := 0;
    variable pc1 : integer := 0;
    variable lastslot : integer := 0;
    variable wprev : std_logic := '1';
    variable l : line;
    variable prev : std_logic := '1';
    variable nvdp : integer := 0;
    variable p : integer;
  begin
    if rising_edge(clk_cpu_o) then
      if m1_s = '0' and mreq_s = '0' then
        if to_integer(unsigned(a_s)) /= pc then pc1 := pc; pc := to_integer(unsigned(a_s)); end if;
        -- where the program is, every 2 ms after 2.9 s
        if now > 2900 ms and (now / 2 ms) /= lastslot then
          lastslot := now / 2 ms;
          l := null; write(l, integer'image(now / 1 us) & " us PCS " & integer'image(pc)); writeline(lf, l);
        end if;
      end if;
      -- writes to the Speculator's flag bytes in RAM (373B nmi_enabled, 373C nmi_immediate, 3711, 3712, 3724, 3725)
      if mreq_s = '0' and wr_s = '0' and wprev = '1' and iorq_s = '1' and now > 1900 ms and now < 3300 ms then
        p := to_integer(unsigned(a_s));
        if p = 16#373B# or p = 16#373C# or p = 16#3711# or p = 16#3724# or p = 16#3725# then
          l := null;
          write(l, integer'image(now / 1 us) & " us MEMW " & integer'image(p) & " " & integer'image(to_integer(unsigned(do_s))) & " pc " & integer'image(pc));
          writeline(lf, l);
        end if;
      end if;
      wprev := wr_s or mreq_s;
      if iorq_s = '0' and wr_s = '0' and prev = '1' then
        p := to_integer(unsigned(a_s(7 downto 0)));
        if p = 1 then
          nvdp := nvdp + 1;
          if nvdp mod 512 = 0 then
            l := null; write(l, integer'image(now / 1 us) & " us VDPDATA " & integer'image(nvdp)); writeline(lf, l);
          end if;
        elsif p = 0 or p = 2 or (p >= 8 and p <= 11) or p = 255 then
          l := null;
          write(l, integer'image(now / 1 us) & " us OUT " & integer'image(p) & " " & integer'image(to_integer(unsigned(do_s))) & " pc " & integer'image(pc));
          writeline(lf, l);
        end if;
      end if;
      prev := wr_s or iorq_s;
    end if;
  end process;

  spy2 : process (CLOCK_50)
    alias nmi_s is << signal .tb_mtx_spec1.dut.spec_nmi_n : std_logic >>;
    alias int_s is << signal .tb_mtx_spec1.dut.ctc_interrupt : std_logic >>;
    file lf2 : text open write_mode is "spec1_log2.txt";
    variable l : line;
    variable pn : std_logic := '1';
    variable pi : std_logic := '0';
  begin
    if rising_edge(CLOCK_50) then
      if nmi_s = '0' and pn = '1' then
        l := null; write(l, integer'image(now / 1 us) & " us NMI"); writeline(lf2, l);
      end if;
      if int_s = '1' and pi = '0' then
        l := null; write(l, integer'image(now / 1 us) & " us INT"); writeline(lf2, l);
      end if;
      pn := nmi_s; pi := int_s;
    end if;
  end process;

  main : process""")
a = tb.index("    pos := 0;\n    if SLOT5 = 0 then") if "    pos := 0;\n    if SLOT5 = 0 then" in tb else tb.index("    wait until cpu_halt = '0' for 2 ms;")
h = tb.index("    -- the program ends with HALT after reporting A5h")
z = tb.index('    if errors = 0 then report "SDX MACHINE TEST PASSED"')
codes = [('4b', 0), ('44', 0), ('1c', 0), ('23', 0), ('29', 0),            # L O A D space
         ('1e', 1), ('1e', 1),                                            # "" : shift and 2, twice
         ('5a', 0)]                                                       # RET
lines = []
shift_on = False
for code, sh in codes:
    if sh and not shift_on:
        lines.append("    kc <= \"00\" & x\"12\"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 30 ms;")
        shift_on = True
    if not sh and shift_on:
        lines.append("    kc <= \"00\" & x\"12\"; ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 40 ms;")
        shift_on = False
    lines.append("    kc <= \"00\" & x\"%s\"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 70 ms;" % code)
    lines.append("    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 50 ms;")
new = '''    wait until idle_s >= 2 for 12 sec;
    report "BASIC idle at " & time'image(now);
    chk(idle_s >= 2, "the OS did not reach the BASIC prompt");
    wait for 100 ms;
    report "typing LOAD" & '"' & '"' & " at " & time'image(now);
''' + '\n'.join(lines) + '''
    report "RET typed at " & time'image(now);
    wait for %d ms;
    report "end at " & time'image(now) & ", stream index " & integer'image(m_idx) & " of " & integer'image(NB);
''' % RUN_MS
tb = tb[:min(a, h)] + new + tb[z:]
rep("    variable errors : integer := 0;", "    variable errors : integer := 0;\n    alias idle_s is << signal .tb_mtx_spec1.dut.U_AUTOROM.idle_wins : integer range 0 to 3 >>;")
tb = tb.replace('SDX MACHINE TEST PASSED', 'SPEC1 BENCH FINISHED').replace('SDX MACHINE TEST FAILED', 'SPEC1 BENCH FAILED')
open(os.path.join(HERE, 'tb_mtx_spec1.vhd'), 'w').write(tb)
print('tb_mtx_spec1.vhd written; stream %d bytes; run %d ms after RET' % (N, RUN_MS))
