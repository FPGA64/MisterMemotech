-- tb_mtx_integ.vhd - the SDX in the whole machine: the real Z80 core, the real mtx.vhd (port decode, memory paging),
-- the SDX ROM in ROM page 3, and sdx_fdc against a model of the HPS block interface. A small test program (cpm_roms.hex,
-- built by make_sdx_test.py) is the "OS ROM"; it reports what it sees to port E0h and this bench checks it.
-- Compile with -2008 (external names).
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;

entity tb_mtx_integ is
  generic (SLOT5 : integer := 0);
end tb_mtx_integ;

architecture sim of tb_mtx_integ is
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
    file df : text open read_mode is "cpm_disc.hex";
    variable dl : line;
    variable db : std_logic_vector(7 downto 0);
  begin
    for i in 0 to 655359 loop
      readline(df, dl); hread(dl, db);
      m(i) := db;
    end loop;
    return m;
  end function;
  shared variable img0 : img_t := init_img(0);
  signal blk_reads, blk_writes : integer := 0;
  function s5 return std_logic is begin if SLOT5 = 1 then return '1'; else return '0'; end if; end function;
  signal slot5_s : std_logic := s5;
  signal relog_s : std_logic := '0';
  signal cg_we_s : std_logic := '0';
  signal rom_hi_s : std_logic := '0';
  signal kr, ks : std_logic := '0';
  signal kc : std_logic_vector(9 downto 0) := (others => '0');
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
  signal cpm_sel_s : std_logic := '0';
  signal cg_addr_s : std_logic_vector(12 downto 0) := (others => '0');
  signal cg_data_s : std_logic_vector(7 downto 0) := (others => '0');
  constant RUN_MS : integer := 5000;
  signal grab_req : std_logic := '0';
  signal frame_state : integer := 0;                 -- 0 idle, 1 waiting for a frame to start, 2 capturing, 3 done
  type frame_t is array (0 to 307199) of std_logic_vector(2 downto 0);
  shared variable frame : frame_t := (others => "000");
  signal nport : integer := 0;
  type pl_t is array (0 to 32767) of std_logic_vector(15 downto 0);
  signal portlog : pl_t := (others => (others => '0'));

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
      sdx_en => ld_sdx_ok, sdx_slot5 => slot5_s, sdx_relog => relog_s, cpm_sel => cpm_sel_s, cpm_ok => ld_cpm_ok, rom_waddr_hi => rom_hi_s, rom2_ok => ld_rom2_ok,
      col80_en => ld_cg_ok, video_sel => "00", cg_we => cg_we_s, cg_addr => cg_addr_s, cg_data => cg_data_s,
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
    alias a_s    is << signal .tb_mtx_integ.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_integ.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_integ.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_integ.dut.WR_n   : std_logic >>;
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

  grab : process (Clk_Video)
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
    alias a_s    is << signal .tb_mtx_integ.dut.A      : std_logic_vector(15 downto 0) >>;
    alias do_s   is << signal .tb_mtx_integ.dut.DO     : std_logic_vector(7 downto 0) >>;
    alias iorq_s is << signal .tb_mtx_integ.dut.IORQ_n : std_logic >>;
    alias wr_s   is << signal .tb_mtx_integ.dut.WR_n   : std_logic >>;
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

  loader : mtx_romload
    port map (clk => CLOCK_50, ioctl_download => ioctl_dl, ioctl_wr => ioctl_wr_s, ioctl_index => ioctl_idx,
              ioctl_addr => ioctl_a, ioctl_dout => ioctl_d, rom_loading => rom_loading, rom_waddr => rom_waddr,
              rom_waddr_hi => rom_hi_s, rom_we => rom_we,
              os_ok => ld_os_ok, basic_ok => ld_basic_ok, sdx_ok => ld_sdx_ok, cpm_ok => ld_cpm_ok, rom2_ok => ld_rom2_ok,
              cg_we => cg_we_s, cg_addr => cg_addr_s, cg_ok => ld_cg_ok);
  rom_wdata <= ioctl_d;
  cg_data_s <= ioctl_d;
  -- as in MTX512.sv: held in reset while a ROM file loads, until the OS and BASIC are in, and after a change of the Disc ROM
  RESET <= reset_ext or rom_loading or (not ld_os_ok) or (not ld_basic_ok) or sel_rst_s;

  main : process
    file f : text open read_mode is "cpm_roms.hex";
    variable l : line;
    variable b : std_logic_vector(7 downto 0);
    variable i : integer := 0;
    variable errors : integer := 0;
    variable k : integer;
    variable exp : integer;
    variable pos : integer;
    file pf : text open read_mode is "cpm_page.hex";
    file cf : text open read_mode is "cpm_cg.hex";
    file fo : text;
    variable ll : line;
    variable ch : std_logic_vector(2 downto 0);
    alias idle_s is << signal .tb_mtx_integ.dut.U_AUTOROM.idle_wins : integer range 0 to 3 >>;
    alias dbg_a is << signal .tb_mtx_integ.dut.A : std_logic_vector(15 downto 0) >>;
    procedure send(idx : std_logic_vector(7 downto 0); fname : string; n : integer) is
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
    function img_at(i : integer) return integer is begin return (i * 7 + (i / 256) * 13) mod 256; end function;
    function secoff(t, sd, s : integer) return integer is begin return ((2 * t + sd) * 16 + s - 1) * 256; end function;
    procedure chk(cond : boolean; what : string) is
    begin
      if not cond then report "FAIL: " & what severity error; errors := errors + 1; end if;
    end procedure;
  begin
    reset_ext <= '1';
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
    wait for RUN_MS * 1 ms;
    report "after " & integer'image(RUN_MS) & " ms: block reads " & integer'image(blk_reads) & ", 80 column port writes " & integer'image(nport);
    -- typing the codes 1b 1b 1b 1b ret 1c 1c 1c 1c ret 23 23 23 23 ret
    kc <= "00" & x"1b"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"1b"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"1b"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"1b"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"5a"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"1c"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"1c"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"1c"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"1c"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"5a"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"23"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"23"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"23"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"23"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    kc <= "00" & x"5a"; ks <= '0'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 100 ms;
    ks <= '1'; kr <= '1'; wait for 5 us; kr <= '0'; wait for 60 ms;
    wait for 1500 ms;
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
    if errors = 0 then report "CPM BENCH FINISHED"; else report "CPM BENCH FAILED, " & integer'image(errors) & " errors" severity failure; end if;
    std.env.finish;
  end process;
end sim;
