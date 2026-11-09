"""Compile the core for ModelSim ASE.

ModelSim insists that every case on a std_logic_vector lists all 3^n metavalue combinations.
Quartus does not. To keep rtl/ untouched this script copies the VHDL to rtlsim/, adds an empty
'when others => null;' to each case ModelSim complains about, and compiles that.
"""
import os
import re
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
MS = '<ModelSim ASE folder>/'
SRC = os.path.join(HERE, '..', 'rtl')
DST = os.path.join(HERE, 'rtlsim')
FAST = os.environ.get('FAST') == '1'
TB = os.environ.get('TB', 'tb_mtx.vhd')
ORDER = ['T80_Pack', 'T80_Reg', 'T80_ALU', 'T80_MCode', 'T80', 'T80a', 'T80se', 'clock_divider', 'ctc',
         'sound', 'mtx_kbd', 'vdp_hex_char', 'vdp_hex', 'vdp_palette', 'vdp_vram', 'vdp', 'memory_map', 'mtx_joy', 'mtx_overlay', 'mtx_speculator', 'mtx_autorom', 'dart', 'mtx_col80']

shutil.rmtree(DST, ignore_errors=True)
os.makedirs(DST)
for n in ORDER + ['mtx']:
    shutil.copy(os.path.join(SRC, n + '.vhd'), os.path.join(DST, n + '.vhd'))
shutil.copy(os.path.join(HERE, 'RamRom_sim.vhd'), os.path.join(DST, 'RamRom_sim.vhd'))
if FAST:
    # stand-ins that simulate quickly: no 50MHz divider counters, no video pipeline
    for n in ('clock_divider', 'vdp', 'vdp_vram'):
        shutil.copy(os.path.join(HERE, 'stubs', n + '.vhd'), os.path.join(DST, n + '.vhd'))
    ORDER = [n for n in ORDER if n not in ('vdp_hex_char', 'vdp_hex', 'vdp_palette')]

# ModelSim ASE cannot index a type conversion: std_logic_vector(to_unsigned(x, n))(k) = '1'
pat = re.compile(r"std_logic_vector\(to_unsigned\((\w+),\s*\d+\)\)\((\d+)\)\s*=\s*'1'")
for n in ORDER:
    pth = os.path.join(DST, n + '.vhd')
    s = open(pth, encoding='utf-8', errors='replace', newline='').read()
    s2 = pat.sub(lambda m: "((%s / %d) mod 2 = 1)" % (m.group(1), 2 ** int(m.group(2))), s)
    if s2 != s:
        open(pth, 'w', encoding='utf-8', newline='').write(s2)
        print('rewrote index-of-conversion in', n)

shutil.rmtree(os.path.join(HERE, 'work'), ignore_errors=True)
subprocess.run([MS + 'vlib.exe', 'work'], cwd=HERE, check=True, stdout=subprocess.DEVNULL)
if os.environ.get('SDX') == '1':       # the SDX controller is SystemVerilog: into the same library before the bench
    subprocess.run([MS + 'vlog.exe', '-quiet', '-sv', os.path.join(SRC, 'sdx_fdc.sv')], cwd=HERE, check=True)


if os.environ.get('LOADER') == '1':    # the ROM loader of the top level (mtx_romload.sv)
    subprocess.run([MS + 'vlog.exe', '-quiet', '-sv', os.path.join(SRC, 'mtx_romload.sv')], cwd=HERE, check=True)

if os.environ.get('XSDRAM') == '1':    # the expansion RAM is in the SDRAM: wrapper, controller and a model of the chip
    subprocess.run([MS + 'vlog.exe', '-quiet', '-sv', '+define+MTX_SIM', os.path.join(SRC, 'sdram.sv'), os.path.join(SRC, 'mtx_xsdram.sv'),
                    os.path.join(HERE, 'sdram_model.sv')], cwd=HERE, check=True)


def vcom(files, std):
    r = subprocess.run([MS + 'vcom.exe', '-quiet', '-nocheck', std] + files, cwd=HERE, capture_output=True, text=True)
    return r.stdout + r.stderr


def patch(fname, line_no):
    path = os.path.join(DST, fname)
    lines = open(path, encoding='utf-8', errors='replace', newline='').read().split('\n')
    # find the 'end case' that closes the case statement starting at line_no (nesting aware)
    depth = 0
    for i in range(line_no - 1, len(lines)):
        s = lines[i].lower()
        s = re.sub(r'--.*', '', s)
        if re.search(r'\bcase\b', s) and not re.search(r'end\s+case', s):
            depth += 1
        if re.search(r'end\s+case', s):
            depth -= 1
            if depth == 0:
                indent = re.match(r'\s*', lines[i]).group(0)
                lines.insert(i, indent + '  when others => null;')
                open(path, 'w', encoding='utf-8', newline='').write('\n'.join(lines))
                return
    raise SystemExit('could not patch %s:%d' % (fname, line_no))


for rnd in range(40):
    out = vcom([os.path.join('rtlsim', n + '.vhd') for n in ORDER] + [os.path.join('rtlsim', 'RamRom_sim.vhd')], '-2008')
    errs = re.findall(r'\*\* Error: [^\n]*?rtlsim[\\/]([A-Za-z0-9_]+\.vhd)\((\d+)\): \(vcom-1339\)', out)
    if not errs:
        bad = [l for l in out.split('\n') if 'Error' in l]
        if bad:
            print('\n'.join(bad[:15]))
            raise SystemExit('compile errors')
        break
    f, ln = errs[0]
    patch(f, int(ln))
    print('patched case at %s:%s' % (f, ln))
else:
    raise SystemExit('too many rounds')

out = vcom([os.path.join('rtlsim', 'mtx.vhd'), TB], '-2008')
bad = [l for l in out.split('\n') if 'Error' in l]
print('\n'.join(bad[:15]) if bad else 'compiled OK')
