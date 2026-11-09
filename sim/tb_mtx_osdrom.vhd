-- tb_mtx_osdrom.vhd - the SDX in the whole machine: the real Z80 core, the real mtx.vhd (port decode, memory paging),
-- the SDX ROM in ROM page 3, and sdx_fdc against a model of the HPS block interface. A small test program (rom2_roms.hex,
-- built by make_sdx_test.py) is the "OS ROM"; it reports what it sees to port E0h and this bench checks it.
-- Compile with -2008 (external names).
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;

entity tb_mtx_osdrom is
  generic (SLOT5 : integer := 0);
end tb_mtx_osdrom;

architecture sim of tb_mtx_osdrom is
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
  constant RUN_MS : integer := 1500;
  signal kr, ks : std_logic := '0';
  signal kc : std_logic_vector(9 downto 0) := (others => '0');
  signal rom2_n : integer := 0;                  -- OUT (0) with the ROM bits 010: ROM 2 selected
  signal rom2_t : time := 0 ns;
  type txt_t is array (0 to 16383) of character;
  signal txt : txt_t := (others => ' ');
  signal ntxt : integer := 0;
  signal logging : std_logic := '0';
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
  signal reset_ext : std_logic := '1';

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
      key_ready => kr, key_stroke => ks, key_code => kc,
      VGA_R => vgar, VGA_G => vgag, VGA_B => vgab, VGA_HS => hs, VGA_VS => vs, VGA_HB => hb, VGA_VB => vb,
      sound_out => sound_out, sound_strobe => sound_strobe, joy1 => "00000", joy2 => "00000",
      tape_in => '0', tape_out => tape_out, tape_out_we => tape_out_we, tape_motor => tape_motor,
      clk_cpu_o => clk_cpu_o, cpu_halt => cpu_halt,
      rom_loading => rom_loading, rom_we => rom_we, rom_waddr => rom_waddr, rom_wdata => rom_wdata,
      mtx_loaded => '0', mtx_ready => '0', mtx_eof => '0', mtx_byte => x"00", mtx_pop_t => open, mtx_rewind_t => open,
      mtx_nm_t => open, mtx_nm_d => open, mtx_nodata => '0',
      sv_wr_t => open, sv_wr_d => open, sv_start_t => open, sv_flush_t => open, sv_busy => '0',
      sdx_en => '0', sdx_slot5 => slot5_s, rom2_ok => ld_rom2_ok,
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
    alias a_s    is << signal .tb_mtx_osdrom.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_osdrom.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_osdrom.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_osdrom.dut.WR_n   : std_logic >>;
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
    alias a_s    is << signal .tb_mtx_osdrom.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_osdrom.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_osdrom.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_osdrom.dut.WR_n   : std_logic >>;
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

  loader : mtx_romload
    port map (clk => CLOCK_50, ioctl_download => ioctl_dl, ioctl_wr => ioctl_wr_s, ioctl_index => ioctl_idx,
              ioctl_addr => ioctl_a, ioctl_dout => ioctl_d, rom_loading => rom_loading, rom_waddr => rom_waddr, rom_we => rom_we,
              os_ok => ld_os_ok, basic_ok => ld_basic_ok, sdx_ok => ld_sdx_ok, rom2_ok => ld_rom2_ok);
  rom_wdata <= ioctl_d;
  -- as in MTX512.sv: the machine is held in reset while a ROM file is loading and until the OS and BASIC are in
  RESET <= reset_ext or rom_loading or (not ld_os_ok) or (not ld_basic_ok);

  main : process
    file f : text open read_mode is "rom2_roms.hex";
    variable l : line;
    variable b : std_logic_vector(7 downto 0);
    variable i : integer := 0;
    variable errors : integer := 0;
    alias idle_s is << signal .tb_mtx_osdrom.dut.U_AUTOROM.idle_wins : integer range 0 to 3 >>;
    file fo : text;
    variable n0 : integer;
    variable k : integer;
    variable exp : integer;
    variable pos : integer;
    function img_at(i : integer) return integer is begin return (i * 7 + (i / 256) * 13) mod 256; end function;
    function secoff(t, sd, s : integer) return integer is begin return ((2 * t + sd) * 16 + s - 1) * 256; end function;
    procedure chk(cond : boolean; what : string) is
    begin
      if not cond then report "FAIL: " & what severity error; errors := errors + 1; end if;
    end procedure;
    procedure send(idx : std_logic_vector(7 downto 0); fname : string; n : integer) is
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
  begin
    reset_ext <= '1';
    wait for 1 us;
    send(x"00", "osd_boot.hex", 24576);                  -- boot.rom as the firmware sends it at core start
    reset_ext <= '0';
    wait until idle_s >= 2 for 12 sec;
    report "BASIC idle at " & time'image(now);
    wait for 100 ms;
    report "Load ROM 2 at " & time'image(now) & ", rom2_ok before " & integer'image(to_integer(unsigned(ld_rom2_ok)));
    send(x"02", "osd_f2.hex", 16384);                       -- OSD -> Load ROM 2
    report "loaded, rom2_ok " & integer'image(to_integer(unsigned(ld_rom2_ok)));
    wait for 900 ms;                                     -- the machine restarts and boots
    wait until idle_s >= 2 for 12 sec;
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
    if errors = 0 then report "ROM 2 BENCH FINISHED"; else report "ROM 2 BENCH FAILED, " & integer'image(errors) & " errors" severity failure; end if;
    std.env.finish;
  end process;
end sim;
