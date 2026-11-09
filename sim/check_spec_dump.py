"""Compare the VHDL board (spec_dump.txt from tb_spec_dump.vhd) with the Python model in try_speculator.py."""
import try_speculator as t

b = t.Board()
n = bad = 0
for line in open('spec_dump.txt'):
    cyc, a, ramcs, keyio, addr = line.split()
    cyc, a, addr = int(cyc), int(a), int(addr)
    rd = cyc == 0
    exp = (int(bool(b.ramcs(a))), int(bool(b.keyio(a, rd))), b.addr(a, rd) if b.ramcs(a) else None)
    got = (int(ramcs), int(keyio), addr if exp[2] is not None else None)
    n += 1
    if exp != got:
        bad += 1
        if bad <= 10: print('MISMATCH', 'read' if rd else 'write', '%04X' % a, 'python', exp, 'vhdl', (int(ramcs), int(keyio), addr))
print(n, 'cases compared,', bad, 'mismatches')
