"""Run mtx_tape's .tap player in ModelSim and decode the tape_in waveform with an independent Spectrum decoder.

    python run_tap_sim.py [short|full]

short (default): the pilot counts and the pause are shortened (PH=40, PD=20, PP=5000 clocks = 100us) so the whole
                 file plays in a couple of seconds of simulated time. The pulse lengths are the real ones.
full:            two tiny blocks with the real pilot counts (8063 and 3223) and the real one second pause; about
                 eight seconds of simulated time, so it takes a quarter of an hour.

The decoder knows only the published Spectrum timings (T-states of 3.5MHz): pilot 2168, sync 667 and 735, bit 0 two
pulses of 855, bit 1 two of 1710. It recovers every block, checks the parity byte, the pilot pulse count and the gap
between blocks.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MS = '<ModelSim ASE folder>/'
T_NS = 1e9 / 3.5e6                                   # one T-state in ns


def parity(b):
    p = 0
    for x in b: p ^= x
    return p


def block(flag, payload):
    b = bytes([flag]) + bytes(payload)
    b += bytes([parity(b)])
    return len(b).to_bytes(2, 'little') + b


def make_tap(mode):
    if mode == 'full':
        return [block(0x00, [0x5A]), block(0xFF, [0xA5])]
    hdr = bytes([3]) + b'TESTCODE  ' + (256).to_bytes(2, 'little') + (32768).to_bytes(2, 'little') + (32768).to_bytes(2, 'little')
    return [
        block(0x00, hdr),                              # a header block (flag 0)
        block(0xFF, range(256)),                       # every byte value
        block(0xFF, [0x00] * 8 + [0xFF] * 8 + [0xAA, 0x55] * 8),
        (0).to_bytes(2, 'little'),                     # an empty block: nothing to play
        block(0x00, b'END'),                           # a short block with a header flag
    ]


def near(t, ref, tol=0.03):
    return abs(t - ref) <= ref * tol


def decode(edges_ns, pilot_tol=0.03):
    """-> a list of dicts: bytes, pilot (pulses of pilot length), first and last edge index."""
    d = [(edges_ns[i + 1] - edges_ns[i]) / T_NS for i in range(len(edges_ns) - 1)]
    out = []
    i = 0
    while i < len(d):
        i0 = i
        n = 0
        while i < len(d) and near(d[i], 2168, pilot_tol):
            n += 1; i += 1
        if n < 10:
            i = max(i, i0 + 1)
            continue
        if i + 1 >= len(d) or not (near(d[i], 667) and near(d[i + 1], 735)):
            raise SystemExit('no sync after %d pilot pulses at pulse %d (%.0f, %.0f T)' % (n, i, d[i], d[i + 1] if i + 1 < len(d) else 0))
        i += 2
        bits = []
        while i + 1 < len(d):
            a, b = d[i], d[i + 1]
            if near(a, 855) and near(b, 855): bits.append(0)
            elif near(a, 1710) and near(b, 1710): bits.append(1)
            else: break
            i += 2
        if len(bits) % 8:
            raise SystemExit('block of %d bits' % len(bits))
        data = bytes(sum(bits[k + j] << (7 - j) for j in range(8)) for k in range(0, len(bits), 8))
        out.append({'bytes': data, 'pilot': n, 'first': i0, 'last': i})
    return out


def run(mode):
    blocks = make_tap(mode)
    tap = b''.join(blocks)
    open(os.path.join(HERE, 'tap.hex'), 'w').write('\n'.join('%02X' % b for b in tap) + '\n')
    subprocess.run([MS + 'vlib.exe', 'worksv3'], cwd=HERE, check=True, stdout=subprocess.DEVNULL)
    r = subprocess.run([MS + 'vlog.exe', '-quiet', '-sv', '../rtl/mtx_tape.sv', 'tb_tap.sv', '-work', 'worksv3'],
                       cwd=HERE, capture_output=True, text=True)
    if r.stdout.strip() or r.stderr.strip(): print((r.stdout + r.stderr)[-1500:])
    if mode == 'short':
        total_T = 0
        for blk in blocks:
            if int.from_bytes(blk[:2], 'little') == 0: continue
            data = blk[2:]
            total_T += (40 if data[0] < 128 else 20) * 2168 + 667 + 735
            for byte in data:
                for k in range(8):
                    total_T += 2 * (1710 if (byte >> k) & 1 else 855)
        run_us = int(total_T * T_NS / 1000) + 5 * 100 + 4000
        args = ['-gPH=40', '-gPD=20', '-gPP=5000', '-gRUN_US=%d' % run_us]
    else:
        args = ['-gRUN_US=8300000']
    print('simulating, mode', mode, args)
    r = subprocess.run([MS + 'vsim.exe', '-c', '-quiet', '-lib', 'worksv3'] + args + ['tb_tap', '-do', 'run -all; quit -f'],
                       cwd=HERE, capture_output=True, text=True)
    print('\n'.join(l for l in r.stdout.split('\n') if l.strip() and not l.startswith('# Time') and 'Warning' not in l)[-1500:])
    edges = [float(x) for x in open(os.path.join(HERE, 'tap_edges.txt')).read().split()]
    print(len(edges), 'edges')
    return blocks, edges


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'short'
    blocks, edges = run(mode)
    want = [b[2:] for b in blocks if len(b) > 2]
    got = decode(edges, 0.001 if mode == 'full' else 0.03)
    pil = [8063 if w[0] < 128 else 3223 for w in want] if mode == 'full' else [40 if w[0] < 128 else 20 for w in want]
    pause_ns = 50_000_000 * 20 if mode == 'full' else 5000 * 20
    print('decoded %d blocks, expected %d' % (len(got), len(want)))
    bad = len(got) != len(want)
    for k, (g, w) in enumerate(zip(got, want)):
        ok_b = g['bytes'] == w and parity(g['bytes']) == 0
        ok_p = g['pilot'] == pil[k]
        gap = ''
        ok_g = True
        if k > 0:
            ns = edges[g['first']] - edges[got[k - 1]['last']]
            ok_g = abs(ns - pause_ns) <= 3000          # the pause, within 3us (byte fetch latency)
            gap = ', gap to previous block %.3f ms (want %.3f) %s' % (ns / 1e6, pause_ns / 1e6, 'ok' if ok_g else 'WRONG')
        print('  block %d: %4d bytes, bytes %s, parity %s, pilot pulses %d (want %d) %s%s' %
              (k, len(g['bytes']), 'match' if g['bytes'] == w else 'DIFFER', 'ok' if parity(g['bytes']) == 0 else 'BAD',
               g['pilot'], pil[k], 'ok' if ok_p else 'WRONG', gap))
        bad += (not ok_b) + (not ok_p) + (not ok_g)
    print('RESULT:', 'PASS' if not bad else 'FAIL (%d problems)' % bad)


if __name__ == '__main__':
    main()
