SDX DISC IMAGES - HOW TO MAKE AND USE THEM
==========================================

The SDX floppy system reads disc images from the SD card. This file covers the disc images only; the rest of the
setup (ROMs, OSD entries, BASIC commands) is in GUIDE.txt, section 5.

This package contains six blank disc images, games/MTX512/BLANK_SDX.mfl and BLANK_SDX_2.mfl to BLANK_SDX_6.mfl, and no ROMs.
You need your own boot3.rom (the SDX ROM, see section 1 of GUIDE.txt for the MD5 values).

BLANK_SDX.mfl     an empty 655360 byte disc (80 tracks, double sided, disc type 07): the SDX system area and
                  nothing else. USER DIR says "No File" and about 586k is free. MD5 756df89c52e7310c13fdc0ba3713804c.
                  Copy it to a new name for each disc you want, mount the copy, type ROM 3 and USER SAVE to it.
                  It is exactly what tools/make_blank_disc.py writes, so you can make other copies, or discs from
                  your own system disc, with the script (section 2).
BLANK_SDX_2.mfl to BLANK_SDX_6.mfl    the same disc five more times, so that you have six to use at once.

More discs without a PC: the core cannot make a new file (a MiSTer core can only use files that exist), but the MiSTer can
copy one: Scripts/MTX512_new_disc.sh makes DISC01.mfl, DISC02.mfl, ... in games/MTX512 as copies of BLANK_SDX.mfl. Put the
Scripts folder on the SD card, leave the core (Menu button), choose Scripts and then MTX512_new_disc.


1. Why a plain empty file does not work
---------------------------------------
When you type ROM 3 the SDX loads its disc operating system (the CP/M BDOS and BIOS) from the first sectors of the
disc in drive A. Every disc therefore has to carry those sectors. An image that is all E5 bytes gives DISC ERROR.

The first 6656 bytes of a disc image are the system area (boot sector, disc type and system code). The file
directory starts after that. A usable blank disc is the system area of a system disc followed by empty (E5) space.


2. Making a blank disc with the Python script
---------------------------------------------
tools/make_blank_disc.py does exactly that. It needs Python 3 and no other packages.

   python make_blank_disc.py SYSTEM_DISC.mfl NEW_DISC.mfl

   SYSTEM_DISC.mfl   a system disc image you already have (only read, never changed)
   NEW_DISC.mfl      the blank disc to create (must be a different name)

Example, run in the folder that holds both files:

   python make_blank_disc.py SYSTEM.mfl MYDISC1.mfl
   python make_blank_disc.py SYSTEM.mfl MYDISC2.mfl

The script prints the size, the disc type and "no files". It refuses to run if the first byte of the source is not
C3 (not a system disc) and it will not overwrite the source.

Tested with a 655360 byte (640K, type 07) system disc. Other sizes (327680, 163840, 81920 bytes) are copied the same
way.


3. Making a blank disc without Python
-------------------------------------
Copy a system disc image to a new name, mount the copy as Disc A, then in BASIC:

   ROM 3
   USER ERA "*.*"

Answer Y to "All files?". The disc is then read-only until you type ROM 3 again. The copy is empty, with the system
area still in place.


4. Using a new disc
-------------------
1. Copy the .mfl file to games/MTX512/ on the SD card.
2. OSD -> SDX Disc A -> pick the file.
3. In BASIC:   ROM 3
4.             USER DIR          (a new disc says "No File")
5.             USER SAVE "TEST.BAS"   (after typing a program)

SDX BASIC works on one disc, drive A. A "B:" in front of a file name does not select drive B. Put each USER command
on a line of its own: only the first USER command on a BASIC program line runs.

To change discs, mount the other file from the OSD and type ROM 3 again so the SDX reads the new disc (or use the menu
entry "SDX: Type ROM 3 now (disc changed)": GUIDE.txt 5.6).


5. Keep a spare
---------------
The images are changed in place when you save to them. Keep the original system disc image untouched and make your
working discs from it with the script.
