//
// mtx_xsdram.sv - the expansion RAM of the MTX512 (256KB, see memory_map.vhd) kept in the MiSTer's SDRAM
//
// The Z80 side is the memory bus of mtx.vhd: se says the address is in the expansion RAM, mreq/rd/wr are MREQ_n,
// RD_n and WR_n turned active high. wait_n goes to the Z80's WAIT_n. All of it runs on the 50MHz clock, as the
// SDRAM controller (sdram.sv) does.
//
// Timing. The controller takes about 8 clocks for a read and about 5 for a write. A Z80 memory cycle at the stock
// 4MHz is 12 clocks and the address is valid from the start of the cycle, one whole cycle before MREQ_n goes low. So:
//   - as soon as the address is in the expansion RAM and the word is not already held, a read is started (a read
//     does no harm, even when the cycle turns out to be a write), and the data is there before the Z80 asks for it
//   - a write is started when WR_n and MREQ_n are low
//   - the Z80 is held with wait_n only when the data (or the write) is not finished at the point the Z80 would
//     take it. At the stock speed that is rare (a refresh in the way); at the turbo speeds it is every access.
// wait_n is released one clock after the data is stable, so a Z80 clock edge at that moment sees either "wait" or
// "data and no wait", never the new wait with the old data.
//

module mtx_xsdram
(
	input             clk,         // 50MHz
	input             init,        // 1 for a few clocks after power up

	// SDRAM chip
	inout      [15:0] SDRAM_DQ,
	output     [12:0] SDRAM_A,
	output            SDRAM_DQML,
	output            SDRAM_DQMH,
	output      [1:0] SDRAM_BA,
	output            SDRAM_nCS,
	output            SDRAM_nWE,
	output            SDRAM_nRAS,
	output            SDRAM_nCAS,
	output            SDRAM_CKE,
	output            SDRAM_CLK,

	// the Z80 memory bus
	input      [17:0] addr,        // block (4 bits) and offset in the block (14 bits)
	input       [7:0] din,         // data from the Z80
	input             se,          // the address is in the expansion RAM
	input             mreq,        // MREQ_n = 0
	input             rd,          // RD_n = 0
	input             wr,          // WR_n = 0
	output      [7:0] dout,        // data to the Z80
	output            wait_n
);

wire        ready;
wire  [7:0] sd_dout;
reg  [17:0] aq;                    // address and data of the access in progress (stable while the controller uses them)
reg   [7:0] dq;
reg         rdp = 0, wep = 0;      // one clock pulses to the controller
reg   [2:0] iss = 0;               // 0 idle, 1 and 2: the controller is taking the request, 3: wait for ready
reg         is_wr = 0;
reg         have = 0;              // sd_dout holds the byte at aq
reg         wdone = 0;             // the write of this cycle has finished

sdram sdram
(
	.init(init),
	.clk(clk),

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

	.addr({7'd0, aq}),
	.dout(sd_dout),
	.din(dq),
	.we(wep),
	.rd(rdp),
	.ready(ready)
);

wire cur_wr = se & mreq & wr;                  // a write cycle to the expansion RAM
wire hit    = have & (aq == addr);             // the byte the Z80 is addressing is held

assign dout   = sd_dout;
assign wait_n = ~(se & mreq & (wr ? ~wdone : (rd & ~hit)));

always @(posedge clk) begin
	rdp <= 0;
	wep <= 0;

	if (!cur_wr) wdone <= 0;

	case (iss)
		0: if (ready & se) begin
			if (cur_wr) begin
				if (!wdone) begin
					wep <= 1; is_wr <= 1; aq <= addr; dq <= din; have <= 0; iss <= 1;
				end
			end else if (!hit) begin
				rdp <= 1; is_wr <= 0; aq <= addr; have <= 0; iss <= 1;
			end
		end
		1: iss <= 2;
		2: iss <= 3;
		3: if (ready) begin
			iss <= 0;
			if (is_wr) wdone <= 1; else have <= 1;
		end
	endcase

	if (init) begin
		iss <= 0; have <= 0; wdone <= 0;
	end
end

endmodule
