// tb_mtxstream.sv - a .mtx file through mtx_tape's byte stream, the way the Z80 side uses it:
// wait for ready, read the byte, toggle mtx_pop_t, repeat; a toggle of mtx_rewind_t restarts.
`timescale 1ns/1ps

module tb_mtxstream;

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

wire        mtx_loaded, mtx_ready, mtx_eof, tape_loaded, tape_error;
wire  [7:0] mtx_byte;
reg         pop_t = 0, rew_t = 0;
reg         nm_t = 0;
reg   [7:0] nm_d = 0;
wire        nodata;

mtx_tape dut
(
	.clk(clk), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_index(16'h0041), .ioctl_wait(ioctl_wait),    // F1, extension 1 = MTX
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.btn_play(1'b0), .btn_rewind(1'b0), .btn_eject(1'b0), .auto_play(1'b1),
	.cpu_motor(1'b0), .tape_in(), .tape_loaded(tape_loaded), .tape_playing(), .tape_error(tape_error),
	.mtx_loaded(mtx_loaded), .mtx_ready(mtx_ready), .mtx_eof(mtx_eof), .mtx_byte(mtx_byte),
	.mtx_pop_t(pop_t), .mtx_rewind_t(rew_t),
	.mtx_nm_t(nm_t), .mtx_nm_d(nm_d), .mtx_nodata(nodata)
);

reg [63:0] mem [0:(1<<20)-1];
reg [31:0] lfsr = 32'h1234ABCD;
always @(posedge clk) lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
assign DDRAM_BUSY = (lfsr[3:2] == 2'b00);

reg [28:0] rd_a;
reg  [4:0] rd_dly = 0;
integer k;
always @(posedge clk) begin
	DDRAM_DOUT_READY <= 0;
	if (DDRAM_WE && !DDRAM_BUSY)
		for (k = 0; k < 8; k = k + 1)
			if (DDRAM_BE[k]) mem[DDRAM_ADDR[19:0]][k*8 +: 8] <= DDRAM_DIN[k*8 +: 8];
	if (DDRAM_RD && !DDRAM_BUSY) begin rd_a <= DDRAM_ADDR; rd_dly <= 5'd5; end
	if (rd_dly != 0) begin
		rd_dly <= rd_dly - 1'd1;
		if (rd_dly == 1) begin DDRAM_DOUT <= mem[rd_a[19:0]]; DDRAM_DOUT_READY <= 1; end
	end
end

reg [7:0] file [0:(1<<16)-1];
integer nbytes = 0;
integer i, got, errors;
integer wait_n;

// take one byte the way the Z80 does: poll status, read, toggle pop (after the read cycle)
task take(output [7:0] b, output eof);
begin
	wait_n = 0;
	eof = 0;
	while (!mtx_ready && !mtx_eof && wait_n < 2000) begin repeat (7) @(posedge clk); wait_n = wait_n + 1; end
	if (mtx_ready) begin
		b = mtx_byte;
		repeat (4) @(posedge clk);
		pop_t = ~pop_t;
		repeat (12) @(posedge clk);       // the next poll is much later than the CDC latency
	end
	else begin b = 8'hxx; eof = mtx_eof; end
end
endtask

reg [7:0] b;
reg       e;

// the Z80 sends the 15 characters of the name asked for (OTIR to port 8D)
task send_name(input [8*15-1:0] name);
integer c;
begin
	for (c = 0; c < 15; c = c + 1) begin
		nm_d = name[(14 - c) * 8 +: 8];
		repeat (3) @(posedge clk);
		nm_t = ~nm_t;
		repeat (150) @(posedge clk);
	end
	repeat (60) @(posedge clk);
end
endtask

// rewind, take n bytes like the overlay does, then ask for a name; returns the verdict
task ask(input integer n, input [8*15-1:0] name, output reg verdict);
integer c;
begin
	rew_t = ~rew_t;
	repeat (60) @(posedge clk);
	for (c = 0; c < n; c = c + 1) take(b, e);
	send_name(name);
	verdict = nodata;
end
endtask

reg v;

initial begin
	$readmemh("mtx.hex", file);
	for (i = 0; i < (1<<16); i = i + 1) if (^file[i] !== 1'bx) nbytes = i + 1;
	$display("file bytes: %0d", nbytes);
	errors = 0;

	repeat (10) @(posedge clk);
	reset = 0;
	repeat (10) @(posedge clk);

	ioctl_download = 1;
	for (i = 0; i < nbytes; i = i + 1) begin
		@(posedge clk);
		while (ioctl_wait) @(posedge clk);
		ioctl_addr <= i; ioctl_dout <= file[i]; ioctl_wr <= 1;
		@(posedge clk);
		ioctl_wr <= 0;
		repeat (3) @(posedge clk);
	end
	@(posedge clk);
	ioctl_download = 0;

	wait (mtx_loaded);
	$display("mtx_loaded at %0t, tape_loaded=%0d error=%0d", $time, tape_loaded, tape_error);
	repeat (50) @(posedge clk);

	// 1) read the first 100 bytes
	for (i = 0; i < 100; i = i + 1) begin
		take(b, e);
		if (e || b !== file[i]) begin errors = errors + 1; $display("MISMATCH byte %0d: got %h want %h eof=%0d", i, b, file[i], e); end
	end
	// 2) rewind in the middle and read the header again
	rew_t = ~rew_t;
	repeat (40) @(posedge clk);
	for (i = 0; i < 40; i = i + 1) begin
		take(b, e);
		if (e || b !== file[i]) begin errors = errors + 1; $display("MISMATCH after rewind byte %0d: got %h want %h", i, b, file[i]); end
	end
	// 3) run to the end of the file
	got = 40;
	while (got < nbytes) begin
		take(b, e);
		if (e || b !== file[got]) begin errors = errors + 1; if (errors < 10) $display("MISMATCH byte %0d", got); end
		got = got + 1;
	end
	repeat (20) @(posedge clk);
	$display("read %0d bytes in total after rewind, file has %0d, eof=%0d", got, nbytes, mtx_eof);
	if (!mtx_eof) errors = errors + 1;
	// 4) past the end the stream stays ready and answers FF; eof stays set
	for (i = 0; i < 20; i = i + 1) begin
		take(b, e);
		if (e || b !== 8'hFF) begin errors = errors + 1; $display("PAST END byte %0d: got %h want ff eof=%0d", i, b, e); end
		if (!mtx_eof) begin errors = errors + 1; $display("eof dropped past the end"); end
	end
	// 5) a rewind starts the file again
	rew_t = ~rew_t;
	repeat (40) @(posedge clk);
	if (mtx_eof) begin errors = errors + 1; $display("eof still set after rewind"); end
	for (i = 0; i < 40; i = i + 1) begin
		take(b, e);
		if (e || b !== file[i]) begin errors = errors + 1; $display("MISMATCH after 2nd rewind byte %0d: got %h want %h", i, b, file[i]); end
	end
	// 5b) the end flag: clear when the next byte is FF (the start of a header), set otherwise
	rew_t = ~rew_t; repeat (60) @(posedge clk);
	if (mtx_eof) begin errors = errors + 1; $display("end flag set at the start of the tape (next byte is FF)"); end
	for (i = 0; i < 100; i = i + 1) take(b, e);
	repeat (60) @(posedge clk);
	if (file[100] !== 8'hFF && !mtx_eof) begin errors = errors + 1; $display("end flag clear though the next byte is %h", file[100]); end

	// 6) LOAD "NAME": the tape is TOADO
	ask(18, "TOADO          ", v); if (v) begin errors = errors + 1; $display("TOADO refused"); end
	ask(18, "toado          ", v); if (v) begin errors = errors + 1; $display("toado (lower case) refused"); end
	ask(18, "               ", v); if (v) begin errors = errors + 1; $display("blank name refused"); end
	ask(18, 120'h0, v);            if (v) begin errors = errors + 1; $display("empty name (zeros) refused"); end
	ask(18, "OTHER          ", v); if (!v) begin errors = errors + 1; $display("OTHER accepted"); end
	ask(18, "TOAD           ", v); if (!v) begin errors = errors + 1; $display("TOAD (a prefix) accepted"); end
	ask(18, "TOADOX         ", v); if (!v) begin errors = errors + 1; $display("TOADOX accepted"); end
	ask(18, {"TOADO", 8'h00, "junkjunkj"}, v); if (v) begin errors = errors + 1; $display("TOADO + zero + junk refused"); end
	// after a mismatch the tape has started again: the next byte is the first one
	ask(18, "OTHER          ", v);
	repeat (60) @(posedge clk);
	take(b, e);
	if (b !== file[0]) begin errors = errors + 1; $display("tape not rewound after a mismatch: %h", b); end
	// the verdict clears with the next name
	ask(18, "TOADO          ", v); if (v) begin errors = errors + 1; $display("verdict not cleared"); end
	// not a header chunk (30 bytes taken since the start): nothing is checked
	ask(30, "OTHER          ", v); if (v) begin errors = errors + 1; $display("a data chunk was checked"); end

	if (errors == 0) $display("MTX STREAM TEST PASSED"); else $display("MTX STREAM TEST FAILED, %0d errors", errors);
	$finish;
end

endmodule
