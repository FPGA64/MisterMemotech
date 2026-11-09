--
-- mtx_joy.vhd - the two joystick ports of the MTX, which are wired into the keyboard matrix
--
-- Schematic (MTX 500 4000-04), connectors J4 and J5:
--   J4, joystick 1: the cursor keypad. Common line is sense KB7, the directions go to drive lines
--       left DR3, down DR6, up DR2, right DR4, fire (HOME) DR5.
--   J5, joystick 2: common line is drive DR7, the directions go to sense lines
--       left KB2, down KB3, up KB0, right KB1, fire KB4.
-- Pressing a direction connects its two lines, exactly like a key at that point of the matrix.
-- Drive lines are active low: a line is selected when its bit of port 5 is 0.
--
-- sense is ANDed with the keyboard's sense5 (port 5 reads KB7..KB0).
--
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity mtx_joy is
  port
    (
    clk   : in  std_logic;
    drive : in  std_logic_vector(7 downto 0);
    joy1  : in  std_logic_vector(4 downto 0);   -- 0 up, 1 down, 2 left, 3 right, 4 fire (any clock domain)
    joy2  : in  std_logic_vector(4 downto 0);
    sense : out std_logic_vector(7 downto 0)    -- 0 = a line is pulled low by a joystick
    );
end mtx_joy;

architecture behavior of mtx_joy is
  signal j1, j1s, j2, j2s : std_logic_vector(4 downto 0) := (others => '0');
begin
  process (clk)
  begin
    if rising_edge(clk) then
      j1 <= joy1;  j1s <= j1;
      j2 <= joy2;  j2s <= j2;
    end if;
  end process;

  sense(7) <= not ( (j1s(0) and not drive(2)) or (j1s(1) and not drive(6)) or
                    (j1s(2) and not drive(3)) or (j1s(3) and not drive(4)) or
                    (j1s(4) and not drive(5)) );
  sense(6 downto 5) <= "11";
  sense(4) <= not ( j2s(4) and not drive(7) );   -- fire
  sense(3) <= not ( j2s(1) and not drive(7) );   -- down
  sense(2) <= not ( j2s(2) and not drive(7) );   -- left
  sense(1) <= not ( j2s(3) and not drive(7) );   -- right
  sense(0) <= not ( j2s(0) and not drive(7) );   -- up
end behavior;
