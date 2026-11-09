"""Boot the Python MTX, mount a .mtx, type LOAD "" and report where the machine ends up.
Usage: emu_load.py file.mtx|file.zip [seconds-of-emulated-frames]"""
import sys, zipfile
sys.path.insert(0, '.')
import mtx_emu as e


def load_stream(p):
    if p.lower().endswith('.zip'):
        z = zipfile.ZipFile(p)
        return z.read(z.infolist()[0])
    return open(p, 'rb').read()


def run(path, frames=3000, run_cmd=False, verbose=True):
    data = load_stream(path)
    m = e.MTX(data)
    m.run(40)
    e.type_line(m, 'LOAD ""')
    last = (-1, -1)
    stuck = 0
    for i in range(frames // 20):
        m.run(20)
        st = (m.sp, m.cpu.PC)
        if m.sp == last[0]: stuck += 1
        else: stuck = 0
        last = st
        if stuck > 15 and m.sp >= len(data): break
    if verbose:
        print('%s: stream %d/%d  rewinds %d  pc=%04X iobyte=%02X frames=%d' % (path.replace(chr(92), '/').split('/')[-1], m.sp, len(data), m.rewinds, m.cpu.PC, m.iobyte, m.frames))
        print('\n'.join(m.screen()))
    return m, data


if __name__ == '__main__':
    run(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 3000)
