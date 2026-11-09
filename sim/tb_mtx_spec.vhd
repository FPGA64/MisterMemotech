-- tb_mtx_spec.vhd - the Speculator board in the whole machine: the real Z80 core, the real mtx.vhd, the CTC and a VDP
-- stand-in that raises a frame interrupt every 20ms. A small test program (spec_roms.hex, built by make_spec_test.py)
-- is the "OS ROM": it exercises the board with real I/O cycles and reports what it sees to port D0h.
-- Compile with -2008 (external names); use the FAST stubs (build_sim.py with FAST=1).
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;

entity tb_mtx_spec is
  generic (FITTED : integer := 1);
end tb_mtx_spec;

architecture sim of tb_mtx_spec is
  signal CLOCK_50  : std_logic := '0';
  signal Clk_Video : std_logic := '0';
  signal RESET     : std_logic := '1';
  signal rom_loading, rom_we : std_logic := '0';
  signal rom_waddr : std_logic_vector(16 downto 0) := (others => '0');
  signal rom_wdata : std_logic_vector(7 downto 0) := (others => '0');
  signal clk_cpu_o, cpu_halt : std_logic;
  signal vgar, vgag, vgab : std_logic_vector(3 downto 0);
  signal hs, vs, hb, vb, tape_motor, tape_out, tape_out_we, sound_strobe : std_logic;
  signal sound_out : std_logic_vector(15 downto 0);
  signal spec_en : std_logic := '1';

  type rep_t is array (0 to 255) of std_logic_vector(7 downto 0);
  signal rep : rep_t := (others => (others => '0'));
  signal nrep : integer := 0;
begin
  CLOCK_50  <= not CLOCK_50  after 10 ns;
  Clk_Video <= not Clk_Video after 20 ns;
  spec_en   <= '1' when FITTED = 1 else '0';

  dut : entity work.mtx
    port map (
      CLOCK_50 => CLOCK_50, Clk_Video => Clk_Video, RESET => RESET, div_cpu => "101",
      hw_pal => '0', frame_60 => '0',
      key_ready => '0', key_stroke => '0', key_code => (others => '0'),
      VGA_R => vgar, VGA_G => vgag, VGA_B => vgab, VGA_HS => hs, VGA_VS => vs, VGA_HB => hb, VGA_VB => vb,
      sound_out => sound_out, sound_strobe => sound_strobe, joy1 => "00000", joy2 => "00000",
      tape_in => '0', tape_out => tape_out, tape_out_we => tape_out_we, tape_motor => tape_motor,
      clk_cpu_o => clk_cpu_o, cpu_halt => cpu_halt,
      rom_loading => rom_loading, rom_we => rom_we, rom_waddr => rom_waddr, rom_wdata => rom_wdata,
      mtx_loaded => '0', mtx_ready => '0', mtx_eof => '0', mtx_byte => x"00", mtx_pop_t => open, mtx_rewind_t => open,
      mtx_nm_t => open, mtx_nm_d => open, mtx_nodata => '0',
      sv_wr_t => open, sv_wr_d => open, sv_start_t => open, sv_flush_t => open, sv_busy => '0',
      sdx_en => '0', sdx_slot5 => '0',
      fdc_cs => open, fdc_a => open, fdc_wr => open, fdc_rd => open, fdc_do => open, fdc_di => x"FF",
      spec_en => spec_en);

  -- watch the Z80's output cycles: port D0h is the program's report port
  spy : process (clk_cpu_o)
    alias a_s    is << signal .tb_mtx_spec.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_spec.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_spec.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_spec.dut.WR_n   : std_logic >>;
    variable prev : std_logic := '1';
  begin
    if rising_edge(clk_cpu_o) then
      if iorq_s = '0' and wr_s = '0' and prev = '1' and a_s(7 downto 0) = x"D0" then
        if nrep < 256 then rep(nrep) <= do_s; end if;
        nrep <= nrep + 1;
      end if;
      prev := wr_s or iorq_s;
    end if;
  end process;

  main : process
    file f : text open read_mode is "spec_roms.hex";
    variable l : line;
    variable b : std_logic_vector(7 downto 0);
    variable i : integer := 0;
    variable errors : integer := 0;
    impure function v(k : integer) return integer is begin return to_integer(unsigned(rep(k))); end function;
    procedure chk(cond : boolean; what : string) is
    begin
      if not cond then report "FAIL: " & what severity error; errors := errors + 1; end if;
    end procedure;
  begin
    RESET <= '1';
    wait for 1 us;
    rom_loading <= '1';
    while not endfile(f) loop
      readline(f, l); hread(l, b);
      wait until rising_edge(CLOCK_50);
      rom_waddr <= std_logic_vector(to_unsigned(16#10000# + i, 17));
      rom_wdata <= b; rom_we <= '1';
      wait until rising_edge(CLOCK_50);
      rom_we <= '0';
      i := i + 1;
    end loop;
    wait until rising_edge(CLOCK_50);
    rom_loading <= '0';
    report "loaded " & integer'image(i) & " bytes";
    wait for 1 us;
    RESET <= '0';
    wait until cpu_halt = '0' for 2 ms;
    wait until cpu_halt = '1' for 400 ms;
    wait for 20 us;
    report "program ended after " & integer'image(nrep) & " reports";
    chk(cpu_halt = '1', "the program did not reach HALT");
    chk(nrep = 11, "expected 11 reports, got " & integer'image(nrep));
    for k in 0 to 10 loop
      report "report " & integer'image(k) & " = " & integer'image(v(k));
    end loop;
    if FITTED = 1 then
      chk(v(0) = 16#1D#, "border via 7E");
      chk(v(1) = 16#A2#, "row 1");
      chk(v(2) = 16#A1#, "row 0");
      chk(v(3) = 16#A8#, "row 7");
      chk(v(5) >= 5, "immediate: interrupts counted");
      chk(v(4) = v(5), "immediate: one NMI per interrupt");
      chk(v(7) >= 5, "delayed: interrupts counted");
      chk(v(6) = v(7), "delayed: one NMI per interrupt");
      chk(v(8) = 0, "NMI disabled: none expected");
      chk(v(9) >= 5, "disabled: interrupts counted");
    else
      chk(v(0) = 16#FF#, "border read with the board not fitted: open bus");
      chk(v(4) = 0 and v(6) = 0 and v(8) = 0, "no NMI without the board");
      chk(v(5) >= 5 and v(7) >= 5 and v(9) >= 5, "interrupts counted");
    end if;
    chk(v(10) = 16#A5#, "end marker");
    if errors = 0 then
      report "SPECULATOR MACHINE TEST PASSED";
    else
      report integer'image(errors) & " FAILURE(S)" severity failure;
    end if;
    wait for 1 us;
    std.env.finish;
  end process;
end sim;
