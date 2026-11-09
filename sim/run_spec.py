"""Compile and run tb_spec (the Speculator board unit test) in ModelSim ASE."""
import os, subprocess
HERE = os.path.dirname(os.path.abspath(__file__))
MS = '<ModelSim ASE folder>/'
wd = os.path.join(HERE, 'work_spec')
import shutil
shutil.rmtree(wd, ignore_errors=True)
os.makedirs(wd)
subprocess.run([MS + 'vlib.exe', 'work'], cwd=wd, check=True, stdout=subprocess.DEVNULL)
r = subprocess.run([MS + 'vcom.exe', '-quiet', '-2008', os.path.join(HERE, '..', 'rtl', 'mtx_speculator.vhd'),
                    os.path.join(HERE, 'tb_spec.vhd')], cwd=wd, capture_output=True, text=True)
print(r.stdout + r.stderr)
r = subprocess.run([MS + 'vsim.exe', '-c', '-quiet', 'work.tb_spec', '-do', 'run -all; quit -f'], cwd=wd, capture_output=True, text=True)
print(r.stdout[-3000:] + r.stderr[-1000:])
