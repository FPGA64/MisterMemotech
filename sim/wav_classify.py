"""Decode the first tape file of every WAV with the OS algorithm (tape_model.py): does the BASIC loader come through?"""
import json, os, sys, zipfile
sys.path.insert(0, '.')
import tape_model as tm

ROOT = tm.BASE
w = lambda d, o: d[o] | (d[o + 1] << 8)
out = []
for folder in sorted(os.listdir(ROOT)):
    if '[WAV]' not in folder: continue
    for zn in sorted(os.listdir(ROOT + folder)):
        if not zn.endswith('.zip'): continue
        res = dict(zip=zn, ok=False, why='')
        try:
            z = zipfile.ZipFile(ROOT + folder + '/' + zn)
            nm = [i for i in z.infolist() if i.filename.lower().endswith('.wav')][0]
            fmt, data = tm.read_wav(ROOT + folder + '/' + zn)
            edges = tm.schmitt_edges(list(data), fmt[2])
            st = [0, 0.0]
            hdr = tm.decode(edges, 18, st)
            name = ''.join(chr(c) if 32 <= c < 127 else '?' for c in hdr[1:16]).rstrip()
            if hdr[0] != 0xFF:
                res['why'] = 'no valid tape header (first byte %02X)' % hdr[0]
            else:
                stk = w(hdr, 16); ns = 0xFB4B - stk
                if not (0x0100 < ns < 0xFFFF):
                    res['why'] = 'odd STKLIM %04X' % stk
                else:
                    sv = tm.decode(edges, ns, st)
                    arr = w(sv, 0xFACC - stk) | (sv[0xFACE - stk] << 16)
                    if arr > 0xB000:
                        res['why'] = 'odd program size %d' % arr
                    else:
                        prog = tm.decode(edges, arr, st)
                        res.update(ok=True, name=name, why='header, system variables and %d byte program decode' % arr)
        except Exception as ex:
            res['why'] = 'decode failed: %s' % ex
        out.append(res)
        print(zn[:50], res['ok'], res['why'], flush=True)
        json.dump(out, open('wavclass.json', 'w'))
