//============================================================================
//
//  Memotech MTX500/512 for MiSTer
//
//  Stock machine, no expansions: Z80A, CTC, TMS9929A VDP, SN76489A sound,
//  64KB RAM, OS + BASIC + ASSEM ROMs. Boots straight to MTX BASIC.
//
//  Derived from REMEMOTECH by Andy Key.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign DDRAM_CLK = CLK_50M;

assign VGA_SL         = 0;
assign VGA_F1         = 0;
assign VGA_SCALER     = 0;
assign VGA_DISABLE    = 0;
assign HDMI_FREEZE    = 0;
assign HDMI_BLACKOUT  = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;                 // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

assign VIDEO_ARX = status[1] ? 13'd16 : 13'd4;
assign VIDEO_ARY = status[1] ? 13'd9  : 13'd3;

`include "build_id.v"
`include "spec_option.vh"      // the Speculator entries of the menu: on or off in this build, and why
localparam CONF_STR = {
	"MTX512;;",
	"-;",
	"O[1],Aspect ratio,4:3,16:9;",
	"O[2],Palette,Normal,Marat;",
	"O[3],Video Hz,50,60;",
	"O[6:5],CPU Speed,4MHz (stock),5MHz,6.25MHz,8.33MHz;",
	"-;",
	`SPEC_TAPE_ENTRY
	"O[8],Tape auto-play,On,Off;",
	"T[9],Tape play/pause;",
	"T[10],Tape rewind;",
	"T[11],Tape eject;",
	"S0,MTX,Mount Save Tape (for SAVE);",
	"-;",
	"S1,MFLDSK,SDX Disc A;",
	"S2,MFLDSK,SDX Disc B;",
	"-;",
	"O[23],CP/M: Disc ROM (then Reset),SDX BASIC,CP/M;",
	"O[22:21],CP/M: Video output,Auto,VDP,80 column;",
	"F3,CHRBIN,CP/M: Load 80 col char ROM (8KB);",
	"-;",
	"T[17],SDX: Type ROM 3 now (disc changed);",
	"O[16],SDX: Type ROM 3 when a disc is mounted,Off,On;",
	"O[13],SDX: ROM slot,ROM 3,ROM 5;",
	"-;",
	"O[18],RAM,64K (stock),320K (SDRAM);",
	"F2,ROMBIN,Load ROM 2 (HiSoft Pascal...);",
	"-;",
	"O[20:19],Serial (DART) on the UART,Off,Channel A,Channel B;",
	`SPEC_MENU_ENTRY
	"-;",
	"O[12],Joystick ports,Normal,Swapped;",
	"O[24],Joysticks,On,Off;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J,Fire,Fire 2;",
	"jn,A,B;",
	"v,2;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [31:0] joystick_0, joystick_1;

// virtual drives of hps_io: 0 = the save tape (an image written block by block by SAVE), 1 and 2 = the SDX discs
wire  [2:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire  [2:0] sd_wr;
wire  [2:0] sd_rd;
wire  [2:0] sd_ack;
wire [31:0] sv_lba;
wire [31:0] sdx_lba;
wire [13:0] sd_buff_addr;
wire  [7:0] sv_buff_din;
wire  [7:0] sdx_buff_din;
wire  [7:0] sd_buff_dout;
wire        sd_buff_wr;
// MiSTer joystick bits: 0 right, 1 left, 2 down, 3 up, 4 and 5 buttons.  First controller = MTX port 1 (J4).
wire [31:0] joy_raw1 = status[12] ? joystick_1 : joystick_0;
wire [31:0] joy_raw2 = status[12] ? joystick_0 : joystick_1;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(3)) hps_io
(
	.clk_sys(CLK_50M),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ps2_key(ps2_key),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(tape_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba('{sv_lba, sdx_lba, sdx_lba}),
	.sd_blk_cnt('{6'd0, 6'd0, 6'd0}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sv_buff_din, sdx_buff_din, sdx_buff_din}),
	.sd_buff_wr(sd_buff_wr)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_25;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_25)
);

wire reset = RESET | status[0] | buttons[1];

///////////////////////   ROMs   ///////////////////////////////
//
// The ROMs are not in the bitstream. At core start the MiSTer firmware sends, from
// /media/fat/games/MTX512/ :
//     boot.rom    (file index 0)     = OS,    8KB   (boot0.rom is the same slot)
//     boot1.rom   (file index 0x40)  = BASIC, 8KB
//     boot2.rom   (file index 0x80)  = ASSEM, 8KB
//     boot3.rom   (file index 0xC0)  = SDX ROM, 8KB (optional: the SDX disc system, see below). A 16KB boot3.rom is the SDX ROM
//                                      (or the CP/M bootstrap PROM) followed by the 80 column board's character ROM: that fits the board.
// A single 24KB boot.rom holding OS + BASIC + ASSEM in that order also works, and a 32KB one with the SDX ROM last.
// A longer boot.rom goes on into ROM 2 (up to 64KB). The OSD entry "Load ROM 2" (file index 2) loads a ROM 2 file by itself.
// Every file lands at on-chip memory byte 0x10000 + index*0x2000 + offset.
// The machine stays in reset until at least the OS and BASIC ROMs have been written.

wire        rom_loading, rom_we;
wire [16:0] rom_waddr;
wire        os_ok, basic_ok, sdx_ok, cpm_ok;                    // the OS, BASIC, SDX ROM, and CP/M PROM (third part of boot3.rom) have arrived
wire        rom_waddr_hi;                                       // bit 17 of the ROM memory address: the CP/M PROM page
wire  [3:0] rom2_ok;                                    // which sub-pages of ROM 2 hold a ROM
wire        cg_we, cg_ok;                               // the 80 column board's character ROM
wire [12:0] cg_addr;

// where the files go in the ROM memory: rtl/mtx_romload.sv. The OSD entry "Load ROM 2" (file index 2) writes a file of up
// to 32KB into the ROM 2 sub-pages (8KB each): HiSoft Pascal is two chips, a 16KB file of the two one after the other.
mtx_romload romload
(
	.clk(CLK_50M),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index[7:0]),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),

	.rom_loading(rom_loading),
	.rom_waddr(rom_waddr),
	.rom_waddr_hi(rom_waddr_hi),
	.rom_we(rom_we),

	.os_ok(os_ok),
	.basic_ok(basic_ok),
	.sdx_ok(sdx_ok),
	.cpm_ok(cpm_ok),
	.rom2_ok(rom2_ok),

	.cg_we(cg_we),
	.cg_addr(cg_addr),
	.cg_ok(cg_ok)
);

wire reset_core = reset | rom_loading | ~os_ok | ~basic_ok;

// The joysticks are part of the keyboard matrix, so a button still held from the OSD (the Reset
// item is usually picked with it) looks like a key held down while the OS starts. After every reset
// the joysticks stay disconnected until they have been seen idle for about 80ms.
reg        joy_armed = 0;
reg [21:0] joy_idle  = 0;
wire       joy_busy  = |{joy_raw1[5:0], joy_raw2[5:0]};
always @(posedge CLK_50M) begin
	if (reset_core) begin
		joy_armed <= 0;
		joy_idle  <= 0;
	end else if (joy_busy) begin
		joy_idle  <= 0;
	end else if (!joy_armed) begin
		joy_idle  <= joy_idle + 1'd1;
		if (&joy_idle) joy_armed <= 1;
	end
end
wire [31:0] joy_port1 = (joy_armed & ~status[24]) ? joy_raw1 : 32'd0;
wire [31:0] joy_port2 = (joy_armed & ~status[24]) ? joy_raw2 : 32'd0;

//////////////////////////////////////////////////////////////////

// OSD value -> clock_divider code (000 = 25MHz ... 101 = 4MHz). 0 is the stock 4MHz (exact on average).
reg [2:0] div_cpu_menu;
always @(*) begin
	case (status[6:5])
		2'd0:    div_cpu_menu = 3'b101;   // 4.000 (stock)
		2'd1:    div_cpu_menu = 3'b100;   // 5.000
		2'd2:    div_cpu_menu = 3'b011;   // 6.250
		default: div_cpu_menu = 3'b010;   // 8.333
	endcase
end

// PS/2 key events: ps2_key[10] toggles on every press and release
reg old_keystb = 0;
always @(posedge CLK_50M) old_keystb <= ps2_key[10];
wire key_strobe = old_keystb ^ ps2_key[10];

///////////////////////   TAPE   ///////////////////////////////

reg  [2:0] tbtn_d;
always @(posedge CLK_50M) tbtn_d <= status[11:9];
wire btn_play   = status[9]  & ~tbtn_d[0];
wire btn_rewind = status[10] & ~tbtn_d[1];
wire btn_eject  = status[11] & ~tbtn_d[2];

// the Communications board: the two channels of the Z80 DART, one of them on the MiSTer's UART (what the UART is
// connected to is set in the MiSTer's own menu, for instance a USB serial adapter)
wire       dart_tx_a, dart_tx_b;
wire       sel_ser_a = (status[20:19] == 2'd1);
wire       sel_ser_b = (status[20:19] == 2'd2);
reg  [1:0] rxd_s = 2'b11;
always @(posedge CLK_50M) rxd_s <= {rxd_s[0], UART_RXD};
assign UART_TXD = sel_ser_a ? dart_tx_a : sel_ser_b ? dart_tx_b : 1'b1;

// a disc was changed: type ROM 3 on the keyboard when BASIC is at its prompt (rtl/mtx_autorom.vhd). Triggered by the menu
// button, or by mounting disc A if the menu option is On. The option is Off by default: the SDX tools (USER FORMAT,
// SYSCOPY, COPY) wait for a key in the same loop as the BASIC prompt, and ask for a disc to be mounted at that moment, so
// typing for them would answer their prompts.
reg        relog_btn_d = 0;
always @(posedge CLK_50M) relog_btn_d <= status[17];
wire       relog_btn  = status[17] & ~relog_btn_d;
wire       mount_a    = img_mounted[1] & (img_size != 0);
wire       sdx_relog  = sdx_ok & ~status[23] & ((mount_a & status[16]) | relog_btn);   // (not with the CP/M PROM: it boots by itself)

wire tape_wave, tape_wait, tape_loaded, tape_playing, tape_error, tape_motor;
wire mtx_loaded, mtx_ready, mtx_eof, mtx_pop_t, mtx_rewind_t;
wire [7:0] mtx_byte;
wire mtx_nm_t, mtx_nodata;
wire [7:0] mtx_nm_d;
wire sv_wr_t, sv_start_t, sv_flush_t, sv_busy, save_mounted;
wire sv_sd_wr;
wire clk_cpu;
wire fdc_cs, fdc_wr, fdc_rd;
wire [2:0] fdc_a;
wire [7:0] fdc_do, fdc_di;
wire [7:0] sv_wr_d;

mtx_tape tape
(
	.clk(CLK_50M),
	.reset(reset),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(tape_wait),

	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),

	.btn_play(btn_play),
	.btn_rewind(btn_rewind),
	.btn_eject(btn_eject),
	.auto_play(~status[8]),

	.cpu_motor(tape_motor),
	.tape_in(tape_wave),
	.tape_loaded(tape_loaded),
	.tape_playing(tape_playing),
	.tape_error(tape_error),

	.mtx_loaded(mtx_loaded),
	.mtx_ready(mtx_ready),
	.mtx_eof(mtx_eof),
	.mtx_byte(mtx_byte),
	.mtx_pop_t(mtx_pop_t),
	.mtx_rewind_t(mtx_rewind_t),
	.mtx_nm_t(mtx_nm_t),
	.mtx_nm_d(mtx_nm_d),
	.mtx_nodata(mtx_nodata)
);

// SAVE: bytes from the INOUT overlay go to the image mounted with "Mount Save Tape"
mtx_save save
(
	.clk(CLK_50M),
	.reset(reset),

	.wr_t(sv_wr_t),
	.wr_d(sv_wr_d),
	.start_t(sv_start_t),
	.flush_t(sv_flush_t),
	.busy(sv_busy),

	.img_mounted(img_mounted[0]),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sv_lba),
	.sd_wr(sv_sd_wr),
	.sd_ack(sd_ack[0]),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_din(sv_buff_din),

	.mounted(save_mounted)
);

// The OS decodes a WAV tape by counting Z80 instruction time, so the CPU must run at stock speed
// while a tape is playing. (.mtx loads do not depend on the CPU speed.)
wire [2:0] div_cpu = tape_playing ? 3'b101 : div_cpu_menu;

wire [3:0] r, g, b;
wire       HSync, VSync, HBlank, VBlank;
wire [15:0] audio_raw;
wire        audio_strobe;

mtx mtx
(
	.CLOCK_50   (CLK_50M),
	.Clk_Video  (clk_25),
	.RESET      (reset_core),
	.div_cpu    (div_cpu),
	.hw_pal     (status[2]),
	.frame_60   (status[3]),

	.key_ready  (key_strobe),
	.key_stroke (~ps2_key[9]),
	.key_code   ({1'b0, ps2_key[8:0]}),

	.VGA_R      (r),
	.VGA_G      (g),
	.VGA_B      (b),
	.VGA_HS     (HSync),
	.VGA_VS     (VSync),
	.VGA_HB     (HBlank),
	.VGA_VB     (VBlank),

	.sound_out  (audio_raw),
	.sound_strobe(audio_strobe),

	// MiSTer joystick bits: 0 right, 1 left, 2 down, 3 up, 4 and 5 buttons
	.joy1       ({joy_port1[4] | joy_port1[5], joy_port1[0], joy_port1[1], joy_port1[2], joy_port1[3]}),
	.joy2       ({joy_port2[4] | joy_port2[5], joy_port2[0], joy_port2[1], joy_port2[2], joy_port2[3]}),

	.tape_in    (tape_wave),
	.tape_out   (),
	.tape_out_we(),
	.tape_motor (tape_motor),
	.clk_cpu_o  (clk_cpu),
	.cpu_halt   (),

	.rom_loading(rom_loading),
	.rom_we     (rom_we),
	.rom_waddr  (rom_waddr),
	.rom_waddr_hi(rom_waddr_hi),
	.rom_wdata  (ioctl_dout),

	.mtx_loaded (mtx_loaded),
	.mtx_ready  (mtx_ready),
	.mtx_eof    (mtx_eof),
	.mtx_byte   (mtx_byte),
	.mtx_pop_t  (mtx_pop_t),
	.mtx_rewind_t(mtx_rewind_t),
	.mtx_nm_t   (mtx_nm_t),
	.mtx_nm_d   (mtx_nm_d),
	.mtx_nodata (mtx_nodata),
	.sv_wr_t    (sv_wr_t),
	.sv_wr_d    (sv_wr_d),
	.sv_start_t (sv_start_t),
	.sv_flush_t (sv_flush_t),
	.sv_busy    (sv_busy),
	.sdx_en     (sdx_ok),
	.sdx_slot5  (status[13]),
	.cpm_sel    (status[23]),
	.cpm_ok     (cpm_ok),
	.fdc_cs     (fdc_cs),
	.fdc_a      (fdc_a),
	.fdc_wr     (fdc_wr),
	.fdc_rd     (fdc_rd),
	.fdc_do     (fdc_do),
	.fdc_di     (fdc_di),
	.spec_en    (`SPEC_EN),
	.sdx_relog  (sdx_relog),
	.ram_exp    (status[18]),
	.dart_rx_a  (sel_ser_a ? rxd_s[1] : 1'b1),
	.dart_rx_b  (sel_ser_b ? rxd_s[1] : 1'b1),
	.dart_tx_a  (dart_tx_a),
	.dart_tx_b  (dart_tx_b),
	.rom2_ok    (rom2_ok),
	.col80_en   (cg_ok),
	.video_sel  (status[22:21]),
	.cg_we      (cg_we),
	.cg_addr    (cg_addr),
	.cg_data    (ioctl_dout),
	.xram_se    (xram_se),
	.xram_addr  (xram_addr),
	.xram_do    (xram_do),
	.xram_mreq_n(xram_mreq_n),
	.xram_rd_n  (xram_rd_n),
	.xram_wr_n  (xram_wr_n),
	.xram_q     (xram_q),
	.xram_wait_n(xram_wait_n)
);

///////////////////////   EXPANSION RAM (SDRAM)   ///////////////////////
//
// The 256KB of the two RAM expansion boards (320K menu entry) is in the MiSTer's SDRAM, not in the FPGA. Without the
// SDRAM module that option has nothing behind it; with 64K (stock) the SDRAM is not used. See rtl/mtx_xsdram.sv.

wire        xram_se, xram_mreq_n, xram_rd_n, xram_wr_n, xram_wait_n;
wire [17:0] xram_addr;
wire  [7:0] xram_do, xram_q;

// the SDRAM controller starts itself; init holds it for the first clocks after configuration
reg  [3:0] sdr_init_cnt = 4'd0;
always @(posedge CLK_50M) if (!(&sdr_init_cnt)) sdr_init_cnt <= sdr_init_cnt + 4'd1;

mtx_xsdram xsdram
(
	.clk(CLK_50M),
	.init(~(&sdr_init_cnt)),

	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE),
	.SDRAM_CLK(SDRAM_CLK),

	.addr(xram_addr),
	.din(xram_do),
	.se(xram_se),
	.mreq(~xram_mreq_n),
	.rd(~xram_rd_n),
	.wr(~xram_wr_n),
	.dout(xram_q),
	.wait_n(xram_wait_n)
);

///////////////////////   SDX   ///////////////////////////////
//
// The Memotech SDX disc system: the FDC 05 controller card (a WD1793 on ports 10h..14h, 8KB SDX ROM in ROM page
// 3, or 5 on later cards) and one or two floppy discs. The discs are images mounted from the OSD (SDX Disc A and
// B). The card is fitted when boot3.rom (the SDX ROM) has been loaded. See rtl/sdx_fdc.sv.

// what the mounted images are: the size says the drive type (the switches the SDX ROM reads)
reg  [1:0] fl_mnt = 0, fl_ro = 0, fl_t40 = 0, fl_ss = 0;
reg [22:0] fl_blks0 = 0, fl_blks1 = 0;
wire       fl_t40_new = (img_size[31:0] == 32'd327680) | (img_size[31:0] == 32'd163840) | (img_size[31:0] == 32'd81920);
wire       fl_ss_new  = (img_size[31:0] == 32'd163840) | (img_size[31:0] == 32'd81920);
always @(posedge CLK_50M) begin
	if (img_mounted[1]) begin
		fl_mnt[0] <= (img_size != 0); fl_ro[0] <= img_readonly; fl_t40[0] <= fl_t40_new; fl_ss[0] <= fl_ss_new;
		fl_blks0 <= img_size[31:9];
	end
	if (img_mounted[2]) begin
		fl_mnt[1] <= (img_size != 0); fl_ro[1] <= img_readonly; fl_t40[1] <= fl_t40_new; fl_ss[1] <= fl_ss_new;
		fl_blks1 <= img_size[31:9];
	end
end

wire        sdx_rd_o, sdx_wr_o, sdx_drv;
assign sd_rd = {sdx_rd_o &  sdx_drv, sdx_rd_o & ~sdx_drv, 1'b0};
assign sd_wr = {sdx_wr_o &  sdx_drv, sdx_wr_o & ~sdx_drv, sv_sd_wr};
wire        sdx_ack = sdx_drv ? sd_ack[2] : sd_ack[1];

sdx_fdc sdx
(
	.clk(clk_cpu),
	.clk_sys(CLK_50M),
	.reset(reset_core),

	.cs(fdc_cs),
	.a(fdc_a),
	.wr(fdc_wr),
	.rd(fdc_rd),
	.din(fdc_do),
	.dout(fdc_di),

	.d_mnt(fl_mnt),
	.d_ro(fl_ro),
	.d_t40(fl_t40),
	.d_ss(fl_ss),
	.d_blks0(fl_blks0),
	.d_blks1(fl_blks1),

	.sd_rd_o(sdx_rd_o),
	.sd_wr_o(sdx_wr_o),
	.sd_drv(sdx_drv),
	.sd_lba(sdx_lba),
	.sd_ack(sdx_ack),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),
	.sd_buff_din(sdx_buff_din)
);

assign CLK_VIDEO = clk_25;
assign CE_PIXEL  = 1'b1;

assign VGA_R  = {r, r};
assign VGA_G  = {g, g};
assign VGA_B  = {b, b};
assign VGA_HS = ~HSync;
assign VGA_VS = ~VSync;
assign VGA_DE = ~(HBlank | VBlank);

// The sound chip model updates about 250000 times a second in the (variable) Z80 clock domain;
// the framework picks one sample 48000 times a second. Average each 1024 clocks (48.8kHz) in the
// fixed 50MHz domain so that nothing aliases, and only look at the value when it is stable.
reg  [2:0]  snd_s = 0;
reg  [1:0]  snd_wait = 0;
reg  [15:0] snd_hold = 0;
reg  [9:0]  snd_cnt = 0;
reg  signed [25:0] snd_acc = 0;
reg  [15:0] pcm = 0;

always @(posedge CLK_50M) begin
	snd_s <= {snd_s[1:0], audio_strobe};
	if (snd_s[2] ^ snd_s[1]) snd_wait <= 2'd3;
	else if (snd_wait != 0) begin
		snd_wait <= snd_wait - 1'd1;
		if (snd_wait == 2'd1) snd_hold <= audio_raw;
	end

	snd_acc <= snd_acc + $signed(snd_hold);
	snd_cnt <= snd_cnt + 1'd1;
	if (&snd_cnt) begin
		pcm     <= (snd_acc + $signed(snd_hold)) >>> 10;
		snd_acc <= 0;
	end
end

assign AUDIO_L = pcm;
assign AUDIO_R = pcm;

assign LED_USER = tape_playing | tape_motor | sv_busy | sdx_rd_o | sdx_wr_o;

endmodule
