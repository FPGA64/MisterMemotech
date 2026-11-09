"""SDX floppy disc controller, as a behavioural model - the reference for the FPGA version.

Ports (SDX card; the MTX operator's manual leaves 10h..1Eh free and puts disc hardware at 20h and up for the FDX):
  10  write: FDC command      read: FDC status
  11  FDC track register
  12  FDC sector register
  13  FDC data register (the data of a sector goes through here, byte by byte)
  14  write: drive control    read: drive status | drive configuration switches

The chip is a Western Digital 179x. This model implements the commands the SDX ROM's driver uses: restore, seek,
step, step in/out (type I), read sector, write sector, multi-sector, write track (format), force interrupt.
The image is a plain sector dump (an MFLOPPY file): sector = ((sides * track + side) * 16 + sector - 1) * length,
16 sectors per track, 256 bytes (double density) or 128 (single density), 1 or 2 sides, 40 or 80 tracks.
A 40 track image in an 80 track drive is recognised by its size: the SDX driver doubles the track number then.
"""

# FDC status register
NOT_READY, PROTECTED, HEAD_LOADED, SEEK_ERROR, CRC_ERROR, TRACK_00, DATA, BUSY = 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01
# drive status port (read): bits 4..0 are the configuration switches (an inverted sense), then
# SDX FDC 05 schematic, IN 14h (74LS244): D7 DRQ, D6 INTRQ, D5 READY, D4 two-drives jumper, D3 SW4 (0 = ON = 6ms step,
# 1 = 12ms), D2 SW3 (0 = 96 TPI = 80 track), D1 SW2 (0 = double sided), D0 SW1 (0 = head load solenoid fitted).
# The switch bits read 0 when the switch is ON; the bank read is the one of the selected drive.
CFG_NO_HEAD_LOAD, CFG_SINGLE_SIDED, CFG_40TRACK, CFG_STEP_12MS, CFG_TWO_DRIVES = 0x01, 0x02, 0x04, 0x08, 0x10
DRV_READY, DRV_INT, DRV_DRQ = 0x20, 0x40, 0x80
# drive control port (write)
CTL_DRIVE1, CTL_SIDE, CTL_MOTOR_ON, CTL_MOTOR_READY, CTL_DOUBLE_DENSITY = 0x01, 0x02, 0x04, 0x08, 0x10

SECTORS = 16


class SdxFdc:
    def __init__(self, trace=None):
        self.images = [None, None]            # bytearray per drive (None = no disc)
        self.cfg = [CFG_TWO_DRIVES, CFG_TWO_DRIVES]   # all switches ON (head load, double sided, 80 track, 6ms), two drives
        self.status = 0
        self.command = 0
        self.track = 0
        self.sector = 0
        self.data = 0
        self.drv = 0
        self.drv_status = 0
        self.control = 0
        self.drv_track = [0, 0]
        self.dir_in = False
        self.sect_len = [256, 256]
        self.raid = 0                         # next sector number for READ ADDRESS
        self.buf = bytearray(256)
        self.pos = 0
        self.wtk = 'init'
        self.wtk_numsec = 0
        self.writes = []                      # (offset, bytes) of every sector written, for the host to persist
        self.trace = trace                    # callable(str) or None
        self.log = []

    # ---- helpers
    def _ready(self):
        return self.images[self.drv] is not None and (self.control & (CTL_MOTOR_ON | CTL_MOTOR_READY)) == (CTL_MOTOR_ON | CTL_MOTOR_READY)

    def _id_track(self):
        """The track number in the ID fields under the head: the physical track, or half of it for a 40 track disc in an
        80 track drive (the driver then steps twice per track)."""
        img = self.images[self.drv]
        n80 = not (self.cfg[self.drv] & CFG_40TRACK)
        nsides = 1 if self.cfg[self.drv] & CFG_SINGLE_SIDED else 2
        if n80 and img is not None and len(img) == 40 * nsides * SECTORS * self.sect_len[self.drv]:
            return self.drv_track[self.drv] // 2
        return self.drv_track[self.drv]

    def _t(self, msg):
        if self.trace: self.trace(msg)

    def mount(self, drive, image, tracks=80, single_sided=False):
        self.images[drive] = image
        c = CFG_TWO_DRIVES
        if tracks == 40: c |= CFG_40TRACK
        if single_sided: c |= CFG_SINGLE_SIDED
        self.cfg[drive] = c

    # ---- type I commands
    def _type1(self, cmd):
        self.status = 0
        if not self._ready():
            self.status |= NOT_READY
            self.drv_status &= ~DRV_READY
        if cmd & 0x08: self.status |= HEAD_LOADED
        if cmd & 0x04 and self.track != self._id_track(): self.status |= SEEK_ERROR     # verify: the ID found is not the track
        if self.drv_track[self.drv] == 0: self.status |= TRACK_00
        self.drv_status |= DRV_INT

    def _step(self, cmd, inward):
        """One step of the head. Step in goes to higher track numbers, step out towards track 0. The track register
        follows when the update bit (bit 4) is set."""
        d = self.drv
        self.dir_in = inward
        if inward: self.drv_track[d] += 1
        elif self.drv_track[d]: self.drv_track[d] -= 1
        if cmd & 0x10: self.track = (self.track + (1 if inward else -1)) & 0xFF

    # ---- sector transfers
    def _setsec(self, cmd, sector, check_tr=True):
        img = self.images[self.drv]
        if img is None:
            raise RuntimeError('read or write of a drive with no disc')
        side = 1 if self.control & CTL_SIDE else 0
        nsides = 1 if self.cfg[self.drv] & CFG_SINGLE_SIDED else 2
        itrack = self._id_track()
        if sector < 1 or sector > SECTORS or (check_tr and self.track != itrack):
            self.command = 0
            self.status = SEEK_ERROR                       # record not found
            self.drv_status = (self.drv_status & ~DRV_DRQ) | DRV_INT
            return False
        self.offset = ((nsides * itrack + side) * SECTORS + sector - 1) * self.sect_len[self.drv]
        self.command = cmd
        self.status = (self.status & ~SEEK_ERROR) | DATA | BUSY
        self.drv_status = (self.drv_status & ~DRV_INT) | DRV_DRQ
        self.pos = 0
        return True

    def _done(self):
        self.command = 0
        self.status = 0
        self.drv_status = (self.drv_status & ~DRV_DRQ) | DRV_INT

    def _rsec(self, cmd):
        if not self._setsec(cmd, self.sector): return
        n = self.sect_len[self.drv]
        img = self.images[self.drv]
        if self.offset + n > len(img):
            raise RuntimeError('read past the end of the disc image')
        self.buf[:n] = img[self.offset:self.offset + n]

    def _rdata(self):
        if (self.command & 0xF0) == 0xC0:     # read address: six bytes
            v = self.buf[self.pos]
            self.pos += 1
            if self.pos >= 6: self._done()
            return v
        if (self.command & 0xE0) == 0x80:     # read sector
            v = self.buf[self.pos]
            self.pos += 1
            if self.pos >= self.sect_len[self.drv]:
                if self.command & 0x10:       # multiple sectors
                    self.sector += 1
                    self._rsec(self.command)
                else:
                    self._done()
            return v
        return self.data

    def _wsec_end(self):
        n = self.sect_len[self.drv]
        img = self.images[self.drv]
        if self.offset + n > len(img):
            raise RuntimeError('write past the end of the disc image')
        img[self.offset:self.offset + n] = self.buf[:n]
        self.writes.append((self.offset, bytes(self.buf[:n])))

    def _wdata(self, v):
        n = self.sect_len[self.drv]
        if (self.command & 0xE0) == 0xA0:     # write sector
            self.buf[self.pos] = v
            self.pos += 1
            if self.pos >= n:
                self._wsec_end()
                if self.command & 0x10:
                    self.sector += 1
                    self._setsec(self.command, self.sector)
                else:
                    self._done()
        elif (self.command & 0xF0) == 0xF0:   # write track = format
            self._wtk(v)
        else:
            self.data = v

    def _wtk(self, v):
        n = self.sect_len[self.drv]
        if self.wtk == 'init':
            if v == 0xFE:
                self.wtk = 'addr'; self.pos = 0
        elif self.wtk == 'addr':
            if v == 0xF7:
                if self.pos < 4: raise RuntimeError('address mark too short')
                trk, sid, sec, ln = self.buf[0], self.buf[1], self.buf[2], self.buf[3]
                if (sec > SECTORS or sec < 1 or (256 if ln else 128) != n):
                    raise RuntimeError('incorrect address mark data %s' % [trk, sid, sec, ln])
                self._setsec(self.command, sec, check_tr=False)
                self.wtk = 'skip'
            elif self.pos < 4:
                self.buf[self.pos] = v; self.pos += 1
            else:
                raise RuntimeError('address mark too long')
        elif self.wtk == 'skip':
            if v == 0xFB: self.wtk = 'data'
        elif self.wtk == 'data':
            if v == 0xF7:
                if self.pos < n: raise RuntimeError('sector too short')
                self._wsec_end()
                self.wtk_numsec += 1
                if self.wtk_numsec == SECTORS: self._done()
                self.wtk = 'init'
            elif self.pos < n:
                self.buf[self.pos] = v; self.pos += 1
            else:
                raise RuntimeError('sector too long')

    # ---- command register
    def _cmd(self, cmd):
        hi = cmd & 0xF0
        d = self.drv
        self.drv_status &= ~DRV_INT                         # a new command resets INTRQ
        if hi == 0x00:                        # restore: step out until track 00, track register = 0
            self.track = 0; self.drv_track[d] = 0; self.dir_in = False; self._type1(cmd)
        elif hi == 0x10:                      # seek: move by (data register - track register), track register = data
            delta = self.data - self.track
            self.dir_in = delta > 0
            self.drv_track[d] = max(0, self.drv_track[d] + delta)
            self.track = self.data; self._type1(cmd)
        elif hi in (0x20, 0x30):              # step, in the last direction
            self._step(cmd, self.dir_in); self._type1(cmd)
        elif hi in (0x40, 0x50):              # step in
            self._step(cmd, True); self._type1(cmd)
        elif hi in (0x60, 0x70):              # step out
            self._step(cmd, False); self._type1(cmd)
        elif hi in (0x80, 0x90):              # read sector
            self._rsec(cmd)
        elif hi in (0xA0, 0xB0):              # write sector
            self._setsec(cmd, self.sector)
        elif hi == 0xC0:                      # read address
            self.raid = self.raid % SECTORS + 1
            lc = 1 if self.sect_len[d] == 256 else 0
            self.buf[:6] = bytes([self._id_track(), 1 if self.control & CTL_SIDE else 0, self.raid, lc, 0, 0])
            self.command = cmd; self.pos = 0
            self.sect_len_ra = 6
            self.status = DATA | BUSY
            self.drv_status = (self.drv_status & ~DRV_INT) | DRV_DRQ
        elif hi == 0xD0:                      # force interrupt
            self.command = 0; self._type1(cmd)
        elif hi == 0xE0:
            raise RuntimeError('READ TRACK is not implemented')
        elif hi == 0xF0:                      # write track
            self.command = cmd; self.wtk = 'init'; self.wtk_numsec = 0
            self.status = (self.status & ~SEEK_ERROR) | DATA | BUSY
            self.drv_status = (self.drv_status & ~DRV_INT) | DRV_DRQ
            self.pos = 0

    # ---- the ports
    def out(self, port, v):
        p = port & 0xFF
        self._t('OUT %02X,%02X' % (p, v))
        if p == 0x10: self._cmd(v)
        elif p == 0x11: self.track = v
        elif p == 0x12: self.sector = v
        elif p == 0x13: self._wdata(v)
        elif p == 0x14:
            self.control = v
            self.drv = 1 if v & CTL_DRIVE1 else 0
            if self._ready():
                self.drv_status |= DRV_READY
            else:
                self.drv_status &= ~DRV_READY
            self.sect_len[self.drv] = 256 if v & CTL_DOUBLE_DENSITY else 128
        else:
            raise RuntimeError('output to an SDX port that does not exist: %02X' % p)

    def in_(self, port):
        p = port & 0xFF
        if p == 0x10:
            v = self.status
            self.drv_status &= ~DRV_INT                     # reading the status register resets INTRQ
        elif p == 0x11: v = self.track
        elif p == 0x12: v = self.sector
        elif p == 0x13: v = self._rdata()
        elif p == 0x14:
            self.drv_status = (self.drv_status & ~DRV_READY) | (DRV_READY if self._ready() else 0)
            v = self.drv_status | self.cfg[self.drv]
        else:
            raise RuntimeError('input from an SDX port that does not exist: %02X' % p)
        self._t('IN  %02X -> %02X' % (p, v))
        return v
