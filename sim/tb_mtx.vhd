-- tb_mtx.vhd - boots the whole core in simulation: loads OS/BASIC/ASSEM through the
-- ROM loader path, releases reset, and shows what the OS draws on the VDP screen.
-- Compile this file with -2008 (external names); the design itself is VHDL-93.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;

entity tb_mtx is
  generic (RUN_MS : integer := 40);
end tb_mtx;

architecture sim of tb_mtx is
  signal CLOCK_50  : std_logic := '0';
  signal Clk_Video : std_logic := '0';
  signal RESET     : std_logic := '1';
  signal div_cpu   : std_logic_vector(2 downto 0) := "101";   -- 4.166MHz
  signal rom_loading : std_logic := '0';
  signal rom_we    : std_logic := '0';
  signal rom_waddr : std_logic_vector(16 downto 0) := (others => '0');
  signal rom_wdata : std_logic_vector(7 downto 0) := (others => '0');
  signal clk_cpu_o : std_logic;
  signal cpu_halt  : std_logic;
  signal sound_out : std_logic_vector(15 downto 0);
  signal tape_motor, tape_out, tape_out_we : std_logic;
  signal vgar, vgag, vgab : std_logic_vector(3 downto 0);
  signal hs, vs, hb, vb : std_logic;

  type vram_t is array (0 to 16383) of std_logic_vector(7 downto 0);
  signal vram_shadow : vram_t := (others => (others => '0'));
  signal vdp_regs    : std_logic_vector(63 downto 0) := (others => '0');
  signal vram_writes : integer := 0;
  signal reg_writes  : integer := 0;
  signal io_ops      : integer := 0;
begin
  CLOCK_50  <= not CLOCK_50  after 10 ns;     -- 50MHz
  Clk_Video <= not Clk_Video after 20 ns;     -- 25MHz

  dut : entity work.mtx
    port map (
      CLOCK_50 => CLOCK_50, Clk_Video => Clk_Video, RESET => RESET, div_cpu => div_cpu,
      hw_pal => '0', frame_60 => '0',
      key_ready => '0', key_stroke => '0', key_code => (others => '0'),
      VGA_R => vgar, VGA_G => vgag, VGA_B => vgab, VGA_HS => hs, VGA_VS => vs, VGA_HB => hb, VGA_VB => vb,
      sound_out => sound_out, sound_strobe => open, joy1 => "00000", joy2 => "00000",
      mtx_loaded => '0', mtx_ready => '0', mtx_eof => '0', mtx_byte => x"00", mtx_pop_t => open, mtx_rewind_t => open,
      tape_in => '0', tape_out => tape_out, tape_out_we => tape_out_we, tape_motor => tape_motor,
      clk_cpu_o => clk_cpu_o, cpu_halt => cpu_halt,
      rom_loading => rom_loading, rom_we => rom_we, rom_waddr => rom_waddr, rom_wdata => rom_wdata);

  -- spy on the host side of the VDP: every VRAM write and every VDP register write
  spy : process (clk_cpu_o)
    alias vwe   is << signal .tb_mtx.dut.host_vram_we  : std_logic >>;
    alias vaddr is << signal .tb_mtx.dut.host_vram_addr : std_logic_vector(13 downto 0) >>;
    alias vd    is << signal .tb_mtx.dut.host_vram_d   : std_logic_vector(7 downto 0) >>;
    alias rwe   is << signal .tb_mtx.dut.vdp_reg_we    : std_logic >>;
    alias rnum  is << signal .tb_mtx.dut.vdp_reg_number : std_logic_vector(2 downto 0) >>;
    alias rval  is << signal .tb_mtx.dut.vdp_reg_value : std_logic_vector(7 downto 0) >>;
    variable l : line;
  begin
    if rising_edge(clk_cpu_o) then
      if vwe = '1' then
        vram_shadow(to_integer(unsigned(vaddr))) <= vd;
        vram_writes <= vram_writes + 1;
      end if;
      if rwe = '1' then
        vdp_regs(to_integer(unsigned(rnum))*8+7 downto to_integer(unsigned(rnum))*8) <= rval;
        reg_writes <= reg_writes + 1;
        write(l, string'("  VDP reg ")); write(l, to_integer(unsigned(rnum)));
        write(l, string'(" <= 0x")); hwrite(l, rval);
        write(l, string'("   at ")); write(l, now);
        writeline(output, l);
      end if;
    end if;
  end process;

  main : process
    file f : text open read_mode is "roms.hex";
    variable l : line;
    variable b : std_logic_vector(7 downto 0);
    variable i : integer := 0;
    procedure dump_screen is
      variable ln : line;
      variable base : integer;
      variable c : integer;
      variable r1 : std_logic_vector(7 downto 0);
    begin
      r1 := vdp_regs(15 downto 8);
      base := to_integer(unsigned(r1(3 downto 0))) * 1024;
      write(ln, string'("VDP name table base 0x")); hwrite(ln, std_logic_vector(to_unsigned(base, 16)));
      writeline(output, ln);
      for row in 0 to 23 loop
        for col in 0 to 39 loop
          c := to_integer(unsigned(vram_shadow(base + row*40 + col)));
          if c >= 32 and c < 127 then write(ln, character'val(c)); else write(ln, '.'); end if;
        end loop;
        writeline(output, ln);
      end loop;
    end procedure;
  begin
    RESET <= '1';
    wait for 1 us;
    -- the ROM loader path: OS, BASIC, ASSEM back to back at 0x10000
    rom_loading <= '1';
    while not endfile(f) loop
      readline(f, l);
      hread(l, b);
      wait until rising_edge(CLOCK_50);
      rom_waddr  <= std_logic_vector(to_unsigned(16#10000# + i, 17));
      rom_wdata  <= b;
      rom_we     <= '1';
      wait until rising_edge(CLOCK_50);
      rom_we     <= '0';
      i := i + 1;
    end loop;
    wait until rising_edge(CLOCK_50);
    rom_loading <= '0';
    report "loaded " & integer'image(i) & " ROM bytes";
    wait for 1 us;
    RESET <= '0';
    report "reset released";

    for msn in 1 to RUN_MS loop
      wait for 1 ms;
      if msn mod 5 = 0 then
        report integer'image(msn) & " ms: vram writes=" & integer'image(vram_writes) &
               " vdp reg writes=" & integer'image(reg_writes);
      end if;
    end loop;
    dump_screen;
    report "SIMULATION DONE";
    wait;
  end process;
end sim;
