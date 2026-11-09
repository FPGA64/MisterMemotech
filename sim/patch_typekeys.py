"""make_cpm_integ.py: TYPEKEYS=1b,1b,1b,1b,1c,... types exactly these PS/2 set 2 codes (each key held KEY_MS, 60 ms between), instead of the fixed text."""
import os

P = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'make_cpm_integ.py')
s = open(P).read()
NL = chr(10)
a = "    marker = \"    grab_req <= '1';\""
assert a in s
new = '''    if os.environ.get('TYPEKEYS'):
        codes = os.environ['TYPEKEYS'].split(',')
        lines = ['    -- typing the codes ' + ' '.join(codes)]
        for c in codes:
            if c == 'ret':
                c = '5a'
            if c == 'wait':
                lines.append('    wait for 1500 ms;')
                continue
            lines.append('    kc <= "00" & x"%s"; ks <= \\'0\\'; kr <= \\'1\\'; wait for 5 us; kr <= \\'0\\'; wait for %d ms;' % (c, KEY_MS))
            lines.append('    ks <= \\'1\\'; kr <= \\'1\\'; wait for 5 us; kr <= \\'0\\'; wait for 60 ms;')
        lines.append('    wait for 1500 ms;')
        typing = NL.join(lines) + NL
'''
s = s.replace(a, new + a, 1)
open(P, 'w').write(s)
import ast
ast.parse(s)
print('patched, syntax ok')
