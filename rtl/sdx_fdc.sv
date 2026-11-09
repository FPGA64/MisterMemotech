//============================================================================
//
//  sdx_fdc - the Memotech SDX floppy disc controller, with the discs as image files on the SD card.
//
//  The SDX FDC 05 card (schematic, designer Tony Brewer) has a WD1793 and, on the I/O ports
//      10h  write: command register        read: status register
//      11h  track register
//      12h  sector register
//      13h  data register
//      14h  write: drive control latch     read: status and switch buffer
//  The ROM driver of the SDX (an 8K ROM in ROM page 3 or 5) works the chip through these. This module is the 1793 as
//  that driver uses it: restore, seek, step, step in, step out, read sector, write sector (also several sectors),
//  read address, write track (format) and force interrupt. sim/sdx_fdc.py is the same thing in Python; the real SDX
//  ROM was run against that model (directory, load, save, run, stat).
//
//  Drive control latch (OUT 14h), from the schematic:  D0 drive (1 = B), D1 side, D2 motor on, D3 motor ready,
//  D4 density (1 = double density, 256 byte sectors; 0 = 128 byte sectors).
//  IN 14h:  D7 DRQ, D6 INTRQ, D5 READY (a disc in the drive and the motor on and ready), D4 two drives jumper,
//  D3 SW4 (step rate), D2 SW3 (1 = 40 track), D1 SW2 (1 = single sided), D0 SW1 (head load solenoid).
//
//  A disc is a raw image: sector = ((sides * track + side) * 16 + sector - 1) * length, 16 sectors per track,
//  256 or 128 bytes a sector. The size of the image sets the switches the ROM reads:
//      655360  80 tracks, double sided   (Memotech type 07)
//      327680  40 tracks, double sided   (type 03)
//      163840  40 tracks, single sided   (type 02)
//       81920  40 tracks, single sided, single density (type 00)
//  The SD card is read and written in 512 byte blocks. A sector is a half (or a quarter) of a block, so a sector
//  write reads the block, changes the sector and writes the block. The ROM polls DRQ, so it simply waits.
//
//  Two clocks: clk (the CPU clock) runs the controller and its registers; clk_sys (50MHz, hps_io) runs the block
//  mover. They meet in a dual clock block RAM and a request/acknowledge pair of toggles.
//
//============================================================================

module sdx_fdc
(
	input         clk,              // CPU clock
	input         clk_sys,          // 50MHz
	input         reset,            // CPU clock domain

	// the Z80 bus, ports 10h..14h (cs is for those ports only)
	input         cs,
	input   [2:0] a,
	input         wr,
	input         rd,
	input   [7:0] din,
	output  [7:0] dout,

	// the drives (clk_sys domain, quasi static)
	input   [1:0] d_mnt,            // an image is mounted
	input   [1:0] d_ro,             // and it is read only
	input   [1:0] d_t40,            // 40 tracks (else 80)
	input   [1:0] d_ss,             // single sided (else double)
	input  [22:0] d_blks0,          // size of the image in 512 byte blocks
	input  [22:0] d_blks1,

	// hps_io, one virtual drive per floppy; the top level connects these to the right index
	output reg        sd_rd_o = 0,
	output reg        sd_wr_o = 0,
	output reg        sd_drv  = 0,  // 0 = drive A, 1 = drive B
	output reg [31:0] sd_lba  = 0,
	input             sd_ack,       // of the drive in use
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	input             sd_buff_wr,
	output      [7:0] sd_buff_din
);

// status register bits of the 1793
localparam [7:0] NOT_READY = 8'h80, PROTECTED = 8'h40, HEAD_LOADED = 8'h20, SEEK_ERROR = 8'h10,
                 TRACK_00 = 8'h04, DATA = 8'h02, BUSY = 8'h01;

// ---- the drive information, into the CPU clock domain
reg [1:0]  mnt_s0 = 0, mnt_s = 0, ro_s0 = 0, ro_s = 0, t40_s0 = 0, t40_s = 0, ss_s0 = 0, ss_s = 0, mnt_p = 0;
reg [22:0] blks0_s0 = 0, blks0_s = 0, blks1_s0 = 0, blks1_s = 0;
always @(posedge clk) begin
	mnt_s0 <= d_mnt; mnt_s <= mnt_s0; mnt_p <= mnt_s;
	ro_s0 <= d_ro;   ro_s <= ro_s0;
	t40_s0 <= d_t40; t40_s <= t40_s0;
	ss_s0 <= d_ss;   ss_s <= ss_s0;
	blks0_s0 <= d_blks0; blks0_s <= blks0_s0;
	blks1_s0 <= d_blks1; blks1_s <= blks1_s0;
end

// ---- registers
reg  [7:0] status = 0, command = 0, trk = 0, sec = 0, dat = 0;
reg  [4:0] ctl = 0;                 // the control latch
reg        int_r = 0, drq = 0;
reg  [7:0] dtrk0 = 0, dtrk1 = 0;    // the head position of each drive
reg  [1:0] dd = 2'b11;              // per drive: 256 byte sectors (from the control latch)
reg        dir_in = 0;

wire        drv   = ctl[0];
wire        side  = ctl[1];
wire        mnt   = drv ? mnt_s[1] : mnt_s[0];
wire        ro    = drv ? ro_s[1]  : ro_s[0];
wire        t40   = drv ? t40_s[1] : t40_s[0];
wire        ss    = drv ? ss_s[1]  : ss_s[0];
wire [22:0] blks  = drv ? blks1_s  : blks0_s;
wire [7:0]  dtrk  = drv ? dtrk1 : dtrk0;
wire        ready = mnt && ctl[2] && ctl[3];
wire        dens  = drv ? dd[1] : dd[0];                // 1 = 256 byte sectors
wire        dsd   = !ss;                                 // double sided

// the switches (a drive without a disc reads as the default: 80 track, double sided)
wire [4:0] cfg  = {1'b1, 1'b0, mnt & t40, mnt & ss, 1'b0};
wire [7:0] st14 = {drq, int_r, ready, cfg};

// ---- the block buffers, two simple dual clock RAMs:
//      xram: filled by the HPS (SD read), read by the controller            (read a sector; the old block of a write)
//      yram: written by the controller, read by the HPS (SD write)          (the block that is written back)
// A write first reads the block into xram and copies it to yram (S_COPY), then the Z80's bytes replace the sector.
reg  [7:0] xram [0:511];
reg  [7:0] yram [0:511];
reg  [7:0] qx = 0, qy = 0;
reg        y_we = 0;
reg  [8:0] x_addr = 0, y_addr = 0;
reg  [7:0] y_din = 0;
reg        sd_busy = 0, sd_is_wr = 0;
always @(posedge clk_sys) begin
	if (sd_buff_wr && sd_busy && !sd_is_wr) xram[sd_buff_addr] <= sd_buff_dout;   // the HPS sends a block
	qy <= yram[sd_buff_addr];                                                      // the HPS reads a block
end
always @(posedge clk) begin
	if (y_we) yram[y_addr] <= y_din;
	qx <= xram[x_addr];
end
wire [7:0] qa = qy;
assign sd_buff_din = qa;

// ---- block requests between the clock domains: toggles
reg        req_t = 0, req_op = 0, req_drv = 0;
reg [31:0] req_lba = 0;
reg  [2:0] ack_s = 0;
reg  [1:0] err_s = 0;
reg        ack_t_sys = 0, ack_err_sys = 0;
always @(posedge clk) begin ack_s <= {ack_s[1:0], ack_t_sys}; err_s <= {err_s[0], ack_err_sys}; end
wire       ack_pulse = ack_s[2] ^ ack_s[1];
wire       ack_err   = err_s[1];

reg  [2:0] rq_s = 0;
reg        req_seen = 0;
reg  [1:0] sstate = 0;
reg [26:0] sto = 0;
localparam [1:0] SS_IDLE = 0, SS_ACK = 1, SS_DONE = 2;
always @(posedge clk_sys) begin
	rq_s <= {rq_s[1:0], req_t};
	case (sstate)
	SS_IDLE: begin
		sd_rd_o <= 0; sd_wr_o <= 0; sd_busy <= 0;
		if (rq_s[1] != req_seen) begin
			req_seen <= rq_s[1];
			sd_drv <= req_drv; sd_lba <= req_lba; sto <= 0; sd_busy <= 1; sd_is_wr <= req_op;
			if (req_op) sd_wr_o <= 1; else sd_rd_o <= 1;
			sstate <= SS_ACK;
		end
	end
	SS_ACK: begin
		sto <= sto + 1'd1;
		if (sd_ack) begin sd_rd_o <= 0; sd_wr_o <= 0; sstate <= SS_DONE; sto <= 0; end
		else if (&sto[26:24]) begin   // about 2.7 s: the HPS did not answer
			sd_rd_o <= 0; sd_wr_o <= 0; ack_err_sys <= 1; ack_t_sys <= ~ack_t_sys; sstate <= SS_IDLE;
		end
	end
	SS_DONE: begin
		sto <= sto + 1'd1;
		if (!sd_ack) begin ack_err_sys <= 0; ack_t_sys <= ~ack_t_sys; sstate <= SS_IDLE; end
		else if (&sto[26:24]) begin ack_err_sys <= 1; ack_t_sys <= ~ack_t_sys; sstate <= SS_IDLE; end
	end
	default: sstate <= SS_IDLE;
	endcase
end

// ------------------------------------------------------------------------------------------------------------
// the controller
localparam [3:0] S_IDLE = 0, S_FETCH = 1, S_RDATA = 2, S_WDATA = 3, S_COMMIT = 4, S_RADDR = 5, S_WTRK = 6, S_NEXT = 7, S_COPY = 8;
reg  [3:0] st = S_IDLE;
reg  [9:0] cp_cnt = 0;
reg        fetch_wr = 0;            // when the block is here: 0 the sector is read, 1 it is written
reg  [1:0] wtk = 0;                 // write track: 0 wait for FE, 1 the address mark, 2 wait for FB, 3 the sector data
reg  [4:0] wtk_numsec = 0;
reg  [8:0] pos = 0;                 // byte within the sector (or within the ID / the read address)
reg  [8:0] boff = 0;                // where the sector starts in the block buffer
reg        blk_valid = 0, blk_drv = 0;
reg [10:0] blk_lba = 0;
reg  [4:0] raid = 0;
reg  [2:0] ra_n = 0;
reg        wr_d = 0, rd_d = 0, cs_d = 0;
reg  [2:0] a_d = 0;
reg  [7:0] id_sec = 0;
reg        id_len = 0;                 // length code of the ID field: 1 = 256 byte sectors
reg        sd_pend = 0;               // a block request has been made and not yet answered

wire        wr_p   = wr && !wr_d;                // write strobe, one clock
wire        rd_end = !rd && rd_d && cs_d;        // a read cycle of the Z80 has just finished (cs_d: it was ours)
wire        fmt    = (command[7:4] == 4'hF);
wire [7:0]  use_sec = fmt ? id_sec : sec;

// the address of the sector: its block and the place in the block. Worked out in registered stages (each one is a
// small piece of logic): the registers it depends on are written by the Z80 many clocks before a command, and a
// multiple sector command waits (S_NEXT) for the stages to catch up.
wire [11:0] sidx_w = ((({4'b0, dtrk} << dsd) + side) << 4) + use_sec - 1'd1;
reg  [11:0] sidx_r = 0;                              // stage 1
wire [19:0] soff_w = dens ? {sidx_r, 8'b0} : {1'b0, sidx_r, 7'b0};
reg  [10:0] sblk_r = 0;                              // stage 2
reg   [8:0] sboff_r = 0;
reg         in_image_r = 0;
reg         sec_ok_r = 0;                            // stage 3
reg         have_blk_r = 0;
wire [10:0] sblk  = sblk_r;
wire [8:0]  sboff = sboff_r;
wire        sec_ok = sec_ok_r;
wire        have_blk = have_blk_r;
wire        last_b = dens ? (pos == 9'd255) : (pos == 9'd127);
always @(posedge clk) begin
	sidx_r     <= sidx_w;
	sblk_r     <= soff_w[19:9];
	sboff_r    <= soff_w[8:0];
	in_image_r <= mnt && ((soff_w[19:9] < blks[10:0]) || (blks[22:11] != 0));
	sec_ok_r   <= (sec >= 8'd1) && (sec <= 8'd16) && (trk == dtrk) && in_image_r;
	have_blk_r <= blk_valid && (blk_drv == drv) && (blk_lba == sblk_r);
end
reg   [2:0] nx_wait = 0;                             // clocks to wait in S_NEXT for the stages above

`define REQUEST(op) begin req_op <= (op); req_drv <= drv; req_lba <= {21'b0, sblk}; req_t <= ~req_t; sd_pend <= 1; end
// the command is over: status, INTRQ
`define FINISH(s) begin st <= S_IDLE; command <= 8'h00; status <= (s); drq <= 1'b0; int_r <= 1'b1; end
// the sector can be used: read its block if it is not in the buffer (a write always reads it, the sector is only
// part of the block)
`define BEGIN_SECTOR(wrc) begin 	boff <= sboff; pos <= 9'd0; 	if (!(wrc) && have_blk) begin st <= S_RDATA; status <= DATA | BUSY; drq <= 1'b1; end 	else begin fetch_wr <= (wrc); st <= S_FETCH; status <= BUSY; drq <= 1'b0; `REQUEST(1'b0) end end

// type I commands: where the head and the track register go
wire        inward_w = (din[7:5] == 3'b010) ? 1'b1 : (din[7:5] == 3'b011) ? 1'b0 : dir_in;
wire  [7:0] nt_seek  = dtrk + dat - trk;
wire  [7:0] nt_step  = inward_w ? dtrk + 8'd1 : ((dtrk != 8'd0) ? dtrk - 8'd1 : 8'd0);
wire  [7:0] ntr_step = din[4] ? (inward_w ? trk + 8'd1 : trk - 8'd1) : trk;

always @(posedge clk) begin
	wr_d <= wr; rd_d <= rd; cs_d <= cs; a_d <= a;
	y_we <= 0;
	x_addr <= (st == S_COPY) ? cp_cnt[8:0] : boff + pos;

	if (reset) begin
		st <= S_IDLE; status <= 0; command <= 0; trk <= 0; sec <= 0; dat <= 0; ctl <= 0; int_r <= 0; drq <= 0;
		dtrk0 <= 0; dtrk1 <= 0; dd <= 2'b11; dir_in <= 0; blk_valid <= 0; raid <= 0; wtk <= 0;
	end
	else begin
		if (ack_pulse) sd_pend <= 0;

		// a disc change makes the block in the buffer stale
		if (mnt_s != mnt_p) blk_valid <= 0;

		// a read of the status register resets INTRQ
		if (rd_end && a_d == 3'd0) int_r <= 0;

		// ---------------------------------------------------------------- the Z80 writes
		if (wr_p && cs) begin
			case (a)
			3'd0: if (!sd_pend) begin   // ---- command (not while a block is moving: the buffer is in use)
				int_r <= 0;
				command <= din;
				case (din[7:4])
				4'h0: begin   // restore
					trk <= 0; if (drv) dtrk1 <= 0; else dtrk0 <= 0; dir_in <= 0; st <= S_IDLE; drq <= 0;
					status <= (ready ? 8'h00 : NOT_READY) | (din[3] ? HEAD_LOADED : 8'h00) | TRACK_00; int_r <= 1;
				end
				4'h1: begin   // seek: the head moves by (data - track register), the track register becomes the data
					if (drv) dtrk1 <= nt_seek; else dtrk0 <= nt_seek;
					dir_in <= (dat > trk); trk <= dat; st <= S_IDLE; drq <= 0;
					status <= (ready ? 8'h00 : NOT_READY) | (din[3] ? HEAD_LOADED : 8'h00)
					        | ((din[2] && dat != nt_seek) ? SEEK_ERROR : 8'h00) | ((nt_seek == 8'd0) ? TRACK_00 : 8'h00); int_r <= 1;
				end
				4'h2, 4'h3, 4'h4, 4'h5, 4'h6, 4'h7: begin   // step, step in, step out
					dir_in <= inward_w;
					if (drv) dtrk1 <= nt_step; else dtrk0 <= nt_step;
					trk <= ntr_step; st <= S_IDLE; drq <= 0;
					status <= (ready ? 8'h00 : NOT_READY) | (din[3] ? HEAD_LOADED : 8'h00)
					        | ((din[2] && ntr_step != nt_step) ? SEEK_ERROR : 8'h00) | ((nt_step == 8'd0) ? TRACK_00 : 8'h00); int_r <= 1;
				end
				4'h8, 4'h9: begin   // read sector
					if (!ready) `FINISH(NOT_READY)
					else if (!sec_ok) `FINISH(SEEK_ERROR)
					else `BEGIN_SECTOR(1'b0)
				end
				4'hA, 4'hB: begin   // write sector
					if (!ready) `FINISH(NOT_READY)
					else if (ro) `FINISH(PROTECTED)
					else if (!sec_ok) `FINISH(SEEK_ERROR)
					else `BEGIN_SECTOR(1'b1)
				end
				4'hC: begin   // read address: six bytes of the next ID
					if (!ready) `FINISH(NOT_READY)
					else begin
						raid <= (raid == 5'd16 || raid == 5'd0) ? 5'd1 : raid + 1'd1;
						st <= S_RADDR; ra_n <= 0; status <= DATA | BUSY; drq <= 1;
					end
				end
				4'hD: begin   // force interrupt
					st <= S_IDLE; command <= 0; drq <= 0; int_r <= 1;
					status <= (ready ? 8'h00 : NOT_READY) | (din[3] ? HEAD_LOADED : 8'h00) | ((dtrk == 8'd0) ? TRACK_00 : 8'h00);
				end
				4'hE: `FINISH(SEEK_ERROR)   // read track: not used by the driver
				4'hF: begin   // write track: the format
					if (!ready) `FINISH(NOT_READY)
					else if (ro) `FINISH(PROTECTED)
					else begin st <= S_WTRK; wtk <= 2'd0; wtk_numsec <= 0; pos <= 0; status <= DATA | BUSY; drq <= 1; end
				end
				endcase
			end
			3'd1: trk <= din;
			3'd2: sec <= din;
			3'd3: begin   // ---- data
				if (st == S_WDATA) begin
					y_we <= 1; y_addr <= boff + pos; y_din <= din;
					if (last_b) begin     // the sector is complete: write the block back
						drq <= 0; status <= BUSY; st <= S_COMMIT; `REQUEST(1'b1)
					end
					else pos <= pos + 1'd1;
				end
				else if (st == S_WTRK) begin
					// the bytes of a track as the driver sends them:  FE trk side sec len F7 ... FB data... F7
					case (wtk)
					2'd0: if (din == 8'hFE) begin wtk <= 2'd1; pos <= 0; end
					2'd1: begin
						if (din == 8'hF7) begin
							// (the ID's track byte is only data: the sector goes where the head is)
							if (pos >= 9'd4 && id_sec >= 8'd1 && id_sec <= 8'd16 && id_len == dens) wtk <= 2'd2;
							else `FINISH(SEEK_ERROR)
						end
						else if (pos < 9'd4) begin
							case (pos[1:0]) 2'd2: id_sec <= din; 2'd3: id_len <= (din != 8'd0); default: ; endcase
							pos <= pos + 1'd1;
						end
						else `FINISH(SEEK_ERROR)
					end
					2'd2: if (din == 8'hFB) begin
						// the data mark: the block that holds this sector is read first
						wtk <= 2'd3; boff <= sboff; pos <= 0;
						fetch_wr <= 1; st <= S_FETCH; status <= BUSY; drq <= 0; `REQUEST(1'b0)
					end
					2'd3: begin
						if (din == 8'hF7) begin
							drq <= 0; status <= BUSY; st <= S_COMMIT; `REQUEST(1'b1)
						end
						else begin
							y_we <= 1; y_addr <= boff + pos; y_din <= din;
							if (!last_b) pos <= pos + 1'd1;
						end
					end
					endcase
				end
				else dat <= din;
			end
			3'd4: begin   // ---- drive control latch
				ctl <= din[4:0];
				if (din[0]) dd[1] <= din[4]; else dd[0] <= din[4];
			end
			default: ;
			endcase
		end

		// ---------------------------------------------------------------- the Z80 read a byte: step to the next
		if (rd_end && a_d == 3'd3 && st == S_RDATA) begin
			if (last_b) begin
				if (command[4]) begin sec <= sec + 1'd1; st <= S_NEXT; nx_wait <= 3'd4; drq <= 0; status <= BUSY; end    // several sectors
				else `FINISH(8'h00)
			end
			else pos <= pos + 1'd1;
		end
		if (rd_end && a_d == 3'd3 && st == S_RADDR) begin
			ra_n <= ra_n + 1'd1;
			if (ra_n == 3'd5) `FINISH(8'h00)
		end

		// ---------------------------------------------------------------- the block mover answers
		if (st == S_FETCH && ack_pulse) begin
			if (ack_err) begin blk_valid <= 0; `FINISH(SEEK_ERROR) end
			else begin
				blk_valid <= 1; blk_drv <= req_drv; blk_lba <= req_lba[10:0];
				if (fetch_wr) begin st <= S_COPY; cp_cnt <= 0; status <= BUSY; drq <= 0; end    // write: copy it to the write buffer
				else begin st <= S_RDATA; status <= DATA | BUSY; drq <= 1; end
			end
		end
		if (st == S_COPY) begin
			// xram -> yram: the address goes out on one clock, the data comes back on the next, then it is written
			cp_cnt <= cp_cnt + 1'd1;
			y_we <= (cp_cnt >= 10'd2) && (cp_cnt <= 10'd513);
			y_addr <= cp_cnt[8:0] - 9'd2;
			y_din <= qx;
			if (cp_cnt == 10'd514) begin
				st <= fmt ? S_WTRK : S_WDATA; status <= DATA | BUSY; drq <= 1;
			end
		end
		if (st == S_COMMIT && ack_pulse) begin
			blk_valid <= 0;                                      // the block on the card now differs from xram
			if (ack_err) begin blk_valid <= 0; `FINISH(SEEK_ERROR) end
			else if (fmt) begin                       // a sector of the format is written
				wtk <= 2'd0; wtk_numsec <= wtk_numsec + 1'd1;
				if (wtk_numsec == 5'd15) `FINISH(8'h00)
				else begin st <= S_WTRK; status <= DATA | BUSY; drq <= 1; end
			end
			else if (command[4]) begin sec <= sec + 1'd1; st <= S_NEXT; nx_wait <= 3'd4; end   // several sectors
			else `FINISH(8'h00)
		end

		// ---------------------------------------------------------------- the next sector of a multiple command
		if (st == S_NEXT) begin
			if (nx_wait != 3'd0) nx_wait <= nx_wait - 1'd1;
			else if (!sec_ok) `FINISH(SEEK_ERROR)
			else `BEGIN_SECTOR(command[7:5] != 3'b100)
		end
	end
end

// ---- what the Z80 reads
reg [7:0] ra_byte;
always @(*) begin
	case (ra_n)
	3'd0: ra_byte = dtrk;
	3'd1: ra_byte = {7'b0, side};
	3'd2: ra_byte = {3'b0, raid};
	3'd3: ra_byte = {7'b0, dens};
	default: ra_byte = 8'h00;
	endcase
end

reg [7:0] rd_mux;
always @(*) begin
	case (a)
	3'd0: rd_mux = status;
	3'd1: rd_mux = trk;
	3'd2: rd_mux = sec;
	3'd3: rd_mux = (st == S_RDATA) ? qx : (st == S_RADDR) ? ra_byte : dat;
	3'd4: rd_mux = st14;
	default: rd_mux = 8'hFF;
	endcase
end
assign dout = rd_mux;

endmodule

`undef REQUEST
`undef FINISH
`undef BEGIN_SECTOR
