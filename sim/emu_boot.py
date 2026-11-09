import sys, time
sys.path.insert(0, '.')
import mtx_emu as e
m = e.MTX(None)
t = time.time()
for i in range(10):
    m.run(10)
    print(i, 'pc=%04X' % m.cpu.PC, 'instr', m.instr, 'ioport', hex(m.iobyte), 'vdp1=%02x' % m.vdp_regs[1], 'halted', m.cpu.halted, '%.1fs' % (time.time() - t))
print('\n'.join(m.screen()))
