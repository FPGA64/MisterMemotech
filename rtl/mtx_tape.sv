//============================================================================
//
//  MTX cassette player: a .WAV file from the HPS, played back as the cassette input.
//
//  HPS (ioctl) --bytes--> DDR3 --64 bit words--> parser / sample reader --> Schmitt trigger --> tape_in
//
//  What the MTX board does with a cassette signal (schematic, MTX 500 4000-04):
//    ear jack -> op-amp (a Schmitt trigger) -> 4070 XOR with an RC-delayed copy -> one pulse per edge
//    -> Z80 CTC channel 3. The pulse generator is in mtx.vhd; this module makes the op-amp's output.
//  sim/tape_model.py runs this signal chain and the OS decoder on real tapes.
//
//  Supported: PCM WAV, mono or stereo (left channel used), 8 or 16 bit, any rate up to 192kHz.
//             .mtx files (a byte stream for the INOUT overlay, no tape signal).
//             .tap files (ZX Spectrum tapes): turned into the Spectrum tape signal here, as a Spectrum
//             core does: pilot tone, two sync pulses, one 855 or 1710 T-state pulse pair per bit, a one
//             second pause between blocks (T-state = 1/3.5MHz). For the Speculator add-on board.
//
//  Playback runs when the file is loaded and either the user pressed Play, or auto-play is on and
//  the MTX has switched its cassette motor on (OUT 1F,AA).
//
//============================================================================

module mtx_tape
(
	input         clk,              // 50MHz, same clock as hps_io and the DDR3 port
	input         reset,

	// HPS download (file index TAPE_IDX)
	input         ioctl_download,
	input         ioctl_wr,
	input  [26:0] ioctl_addr,
	input   [7:0] ioctl_dout,
	input  [15:0] ioctl_index,
	output        ioctl_wait,

	// DDR3
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	// user controls (one clock pulses)
	input         btn_play,         // play / pause
	input         btn_rewind,
	input         btn_eject,
	input         auto_play,        // run whenever the MTX motor is on

	// machine
	input         cpu_motor,        // asynchronous, from the Z80 side
	output        tape_in,
	output        tape_loaded,
	output        tape_playing,
	output        tape_error,

	// .mtx files: a byte stream for the INOUT overlay in mtx.vhd
	output        mtx_loaded,
	output        mtx_ready,        // a byte is waiting
	output        mtx_eof,          // no more bytes
	output  [7:0] mtx_byte,
	input         mtx_pop_t,        // toggles when the CPU has taken a byte (Z80 clock domain)
	input         mtx_rewind_t,     // toggles to restart the stream
	input         mtx_nm_t,         // toggles when the CPU has sent a character of the name asked for (port 8D)
	input   [7:0] mtx_nm_d,
	output        mtx_nodata        // the name asked for is not the name on the tape
);

parameter [15:0] TAPE_IDX  = 16'd1;
// .tap player: pulse counts and the pause, in the real values (a test bench shortens them)
parameter [12:0] TAP_PILOT_HDR  = 13'd8063;       // pilot pulses before a block whose flag byte is below 128
parameter [12:0] TAP_PILOT_DATA = 13'd3223;       // ... and 128 or above
parameter [25:0] TAP_PAUSE      = 26'd50_000_000; // one second between blocks
parameter [28:0] DDR_BASE  = 29'h06000000;   // 0x30000000 as a 64 bit word address
parameter [31:0] CLK_HZ    = 32'd50_000_000;

///////////////////////////////////////////////////////////////////////////////
// Block A: DDR3 port, download into DDR3, byte reader
///////////////////////////////////////////////////////////////////////////////

wire dl_active = ioctl_download && (ioctl_index[5:0] == TAPE_IDX[5:0]);   // [7:6] = which extension: 0 WAV, 1 MTX
reg  dl_active_d = 0;
wire dl_start  = dl_active & ~dl_active_d;
wire dl_end    = ~dl_active & dl_active_d;
reg  [1:0] ftype = 0;                       // 0 = WAV, 1 = MTX (extension index in the file index)
always @(posedge clk) if (dl_start) ftype <= ioctl_index[7:6];

reg  [28:0] d_addr = 0;
reg  [63:0] d_din  = 0;
reg   [7:0] d_be   = 0;
reg         d_rd   = 0;
reg         d_we   = 0;

assign DDRAM_ADDR     = d_addr;
assign DDRAM_DIN      = d_din;
assign DDRAM_BE       = d_be;
assign DDRAM_RD       = d_rd;
assign DDRAM_WE       = d_we;
assign DDRAM_BURSTCNT = 8'd1;

reg         wr_pend = 0;
reg  [28:0] wr_addr = 0;
reg  [63:0] wr_data = 0;
reg   [7:0] wr_be   = 0;

reg         rd_pend = 0;
reg         rd_wait = 0;
reg  [28:0] rd_addr = 0;

reg  [63:0] cache    = 0;
reg  [23:0] cache_w  = 0;
reg         cache_ok = 0;

reg  [63:0] wbuf = 0;
reg  [26:0] last_addr = 0;
reg  [26:0] file_len  = 0;
reg         flush     = 0;
reg         dl_done   = 0;      // pulses when the whole file is in DDR3

assign ioctl_wait = wr_pend;

// byte reader: rb_start pulse with rb_idx, answer in rb_data with a rb_done pulse
wire        rb_start;
wire [26:0] rb_idx;
reg         rb_active = 0;
reg   [7:0] rb_data   = 0;
reg         rb_done   = 0;
wire [23:0] rb_w      = rb_idx[26:3];

always @(posedge clk) begin
	dl_active_d <= dl_active;
	dl_done     <= 0;
	rb_done     <= 0;

	// ---- DDR3 port
	if (!DDRAM_BUSY) begin
		d_rd <= 0;
		d_we <= 0;
		if (wr_pend) begin
			d_addr  <= wr_addr;
			d_din   <= wr_data;
			d_be    <= wr_be;
			d_we    <= 1;
			wr_pend <= 0;
		end
		else if (rd_pend) begin
			d_addr  <= rd_addr;
			d_be    <= 8'hFF;
			d_rd    <= 1;
			rd_pend <= 0;
			rd_wait <= 1;
		end
	end

	if (DDRAM_DOUT_READY && rd_wait) begin
		cache    <= DDRAM_DOUT;
		cache_w  <= rd_addr[23:0];
		cache_ok <= 1;
		rd_wait  <= 0;
	end

	// ---- download: bytes -> 64 bit words
	if (dl_active && ioctl_wr) begin
		wbuf[{ioctl_addr[2:0], 3'b000} +: 8] <= ioctl_dout;
		last_addr <= ioctl_addr;
		if (ioctl_addr[2:0] == 3'd7) begin
			wr_addr <= DDR_BASE + {5'd0, ioctl_addr[26:3]};
			wr_data <= {ioctl_dout, wbuf[55:0]};
			wr_be   <= 8'hFF;
			wr_pend <= 1;
		end
	end

	if (dl_end) flush <= 1;

	if (flush && !wr_pend && !d_we) begin       // the last, partial word
		flush    <= 0;
		file_len <= last_addr + 1'd1;
		if (last_addr[2:0] != 3'd7) begin
			wr_addr <= DDR_BASE + {5'd0, last_addr[26:3]};
			wr_data <= wbuf;
			wr_be   <= 8'((9'd1 << (last_addr[2:0] + 1'd1)) - 9'd1);
			wr_pend <= 1;
		end
		dl_done <= 1;
	end

	// ---- byte reader
	if (rb_start) rb_active <= 1;

	if (rb_active && !wr_pend && !d_we && !flush) begin
		if (cache_ok && cache_w == rb_w) begin
			rb_data   <= cache[{rb_idx[2:0], 3'b000} +: 8];
			rb_done   <= 1;
			rb_active <= 0;
		end
		else if (!rd_pend && !rd_wait && !d_rd) begin
			rd_addr <= DDR_BASE + {5'd0, rb_w};
			rd_pend <= 1;
		end
	end

	if (dl_start) begin
		cache_ok  <= 0;
		rb_active <= 0;
	end

	if (reset) begin
		wr_pend   <= 0;
		rd_pend   <= 0;
		rd_wait   <= 0;
		flush     <= 0;
		rb_active <= 0;
		cache_ok  <= 0;
	end
end

///////////////////////////////////////////////////////////////////////////////
// Block B: WAV header parser
///////////////////////////////////////////////////////////////////////////////

localparam [3:0] S_NONE   = 0,
                 S_FIELD  = 2,   // read fld_n bytes from fld_addr into fld_val, then go to ret
                 S_RIFF   = 3,
                 S_WAVE   = 4,
                 S_CID    = 5,
                 S_CSZ    = 6,
                 S_FMT    = 7,
                 S_READY  = 8,
                 S_ERROR  = 9,
                 S_MTX    = 10,   // a .mtx file: no parsing, the stream is served to the INOUT overlay
                 S_TAP    = 11;   // a .tap file: no parsing, the tap player makes the Spectrum tape signal

reg   [3:0] state = S_NONE;
reg   [3:0] ret   = S_NONE;
reg  [26:0] fld_addr = 0;
reg   [2:0] fld_n    = 0;
reg   [2:0] fld_k    = 0;
reg  [31:0] fld_val  = 0;
reg         fld_req  = 0;

reg  [26:0] pos = 0;             // current chunk
reg  [31:0] cid = 0;
reg  [31:0] csz = 0;
reg   [1:0] fmt_step = 0;
reg  [15:0] w_tag = 0, w_chans = 0, w_bits = 0;
reg  [31:0] w_rate = 0;
reg  [26:0] data_start = 0;
reg  [26:0] data_len   = 0;
reg         have_fmt   = 0;

reg         p_rb_start = 0;
reg  [26:0] p_rb_idx   = 0;
reg         rewind_req = 0;      // pulses when a file has just become ready

wire [26:0] next_chunk = pos + 27'd8 + csz[26:0] + {26'd0, csz[0]};

task field(input [26:0] a, input [2:0] n, input [3:0] r);
begin
	fld_addr <= a;
	fld_n    <= n;
	fld_k    <= 0;
	fld_val  <= 0;
	ret      <= r;
	state    <= S_FIELD;
	fld_req  <= 1;
end
endtask

always @(posedge clk) begin
	rewind_req <= 0;
	p_rb_start <= 0;

	case (state)
		S_FIELD: begin
			if (fld_req) begin
				p_rb_idx   <= fld_addr + fld_k;
				p_rb_start <= 1;
				fld_req    <= 0;
			end
			else if (rb_done) begin
				fld_val[{fld_k[1:0], 3'b000} +: 8] <= rb_data;
				if (fld_k + 1'd1 == fld_n) state <= ret;
				else begin
					fld_k   <= fld_k + 1'd1;
					fld_req <= 1;
				end
			end
		end

		S_RIFF: begin
			if (fld_val != 32'h46464952) state <= S_ERROR;      // "RIFF"
			else field(27'd8, 3'd4, S_WAVE);
		end

		S_WAVE: begin
			if (fld_val != 32'h45564157) state <= S_ERROR;      // "WAVE"
			else begin
				pos      <= 27'd12;
				have_fmt <= 0;
				field(27'd12, 3'd4, S_CID);
			end
		end

		S_CID: begin
			cid <= fld_val;
			field(pos + 27'd4, 3'd4, S_CSZ);
		end

		S_CSZ: begin
			csz <= fld_val;
			if (cid == 32'h20746D66) begin                       // "fmt "
				fmt_step <= 0;
				field(pos + 27'd8, 3'd2, S_FMT);
			end
			else if (cid == 32'h61746164) begin                  // "data"
				data_start <= pos + 27'd8;
				data_len   <= (fld_val[26:0] > file_len) ? file_len : fld_val[26:0];
				state      <= (have_fmt && (w_tag == 16'd1) && (w_rate != 0) && (w_rate <= 32'd192000) &&
				               (w_bits == 16'd8 || w_bits == 16'd16) && (w_chans == 16'd1 || w_chans == 16'd2))
				              ? S_READY : S_ERROR;
				rewind_req <= 1;
			end
			else begin
				pos <= pos + 27'd8 + fld_val[26:0] + {26'd0, fld_val[0]};
				if (pos + 27'd8 + fld_val[26:0] > file_len) state <= S_ERROR;
				else field(pos + 27'd8 + fld_val[26:0] + {26'd0, fld_val[0]}, 3'd4, S_CID);
			end
		end

		S_FMT: begin
			case (fmt_step)
				2'd0: begin w_tag   <= fld_val[15:0]; fmt_step <= 2'd1; field(pos + 27'd10, 3'd2, S_FMT); end
				2'd1: begin w_chans <= fld_val[15:0]; fmt_step <= 2'd2; field(pos + 27'd12, 3'd4, S_FMT); end
				2'd2: begin w_rate  <= fld_val;       fmt_step <= 2'd3; field(pos + 27'd22, 3'd2, S_FMT); end
				2'd3: begin
					w_bits   <= fld_val[15:0];
					have_fmt <= 1;
					pos      <= next_chunk;
					field(next_chunk, 3'd4, S_CID);
				end
			endcase
		end

		default: ;
	endcase

	// a new file: parse it once its last word has been written
	if (dl_start) state <= S_NONE;
	if (dl_done) begin
		if (ftype == 2'd1)      state <= S_MTX;
		else if (ftype == 2'd2) state <= S_TAP;
		else                    field(27'd0, 3'd4, S_RIFF);
	end

	if (reset || btn_eject) state <= S_NONE;
end

wire wav_loaded = (state == S_READY);
assign tape_loaded = wav_loaded | (state == S_TAP);
assign tape_error  = (state == S_ERROR);

///////////////////////////////////////////////////////////////////////////////
// Block C: playback
///////////////////////////////////////////////////////////////////////////////

// the MTX motor line comes from the Z80 clock domain
reg [2:0] motor_s = 0;
always @(posedge clk) motor_s <= {motor_s[1:0], cpu_motor};
wire motor_on = motor_s[2];

reg  manual_run = 0;
reg  ended      = 0;
wire run = wav_loaded & ~ended & (manual_run | (auto_play & motor_on));
wire tap_run;
assign tape_playing = run | tap_run;

wire        bits16   = (w_bits == 16'd16);
wire        stereo   = (w_chans == 16'd2);
wire  [1:0] frame_sh = {1'b0, bits16} + {1'b0, stereo};      // bytes per frame = 1 << frame_sh

reg  [26:0] smp_n = 0;           // frame number
reg         nxt_valid = 0;
reg   [7:0] nxt_val   = 0;
reg         fetching  = 0;
reg  [31:0] acc       = 0;
reg  [15:0] dc        = 0;
reg         first     = 1;

reg         wav_in = 0;
reg         y_rb_start = 0;
reg  [26:0] y_rb_idx   = 0;

wire [27:0] byte_off = {1'b0, smp_n} << frame_sh;

always @(posedge clk) begin
	reg [31:0] acc_n;
	reg signed [16:0] diff;
	reg [15:0] dc_n;
	reg signed [9:0] x;
	reg  [7:0] s;

	y_rb_start <= 0;

	if (btn_play) manual_run <= ~manual_run;

	if (rewind_req || btn_rewind || reset || dl_start || btn_eject) begin
		smp_n     <= 0;
		nxt_valid <= 0;
		fetching  <= 0;
		ended     <= 0;
		first     <= 1;
		acc       <= 0;
		if (btn_rewind || btn_eject || reset) manual_run <= 0;
	end
	else if (wav_loaded && !ended) begin
		// fetch the next sample ahead of its tick
		if (!nxt_valid && !fetching) begin
			if (byte_off >= {1'b0, data_len}) ended <= 1;
			else begin
				y_rb_idx   <= data_start + byte_off[26:0] + {26'd0, bits16};
				y_rb_start <= 1;
				fetching   <= 1;
			end
		end
		if (fetching && rb_done) begin
			nxt_val   <= bits16 ? (rb_data ^ 8'h80) : rb_data;
			nxt_valid <= 1;
			fetching  <= 0;
		end

		if (run) begin
			acc_n = acc + w_rate;
			if (acc_n >= CLK_HZ) begin
				acc_n = acc_n - CLK_HZ;
				if (nxt_valid) begin
					s = nxt_val;
					if (first) begin
						dc_n  = {s, 8'd0};
						first <= 0;
					end
					else begin
						diff = $signed({1'b0, s, 8'd0}) - $signed({1'b0, dc});
						dc_n = dc + {{7{diff[16]}}, diff[16:8]};   // signed step, as the model's >> 8
					end
					dc <= dc_n;
					x  = $signed({2'b00, s}) - $signed({2'b00, dc_n[15:8]});
					if (x > 10'sd8)       wav_in <= 1;
					else if (x < -10'sd8) wav_in <= 0;
					nxt_valid <= 0;
					smp_n     <= smp_n + 1'd1;
				end
			end
			acc <= acc_n;
		end
	end
end


///////////////////////////////////////////////////////////////////////////////
// Block D: .mtx byte stream
//
// A .mtx file is the bytes the OS passes to INOUT, in order (3.3 of the spec). A small FIFO is kept
// full from DDR3 and the Z80 side takes bytes with IN A,(8E). The Z80 clock domain tells us about
// each byte it took (mtx_pop_t toggles) and about a restart (mtx_rewind_t toggles).
///////////////////////////////////////////////////////////////////////////////

assign mtx_loaded = (state == S_MTX);

reg  [2:0] pop_s = 0, rew_s = 0;
always @(posedge clk) begin
	pop_s <= {pop_s[1:0], mtx_pop_t};
	rew_s <= {rew_s[1:0], mtx_rewind_t};
end
wire pop_pulse = pop_s[2] ^ pop_s[1];
wire rew_ext   = rew_s[2] ^ rew_s[1];
reg  nd_rew    = 0;                       // a name mismatch also starts the tape again
wire rew_pulse = rew_ext | nd_rew;

reg   [7:0] fifo [0:7];
reg   [2:0] f_wr = 0, f_rd = 0;
reg   [3:0] f_cnt = 0;
reg  [26:0] m_idx = 0;           // next file byte to fetch
reg         m_fetching = 0;
reg         m_discard  = 0;      // a rewind happened while a read was in flight
reg         m_rb_start = 0;
reg  [26:0] m_rb_idx   = 0;

// Past the end of the file the stream keeps answering "ready" with FF, like blank tape marker bytes.
// Many .mtx files stop short of the last bytes the OS reads (usually a 1 byte end marker, which is FF in
// the files that have it); without this LOAD would wait at "Found:" for bytes that are not there.
// mtx_eof stays set, so the overlay still restarts the file when the next header is asked for.
wire   eof_raw   = (f_cnt == 0) && (m_idx >= file_len) && !m_fetching;
assign mtx_ready = (f_cnt != 0) || eof_raw;
assign mtx_byte  = (f_cnt != 0) ? fifo[f_rd] : 8'hFF;
// mtx_eof is what the overlay asks when a header chunk is wanted: start the tape again if it is at its end, or if
// the next byte is not FF (a header always starts with FF; what follows a SAVEd tape is not FF). A tape with
// several files one after the other has an FF there, so a second LOAD goes on to the next file.
assign mtx_eof   = eof_raw || (f_cnt != 0 && fifo[f_rd] != 8'hFF);

always @(posedge clk) begin
	m_rb_start <= 0;

	if (state != S_MTX || rew_pulse) begin
		f_wr  <= 0;
		f_rd  <= 0;
		f_cnt <= 0;
		m_idx <= 0;
		if (m_fetching) m_discard <= 1;
	end
	else begin
		if (pop_pulse && f_cnt != 0) begin
			f_rd <= f_rd + 1'd1;
		end

		if (m_fetching && rb_done) begin
			m_fetching <= 0;
			m_discard  <= 0;
			if (!m_discard) begin
				fifo[f_wr] <= rb_data;
				f_wr       <= f_wr + 1'd1;
				m_idx      <= m_idx + 1'd1;
			end
		end
		else if (!m_fetching && f_cnt < 4'd7 && m_idx < file_len) begin
			m_rb_idx   <= m_idx;
			m_rb_start <= 1;
			m_fetching <= 1;
		end

		f_cnt <= f_cnt + ((m_fetching && rb_done && !m_discard) ? 4'd1 : 4'd0)
		               - ((pop_pulse && f_cnt != 0) ? 4'd1 : 4'd0);
	end

	if (reset) begin
		m_fetching <= 0;
		m_discard  <= 0;
	end
end

// ---- LOAD "NAME": is this the tape asked for?
// The name on the tape is bytes 1..15 of the file; they are caught as the CPU takes them. The CPU then sends the 15
// characters of the name asked for (OTIR to port 8D) at the end of every LOAD/VERIFY chunk. If that chunk was the
// 18 byte header (18 bytes taken since the stream started) the two are compared: exact, ignoring case, a blank name
// asks for any tape. A mismatch sets mtx_nodata for the CPU and starts the tape again, so the next LOAD is clean.
reg  [5:0] pcnt = 0;                      // bytes taken since the stream started, stops at 63
reg  [7:0] tn [0:14];                     // the name on the tape
reg  [7:0] rq [0:14];                     // the name asked for
reg  [3:0] nm_cnt = 0;
reg        nm_done = 0;
reg        no_data = 0;
reg  [2:0] nm_s = 0;
always @(posedge clk) nm_s <= {nm_s[1:0], mtx_nm_t};
wire nm_pulse = nm_s[2] ^ nm_s[1];

reg  mismatch;
reg  decided;
integer q;
always @* begin
	mismatch = 0;
	decided  = (rq[0] < 8'h21);               // LOAD "": any tape will do
	for (q = 0; q < 15; q = q + 1) begin
		if (!decided) begin
			if ((rq[q] | 8'h20) != (tn[q] | 8'h20)) begin
				decided = 1;
				if (rq[q] >= 8'h21 || tn[q] >= 8'h21) mismatch = 1;   // one name goes on: different
			end
			else if (rq[q] < 8'h21) decided = 1;                      // equal, and both names end here
		end
	end
end

always @(posedge clk) begin
	nd_rew  <= 0;
	nm_done <= 0;

	if (state != S_MTX || rew_pulse) pcnt <= 0;
	else if (pop_pulse && f_cnt != 0) begin
		if (pcnt != 6'd63) pcnt <= pcnt + 1'd1;
		if (pcnt >= 6'd1 && pcnt <= 6'd15) tn[pcnt - 1'd1] <= fifo[f_rd];
	end

	if (nm_pulse) begin
		if (nm_cnt == 0) no_data <= 0;
		rq[nm_cnt] <= mtx_nm_d;
		if (nm_cnt == 4'd14) begin nm_cnt <= 0; nm_done <= 1; end
		else nm_cnt <= nm_cnt + 1'd1;
	end

	if (nm_done && state == S_MTX && pcnt == 6'd18 && mismatch) begin
		no_data <= 1;
		nd_rew  <= 1;
	end

	if (reset) begin nm_cnt <= 0; no_data <= 0; end
end
assign mtx_nodata = no_data;

///////////////////////////////////////////////////////////////////////////////
// Block E: .tap player (ZX Spectrum tapes)
//
// A .tap file is a series of blocks: a 16 bit length, then that many bytes (the first is the flag byte, the last a
// parity byte). The Spectrum ROM saves a block as: a pilot tone (flag below 128, a header: 8063 pulses, else 3223),
// a sync pulse of 667 T-states, one of 735, then each bit MSB first as two pulses of 855 T-states (0) or 1710 (1),
// and a pause of a second before the next block. A pulse is one level; tape_in changes at the end of it.
// 1 T-state is 1/3.5MHz = 100/7 clocks of 50MHz.
///////////////////////////////////////////////////////////////////////////////

localparam [25:0] HP_PILOT = 26'd30971;    // 2168 T
localparam [25:0] HP_SYNC1 = 26'd9529;     //  667 T
localparam [25:0] HP_SYNC2 = 26'd10500;    //  735 T
localparam [25:0] HP_BIT0  = 26'd12214;    //  855 T
localparam [25:0] HP_BIT1  = 26'd24429;    // 1710 T

localparam [2:0] TP_L0 = 0, TP_L1 = 1, TP_F = 2, TP_PILOT = 3, TP_SYNC1 = 4, TP_SYNC2 = 5, TP_DATA = 6, TP_STALL = 7;

reg         tap_in = 0;
reg   [2:0] t_ph = TP_L0;
reg         t_pause = 0;                   // in the pause after a block (t_ph is TP_L0)
reg         t_ended = 0;
reg         t_busy = 0;                    // a byte read is in flight
reg         t_rb_start = 0;
reg  [26:0] t_rb_idx = 0;
reg  [26:0] t_pos = 0;                     // start of the current block (its length bytes)
reg  [15:0] t_len = 0;                     // bytes in the block
reg  [15:0] t_rem = 0;                     // bytes still to send, the current one included
reg  [26:0] t_didx = 0;                    // file index of the next byte to fetch
reg   [7:0] t_cur = 0;                     // the byte being sent
reg   [2:0] t_bit = 0;
reg         t_half = 0;
reg   [7:0] t_nbyte = 0;                   // the byte after it, fetched ahead
reg         t_nvalid = 0;
reg  [12:0] t_pn = 0;                      // pilot pulses left
reg  [25:0] t_cnt = 0;

wire tap_active = (state == S_TAP);
assign tap_run = tap_active & ~t_ended & (manual_run | (auto_play & motor_on));
assign tape_in = tap_active ? tap_in : wav_in;

always @(posedge clk) begin
	t_rb_start <= 0;

	if (reset || btn_rewind || btn_eject || dl_start || !tap_active) begin
		t_ph     <= TP_L0;
		t_pause  <= 0;
		t_ended  <= 0;
		t_busy   <= 0;
		t_pos    <= 0;
		t_nvalid <= 0;
		tap_in   <= 0;
	end
	else begin
		if (t_busy && rb_done) t_busy <= 0;

		// ---- bytes from the file: the block header, then the data bytes one ahead of the pulse generator
		case (t_ph)
			TP_L0, TP_L1, TP_F: begin
				if (!t_pause) begin
					if (!t_busy) begin
						if (t_ph == TP_L0 && t_pos + 27'd2 > file_len) t_ended <= 1;
						else begin
							t_rb_idx   <= t_pos + {24'd0, t_ph};
							t_rb_start <= 1;
							t_busy     <= 1;
						end
					end
					else if (rb_done) begin
						case (t_ph)
							TP_L0: begin t_len[7:0]  <= rb_data; t_ph <= TP_L1; end
							TP_L1: begin t_len[15:8] <= rb_data; t_ph <= TP_F;  end
							default: begin
								if (t_len == 16'd0) begin
									t_pos <= t_pos + 27'd2;                 // an empty block: nothing to play
									t_ph  <= TP_L0;
								end
								else begin
									t_cur    <= rb_data;                      // the flag byte is the first byte sent
									t_rem    <= t_len;
									t_didx   <= t_pos + 27'd3;
									t_nvalid <= 0;
									t_pn     <= (rb_data < 8'd128) ? TAP_PILOT_HDR : TAP_PILOT_DATA;
									t_cnt    <= HP_PILOT - 1'd1;
									t_ph     <= TP_PILOT;
									tap_in   <= ~tap_in;                      // the edge that starts the first pilot pulse
								end
							end
						endcase
					end
				end
			end
			default: begin
				if (!t_nvalid && !t_busy && t_rem > 16'd1 && t_didx < t_pos + 27'd2 + {11'd0, t_len} && t_didx < file_len) begin
					t_rb_idx   <= t_didx;
					t_rb_start <= 1;
					t_busy     <= 1;
				end
				else if (t_busy && rb_done) begin
					t_nbyte  <= rb_data;
					t_nvalid <= 1;
					t_didx   <= t_didx + 1'd1;
				end
			end
		endcase

		// ---- pulse generator: one tick at the end of every pulse; it only runs while the tape is playing
		if (tap_run) begin
			if (t_pause) begin
				if (t_cnt != 0) t_cnt <= t_cnt - 1'd1;
				else begin
					t_pause <= 0;
					t_pos   <= t_pos + 27'd2 + {11'd0, t_len};
				end
			end
			else if (t_ph == TP_PILOT || t_ph == TP_SYNC1 || t_ph == TP_SYNC2 || t_ph == TP_DATA) begin
				if (t_cnt != 0) t_cnt <= t_cnt - 1'd1;
				else begin
					tap_in <= ~tap_in;
					case (t_ph)
						TP_PILOT: begin
							if (t_pn == 13'd1) begin t_cnt <= HP_SYNC1 - 1'd1; t_ph <= TP_SYNC1; end
							else begin t_pn <= t_pn - 1'd1; t_cnt <= HP_PILOT - 1'd1; end
						end
						TP_SYNC1: begin t_cnt <= HP_SYNC2 - 1'd1; t_ph <= TP_SYNC2; end
						TP_SYNC2: begin
							t_bit  <= 3'd7;
							t_half <= 0;
							t_cnt  <= (t_cur[7] ? HP_BIT1 : HP_BIT0) - 1'd1;
							t_ph   <= TP_DATA;
						end
						default: begin                                        // TP_DATA
							if (!t_half) begin
								t_half <= 1;
								t_cnt  <= (t_cur[t_bit] ? HP_BIT1 : HP_BIT0) - 1'd1;
							end
							else begin
								t_half <= 0;
								if (t_bit != 3'd0) begin
									t_bit <= t_bit - 1'd1;
									t_cnt <= (t_cur[t_bit - 3'd1] ? HP_BIT1 : HP_BIT0) - 1'd1;
								end
								else if (t_rem == 16'd1) begin                 // the block is done: pause
									t_pause <= 1;
									t_cnt   <= TAP_PAUSE - 1'd1;
									t_ph    <= TP_L0;
								end
								else begin
									t_rem <= t_rem - 1'd1;
									if (t_nvalid) begin
										t_cur    <= t_nbyte;
										t_nvalid <= 0;
										t_bit    <= 3'd7;
										t_cnt    <= (t_nbyte[7] ? HP_BIT1 : HP_BIT0) - 1'd1;
									end
									else t_ph <= TP_STALL;                      // the next byte has not arrived yet
								end
							end
						end
					endcase
				end
			end
			else if (t_ph == TP_STALL && !t_nvalid && !t_busy && t_didx >= file_len) begin
				t_ended <= 1;                                                  // a damaged file: the last block is short
			end
			else if (t_ph == TP_STALL && t_nvalid) begin
				t_cur    <= t_nbyte;
				t_nvalid <= 0;
				t_bit    <= 3'd7;
				t_half   <= 0;
				t_cnt    <= (t_nbyte[7] ? HP_BIT1 : HP_BIT0) - 1'd1;
				t_ph     <= TP_DATA;
			end
		end
	end
end

// the byte reader serves the parser until the file is ready, then the player or the stream
assign rb_start = p_rb_start | y_rb_start | m_rb_start | t_rb_start;
assign rb_idx   = (state == S_READY) ? y_rb_idx : (state == S_MTX) ? m_rb_idx : (state == S_TAP) ? t_rb_idx : p_rb_idx;

endmodule
