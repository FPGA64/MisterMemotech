"""Add the CP/M key shaping to rtl/mtx_kbd.vhd (see the comment in the code)."""
import os

P = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'rtl', 'mtx_kbd.vhd')
s = open(P, newline='').read()
crlf = chr(13) + chr(10) in s
s = s.replace(chr(13) + chr(10), chr(10))


def rep(a, b):
    global s
    assert a in s, a[:80]
    s = s.replace(a, b, 1)


rep("  signal km, cmask : std_logic_vector(79 downto 0);\n", """  signal km, cmask : std_logic_vector(79 downto 0);

  -- CP/M mode: every key press is shaped (see the process below). kq = the keys after shaping
  signal kq : std_logic_vector(79 downto 0) := (others => '1');
  type cnt_t is array (0 to 79) of integer range 0 to 1023;
  type st_t  is array (0 to 79) of integer range 0 to 3;
  signal c_cnt : cnt_t := (others => 0);
  signal c_st  : st_t  := (others => 0);
  signal c_rep : std_logic_vector(79 downto 0) := (others => '0');
  signal tick  : std_logic := '0';
  signal tick_cnt : integer range 0 to 49999 := 0;
  constant K_MIN    : integer := 60;     -- ms: a press is seen for at least this long (a short tap is stretched)
  constant K_CAP    : integer := 90;     -- ms: and for at most this long (a key held down is released; the core repeats it)
  constant K_GAP    : integer := 40;     -- ms: between two presses of the same key
  constant K_REPDEL : integer := 450;    -- ms: a key held this long starts repeating
  constant K_REPGAP : integer := 60;     -- ms: between repeats
  signal kx_src : std_logic_vector(79 downto 0);
""")

old_kx = "  kx <= ( km(79 downto 39) & (km(38) and seqk(1)) & km(37 downto 19) & (km(18) and seqk(0)) & km(17 downto 0) ) and inj;"
new_kx = """  -- in CP/M mode the keys are shaped, except the shift, control and caps keys (they must stay down as long as they are held)
  kx_src <= km when cpm_mode = '0' else
            ( kq(79 downto 67) & km(66) & kq(65 downto 61) & km(60) & kq(59 downto 41) & km(40) & kq(39 downto 21) & km(20) & kq(19 downto 0) );

  kx <= ( kx_src(79 downto 39) & (kx_src(38) and seqk(1)) & kx_src(37 downto 19) & (kx_src(18) and seqk(0)) & kx_src(17 downto 0) ) and inj;

  -- Key shaping for CP/M. The CP/M BIOS reads the keyboard only now and then (it is busy while it draws the screen or reads the
  -- disc) and times its own auto-repeat by counting its polls, so a short tap can fall between two polls and be lost, and a key held a
  -- little long gets a second character. Here each press is made to last 60 to 90 ms, with 40 ms between two presses of a key; a key
  -- held down for 450 ms repeats every 60 ms. (The MTX OS does its own, so this is only on with the CP/M ROM.)
  process ( clk_1mhz )
    variable raw : std_logic;
  begin
    if rising_edge(clk_1mhz) then
      if tick_cnt = 49999 then tick_cnt <= 0; tick <= '1'; else tick_cnt <= tick_cnt + 1; tick <= '0'; end if;
      for i in 0 to 79 loop
        raw := km(i);
        case c_st(i) is
          when 0 =>                                   -- idle: wait for a press
            kq(i) <= '1';
            c_rep(i) <= '0';
            if raw = '0' then kq(i) <= '0'; c_st(i) <= 1; c_cnt(i) <= 0; end if;
          when 1 =>                                   -- down
            kq(i) <= '0';
            if tick = '1' then
              if c_cnt(i) < 1000 then c_cnt(i) <= c_cnt(i) + 1; end if;
              if raw = '1' and c_cnt(i) >= K_MIN then
                kq(i) <= '1'; c_st(i) <= 2; c_cnt(i) <= 0;
              elsif c_cnt(i) >= K_CAP then
                kq(i) <= '1'; c_st(i) <= 3; c_cnt(i) <= 0;
              end if;
            end if;
          when 2 =>                                   -- gap after a press that was let go
            kq(i) <= '1';
            if raw = '1' then c_rep(i) <= '0'; end if;
            if tick = '1' then
              if c_cnt(i) >= K_GAP then c_st(i) <= 0; else c_cnt(i) <= c_cnt(i) + 1; end if;
            end if;
          when others =>                              -- still held after the cap: released here, repeated later
            kq(i) <= '1';
            if raw = '1' then
              c_st(i) <= 2; c_cnt(i) <= 0; c_rep(i) <= '0';
            elsif tick = '1' then
              if c_cnt(i) >= (K_REPGAP - 1) and c_rep(i) = '1' then
                c_st(i) <= 1; c_cnt(i) <= 0;
              elsif c_cnt(i) >= (K_REPDEL - K_CAP) and c_rep(i) = '0' then
                c_st(i) <= 1; c_cnt(i) <= 0; c_rep(i) <= '1';
              elsif c_cnt(i) < 1000 then
                c_cnt(i) <= c_cnt(i) + 1;
              end if;
            end if;
        end case;
      end loop;
    end if;
  end process;"""
rep(old_kx, new_kx)
open(P, 'w', newline='').write(s.replace(chr(10), chr(13) + chr(10)) if crlf else s)
print('patched mtx_kbd.vhd')
