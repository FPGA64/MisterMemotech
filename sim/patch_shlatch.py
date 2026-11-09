"""1. take the OSD 'BackSpace in CP/M' option out again (BackSpace in CP/M is the plain BS key)
   2. CP/M mode: the shift and control keys are latched while another key is held (see the comment in the code)"""
import os

R = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..') + '/'
NL = chr(10)


def edit(p, pairs):
    s = open(R + p, newline='').read()
    crlf = chr(13) + NL in s
    s = s.replace(chr(13) + NL, NL)
    for a, b in pairs:
        assert a in s, (p, a[:80])
        s = s.replace(a, b, 1)
    open(R + p, 'w', newline='').write(s.replace(NL, chr(13) + NL) if crlf else s)


# 1. the option out
edit('MTX512.sv', [
    ("""	"O[24],BackSpace in CP/M,BS only,BS + DEL;",\n""", ""),
    ("""	.bs_pair    (status[24]),\n""", ""),
])
edit('rtl/mtx.vhd', [
    ("""    bs_pair      : in  std_logic := '0';               -- BackSpace in CP/M: 1 = BS then DEL, 0 = BS only\n""", ""),
    ("""      cpm_mode   => cpm_sel,
      bs_pair    => bs_pair""", """      cpm_mode   => cpm_sel"""),
])
edit('rtl/mtx_kbd.vhd', [
    ("""              -- BASIC: BS then DEL, or the plain BS key with a shift held. CP/M: the plain BS key, or the pair if OSD asks for it
              if ( cpm_mode = '0' and shift = '1' ) or ( cpm_mode = '1' and bs_pair = '1' ) then
                bs_go := '1'; shifts(11) <= '1';
              else
                k(18) <= '0'; shifts(11) <= '0';
              end if;""", """              if shift = '1' and cpm_mode = '0' then bs_go := '1'; else k(18) <= '0'; end if;   -- shift = '0' when a shift key is down
              shifts(11) <= shift and not cpm_mode;"""),
    ("""    cpm_mode   : in  std_logic := '0';
    -- (OSD "BackSpace in CP/M") 1 = BackSpace sends BS then DEL in CP/M too, as in BASIC (what the editor of FDXB, Disc BASIC, wants); 0 = BS only
    bs_pair    : in  std_logic := '0'
    );""", """    cpm_mode   : in  std_logic := '0'
    );"""),
    # 2. the latch
    ("""  signal km, cmask : std_logic_vector(79 downto 0);
""", """  signal km, cmask : std_logic_vector(79 downto 0);

  -- CP/M mode: the shift and control keys as the CPU sees them are frozen while another key is held (see below)
  signal kl : std_logic_vector(79 downto 0);
  signal any_key : std_logic;
  signal any_d   : std_logic := '0';
  signal lat60, lat66, lat20 : std_logic := '1';
"""),
    ("""  kx <= ( km(79 downto 39) & (km(38) and seqk(1)) & km(37 downto 19) & (km(18) and seqk(0)) & km(17 downto 0) ) and inj;""",
     """  -- The CP/M BIOS decides the character from the keys that are down at the moment it looks. If the shift (or control) key is let go
  -- while a letter is still down, the letter becomes a different character (S to s) and the BIOS types it a second time. So in CP/M
  -- mode the state of the shift, control keys is taken when the first other key goes down and kept until all the other keys are up.
  any_key <= '0' when ( km(79 downto 67) = "1111111111111" and km(65 downto 61) = "11111" and km(59 downto 41) = "1111111111111111111" and
                        km(39 downto 21) = "1111111111111111111" and km(19 downto 0) = x"FFFFF" ) else '1';
  process ( clk_1mhz )
  begin
    if rising_edge(clk_1mhz) then
      any_d <= any_key;
      if any_key = '1' and any_d = '0' then          -- the first key goes down: take the shift and control state
        lat60 <= km(60); lat66 <= km(66); lat20 <= km(20);
      end if;
    end if;
  end process;
  kl <= km when cpm_mode = '0' or any_key = '0' else
        ( km(79 downto 67) & lat66 & km(65 downto 61) & lat60 & km(59 downto 21) & lat20 & km(19 downto 0) );

  kx <= ( kl(79 downto 39) & (kl(38) and seqk(1)) & kl(37 downto 19) & (kl(18) and seqk(0)) & kl(17 downto 0) ) and inj;"""),
])
print('patched')
