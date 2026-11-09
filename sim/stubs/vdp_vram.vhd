-- Simulation stand-in for vdp_vram: a plain dual port RAM.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity vdp_vram is
  port
    (
    clk_host  : in  std_logic;
    d_host    : in  std_logic_vector(7 downto 0);
    addr_host : in  std_logic_vector(13 downto 0);
    we_host   : in  std_logic;
    q_host    : out std_logic_vector(7 downto 0);
    clk_vdp   : in  std_logic;
    addr_vdp  : in  std_logic_vector(13 downto 0);
    q_vdp     : out std_logic_vector(7 downto 0)
    );
end vdp_vram;

architecture sim of vdp_vram is
  type ram_t is array (0 to 16383) of std_logic_vector(7 downto 0);
  signal ram : ram_t := (others => x"00");
begin
  process (clk_host) begin
    if rising_edge(clk_host) then
      if we_host = '1' then ram(to_integer(unsigned(addr_host))) <= d_host; end if;
      q_host <= ram(to_integer(unsigned(addr_host)));
    end if;
  end process;
  process (clk_vdp) begin
    if rising_edge(clk_vdp) then q_vdp <= ram(to_integer(unsigned(addr_vdp))); end if;
  end process;
end sim;
