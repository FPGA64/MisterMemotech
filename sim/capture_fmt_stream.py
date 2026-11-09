"""Run the real SDX USER FORMAT in the software MTX (type 07 build, 640K) and keep the bytes the formatter sends to the
controller for the first track (track 0, side 0): fmt_stream.bin. tb_mtx_sdxfmt.vhd plays them back into the real
controller code (rtl/sdx_fdc.sv) with the track and side patched.
"""
import sys

sys.path.insert(0, '.')
import mtx_emu as e
from test_sdx import key, typ, last

ROM = '<folder with boot.rom, boot1.rom, boot2.rom>/boot3.rom'
SYS = '<project>/refs/memu_src/mfloppy/andy_sys.mfloppy'
RET = [e.LAYOUT[chr(10)]]

sysdisc = bytearray(open(SYS, 'rb').read())
m = e.MTX(None, sdx_rom=ROM, floppies=(sysdisc, None), sdx_slot=3)
m.run(80)
typ(m, 'ROM 3', 300)
typ(m, 'USER FORMAT', 600)
m.fdc.images[0] = bytearray(len(sysdisc))
log = []
m.fdc.trace = log.append
key(m, RET, hold=10, gap=10)
for i in range(60):
    m.run(100)
    idx = [k for k, l in enumerate(log) if l.startswith('OUT 10,F4')]
    if len(idx) >= 2: break
first, second = idx[0], idx[1]
data = bytes(int(l.split(',')[1], 16) for l in log[first:second] if l.startswith('OUT 13'))
open('fmt_stream.bin', 'wb').write(data)
print('the formatter sent %d bytes for the first track' % len(data))
print('commands around it:', [l for l in log[max(0, first - 8):first + 1]])
print('other register writes during the stream:', sorted(set(l for l in log[first:second] if not l.startswith('OUT 13') and l.startswith('OUT'))))
reads = [l for l in log[first:second] if l.startswith('IN')]
print('register reads during the stream (kinds):', sorted(set(l.split(',')[0] for l in reads)))
# the ID fields: FE C H R N F7
ids = [(data[i + 1], data[i + 2], data[i + 3], data[i + 4]) for i in range(len(data) - 5) if data[i] == 0xFE and data[i + 5] == 0xF7]
print('ID fields (C, H, R, N):', ids)
