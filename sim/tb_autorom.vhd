-- tb_autorom.vhd - mtx_autorom: types ROM 3 RET after a trigger, but only when the CPU is waiting for a key.
--   idle:  instruction fetches mostly inside the keyboard wait loop (a few outside, like the 50Hz interrupt routine)
--   busy:  fetches elsewhere
-- The generics are shortened (window 20 us, key hold 6 us, gap 4 us, time out 400 us) so the test takes a moment.
-- Compile with -2008.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.ALL;

entity tb_autorom is
end tb_autorom;

architecture sim of tb_autorom is
  signal clk50 : std_logic := '0';
  signal reset : std_logic := '0';
  signal trig  : std_logic := '0';
  signal a     : std_logic_vector(15 downto 0) := x"0000";
  signal m1_n, mreq_n : std_logic := '1';
  signal inj : std_logic_vector(79 downto 0);
  signal busy : std_logic;
  signal idle_mode : boolean := true;
  signal cpu_on : boolean := true;
  signal presses : integer := 0;                  -- how many times a key went down
begin
  count : process (inj) begin
    if inj /= (79 downto 0 => '1') then presses <= presses + 1; end if;
  end process;
  clk50 <= not clk50 after 10 ns;

  dut : entity work.mtx_autorom
    generic map (WINDOW => 1000, HOLD => 300, GAP => 200, TIMEOUT => 20000)
    port map (clk50 => clk50, reset => reset, trig => trig, a => a, m1_n => m1_n, mreq_n => mreq_n, inj => inj, busy => busy);

  -- a fake CPU: an instruction fetch every 400 ns (20 clocks of 50MHz); in idle mode 19 of 20 are in the loop
  cpu : process
    variable n : integer := 0;
  begin
    wait until rising_edge(clk50);
    for k in 1 to 5 loop wait until rising_edge(clk50); end loop;
    if cpu_on then
      n := n + 1;
      if idle_mode then
        if n mod 20 = 0 then a <= x"0095"; else a <= std_logic_vector(to_unsigned(16#36B0# + (n mod 16), 16)); end if;
      else
        a <= std_logic_vector(to_unsigned(16#1200# + (n mod 300), 16));
      end if;
      m1_n <= '0'; mreq_n <= '0';
      for k in 1 to 6 loop wait until rising_edge(clk50); end loop;
      m1_n <= '1'; mreq_n <= '1';
      for k in 1 to 8 loop wait until rising_edge(clk50); end loop;
    end if;
  end process;

  main : process
    variable errors : integer := 0;
    type key_arr is array (0 to 5) of integer;
    constant want : key_arr := (22, 34, 73, 78, 1, 56);     -- R O M space 3 RET
    variable seen : integer;
    variable pressed_key : integer;
    variable order : integer;
    variable p0 : integer;

    procedure fail (msg : string) is
    begin
      errors := errors + 1;
      report "FAIL: " & msg severity error;
    end procedure;

    function key_down (v : std_logic_vector(79 downto 0)) return integer is
    begin
      for i in 0 to 79 loop
        if v(i) = '0' then return i; end if;
      end loop;
      return -1;
    end function;

    procedure pulse is
    begin
      wait until rising_edge(clk50);
      trig <= '1';
      wait until rising_edge(clk50);
      trig <= '0';
    end procedure;
  begin
    wait for 1 us;

    -- 1. a trigger while the CPU is idle: the six keys, one after another, in order, never two at once
    idle_mode <= true;
    wait for 60 us;                                   -- a few windows go by: idle is seen
    pulse;
    order := 0;
    for k in 0 to 5 loop
      wait until inj /= (79 downto 0 => '1') for 100 us;
      pressed_key := key_down(inj);
      if pressed_key /= want(k) then fail("key " & integer'image(k) & ": got matrix key " & integer'image(pressed_key) & ", want " & integer'image(want(k))); end if;
      wait until inj = (79 downto 0 => '1') for 100 us;
    end loop;
    wait for 20 us;
    if busy /= '0' then fail("still busy after the last key"); end if;
    if inj /= (79 downto 0 => '1') then fail("a key is still down after RET"); end if;

    -- 2. a trigger while the CPU is busy elsewhere: nothing is typed, and the request is dropped after the time out
    idle_mode <= false;
    wait for 60 us;
    p0 := presses;
    pulse;
    wait for 450 us;                                  -- longer than the time out
    if presses /= p0 then fail("keys typed into a busy CPU"); end if;
    if busy /= '0' then fail("the request was not dropped after the time out"); end if;
    idle_mode <= true;
    wait for 150 us;
    if presses /= p0 then fail("a dropped request typed keys when the CPU became idle later"); end if;

    -- 3. a request made while busy is typed when the CPU becomes idle within the time out
    idle_mode <= false;
    wait for 60 us;
    p0 := presses;
    pulse;
    wait for 100 us;
    if presses /= p0 then fail("keys typed into a busy CPU (3)"); end if;
    idle_mode <= true;
    wait until inj /= (79 downto 0 => '1') for 200 us;
    if key_down(inj) /= want(0) then fail("no R after the CPU became idle"); end if;
    wait for 300 us;

    -- 4. a reset stops the typing
    pulse;
    wait until inj /= (79 downto 0 => '1') for 200 us;
    reset <= '1';
    wait for 1 us;
    reset <= '0';
    wait for 5 us;
    if inj /= (79 downto 0 => '1') then fail("a key stays down after a reset"); end if;
    if busy /= '0' then fail("busy after a reset"); end if;

    -- 5. the CPU stopped (no fetches at all): nothing is typed
    cpu_on <= false;
    wait for 30 us;
    p0 := presses;
    pulse;
    wait for 450 us;
    if presses /= p0 then fail("keys typed while the CPU was stopped"); end if;

    if errors = 0 then report "tb_autorom: all checks passed" severity note;
    else report "tb_autorom: " & integer'image(errors) & " check(s) FAILED" severity failure; end if;
    finish;
  end process;
end sim;
