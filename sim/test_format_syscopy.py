"""USER FORMAT and USER SYSCOPY in the software MTX with the real SDX ROM (type 07 build, 640K discs) and the Python model of
the controller: format a blank disc, copy the system onto it (swapping discs when SYSCOPY asks), then use the new disc.

    python test_format_syscopy.py
"""
import sys
import time

sys.path.insert(0, '.')
import mtx_emu as e
from test_sdx import key, typ, last

TYPE = sys.argv[1] if len(sys.argv) > 1 else '07'                  # '07' (640K, 80 tracks) or '03' (320K, 40 tracks)
ROM = '<folder with boot.rom, boot1.rom, boot2.rom>/boot3.rom' if TYPE == '07' else '<project>/refs/memu_src/roms/sdx-type03.rom'
SYS = '<project>/refs/memu_src/mfloppy/andy_sys.mfloppy'
RET = [e.LAYOUT[chr(10)]]
SPACE = [e.LAYOUT[' ']]

sysdisc = bytearray(open(SYS, 'rb').read())
if TYPE == '03':
    # a type 03 system disc: the first 40 tracks (both sides) of the 640K system disc, with the type byte of the boot sector 03
    sysdisc = sysdisc[:327680]
    sysdisc[3] = 0x03
blank = bytearray(len(sysdisc))                       # a new disc: nothing on it at all
TRACKS = 40 if TYPE == '03' else 80
t0 = time.time()
log = []
m = e.MTX(None, sdx_rom=ROM, floppies=(sysdisc, None), sdx_slot=3)
m.fdc.mount(0, sysdisc, tracks=TRACKS)
m.run(80)
typ(m, 'ROM 3', 300)
print('ROM 3        ->', last(m, 2))

# ---- FORMAT: the formatter asks for the disc to be inserted, then RET
typ(m, 'USER FORMAT', 600)
print('USER FORMAT  ->', last(m, 4))
m.fdc.images[0] = blank                              # the user inserts the blank disc
n_wt = []
m.fdc.trace = lambda s: n_wt.append(s) if s.startswith('OUT 10,F') else None
key(m, RET, hold=10, gap=10)
for i in range(40):
    m.run(300)
    scr = ' '.join(last(m, 6))
    if 'End of formatting' in scr: break
print('after FORMAT ->', last(m, 4), '; write track commands:', len(n_wt), '; %.0f s' % (time.time() - t0))
m.fdc.trace = None

# ---- SYSCOPY: it asks for the source disc and then the destination disc
typ(m, 'ROM 3', 300)
print('ROM 3 again  ->', last(m, 2))
m.fdc.images[0] = sysdisc
typ(m, 'USER SYSCOPY', 400)
for step in range(12):
    scr = last(m, 6)
    text = ' '.join(scr)
    print('  SYSCOPY step %d ->' % step, scr[-3:])
    if 'Insert Source' in scr[-2] + scr[-1] if len(scr) >= 2 else False:
        m.fdc.images[0] = sysdisc
    elif 'Insert Destination' in ' '.join(scr[-2:]):
        m.fdc.images[0] = blank
    elif 'Ready' in scr[-1] and step > 0:
        break
    key(m, SPACE, hold=10, gap=10)
    m.run(1500)
print('after SYSCOPY ->', last(m, 4), '; %.0f s' % (time.time() - t0))

# ---- the new disc: log it in with ROM 3 and use it
m.fdc.images[0] = blank
typ(m, 'ROM 3', 300)
typ(m, 'USER DIR', 2500)
print('USER DIR on the new disc ->', last(m, 3))
typ(m, '10 PRINT "FORMATTED"', 30)
typ(m, 'USER SAVE "T.BAS"', 6000)
typ(m, 'USER DIR', 2500)
print('after USER SAVE ->', last(m, 3))
same_sys = sum(1 for i in range(6656) if blank[i] == sysdisc[i])
print('system area (first 6656 bytes) equal to the system disc: %d of 6656; total %.0f s' % (same_sys, time.time() - t0))
