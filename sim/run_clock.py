"""Compile and run tb_clock (the clock divider against the real MTX clocks) in ModelSim ASE."""
import os, shutil, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
MS = '<ModelSim ASE folder>/'
wd = os.path.join(HERE, 'work_clock')
shutil.rmtree(wd, ignore_errors=True)
os.makedirs(wd)
subprocess.run([MS + 'vlib.exe', 'work'], cwd=wd, check=True, stdout=subprocess.DEVNULL)
r = subprocess.run([MS + 'vcom.exe', '-quiet', '-2008', os.path.join(HERE, '..', 'rtl', 'clock_divider.vhd'), os.path.join(HERE, 'tb_clock.vhd')],
                   cwd=wd, capture_output=True, text=True)
print((r.stdout + r.stderr)[-2500:])
r = subprocess.run([MS + 'vsim.exe', '-c', '-quiet', 'work.tb_clock', '-do', 'run -all; quit -f'], cwd=wd, capture_output=True, text=True)
print(chr(10).join(l for l in r.stdout.split(chr(10)) if l.strip() and 'metavalue' not in l and not l.startswith('#    Time'))[-3500:])
