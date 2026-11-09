-- tb_sound_rates.vhd - the sound chip (sound.vhd) against the SN76489A data sheet in appendix 7 of the MTX operator's
-- manual, with an exact 4.000MHz clock:
--   tone: f = N/(32 n), so a half period is n * 4us
--   noise: shift rate N/512, N/1024, N/2048 (periodic noise: one shift per 128, 256, 512 us), or the rate of tone 3
--   attenuation: 2dB steps in amplitude (6000 * 10^(-a/10) here), 15 is off
--   the register address of a first byte is latched; a data byte goes to that register
-- Compile with -2008 (external names).
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.ENV.ALL;
use IEEE.MATH_REAL.ALL;

entity tb_sound_rates is
end tb_sound_rates;

architecture sim of tb_sound_rates is
  signal clk : std_logic := '0';
  signal reset : std_logic := '1';
  signal reg_we : std_logic := '0';
  signal reg_value : std_logic_vector(7 downto 0) := (others => '0');
  signal snd : std_logic_vector(15 downto 0);
  signal strobe : std_logic;
begin
  clk <= not clk after 125 ns;     -- 4.000MHz

  dut : entity work.sound
    port map (clk_cpu => clk, reset => reset, reg_we => reg_we, reg_value => reg_value, div_cpu => "101",
              output => snd, strobe => strobe);

  main : process
    alias lfsr_s is << signal .tb_sound_rates.dut.noise_lfsr : std_logic_vector(15 downto 0) >>;
    variable errors : integer := 0;
    variable t0, d : time;
    variable pk, want, n : integer;
    type int_arr is array (0 to 2) of integer;
    constant test_n : int_arr := (100, 250, 1023);

    procedure fail (msg : string) is
    begin
      errors := errors + 1;
      report "FAIL: " & msg severity error;
    end procedure;

    procedure wr (v : std_logic_vector(7 downto 0)) is
    begin
      wait until falling_edge(clk);
      reg_value <= v; reg_we <= '1';
      wait until falling_edge(clk);
      reg_we <= '0';
      wait for 8 us;                 -- the chip wants 32 clock cycles between bytes
    end procedure;

    procedure set_tone (ch : integer; n : integer) is
    begin
      wr("1" & std_logic_vector(to_unsigned(ch * 2, 3)) & std_logic_vector(to_unsigned(n mod 16, 4)));
      wr("00" & std_logic_vector(to_unsigned(n / 16, 6)));
    end procedure;

    procedure set_vol (ch : integer; a : integer) is
    begin
      wr("1" & std_logic_vector(to_unsigned(ch * 2 + 1, 3)) & std_logic_vector(to_unsigned(a, 4)));
    end procedure;

    -- the largest |output| over 10 ms, sampled every 100us: with a slow tone this is the steady level of channel 1
    procedure peak (p : out integer) is
      variable m : integer := 0;
    begin
      for k in 1 to 100 loop
        wait for 100 us;
        if abs(to_integer(signed(snd))) > m then m := abs(to_integer(signed(snd))); end if;
      end loop;
      p := m;
    end procedure;
  begin
    wait for 1 us;
    reset <= '0';
    wait for 1 us;

    -- ---- tone frequency: the output changes sign once per half period, which is n * 4us
    set_vol(0, 0);
    for i in test_n'range loop
      n := test_n(i);
      set_tone(0, n);
      wait until snd(15)'event;
      wait until snd(15)'event;
      t0 := now;
      wait until snd(15)'event;
      d := now - t0;
      report "tone n=" & integer'image(n) & ": half period " & time'image(d) & ", f = " & integer'image(4000000 / (32 * n)) & " Hz" severity note;
      if d < n * 4 us - 1 us or d > n * 4 us + 1 us then
        fail("tone n=" & integer'image(n) & ": half period " & time'image(d) & ", want " & time'image(n * 4 us));
      end if;
    end loop;

    -- ---- the latch: a first byte for tone 1's attenuation, then a data byte, goes to the attenuation
    set_tone(0, 1023);
    wr(x"BF"); wr(x"DF"); wr(x"FF"); -- tone 2, tone 3 and noise attenuation 15 (off)
    set_vol(0, 0);
    wr(x"91");                       -- tone 1 attenuation 1, and the register is latched
    wr(x"05");                       -- a data byte: it is the attenuation again, now 5
    peak(pk);
    want := integer(round(6000.0 * 10.0 ** (-5.0 / 10.0)));
    if abs(pk - want) > want / 50 + 2 then fail("a data byte after an attenuation first byte: level " & integer'image(pk) & ", want " & integer'image(want)); end if;
    report "latched attenuation: level " & integer'image(pk) & " (want " & integer'image(want) & ")" severity note;

    -- ---- attenuation steps
    for a in 0 to 15 loop
      set_vol(0, a);
      peak(pk);
      want := integer(round(6000.0 * 10.0 ** (-real(a) / 10.0)));
      if a = 15 then want := 0; end if;
      if abs(pk - want) > want / 50 + 2 then fail("attenuation " & integer'image(a) & ": level " & integer'image(pk) & ", want " & integer'image(want)); end if;
    end loop;
    report "attenuation steps checked" severity note;

    -- ---- noise shift rates (periodic noise, so every shift changes the register)
    set_vol(0, 15);
    for nf in 0 to 2 loop
      wr("11100" & std_logic_vector(to_unsigned(nf, 3)));          -- E0 | NF: periodic noise
      wait until lfsr_s'event;
      wait until lfsr_s'event;
      t0 := now;
      wait until lfsr_s'event;
      d := now - t0;
      report "noise NF=" & integer'image(nf) & ": a shift every " & time'image(d) severity note;
      case nf is
        when 0 => if d < 127 us or d > 129 us then fail("noise NF=0: shift interval " & time'image(d) & ", want 128 us (N/512 = 7812.5 Hz)"); end if;
        when 1 => if d < 255 us or d > 257 us then fail("noise NF=1: shift interval " & time'image(d) & ", want 256 us (N/1024 = 3906.25 Hz)"); end if;
        when others => if d < 511 us or d > 513 us then fail("noise NF=2: shift interval " & time'image(d) & ", want 512 us (N/2048 = 1953.125 Hz)"); end if;
      end case;
    end loop;
    -- NF=3: the rate of tone 3, one shift per full period (2 * n * 4 us)
    set_tone(2, 50);
    wr("11100011");
    wait until lfsr_s'event;
    wait until lfsr_s'event;
    t0 := now;
    wait until lfsr_s'event;
    d := now - t0;
    report "noise NF=3 (tone 3, n=50): a shift every " & time'image(d) severity note;
    if d < 399 us or d > 401 us then fail("noise NF=3 with tone 3 n=50: shift interval " & time'image(d) & ", want 400 us"); end if;

    if errors = 0 then
      report "tb_sound_rates: all checks passed" severity note;
    else
      report "tb_sound_rates: " & integer'image(errors) & " check(s) FAILED" severity failure;
    end if;
    finish;
  end process;
end sim;
