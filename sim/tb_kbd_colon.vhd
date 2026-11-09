-- tb_kbd_colon.vhd - the colon: the PC Shift+; is the MTX colon key (row 5, column 5: sense5 bit 5 with only drive row 5 low) with NO shift
-- (LSHIFT row 6 column 0, RSHIFT row 6 column 6) seen by the CPU; ; alone is the MTX ;+ key (row 4, column 5); the # key is the colon too.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tb_kbd_colon is
end tb_kbd_colon;

architecture sim of tb_kbd_colon is
  signal clk        : std_logic := '0';
  signal key_ready  : std_logic := '0';
  signal key_stroke : std_logic := '1';
  signal key_code   : std_logic_vector(9 downto 0) := (others => '0');
  signal drive      : std_logic_vector(7 downto 0) := x"FF";
  signal sense5     : std_logic_vector(7 downto 0);
  signal sense6     : std_logic_vector(7 downto 0);
  signal extra      : std_logic_vector(13 downto 0);
begin
  clk <= not clk after 10 ns;
  dut : entity work.mtx_kbd
    port map (clk_1mhz => clk, key_ready => key_ready, key_stroke => key_stroke, key_code => key_code,
              drive => drive, sense5 => sense5, sense6 => sense6, extra_keys => extra);

  stim : process
    variable errors : integer := 0;
    procedure ps2(code : std_logic_vector(9 downto 0); stroke : std_logic) is
    begin
      wait until rising_edge(clk);
      key_code <= code; key_stroke <= stroke; key_ready <= '1';
      wait until rising_edge(clk);
      key_ready <= '0';
      wait for 200 ns;
    end procedure;
    -- the level of one key of the grid: row r (0..7), column c (0..7): 0 = pressed
    procedure key(r, c : integer; v : out std_logic) is
      variable d : std_logic_vector(7 downto 0) := x"FF";
    begin
      d(r) := '0';
      drive <= d;
      wait for 100 ns;
      v := sense5(c);
    end procedure;
    variable lv : std_logic_vector(7 downto 0);
    -- chk of a set of (row, column, expected level) written as a string of tests
    procedure ex(r, c : integer; e : std_logic; what : string) is
      variable v : std_logic;
    begin
      key(r, c, v);
      if v /= e then report "FAIL: " & what severity error; errors := errors + 1; end if;
    end procedure;
    procedure chk(c : boolean; what : string) is
    begin
      if not c then report "FAIL: " & what severity error; errors := errors + 1; end if;
    end procedure;
  begin
    wait for 1 us;
    ex(5, 5, '1', "all up at the start"); ex(4, 5, '1', "all up at the start"); ex(6, 0, '1', "all up at the start"); ex(6, 6, '1', "all up at the start");
    -- ; alone: the MTX ;+ key
    ps2("00" & x"4c", '0');
    ex(4, 5, '0', "; alone: the ;+ key down"); ex(5, 5, '1', "; alone: no colon key");
    ps2("00" & x"4c", '1');
    ex(4, 5, '1', "; alone: released");
    -- left shift + ; : the shift is hidden at once, the colon key follows 20 ms later (never the key with a visible shift), and on release the
    -- colon key goes first and the shift comes back 20 ms later
    ps2("00" & x"12", '0');
    ex(6, 0, '0', "left shift down alone: LSHIFT seen");
    ps2("00" & x"4c", '0');
    ex(6, 0, '1', "shift + ;: LSHIFT hidden from the CPU at once");
    ex(5, 5, '1', "shift + ;: the colon key is not down yet");
    ex(4, 5, '1', "shift + ;: not the ;+ key");
    wait for 25 ms;
    ex(5, 5, '0', "shift + ; (25 ms): the colon key down");
    ex(6, 0, '1', "shift + ; (25 ms): LSHIFT still hidden");
    ex(4, 5, '1', "shift + ; (25 ms): not the ;+ key");
    ps2("00" & x"4c", '1');
    ex(5, 5, '1', "shift + ; released: the colon key up at once");
    ex(6, 0, '1', "shift + ; released: LSHIFT still hidden for a moment");
    wait for 25 ms;
    ex(6, 0, '0', "shift + ; released (25 ms), shift still down: LSHIFT seen again");
    ps2("00" & x"12", '1');
    ex(6, 0, '1', "all up");
    -- right shift + ; , and the shift let go before the ;
    ps2("00" & x"59", '0');
    ps2("00" & x"4c", '0');
    wait for 25 ms;
    ex(5, 5, '0', "right shift + ;: the colon key"); ex(6, 6, '1', "right shift + ;: RSHIFT hidden");
    ps2("00" & x"59", '1');
    ex(5, 5, '0', "shift let go first: the colon key still down");
    ps2("00" & x"4c", '1');
    wait for 25 ms;
    ex(5, 5, '1', "everything up"); ex(4, 5, '1', "everything up"); ex(6, 6, '1', "everything up");
    -- a ; let go before the colon key was pressed (a very short tap): no colon key, the shift comes back
    ps2("00" & x"12", '0'); ps2("00" & x"4c", '0'); wait for 2 ms; ps2("00" & x"4c", '1'); wait for 25 ms;
    ex(5, 5, '1', "short tap: no colon key"); ex(6, 0, '0', "short tap: LSHIFT seen again");
    ps2("00" & x"12", '1');
    -- another key with shift is untouched: Shift + A is shift and A
    ps2("00" & x"12", '0'); ps2("00" & x"1c", '0');
    ex(5, 0, '0', "shift + A: both seen"); ex(6, 0, '0', "shift + A: both seen");
    ps2("00" & x"1c", '1'); ps2("00" & x"12", '1');
    -- the # key is the colon too
    ps2("00" & x"5d", '0'); ex(5, 5, '0', "#: the colon key"); ps2("00" & x"5d", '1');
    if errors = 0 then report "KBD COLON TEST PASSED"; else report "KBD COLON TEST FAILED" severity failure; end if;
    std.env.finish;
  end process;
end sim;
