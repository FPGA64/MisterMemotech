-- tb_kbd_cond.vhd - CP/M key shaping (cpm_mode = 1): a very short tap is stretched to 60 ms, a key held down is released after 90 ms and
-- repeats after 450 ms every 60 ms, two taps of a key have a gap of at least 40 ms, a shift key is NOT shaped, and without cpm_mode keys pass
-- as they are. The key is S (PS/2 1B): row 4, column 1, so sense5 bit 1 with drive row 4 low.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tb_kbd_cond is
end tb_kbd_cond;

architecture sim of tb_kbd_cond is
  signal clk        : std_logic := '0';
  signal key_ready  : std_logic := '0';
  signal key_stroke : std_logic := '1';
  signal key_code   : std_logic_vector(9 downto 0) := (others => '0');
  signal drive      : std_logic_vector(7 downto 0) := x"EF";
  signal sense5     : std_logic_vector(7 downto 0);
  signal sense6     : std_logic_vector(7 downto 0);
  signal extra      : std_logic_vector(13 downto 0);
  signal cpm        : std_logic := '1';
  signal s_dn       : std_logic;
begin
  clk <= not clk after 10 ns;
  dut : entity work.mtx_kbd
    port map (clk_1mhz => clk, key_ready => key_ready, key_stroke => key_stroke, key_code => key_code,
              drive => drive, sense5 => sense5, sense6 => sense6, extra_keys => extra, cpm_mode => cpm);
  s_dn <= not sense5(1);

  stim : process
    variable errors : integer := 0;
    variable t0 : time;
    variable n : integer;
    variable d : time;
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
    -- how long S has been seen down, counted from the moment tp (when the PC key went down), to the moment it goes up
    procedure measure(tp : time; variable dd : out time) is
    begin
      if s_dn = '0' then wait until s_dn = '1' for 20 ms; end if;
      wait until s_dn = '0' for 500 ms;
      dd := now - tp;
    end procedure;
  begin
    wait for 1 ms;
    -- a tap of 5 ms: seen for about 60 ms
    t0 := now;
    ps2("00" & x"1b", '0'); wait for 5 ms; ps2("00" & x"1b", '1');
    measure(t0, d); chk(d >= 58 ms and d <= 64 ms, "a 5 ms tap is stretched to about 60 ms, got " & time'image(d));
    wait for 100 ms;
    -- two taps 20 ms apart: two separate presses, with a gap of at least 40 ms between them
    ps2("00" & x"1b", '0'); wait for 5 ms; ps2("00" & x"1b", '1'); wait for 20 ms; ps2("00" & x"1b", '0'); wait for 5 ms; ps2("00" & x"1b", '1');
    wait until s_dn = '1' for 20 ms;
    wait until s_dn = '0' for 200 ms;
    t0 := now;
    wait until s_dn = '1' for 200 ms;
    chk(s_dn = '1', "the second tap is seen as a second press");
    chk(now - t0 >= 38 ms, "at least 40 ms between the two presses, got " & time'image(now - t0));
    wait for 300 ms;
    -- a key held down: seen for about 90 ms, then released, then repeating after 450 ms
    t0 := now;
    ps2("00" & x"1b", '0');
    measure(t0, d); chk(d >= 88 ms and d <= 93 ms, "a held key is released after about 90 ms, got " & time'image(d));
    wait for 200 ms;
    chk(s_dn = '0', "still up 300 ms into the hold (no repeat yet)");
    wait for 200 ms;
    n := 0;
    for i in 1 to 6 loop
      wait until s_dn = '1' for 200 ms;
      if s_dn = '1' then n := n + 1; end if;
      wait until s_dn = '0' for 200 ms;
    end loop;
    chk(n >= 4, "a key held down repeats, got " & integer'image(n) & " presses");
    ps2("00" & x"1b", '1');
    wait for 300 ms;
    chk(s_dn = '0', "up after release");
    -- the shift is not shaped: it stays down as long as the PC shift (LSHIFT is row 6, column 0)
    drive <= x"BF"; wait for 1 us;
    ps2("00" & x"12", '0'); wait for 400 ms;
    chk(sense5(0) = '0', "the shift key stays down for 400 ms");
    ps2("00" & x"12", '1'); wait for 1 us;
    chk(sense5(0) = '1', "and goes up at once");
    -- without cpm_mode keys pass as they are
    drive <= x"EF"; cpm <= '0'; wait for 1 us;
    ps2("00" & x"1b", '0'); wait for 200 ms;
    chk(s_dn = '1', "BASIC mode: held for 200 ms, still down");
    ps2("00" & x"1b", '1'); wait for 1 us;
    chk(s_dn = '0', "BASIC mode: up at once");
    if errors = 0 then report "KBD SHAPING TEST PASSED"; else report "KBD SHAPING TEST FAILED" severity failure; end if;
    std.env.finish;
  end process;
end sim;
