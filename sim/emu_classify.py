"""Probe every .mtx in the collection with the Python MTX and write results to classify.json"""
import json, os, sys, zipfile
sys.path.insert(0, '.')
import emu_alive as ea

out = json.load(open('classify.json')) if os.path.exists('classify.json') else []
done = {(r['folder'], r['zip']) for r in out}
for folder in sorted(os.listdir(ea.ROOT)):
    fp = ea.ROOT + folder
    for zn in sorted(os.listdir(fp)):
        if not zn.lower().endswith('.zip'): continue
        if (folder, zn) in done: continue
        z = zipfile.ZipFile(fp + '/' + zn)
        for i in z.infolist():
            if i.filename.lower().endswith('.mtx'):
                r = ea.probe(z.read(i), 100)
                r.update(folder=folder, zip=zn, member=i.filename)
                out.append(r)
                print(zn[:50], r['read'], '/', r['n'], 'pc=%04X' % r['pc'], flush=True)
                json.dump(out, open('classify.json', 'w'))
