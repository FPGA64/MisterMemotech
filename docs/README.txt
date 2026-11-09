MTX512 for MiSTer - stock Memotech MTX500/512, boots straight to MTX BASIC

Copy to the SD card, keeping the folder names:

  _Computer/MTX512_20261108_menu.rbf   the core
  games/MTX512/boot.rom               OS ROM,    8192 bytes
  games/MTX512/boot1.rom              BASIC ROM, 8192 bytes
  games/MTX512/boot2.rom              ASSEM ROM, 8192 bytes (optional)
  games/MTX512/boot3.rom              SDX ROM,   8192 bytes (optional: adds the SDX disc system, see GUIDE.txt)
  games/MTX512/BLANK.mtx              a blank tape for SAVE, 65536 bytes (optional, see SAVE below)
  games/MTX512/BLANK_SDX.mfl          a blank SDX disc, 655360 bytes; BLANK_SDX_2.mfl to _6 are five more (optional, see DISCS_README.txt)
  Scripts/MTX512_new_disc.sh          MiSTer Scripts menu: makes another blank disc, DISC01.mfl, DISC02.mfl, ... (see DISCS_README.txt)

GUIDE.txt in this package explains SAVE, VERIFY, the keyboard and the SDX disc system step by step, and lists the
MD5 checksums of the ROMs that were used. tools/make_blank_disc.py (Python 3) makes blank SDX discs;
tools/make_boot_rom.py builds a boot.rom that includes ROM 2 (GUIDE.txt 6.3); tools/make_boot3_rom.py builds the boot3.rom for
CP/M and the 80 column board (GUIDE.txt 6.5). RAM 320K, a serial port (DART) and the exact
4MHz clock are described in GUIDE.txt section 6.

The ROMs are loaded automatically when the core starts. Until the OS and BASIC ROMs have
arrived the machine is held in reset and the screen stays blank.
(A single 24576 byte boot.rom holding OS + BASIC + ASSEM in that order also works.)

TAPES
  OSD -> "Insert Tape" -> pick a .mtx or a .wav, then in BASIC type   LOAD ""

  .mtx   loads in a second or two. The file is the data the OS would read from the tape.
         Works for files that start FF + tape name (BASIC programs, and machine code with a
         name header). Files named .mtx that are really SDX BASIC (start F2 F8) or RUN files
         are not tapes and will not load.
         If the name you give to LOAD does not match the file, BREAK gets you out.
         Past the end of the file the core supplies FF bytes. Many .mtx files stop a byte or so short
         of what the OS reads (a missing end marker, which is FF in the files that have it), and with
         the FF fill they load normally. A game that loads a second tape file by name (the .mtx holds
         only the first), or a truncated conversion, gets FF where its data should be and will not run
         properly: use the .wav.
         LOAD "NAME" needs the name on the tape. A name that is not there gives "No data" at once, and the
         tape starts again, so the next LOAD is clean. LOAD "" takes whatever tape is in. Names are matched
         exactly, ignoring upper/lower case. The same goes for VERIFY "NAME".
         VERIFY compares the tape with memory byte by byte and stops with "Mismatch" at the first difference.
         The OS system variables are part of what it compares, so type RUN first if you have been typing
         other commands since the LOAD (that is how the MTX ROM works).
  .wav   plays in real time through the cassette input (30-60 s for most games). Needed for
         games that load a second file or use their own fast loader. PCM, 8 or 16 bit.
         The tape starts when the MTX turns its cassette motor on and stops when it turns it off.
SAVE (to a .mtx file)
  1. OSD -> "Insert Tape" -> BLANK.mtx (or any .mtx: this is what makes the core handle the tape calls).
  2. OSD -> "Mount Save Tape" -> BLANK.mtx. Only a file of exactly 65536 bytes is accepted, so a game tape
     cannot be written over by mistake. Copy BLANK.mtx to a new name for each program you want to keep.
  3. In BASIC:   SAVE "NAME"      The LED lights while it is written to the card.
  The file is now the tape, followed by zero bytes up to 64 KB. SAVE starts at the top of the file and
  clears the rest, so one file holds one tape. To get it back, "Insert Tape" the file again, then
  LOAD "NAME" (you can load it as often as you like). It is an ordinary .mtx, so other MTX emulators read it.
  With no save tape mounted, or a file of any other size, SAVE does nothing, as before.

KEYBOARD (PC keyboard)
  Backspace   removes the character to the left: the core sends the MTX BS key (cursor left) and then the DEL
              key (erase the character under the cursor), which is how you do it on the MTX.
  Shift+Backspace   the plain MTX BS key (cursor left only).
  Delete      the MTX DEL key (erase the character under the cursor). Insert is INS, End is EOL.

SDX DISC SYSTEM (needs boot3.rom, the SDX ROM)
  The Memotech SDX floppy disc system: the FDC 05 controller card (WD1793, ports 10h-14h, SDX ROM in ROM page 3 or 5)
  with a disc that is an image file (.mfl or .dsk, plain sector dump of 655360, 327680, 163840 or 81920
  bytes: the size sets the drive type). The disc must be a system disc; tools/make_blank_disc.py makes an empty one
  from a system disc. OSD -> SDX Disc A, then in BASIC type  ROM 3  and use the
  USER commands: USER DIR, USER LOAD "X.BAS", USER SAVE "X.BAS", USER RUN "X.RUN" ... Sector writes go straight to
  the image file on the card. Without boot3.rom the core is a plain MTX500/512. See GUIDE.txt.

80 COLUMN BOARD AND CP/M (needs your own CP/M bootstrap PROM, character ROM and CP/M disc: GUIDE.txt 6.5)
  The Memotech 80 column board (80 x 24 text in colour, ports 30h-33h and 38h-39h) is in the core, fitted when its 8192 byte
  character ROM has been loaded. tools/make_boot3_rom.py (or make_boot3_rom.bat on Windows, or the Scripts menu entry MTX512_make_boot3 on the MiSTer) makes
  one boot3.rom of 24576 bytes from the SDX ROM, the character ROM and the SDX CP/M bootstrap PROM. Mount a CP/M system disc as SDX Disc A, then OSD -> CP/M: Disc ROM -> CP/M and OSD -> Reset: the machine boots
  CP/M by itself and shows A> on the 80 column screen. CP/M: Disc ROM -> SDX BASIC (and Reset) goes back to SDX BASIC. CP/M: Video output:
  Auto (VDP until the board is set up, then the 80 column picture), VDP, or 80 column. The picture is 640 x 480, not the board's
  15.6kHz. Tested in logic simulation as far as the A> prompt; not tried on a real MiSTer. The FDX controller is not built.

OSD: Insert Tape, Mount Save Tape, SDX Disc A and B, SDX ROM slot (3 or 5), auto-play (on), play/pause,
rewind, eject; aspect ratio, palette, 50/60Hz, CPU speed (default 4MHz); RAM 64K or 320K (the 320K is in the SDRAM module); Serial (DART) on the UART; Type ROM 3 now and
when a disc is mounted; Load ROM 2; CP/M: Disc ROM (SDX BASIC or CP/M, then Reset), CP/M: Video output (Auto, VDP, 80 column), CP/M: Load 80 col char ROM; Joysticks On or Off; Reset. The LED lights while a WAV
plays, a SAVE is written or an SDX disc is used.

JOYSTICKS: two ports, wired into the keyboard matrix like the real MTX. Port 1 acts as the cursor
keypad (arrows + HOME for fire), port 2 is the second joystick socket. Use the MiSTer menu
"Define joystick buttons" for the core. OSD: "Joystick ports: Normal / Swapped" swaps them.

SOUND: SN76489 model with real 2dB volume steps, signed 16 bit output, averaged down to 48kHz. Checked against the
SN76489A data sheet (tone pitch, noise rates, register latch); see GUIDE.txt 6.1.

CPU SPEED: 4MHz (stock, default; exactly 4.000MHz on average, like the MTX crystal), 5, 6.25, 8.33MHz. While a .wav tape plays the core always runs
at stock speed, because the OS decodes WAV tapes by counting CPU time.
(Saved settings from earlier builds are reset on first start.)

------------------------------------------------------------------------------------------------
CREDITS

This core would not exist without the work of Andy Key, who wrote both of the projects below.

REMEMOTECH (http://www.nyangau.org/rememotech/rememotech.htm)
  A modern re-implementation of the Memotech MTX in VHDL: the glue logic, the VDP, the sound chip,
  the CTC, the keyboard matrix and the memory map. This core is derived from its CPU board design.
  It was first brought to MiSTer as "Rememotech-Mister", a hybrid that also carried CP/M, an SD card,
  an 80 column card and a numeric accelerator. This core removed all of that to be a stock
  MTX500/512 that boots straight to MTX BASIC like the machine did in 1984, and then added the SDX, the RAM
  expansion, the serial port and the 80 column board back as options. The 80 column board here is new work, written from
  Memotech's schematic (redrawn by Dave Stevenson) and the MTX-FDX Technical Manual, both from Primrosebank
  (http://www.primrosebank.net/).

MEMU (http://www.nyangau.org/memu/ , tape formats: http://www.nyangau.org/memu/formats.htm)
  A Memotech emulator. The .mtx tape format used here is MEMU's: the bytes the OS passes to its
  tape routine, with no pulses. MEMU's way of loading it, replacing the OS routine INOUT, is the
  idea behind the instant .mtx loading in this core. In this core the replacement is a small piece
  of Z80 code in the FPGA that fetches bytes from the file, and it calls the OS's own set-up and
  clean-up routines so that interrupts behave as they do on a real tape load. MEMU's documentation
  was also the reference for the memory map, I/O ports and tape handling.

Also:
  Memotech Ltd           the MTX500/512 and its OS, BASIC and ASSEM ROMs (games/MTX512/boot*.rom are
                         the unmodified Memotech ROM images; they remain Memotech's work)
  Brian Pritchard        the MTX Series Operators Manual, with the circuit diagrams that show how the
                         cassette input, joysticks and keyboard are wired
  Daniel Wallner, Mike J and the T80 authors   the T80 Z80 core (opencores / fpgaarcade)
  MiSTer-devel           Template_MiSTer and the sys/ framework, and the MiSTer firmware
  Jim Wills and Paul Daniels   preservation of MTX tapes (.mtx, .wav), as credited in MEMU's own notes
  TOSEC                  the MTX software collection used for testing

------------------------------------------------------------------------------------------------
LICENCE

Free software under the GNU General Public License version 2, as REMEMOTECH and the MiSTer
template are. The source is in MTX512_source.zip (build notes in SOURCE_README.txt inside it).
The Memotech ROMs are not covered by that licence and are not in the source.
