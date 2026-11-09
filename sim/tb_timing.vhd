-- tb_timing.vhd - how many clock cycles does the OS tape-count loop take on this T80 configuration?
-- The loop (OS 0A72):  INBIT2: DEC A ; JP C,INBIT2   is 4 + 10 = 14 T-states on a real Z80.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.ALL;

entity tb_timing is
  generic (MODE : integer := 1; PSEL : integer := 1);
end tb_timing;

architecture sim of tb_timing is
  type mem_t is array (0 to 255) of std_logic_vector(7 downto 0);
  constant prog : mem_t := (
    0 => x"37",                  -- SCF
    1 => x"3E", 2 => x"00",      -- LD A,0
    3 => x"3D",                  -- L: DEC A
    4 => x"DA", 5 => x"03", 6 => x"00",   -- JP C,L
    others => x"00");
  constant prog2 : mem_t := (
    0 => x"21", 1 => x"00", 2 => x"90",       -- LD HL,9000
    3 => x"3A", 4 => x"00", 5 => x"90",       -- L: LD A,(9000)      13
    6 => x"32", 7 => x"01", 8 => x"90",       --    LD (9001),A      13
    9 => x"C5",                               --    PUSH BC          11
    10 => x"C1",                              --    POP BC           10
    11 => x"CD", 12 => x"40", 13 => x"00",    --    CALL 0040        17   (RET 10 at 0040)
    14 => x"11", 15 => x"01", 16 => x"00",    --    LD DE,0001       10
    17 => x"19",                              --    ADD HL,DE        11
    18 => x"23",                              --    INC HL           6
    19 => x"77",                              --    LD (HL),A        7
    20 => x"7E",                              --    LD A,(HL)        7
    21 => x"18", 22 => x"EC",                 --    JR L             12   (-20 -> 3)
    16#40# => x"C9",
    others => x"00");
  signal clk : std_logic := '0';
  signal rst_n : std_logic := '0';
  signal M1_n, MREQ_n, IORQ_n, RD_n, WR_n : std_logic;
  signal A : std_logic_vector(15 downto 0);
  signal DI, DO : std_logic_vector(7 downto 0);
  signal d1, d2 : std_logic_vector(7 downto 0);
  signal cycles : integer := 0;
  signal last   : integer := 0;
  signal n      : integer := 0;
  signal fetch_d : std_logic := '1';
begin
  clk <= not clk after 125 ns;
  dut : entity work.T80se
    generic map (Mode => MODE, T2Write => 0, IOWait => 1)
    port map (RESET_n => rst_n, CLK_n => clk, CLKEN => '1', WAIT_n => '1', INT_n => '1', NMI_n => '1',
              BUSRQ_n => '1', M1_n => M1_n, MREQ_n => MREQ_n, IORQ_n => IORQ_n, RD_n => RD_n, WR_n => WR_n,
              RFSH_n => open, HALT_n => open, BUSAK_n => open, A => A, DI => DI, DO => DO);
  d1 <= prog(to_integer(unsigned(A(7 downto 0))));
  d2 <= prog2(to_integer(unsigned(A(7 downto 0))));
  DI <= d1 when (PSEL = 1 and MREQ_n = '0' and RD_n = '0' and unsigned(A) < 256) else
        d2 when (PSEL = 2 and MREQ_n = '0' and RD_n = '0' and unsigned(A) < 256) else
        x"00" when (MREQ_n = '0' and RD_n = '0') else x"FF";

  process (clk)
    variable f : std_logic;
  begin
    if rising_edge(clk) then
      cycles <= cycles + 1;
      if M1_n = '0' and MREQ_n = '0' and RD_n = '0' then f := '0'; else f := '1'; end if;
      fetch_d <= f;
      if f = '0' and fetch_d = '1' and PSEL = 2 and cycles > 20 and cycles < 400 then
        report "fetch at " & to_hstring(A) & " cycle " & integer'image(cycles);
      end if;
      if f = '0' and fetch_d = '1' and A = x"0003" then          -- fetch of DEC A / LD A,(9000)
        if last /= 0 and n < 6 then
          report "mode " & integer'image(MODE) & ": DEC A / JP C loop = " & integer'image(cycles - last) & " clock cycles (real Z80: 14 for program 1, 127 for program 2)";
        end if;
        last <= cycles;
        n <= n + 1;
        if n = 7 then finish; end if;
      end if;
    end if;
  end process;

  process begin wait for 1 us; rst_n <= '1'; wait; end process;
end sim;
