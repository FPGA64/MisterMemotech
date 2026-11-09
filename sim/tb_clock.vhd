-- tb_clock.vhd - the clock divider against the real MTX clocks: the stock CPU clock is 4MHz (the crystal), the CTC timer
-- input is 4MHz/16 = 250kHz, the CTC counter input is 4MHz/13 = 307.692kHz. Counts edges over 100 ms of a 50MHz clock.
-- Compile with -2008 (external names are not used; plain VHDL).
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.ALL;

entity tb_clock is
end tb_clock;

architecture sim of tb_clock is
  signal clk50 : std_logic := '0';
  signal div : std_logic_vector(2 downto 0) := "101";
  signal c_cpu, c_t16, c_cnt, c_25, c_4, c_1 : std_logic;
  signal n_cpu, n_t16, n_cnt : integer := 0;
  signal hi_min, hi_max, lo_min, lo_max : integer := 0;
begin
  clk50 <= not clk50 after 10 ns;

  dut : entity work.clock_divider
    port map (clk_50mhz => clk50, div_cpu => div, clk_cpu => c_cpu, clk_timer16 => c_t16, clk_counter => c_cnt,
              clk_25mhz => c_25, clk_4mhz => c_4, clk_1mhz => c_1);

  process (c_cpu) begin if rising_edge(c_cpu) then n_cpu <= n_cpu + 1; end if; end process;
  process (c_t16) begin if rising_edge(c_t16) then n_t16 <= n_t16 + 1; end if; end process;
  process (c_cnt) begin if rising_edge(c_cnt) then n_cnt <= n_cnt + 1; end if; end process;

  main : process
    variable errors : integer := 0;
    variable a, b, c : integer;
    variable t_prev, t_now : time;
    variable periods : integer;
    variable p12, p13 : integer := 0;

    procedure fail (msg : string) is
    begin
      errors := errors + 1;
      report "FAIL: " & msg severity error;
    end procedure;

    procedure expect (what : string; got, want : integer) is
    begin
      if abs(got - want) > 1 then fail(what & ": " & integer'image(got) & " edges, want " & integer'image(want));
      else report what & ": " & integer'image(got) & " edges (want " & integer'image(want) & ")" severity note; end if;
    end procedure;
  begin
    -- stock speed
    wait for 1 us;
    a := n_cpu; b := n_t16; c := n_cnt;
    wait for 100 ms;
    expect("CPU clock, stock (4MHz)", n_cpu - a, 400000);
    expect("CTC timer input (250kHz)", n_t16 - b, 25000);
    expect("CTC counter input (4MHz/13)", n_cnt - c, 30769);

    -- the stock clock is made of cycles of 12 and 13 clocks of 50MHz
    wait until rising_edge(c_cpu);
    t_prev := now;
    for k in 1 to 2000 loop
      wait until rising_edge(c_cpu);
      t_now := now;
      if t_now - t_prev = 240 ns then p12 := p12 + 1;
      elsif t_now - t_prev = 260 ns then p13 := p13 + 1;
      else fail("a CPU cycle of " & time'image(t_now - t_prev)); end if;
      t_prev := t_now;
    end loop;
    report "stock CPU cycles: " & integer'image(p12) & " of 240 ns, " & integer'image(p13) & " of 260 ns" severity note;
    if p12 /= 1000 or p13 /= 1000 then fail("the 12/13 pattern is not alternating evenly"); end if;

    -- the other speeds are plain divisions of 50MHz
    div <= "100";                        -- 5MHz
    wait for 1 us;
    a := n_cpu;
    wait for 10 ms;
    expect("CPU clock, 5MHz setting (10 ms)", n_cpu - a, 50000);
    div <= "010";                        -- 8.333MHz
    wait for 1 us;
    a := n_cpu;
    wait for 10 ms;
    expect("CPU clock, 8.333MHz setting (10 ms)", n_cpu - a, 83333);

    if errors = 0 then report "tb_clock: all checks passed" severity note;
    else report "tb_clock: " & integer'image(errors) & " check(s) FAILED" severity failure; end if;
    finish;
  end process;
end sim;
