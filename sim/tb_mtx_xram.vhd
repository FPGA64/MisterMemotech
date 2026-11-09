-- tb_mtx_xram.vhd - the SDX in the whole machine: the real Z80 core, the real mtx.vhd (port decode, memory paging),
-- the SDX ROM in ROM page 3, and sdx_fdc against a model of the HPS block interface. A small test program (xram_roms.hex,
-- built by make_sdx_test.py) is the "OS ROM"; it reports what it sees to port E0h and this bench checks it.
-- Compile with -2008 (external names).
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;

entity tb_mtx_xram is
  generic (SLOT5 : integer := 0; RAM_EXP : integer := 0);
end tb_mtx_xram;

architecture sim of tb_mtx_xram is
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
  component mtx_xsdram
    port
      (
      clk, init : in std_logic;
      SDRAM_DQ : inout std_logic_vector(15 downto 0);
      SDRAM_A : out std_logic_vector(12 downto 0);
      SDRAM_DQML, SDRAM_DQMH : out std_logic;
      SDRAM_BA : out std_logic_vector(1 downto 0);
      SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK : out std_logic;
      addr : in std_logic_vector(17 downto 0); din : in std_logic_vector(7 downto 0);
      se, mreq, rd, wr : in std_logic;
      dout : out std_logic_vector(7 downto 0); wait_n : out std_logic
      );
  end component;
  component sdram_model
    port
      (
      clk, cke, cs_n, ras_n, cas_n, we_n : in std_logic;
      ba : in std_logic_vector(1 downto 0); a : in std_logic_vector(12 downto 0);
      dqml, dqmh : in std_logic;
      dq : inout std_logic_vector(15 downto 0)
      );
  end component;
  signal x_se, x_mreq_n, x_rd_n, x_wr_n, x_wait_n : std_logic;
  signal x_addr : std_logic_vector(17 downto 0);
  signal x_do, x_q : std_logic_vector(7 downto 0);
  signal sd_dq : std_logic_vector(15 downto 0);
  signal sd_a : std_logic_vector(12 downto 0);
  signal sd_ba : std_logic_vector(1 downto 0);
  signal sd_dqml, sd_dqmh, sd_ncs, sd_nwe, sd_nras, sd_ncas, sd_cke, sd_clk : std_logic;
  signal init_cnt : integer := 0;
  signal sd_init : std_logic := '1';
  function expv return std_logic is begin if RAM_EXP = 1 then return '1'; else return '0'; end if; end function;
  type exp_t is array (0 to 86) of integer;
  constant EXP0 : exp_t := (16, 17, 18, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 17, 18, 255, 16, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 192, 193, 194, 255, 192, 193, 165);
  constant EXP1 : exp_t := (16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 17, 18, 19, 16, 21, 20, 23, 22, 25, 24, 27, 26, 29, 28, 31, 30, 33, 32, 255, 34, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 192, 193, 194, 255, 192, 193, 165);

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
      sdx_en => '0', sdx_slot5 => slot5_s, ram_exp => expv, rom2_ok => "0111",
      fdc_cs => fdc_cs, fdc_a => fdc_a, fdc_wr => fdc_wr, fdc_rd => fdc_rd, fdc_do => fdc_do, fdc_di => fdc_di,
      xram_se => x_se, xram_addr => x_addr, xram_do => x_do, xram_mreq_n => x_mreq_n, xram_rd_n => x_rd_n, xram_wr_n => x_wr_n,
      xram_q => x_q, xram_wait_n => x_wait_n);

  process (CLOCK_50)
  begin
    if rising_edge(CLOCK_50) then
      if init_cnt < 15 then init_cnt <= init_cnt + 1; else sd_init <= '0'; end if;
    end if;
  end process;

  xs : mtx_xsdram
    port map (
      clk => CLOCK_50, init => sd_init,
      SDRAM_DQ => sd_dq, SDRAM_A => sd_a, SDRAM_DQML => sd_dqml, SDRAM_DQMH => sd_dqmh, SDRAM_BA => sd_ba,
      SDRAM_nCS => sd_ncs, SDRAM_nWE => sd_nwe, SDRAM_nRAS => sd_nras, SDRAM_nCAS => sd_ncas, SDRAM_CKE => sd_cke, SDRAM_CLK => sd_clk,
      addr => x_addr, din => x_do, se => x_se, mreq => not x_mreq_n, rd => not x_rd_n, wr => not x_wr_n, dout => x_q, wait_n => x_wait_n);

  chip : sdram_model
    port map (clk => sd_clk, cke => sd_cke, cs_n => sd_ncs, ras_n => sd_nras, cas_n => sd_ncas, we_n => sd_nwe,
              ba => sd_ba, a => sd_a, dqml => sd_dqml, dqmh => sd_dqmh, dq => sd_dq);

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
    alias a_s    is << signal .tb_mtx_xram.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_xram.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_xram.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_xram.dut.WR_n   : std_logic >>;
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

  main : process
    file f : text open read_mode is "xram_roms.hex";
    variable l : line;
    variable b : std_logic_vector(7 downto 0);
    variable i : integer := 0;
    variable errors : integer := 0;
    variable k : integer;
    variable exp : integer;
    variable pos : integer;
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
    wait until cpu_halt = '0' for 2 ms;
    wait until cpu_halt = '1' for 200 ms;
    wait for 20 us;
    report "program ended after " & integer'image(nrep) & " reports; block reads " & integer'image(blk_reads) &
           ", block writes " & integer'image(blk_writes);
    chk(cpu_halt = '1', "the program did not reach HALT");

    chk(nrep = 87, "number of reports: " & integer'image(nrep));
    for k in 0 to 86 loop
      if RAM_EXP = 1 then
        chk(to_integer(unsigned(rep(k))) = EXP1(k), "report " & integer'image(k) & ": got " & integer'image(to_integer(unsigned(rep(k)))) & ", want " & integer'image(EXP1(k)));
      else
        chk(to_integer(unsigned(rep(k))) = EXP0(k), "report " & integer'image(k) & ": got " & integer'image(to_integer(unsigned(rep(k)))) & ", want " & integer'image(EXP0(k)));
      end if;
    end loop;
    if errors = 0 then report "MEMORY MAP TEST PASSED"; else report "MEMORY MAP TEST FAILED, " & integer'image(errors) & " errors" severity failure; end if;
    std.env.finish;
  end process;
end sim;
