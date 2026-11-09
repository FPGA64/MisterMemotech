-- tb_kbd_break.vhd - the BREAK key (row 0, column 8, sense6 bit 0) from its four PC keys: Num * (00 7C), Scroll Lock (00 7E),
-- Ctrl+Pause (extended 7E) and Pause (extended 77). The MiSTer reports Pause as a press and never a release, so the core holds BREAK
-- for 100000 ticks of clk_1mhz and lets go by itself. Here clk_1mhz is a 50MHz clock, so that is 2 ms.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_kbd_break is
end tb_kbd_break;

architecture sim of tb_kbd_break is
  signal clk        : std_logic := '0';
  signal key_ready  : std_logic := '0';
  signal key_stroke : std_logic := '1';
  signal key_code   : std_logic_vector(9 downto 0) := (others => '0');
  signal drive      : std_logic_vector(7 downto 0) := x"FE";       -- row 0 low
  signal sense5     : std_logic_vector(7 downto 0);
  signal sense6     : std_logic_vector(7 downto 0);
  signal extra      : std_logic_vector(13 downto 0);
  signal downs      : integer := 0;
  signal t_dn       : time := 0 ns;
  signal last_down  : time := 0 ns;
begin
  clk <= not clk after 10 ns;

  dut : entity work.mtx_kbd
    port map (clk_1mhz => clk, key_ready => key_ready, key_stroke => key_stroke, key_code => key_code,
              drive => drive, sense5 => sense5, sense6 => sense6, extra_keys => extra);

  process (sense6)
  begin
    if sense6(0) = '0' then
      t_dn <= now; downs <= downs + 1;
    elsif now > 0 ns then
      last_down <= now - t_dn;
    end if;
  end process;

  stim : process
    variable errors : integer := 0;
    variable d0 : integer;
    procedure ps2(code : std_logic_vector(9 downto 0); stroke : std_logic) is
    begin
      wait until rising_edge(clk);
      key_code <= code; key_stroke <= stroke; key_ready <= '1';
      wait until rising_edge(clk);
      key_ready <= '0';
    end procedure;
    procedure chk(c : boolean; what : string) is
    begin
      if not c then report "FAIL: " & what severity error; errors := errors + 1; end if;
    end procedure;
  begin
    wait for 1 us;
    chk(sense6(0) = '1', "BREAK up at the start");
    -- Num * press and release
    d0 := downs; ps2("00" & x"7c", '0'); wait for 300 us; chk(sense6(0) = '0', "Num * down"); ps2("00" & x"7c", '1'); wait for 5 us;
    chk(sense6(0) = '1', "Num * up"); chk(downs = d0 + 1, "Num * counted once");
    -- Scroll Lock
    d0 := downs; ps2("00" & x"7e", '0'); wait for 300 us; chk(sense6(0) = '0', "Scroll Lock down"); ps2("00" & x"7e", '1'); wait for 5 us;
    chk(sense6(0) = '1', "Scroll Lock up");
    -- Ctrl+Pause
    ps2("01" & x"7e", '0'); wait for 300 us; chk(sense6(0) = '0', "Ctrl+Pause down"); ps2("01" & x"7e", '1'); wait for 5 us;
    chk(sense6(0) = '1', "Ctrl+Pause up");
    -- Pause: a press only; BREAK must go down at once and come up by itself after about 2 ms (100000 ticks)
    d0 := downs; ps2("01" & x"77", '0'); wait for 100 us;
    chk(sense6(0) = '0', "Pause down");
    wait for 1500 us;
    chk(sense6(0) = '0', "Pause still down at 1.6 ms");
    wait for 1000 us;
    chk(sense6(0) = '1', "Pause let go by itself after about 2 ms");
    chk(downs = d0 + 1, "Pause counted once");
    chk(last_down > 1900 us and last_down < 2100 us, "Pause held about 2 ms (100000 ticks of 20 ns): " & time'image(last_down));
    -- NumLock (the other 77) is PAGE, not BREAK
    d0 := downs; ps2("00" & x"77", '0'); wait for 100 us; chk(sense6(0) = '1', "NumLock is not BREAK"); ps2("00" & x"77", '1'); wait for 5 us;
    chk(downs = d0, "NumLock did not press BREAK");
    if errors = 0 then report "BREAK KEYS TEST PASSED"; else report "BREAK KEYS TEST FAILED" severity failure; end if;
    std.env.finish;
  end process;
end sim;
