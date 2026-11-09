// spec_option.vh - are the Speculator entries in the menu of this build?
//
// THIS FILE IS THE PUBLIC VERSION: THE SPECULATOR IS OFF.
//
// What is switched off here, and why
//
//   The Speculator is the Memotech add-on (designed by Tony Brewer, 1985) that lets an MTX512 run ZX Spectrum
//   games. To be of any use it needs two things that are other people's work and are not part of this core:
//   Memotech's Speculator program (the tape SPEC1.mtx) and the Spectrum games themselves. The core would be
//   a board with nothing to run, and the program and games cannot be distributed with it. So in the public
//   build the Speculator is removed from the menu:
//
//     - there is no "Speculator board" entry (the board, mtx_speculator.vhd, stays tied off: SPEC_EN is 0),
//     - "Insert Tape" does not offer ZX Spectrum .tap files (the tape player's .tap code stays in
//       mtx_tape.sv, it is simply never selected).
//
//   SPEC_EN is a constant 0 here, not a menu setting, on purpose: the menu setting is stored in the core's
//   configuration file, and a setting saved by a build that has the entry must not switch the board on in a
//   build that has not.
//
// To build with the Speculator
//
//   Replace the three definitions below with these, and compile as usual (the rest of the source is the same):
//
//     `define SPEC_TAPE_ENTRY "F1,WAVMTXTAP,Insert Tape;",
//     `define SPEC_MENU_ENTRY "O[14],Speculator board,Off,On;",
//     `define SPEC_EN         status[14]
//
//   You then also need your own copy of the Speculator program and of the games as .tap files.

`define SPEC_TAPE_ENTRY "F1,WAVMTX,Insert Tape;",
`define SPEC_MENU_ENTRY
`define SPEC_EN         1'b0
