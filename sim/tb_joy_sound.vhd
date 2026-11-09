-- tb_joy_sound.vhd - unit tests for the joystick matrix wiring (mtx_joy) and the sound chip model (sound)
-- Compile with -2008.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.ALL;

entity tb_joy_sound is
end tb_joy_sound;

architecture sim of tb_joy_sound is
  signal clk : std_logic := '0';
  signal drive : std_logic_vector(7 downto 0) := (others => '1');
  signal joy1, joy2 : std_logic_vector(4 downto 0) := (others => '0');
  signal sense : std_logic_vector(7 downto 0);

  signal reset : std_logic := '1';
  signal reg_we : std_logic := '0';
  signal reg_value : std_logic_vector(7 downto 0) := (others => '0');
  signal snd : std_logic_vector(15 downto 0);
  signal strobe : std_logic;
  signal sample : integer := 0;
  signal updates : integer := 0;
begin
  clk <= not clk after 125 ns;     -- 4MHz

  joy : entity work.mtx_joy port map (clk => clk, drive => drive, joy1 => joy1, joy2 => joy2, sense => sense);
  chip : entity work.sound
    port map (clk_cpu => clk, reset => reset, reg_we => reg_we, reg_value => reg_value, div_cpu => "101",
              output => snd, strobe => strobe);
  sample <= to_integer(signed(snd));

  process (strobe) begin updates <= updates + 1; end process;

  main : process
    variable errors : integer := 0;
    -- joystick 1: bit -> drive line (up DR2, down DR6, left DR3, right DR4, fire DR5), sense line 7
    type map_t is array (0 to 4) of integer;
    constant j1_drive : map_t := (2, 6, 3, 4, 5);
    -- joystick 2: bit -> sense line (up KB0, down KB3, left KB2, right KB1, fire KB4), drive line 7
    constant j2_sense : map_t := (0, 3, 2, 1, 4);
    variable exp : std_logic_vector(7 downto 0);

    procedure wr(v : std_logic_vector(7 downto 0)) is
    begin
      wait until rising_edge(clk);
      reg_value <= v; reg_we <= '1';
      wait until rising_edge(clk);
      reg_we <= '0';
    end procedure;

    variable mx, mn, zeros : integer;
    type vol_t is array (0 to 15) of integer;
    constant vol : vol_t := (6000, 4766, 3786, 3007, 2389, 1897, 1507, 1197, 951, 755, 600, 476, 378, 301, 239, 0);
  begin
    -------------------------------------------------------------------- joystick
    wait for 2 us;
    drive <= (others => '1'); wait for 3 us;
    if sense /= x"FF" then report "FAIL: no joystick, no drive: sense should be FF" severity error; errors := errors + 1; end if;
    for d in 0 to 7 loop
      for b in 0 to 4 loop
        -- joystick 1 pressed in direction b, drive line d selected (low)
        joy1 <= (others => '0'); joy2 <= (others => '0');
        joy1(b) <= '1';
        drive <= (others => '1'); drive(d) <= '0';
        wait for 3 us;
        exp := x"FF";
        if d = j1_drive(b) then exp(7) := '0'; end if;
        if sense /= exp then
          report "FAIL: joystick 1 bit " & integer'image(b) & " drive " & integer'image(d) severity error; errors := errors + 1;
        end if;
        -- joystick 2
        joy1 <= (others => '0'); joy2 <= (others => '0');
        joy2(b) <= '1';
        wait for 3 us;
        exp := x"FF";
        if d = 7 then exp(j2_sense(b)) := '0'; end if;
        if sense /= exp then
          report "FAIL: joystick 2 bit " & integer'image(b) & " drive " & integer'image(d) severity error; errors := errors + 1;
        end if;
      end loop;
    end loop;
    -- all unselected drive lines: nothing seen even with everything pressed
    joy1 <= (others => '1'); joy2 <= (others => '1'); drive <= (others => '1'); wait for 3 us;
    if sense /= x"FF" then report "FAIL: pressed but no drive line selected" severity error; errors := errors + 1; end if;
    joy1 <= (others => '0'); joy2 <= (others => '0');
    report "joystick wiring checked";

    -------------------------------------------------------------------- sound
    reset <= '0';
    wait for 2 us;
    -- three tone channels silent, noise silent
    wr(x"9F"); wr(x"BF"); wr(x"DF"); wr(x"FF");
    -- channel 0 tone: frequency value 10, attenuation a
    for a in 0 to 15 loop
      wr(x"8A"); wr(x"00");                 -- freq(0) = 10
      wr(std_logic_vector(to_unsigned(16#90# + a, 8)));
      wait for 400 us;
      mx := -100000; mn := 100000;
      for k in 1 to 20000 loop
        wait until rising_edge(clk);
        if sample > mx then mx := sample; end if;
        if sample < mn then mn := sample; end if;
      end loop;
      if abs(mx - vol(a)) > vol(a) / 50 + 4 or abs(mn + vol(a)) > vol(a) / 50 + 4 then
        report "FAIL: attenuation " & integer'image(a) & ": peak " & integer'image(mx) & " / " & integer'image(mn) &
               " expected +-" & integer'image(vol(a)) severity error;
        errors := errors + 1;
      end if;
    end loop;
    report "attenuation steps checked (2dB table)";

    -- a chord: channel 0 and 1 at full volume with different frequencies: levels must form a proper sum
    wr(x"8A"); wr(x"00"); wr(x"90");
    wr(x"AF"); wr(x"00"); wr(x"B0");        -- freq(1) = 15, atten 0
    wait for 400 us;
    mx := -100000; mn := 100000; zeros := 0;
    for k in 1 to 40000 loop
      wait until rising_edge(clk);
      if sample > mx then mx := sample; end if;
      if sample < mn then mn := sample; end if;
      if abs(sample) < 500 then zeros := zeros + 1; end if;
    end loop;
    report "chord peaks " & integer'image(mx) & " / " & integer'image(mn) & ", samples near zero: " & integer'image(zeros);
    if mx < 11900 or mn > -11900 then report "FAIL: two full volume channels should reach +-12000" severity error; errors := errors + 1; end if;
    if zeros = 0 then report "FAIL: a chord must pass through the middle level" severity error; errors := errors + 1; end if;

    if errors = 0 then report "JOY AND SOUND TESTS PASSED"; else report "JOY AND SOUND TESTS FAILED" severity failure; end if;
    finish;
  end process;
end sim;
