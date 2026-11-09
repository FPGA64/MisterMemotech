-- tb_kbd_cpmbs.vhd - in CP/M mode (cpm_mode = 1) BackSpace is the plain MTX BS key (row 1, column 8: sense6 bit 0 with drive row 1 low),
-- down while the PC key is down, and the DEL key (row 3, column 8) is never pressed; without CP/M mode it is BS then DEL (tb_kbd_bs.vhd).
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tb_kbd_cpmbs is
end tb_kbd_cpmbs;

architecture sim of tb_kbd_cpmbs is
  signal clk        : std_logic := '0';
  signal key_ready  : std_logic := '0';
  signal key_stroke : std_logic := '1';
  signal key_code   : std_logic_vector(9 downto 0) := (others => '0');
  signal drive      : std_logic_vector(7 downto 0) := x"FF";
  signal sense5     : std_logic_vector(7 downto 0);
  signal sense6     : std_logic_vector(7 downto 0);
  signal extra      : std_logic_vector(13 downto 0);
  signal cpm        : std_logic := '1';
  signal bs_dn, del_dn : integer := 0;
begin
  clk <= not clk after 10 ns;
  dut : entity work.mtx_kbd
    port map (clk_1mhz => clk, key_ready => key_ready, key_stroke => key_stroke, key_code => key_code,
              drive => drive, sense5 => sense5, sense6 => sense6, extra_keys => extra, cpm_mode => cpm);

  stim : process
    variable errors : integer := 0;
    variable v : std_logic;
    procedure ps2(code : std_logic_vector(9 downto 0); stroke : std_logic) is
    begin
      wait until rising_edge(clk);
      key_code <= code; key_stroke <= stroke; key_ready <= '1';
      wait until rising_edge(clk);
      key_ready <= '0';
      wait for 200 ns;
    end procedure;
    procedure bs_level(variable v : out std_logic) is
    begin drive <= x"FD"; wait for 100 ns; v := sense6(0); end procedure;
    procedure del_level(variable v : out std_logic) is
    begin drive <= x"F7"; wait for 100 ns; v := sense6(0); end procedure;
    procedure chk(c : boolean; what : string) is
    begin
      if not c then report "FAIL: " & what severity error; errors := errors + 1; end if;
    end procedure;
  begin
    wait for 1 us;
    ps2("00" & x"66", '0');
    bs_level(v);  chk(v = '0', "CP/M mode: BackSpace down: the BS key is down at once");
    wait for 40 ms;
    bs_level(v);  chk(v = '0', "CP/M mode: still down 40 ms into the press");
    del_level(v); chk(v = '1', "CP/M mode: the DEL key is not pressed");
    ps2("00" & x"66", '1');
    wait for 100 ms;
    bs_level(v);  chk(v = '1', "CP/M mode: released shortly after the PC key");
    del_level(v); chk(v = '1', "CP/M mode: DEL never came after");
    -- the same with BASIC (cpm_mode 0): BS first, then DEL a moment later
    cpm <= '0'; wait for 1 us;
    ps2("00" & x"66", '0');
    bs_level(v);  chk(v = '0', "BASIC mode: BS first");
    wait for 150 ms;
    del_level(v); chk(v = '0' or v = '1', "BASIC mode: (DEL comes after the BS)");
    ps2("00" & x"66", '1');
    if errors = 0 then report "KBD CPM BACKSPACE TEST PASSED"; else report "KBD CPM BACKSPACE TEST FAILED" severity failure; end if;
    std.env.finish;
  end process;
end sim;
