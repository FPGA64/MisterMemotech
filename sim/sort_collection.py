"""Copy the TOSEC MTX collection into Working / Not working / Unverified folders (originals untouched)."""
import json, os, re, shutil, zipfile

SRC = '<TOSEC collection folder>/'
DST = '<output folder>/'
HERE = os.path.dirname(os.path.abspath(__file__))
cls = {(r['folder'], r['zip']): r for r in json.load(open(os.path.join(HERE, 'classify.json')))}
wav = {r['zip']: r for r in json.load(open(os.path.join(HERE, 'wavclass.json')))}
HW_OK = {'Pothole Pete (1984)(Continental Software).zip', 'Blobbo (1984)(Continental Software)[a2].zip'}


def kind(folder):
    for k in ('Games', 'Applications', 'Demos', 'Firmware'):
        if k in folder: return k
    return 'Other'


def base(zn):
    return re.sub(r'\[[^\]]*\]\.zip$|\.zip$', '', zn).strip()


wav_ok = {base(z): z for z, r in wav.items() if r['ok']}
rows = []          # (bucket, kind, fmt, zip, note)

for folder in sorted(os.listdir(SRC)):
    for zn in sorted(os.listdir(SRC + folder)):
        if not zn.lower().endswith('.zip'): continue
        k = kind(folder)
        names = [i.filename.lower() for i in zipfile.ZipFile(SRC + folder + '/' + zn).infolist()]
        if any(n.endswith('.mtx') for n in names):
            r = cls[(folder, zn)]
            alt = wav_ok.get(base(zn))
            alt_txt = ' WAV version: %s' % alt if alt else ''
            alive_gfx = (all(set(x.strip()) <= {'.'} for x in r['screen']) and
                         (r['vram_writes'] > 0 or r['kbd'] > 0 or r['sound'] > 0 or r['halted']))
            extra_ok = r['read'] < r['n'] and r['n'] - r['read'] <= 200 and alive_gfx
            # the core fills a short file with FF past its end; a few bytes (a missing end marker) are fine, but
            # a program that reads thousands of bytes past the end is truncated
            ran_dry = r.get('eof_waits', 0) > 50
            if (r['read'] >= r['n'] or extra_ok) and r['rew'] == 0 and r['pc'] >= 0x100 and not ran_dry:
                note = 'loads and runs in the emulator test'
                if r['read'] < r['n']: note += ' (the file has %d unused bytes at the end)' % (r['n'] - r['read'])
                if zn in HW_OK: note = 'loads and runs (checked on the MiSTer)'
                elif not r['halted'] and r['vram_writes'] == 0 and r['kbd'] == 0 and r['sound'] == 0:
                    note = 'loads fully; the test saw no keyboard/screen activity afterwards (may be busy or waiting)'
                rows.append(('Working', k, 'MTX', zn, folder, note))
            else:
                if ran_dry:
                    why = 'the file is truncated: the OS reads far past its end (the core fills that with FF).' + alt_txt
                elif r['read'] >= r['n'] and r['pc'] < 0x100:
                    why = 'loads, then crashes: it needs a second tape file or its own loader.' + alt_txt
                elif r['rew'] > 0:
                    why = 'asks for another tape file that is not in the .mtx (waits at the end).' + alt_txt
                else:
                    why = 'stops after %d of %d bytes: file does not match its own tape header or is not a BASIC tape.%s' % (r['read'], r['n'], alt_txt)
                rows.append(('Not working', k, 'MTX', zn, folder, why))
        elif any(n.endswith('.wav') for n in names):
            r = wav[zn]
            if r['ok']: rows.append(('Working', k, 'WAV', zn, folder, 'first tape file decodes with the OS algorithm (play in real time)'))
            else: rows.append(('Unverified', k, 'WAV', zn, folder, 'could not confirm the first tape file in the test (%s); may still load' % r['why']))
        else:
            rows.append(('Unverified', k, 'Other', zn, folder, 'not a tape image (no .mtx or .wav inside)'))

import sys
if os.path.exists(DST) and '--overwrite' not in sys.argv:
    raise SystemExit('%s exists (it may hold files you added); pass --overwrite to rebuild it' % DST)
shutil.rmtree(DST, ignore_errors=True)
for bucket, k, fmt, zn, folder, note in rows:
    d = os.path.join(DST, bucket, fmt if fmt != 'Other' else 'Not tapes', k)
    os.makedirs(d, exist_ok=True)
    shutil.copy2(SRC + folder + '/' + zn, os.path.join(d, zn))

lines = ['MTX collection sorted by whether it loads on the MiSTer MTX512 core.',
         'Copies only: the original collection is untouched.',
         '',
         'Working     = loads in the core (MTX = instant load via OSD Insert Tape, WAV = plays in real time).',
         'Not working = this .mtx does not load; where a WAV of the same game exists it is named.',
         'Unverified = could not be checked (see the reason).',
         '',
         'How it was tested: the .mtx files were loaded with LOAD "" in a software MTX (sim/mtx_emu.py) that runs the',
         'real ROMs and the exact loader code in the FPGA core; the WAVs were decoded with the OS tape algorithm.',
         'Only the items marked "checked on the MiSTer" were seen working on real hardware.', '']
for bucket in ('Working', 'Not working', 'Unverified'):
    lines.append('== %s' % bucket)
    for b, k, fmt, zn, folder, note in rows:
        if b == bucket: lines.append('  [%s %s] %s : %s' % (fmt, k, zn, note))
    lines.append('')
open(DST + 'INDEX.txt', 'w', encoding='ascii', errors='replace').write('\n'.join(lines))
from collections import Counter
print(Counter((b, f) for b, k, f, z, fo, n in rows))
