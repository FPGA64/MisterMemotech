-- tb_mtx_rom3.vhd - the SDX in the whole machine: the real Z80 core, the real mtx.vhd (port decode, memory paging),
-- the SDX ROM in ROM page 3, and sdx_fdc against a model of the HPS block interface. A small test program (rom3_roms.hex,
-- built by make_sdx_test.py) is the "OS ROM"; it reports what it sees to port E0h and this bench checks it.
-- Compile with -2008 (external names).
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;

entity tb_mtx_rom3 is
  generic (SLOT5 : integer := 0);
end tb_mtx_rom3;

architecture sim of tb_mtx_rom3 is
  component sdx_fdc
    port
      (
      clk, clk_sys, reset : in std_logic;
      cs : in std_logic; a : in std_logic_vector(2 downto 0); wr, rd : in std_logic;
      din : in std_logic_vector(7 downto 0); dout : out std_logic_vector(7 downto 0);
      d_mnt, d_ro, d_t40, d_ss : in std_logic_vector(1 downto 0);
      d_blks0, d_blks1 : in std_logic_vector(22 downto 0);
      sd_rd_o, sd_wr_o, sd_drv : out std_logic;
      sd_lba : out std_logic_vector(31 downto 0);
      sd_ack : in std_logic;
      sd_buff_addr : in std_logic_vector(8 downto 0);
      sd_buff_dout : in std_logic_vector(7 downto 0);
      sd_buff_wr : in std_logic;
      sd_buff_din : out std_logic_vector(7 downto 0)
      );
  end component;

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

  signal fdc_cs, fdc_wr, fdc_rd : std_logic;
  signal fdc_a : std_logic_vector(2 downto 0);
  signal fdc_do, fdc_di : std_logic_vector(7 downto 0);

  signal sd_rd_o, sd_wr_o, sd_drv, sd_ack : std_logic := '0';
  signal sd_lba : std_logic_vector(31 downto 0);
  signal sd_buff_addr : std_logic_vector(8 downto 0) := (others => '0');
  signal sd_buff_dout : std_logic_vector(7 downto 0) := (others => '0');
  signal sd_buff_wr : std_logic := '0';
  signal sd_buff_din : std_logic_vector(7 downto 0);

  -- the disc images
  type img_t is array (0 to 655359) of std_logic_vector(7 downto 0);
  function init_img(drv : integer) return img_t is
    variable m : img_t;
  begin
    for i in 0 to 655359 loop
      if drv = 0 then m(i) := std_logic_vector(to_unsigned((i * 7 + (i / 256) * 13) mod 256, 8));
      else            m(i) := std_logic_vector(to_unsigned((i * 5 + (i / 512) * 3 + 1) mod 256, 8)); end if;
    end loop;
    return m;
  end function;
  shared variable img0 : img_t := init_img(0);
  signal blk_reads, blk_writes : integer := 0;
  function s5 return std_logic is begin if SLOT5 = 1 then return '1'; else return '0'; end if; end function;
  signal slot5_s : std_logic := s5;
  signal relog_s : std_logic := '0';
  signal rom3_n  : integer := 0;                 -- OUT (0) with the ROM bits 011: ROM 3 selected
  signal rom3_t  : time := 0 ns;

  -- what the program reports on port E0h
  type rep_t is array (0 to 4095) of std_logic_vector(7 downto 0);
  signal rep : rep_t := (others => (others => '0'));
  signal nrep : integer := 0;
  signal spy_a  : std_logic_vector(15 downto 0);
  signal spy_do : std_logic_vector(7 downto 0);
  signal spy_iorq, spy_wr : std_logic;
begin
  CLOCK_50  <= not CLOCK_50  after 10 ns;
  Clk_Video <= not Clk_Video after 20 ns;

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
      sdx_en => '1', sdx_slot5 => slot5_s, sdx_relog => relog_s,
      fdc_cs => fdc_cs, fdc_a => fdc_a, fdc_wr => fdc_wr, fdc_rd => fdc_rd, fdc_do => fdc_do, fdc_di => fdc_di);

  fdc : sdx_fdc
    port map (
      clk => clk_cpu_o, clk_sys => CLOCK_50, reset => RESET,
      cs => fdc_cs, a => fdc_a, wr => fdc_wr, rd => fdc_rd, din => fdc_do, dout => fdc_di,
      d_mnt => "01", d_ro => "00", d_t40 => "00", d_ss => "00",
      d_blks0 => std_logic_vector(to_unsigned(1280, 23)), d_blks1 => std_logic_vector(to_unsigned(1280, 23)),
      sd_rd_o => sd_rd_o, sd_wr_o => sd_wr_o, sd_drv => sd_drv, sd_lba => sd_lba, sd_ack => sd_ack,
      sd_buff_addr => sd_buff_addr, sd_buff_dout => sd_buff_dout, sd_buff_wr => sd_buff_wr, sd_buff_din => sd_buff_din);

  -- the HPS side of the SD block interface: a block is sent (read) or taken (write) byte by byte
  hps : process
    variable lba : integer;
  begin
    wait until rising_edge(CLOCK_50);
    if sd_rd_o = '1' then
      for k in 1 to 20 loop wait until rising_edge(CLOCK_50); end loop;
      lba := to_integer(unsigned(sd_lba(19 downto 0)));
      sd_ack <= '1';
      for k in 0 to 511 loop
        wait until rising_edge(CLOCK_50);
        sd_buff_addr <= std_logic_vector(to_unsigned(k, 9));
        sd_buff_dout <= img0(lba * 512 + k);
        sd_buff_wr <= '1';
        wait until rising_edge(CLOCK_50);
        sd_buff_wr <= '0';
      end loop;
      for k in 1 to 3 loop wait until rising_edge(CLOCK_50); end loop;
      sd_ack <= '0'; blk_reads <= blk_reads + 1;
      for k in 1 to 3 loop wait until rising_edge(CLOCK_50); end loop;
    elsif sd_wr_o = '1' then
      for k in 1 to 20 loop wait until rising_edge(CLOCK_50); end loop;
      lba := to_integer(unsigned(sd_lba(19 downto 0)));
      sd_ack <= '1';
      for k in 0 to 511 loop
        sd_buff_addr <= std_logic_vector(to_unsigned(k, 9));
        for j in 1 to 3 loop wait until rising_edge(CLOCK_50); end loop;
        img0(lba * 512 + k) := sd_buff_din;
      end loop;
      for k in 1 to 3 loop wait until rising_edge(CLOCK_50); end loop;
      sd_ack <= '0'; blk_writes <= blk_writes + 1;
      for k in 1 to 3 loop wait until rising_edge(CLOCK_50); end loop;
    end if;
  end process;

  -- watch the Z80's output cycles: port E0h is the program's report port
  spy : process (clk_cpu_o)
    alias a_s    is << signal .tb_mtx_rom3.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_rom3.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_rom3.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_rom3.dut.WR_n   : std_logic >>;
    variable prev : std_logic := '1';
  begin
    if rising_edge(clk_cpu_o) then
      if iorq_s = '0' and wr_s = '0' and prev = '1' and a_s(7 downto 0) = x"E0" then
        if nrep < 4096 then rep(nrep) <= do_s; end if;
        nrep <= nrep + 1;
      end if;
      prev := wr_s or iorq_s;
    end if;
  end process;

  spy0 : process (clk_cpu_o)
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

  main : process
    file f : text open read_mode is "rom3_roms.hex";
    variable l : line;
    variable b : std_logic_vector(7 downto 0);
    variable i : integer := 0;
    variable errors : integer := 0;
    variable k : integer;
    variable exp : integer;
    variable pos : integer;
    variable n0 : integer;
    variable t0 : time;
    alias idle_s is << signal .tb_mtx_rom3.dut.U_AUTOROM.idle_wins : integer range 0 to 3 >>;
    function img_at(i : integer) return integer is begin return (i * 7 + (i / 256) * 13) mod 256; end function;
    function secoff(t, sd, s : integer) return integer is begin return ((2 * t + sd) * 16 + s - 1) * 256; end function;
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
    -- the program ends with HALT after reporting A5h
    -- the OS boots to the BASIC prompt; the autorom watches the CPU and sees it idle
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
    if errors = 0 then report "ROM 3 TYPIST MACHINE TEST PASSED"; else report "ROM 3 TYPIST MACHINE TEST FAILED, " & integer'image(errors) & " errors" severity failure; end if;
    std.env.finish;
  end process;
end sim;
