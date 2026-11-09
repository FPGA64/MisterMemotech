--
-- clock_divider.vhd - Generate CPU related clocks
--
-- In a real Memotech
--   CPU clock is 4MHz (the crystal, schematic p47 of the service manual)
--   CTC timer input is 4MHz
--   CTC counter input for two channels is 4MHz/13, ie: 0.307692MHz
--   the sound chip is clocked by the same 4MHz (its pitch is 4MHz/(32 n))
--
-- 50MHz / 4MHz = 12.5, so the stock CPU clock is made of cycles that are alternately 12 and 13 clocks of 50MHz
-- long. The average is exactly 4.000MHz (200 clocks of 50MHz are 16 CPU cycles), a single cycle is 4% off,
-- which a Z80 does not care about. Everything stays on the 50MHz clock, so there is no new clock domain.
-- The CTC timer input (4MHz/16 = 250kHz) is exact; the counter input 4MHz/13 is made of half periods of
-- 81, 81, 81, 82 clocks (average 81.25, exactly 50MHz/162.5 = 0.307692MHz).
--
-- The other CPU speeds are plain divisions of 50MHz:
--   CPU clock is 25, 12.5, 8.333, 6.25, 5, 4.000 (stock), 3.571, 3.125 MHz
--
-- We need to run the CTC timer speed at 4MHz, despite the fact the processor may be running faster, as programs
-- use it for timing purposes.
--
-- The 4MHz/13 counter inputs end up driving the serial ports.
--
-- We generate a 4MHz clock used by the I2C loader only.
-- We generate a 1MHz clock which we use when reading the PS/2 keyboard.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;

entity clock_divider is
  port
    (
    clk_50mhz   : in  std_logic;
    div_cpu     : in  std_logic_vector(2 downto 0); -- Turbo buttons!
      -- 000 => 25.000MHz
      -- 001 => 12.500MHz
      -- 010 =>  8.333MHz
      -- 011 =>  6.250MHz
      -- 100 =>  5.000MHz
      -- 101 =>  4.000MHz (exact on average, see above)
      -- 110 =>  3.571MHz
      -- 111 =>  3.125MHz
    clk_cpu     : out std_logic; -- CPU speed
    clk_timer16 : out std_logic; -- CTC Timer input, pre divided by 16
    clk_counter : out std_logic; -- CTC Counter input (two channels)
    clk_25mhz   : out std_logic; -- VGA dot clock
    clk_4mhz    : out std_logic; -- for I2C loader only
    clk_1mhz    : out std_logic  -- for reading the PS/2 keyboard
    );
end clock_divider;

architecture behavior of clock_divider is

  signal counter_cpu     : std_logic_vector(2 downto 0) := "000";
  signal clk_cpu_int     : std_logic := '0';
  signal cpu_odd         : std_logic := '0';                  -- stock speed: every other cycle is 13 clocks, not 12
  signal counter_cnt_ph  : std_logic_vector(1 downto 0) := "00";
  signal counter_timer16 : std_logic_vector(6 downto 0) := "0000000";
  signal clk_timer16_int : std_logic := '0';
  signal counter_counter : std_logic_vector(6 downto 0) := "0000000";
  signal clk_counter_int : std_logic := '0';
  signal clk_25mhz_int   : std_logic := '0';
  signal counter_4mhz    : std_logic_vector(2 downto 0) := "000";
  signal clk_4mhz_int    : std_logic := '0';
  signal counter_1mhz    : std_logic_vector(4 downto 0) := "00000";
  signal clk_1mhz_int    : std_logic := '0';

begin

  process ( clk_50mhz )
  begin
    if rising_edge(clk_50mhz) then

      clk_cpu <= clk_cpu_int;
      if counter_cpu = "000" then
        clk_cpu_int <= not clk_cpu_int;
        if div_cpu = "101" then
          -- stock: 6 clocks high, then 6 low, 6 high, 7 low, ... = cycles of 12 and 13 clocks
          if clk_cpu_int = '1' then
            -- going low: the long low phase every other cycle
            counter_cpu <= "101";
            if cpu_odd = '1' then counter_cpu <= "110"; end if;
            cpu_odd <= not cpu_odd;
          else
            counter_cpu <= "101";
          end if;
        else
          counter_cpu <= div_cpu;
        end if;
      else
        counter_cpu <= counter_cpu-1;
      end if;

      clk_timer16 <= clk_timer16_int;
      if counter_timer16 = "0000000" then
        clk_timer16_int <= not clk_timer16_int;
        counter_timer16 <= "1100011"; -- 99, as 25MHz/(99+1)=250kHz=4MHz/16
      else
        counter_timer16 <= counter_timer16-1;
      end if;

      clk_counter <= clk_counter_int;
      if counter_counter = "0000000" then
        clk_counter_int <= not clk_counter_int;
        counter_cnt_ph  <= counter_cnt_ph + 1;
        if counter_cnt_ph = "11" then
          counter_counter <= "1010001"; -- 81, so that the half periods are 81, 81, 81, 82 clocks:
        else                            -- average 81.25 = 50MHz/162.5 half period, 0.307692MHz = 4MHz/13
          counter_counter <= "1010000"; -- 80
        end if;
      else
        counter_counter <= counter_counter-1;
      end if;

      clk_25mhz     <= clk_25mhz_int;
      clk_25mhz_int <= not clk_25mhz_int;

      clk_4mhz <= clk_4mhz_int;
      if counter_4mhz = "000" then
        clk_4mhz_int <= not clk_4mhz_int;
        counter_4mhz <= "101"; -- 5, as 25MHz/(5+1)=4.166MHz
      else
        counter_4mhz <= counter_4mhz-1;
      end if;

      clk_1mhz <= clk_1mhz_int;
      if counter_1mhz = "00000" then
        clk_1mhz_int <= not clk_1mhz_int;
        counter_1mhz <= "11000"; -- 24, as 25MHz/(24+1)=1MHz
      else
        counter_1mhz <= counter_1mhz-1;
      end if;

    end if;

  end process;

end behavior;
