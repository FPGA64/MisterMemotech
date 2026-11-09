-- tb_kbd_shlatch.vhd - CP/M mode (cpm_mode = 1): the shift and control keys the CPU sees are frozen while another key is down.
--  - Shift down, S down, Shift up while S is still down: LSHIFT stays visible until S is up (so the BIOS does not turn S into s and type it twice)
--  - S down, Shift down while S is still down: LSHIFT stays hidden until S is up
--  - without cpm_mode the shift follows the PC shift at once
-- LSHIFT is row 6, column 0 (drive row 6 low: sense5 bit 0). S is PS/2 1B.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tb_kbd_shlatch is
end tb_kbd_shlatch;

architecture sim of tb_kbd_shlatch is
  signal clk        : std_logic := '0';
  signal key_ready  : std_logic := '0';
  signal key_stroke : std_logic := '1';
  signal key_code   : std_logic_vector(9 downto 0) := (others => '0');
  signal drive      : std_logic_vector(7 downto 0) := x"BF";
  signal sense5     : std_logic_vector(7 downto 0);
  signal sense6     : std_logic_vector(7 downto 0);
  signal extra      : std_logic_vector(13 downto 0);
  signal cpm        : std_logic := '1';
begin
  clk <= not clk after 10 ns;
  dut : entity work.mtx_kbd
    port map (clk_1mhz => clk, key_ready => key_ready, key_stroke => key_stroke, key_code => key_code,
              drive => drive, sense5 => sense5, sense6 => sense6, extra_keys => extra, cpm_mode => cpm);

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
    procedure chk(c : boolean; what : string) is
    begin
      if not c then report "FAIL: " & what severity error; errors := errors + 1; end if;
    end procedure;
  begin
    wait for 1 us;
    chk(sense5(0) = '1', "shift up at the start");
    -- shift down, S down, shift up, S still down
    ps2("00" & x"12", '0'); wait for 1 us;
    chk(sense5(0) = '0', "shift down alone: seen");
    ps2("00" & x"1b", '0'); wait for 1 us;
    chk(sense5(0) = '0', "shift + S: shift seen");
    ps2("00" & x"12", '1'); wait for 1 us;
    chk(sense5(0) = '0', "shift let go while S is down: still seen (so the character does not change)");
    ps2("00" & x"1b", '1'); wait for 1 us;
    chk(sense5(0) = '1', "S up: the shift follows the real key again (up)");
    -- S down, shift down late, shift stays hidden until S is up
    ps2("00" & x"1b", '0'); wait for 1 us;
    chk(sense5(0) = '1', "S alone: no shift");
    ps2("00" & x"12", '0'); wait for 1 us;
    chk(sense5(0) = '1', "shift pressed while S is down: hidden");
    ps2("00" & x"1b", '1'); wait for 1 us;
    chk(sense5(0) = '0', "S up: the shift (still held) is seen");
    ps2("00" & x"12", '1'); wait for 1 us;
    chk(sense5(0) = '1', "shift up");
    -- the shift key alone is never frozen
    ps2("00" & x"12", '0'); wait for 1 us; chk(sense5(0) = '0', "shift alone, down");
    ps2("00" & x"12", '1'); wait for 1 us; chk(sense5(0) = '1', "shift alone, up");
    -- BASIC mode: follows at once
    cpm <= '0'; wait for 1 us;
    ps2("00" & x"12", '0'); ps2("00" & x"1b", '0'); ps2("00" & x"12", '1'); wait for 1 us;
    chk(sense5(0) = '1', "BASIC mode: shift up at once while S is down");
    ps2("00" & x"1b", '1');
    if errors = 0 then report "KBD SHIFT LATCH TEST PASSED"; else report "KBD SHIFT LATCH TEST FAILED" severity failure; end if;
    std.env.finish;
  end process;
end sim;
