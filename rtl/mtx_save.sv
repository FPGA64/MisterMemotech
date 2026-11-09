//============================================================================
//
//  mtx_save - SAVE to a mounted .mtx image.
//
//  The Z80 side (the INOUT overlay) streams the bytes of a SAVE to the port at 8E, tells us where a tape starts
//  (OUT 8F,2) and where a chunk ends (OUT 8F,4). The bytes are collected into 512 byte blocks and written to the
//  image the user mounted from the OSD (an SD block device through hps_io). The image is an ordinary .mtx file, so
//  it can be loaded again with Insert Tape.
//
//  - start : the first blocks of the image (at most 130, the largest tape that fits the MTX) are cleared to 00, so no
//            part of an older, longer tape is left behind. The file ends up as the new tape followed by 00 (a header
//            always starts with FF, so the next LOAD of the tape starts again from the top).
//  - byte  : goes into the block buffer; a full block is written out at once and the next block begins.
//  - flush : the rest of the current block is filled with 00 and the block is written. More bytes may follow in the
//            same block (a SAVE is several chunks).
//  Nothing is written if no image is mounted, if it is read only, or if it is not exactly 64 KB.
//  busy is high while a block is being written; the Z80 waits for it before the next byte.
//
//============================================================================

module mtx_save
(
	input         clk,              // 50MHz, the hps_io clock
	input         reset,

	// Z80 side: toggles and a byte that is stable around each toggle
	input         wr_t,             // a byte of tape was written
	input   [7:0] wr_d,
	input         start_t,          // a tape starts
	input         flush_t,          // the chunk is complete
	output        busy,

	// hps_io, one virtual drive
	input         img_mounted,
	input         img_readonly,
	input  [63:0] img_size,
	output reg [31:0] sd_lba,
	output reg        sd_wr,
	input             sd_ack,
	input       [8:0] sd_buff_addr,
	output      [7:0] sd_buff_din,

	output        mounted
);

parameter [31:0] ERASE_MAX = 32'd130;      // blocks cleared at the start of a tape: 65 KB
parameter [31:0] TIMEOUT   = 32'd100_000_000;   // 2 s: give up if the HPS never answers

// ---- the Z80 side toggles
reg [2:0] wr_s = 0, st_s = 0, fl_s = 0;
always @(posedge clk) begin
	wr_s <= {wr_s[1:0], wr_t};
	st_s <= {st_s[1:0], start_t};
	fl_s <= {fl_s[1:0], flush_t};
end
reg [4:0] holdoff = 0;                     // a reset can leave a toggle behind in the synchronisers: ignore it
always @(posedge clk) if (reset) holdoff <= 0; else if (!(&holdoff)) holdoff <= holdoff + 1'd1;
wire live = &holdoff;
wire wr_p = live & (wr_s[2] ^ wr_s[1]);
wire st_p = live & (st_s[2] ^ st_s[1]);
wire fl_p = live & (fl_s[2] ^ fl_s[1]);

// ---- the mounted image
// Only a file of exactly 64 KB is used (the blank tape that comes with the core). SAVE clears the start of the image,
// so a game tape mounted by mistake must not be written: those are never exactly this size.
localparam [63:0] IMG_SIZE = 64'd65536;
reg        mnt = 0;
reg [31:0] nblk = 0;
always @(posedge clk) begin
	if (reset) mnt <= 0;
	else if (img_mounted) begin
		mnt  <= (img_size == IMG_SIZE) && !img_readonly;
		nblk <= IMG_SIZE[40:9];
	end
end
assign mounted = mnt;

// ---- the block buffer: written by the state machine, read by the HPS (one clock of latency)
reg [7:0] ram [0:511];
reg       ram_we = 0;
reg [8:0] ram_wa = 0;
reg [7:0] ram_wd = 0;
reg [7:0] sd_q   = 0;
always @(posedge clk) begin
	if (ram_we) ram[ram_wa] <= ram_wd;
	sd_q <= ram[sd_buff_addr];
end
assign sd_buff_din = sd_q;

// ---- state machine
localparam [3:0] S_IDLE = 0, S_FILL = 1, S_PAD = 2, S_REQ = 3, S_ACK = 4, S_DONE = 5;
localparam [1:0] O_ERASE = 0, O_FLUSH = 1, O_FULL = 2;

reg  [3:0] st = S_IDLE;
reg  [1:0] op = O_ERASE;
reg  [9:0] cnt = 0;
reg  [9:0] wptr = 0;                       // bytes in the buffer (0..511), the block being filled is cur
reg [31:0] cur = 0;                        // block being filled
reg [31:0] er_n = 0, er_i = 0;
reg [31:0] to = 0;
reg        old_ack = 0;

assign busy = (st != S_IDLE);

always @(posedge clk) begin
	ram_we  <= 0;
	old_ack <= sd_ack;

	if (reset || !mnt) begin
		st <= S_IDLE; sd_wr <= 0; wptr <= 0; cur <= 0;
	end
	else case (st)

	S_IDLE: begin
		if (st_p) begin                    // a tape starts: clear the start of the image
			er_n <= (nblk > ERASE_MAX) ? ERASE_MAX : nblk;
			er_i <= 0; cnt <= 0; op <= O_ERASE; st <= S_FILL;
		end
		else if (fl_p) begin               // the chunk is complete: write the part block
			if (wptr != 0 && cur < nblk) begin
				cnt <= wptr; op <= O_FLUSH; st <= S_PAD;
			end
		end
		else if (wr_p) begin
			if (cur < nblk) begin
				ram_we <= 1; ram_wa <= wptr[8:0]; ram_wd <= wr_d;
				if (wptr == 10'd511) begin
					wptr <= 10'd512; op <= O_FULL; sd_lba <= cur; st <= S_REQ; to <= 0;
				end
				else wptr <= wptr + 1'd1;
			end
		end
	end

	S_FILL: begin                          // the buffer is all 00
		ram_we <= 1; ram_wa <= cnt[8:0]; ram_wd <= 8'h00;
		cnt <= cnt + 1'd1;
		if (cnt == 10'd511) begin
			sd_lba <= er_i; to <= 0; st <= S_REQ;
		end
	end

	S_PAD: begin                           // the rest of the block is 00
		ram_we <= 1; ram_wa <= cnt[8:0]; ram_wd <= 8'h00;
		cnt <= cnt + 1'd1;
		if (cnt == 10'd511) begin
			sd_lba <= cur; to <= 0; st <= S_REQ;
		end
	end

	S_REQ: begin                           // let the last buffer write land, then ask for the block to be written
		if (!ram_we) begin sd_wr <= 1; st <= S_ACK; end
	end

	S_ACK: begin
		to <= to + 1'd1;
		if (~old_ack & sd_ack) begin sd_wr <= 0; st <= S_DONE; to <= 0; end
		else if (to == TIMEOUT) begin sd_wr <= 0; st <= S_IDLE; end
	end

	S_DONE: begin
		to <= to + 1'd1;
		if (old_ack & ~sd_ack) begin
			case (op)
			O_ERASE: begin
				if (er_i + 1'd1 < er_n) begin
					er_i <= er_i + 1'd1; sd_lba <= er_i + 1'd1; to <= 0; st <= S_REQ;
				end
				else begin wptr <= 0; cur <= 0; st <= S_IDLE; end
			end
			O_FLUSH: st <= S_IDLE;
			O_FULL:  begin cur <= cur + 1'd1; wptr <= 0; st <= S_IDLE; end
			endcase
		end
		else if (to == TIMEOUT) st <= S_IDLE;
	end

	default: st <= S_IDLE;
	endcase
end

endmodule
