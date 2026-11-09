"""Run the SDRAM expansion RAM (rtl/sdram.sv, rtl/mtx_xsdram.sv) against the chip model in ModelSim.

    python run_xsdram.py [cycles]

Three bus speeds: the stock 4MHz (T states of 12 and 13 clocks of 50MHz), 6 clocks per T state and 2 clocks per T state (the
25MHz turbo). Prints the RESULT lines and PASS or FAIL for each.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MS = '<ModelSim ASE folder>/'
cycles = sys.argv[1] if len(sys.argv) > 1 else '3000'

subprocess.run(['cmd', '/c', 'rmdir', '/s', '/q', 'worksdram'], cwd=HERE, capture_output=True)
subprocess.run([MS + 'vlib.exe', 'worksdram'], cwd=HERE, check=True, stdout=subprocess.DEVNULL)
r = subprocess.run([MS + 'vlog.exe', '-quiet', '-sv', '+define+MTX_SIM', '../rtl/sdram.sv', '../rtl/mtx_xsdram.sv', 'sdram_model.sv',
                    'tb_xsdram.sv', '-work', 'worksdram'], cwd=HERE, capture_output=True, text=True)
print(r.stdout + r.stderr)
if r.returncode:
    raise SystemExit('compile failed')
ok = True
for tclk in ('0', '6', '2'):
    r = subprocess.run([MS + 'vsim.exe', '-c', '-quiet', '-lib', 'worksdram', '+TCLK=' + tclk, '+CYCLES=' + cycles, 'tb_xsdram',
                        '-do', 'run -all; quit -f'], cwd=HERE, capture_output=True, text=True)
    print('== TCLK', tclk, '(stock 12/13 clocks)' if tclk == '0' else '')
    out = r.stdout + r.stderr
    for l in out.split('\n'):
        if any(k in l for k in ('RESULT', 'PASS', 'FAIL', 'ERROR', 'MISMATCH', 'Error', 'Fatal')):
            print('  ', l.strip())
    ok = ok and ('PASS' in out) and ('FAIL' not in out)
print('ALL PASS' if ok else 'SOME FAILED')
