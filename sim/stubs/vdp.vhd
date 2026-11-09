-- Simulation stand-in for the VDP: registers, a frame flag every 20ms, no video.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity vdp is
  port
    (
    clk_25mhz     : in  std_logic;
    vram_addr     : out std_logic_vector(13 downto 0);
    vram_q        : in  std_logic_vector(7 downto 0);
    clk_cpu       : in  std_logic;
    reg_re        : in  std_logic;
    reg_we        : in  std_logic;
    reg_number    : in  std_logic_vector(2 downto 0);
    reg_value     : in  std_logic_vector(7 downto 0);
    status        : out std_logic_vector(7 downto 0);
    interrupt     : out std_logic;
    hw_pal        : in  std_logic;
    frame_rate    : in  std_logic;
    debug_patnam  : in  std_logic;
    debug_patgen  : in  std_logic;
    debug_patcol  : in  std_logic;
    debug_sprgen  : in  std_logic;
    vga_r         : out std_logic_vector(3 downto 0);
    vga_g         : out std_logic_vector(3 downto 0);
    vga_b         : out std_logic_vector(3 downto 0);
    vga_hsync     : out std_logic;
    vga_vsync     : out std_logic;
    vga_hblank    : out std_logic;
    vga_vblank    : out std_logic
    );
end vdp;

architecture sim of vdp is
  type regs_t is array (0 to 7) of std_logic_vector(7 downto 0);
  signal regs  : regs_t := (others => x"00");
  signal frame : std_logic := '0';
  signal frame_clk : std_logic := '0';
begin
  vram_addr <= (others => '0');
  vga_r <= x"0"; vga_g <= x"0"; vga_b <= x"0";
  vga_hsync <= '0'; vga_vsync <= '0'; vga_hblank <= '0'; vga_vblank <= '0';
  frame_clk <= not frame_clk after 10 ms;          -- 50Hz frames
  status <= frame & "0000000";

  process (clk_cpu)
    variable prev : std_logic := '0';
  begin
    if rising_edge(clk_cpu) then
      if reg_we = '1' then regs(to_integer(unsigned(reg_number))) <= reg_value; end if;
      if frame_clk = '1' and prev = '0' then frame <= '1'; end if;
      prev := frame_clk;
      if reg_re = '1' then frame <= '0'; end if;
    end if;
  end process;
  interrupt <= frame and regs(1)(5);
end sim;
