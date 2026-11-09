"""The Memotech 80 column board, as a software model written from the primary documents:

  - MTX-FDX Technical Manual, chapter 1 (I/O port assignments, bit level port descriptions, pages 1.7 to 1.9) and chapter 3
    (the 80 column board)
  - the board's schematic (80Col_schem.pdf, redrawn by Dave Stevenson)

What they say, and what is modelled:

  ports 38h, 39h   the Motorola MC6845 CRTC: 38h selects a register, 39h reads or writes it
  port 30h write   D0..D7 = display memory address A0..A7. "Writing to this port initiates a VDU memory access."
  port 31h write   D0..D2 = A8..A10, D5 write enable attribute memory, D6 write enable ASCII memory,
                   D7 = write cycle when high, read cycle when low
  port 32h r/w     the ASCII byte (the alpha or graphic character code)
  port 33h r/w     the attribute byte
  port 30h read    rings the bell (the schematic: /IN30 = BELL); nothing else
  The display memory is two 2K x 8 RAMs (6116): ASCII and attribute, one pair per character cell, 80 x 24 = 1920 cells,
  addressed by the CRTC's MA0..MA10. The CPU reaches it only through the latches above.

  attribute byte, colour monitor: D0 red, D1 green, D2 blue foreground; D3 red, D4 green, D5 blue background; D6 blink; D7 graphics
  (monochrome monitor: D0 underline, D2 bright-up, D4 reverse video, D5 background).
  ASCII byte: with D7 of the attribute clear the alpha character generator; set, the graphics generator.
"""

COLS, ROWS = 80, 24


class Col80:
    def __init__(self):
        self.asc = bytearray(2048)
        self.atr = bytearray(2048)
        self.p30 = 0
        self.p31 = 0
        self.d32 = 0
        self.d33 = 0
        self.sel = 0
        self.crtc = [0] * 18
        self.bells = 0
        self.log = []                 # (kind, port, value) of every access, for looking at the protocol
        self.writes = 0
        self.reads = 0

    def out(self, port, v):
        p = port & 0xFF
        self.log.append(('out', p, v))
        if p == 0x30:
            self.p30 = v
            self._access()
        elif p == 0x31:
            self.p31 = v
        elif p == 0x32:
            self.d32 = v
        elif p == 0x33:
            self.d33 = v
        elif p == 0x38:
            self.sel = v & 0x1F
        elif p == 0x39:
            if self.sel < 18:
                self.crtc[self.sel] = v

    def in_(self, port):
        p = port & 0xFF
        v = 0xFF
        if p == 0x30:
            self.bells += 1
        elif p == 0x32:
            v = self.d32
        elif p == 0x33:
            v = self.d33
        elif p == 0x38:
            v = 0                       # the 6845 has no status register
        elif p == 0x39:
            v = self.crtc[self.sel] if 14 <= self.sel <= 17 else 0   # R14 to R17 can be read
        self.log.append(('in', p, v))
        return v

    def _access(self):
        addr = ((self.p31 & 7) << 8) | self.p30
        if self.p31 & 0x80:                  # a write cycle
            self.writes += 1
            if self.p31 & 0x40:
                self.asc[addr] = self.d32
            if self.p31 & 0x20:
                self.atr[addr] = self.d33
        else:                                # a read cycle: the latches take what the memory holds
            self.reads += 1
            self.d32 = self.asc[addr]
            self.d33 = self.atr[addr]

    def start(self):
        return ((self.crtc[12] & 0x3F) << 8) | self.crtc[13]

    def text(self):
        """The screen as 24 lines of 80 characters from the display start address (graphics cells shown as #)."""
        s = self.start()
        out = []
        for r in range(ROWS):
            line = ''
            for c in range(COLS):
                a = (s + r * COLS + c) & 0x7FF
                ch = self.asc[a]
                if self.atr[a] & 0x80:
                    line += '#' if ch else ' '
                else:
                    line += chr(ch) if 32 <= ch < 127 else ' '
            out.append(line.rstrip())
        return out
