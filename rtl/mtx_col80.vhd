--
-- mtx_col80.vhd - the Memotech 80 column board
--
-- Written from the primary documents: the MTX-FDX Technical Manual (chapter 1, I/O port assignments, and chapter 3, the 80
-- column board) and the board's schematic (80Col_schem.pdf).
--
-- What the board is
--   a Motorola MC6845 CRTC (ports 38h select, 39h data), two 2K x 8 RAMs holding the screen (one byte of ASCII code and one
--   byte of attribute for each of the 80 x 24 character cells), two 2732 character ROMs (alpha and graphics) and a pixel
--   shifter that makes RED, GRN and BLU. The Z80 can reach the screen RAMs only through four latches:
--     port 30h  w  A0..A7 of the cell, and the write of this port starts the access
--     port 31h  w  D0..D2 = A8..A10, D5 write enable for the attribute RAM, D6 write enable for the ASCII RAM,
--                  D7 = 1 a write cycle, 0 a read cycle
--     port 32h  rw the ASCII byte (written by the CPU, or what a read cycle brought in)
--     port 33h  rw the attribute byte (likewise)
--     port 30h  r  rings the bell (no sound is made here)
--   Attribute byte, colour monitor: D0 D1 D2 = red, green, blue of the foreground, D3 D4 D5 = red, green, blue of the
--   background, D6 = blink, D7 = graphics (the graphics character ROM is used in place of the alpha one).
--
-- What is not the same as the board
--   The board scans at 15.6kHz with a 15MHz dot clock. Here the picture is made at 25MHz with 640 x 480 timing: 640 pixels of
--   80 characters, every scan line of the board shown twice. The CRTC registers that say how the screen is built (R1 characters
--   displayed, R6 rows displayed, R9 scan lines per row, R10 R11 the cursor shape and blink, R12 R13 the start address, R14 R15
--   the cursor address) are used; the ones that make up the 15.6kHz timing (R0, R2, R3, R4, R5, R7, R8) are stored and read
--   back but the sync pulses come from the fixed 640 x 480 timing. The monochrome monitor output (MON, and the bits of the
--   attribute that only it uses) is not made. The cursor is shown as the character cell with its pixels inverted on the scan
--   lines R10 to R11, blinking as R10 bits 6 and 5 say; the blink bit of the attribute hides the character at the same rate as the
--   slow cursor blink.
--
-- Character ROM image (the file is 8KB: the graphics ROM 0000..0FFF, then the alpha ROM 1000..1FFF; 16 bytes per character,
-- bit 7 is the leftmost pixel). The loader writes it through cg_we, cg_addr, cg_data on clk_ld.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- 2K x 8 RAM: port A reads and writes (CPU side), port B reads only (video side)
entity mtx_col80_ram is
  port
    (
    clk_a  : in  std_logic;
    we_a   : in  std_logic;
    addr_a : in  std_logic_vector(10 downto 0);
    d_a    : in  std_logic_vector(7 downto 0);
    q_a    : out std_logic_vector(7 downto 0);
    clk_b  : in  std_logic;
    addr_b : in  std_logic_vector(10 downto 0);
    q_b    : out std_logic_vector(7 downto 0)
    );
end mtx_col80_ram;

architecture behavior of mtx_col80_ram is
  type ram_type is array (0 to 2047) of std_logic_vector(7 downto 0);
  signal r : ram_type := (others => (others => '0'));
  attribute ramstyle : string;
  attribute ramstyle of r : signal is "no_rw_check";
begin
  process ( clk_a )
  begin
    if rising_edge(clk_a) then
      if we_a = '1' then
        r(to_integer(unsigned(addr_a))) <= d_a;
      end if;
      q_a <= r(to_integer(unsigned(addr_a)));
    end if;
  end process;

  process ( clk_b )
  begin
    if rising_edge(clk_b) then
      q_b <= r(to_integer(unsigned(addr_b)));
    end if;
  end process;
end behavior;


-- the character ROM: written by the loader (clk_w), read by the video (clk_r)
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mtx_col80_cg is
  port
    (
    clk_w  : in  std_logic;
    we     : in  std_logic;
    addr_w : in  std_logic_vector(12 downto 0);
    d_w    : in  std_logic_vector(7 downto 0);
    clk_r  : in  std_logic;
    addr_r : in  std_logic_vector(12 downto 0);
    q_r    : out std_logic_vector(7 downto 0)
    );
end mtx_col80_cg;

architecture behavior of mtx_col80_cg is
  type ram_type is array (0 to 8191) of std_logic_vector(7 downto 0);
  signal r : ram_type := (others => (others => '0'));
begin
  process ( clk_w )
  begin
    if rising_edge(clk_w) then
      if we = '1' then
        r(to_integer(unsigned(addr_w))) <= d_w;
      end if;
    end if;
  end process;

  process ( clk_r )
  begin
    if rising_edge(clk_r) then
      q_r <= r(to_integer(unsigned(addr_r)));
    end if;
  end process;
end behavior;


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mtx_col80 is
  port
    (
    -- the CPU side
    clk_cpu   : in  std_logic;
    reset     : in  std_logic;                      -- 1 = reset
    en        : in  std_logic;                      -- the board is fitted
    a         : in  std_logic_vector(7 downto 0);   -- I/O address A7..A0
    wr_io     : in  std_logic;                      -- an I/O write cycle (not an interrupt acknowledge)
    d_in      : in  std_logic_vector(7 downto 0);   -- data from the Z80
    d_out     : out std_logic_vector(7 downto 0);   -- data to the Z80 for an I/O read
    hit       : out std_logic;                      -- the address is one the board answers on a read
    crtc_prog : out std_logic;                      -- the CRTC has been programmed since reset (clk_cpu domain)
    -- character ROM load
    clk_ld    : in  std_logic;
    cg_we     : in  std_logic;
    cg_addr   : in  std_logic_vector(12 downto 0);
    cg_data   : in  std_logic_vector(7 downto 0);
    -- video, 640 x 480 at 25MHz
    clk_vid   : in  std_logic;
    frame_60  : in  std_logic;                      -- 0 = 50Hz (625 lines), 1 = 60Hz (525 lines)
    vga_r, vga_g, vga_b : out std_logic_vector(3 downto 0);
    vga_hs, vga_vs      : out std_logic;
    vga_hb, vga_vb      : out std_logic
    );
end mtx_col80;

architecture behavior of mtx_col80 is

  type crtc_array is array (0 to 17) of std_logic_vector(7 downto 0);
  signal crtc : crtc_array := (others => (others => '0'));
  signal sel  : std_logic_vector(4 downto 0) := (others => '0');

  signal p30, p31, d32, d33 : std_logic_vector(7 downto 0) := (others => '0');
  signal s1, s2 : std_logic := '0';
  signal prog   : std_logic := '0';
  signal wr_en  : std_logic;

  signal ram_addr_a : std_logic_vector(10 downto 0);
  signal we_asc, we_atr : std_logic;
  signal qa_asc, qa_atr : std_logic_vector(7 downto 0);

  -- video
  signal h : unsigned(9 downto 0) := (others => '0');
  signal v : unsigned(9 downto 0) := (others => '0');
  signal vtot : unsigned(9 downto 0) := to_unsigned(525, 10);
  signal fcnt : unsigned(5 downto 0) := (others => '0');

  signal ra       : unsigned(4 downto 0) := (others => '0');        -- scan line within the character row
  signal crow     : unsigned(5 downto 0) := (others => '0');        -- character row
  signal ma_row   : unsigned(10 downto 0) := (others => '0');       -- display address of the first character of the row
  signal vis_next, line_vis : std_logic := '0';

  signal ma_q     : std_logic_vector(10 downto 0) := (others => '0');
  signal qb_asc, qb_atr : std_logic_vector(7 downto 0);
  signal cg_q     : std_logic_vector(7 downto 0);
  signal cg_ra    : std_logic_vector(12 downto 0) := (others => '0');
  signal atr_next, atr_cur : std_logic_vector(7 downto 0) := (others => '0');
  signal glyph_next : std_logic_vector(7 downto 0) := (others => '0');
  signal shift    : std_logic_vector(7 downto 0) := (others => '0');
  signal cur_hit_next, cur_next, cur_cur : std_logic := '0';

  signal r1_c, r6_c, r9_c, r10_c, r11_c, r12_c, r13_c, r14_c, r15_c : std_logic_vector(7 downto 0);
  signal slot     : unsigned(6 downto 0);
  signal hact, pix_on : std_logic;
  signal cur_on   : std_logic;

  signal red_o, grn_o, blu_o : std_logic := '0';
  signal hs_i, vs_i, hb_i, vb_i : std_logic := '0';

begin

  wr_en <= wr_io and en;

  ---------------------------------------------------------------------------------------------------------------------------
  -- the CPU side: the ports, and the screen RAM access
  ---------------------------------------------------------------------------------------------------------------------------
  process ( clk_cpu )
  begin
    if rising_edge(clk_cpu) then
      s1 <= '0';
      s2 <= s1;
      if reset = '1' then
        prog <= '0';
        sel  <= (others => '0');
      else
        if wr_en = '1' then
          case a is
            when x"30" => p30 <= d_in; s1 <= '1';
            when x"31" => p31 <= d_in;
            when x"32" => d32 <= d_in;
            when x"33" => d33 <= d_in;
            when x"38" => sel <= d_in(4 downto 0);
            when x"39" =>
              prog <= '1';
              if to_integer(unsigned(sel)) <= 17 then
                crtc(to_integer(unsigned(sel))) <= d_in;
              end if;
            when others => null;
          end case;
        end if;
        -- a read cycle brings the two bytes into the latches (the RAM output is there one clock after the access)
        if s2 = '1' and p31(7) = '0' then
          d32 <= qa_asc;
          d33 <= qa_atr;
        end if;
      end if;
    end if;
  end process;

  ram_addr_a <= p31(2 downto 0) & p30;
  we_asc <= s1 and p31(7) and p31(6);
  we_atr <= s1 and p31(7) and p31(5);

  U_ASC : entity work.mtx_col80_ram
    port map ( clk_a => clk_cpu, we_a => we_asc, addr_a => ram_addr_a, d_a => d32, q_a => qa_asc,
               clk_b => clk_vid, addr_b => ma_q, q_b => qb_asc );
  U_ATR : entity work.mtx_col80_ram
    port map ( clk_a => clk_cpu, we_a => we_atr, addr_a => ram_addr_a, d_a => d33, q_a => qa_atr,
               clk_b => clk_vid, addr_b => ma_q, q_b => qb_atr );

  crtc_prog <= prog;

  hit <= en when ( a = x"30" or a = x"31" or a = x"32" or a = x"33" or a = x"38" or a = x"39" ) else '0';

  process ( a, d32, d33, crtc, sel )
  begin
    d_out <= x"FF";
    case a is
      when x"32" => d_out <= d32;
      when x"33" => d_out <= d33;
      when x"38" => d_out <= x"00";                           -- the 6845 has no status register
      when x"39" =>
        if sel = "01110" then d_out <= crtc(14);
        elsif sel = "01111" then d_out <= crtc(15);
        else d_out <= x"00";                                  -- the other registers cannot be read (R16, R17: light pen)
        end if;
      when others => d_out <= x"FF";                          -- port 30h: the bell
    end case;
  end process;

  ---------------------------------------------------------------------------------------------------------------------------
  -- the video
  ---------------------------------------------------------------------------------------------------------------------------
  U_CG : entity work.mtx_col80_cg
    port map ( clk_w => clk_ld, we => cg_we, addr_w => cg_addr, d_w => cg_data,
               clk_r => clk_vid, addr_r => cg_ra, q_r => cg_q );

  r1_c  <= crtc(1);  r6_c  <= crtc(6);  r9_c  <= crtc(9);  r10_c <= crtc(10); r11_c <= crtc(11);
  r12_c <= crtc(12); r13_c <= crtc(13); r14_c <= crtc(14); r15_c <= crtc(15);

  slot <= h(9 downto 3);
  hact <= '1' when ( h < 640 and h(9 downto 3) < unsigned(r1_c(6 downto 0)) ) else '0';
  pix_on <= hact and line_vis;

  -- the cursor blink: R10 bits 6 and 5: 00 steady, 01 off, 10 blinks at 1/16 and 11 at 1/32 of the field rate
  with r10_c(6 downto 5) select
    cur_on <= '1'          when "00",
              '0'          when "01",
              fcnt(3)      when "10",
              fcnt(4)      when others;

  process ( clk_vid )
    variable ma_n : unsigned(10 downto 0);
    variable col  : std_logic_vector(2 downto 0);
    variable px   : std_logic;
  begin
    if rising_edge(clk_vid) then
      ---------------------------------------------------------------- the raster
      if h = 799 then
        h <= (others => '0');
        if v = vtot - 1 then
          v <= (others => '0');
        else
          v <= v + 1;
        end if;
        line_vis <= vis_next;
      else
        h <= h + 1;
      end if;

      if h = 0 then
        if v = vtot - 1 then
          if frame_60 = '1' then vtot <= to_unsigned(525, 10); else vtot <= to_unsigned(625, 10); end if;
        end if;
      end if;

      -- sync, blanking (one clock late like the pixels)
      if h >= 656 and h < 752 then hs_i <= '1'; else hs_i <= '0'; end if;
      if h >= 640 then hb_i <= '1'; else hb_i <= '0'; end if;
      if v >= 480 then vb_i <= '1'; else vb_i <= '0'; end if;
      if frame_60 = '1' then
        if v >= 490 and v < 492 then vs_i <= '1'; else vs_i <= '0'; end if;
      else
        if v >= 520 and v < 522 then vs_i <= '1'; else vs_i <= '0'; end if;
      end if;
      if h = 0 and v = 480 then fcnt <= fcnt + 1; end if;

      ---------------------------------------------------------------- the row counters, for the NEXT line
      if h = 700 then
        if v = vtot - 1 then
          ra <= (others => '0');
          crow <= (others => '0');
          ma_row <= unsigned(r12_c(2 downto 0)) & unsigned(r13_c);
        elsif v(0) = '1' then                      -- every scan line of the board is shown twice
          if ra = unsigned(r9_c(4 downto 0)) then
            ra <= (others => '0');
            crow <= crow + 1;
            ma_row <= ma_row + unsigned(r1_c);
          else
            ra <= ra + 1;
          end if;
        end if;
      end if;
      if h = 701 then
        if ( v = vtot - 1 or v < 479 ) and crow < unsigned(r6_c(5 downto 0)) then
          vis_next <= '1';
        else
          vis_next <= '0';
        end if;
      end if;

      ---------------------------------------------------------------- the character pipeline (8 clocks per character)
      -- clock 0: the display address of the next character; 1: the RAMs read; 2: the ASCII byte gives the character ROM address;
      -- 3: the ROM reads; 5: the glyph is kept; 7: it goes into the shift register
      case h(2 downto 0) is
        when "000" =>
          if slot = 99 then
            ma_n := ma_row;
          else
            ma_n := ma_row + resize(slot + 1, 11);
          end if;
          ma_q <= std_logic_vector(ma_n);
        when "010" =>
          cg_ra <= (not qb_atr(7)) & qb_asc & std_logic_vector(ra(3 downto 0));
          atr_next <= qb_atr;
          if ma_q = std_logic_vector(unsigned(r14_c(2 downto 0)) & unsigned(r15_c)) then
            cur_hit_next <= '1';
          else
            cur_hit_next <= '0';
          end if;
        when "101" =>
          glyph_next <= cg_q;
        when "111" =>
          shift <= glyph_next;
          atr_cur <= atr_next;
          if cur_hit_next = '1' and cur_on = '1' and ra >= unsigned(r10_c(4 downto 0)) and ra <= unsigned(r11_c(4 downto 0)) then
            cur_cur <= '1';
          else
            cur_cur <= '0';
          end if;
        when others => null;
      end case;
      if h(2 downto 0) /= "111" then
        shift <= shift(6 downto 0) & '0';
      end if;
      -- (the assignment of "111" above wins over this one, which is not executed then)

      ---------------------------------------------------------------- the pixel
      px := shift(7);
      if atr_cur(6) = '1' and fcnt(4) = '1' then px := '0'; end if;
      px := px xor cur_cur;
      if px = '1' then col := atr_cur(2 downto 0); else col := atr_cur(5 downto 3); end if;
      if pix_on = '1' then
        red_o <= col(0); grn_o <= col(1); blu_o <= col(2);
      else
        red_o <= '0'; grn_o <= '0'; blu_o <= '0';
      end if;
    end if;
  end process;

  vga_r <= (others => red_o);
  vga_g <= (others => grn_o);
  vga_b <= (others => blu_o);
  vga_hs <= hs_i;
  vga_vs <= vs_i;
  vga_hb <= hb_i;
  vga_vb <= vb_i;

end behavior;
