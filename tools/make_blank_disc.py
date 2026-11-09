"""Make a blank, usable SDX disc image from a system disc image you already have.

    python make_blank_disc.py SYSTEM_DISC.mfl NEW_DISC.mfl

Why this is needed: when you type ROM 3 the SDX loads its disc operating system (the CP/M BDOS and BIOS) from the
first sectors of the disc in drive A. So every disc has to carry those sectors; an image full of E5 bytes gives
DISC ERROR. This script keeps the first 6656 bytes of the system disc (boot sector, disc type and the system
code), fills everything after that with E5 (an empty CP/M directory and free data area) and writes the result.
The new disc has no files on it. It works as drive A or drive B.

Tested with a 655360 byte (640K, type 07) system disc: ROM 3, USER DIR (No File), USER STAT, USER SAVE and loading
the program back after a reset all work. Other sizes are copied the same way.

Nothing is read from or written to the system disc; it is only read. Python 3, no other packages."""
import sys

SYSTEM_BYTES = 6656            # boot sector + system code; the CP/M directory starts at this offset
KNOWN_SIZES = {655360: 'type 07 (80 tracks, double sided)', 327680: 'type 03 (40 tracks, double sided)',
               163840: 'type 02 (40 tracks, single sided)', 81920: 'type 00 (40 tracks, single sided, single density)'}


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    src, dst = argv[1], argv[2]
    if src == dst:
        print('The new disc must have a different name from the system disc.')
        return 2
    data = open(src, 'rb').read()
    if len(data) not in KNOWN_SIZES:
        print('Warning: %d bytes is not a usual disc size (%s).' % (len(data), ', '.join(str(s) for s in sorted(KNOWN_SIZES))))
    if len(data) < SYSTEM_BYTES or data[0] != 0xC3:
        print('That does not look like an SDX system disc (the first byte should be C3). Nothing written.')
        return 1
    img = bytearray([0xE5]) * len(data)
    img[:SYSTEM_BYTES] = data[:SYSTEM_BYTES]
    open(dst, 'wb').write(img)
    print('Wrote %s: %d bytes, %s, no files. Disc type byte in the boot sector: %02X.'
          % (dst, len(img), KNOWN_SIZES.get(len(img), 'unusual size'), img[3]))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
