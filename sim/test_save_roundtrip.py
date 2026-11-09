"""SAVE round trip in the software MTX: write a BASIC program, SAVE it, start a fresh machine (a reset) with the saved
tape, LOAD it, LIST/RUN it, then VERIFY it (once matching, once after a change)."""
import sys
sys.path.insert(0, '.')
import mtx_emu as e


def last(m, n=3):
    return [r for r in m.screen() if r.strip()][-n:]


def key(m, ks, shift=False, hold=8, gap=6):
    """one key press, with SHIFT held first and released last for shifted characters"""
    if shift:
        m.keys = {e.SHIFT}; m.run(4)
        m.keys = {e.SHIFT} | set(ks); m.run(hold)
        m.keys = {e.SHIFT}; m.run(3)
    else:
        m.keys = set(ks); m.run(hold)
    m.keys = set(); m.run(gap)


def typ(m, text, frames=120):
    for ch in text:
        if ch == '"': key(m, [e.LAYOUT['2']], shift=True)
        else: key(m, [e.LAYOUT[ch.upper()]])
    key(m, [e.LAYOUT[chr(10)]], hold=10, gap=10)
    m.run(frames)


errors = 0


def check(cond, what):
    global errors
    print(('ok   ' if cond else 'FAIL ') + what)
    if not cond: errors += 1


# ---- 1) write a BASIC program and SAVE it; the machine has a (blank) tape inserted so the overlay is active
m = e.MTX(b'')
m.run(80)
typ(m, '10 PRINT "HELLO WORLD"')
typ(m, '20 PRINT "SAVED OK"')
typ(m, 'RUN')
print('RUN        ->', last(m, 4))
check(any('HELLO WORLD' in r for r in last(m, 6)), 'the program runs before saving')
typ(m, 'SAVE "TEST"', 250)
print('SAVE       ->', last(m, 3))
saved = bytes(m.saved)
print('saved %d bytes, %d tape start(s); header %s' % (len(saved), m.save_starts, saved[:18].hex(' ')))
check(len(saved) > 18 and saved[0] == 0xFF and saved[1:5] == b'TEST', 'the saved tape starts with the FF header and the name TEST')
check(m.save_starts == 1, 'one tape was started')

# ---- 2) reset: a fresh machine with the saved tape inserted
r = e.MTX(saved)
r.run(80)
typ(r, 'LIST')
print('LIST (new) ->', last(r, 3), '  (nothing yet: the program is gone after the reset)')
typ(r, 'LOAD "TEST"', 250)
print('LOAD       ->', last(r, 3))
check(r.sp >= len(saved) - 1, 'LOAD read the whole saved tape (%d of %d bytes)' % (r.sp, len(saved)))
typ(r, 'LIST')
print('LIST       ->', last(r, 4))
check(any('PRINT "HELLO WORLD"' in x for x in last(r, 6)), 'LIST shows line 10 after loading')
typ(r, 'RUN')
print('RUN        ->', last(r, 4))
check(any('HELLO WORLD' in x for x in last(r, 6)) and any('SAVED OK' in x for x in last(r, 6)), 'the loaded program runs and prints both lines')

# ---- 3) VERIFY
typ(r, 'VERIFY "TEST"', 300)
print('VERIFY     ->', last(r, 3))
check(last(r, 1)[0].strip().upper().startswith('READY'), 'VERIFY of the unchanged program ends at Ready')
check('Mismatch' not in ' '.join(last(r, 3)), 'no Mismatch for the unchanged program')

# change a byte of the program in memory, then VERIFY again
prog = 0x4000 + 0x200
old = r.read(prog)
r.write(prog, (old + 1) & 0xFF)
typ(r, 'VERIFY "TEST"', 400)
print('VERIFY after a change ->', last(r, 3))
# the byte may be outside the saved program; try a few places until the compare fails
bad = 'Mismatch' in ' '.join(last(r, 3))
if not bad:
    for a in range(0x4000, 0x4400, 0x40):
        r2 = e.MTX(saved); r2.run(80); typ(r2, 'LOAD "TEST"', 250)
        r2.write(a, (r2.read(a) + 1) & 0xFF)
        typ(r2, 'VERIFY "TEST"', 400)
        if 'Mismatch' in ' '.join(last(r2, 3)):
            bad = True; print('VERIFY after changing %04X ->' % a, last(r2, 2)); break
check(bad, 'VERIFY reports Mismatch when memory differs from the tape')

# ---- 4) a wrong name
r3 = e.MTX(saved); r3.run(80)
typ(r3, 'LOAD "OTHER"', 250)
print('LOAD "OTHER" ->', last(r3, 2))
check('No data' in ' '.join(last(r3, 2)), 'LOAD of a name that is not on the tape gives No data')

# ---- 5) the saved file on the SD card is the tape followed by 00 up to 64 KB: load it again and again, no rewind
tape64 = saved + bytes(65536 - len(saved))
r4 = e.MTX(tape64)
r4.run(80)
for k, cmd in enumerate(('LOAD "TEST"', 'LOAD ""', 'LOAD "TEST"')):
    typ(r4, 'NEW')
    typ(r4, cmd, 250)
    typ(r4, 'LIST')
    ok = any('PRINT "HELLO WORLD"' in x for x in last(r4, 6)) and any('PRINT "SAVED OK"' in x for x in last(r4, 6))
    print('%-14s ->' % cmd, last(r4, 3))
    check(ok, 'load number %d from the 64 KB file (%s) gives the program' % (k + 1, cmd))
typ(r4, 'RUN')                      # VERIFY compares the OS system variables too: RUN puts them back as they were saved
typ(r4, 'VERIFY "TEST"', 300)
print('VERIFY         ->', last(r4, 2))
check(last(r4, 1)[0].strip().upper().startswith('READY') and 'No data' not in ' '.join(last(r4, 3)), 'VERIFY from the 64 KB file ends at Ready')

print('\nSAVE ROUND TRIP', 'PASSED' if errors == 0 else 'FAILED (%d)' % errors)
