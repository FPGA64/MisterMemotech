-- tb_kbd_bs.vhd - PC BackSpace on the MTX keyboard: BS then DEL, and Shift+BackSpace = BS only.
-- Watches the BS key (row 1) or the DEL key (row 3) as the CPU sees them on sense6 bit 0, generic ROW.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_kbd_bs is
  generic (ROW : integer := 1; SHIFTED : integer := 0);
end tb_kbd_bs;

architecture sim of tb_kbd_bs is
  signal clk        : std_logic := '0';
  signal key_ready  : std_logic := '0';
  signal key_stroke : std_logic := '1';
  signal key_code   : std_logic_vector(9 downto 0) := (others => '0');
  signal drive      : std_logic_vector(7 downto 0) := (others => '1');
  signal sense5     : std_logic_vector(7 downto 0);
  signal sense6     : std_logic_vector(7 downto 0);
  signal extra      : std_logic_vector(13 downto 0);
  signal t_dn       : time := 0 ns;
  signal downs      : integer := 0;
begin
  clk <= not clk after 10 ns;                           -- 50 MHz

  dut : entity work.mtx_kbd
    port map (clk_1mhz => clk, key_ready => key_ready, key_stroke => key_stroke, key_code => key_code,
              drive => drive, sense5 => sense5, sense6 => sense6, extra_keys => extra);

  drive <= (others => '1') when false else
           std_logic_vector(to_unsigned(255 - 2**ROW, 8));      -- only this row low

  -- log every change of the key as the CPU sees it
  process (sense6)
  begin
    if sense6(0) = '0' then
      t_dn <= now; downs <= downs + 1;
      report "key " & integer'image(ROW) & " DOWN at " & time'image(now);
    elsif now > 0 ns then
      report "key " & integer'image(ROW) & " UP   at " & time'image(now) & "  (was down " & time'image(now - t_dn) & ")";
    end if;
  end process;

  stim : process
    procedure ps2(code : std_logic_vector(9 downto 0); stroke : std_logic) is
    begin
      wait until rising_edge(clk);
      key_code <= code; key_stroke <= stroke; key_ready <= '1';
      wait until rising_edge(clk);
      key_ready <= '0';
    end procedure;
  begin
    wait for 1 us;
    if SHIFTED = 1 then ps2("00" & x"12", '0'); wait for 1 us; end if;      -- LeftShift down
    ps2("00" & x"66", '0');                                                  -- BackSpace down
    wait for 5 ms;
    ps2("00" & x"66", '1');                                                  -- BackSpace up
    wait for 5 ms;
    if SHIFTED = 1 then ps2("00" & x"12", '1'); end if;
    wait for 300 ms;                                                         -- let the sequence finish
    report "presses seen on this key: " & integer'image(downs);
    std.env.finish;
  end process;
end sim;
