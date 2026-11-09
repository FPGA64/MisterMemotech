"""Load a .mtx in the Python MTX and report whether the program is alive afterwards."""
import sys, zipfile, collections
sys.path.insert(0, '.')
import mtx_emu as e

ROOT = '<TOSEC collection folder>/'


def probe(data, frames_after=150):
    m = e.MTX(data)
    cnt = collections.Counter()
    oi, oo = m.in_, m.out

    def in_(p, hi=0):
        cnt['in%02X' % (p & 0xFF)] += 1
        return oi(p, hi)

    def out(p, v, hi=0):
        cnt['out%02X' % (p & 0xFF)] += 1
        oo(p, v, hi)
    m.in_, m.out = in_, out
    m.run(60)
    e.type_line(m, 'LOAD ""', hold=4)
    last = -1; same = 0
    for k in range(150):
        m.run(10)
        same = same + 1 if m.sp == last else 0
        last = m.sp
        if same >= 20 and m.sp > 0: break
    done = m.sp >= len(data)
    cnt.clear()
    v0 = bytes(m.vram)
    pcs = set()
    for f in range(frames_after // 10):
        m.run(10)
        pcs.add(m.cpu.PC)
    vch = sum(1 for a, b in zip(v0, m.vram) if a != b)
    return dict(read=m.sp, n=len(data), done=done, rew=m.rewinds, pc=m.cpu.PC, halted=m.cpu.halted,
                eof_waits=m.eof_waits,
                vram_writes=cnt['out01'], vram_changed=vch, kbd=cnt['in05'], sound=cnt['in03'], vdp_regs=list(m.vdp_regs),
                screen=[r for r in m.screen() if r.strip()][-2:])


if __name__ == '__main__':
    import os, fnmatch
    gd = ROOT + [d for d in os.listdir(ROOT) if '[MTX]' in d][0] + '/'
    for pat in sys.argv[1:]:
        for f in sorted(gd + n for n in os.listdir(gd) if fnmatch.fnmatchcase(n, pat)):
            z = zipfile.ZipFile(f)
            r = probe(z.read(z.infolist()[0]))
            print(f.replace(chr(92), '/').split('/')[-1][:44], {k: v for k, v in r.items() if k != 'vdp_regs'})
