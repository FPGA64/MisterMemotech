-- Simulation stand-in for clock_divider: same entity, no 50MHz counters (they are slow to simulate).
-- clk_cpu 4.000MHz, CTC timer input 4MHz/16 = 250kHz, CTC counter input 4MHz/13 = 0.3077MHz (see rtl/clock_divider.vhd).
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity clock_divider is
  port
    (
    clk_50mhz   : in  std_logic;
    div_cpu     : in  std_logic_vector(2 downto 0);
    clk_cpu     : out std_logic;
    clk_timer16 : out std_logic;
    clk_counter : out std_logic;
    clk_25mhz   : out std_logic;
    clk_4mhz    : out std_logic;
    clk_1mhz    : out std_logic
    );
end clock_divider;

architecture sim of clock_divider is
  signal c, t, k : std_logic := '0';
begin
  c <= not c after 125 ns;
  t <= not t after 2000 ns;
  k <= not k after 1625 ns;
  clk_cpu     <= c;
  clk_timer16 <= t;
  clk_counter <= k;
  clk_25mhz   <= '0';
  clk_4mhz    <= '0';
  clk_1mhz    <= '0';
end sim;
