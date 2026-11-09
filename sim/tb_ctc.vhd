-- tb_ctc.vhd - ctc.vhd: the counter is loaded when a time constant is written, so a counter set to 1 interrupts at the first input
-- pulse (not after 256), and a software reset clears a pending interrupt.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_ctc is
end tb_ctc;

architecture sim of tb_ctc is
  signal clk     : std_logic := '0';
  signal reset   : std_logic := '1';
  signal channel : std_logic_vector(1 downto 0) := "00";
  signal we      : std_logic := '0';
  signal dw      : std_logic_vector(7 downto 0) := (others => '0');
  signal dr      : std_logic_vector(7 downto 0);
  signal int     : std_logic;
  signal re_vec  : std_logic := '0';
  signal vec     : std_logic_vector(7 downto 1);
  signal count0  : std_logic := '0';
  signal timer16 : std_logic := '0';
  signal zc0, zc1, zc2 : std_logic;
begin
  clk <= not clk after 10 ns;

  dut : entity work.ctc
    port map (clk_cpu => clk, reset => reset, channel => channel, we => we, data_write => dw, data_read => dr,
              interrupt => int, re_vector => re_vec, vector => vec, timer16 => timer16, count0 => count0,
              count1 => '0', count2 => '0', count3 => '0', zcto0 => zc0, zcto1 => zc1, zcto2 => zc2);

  stim : process
    variable errors : integer := 0;
    variable n : integer;
    procedure wr(ch : integer; v : integer) is
    begin
      wait until rising_edge(clk);
      channel <= std_logic_vector(to_unsigned(ch, 2)); dw <= std_logic_vector(to_unsigned(v, 8)); we <= '1';
      wait until rising_edge(clk);
      we <= '0';
    end procedure;
    procedure pulse is
    begin
      count0 <= '1'; wait for 100 ns; count0 <= '0'; wait for 100 ns;
    end procedure;
    procedure chk(c : boolean; what : string) is
    begin
      if not c then report "FAIL: " & what severity error; errors := errors + 1; end if;
    end procedure;
    -- how many input pulses until the interrupt, at most 300
    procedure pulses_to_int(variable k : out integer) is
      variable c : integer := 0;
    begin
      while int = '0' and c < 300 loop pulse; c := c + 1; end loop;
      k := c;
    end procedure;
    procedure ack is
    begin   -- the CPU takes the vector: clears the pending flag
      wait until rising_edge(clk); re_vec <= '1'; wait until rising_edge(clk); wait until rising_edge(clk); re_vec <= '0';
      wait for 100 ns;
    end procedure;
  begin
    wait for 100 ns;
    reset <= '0';
    wait for 100 ns;

    -- hardware reset state: channel 0 counter mode, interrupt, time constant 1 (control C5): the first pulse interrupts
    wr(0, 16#C5#); wr(0, 1);
    pulses_to_int(n);
    chk(n = 1, "stopped channel, constant 1: interrupt at pulse 1, got " & integer'image(n));
    ack;
    chk(int = '0', "the acknowledge clears it");

    -- the same channel running: counts on, and a pulse brings the next interrupt (TC 1 again)
    pulses_to_int(n);
    chk(n = 1, "running channel, reload of 1: interrupt at every pulse, got " & integer'image(n));
    ack;

    -- software reset (control 03), then control C5 and 3: three pulses
    wr(0, 3);
    wr(0, 16#C5#); wr(0, 3);
    pulses_to_int(n);
    chk(n = 3, "after a software reset, constant 3: interrupt at pulse 3, got " & integer'image(n));
    ack;

    -- constant 0 means 256
    wr(0, 3);
    wr(0, 16#C5#); wr(0, 0);
    pulses_to_int(n);
    chk(n = 256, "constant 0 is 256 pulses, got " & integer'image(n));
    ack;

    -- a running channel given a new constant (control C5 without reset, constant 9): loaded at once, as MEMU does (its author
    -- found that this matches the real hardware): nine pulses from the write, whatever count the old constant had reached
    wr(0, 3);
    wr(0, 16#C5#); wr(0, 4);
    pulse; pulse;                                        -- two of four
    wr(0, 16#C5#); wr(0, 9);
    pulses_to_int(n);
    chk(n = 9, "running channel given a new constant counts it from the write: got " & integer'image(n));
    ack;

    -- a software reset (control word with the reset bit) clears the channel's pending interrupt
    wr(0, 3);
    wr(0, 16#C5#); wr(0, 1);
    pulse;
    chk(int = '1', "interrupt pending before the reset");
    wr(0, 3);
    wait for 200 ns;
    chk(int = '0', "a software reset clears the pending interrupt");

    if errors = 0 then report "CTC TEST PASSED"; else report "CTC TEST FAILED" severity failure; end if;
    std.env.finish;
  end process;
end sim;
