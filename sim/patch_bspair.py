"""OSD 'BackSpace in CP/M': BS only (default) or BS + DEL. mtx_kbd.vhd gets a bs_pair input, mtx.vhd and MTX512.sv pass it on."""
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


edit('rtl/mtx_kbd.vhd', [
    ("""              if shift = '1' and cpm_mode = '0' then bs_go := '1'; else k(18) <= '0'; end if;   -- shift = '0' when a shift key is down
              shifts(11) <= shift and not cpm_mode;""",
     """              -- BASIC: BS then DEL, or the plain BS key with a shift held. CP/M: the plain BS key, or the pair if OSD asks for it
              if ( cpm_mode = '0' and shift = '1' ) or ( cpm_mode = '1' and bs_pair = '1' ) then
                bs_go := '1'; shifts(11) <= '1';
              else
                k(18) <= '0'; shifts(11) <= '0';
              end if;"""),
    ("""    cpm_mode   : in  std_logic := '0'
    );""", """    cpm_mode   : in  std_logic := '0';
    -- (OSD "BackSpace in CP/M") 1 = BackSpace sends BS then DEL in CP/M too, as in BASIC (what the editor of FDXB, Disc BASIC, wants); 0 = BS only
    bs_pair    : in  std_logic := '0'
    );"""),
])
edit('rtl/mtx.vhd', [
    ("""    cpm_ok       : in  std_logic := '0';               -- the CP/M PROM has been loaded""",
     """    cpm_ok       : in  std_logic := '0';               -- the CP/M PROM has been loaded
    bs_pair      : in  std_logic := '0';               -- BackSpace in CP/M: 1 = BS then DEL, 0 = BS only"""),
    ("""      cpm_mode   => cpm_sel""", """      cpm_mode   => cpm_sel,
      bs_pair    => bs_pair"""),
])
edit('MTX512.sv', [
    ("""	"O[23],Disc ROM (restarts),SDX BASIC,CP/M;",""",
     """	"O[23],Disc ROM (restarts),SDX BASIC,CP/M;",
	"O[24],BackSpace in CP/M,BS only,BS + DEL;","""),
    ("""	.cpm_ok     (cpm_ok),""", """	.cpm_ok     (cpm_ok),
	.bs_pair    (status[24]),"""),
])
print('patched')
