"""Run LOAD "" on every .mtx in the collection with the Python MTX and classify the result."""
import os, sys, random, zipfile
sys.path.insert(0, '.')
import mtx_emu as e

ROOT = '<TOSEC collection folder>/'
seeds = [None] + [int(a) for a in sys.argv[1:]]
rows = []
for folder in sorted(os.listdir(ROOT)):
    fp = os.path.join(ROOT, folder)
    for zn in sorted(os.listdir(fp)):
        if not zn.lower().endswith('.zip'): continue
        z = zipfile.ZipFile(os.path.join(fp, zn))
        for i in z.infolist():
            if not i.filename.lower().endswith('.mtx'): continue
            d = z.read(i)
            res = []
            for sd in seeds:
                m = e.MTX(d)
                if sd is not None: m.rng = random.Random(sd)
                m.run(60)
                e.type_line(m, 'LOAD ""', hold=4)
                last = -1; same = 0
                for k in range(120):
                    m.run(10)
                    if m.sp == last: same += 1
                    else: same = 0
                    last = m.sp
                    if same >= 25 and (m.sp >= len(d) or m.sp > 0): break
                scr = [r for r in m.screen() if r.strip()]
                res.append((m.sp, m.rewinds, m.cpu.PC, m.cpu.halted, scr[-2:]))
            rows.append((zn[:46], len(d), res))
            sp, rw, pc, hl, scr = res[0]
            print('%-46s %6d  read %6d rew %d pc=%04X %s %s' % (zn[:46], len(d), sp, rw, pc, 'HALT' if hl else '    ', ' | '.join(s.strip() for s in scr)[:60]), flush=True)
