--
-- mtx_speculator.vhd - the Memotech Speculator add-on board (Tony Brewer), as drawn in Speculator_Schematic.pdf
--
-- The board is a 2K x 8 RAM (HM6116), a 74LS74 (two flip-flops), a 74LS123 (two monostables) and two PAL14L4:
--
--   IC3 (all terms need IORQ low and M1 high; RD is the /RD pin level, so "RD high" is a write cycle)
--     RAMCS : A6 and A5 both 1 (ports 60-7F and E0-FF), or A4..A0 all 1 (ports 1F, 3F, 5F ... FF)
--     KEYIO : port 7E during a write, or port FE during a read (A7..A1 = 1111111, A0 = 0)
--     NMIWR : port FF during a write
--   IC4 (encodes which of A15..A8 is low into RA2..RA0; RA3 is low for any keyboard cycle)
--     the RAM address is A6..A0 of the port followed by RA3..RA0, A7 is not used
--
--   Port FF write: D0 -> NMIEN, D1 -> NMISEL (both cleared by RESET).
--   The falling edge of the bus /INT starts a 1.5us /IMM pulse (74LS123 IC5A); when that ends, a 1.5us /DEL pulse
--   (IC5B). NMIEN low clears both. /NMI = /DEL when NMISEL is 0, /IMM when NMISEL is 1.
--   Not on the schematic, but needed: setting NMIEN (0 to 1) also starts the NMI sequence, whatever /INT is doing. The
--   Speculator program resets the CTC channels, enables the NMI and then waits for an NMI to start its frame interrupts
--   (its NMI handler re-enables CTC channel 0 on the way out); with nothing to cause the first one it waits for ever and
--   the screen stays black. MEMU does the same ("fake NMI soon" whenever the NMI is enabled), and runs the program.
--
-- With en = '0' the board is not fitted: it never drives the bus and never raises NMI.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity mtx_speculator is
  port
    (
    clk     : in  std_logic;                      -- CPU clock
    clk50   : in  std_logic;                      -- fixed 50MHz, times the two NMI pulses
    reset_n : in  std_logic;
    en      : in  std_logic;                      -- the board is fitted
    a       : in  std_logic_vector(15 downto 0);
    iorq_n  : in  std_logic;
    m1_n    : in  std_logic;
    rd_n    : in  std_logic;
    wr_n    : in  std_logic;
    d_in    : in  std_logic_vector(7 downto 0);   -- data from the Z80
    int_n   : in  std_logic;                      -- the bus /INT line
    d_out   : out std_logic_vector(7 downto 0);   -- RAM data to the Z80
    hit     : out std_logic;                      -- a read the board answers (d_out is valid)
    nmi_n   : out std_logic                       -- to the Z80 /NMI, in the clk domain
    );
end mtx_speculator;

architecture behavior of mtx_speculator is

  type ram_t is array (0 to 2047) of std_logic_vector(7 downto 0);
  signal ram : ram_t := (others => (others => '0'));
  attribute ramstyle : string;
  attribute ramstyle of ram : signal is "MLAB, no_rw_check";   -- read and write never happen in the same cycle

  constant PULSE : integer := 75;                 -- 1.5us in 50MHz clocks

  signal cyc    : std_logic;
  signal ramcs  : std_logic;
  signal keyio  : std_logic;
  signal ra     : std_logic_vector(3 downto 0);
  signal p0, p1, p2 : std_logic;
  signal addr   : std_logic_vector(10 downto 0);

  signal nmien  : std_logic := '0';
  signal nmisel : std_logic := '0';

  signal i1, i2, i_d : std_logic := '1';
  signal e1, e2, e3  : std_logic := '0';
  signal s1, s2      : std_logic := '0';
  signal imm_cnt, del_cnt : integer range 0 to PULSE := 0;
  signal nmi_raw_n   : std_logic := '1';
  signal n1          : std_logic := '1';

begin

  cyc   <= '1' when ( en = '1' and iorq_n = '0' and m1_n = '1' ) else '0';
  ramcs <= '1' when ( cyc = '1' and ( ( a(6) = '1' and a(5) = '1' ) or a(4 downto 0) = "11111" ) ) else '0';
  keyio <= '1' when ( cyc = '1' and a(6 downto 1) = "111111" and a(0) = '0' and
                      ( ( a(7) = '0' and rd_n = '1' ) or ( a(7) = '1' and rd_n = '0' ) ) ) else '0';

  -- IC4 products, each true when RAn is pulled low
  p0 <= ( a(15) and not a(14) ) or
        ( a(15) and a(13) and not a(12) ) or
        ( a(15) and a(13) and a(11) and not a(10) ) or
        ( a(15) and a(13) and a(11) and a(9) and not a(8) );
  p1 <= ( a(15) and a(14) and not a(13) ) or
        ( a(15) and a(14) and not a(12) ) or
        ( a(15) and a(14) and a(11) and a(10) and not a(9) ) or
        ( a(15) and a(14) and a(11) and a(10) and not a(8) );
  p2 <= ( a(15) and a(14) and a(13) and a(12) and not a(11) ) or
        ( a(15) and a(14) and a(13) and a(12) and not a(10) ) or
        ( a(15) and a(14) and a(13) and a(12) and not a(9) ) or
        ( a(15) and a(14) and a(13) and a(12) and not a(8) );

  ra(0) <= not ( keyio and p0 );
  ra(1) <= not ( keyio and p1 );
  ra(2) <= not ( keyio and p2 );
  ra(3) <= not ( keyio or ( ( not a(7) ) and a(0) ) );

  addr <= a(6 downto 0) & ra;

  d_out <= ram(to_integer(unsigned(addr)));
  hit   <= '1' when ( ramcs = '1' and rd_n = '0' ) else '0';

  process (clk)
  begin
    if rising_edge(clk) then
      if ramcs = '1' and wr_n = '0' then
        ram(to_integer(unsigned(addr))) <= d_in;
      end if;
    end if;
  end process;

  -- port FF write: the two flip-flops
  process (clk, reset_n)
  begin
    if reset_n = '0' then
      nmien  <= '0';
      nmisel <= '0';
    elsif rising_edge(clk) then
      if en = '0' then
        nmien  <= '0';
        nmisel <= '0';
      elsif cyc = '1' and a(7 downto 0) = x"FF" and rd_n = '1' and wr_n = '0' then
        nmien  <= d_in(0);
        nmisel <= d_in(1);
      end if;
    end if;
  end process;

  -- the two monostables, in real time
  process (clk50)
  begin
    if rising_edge(clk50) then
      i1 <= int_n;  i2 <= i1;  i_d <= i2;
      e1 <= nmien;  e2 <= e1;  e3 <= e2;
      s1 <= nmisel; s2 <= s1;
      if e2 = '0' then
        imm_cnt <= 0;
        del_cnt <= 0;
      else
        if ( i_d = '1' and i2 = '0' ) or e3 = '0' then   -- /INT falls, or NMIEN has just been set
          imm_cnt <= PULSE;
        elsif imm_cnt /= 0 then
          imm_cnt <= imm_cnt - 1;
        end if;
        if imm_cnt = 1 and not ( ( i_d = '1' and i2 = '0' ) or e3 = '0' ) then
          del_cnt <= PULSE;
        elsif del_cnt /= 0 then
          del_cnt <= del_cnt - 1;
        end if;
      end if;
      if ( s2 = '0' and del_cnt /= 0 ) or ( s2 = '1' and imm_cnt /= 0 ) then
        nmi_raw_n <= '0';
      else
        nmi_raw_n <= '1';
      end if;
    end if;
  end process;

  process (clk)
  begin
    if rising_edge(clk) then
      n1 <= nmi_raw_n;
    end if;
  end process;

  nmi_n <= n1 when en = '1' else '1';

end behavior;
