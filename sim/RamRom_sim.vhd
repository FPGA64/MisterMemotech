-- RamRom_sim.vhd - simulation model of the altsyncram wrapper RamRom (128K x 16, byte enables)
-- Behaves like altsyncram single port, unregistered output: the address is registered on
-- the clock edge and q follows the registered address.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity RamRom is
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
end RamRom;

architecture sim of RamRom is
  type mem_t is array (0 to 131071) of std_logic_vector(15 downto 0);
  signal mem    : mem_t := (others => (others => '0'));
  signal addr_r : integer range 0 to 131071 := 0;
begin
  process (clock)
  begin
    if rising_edge(clock) then
      if clken = '1' then
        if wren = '1' then
          if byteena(0) = '1' then mem(to_integer(unsigned(address)))(7 downto 0)  <= data(7 downto 0);  end if;
          if byteena(1) = '1' then mem(to_integer(unsigned(address)))(15 downto 8) <= data(15 downto 8); end if;
        end if;
        if rden = '1' or wren = '1' then
          addr_r <= to_integer(unsigned(address));
        end if;
      end if;
    end if;
  end process;
  q <= mem(addr_r);
end sim;
