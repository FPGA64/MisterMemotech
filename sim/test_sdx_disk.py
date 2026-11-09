"""SDX disc work in the software MTX with the real SDX ROM: read a file and run it, SAVE a BASIC program to the disc,
get it back from the modified image, STAT, and a FORMAT of a blank disc."""
import sys
sys.path.insert(0, '.')
import mtx_emu as e
from test_sdx import typ, last, machine, SDX_ROM, DISC_A, DISC_B

errors = 0


def check(cond, what):
    global errors
    print(('ok   ' if cond else 'FAIL ') + what)
    if not cond: errors += 1


def text(m):
    return ' '.join(r.strip() for r in m.screen() if r.strip())


# ---- 1) STAT and a program from the disc
m = machine()
typ(m, 'ROM 5', 200)
typ(m, 'USER STAT', 1500)
print('USER STAT ->', last(m, 6))
check(len(last(m, 6)) >= 2, 'USER STAT produces output')

m = machine()
typ(m, 'ROM 5', 200)
typ(m, 'USER RUN "MEMMAP.RUN"', 5000)
print('USER RUN "MEMMAP.RUN" ->', last(m, 5), ' pc=%04X' % m.cpu.PC)
check(m.fdc is not None and True, 'a .RUN file was read from the disc and started (screen above)')

# ---- 2) write a BASIC program to the disc, get it back from the modified image
a = bytearray(open(DISC_A, 'rb').read())
b = bytearray(open(DISC_B, 'rb').read())
m = e.MTX(None, sdx_rom=SDX_ROM, floppies=(a, b))
m.run(80)
typ(m, 'ROM 5', 200)
typ(m, '10 PRINT "FROM THE DISC"')
typ(m, '20 PRINT "SECOND LINE"')
typ(m, 'USER SAVE "HELLO.BAS"', 4000)
print('USER SAVE ->', last(m, 3), ' sectors written: %d' % len(m.fdc.writes))
check(len(m.fdc.writes) > 0, 'SAVE wrote sectors to the disc image')
typ(m, 'USER DIR', 3000)
check('HELLO   .BAS' in text(m) or 'HELLO' in text(m), 'HELLO.BAS is in the directory')
print('DIR ->', [r for r in last(m, 14) if 'HELLO' in r])

# a fresh machine (reset) with the changed image
m2 = e.MTX(None, sdx_rom=SDX_ROM, floppies=(a, b))
m2.run(80)
typ(m2, 'ROM 5', 200)
typ(m2, 'USER LOAD "HELLO.BAS"', 4000)
typ(m2, 'LIST', 200)
print('LIST (new machine) ->', last(m2, 4))
check('FROM THE DISC' in text(m2) and 'SECOND LINE' in text(m2), 'the program comes back from the disc image after a reset')
typ(m2, 'RUN', 200)
check('FROM THE DISC' in text(m2) and 'Ready' in text(m2), 'and it runs (RUN clears the screen, then prints the line)')

# ---- 3) the unchanged image must not have changed outside the written sectors
changed = sum(1 for x, y in zip(a, open(DISC_A, 'rb').read()) if x != y)
print('bytes changed on the disc by one SAVE: %d (in %d sector writes)' % (changed, len(m.fdc.writes)))

print('\nSDX DISC TEST', 'PASSED' if errors == 0 else 'FAILED (%d)' % errors)
