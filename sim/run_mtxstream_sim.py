"""Run tb_mtxstream: a whole .mtx file through mtx_tape's stream FIFO (download, DDR3, handshake, rewind, EOF)."""
import glob
import os
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tape_model as tm

MS = '<ModelSim ASE folder>/'
stem = sys.argv[1] if len(sys.argv) > 1 else 'Toado (1984)(Continental Software)'
z = zipfile.ZipFile(glob.glob(tm.BASE + 'Memotech MTX - Games - [[]MTX[]]*/' + stem + '.zip')[0])
mtx = z.read(z.infolist()[0])
open(os.path.join(HERE, 'mtx.hex'), 'w').write('\n'.join('%02X' % b for b in mtx) + '\n')
print('mtx bytes', len(mtx))

subprocess.run([MS + 'vlib.exe', 'worksv2'], cwd=HERE, check=True, stdout=subprocess.DEVNULL)
r = subprocess.run([MS + 'vlog.exe', '-quiet', '-sv', '../rtl/mtx_tape.sv', 'tb_mtxstream.sv', '-work', 'worksv2'],
                   cwd=HERE, capture_output=True, text=True)
print((r.stdout + r.stderr)[-1200:])
r = subprocess.run([MS + 'vsim.exe', '-c', '-quiet', '-lib', 'worksv2', 'tb_mtxstream', '-do', 'run -all; quit -f'],
                   cwd=HERE, capture_output=True, text=True)
print('\n'.join([l for l in r.stdout.split('\n') if l.strip() and not l.startswith('# Time')][-12:]))
