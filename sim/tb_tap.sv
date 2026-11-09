// tb_tap.sv - a .tap file through mtx_tape (extension index 2 of F1), logging the tape_in edges.
// Input:  tap.hex   one byte per line (a .tap file)
// Output: tap_edges.txt   one line per tape_in edge: time in ns
// PH, PD and PP shorten the pilot pulse counts and the pause so that a test does not need minutes of simulated time;
// the pulse lengths themselves are always the real ones.
`timescale 1ns/1ps

module tb_tap;

parameter RUN_US = 300000;
parameter PH = 8063;
parameter PD = 3223;
parameter PP = 50000000;
parameter STOP_AFTER_EDGES = 0;           // 0: run for RUN_US

reg clk = 0;
always #10 clk = ~clk;                    // 50MHz

reg         reset = 1;
reg         ioctl_download = 0;
reg         ioctl_wr = 0;
reg  [26:0] ioctl_addr = 0;
reg   [7:0] ioctl_dout = 0;
wire        ioctl_wait;

wire        DDRAM_BUSY;
wire  [7:0] DDRAM_BURSTCNT;
wire [28:0] DDRAM_ADDR;
reg  [63:0] DDRAM_DOUT = 0;
reg         DDRAM_DOUT_READY = 0;
wire        DDRAM_RD;
wire [63:0] DDRAM_DIN;
wire  [7:0] DDRAM_BE;
wire        DDRAM_WE;

reg  btn_play = 0, btn_rewind = 0, btn_eject = 0;
reg  auto_play = 1;
reg  cpu_motor = 0;
wire tape_in, tape_loaded, tape_playing, tape_error;

mtx_tape #(.TAP_PILOT_HDR(PH), .TAP_PILOT_DATA(PD), .TAP_PAUSE(PP)) dut
(
	.clk(clk), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_index(16'h0081), .ioctl_wait(ioctl_wait),     // F1, extension 2 = TAP
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.btn_play(btn_play), .btn_rewind(btn_rewind), .btn_eject(btn_eject), .auto_play(auto_play),
	.cpu_motor(cpu_motor), .tape_in(tape_in), .tape_loaded(tape_loaded),
	.tape_playing(tape_playing), .tape_error(tape_error),
	.mtx_loaded(), .mtx_ready(), .mtx_eof(), .mtx_byte(),
	.mtx_pop_t(1'b0), .mtx_rewind_t(1'b0), .mtx_nm_t(1'b0), .mtx_nm_d(8'd0), .mtx_nodata()
);

// ---- DDR3 model: 64 bit words, random busy, read data 5 clocks after acceptance
reg [63:0] mem [0:(1<<20)-1];
reg [31:0] lfsr = 32'h1234ABCD;
always @(posedge clk) lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
assign DDRAM_BUSY = (lfsr[3:2] == 2'b00);          // busy about a quarter of the time

reg [28:0] rd_a;
reg  [4:0] rd_dly = 0;
integer k;
always @(posedge clk) begin
	DDRAM_DOUT_READY <= 0;
	if (DDRAM_WE && !DDRAM_BUSY) begin
		for (k = 0; k < 8; k = k + 1)
			if (DDRAM_BE[k]) mem[DDRAM_ADDR[19:0]][k*8 +: 8] <= DDRAM_DIN[k*8 +: 8];
	end
	if (DDRAM_RD && !DDRAM_BUSY) begin
		rd_a   <= DDRAM_ADDR;
		rd_dly <= 5'd5;
	end
	if (rd_dly != 0) begin
		rd_dly <= rd_dly - 1'd1;
		if (rd_dly == 1) begin
			DDRAM_DOUT       <= mem[rd_a[19:0]];
			DDRAM_DOUT_READY <= 1;
		end
	end
end

// ---- edge log
integer fe;
reg tape_d = 0;
integer nedges = 0;
always @(posedge clk) begin
	tape_d <= tape_in;
	if (tape_in != tape_d) begin
		$fwrite(fe, "%0d\n", $time);
		nedges = nedges + 1;
		if (STOP_AFTER_EDGES != 0 && nedges >= STOP_AFTER_EDGES) begin
			$display("stopped after %0d edges at %0t", nedges, $time);
			$fclose(fe);
			$finish;
		end
	end
end

// ---- the file
reg [7:0] file [0:(1<<20)-1];
integer nbytes = 0;
integer i;

initial begin
	fe = $fopen("tap_edges.txt", "w");
	$readmemh("tap.hex", file);
	for (i = 0; i < (1<<20); i = i + 1) if (^file[i] !== 1'bx) nbytes = i + 1;
	$display("file bytes: %0d  parameters: PH=%0d PD=%0d PP=%0d  (defaults in the DUT: %0d %0d %0d)",
	         nbytes, PH, PD, PP, 8063, 3223, 50000000);

	repeat (10) @(posedge clk);
	reset = 0;
	repeat (10) @(posedge clk);

	ioctl_download = 1;
	for (i = 0; i < nbytes; i = i + 1) begin
		@(posedge clk);
		while (ioctl_wait) @(posedge clk);
		ioctl_addr <= i;
		ioctl_dout <= file[i];
		ioctl_wr   <= 1;
		@(posedge clk);
		ioctl_wr   <= 0;
		repeat (3) @(posedge clk);
	end
	@(posedge clk);
	ioctl_download = 0;

	wait (tape_loaded || tape_error);
	$display("loaded=%0d error=%0d at %0t", tape_loaded, tape_error, $time);
	repeat (20) @(posedge clk);
	$display("start at %0t (motor on, auto play)", $time);
	cpu_motor = 1;
	repeat (RUN_US) #1000;                  // not #(RUN_US*1000): that overflows 32 bits above 2.1 s
	$display("playing=%0d edges=%0d at %0t", tape_playing, nedges, $time);
	$fclose(fe);
	$finish;
end

endmodule
