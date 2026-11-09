"""Assemble the INOUT overlay and write rtl/mtx_overlay.vhd.

When a .mtx file is mounted the OS routine INOUT (0AAE..0B05) is replaced by this routine, which
copies the next DE bytes of the .mtx stream to (HL) instead of decoding tape pulses.
VERIFY compares instead of storing (error 11 Mismatch); LOAD "NAME" with a name that is not on the tape gives error 15 No data
(the core does the comparison, port 8D). SAVE streams its bytes to the save image (ports 8E, 8F).
Contract (from the ROM listing and MEMU): HL = address, DE = byte count, (FD68) = 0 SAVE / else
LOAD or VERIFY, (FD67) = non-zero VERIFY. A file's first chunk is the 18 byte header read to C011.
Exit through RESint (0B06), exactly as the OS routine does.

Ports:  8E  read: next byte of the .mtx stream
        8F  write bit 0: rewind the stream   read: bit 0 = a byte is ready, bit 1 = end of file
"""
import os

BASE = 0x0A60           # start of the window: the unused tape bit routines below INOUT hold the helpers
ENTRY = 0x0AAE          # INOUT itself
LIMIT = 0x0B06           # RESint starts here; the window must end before it
RESINT = 0x0B06
SETINT = 0x0B10

prog = []                # (kind, value) : ('b', byte) | ('label', name) | ('rel', name) | ('abs', name)


def b(*vals):
    for v in vals:
        prog.append(('b', v))


def label(n):
    prog.append(('label', n))


def rel(n):
    prog.append(('rel', n))


def jp(op, target):
    prog.append(('b', op))
    prog.append(('abs', target))


# ---- helpers, in the window below INOUT (reached by jumps from the routine at ENTRY)
label('done')                   # the copy is finished (LOAD or VERIFY)
b(0x21, 0x02, 0xC0)             # LD HL,C002            the name asked for, 15 characters
b(0x01, 0x8D, 0x0F)             # LD BC,0F8D            B = 15, C = port 8D
b(0xED, 0xB3)                   # OTIR                  send it; the core compares it with the name on the tape when a
b(0xDB, 0x8D)                   # IN A,(8D)             header chunk has just been read. 1 = not the tape asked for
b(0xA7)                         # AND A
b(0x28); rel('ok')              # JR Z,ok
b(0xCD); prog.append(('abs', RESINT)); b(0xEF, 0x0F)           # CALL RESint / RST 28 / DB 15      No data
label('ok')
jp(0xC3, RESINT)                # JP RESint
label('save')                   # SAVE: HL = data, DE = length
b(0x7B, 0xFE, 0x14); b(0x20); rel('sdat')       # LD A,E / CP 20 / JR NZ,sdat   the ROM writes the header as 20 bytes:
b(0x7A, 0xA7); b(0x20); rel('sdat')             # LD A,D / AND A / JR NZ,sdat   the last 2 are not part of it
b(0x7C, 0xFE, 0xC0); b(0x20); rel('sdat')       # LD A,H / CP C0 / JR NZ,sdat   (the header is at C001)
b(0x3E, 0x02, 0xD3, 0x8F)       # LD A,2 / OUT (8F),A   a new tape starts
b(0x1B, 0x1B)                   # DEC DE / DEC DE
label('sdat')
b(0xDB, 0x8F, 0xCB, 0x57)       # IN A,(8F) / BIT 2,A   wait while a block is being written
b(0x20); rel('sdat')            # JR NZ,sdat
b(0x7E, 0xD3, 0x8E)             # LD A,(HL) / OUT (8E),A
b(0x23, 0x1B, 0x7A, 0xB3)       # INC HL / DEC DE / LD A,D / OR E
b(0x20); rel('sdat')            # JR NZ,sdat
b(0x3E, 0x04, 0xD3, 0x8F)       # LD A,4 / OUT (8F),A   the chunk is complete: write out what is buffered
jp(0xC3, RESINT)                # JP RESint
label('mm')                     # VERIFY found a difference
b(0xCD); prog.append(('abs', RESINT)); b(0xEF, 0x0B)           # CALL RESint / RST 28 / DB 11      Mismatch
label('brk')                    # BREAK pressed
b(0xCD); prog.append(('abs', RESINT)); b(0xEF, 0x3E)           # CALL RESint / RST 28 / DB 62      Break, as in the OS
prog.append(('pad', ENTRY))

# ---- INOUT
label('start')
b(0x7A)                         # LD A,D
b(0xB3)                         # OR E
b(0xC8)                         # RET Z
b(0xCD); prog.append(('abs', SETINT))   # CALL SETint     exactly what the OS routine does first: the interrupt table
                                #                       is pointed at do-nothing handlers (the block being loaded
                                #                       includes the system variables the real handlers use), and
                                #                       timer ticks are acknowledged while we copy. DI would instead
                                #                       leave one pending that fires the moment we return
label('chk')
b(0x3E, 0xFE)                   # LD A,FEh              keyboard column 0 ...
b(0xD3, 0x05)                   # OUT (05),A
b(0xDB, 0x06)                   # IN A,(06)             ... bit 0 low = BREAK pressed (as BLIP in the OS)
b(0xCB, 0x47)                   # BIT 0,A
b(0x28); rel('brk')             # JR Z,brk
b(0x3A, 0x68, 0xFD)             # LD A,(FD68)
b(0xA7)                         # AND A
jp(0xCA, 'save')                # JP Z,save
b(0x7B)                         # LD A,E
b(0xFE, 0x12)                   # CP 12h
b(0x20); rel('body')            # JR NZ,body
b(0x7A)                         # LD A,D
b(0xA7)                         # AND A
b(0x20); rel('body')            # JR NZ,body
b(0x7C)                         # LD A,H
b(0xFE, 0xC0)                   # CP C0h
b(0x20); rel('body')            # JR NZ,body
b(0x7D)                         # LD A,L
b(0xFE, 0x11)                   # CP 11h                LOAD reads the header to C011 ...
b(0x28); rel('hdr')             # JR Z,hdr
b(0xFE, 0x22)                   # CP 22h                ... VERIFY reads the tape's header to C022
b(0x20); rel('body')            # JR NZ,body
label('hdr')
b(0xDB, 0x8F)                   # IN A,(8F)             a header chunk with the stream at its end:
b(0xE6, 0x02)                   # AND 2                 start the tape again from the beginning
b(0x28); rel('body')            # JR Z,body
b(0x3E, 0x01)                   # LD A,1
b(0xD3, 0x8F)                   # OUT (8F),A
label('body')
b(0x3A, 0x67, 0xFD)             # LD A,(FD67)
b(0x47)                         # LD B,A                (non-zero: VERIFY, compare instead of store)
label('loop')
b(0xDB, 0x8F)                   # IN A,(8F)
b(0x1F)                         # RRA                   (carry = byte ready; past the end of the file the stream
b(0x30); rel('loop')            # JR NC,loop             stays ready and gives FF, so this only waits for the buffer)
b(0xDB, 0x8E)                   # IN A,(8E)
b(0x4F)                         # LD C,A
b(0x78)                         # LD A,B
b(0xA7)                         # AND A
b(0x28); rel('store')           # JR Z,store
b(0x7E)                         # LD A,(HL)             VERIFY
b(0xB9)                         # CP C
b(0x20); rel('mm')              # JR NZ,mm
b(0x18); rel('skip')            # JR skip
label('store')
b(0x71)                         # LD (HL),C
label('skip')
b(0x23)                         # INC HL
b(0x1B)                         # DEC DE
b(0x7A)                         # LD A,D
b(0xB3)                         # OR E
b(0x20); rel('loop')            # JR NZ,loop
jp(0xC3, 'done')                # JP done               (checks the tape name after a header chunk)

# pass 1: addresses
addr = BASE
labels = {}
for kind, v in prog:
    if kind == 'label':
        labels[v] = addr
    elif kind == 'b' or kind == 'rel':
        addr += 1
    elif kind == 'abs':
        addr += 2
    elif kind == 'pad':
        assert addr <= v, 'helpers overrun the entry point'
        addr = v
size = addr - BASE
assert BASE + size <= LIMIT, 'overlay is %d bytes, only %d fit' % (size, LIMIT - BASE)

# pass 2: bytes
out = []
addr = BASE
for kind, v in prog:
    if kind == 'label':
        continue
    if kind == 'b':
        out.append(v)
        addr += 1
    elif kind == 'rel':
        d = labels[v] - (addr + 1)
        assert -128 <= d <= 127, (v, d)
        out.append(d & 0xFF)
        addr += 1
    elif kind == 'abs':
        t = v if isinstance(v, int) else labels[v]
        out += [t & 0xFF, t >> 8]
        addr += 2
    elif kind == 'pad':
        out += [0x00] * (v - addr)
        addr = v

window = LIMIT - BASE
out += [0x00] * (window - len(out))
print('overlay %d bytes of %d' % (size, window))
print(' '.join('%02X' % x for x in out[:size]))

vhd = []
vhd.append('--')
vhd.append('-- mtx_overlay.vhd - replacement for the OS tape routine INOUT (0AAE..0B05) and the tape bit routines below it (0A60..0AAD)')
vhd.append('--')
vhd.append('-- Generated by sim/make_overlay.py. Copies the next DE bytes of the .mtx stream to (HL).')
vhd.append('-- HL = address, DE = byte count, (FD68) = 0 SAVE, (FD67) <> 0 VERIFY. A 18 byte read to C011')
vhd.append('-- starts a new file (rewind). VERIFY compares; a name not on the tape gives No data. Leaves through RESint (0B06).')
vhd.append('-- Ports: 8E read = next byte; 8F write bit 0 = rewind, read bit 0 = byte ready, bit 1 = end of file.')
vhd.append('--')
vhd.append('')
vhd.append('library IEEE;')
vhd.append('use IEEE.STD_LOGIC_1164.ALL;')
vhd.append('use IEEE.NUMERIC_STD.ALL;')
vhd.append('')
vhd.append('entity mtx_overlay is')
vhd.append('  port')
vhd.append('    (')
vhd.append('    addr : in  std_logic_vector(15 downto 0);')
vhd.append('    hit  : out std_logic;                       -- this address is served by the overlay')
vhd.append('    q    : out std_logic_vector(7 downto 0)')
vhd.append('    );')
vhd.append('end mtx_overlay;')
vhd.append('')
vhd.append('architecture behavior of mtx_overlay is')
vhd.append('  constant BASE : integer := 16#%04X#;' % BASE)
vhd.append('  type rom_t is array (0 to %d) of std_logic_vector(7 downto 0);' % (window - 1))
vhd.append('  constant rom : rom_t :=')
vhd.append('    (')
for i in range(0, window, 8):
    row = ', '.join('x"%02X"' % x for x in out[i:i + 8])
    vhd.append('    ' + row + (',' if i + 8 < window else ''))
vhd.append('    );')
vhd.append('  signal off : integer range 0 to 65535;')
vhd.append('begin')
vhd.append('  off <= to_integer(unsigned(addr)) - BASE when to_integer(unsigned(addr)) >= BASE else 65535;')
vhd.append('  hit <= \'1\' when off < %d else \'0\';' % window)
vhd.append('  q   <= rom(off) when off < %d else x"00";' % window)
vhd.append('end behavior;')
here = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(here, '..', 'rtl', 'mtx_overlay.vhd'), 'w', newline='\n').write('\n'.join(vhd) + '\n')
print('wrote rtl/mtx_overlay.vhd')
