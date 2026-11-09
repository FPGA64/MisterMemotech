"""MTX512.sv: the CP/M entries together, near the discs, with a CP/M: prefix; no automatic reset when Disc ROM is changed."""
import os

P = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'MTX512.sv')
s = open(P, newline='').read()
NL = chr(10)
crlf = chr(13) + NL in s
s = s.replace(chr(13) + NL, NL)


def rep(a, b):
    global s
    assert a in s, a[:80]
    s = s.replace(a, b, 1)


rep('''	"S2,MFLDSK,SDX Disc B;",
	"T[17],SDX: Type ROM 3 now (disc changed);",
	"O[16],SDX: Type ROM 3 when a disc is mounted,Off,On;",
	"O[13],SDX: ROM slot,ROM 3,ROM 5;",
	"O[23],Disc ROM (restarts),SDX BASIC,CP/M;",
	"-;",
	"O[18],RAM,64K (stock),320K (SDRAM);",
	"F2,ROMBIN,Load ROM 2 (HiSoft Pascal...);",
	"F3,CHRBIN,Load 80 col char ROM (8KB);",
	"O[22:21],Video output,Auto,VDP,80 column;",
	"-;",''', '''	"S2,MFLDSK,SDX Disc B;",
	"-;",
	"O[23],CP/M: Disc ROM (then Reset),SDX BASIC,CP/M;",
	"O[22:21],CP/M: Video output,Auto,VDP,80 column;",
	"F3,CHRBIN,CP/M: Load 80 col char ROM (8KB);",
	"-;",
	"T[17],SDX: Type ROM 3 now (disc changed);",
	"O[16],SDX: Type ROM 3 when a disc is mounted,Off,On;",
	"O[13],SDX: ROM slot,ROM 3,ROM 5;",
	"-;",
	"O[18],RAM,64K (stock),320K (SDRAM);",
	"F2,ROMBIN,Load ROM 2 (HiSoft Pascal...);",
	"-;",''')

a = s.index("// choosing the other disc ROM")
b = s.index("wire reset_core = ")
s = s[:a] + s[b:]
rep("wire reset_core = reset | rom_loading | ~os_ok | ~basic_ok | (sel_rst != 0);", "wire reset_core = reset | rom_loading | ~os_ok | ~basic_ok;")
open(P, 'w', newline='').write(s.replace(NL, chr(13) + NL) if crlf else s)
print('patched')
