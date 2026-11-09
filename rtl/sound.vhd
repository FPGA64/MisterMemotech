--
-- sound.vhd - SN76489A sound chip
--
-- References
--   http://www.smspower.org/Development/SN76489
--   the SN76489A data sheet in appendix 7 of the MTX operator's manual: a tone is N/(32 n) with N the clock,
--   attenuation in 2dB steps (15 is off), the noise shift register shifts at N/512, N/1024 or N/2048 (or at the
--   rate of tone 3), and the register address of the first byte is latched, so a following data byte goes to
--   the same register. The MTX clocks the chip at exactly 4MHz (the Z80 clock).
--
-- Rewritten in 2017 to avoid using two seperate clock domains.
-- Instead do everything off of clk_cpu, and divide further so that we
-- update the waveform 250000 times per second (roughly).
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sound is
  port
    (
    -- processor interface
    clk_cpu   : in  std_logic;
    reset     : in  std_logic;
    reg_we    : in  std_logic;
    reg_value : in  std_logic_vector(7 downto 0);
    -- CPU speed, so we can further divide cpu_clk
    div_cpu   : in  std_logic_vector(2 downto 0);
    -- sound output: 16 bit signed, with a strobe that toggles each time it changes
    output    : out std_logic_vector(15 downto 0);
    strobe    : out std_logic
    );
end sound;

architecture behavior of sound is

  -- tone channels
  type freq_t  is array (natural range 0 to 2) of std_logic_vector(9 downto 0);
  type phase_t is array (natural range 0 to 2) of std_logic;
  type atten_t is array (natural range 0 to 2) of std_logic_vector(3 downto 0);
  type level_t is array (natural range 0 to 2) of signed(15 downto 0);

  -- SN76489 volume: attenuation steps are 2dB, 15 is off. Peak value of one channel is 6000,
  -- so all four channels together stay inside 16 bit signed.   6000 * 10^(-atten/10)
  type vol_t is array (0 to 15) of integer;
  constant vol : vol_t := (6000, 4766, 3786, 3007, 2389, 1897, 1507, 1197,
                            951,  755,  600,  476,  378,  301,  239,    0);
  signal freq    : freq_t := (others => "0000000000");
  signal count   : freq_t := (others => "0000000000");
  signal phase   : phase_t := (others => '0');
  signal atten   : atten_t := (others => "1111");
  signal level   : level_t := (others => (others => '0'));
  signal channel : natural range 0 to 2 := 0;
  signal latched : std_logic_vector(2 downto 0) := "000";   -- register address of the last first byte

  -- noise channel
  signal noise_fb        : std_logic;
  signal noise_freq_ctrl : std_logic_vector(1 downto 0);
  signal noise_count     : std_logic_vector(9 downto 0) := "0000000000";
  signal noise_lfsr      : std_logic_vector(15 downto 0) := "1000000000000000";
  signal noise_ff        : std_logic := '0';     -- the noise "flip-flop": the shift register shifts when it goes high
  signal noise_atten     : std_logic_vector(3 downto 0) := "1111";
  signal noise_level     : signed(15 downto 0) := (others => '0');

  -- use this to further divide clk_cpu down to 4MHz/16 approx
  signal clk_cpu_count : std_logic_vector(6 downto 0) := "0000000";

  signal output_int : signed(17 downto 0) := (others => '0');
  signal strobe_r   : std_logic := '0';

begin

  process ( clk_cpu, reset )
    variable o : signed(17 downto 0);
  begin
    if reset = '1' then

      -- when chip is reset, it goes silent, and tone frequencies are reset
      for i in 0 to 2 loop
        freq(i)  <= "0000000000";
        atten(i) <= "1111";
      end loop;
      noise_fb        <= '0';
      noise_freq_ctrl <= "00";
      noise_atten     <= "1111";
      noise_lfsr      <= "1000000000000000";
      latched         <= "000";

    elsif rising_edge(clk_cpu) then

      -- generate waveform
      if clk_cpu_count = "0000000" then

        for i in 0 to 2 loop
          -- tone channel attenuation
          if phase(i) = '1' then
            level(i) <= to_signed( vol(to_integer(unsigned(atten(i)))), 16);
          else
            level(i) <= to_signed(-vol(to_integer(unsigned(atten(i)))), 16);
          end if;
          -- tone channel advance
          if count(i) = "0000000001" then
            count(i) <= freq(i);
            phase(i) <= not phase(i);
          else
            count(i) <= count(i)-1;
          end if;
        end loop;

        -- noise channel attenuation
        if noise_lfsr(0) = '1' then
          noise_level <= to_signed( vol(to_integer(unsigned(noise_atten))), 16);
        else
          noise_level <= to_signed(-vol(to_integer(unsigned(noise_atten))), 16);
        end if;

        -- noise channel advance: the counter runs like a tone counter (half periods of 16, 32, 64 or tone 3's
        -- value), and the shift register shifts only on the rising edge of its flip-flop, once per full period:
        -- N/(16*16*2) = N/512, N/1024, N/2048 as the data sheet says
        if noise_count = "0000000001" then
          case noise_freq_ctrl is
            when "00" => noise_count <= "0000010000"; -- 16
            when "01" => noise_count <= "0000100000"; -- 16*2
            when "10" => noise_count <= "0001000000"; -- 16*4
            when "11" => noise_count <= freq(2);
          end case;
          noise_ff <= not noise_ff;
          if noise_ff = '0' then
            if noise_fb = '1' then
              noise_lfsr <= ( noise_lfsr(0) xor noise_lfsr(3) ) & noise_lfsr(15 downto 1);
            else
              noise_lfsr <=   noise_lfsr(0)                     & noise_lfsr(15 downto 1);
            end if;
          end if;
        else
          noise_count <= noise_count-1;
        end if;

        -- sum of levels is in the range -24000 to 24000
        o := resize(level(0), 18) + resize(level(1), 18) + resize(level(2), 18) + resize(noise_level, 18);

        -- soften the edges of the square waves a little, as the analog chip and TV speaker did:
        -- new value = new/2 + old/2 (the output is then averaged down to 48kHz in the top level)
        output_int <= shift_right(o, 1) + shift_right(output_int, 1);
        strobe_r   <= not strobe_r;

        -- how many clk_cpu's to ignore before generating wavefrom again (16 CPU clocks at the stock 4MHz: the tone
        -- counters then run at exactly N/16 = 250kHz)
        case div_cpu is
          when "000" =>
            clk_cpu_count <= "1100011"; -- 25.000MHz/(99+1) = 250000Hz
          when "001" =>
            clk_cpu_count <= "0110001"; -- 12.500MHz/(49+1) = 250000Hz
          when "010" =>
            clk_cpu_count <= "0100000"; --  8.333MHz/(32+1) = 252525Hz +1% error
          when "011" =>
            clk_cpu_count <= "0011000"; --  6.250MHz/(24+1) = 250000Hz
          when "100" =>
            clk_cpu_count <= "0010011"; --  5.000MHz/(19+1) = 250000Hz
          when "101" =>
            clk_cpu_count <= "0001111"; --  4.000MHz/(15+1) = 250000Hz (stock: exact)
          when "110" =>
            clk_cpu_count <= "0001101"; --  3.571MHz/(13+1) = 255102Hz +2% error
          when "111" =>
            clk_cpu_count <= "0001011"; --  3.125MHz/(11+1) = 260416Hz +4% error
        end case;
      else
        clk_cpu_count <= clk_cpu_count-1;
      end if;

      -- writes to sound registers
      if reg_we = '1' then
        if reg_value(7) = '1' then
          -- a first byte: latch the register address and write the low bits
          latched <= reg_value(6 downto 4);
          case reg_value(6 downto 4) is
            when "000" => freq(0)(3 downto 0) <= reg_value(3 downto 0);
            when "001" => atten(0) <= reg_value(3 downto 0);
            when "010" => freq(1)(3 downto 0) <= reg_value(3 downto 0);
            when "011" => atten(1) <= reg_value(3 downto 0);
            when "100" => freq(2)(3 downto 0) <= reg_value(3 downto 0);
            when "101" => atten(2) <= reg_value(3 downto 0);
            when "110" =>
              noise_fb        <= reg_value(2);
              noise_freq_ctrl <= reg_value(1 downto 0);
              noise_lfsr      <= "1000000000000000";
            when others => noise_atten <= reg_value(3 downto 0);
          end case;
        else
          -- a data byte: it goes to the register that was latched (the data sheet: "the register address is latched
          -- on the chip, so the data will continue going into the same register")
          case latched is
            when "000" => freq(0)(9 downto 4) <= reg_value(5 downto 0);
            when "010" => freq(1)(9 downto 4) <= reg_value(5 downto 0);
            when "100" => freq(2)(9 downto 4) <= reg_value(5 downto 0);
            when "001" => atten(0) <= reg_value(3 downto 0);
            when "011" => atten(1) <= reg_value(3 downto 0);
            when "101" => atten(2) <= reg_value(3 downto 0);
            when "110" =>
              noise_fb        <= reg_value(2);
              noise_freq_ctrl <= reg_value(1 downto 0);
              noise_lfsr      <= "1000000000000000";
            when others => noise_atten <= reg_value(3 downto 0);
          end case;
        end if;
      end if;

    end if;
  end process;

  output <= std_logic_vector(output_int(15 downto 0));
  strobe <= strobe_r;

end behavior;
