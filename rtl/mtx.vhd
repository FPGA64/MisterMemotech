--
-- mtx.vhd - Memotech MTX512: Z80, CTC, VDP, sound chip, keyboard, 64KB RAM, and the SDX, 80 column board and others as options
--
-- Derived from the CPU board of REMEMOTECH by Andy Key (http://www.nyangau.org/rememotech)
-- with the REMEMOrizer, CP/M, SD card, 80 column card, DART and accelerator removed.
-- What remains is a stock MTX500/512 with no expansions.
--
-- I/O ports (A7..A0 decoded, A15..A8 ignored, as on the motherboard):
--   00  w IOBYTE (memory paging)          r printer strobe (no effect here)
--   01  rw VDP data                       02  w VDP control / r VDP status
--   03  w cassette out (bit 0)            r sound chip strobe
--   04  r printer status                  05  w keyboard drive / r keyboard sense
--   06  w sound data / r keyboard sense   07  parallel port (not connected)
--   08-0B  CTC channels 0..3              1F  w cassette motor (AA = on, 55 = off)
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mtx is
  port
    (
    CLOCK_50     : in  std_logic;                     -- fixed 50MHz
    Clk_Video    : in  std_logic;                     -- 25MHz, VDP pixel clock
    RESET        : in  std_logic;                     -- 1 = reset
    div_cpu      : in  std_logic_vector(2 downto 0);  -- CPU speed, see clock_divider
    hw_pal       : in  std_logic;                     -- VDP palette: 0 normal, 1 Marat
    frame_60     : in  std_logic;                     -- 0 = 50Hz, 1 = 60Hz
    -- keyboard (PS/2 key events)
    key_ready    : in  std_logic;
    key_stroke   : in  std_logic;
    key_code     : in  std_logic_vector(9 downto 0);
    -- video
    VGA_R, VGA_G, VGA_B : out std_logic_vector(3 downto 0);
    VGA_HS, VGA_VS      : out std_logic;
    VGA_HB, VGA_VB      : out std_logic;
    -- audio
    sound_out    : out std_logic_vector(15 downto 0);   -- signed
    sound_strobe : out std_logic;
    -- joysticks: bit 0 up, 1 down, 2 left, 3 right, 4 fire (any clock domain)
    joy1         : in  std_logic_vector(4 downto 0);
    joy2         : in  std_logic_vector(4 downto 0);
    -- cassette
    tape_in      : in  std_logic;                     -- tape waveform (any clock domain)
    tape_out     : out std_logic;                     -- bit 0 of last write to port 03
    tape_out_we  : out std_logic;                     -- 1 clk_cpu pulse per write to port 03
    tape_motor   : out std_logic;                     -- 1 = motor on (OUT 1F,AA)
    clk_cpu_o    : out std_logic;                     -- CPU clock, for status/debug
    cpu_halt     : out std_logic;
    -- ROM loader (boot.rom / boot0..2.rom from the HPS, CPU must be held in RESET while loading)
    rom_loading  : in  std_logic;
    rom_we       : in  std_logic;                      -- write one byte (CLOCK_50 domain)
    rom_waddr    : in  std_logic_vector(16 downto 0);  -- byte address in on-chip memory
    rom_waddr_hi : in  std_logic := '0';               -- bit 17 of it (the page of the CP/M PROM)
    rom_wdata    : in  std_logic_vector(7 downto 0);
    -- .mtx stream (INOUT overlay)
    mtx_loaded   : in  std_logic;
    mtx_ready    : in  std_logic;                      -- a byte is waiting (50MHz domain)
    mtx_eof      : in  std_logic;
    mtx_byte     : in  std_logic_vector(7 downto 0);
    mtx_pop_t    : out std_logic;                      -- toggles when a byte has been taken
    mtx_rewind_t : out std_logic;                      -- toggles to restart the stream
    mtx_nm_t     : out std_logic;                      -- toggles for each character of the name asked for (port 8D)
    mtx_nm_d     : out std_logic_vector(7 downto 0);
    mtx_nodata   : in  std_logic;                      -- the name asked for is not the name on the tape
    -- SAVE (INOUT overlay)
    sv_wr_t      : out std_logic;                      -- toggles for each byte written to port 8E
    sv_wr_d      : out std_logic_vector(7 downto 0);
    sv_start_t   : out std_logic;                      -- toggles: a tape starts (OUT 8F,2)
    sv_flush_t   : out std_logic;                      -- toggles: the chunk is complete (OUT 8F,4)
    sv_busy      : in  std_logic;                      -- a block is being written to the save image
    -- SDX (floppy controller on ports 10h..14h, ROM page 3 or 5)
    sdx_en       : in  std_logic;                      -- an SDX ROM has been loaded: the card is fitted
    cpm_sel      : in  std_logic := '0';               -- the disc ROM is the CP/M bootstrap PROM (else the SDX ROM)
    cpm_ok       : in  std_logic := '0';               -- the CP/M PROM has been loaded
    sdx_slot5    : in  std_logic;                      -- its ROM answers as ROM 5 (else ROM 3)
    fdc_cs       : out std_logic;                      -- an I/O cycle on port 10h..14h
    fdc_a        : out std_logic_vector(2 downto 0);   -- the register (port - 10h)
    fdc_wr       : out std_logic;                      -- write strobe
    fdc_rd       : out std_logic;                      -- read strobe
    fdc_do       : out std_logic_vector(7 downto 0);   -- data from the Z80
    fdc_di       : in  std_logic_vector(7 downto 0);   -- data to the Z80
    -- Speculator (ZX Spectrum add-on board: RAM behind ports 1F, 7E, 7F, FB, FE, FF and an NMI generator)
    spec_en      : in  std_logic := '0';               -- the board is fitted
    -- SDX: a disc was changed (one 50MHz clock pulse): type ROM 3 when BASIC is at its prompt (mtx_autorom.vhd)
    sdx_relog    : in  std_logic := '0';
    -- memory: the 256KB expansion RAM, and which of the four ROM 2 sub-pages were loaded (memory_map.vhd)
    ram_exp      : in  std_logic := '0';
    rom2_ok      : in  std_logic_vector(3 downto 0) := "0000";
    -- the expansion RAM is outside this module (the SDRAM, mtx_xsdram.sv): its bus, and its WAIT for the Z80
    xram_se      : out std_logic;                      -- the address is in the expansion RAM
    xram_addr    : out std_logic_vector(17 downto 0);  -- block (4 bits) and offset in the block (14 bits)
    xram_do      : out std_logic_vector(7 downto 0);   -- data from the Z80
    xram_mreq_n  : out std_logic;
    xram_rd_n    : out std_logic;
    xram_wr_n    : out std_logic;
    xram_q       : in  std_logic_vector(7 downto 0) := x"FF";   -- data to the Z80
    xram_wait_n  : in  std_logic := '1';
    -- the Communications board: the two serial channels of the Z80 DART (ports 0C to 0F)
    dart_rx_a    : in  std_logic := '1';
    dart_rx_b    : in  std_logic := '1';
    dart_tx_a    : out std_logic;
    dart_tx_b    : out std_logic;
    -- the 80 column board (ports 30h to 33h, 38h, 39h), shown instead of the VDP when video_sel says so
    col80_en     : in  std_logic := '0';                -- the board is fitted (its character ROM has been loaded)
    video_sel    : in  std_logic_vector(1 downto 0) := "00";   -- 00 auto (80 column once the CRTC has been programmed), 01 VDP, 10 80 column
    cg_we        : in  std_logic := '0';                -- write one byte of the character ROM (CLOCK_50 domain)
    cg_addr      : in  std_logic_vector(12 downto 0) := (others => '0');
    cg_data      : in  std_logic_vector(7 downto 0) := (others => '0')
    );
end mtx;

architecture behavior of mtx is

  component RamRom
    port
      (
      address : in  std_logic_vector (16 downto 0);
      byteena : in  std_logic_vector (1 downto 0) := (others => '1');
      clken   : in  std_logic := '1';
      clock   : in  std_logic := '1';
      rden    : in  std_logic := '1';
      data    : in  std_logic_vector (15 downto 0);
      wren    : in  std_logic;
      q       : out std_logic_vector (15 downto 0)
      );
  end component;

  signal one : std_logic;

  -- clocks
  signal clk_cpu       : std_logic;
  signal ctc_timer16   : std_logic;
  signal ctc_counter   : std_logic;

  -- VRAM
  signal host_vram_addr     : std_logic_vector(13 downto 0) := "00000000000000";
  signal host_vram_addr_inc : std_logic := '0';
  signal host_vram_d        : std_logic_vector(7 downto 0) := (others => '0');
  signal host_vram_we       : std_logic := '0';
  signal host_vram_q        : std_logic_vector(7 downto 0);
  signal vdp_vram_addr      : std_logic_vector(13 downto 0);
  signal vdp_vram_q         : std_logic_vector(7 downto 0);

  -- VDP
  signal vdp_latched     : std_logic := '0';
  signal vdp_reg_re      : std_logic;
  signal vdp_reg_we      : std_logic := '0';
  signal vdp_reg_number  : std_logic_vector(2 downto 0) := "000";
  signal vdp_reg_value   : std_logic_vector(7 downto 0) := (others => '0');
  signal vdp_status      : std_logic_vector(7 downto 0);
  signal vdp_interrupt   : std_logic;

  -- sound
  signal sound_reg_we    : std_logic;
  signal sound_reg_value : std_logic_vector(7 downto 0) := (others => '0');

  -- keyboard
  signal drive      : std_logic_vector(7 downto 0) := x"ff";
  signal sense5     : std_logic_vector(7 downto 0);
  signal sense6     : std_logic_vector(7 downto 0);
  signal extra_keys : std_logic_vector(13 downto 0);

  -- CTC
  signal ctc_we        : std_logic;
  signal ctc_data_read : std_logic_vector(7 downto 0);
  signal ctc_interrupt : std_logic;
  signal ctc_re_vector : std_logic;
  signal ctc_vector    : std_logic_vector(7 downto 1);

  -- cassette
  signal ts1, ts2, ts3 : std_logic := '0';
  signal tape_edge     : std_logic := '0';
  signal tape_motor_r  : std_logic := '0';
  signal tape_out_r    : std_logic := '0';
  signal tape_out_we_r : std_logic := '0';

  -- memory map
  signal iobyte    : std_logic_vector(7 downto 0) := x"00";
  signal se        : std_logic;
  signal we        : std_logic;
  signal phys_addr : std_logic_vector(21 downto 13);

  -- on-chip memory
  signal RAM_ADDR : std_logic_vector(16 downto 0);
  signal disc_en  : std_logic;
  signal RAM_LB_N : std_logic;
  signal RAM_UB_N : std_logic;
  signal RAM_OE_N : std_logic;
  signal RAM_WE_N : std_logic;
  signal RAM_D    : std_logic_vector(15 downto 0);
  signal RAM_Q    : std_logic_vector(15 downto 0);

  -- Z80
  signal RESET_n : std_logic;
  signal M1_n    : std_logic;
  signal MREQ_n  : std_logic;
  signal IORQ_n  : std_logic;
  signal RD_n    : std_logic;
  signal WR_n    : std_logic;
  signal HALT_n  : std_logic;
  signal A       : std_logic_vector(15 downto 0);
  signal DI      : std_logic_vector(7 downto 0);
  signal DO      : std_logic_vector(7 downto 0);

  signal vdp_r, vdp_g, vdp_b : std_logic_vector(3 downto 0);
  signal vdp_hs, vdp_vs, vdp_hb, vdp_vb : std_logic;

  -- the 80 column board
  signal col_hit, col_prog, col_wr, col_sel : std_logic;
  signal col_do : std_logic_vector(7 downto 0);
  signal col_r, col_g, col_b : std_logic_vector(3 downto 0);
  signal col_hs, col_vs, col_hb, col_vb : std_logic;
  signal prog_v : std_logic_vector(1 downto 0) := "00";

  -- joysticks are wired into the keyboard matrix (schematic, connectors J4 and J5)
  signal joy_sense : std_logic_vector(7 downto 0);

  -- .mtx overlay
  signal ovl_hit   : std_logic;
  signal ovl_q     : std_logic_vector(7 downto 0);
  signal ovl_use   : std_logic;
  signal rdy_s     : std_logic_vector(1 downto 0) := "00";
  signal eof_s     : std_logic_vector(1 downto 0) := "00";
  signal ld_s      : std_logic_vector(1 downto 0) := "00";
  signal pop_r     : std_logic := '0';
  signal rew_r     : std_logic := '0';
  signal rd8e_d    : std_logic := '0';
  signal nm_r      : std_logic := '0';
  signal nm_dr     : std_logic_vector(7 downto 0) := (others => '0');
  signal sv_r      : std_logic := '0';
  signal sv_dr     : std_logic_vector(7 downto 0) := (others => '0');
  signal ss_r      : std_logic := '0';
  signal sf_r      : std_logic := '0';
  signal nd_s      : std_logic_vector(1 downto 0) := "00";
  signal sb_s      : std_logic_vector(1 downto 0) := "00";

  -- the DART (Communications board)
  signal dart_cs     : std_logic;
  signal dart_data_a, dart_stat_a, dart_data_b, dart_stat_b : std_logic_vector(7 downto 0);
  signal ctc_zcto1, ctc_zcto2 : std_logic;

  -- expansion RAM and the ROM 2 sub-page register
  signal xse      : std_logic;
  signal xblk     : std_logic_vector(3 downto 0);
  signal subpage  : std_logic_vector(1 downto 0) := "00";

  -- keys typed by the core (ROM 3 after a disc change)
  signal inj_keys : std_logic_vector(79 downto 0);

  -- Speculator
  signal spec_hit   : std_logic;
  signal spec_do    : std_logic_vector(7 downto 0);
  signal spec_nmi_n : std_logic;

begin

  one <= '1';
  -- the disc system is fitted when the ROM it runs has been loaded: the SDX ROM, or the CP/M PROM when that is the one selected
  disc_en <= cpm_ok when cpm_sel = '1' else sdx_en;
  RESET_n <= not RESET;

  U_DIVIDER : entity work.clock_divider
    port map
      (
      clk_50mhz   => CLOCK_50,
      div_cpu     => div_cpu,
      clk_cpu     => clk_cpu,
      clk_timer16 => ctc_timer16,
      clk_counter => ctc_counter,
      clk_25mhz   => open,
      clk_4mhz    => open,
      clk_1mhz    => open
      );

  clk_cpu_o <= clk_cpu;
  cpu_halt  <= not HALT_n;

  U_VRAM : entity work.vdp_vram
    port map
      (
      clk_host  => clk_cpu,
      d_host    => host_vram_d,
      addr_host => host_vram_addr,
      we_host   => host_vram_we,
      q_host    => host_vram_q,
      clk_vdp   => Clk_Video,
      addr_vdp  => vdp_vram_addr,
      q_vdp     => vdp_vram_q
      );

  U_VDP : entity work.vdp
    port map
      (
      clk_25mhz     => Clk_Video,
      vram_addr     => vdp_vram_addr,
      vram_q        => vdp_vram_q,
      clk_cpu       => clk_cpu,
      reg_re        => vdp_reg_re,
      reg_we        => vdp_reg_we,
      reg_number    => vdp_reg_number,
      reg_value     => vdp_reg_value,
      status        => vdp_status,
      interrupt     => vdp_interrupt,
      hw_pal        => hw_pal,
      frame_rate    => frame_60,
      debug_patnam  => '0',
      debug_patgen  => '0',
      debug_patcol  => '0',
      debug_sprgen  => '0',
      vga_r         => vdp_r,
      vga_g         => vdp_g,
      vga_b         => vdp_b,
      vga_hsync     => vdp_hs,
      vga_vsync     => vdp_vs,
      vga_hblank    => vdp_hb,
      vga_vblank    => vdp_vb
      );

  -- the 80 column board, and which of the two pictures goes out
  col_wr <= '1' when ( WR_n = '0' and IORQ_n = '0' and M1_n = '1' ) else '0';

  U_COL80 : entity work.mtx_col80
    port map
      (
      clk_cpu   => clk_cpu,
      reset     => RESET,
      en        => col80_en,
      a         => A(7 downto 0),
      wr_io     => col_wr,
      d_in      => DO,
      d_out     => col_do,
      hit       => col_hit,
      crtc_prog => col_prog,
      clk_ld    => CLOCK_50,
      cg_we     => cg_we,
      cg_addr   => cg_addr,
      cg_data   => cg_data,
      clk_vid   => Clk_Video,
      frame_60  => frame_60,
      vga_r     => col_r,
      vga_g     => col_g,
      vga_b     => col_b,
      vga_hs    => col_hs,
      vga_vs    => col_vs,
      vga_hb    => col_hb,
      vga_vb    => col_vb
      );

  process ( Clk_Video )
  begin
    if rising_edge(Clk_Video) then
      prog_v <= prog_v(0) & col_prog;
      if video_sel = "10" or ( video_sel = "00" and col80_en = '1' and prog_v(1) = '1' ) then
        col_sel <= '1';
      else
        col_sel <= '0';
      end if;
    end if;
  end process;

  VGA_R  <= col_r  when col_sel = '1' else vdp_r;
  VGA_G  <= col_g  when col_sel = '1' else vdp_g;
  VGA_B  <= col_b  when col_sel = '1' else vdp_b;
  VGA_HS <= col_hs when col_sel = '1' else vdp_hs;
  VGA_VS <= col_vs when col_sel = '1' else vdp_vs;
  VGA_HB <= col_hb when col_sel = '1' else vdp_hb;
  VGA_VB <= col_vb when col_sel = '1' else vdp_vb;

  U_SOUND : entity work.sound
    port map
      (
      clk_cpu   => clk_cpu,
      reset     => RESET,
      reg_we    => sound_reg_we,
      reg_value => sound_reg_value,
      div_cpu   => div_cpu,
      output    => sound_out,
      strobe    => sound_strobe
      );

  U_MTXKBD : entity work.mtx_kbd
    port map
      (
      clk_1mhz   => CLOCK_50,
      key_ready  => key_ready,
      key_stroke => key_stroke,
      key_code   => key_code,
      drive      => drive,
      sense5     => sense5,
      sense6     => sense6,
      extra_keys => extra_keys,
      inj        => inj_keys,
      cpm_mode   => cpm_sel
      );

  U_AUTOROM : entity work.mtx_autorom
    port map
      (
      clk50  => CLOCK_50,
      reset  => RESET,
      trig   => sdx_relog,
      a      => A,
      m1_n   => M1_n,
      mreq_n => MREQ_n,
      inj    => inj_keys,
      busy   => open
      );

  U_CTC : entity work.ctc
    port map
      (
      clk_cpu    => clk_cpu,
      reset      => RESET,
      channel    => A(1 downto 0),
      we         => ctc_we,
      data_write => DO,
      data_read  => ctc_data_read,
      interrupt  => ctc_interrupt,
      re_vector  => ctc_re_vector,
      vector     => ctc_vector,
      timer16    => ctc_timer16,
      count0     => vdp_interrupt,  -- VDP interrupt
      count1     => ctc_counter,    -- 4MHz/13: tape-out baud timer (serial clock on a real MTX)
      count2     => ctc_counter,    -- 4MHz/13
      count3     => tape_edge,      -- cassette: one pulse per edge of the tape waveform
      zcto0      => open,
      zcto1      => ctc_zcto1,      -- the baud rate clock of RS232 channel A
      zcto2      => ctc_zcto2       -- ... and of channel B
      );

  -- the Communications board of the FDX/HDX: a Z80 DART on ports 0C (data A), 0D (data B), 0E (control A), 0F (control B)
  dart_cs <= '1' when ( IORQ_n = '0' and M1_n = '1' and A(7 downto 2) = "000011" ) else '0';

  U_DART : entity work.dart
    port map
      (
      clk_cpu => clk_cpu,
      reset   => RESET,
      b_not_a => A(0),
      c_not_d => A(1),
      cs      => dart_cs,
      iorq_n  => IORQ_n,
      rd_n    => RD_n,
      wr_n    => WR_n,
      data_i  => DO,
      stat_a  => dart_stat_a,
      data_a  => dart_data_a,
      stat_b  => dart_stat_b,
      data_b  => dart_data_b,
      clk_a   => ctc_zcto1,
      clk_b   => ctc_zcto2,
      rx_a    => dart_rx_a,
      tx_a    => dart_tx_a,
      rx_b    => dart_rx_b,
      tx_b    => dart_tx_b
      );

  U_MEMORYMAP : entity work.memory_map
    port map
      (
      iobyte    => iobyte,
      sdx_en    => disc_en,
      cpm_sel   => cpm_sel,
      sdx_slot5 => sdx_slot5,
      ram_exp   => ram_exp,
      rom2_ok   => rom2_ok,
      subpage   => subpage,
      addr      => A(15 downto 13),
      se        => se,
      we        => we,
      phys_addr => phys_addr,
      xse       => xse,
      xblk      => xblk
      );

  xram_se     <= xse;
  xram_addr   <= xblk & A(13 downto 0);
  xram_do     <= DO;
  xram_mreq_n <= MREQ_n;
  xram_rd_n   <= RD_n;
  xram_wr_n   <= WR_n;

  -- the ROM 2 sub-page: a write to 0000-1FFF while the OS ROM is there (RELCPMH = 0) sets it, as on the original ROM card
  process ( clk_cpu, RESET_n )
  begin
    if RESET_n = '0' then
      subpage <= "00";
    elsif rising_edge(clk_cpu) then
      if WR_n = '0' and MREQ_n = '0' and A(15 downto 13) = "000" and iobyte(7) = '0' then
        subpage <= DO(1 downto 0);
      end if;
    end if;
  end process;

  U_RAMROM : RamRom
    port map
      (
      address => RAM_ADDR,
      byteena => not RAM_UB_N & not RAM_LB_N,
      clken   => one,
      clock   => CLOCK_50,
      rden    => not RAM_OE_N,
      data    => RAM_D,
      wren    => not RAM_WE_N,
      q       => RAM_Q
      );

  -- INOUT overlay: while a .mtx is mounted the OS tape routine is replaced (OS ROM visible only)
  U_OVL : entity work.mtx_overlay
    port map ( addr => A, hit => ovl_hit, q => ovl_q );
  ovl_use <= '1' when ( ld_s(1) = '1' and ovl_hit = '1' and A(15 downto 13) = "000" and iobyte(7) = '0' ) else '0';

  -- the SDX FDC 05 card decodes 10h..13h (the 1793) and 14h (control latch / status), and nothing else
  -- (schematic: /FDCS = /A7 /A6 /A5 A4 /A3 /A2, /CTLWR and /CTLRD = 14h, all with M1 high and IORQ low)
  fdc_cs <= '1' when (disc_en = '1' and IORQ_n = '0' and M1_n = '1' and A(7 downto 3) = "00010" and
                      (A(2 downto 0) = "000" or A(2 downto 0) = "001" or A(2 downto 0) = "010" or
                       A(2 downto 0) = "011" or A(2 downto 0) = "100")) else '0';
  fdc_a  <= A(2 downto 0);
  fdc_wr <= '1' when WR_n = '0' else '0';
  fdc_rd <= '1' when RD_n = '0' else '0';
  fdc_do <= DO;

  mtx_pop_t    <= pop_r;
  mtx_rewind_t <= rew_r;
  mtx_nm_t     <= nm_r;
  mtx_nm_d     <= nm_dr;
  sv_wr_t      <= sv_r;
  sv_wr_d      <= sv_dr;
  sv_start_t   <= ss_r;
  sv_flush_t   <= sf_r;

  U_Z80 : entity work.T80se
    generic map
      (
      Mode    => 1, -- Fast Z80 (Non-M1 cycles shortened to 3T)
      T2Write => 0, -- WR_n active in T3
      IOWait  => 1  -- Std I/O cycle
      )
    port map
      (
      RESET_n => RESET_n,
      CLK_n   => clk_cpu,
      CLKEN   => one,
      WAIT_n  => xram_wait_n,
      INT_n   => not ctc_interrupt,
      NMI_n   => spec_nmi_n,
      BUSRQ_n => one,
      M1_n    => M1_n,
      MREQ_n  => MREQ_n,
      IORQ_n  => IORQ_n,
      RD_n    => RD_n,
      WR_n    => WR_n,
      RFSH_n  => open,
      HALT_n  => HALT_n,
      BUSAK_n => open,
      A       => A,
      DI      => DI,
      DO      => DO
      );

  U_SPEC : entity work.mtx_speculator
    port map
      (
      clk     => clk_cpu,
      clk50   => CLOCK_50,
      reset_n => RESET_n,
      en      => spec_en,
      a       => A,
      iorq_n  => IORQ_n,
      m1_n    => M1_n,
      rd_n    => RD_n,
      wr_n    => WR_n,
      d_in    => DO,
      int_n   => not ctc_interrupt,
      d_out   => spec_do,
      hit     => spec_hit,
      nmi_n   => spec_nmi_n
      );

  -- memory: 16 bit wide, byte lane picked by A0
  -- while a ROM file is loading the CPU is in reset and the loader owns the memory
  RAM_ADDR <= rom_waddr_hi & rom_waddr(16 downto 1) when rom_loading = '1' else phys_addr(17 downto 13) & A(12 downto 1);
  RAM_LB_N <= '0' when ( rom_loading = '1' and rom_waddr(0) = '0' ) or ( rom_loading = '0' and A(0) = '0' ) else '1';
  RAM_UB_N <= '0' when ( rom_loading = '1' and rom_waddr(0) = '1' ) or ( rom_loading = '0' and A(0) = '1' ) else '1';
  RAM_OE_N <= '0' when ( rom_loading = '0' and RD_n = '0' and MREQ_n = '0' and se = '1'              ) else '1';
  RAM_WE_N <= '0' when ( rom_loading = '1' and rom_we = '1' ) or
                       ( rom_loading = '0' and WR_n = '0' and MREQ_n = '0' and se = '1' and we = '1' ) else '1';
  RAM_D    <= rom_wdata & rom_wdata when rom_loading = '1' else DO & DO;

  -- cassette input: the MTX board makes a pulse on EVERY edge of the tape waveform
  -- (op-amp, then a 4070 XOR of the signal with an RC-delayed copy) and feeds CTC channel 3
  process (clk_cpu)
  begin
    if rising_edge(clk_cpu) then
      ts1 <= tape_in;
      ts2 <= ts1;
      ts3 <= ts2;
      tape_edge <= ts2 xor ts3;
    end if;
  end process;

  tape_out    <= tape_out_r;
  tape_out_we <= tape_out_we_r;
  tape_motor  <= tape_motor_r;

  -- IO writes, and side effects of reads
  process ( clk_cpu, RESET_n )
  begin
    if RESET_n = '0' then
      host_vram_addr     <= "00000000000000";
      host_vram_we       <= '0';
      host_vram_addr_inc <= '0';
      vdp_latched        <= '0';
      vdp_reg_we         <= '0';
      iobyte             <= x"00";      -- stock MTX reset: OS ROM, BASIC, RAM page 0
      drive              <= x"ff";
      tape_motor_r       <= '0';
      tape_out_we_r      <= '0';
      pop_r              <= '0';
      rew_r              <= '0';
      nm_r               <= '0';
      sv_r               <= '0';
      ss_r               <= '0';
      sf_r               <= '0';
    elsif rising_edge(clk_cpu) then
      host_vram_we       <= '0';
      if host_vram_addr_inc = '1' then
        host_vram_addr <= host_vram_addr+1;
      end if;
      host_vram_addr_inc <= '0';
      vdp_reg_we         <= '0';
      tape_out_we_r      <= '0';
      rdy_s <= rdy_s(0) & mtx_ready;
      eof_s <= eof_s(0) & mtx_eof;
      ld_s  <= ld_s(0)  & mtx_loaded;
      nd_s  <= nd_s(0)  & mtx_nodata;
      sb_s  <= sb_s(0)  & sv_busy;
      -- the stream moves on when a read of port 8E has FINISHED, so the byte is stable during it
      if IORQ_n = '0' and RD_n = '0' and A(7 downto 0) = x"8e" then
        rd8e_d <= '1';
      else
        rd8e_d <= '0';
        if rd8e_d = '1' then pop_r <= not pop_r; end if;
      end if;
      if WR_n = '0' and IORQ_n = '0' then
        case A(7 downto 0) is
          when x"00" =>
            -- set the IOBYTE
            iobyte <= DO;
          when x"01" =>
            -- VDP data
            -- present data to VRAM
            -- on next clock it'll be latched
            host_vram_d        <= DO;
            host_vram_we       <= '1';
            host_vram_addr_inc <= '1';
            vdp_latched        <= '0';
          when x"02" =>
            -- VDP control
            if vdp_latched = '0' then
              host_vram_addr(7 downto 0) <= DO;
              vdp_latched <= '1';
            else
              case DO(7 downto 6) is
                when "00" | "01" =>
                  -- set up for reading or writing
                  host_vram_addr(13 downto 8) <= DO(5 downto 0);
                when "10" =>
                  -- write VDP register
                  vdp_reg_number <= DO(2 downto 0);
                  vdp_reg_value  <= host_vram_addr(7 downto 0);
                  vdp_reg_we     <= '1';
                when others =>
              end case;
              vdp_latched <= '0';
            end if;
          when x"03" =>
            -- cassette output
            tape_out_r    <= DO(0);
            tape_out_we_r <= '1';
          when x"05" =>
            -- set keyboard drive
            drive <= DO;
          when x"06" =>
            -- sound data is latched
            -- sound chip notices when port 3 is read
            sound_reg_value <= DO;
          when x"8d" =>
            -- a character of the name asked for (LOAD "NAME"); the core compares it with the tape's
            nm_dr <= DO;
            nm_r  <= not nm_r;
          when x"8e" =>
            -- SAVE: a byte of tape
            sv_dr <= DO;
            sv_r  <= not sv_r;
          when x"8f" =>
            -- bit 0: restart the .mtx stream, bit 1: a tape is being saved from its start, bit 2: write out the
            -- bytes saved so far
            if DO(0) = '1' then rew_r <= not rew_r; end if;
            if DO(1) = '1' then ss_r  <= not ss_r;  end if;
            if DO(2) = '1' then sf_r  <= not sf_r;  end if;
          when x"1f" =>
            -- cassette remote control
            if DO = x"aa" then
              tape_motor_r <= '1';
            elsif DO = x"55" then
              tape_motor_r <= '0';
            end if;
          when others =>
            -- nothing
        end case;
      elsif RD_n = '0' and IORQ_n = '0' then
        case A(7 downto 0) is
          when x"01" =>
            -- VDP data
            host_vram_addr_inc <= '1';
            vdp_latched        <= '0';
          when x"02" =>
            -- VDP status
            vdp_latched <= '0';
          when others =>
            -- nothing
        end case;
      end if;
    end if;
  end process;

  U_JOY : entity work.mtx_joy
    port map ( clk => clk_cpu, drive => drive, joy1 => joy1, joy2 => joy2, sense => joy_sense );

  -- Ensure VDP knows of CPU intent to read status
  vdp_reg_re <= '1' when ( RD_n = '0' and IORQ_n = '0' and A(7 downto 0) = x"02" ) else '0';

  -- Ensure sound chip knows of write register
  sound_reg_we <= '1' when ( RD_n = '0' and IORQ_n = '0' and A(7 downto 0) = x"03" ) else '0';

  -- Ensure CTC knows of CPU intent to write register
  ctc_we <= '1' when ( WR_n = '0' and IORQ_n = '0' and A(7 downto 2) = "000010" ) else '0';

  -- Ensure CTC knows when CPU reads the vector
  ctc_re_vector <= '1' when ( M1_n = '0' and IORQ_n = '0' ) else '0';

  -- input to Z80
  -- combinatorial process rather than deep when-else
  process(M1_n, IORQ_n, MREQ_n, RD_n, se, A, RAM_Q, ctc_vector,
          host_vram_q, vdp_status, sense5, sense6, ctc_data_read, joy_sense,
          ovl_use, ovl_q, mtx_byte, rdy_s, eof_s, nd_s, sb_s, disc_en, fdc_di, spec_hit, spec_do, xse, xram_q,
          dart_data_a, dart_data_b, dart_stat_a, dart_stat_b, col_hit, col_do)
  begin
    if MREQ_n = '0' then
      -- memory read
      if ovl_use = '1' then
        DI <= ovl_q;
      elsif xse = '1' then
        DI <= xram_q;
      elsif se = '1' and A(0) = '0' then
        DI <= RAM_Q( 7 downto 0);
      elsif se = '1' and A(0) = '1' then
        DI <= RAM_Q(15 downto 8);
      else
        DI <= x"FF";    -- open bus: nothing fitted here
      end if;
    elsif IORQ_n = '0' then
      if M1_n = '0' then
        -- interrupt vector
        DI <= ctc_vector & "0";
      else
        -- I/O reads
        if spec_hit = '1' then
          DI <= spec_do;                             -- Speculator RAM (ports 60-7F, E0-FF, xxx11111)
        elsif col_hit = '1' then
          DI <= col_do;                              -- the 80 column board (ports 30h to 33h, 38h, 39h)
        else
        case A(7 downto 0) is
          when x"01" => DI <= host_vram_q;
          when x"02" => DI <= vdp_status;
          when x"03" => DI <= x"03";                 -- sound strobe: bus is not driven
          when x"04" => DI <= x"00";                 -- printer status: no printer
          when x"05" => DI <= sense5 and joy_sense;
          when x"06" => DI <= sense6;
          when x"08"|x"09"|x"0a"|x"0b" => DI <= ctc_data_read;
          when x"0c" => DI <= dart_data_a;
          when x"0d" => DI <= dart_data_b;
          when x"0e" => DI <= dart_stat_a;
          when x"0f" => DI <= dart_stat_b;
          when x"10"|x"11"|x"12"|x"13"|x"14" =>
            if disc_en = '1' then DI <= fdc_di; else DI <= x"FF"; end if;   -- SDX floppy controller
          when x"8d" => DI <= "0000000" & nd_s(1);               -- 1 = the name asked for is not on the tape
          when x"8e" => DI <= mtx_byte;                          -- .mtx stream
          when x"8f" => DI <= "00000" & sb_s(1) & eof_s(1) & rdy_s(1);   -- .mtx stream status, bit 2 = saving
          when others => DI <= x"FF";                -- nothing there
        end case;
        end if;
      end if;
    else
      DI <= x"FF";
    end if;
  end process;

end behavior;
