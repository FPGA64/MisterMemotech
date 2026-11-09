"""Reference model of the MTX tape input chain, checked against real tapes.

 WAV samples -> Schmitt trigger (the op-amp) -> one pulse per edge (the 4070 XOR) -> CTC3 interrupt
 -> the OS decoder (INBIT / INBLOCK / INBYTE, ROM listing 0A53-0ADF) -> bytes

The OS decoder is emulated in time: each interrupt toggles Carry; INBIT counts in 14 T-state
steps (3.5us at 4MHz) between interrupt #1 and interrupt #2 and compares with MIDVAL (0xB0).

Usage: tape_model.py [wav-zip] [mtx-zip]    (defaults: a few pairs from the TOSEC set)
"""
import glob
import os
import struct
import sys
import zipfile

BASE = '<collection folder>/'
MIDVAL = 0xB0
STEP_US = 14 / 4.0          # 14 T-states at 4MHz
THRESH_US = (256 - MIDVAL) * STEP_US     # 280us: longer than this = carry set = bit 1
PROC_US = 40.0              # time the CPU needs between consuming an edge and arming the next wait


def read_wav(zp):
    z = zipfile.ZipFile(zp)
    w = z.read(z.infolist()[0])
    pos = 12
    fmt = None
    while pos + 8 <= len(w):
        cid = w[pos:pos + 4]
        sz = struct.unpack('<I', w[pos + 4:pos + 8])[0]
        if cid == b'fmt ':
            fmt = struct.unpack('<HHIIHH', w[pos + 8:pos + 24])
        if cid == b'data':
            return fmt, w[pos + 8:pos + 8 + sz]
        pos += 8 + sz + (sz & 1)
    raise ValueError('no data chunk')


def schmitt_edges(samples, rate, th=8, shift=8):
    """Edge times in microseconds. Slow DC tracker + hysteresis, as the RTL does it."""
    edges = []
    dc = samples[0] << shift
    state = None
    for n, s in enumerate(samples):
        dc += ((s << shift) - dc) >> shift
        x = s - (dc >> shift)
        new = state
        if x > th:
            new = 1
        elif x < -th:
            new = 0
        if state is not None and new != state:
            edges.append(n * 1e6 / rate)
        state = new
    return edges


def decode(edges, nbytes, state=None):
    """Emulate the OS loader: leader of short bits, long start pulse, then LSB-first bytes."""
    i = 0                      # index of the next edge not yet consumed
    t_free = 0.0               # CPU is busy until here
    if state:
        i, t_free = state

    def next_edge_after(t):
        nonlocal i
        while i < len(edges) and edges[i] < t:
            i += 1
        return i

    def inbit():
        """Wait for interrupt #1, time to interrupt #2. Returns bit (carry) or None at end."""
        nonlocal i, t_free
        j = next_edge_after(t_free)
        if j + 1 >= len(edges):
            return None
        d = edges[j + 1] - edges[j]
        t_free = edges[j + 1] + PROC_US
        i = j + 2
        return 1 if d > THRESH_US else 0

    # INBLOCK: 256 consecutive short (carry clear) bits
    run = 0
    while run < 256:
        b = inbit()
        if b is None:
            return None
        run = run + 1 if b == 0 else 0
    # STBIT: enter INBIT2 at an arbitrary moment (carry already set), wait for the next edge;
    # a wait longer than the threshold means the long start pulse.
    while True:
        j = next_edge_after(t_free)
        if j >= len(edges):
            return None
        wait = edges[j] - t_free
        t_free = edges[j] + PROC_US
        i = j + 1
        if wait > THRESH_US:
            break
    out = bytearray()
    for _ in range(nbytes):
        v = 0
        for k in range(8):
            b = inbit()
            if b is None:
                return bytes(out)
            v |= b << k
        out.append(v)
    if state is not None:
        state[:] = [i, t_free]
    return bytes(out)


def pair(stem):
    w = glob.glob(BASE + 'Memotech MTX - Games - [[]WAV[]]*/' + stem + '.zip')
    m = glob.glob(BASE + 'Memotech MTX - Games - [[]MTX[]]*/' + stem + '.zip')
    return (w[0], m[0]) if w and m else None


def check(stem, th=8):
    p = pair(stem)
    if not p:
        return None
    fmt, data = read_wav(p[0])
    rate = fmt[2]
    edges = schmitt_edges(list(data), rate, th=th)
    z = zipfile.ZipFile(p[1])
    mtx = z.read(z.infolist()[0])
    st = [0, 0.0]
    hdr = decode(edges, 18, st)
    stk = hdr[16] | (hdr[17] << 8) if hdr and len(hdr) == 18 else 0xF8F2
    n2 = 0xFB4B - stk
    blk2 = decode(edges, n2, st)
    got = (hdr or b'') + (blk2 or b'')
    return got, mtx[:18 + n2], len(edges)


if __name__ == '__main__':
    stems = sys.argv[1:] or ['Nemo (1983)(Continental Software)', 'Agrovator (1985)(Syntax Software)',
                              'Toado (1984)(Continental Software)', 'Mission Alphatron (1984)(Continental Software)',
                              'Arcazion (1985)(Sawyer, Chris)']
    print('threshold %.0f us' % THRESH_US)
    for s in stems:
        r = check(s)
        if r is None:
            print(s, ': no pair')
            continue
        got, want, ne = r
        print('%s: %d edges' % (s, ne))
        ok = got == want
        bad = sum(1 for a, b in zip(got, want) if a != b) + abs(len(got) - len(want))
        print('   header block + system variables block (%d bytes): %s, %d byte differences' % (len(want), 'IDENTICAL' if ok else 'DIFFERENT', bad))
        if not ok:
            print('   first 24 decoded:', got[:24].hex(' '))
            print('   first 24 file   :', want[:24].hex(' '))
