"""Run mtx_tape in ModelSim on the start of a real WAV and compare its edges with tape_model.py.

Usage: run_tape_sim.py ["game stem"] [samples]
"""
import glob
import os
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tape_model as tm

MS = '<ModelSim ASE folder>/'
stem = sys.argv[1] if len(sys.argv) > 1 else 'Nemo (1983)(Continental Software)'
nsamp = int(sys.argv[2]) if len(sys.argv) > 2 else 8000

wzip = glob.glob(tm.BASE + 'Memotech MTX - Games - [[]WAV[]]*/' + stem + '.zip')[0]
z = zipfile.ZipFile(wzip)
w = z.read(z.infolist()[0])
off = w.index(b'data') + 8
cut = w[:off + nsamp]
open(os.path.join(HERE, 'wav.hex'), 'w').write('\n'.join('%02X' % b for b in cut) + '\n')
print('wav bytes', len(cut), 'header', off)

# expected edges from the model (microseconds)
rate = int.from_bytes(w[24:28], 'little')
exp = tm.schmitt_edges(list(w[off:off + nsamp]), rate)
print('model edges:', len(exp), 'rate', rate)

run_us = int(nsamp * 1e6 / rate) + 2000
subprocess.run([MS + 'vlib.exe', 'worksv'], cwd=HERE, check=True, stdout=subprocess.DEVNULL)
r = subprocess.run([MS + 'vlog.exe', '-quiet', '-sv', '../rtl/mtx_tape.sv', 'tb_tape.sv', '-work', 'worksv'],
                   cwd=HERE, capture_output=True, text=True)
print(r.stdout[-1500:], r.stderr[-1500:])
r = subprocess.run([MS + 'vsim.exe', '-c', '-quiet', '-lib', 'worksv', '-gRUN_US=%d' % run_us, 'tb_tape',
                    '-do', 'run -all; quit -f'], cwd=HERE, capture_output=True, text=True)
print('\n'.join([l for l in r.stdout.split('\n') if l.strip() and not l.startswith('# Time')][-12:]))

got = [int(l) / 1000.0 for l in open(os.path.join(HERE, 'edges_rtl.txt')) if l.strip()]   # ps -> ns?  $time is ns
print('rtl edges  :', len(got))
if got:
    t0 = got[0] - exp[0] if exp else 0
    n = min(len(got), len(exp))
    errs = [abs((got[i] - got[0]) - (exp[i] - exp[0])) for i in range(n)]
    print('edges compared %d, max timing difference %.3f us, mean %.3f us' % (n, max(errs), sum(errs) / n))
    print('first model edges (us):', [round(e, 1) for e in exp[:6]])
    print("first rtl edges   (us, relative):", [round((g - got[0]) + exp[0], 1) for g in got[:6]])
