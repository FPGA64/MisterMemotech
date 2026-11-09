"""Run the ROM loader bench (rtl/mtx_romload.sv) in ModelSim: python run_romload.py"""
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
MS = '<ModelSim ASE folder>/'
subprocess.run(['cmd', '/c', 'rmdir', '/s', '/q', 'workrl'], cwd=HERE, capture_output=True)
subprocess.run([MS + 'vlib.exe', 'workrl'], cwd=HERE, check=True, stdout=subprocess.DEVNULL)
r = subprocess.run([MS + 'vlog.exe', '-quiet', '-sv', '../rtl/mtx_romload.sv', 'tb_romload.sv', '-work', 'workrl'], cwd=HERE, capture_output=True, text=True)
print(r.stdout + r.stderr)
if r.returncode:
    raise SystemExit('compile failed')
ok = True
for args, name in (([], 'signature'), (['+NOSIG'], 'no signature')):
    r = subprocess.run([MS + 'vsim.exe', '-c', '-quiet', '-lib', 'workrl'] + args + ['tb_romload', '-do', 'run -all; quit -f'],
                       cwd=HERE, capture_output=True, text=True)
    out = r.stdout + r.stderr
    print('==', name)
    for l in out.split('\n'):
        if any(k in l for k in ('RESULT', 'PASS', 'FAIL', 'ERROR', 'Error')):
            print('  ', l.strip())
    ok = ok and 'PASS' in out and 'FAIL' not in out
print('ALL PASS' if ok else 'SOME FAILED')
