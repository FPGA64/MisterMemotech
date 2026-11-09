"""Compile and run tb_sound_rates (the sound chip against the SN76489A data sheet) in ModelSim ASE."""
import os
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
MS = '<ModelSim ASE folder>/'
wd = os.path.join(HERE, 'work_sound')
shutil.rmtree(wd, ignore_errors=True)
os.makedirs(wd)
subprocess.run([MS + 'vlib.exe', 'work'], cwd=wd, check=True, stdout=subprocess.DEVNULL)

# ModelSim ASE wants every case on a std_logic_vector to list all metavalue combinations: a private copy of
# sound.vhd gets 'when others' where its two cases have none (rtl/ is untouched)
src = open(os.path.join(HERE, '..', 'rtl', 'sound.vhd'), newline='').read().replace('\r\n', '\n')
NL = chr(10)
a1 = '            when "11" => noise_count <= freq(2);' + NL + '          end case;'
b1 = '            when "11" => noise_count <= freq(2);' + NL + '            when others => null;' + NL + '          end case;'
a2 = '          when "111" =>' + NL + '            clk_cpu_count <= "0001011";'
assert a1 in src
src = src.replace(a1, b1, 1)
i = src.index(a2)
j = src.index('end case;', i)
src = src[:j] + 'when others => null;' + NL + '        ' + src[j:]
open(os.path.join(wd, 'sound.vhd'), 'w', newline='').write(src)

r = subprocess.run([MS + 'vcom.exe', '-quiet', '-2008', 'sound.vhd', os.path.join(HERE, 'tb_sound_rates.vhd')],
                   cwd=wd, capture_output=True, text=True)
print((r.stdout + r.stderr)[-2500:])
r = subprocess.run([MS + 'vsim.exe', '-c', '-quiet', 'work.tb_sound_rates', '-do', 'run -all; quit -f'],
                   cwd=wd, capture_output=True, text=True)
print(NL.join(l for l in r.stdout.split(NL) if l.strip() and 'metavalue' not in l and not l.startswith('#    Time'))[-3500:])
