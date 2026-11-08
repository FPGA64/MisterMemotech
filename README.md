# Memotech MTX for [MiSTer](https://github.com/MiSTer-devel/Main_MiSTer/wiki)

A Memotech MTX core for MiSTer, based on [REMEMOTECH](http://www.nyangau.org/rememotech/rememotech.htm) by Andy Key and the MiSTer port [Rememotech-Mister](https://github.com/RW-FPGA-devel-Team/Rememotech-Mister) by the RW FPGA devel Team.

This is a stripped-down build that behaves like a stock MTX with no expansion ROMs fitted: it boots straight to MTX BASIC using ROM images you supply yourself. CP/M, SDX and the SD card / VHD storage of the original port have been removed.

## Features
- Z80 CPU (T80) with selectable speed from 3.125 MHz to 12.5 MHz
- VDP video output over HDMI and VGA, 4:3 or 16:9, 50 Hz or 60 Hz
- Choice of normal or alternative (Marat) colour palette
- Sound chip
- PS/2 keyboard through the MiSTer keyboard input
- OS, BASIC and Assembler ROMs loaded from the OSD
- Debug memory monitor overlay

## Installation
Copy the latest `releases/Rememotech_*.rbf` to the `_Computer` folder on the SD card.

Put your ROM files in `games/Rememotech/` on the SD card.

## ROMs
**No ROM images are included in this repository or in the core.** You need three 8KB (8192 byte) dumps from your own Memotech MTX:

| OSD entry     | ROM                                 |
|---------------|-------------------------------------|
| OS ROM        | Fixed OS ROM (Z80 0000-1FFF)        |
| BASIC ROM     | Pluggable ROM page 0 (BASIC)        |
| Assembler ROM | Pluggable ROM page 1 (Assembler)    |

## Usage
1. Load the core. The screen stays blank until all three ROMs have been loaded.
2. Open the OSD and load a file into each of **OS ROM**, **BASIC ROM** and **Assembler ROM**.
3. When the third ROM is loaded the machine starts and boots to MTX BASIC.

The ROMs are held in FPGA memory, so they have to be loaded again each time the core is started.

### OSD options

| Option        | Values                                   |
|---------------|------------------------------------------|
| Video         | Normal, Debug Monitor                    |
| Aspect ratio  | 4:3, 16:9                                |
| PAL           | Normal, Marat                            |
| Hz            | 60, 50                                   |
| Cpu Mzh       | 12.5, 8.333, 6.25, 5, 4.166, 3.571, 3.125 |
| OSD DEBUG     | Yes, No                                  |
| Reset         |                                          |

## Changes from Rememotech-Mister
- OSD file loading for the OS, BASIC and Assembler ROMs, written into the existing SRAM at the original ROM page offsets. The core is held in reset until all three are loaded.
- All ROM images, the CP/M / SDX system and the RAM disc image have been removed from the initial memory contents (`rtl/Roms.mif`). Only the REMEMOTECH REMON boot monitor remains, which hands over to the normal MTX ROM boot.
- SD card interface removed.
- The "Video Out: 80Col/VDP" option was mislabelled (there is no 80 column card in this port; it switched the debug monitor overlay). It is now "Video: Normal/Debug Monitor" and defaults to normal video.

## Not supported
- CP/M, SDX and the FDX 80 column card
- SD card / VHD disk storage
- Virtual tapes (these relied on the CP/M tools)

## Building
Open `Rememotech.qpf` in Quartus Prime Lite 17.0.2 and compile. The bitstream is written to `output_files/Rememotech.rbf`.

Do not add files to the project in the Quartus IDE. Add them to `files.qip` instead.

## Credits
- Andy Key - REMEMOTECH
- RW FPGA devel Team - original MiSTer port
- Daniel Wallner and MikeJ - T80 CPU core
- Mike Stirling - I2S / I2C audio interface
- Sorgelig and the MiSTer-devel contributors - MiSTer framework (`sys/`)
- Geoff Boyd - original Memotech MTX hardware design

## License
GNU General Public License version 2, see [LICENSE](LICENSE). Some files carry their own compatible licence in their header (T80 and the Mike Stirling audio files use BSD-style licences).

Memotech and MTX are names of their respective owners. This project is not affiliated with them.
