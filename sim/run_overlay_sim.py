"""Run tb_overlay in ModelSim: the INOUT overlay on a real Z80 with the stock OS ROM."""
import glob
import os
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tape_model as tm

MS = '<ModelSim ASE folder>/'
R = os.path.join(HERE, '..', 'rtl')

os_rom = open('<ROM folder>/os.rom', 'rb').read()
open(os.path.join(HERE, 'os.hex'), 'w').write('\n'.join('%02X' % b for b in os_rom) + '\n')

z = zipfile.ZipFile(glob.glob(tm.BASE + 'Memotech MTX - Games - [[]MTX[]]*/Toado (1984)(Continental Software).zip')[0])
mtx = z.read(z.infolist()[0])
open(os.path.join(HERE, 'stream.hex'), 'w').write('\n'.join('%02X' % b for b in mtx[:70]) + '\n')

subprocess.run([MS + 'vlib.exe', 'workov'], cwd=HERE, check=True, stdout=subprocess.DEVNULL)
files = [os.path.join(R, n) for n in ('T80_Pack.vhd', 'T80_Reg.vhd', 'T80_ALU.vhd', 'T80_MCode.vhd', 'T80.vhd',
                                       'T80a.vhd', 'T80se.vhd', 'mtx_overlay.vhd')] + ['tb_overlay.vhd']
r = subprocess.run([MS + 'vcom.exe', '-quiet', '-2008', '-nocheck', '-work', 'workov'] + files,
                   cwd=HERE, capture_output=True, text=True)
errs = [l for l in (r.stdout + r.stderr).split('\n') if 'Error' in l]
print('\n'.join(errs[:10]) if errs else 'compiled OK')
if errs:
    sys.exit(1)
r = subprocess.run([MS + 'vsim.exe', '-c', '-quiet', '-lib', 'workov', 'tb_overlay', '-do', 'run -all; quit -f'],
                   cwd=HERE, capture_output=True, text=True)
print('\n'.join([l for l in r.stdout.split('\n') if l.strip() and 'Time:' not in l and 'metavalue' not in l][-14:]))
