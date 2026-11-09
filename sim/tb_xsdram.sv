// tb_xsdram.sv - the expansion RAM wrapper (rtl/mtx_xsdram.sv) and the SDRAM controller (rtl/sdram.sv) against a model
// of the SDRAM chip (sdram_model.sv), driven like the Z80 of the core: the memory cycles of T80se (T1, T2 with
// the WAIT_n check at its end, T3), a T state being 12 and 13 clocks of 50MHz alternately for the stock 4MHz, or a
// fixed number of clocks for the turbo speeds.
//
//   vsim ... +TCLK=0 (stock 12/13) | +TCLK=n (fixed n clocks per T state) +CYCLES=n
//
// The expansion RAM is accessed in the ways programs do: random bytes, runs up and down, a byte and its neighbour in the
// same 16 bit word, and a read straight after a write. Every byte read is compared with what was written; the first
// access is made at power up, when the controller is still being set up (the Z80 has to wait). The chip model reports
// timing and start-up errors and the longest gap between refreshes.
`timescale 1ns/1ps

module tb_xsdram;

reg clk = 0;
always #10 clk = ~clk;

integer TCLK, CYCLES;
reg [17:0] addr = 0;
reg  [7:0] din = 0;
reg        se = 0, mreq = 0, rd = 0, wr = 0;
wire [7:0] dout;
wire       wait_n;

wire [15:0] DQ;
wire [12:0] A;
wire        DQML, DQMH, nCS, nWE, nRAS, nCAS, CKE, SCLK;
wire  [1:0] BA;

reg [3:0] init_cnt = 0;
always @(posedge clk) if (!(&init_cnt)) init_cnt <= init_cnt + 1;

mtx_xsdram dut
(
	.clk(clk), .init(~(&init_cnt)),
	.SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_DQML(DQML), .SDRAM_DQMH(DQMH), .SDRAM_BA(BA),
	.SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS), .SDRAM_nCAS(nCAS), .SDRAM_CKE(CKE), .SDRAM_CLK(SCLK),
	.addr(addr), .din(din), .se(se), .mreq(mreq), .rd(rd), .wr(wr), .dout(dout), .wait_n(wait_n)
);

sdram_model chip
(
	.clk(SCLK), .cke(CKE), .cs_n(nCS), .ras_n(nRAS), .cas_n(nCAS), .we_n(nWE),
	.ba(BA), .a(A), .dqml(DQML), .dqmh(DQMH), .dq(DQ)
);

reg  [7:0] expd [0:262143];
reg        known [0:262143];
integer    mism = 0, xcycles = 0, waits = 0, ocycles = 0, owaits = 0;
integer    k, startup_waits = 0;
reg        odd = 0;

initial for (k = 0; k < 262144; k = k + 1) known[k] = 0;

task tstate;
	integer n;
begin
	if (TCLK == 0) begin n = odd ? 13 : 12; odd = ~odd; end else n = TCLK;
	repeat (n) @(posedge clk);
end
endtask

// one memory cycle: address (and data) valid from the start of T1, MREQ and RD or WR from the start of T2,
// WAIT_n looked at the end of each T2, the data taken then
task cycle(input [17:0] a, input w, input [7:0] d, input is_x);
	reg [7:0] got;
	integer   nw;
begin
	addr <= a; din <= d; se <= is_x;
	tstate;
	mreq <= 1; rd <= ~w; wr <= w;
	nw = 0;
	begin : t2
		forever begin
			tstate;
			if (wait_n) begin
				got = dout;
				mreq <= 0; rd <= 0; wr <= 0;
				disable t2;
			end
			nw = nw + 1;
		end
	end
	tstate;
	if (is_x) begin
		xcycles = xcycles + 1; waits = waits + nw;
		if (w) begin expd[a] = d; known[a] = 1; end
		else if (known[a] && got !== expd[a]) begin
			mism = mism + 1;
			if (mism < 20) $display("MISMATCH read %05x: got %02x expected %02x (%0t)", a, got, expd[a], $time);
		end else if (!known[a]) ;
	end else begin
		ocycles = ocycles + 1; owaits = owaits + nw;
	end
end
endtask

integer seed;
function integer rnd(input integer n);
begin
	rnd = $unsigned($random(seed)) % n;
end
endfunction

integer it, j, len, base, kind;
reg [17:0] a0;
reg  [7:0] dd;

initial begin
	if (!$value$plusargs("TCLK=%d", TCLK)) TCLK = 0;
	if (!$value$plusargs("CYCLES=%d", CYCLES)) CYCLES = 3000;
	seed = 12345;
	// the very first accesses, while the controller starts up
	cycle(18'h01234, 1, 8'hA5, 1);
	cycle(18'h01234, 0, 8'h00, 1);
	cycle(18'h01235, 1, 8'h5A, 1);
	cycle(18'h01234, 0, 8'h00, 1);
	cycle(18'h01235, 0, 8'h00, 1);
	startup_waits = waits; waits = 0; xcycles = 0;      // what follows is after the start-up
	for (it = 0; it < CYCLES; it = it + 1) begin
		kind = rnd(8);
		a0 = rnd(262144);
		case (kind)
		0: begin   // write run up, then read it back, other memory cycles between like instruction fetches
			len = 4 + rnd(40);
			for (j = 0; j < len; j = j + 1) begin cycle(18'h3FFFF & (a0 + j), 1, rnd(256), 1); cycle(rnd(65536), 0, 0, 0); end
			for (j = 0; j < len; j = j + 1) cycle(18'h3FFFF & (a0 + j), 0, 0, 1);
		end
		1: begin   // a block copy: read a byte, write it elsewhere, down
			len = 4 + rnd(30);
			for (j = 0; j < len; j = j + 1) cycle(18'h3FFFF & (a0 - j), 1, rnd(256), 1);
			for (j = 0; j < len; j = j + 1) begin
				cycle(18'h3FFFF & (a0 - j), 0, 0, 1);
				cycle(18'h3FFFF & (a0 + 18'h1000 - j), 1, rnd(256), 1);
			end
		end
		2: begin   // a byte and its neighbour in the same word, written and read both ways round
			cycle(a0, 1, rnd(256), 1);
			cycle(a0 ^ 18'd1, 1, rnd(256), 1);
			cycle(a0, 0, 0, 1);
			cycle(a0 ^ 18'd1, 0, 0, 1);
			cycle(a0, 0, 0, 1);
		end
		3: begin   // read straight after write, same byte, and write straight after read
			dd = rnd(256);
			cycle(a0, 1, dd, 1);
			cycle(a0, 0, 0, 1);
			cycle(a0, 1, ~dd, 1);
			cycle(a0, 0, 0, 1);
			cycle(a0 + 1, 0, 0, 1);
			cycle(a0 + 1, 1, dd, 1);
		end
		4: begin   // random single accesses
			for (j = 0; j < 10; j = j + 1) cycle(rnd(262144), rnd(2), rnd(256), 1);
		end
		5: begin   // memory outside the expansion RAM, with idle T states
			for (j = 0; j < 6; j = j + 1) begin cycle(rnd(65536), rnd(2), rnd(256), 0); if (rnd(3) == 0) tstate; end
		end
		6: begin   // all reads: instruction fetches from the expansion RAM, with an idle T state of refresh each
			len = 8 + rnd(40);
			for (j = 0; j < len; j = j + 1) begin cycle(18'h3FFFF & (a0 + j), 0, 0, 1); tstate; end
		end
		7: begin   // a small area hammered, so that reads and writes meet the same word often
			for (j = 0; j < 12; j = j + 1) cycle((a0 & 18'h3FFF0) + rnd(4), rnd(2), rnd(256), 1);
		end
		endcase
	end
	repeat (2000) @(posedge clk);
	$display("RESULT start-up: Z80 waited %0d T states; after it: %0d expansion RAM cycles with %0d wait states (%0.2f per cycle), other cycles %0d with %0d wait states", startup_waits, xcycles, waits, 1.0 * waits / xcycles, ocycles, owaits);
	$display("RESULT mismatches %0d, chip errors %0d, reads %0d writes %0d refreshes %0d, longest refresh gap %0.1f ns",
		mism, chip.errors, chip.reads, chip.writes, chip.refreshes, chip.max_gap);
	if (mism == 0 && chip.errors == 0 && owaits == 0 && chip.refreshes > 10 && chip.max_gap < 7800.0) $display("PASS");
	else $display("FAIL");
	$finish;
end

endmodule
