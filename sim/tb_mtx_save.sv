`timescale 1ns/1ps
// tb_mtx_save - mtx_save against a model of the HPS side of the SD block protocol.
module tb_mtx_save;

reg clk = 0;
always #10 clk = ~clk;                          // 50MHz

reg        reset = 1;
reg        wr_t = 0, start_t = 0, flush_t = 0;
reg  [7:0] wr_d = 0;
wire       busy;
reg        img_mounted = 0, img_readonly = 0;
reg [63:0] img_size = 0;
wire [31:0] sd_lba;
wire        sd_wr;
reg         sd_ack = 0;
reg   [8:0] sd_buff_addr = 0;
wire  [7:0] sd_buff_din;
wire        mounted;

mtx_save #(.TIMEOUT(32'd400000)) dut
(
	.clk(clk), .reset(reset),
	.wr_t(wr_t), .wr_d(wr_d), .start_t(start_t), .flush_t(flush_t), .busy(busy),
	.img_mounted(img_mounted), .img_readonly(img_readonly), .img_size(img_size),
	.sd_lba(sd_lba), .sd_wr(sd_wr), .sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_din(sd_buff_din),
	.mounted(mounted)
);

// ---- the HPS: a 64 KB image file; a block write is acknowledged, then read out byte by byte
reg [7:0] img [0:65535];
integer   writes = 0;
integer   k, lba_l;
initial forever begin
	@(posedge sd_wr);
	repeat (20) @(posedge clk);                 // latency of the HPS
	lba_l = sd_lba;
	sd_buff_addr = 0;
	sd_ack = 1;
	repeat (2) @(posedge clk);
	for (k = 0; k < 512; k = k + 1) begin
		repeat (4) @(posedge clk);              // SPI pace
		if (lba_l * 512 + k < 65536) img[lba_l * 512 + k] = sd_buff_din;
		sd_buff_addr = sd_buff_addr + 1'd1;
	end
	repeat (6) @(posedge clk);
	sd_ack = 0;
	writes = writes + 1;
end

// ---- the Z80 side
task zbyte(input [7:0] b);
begin
	repeat (100) @(posedge clk);
	while (busy) @(posedge clk);                // the overlay polls bit 2 of port 8F
	wr_d = b;
	repeat (3) @(posedge clk);
	wr_t = ~wr_t;
end
endtask

task zstart;
begin
	repeat (100) @(posedge clk);
	start_t = ~start_t;
	repeat (100) @(posedge clk);
	while (busy) @(posedge clk);
end
endtask

task zflush;
begin
	repeat (100) @(posedge clk);
	flush_t = ~flush_t;
	repeat (100) @(posedge clk);
	while (busy) @(posedge clk);
end
endtask

function [7:0] pat(input integer seed, input integer i);
	pat = (i * 7 + seed * 13 + (i >> 8)) & 8'hFF;
endfunction

integer errors = 0;
integer i, n, base;

task check_bytes(input integer seed, input integer from, input integer len, input integer fileoff);
integer j;
begin
	for (j = 0; j < len; j = j + 1)
		if (img[fileoff + j] !== pat(seed, from + j)) begin
			errors = errors + 1;
			if (errors < 10) $display("MISMATCH image[%0d]=%h want %h", fileoff + j, img[fileoff + j], pat(seed, from + j));
		end
end
endtask

task check_ff(input integer from, input integer to);
integer j;
begin
	for (j = from; j <= to; j = j + 1)
		if (img[j] !== 8'h00) begin
			errors = errors + 1;
			if (errors < 10) $display("NOT 00 image[%0d]=%h", j, img[j]);
		end
end
endtask

task save_chunk(input integer seed, input integer len, input integer fileoff);
integer j;
begin
	for (j = 0; j < len; j = j + 1) zbyte(pat(seed, j));
	zflush;
end
endtask

initial begin
	for (i = 0; i < 65536; i = i + 1) img[i] = 8'h00;
	repeat (20) @(posedge clk); reset = 0;
	repeat (60) @(posedge clk);

	// ---- 1) a tape in several chunks onto a 64 KB image that holds old data (00)
	img_size = 65536; img_readonly = 0; img_mounted = 1; @(posedge clk); img_mounted = 0;
	repeat (10) @(posedge clk);
	zstart;
	$display("after start: %0d block writes (erase)", writes);
	save_chunk(1, 18, 0);
	save_chunk(2, 601, 18);
	save_chunk(3, 1300, 619);
	save_chunk(4, 1, 1919);
	check_bytes(1, 0, 18, 0);
	check_bytes(2, 0, 601, 18);
	check_bytes(3, 0, 1300, 619);
	check_bytes(4, 0, 1, 1919);
	check_ff(1920, 65535);
	$display("tape 1 written: %0d block writes in total", writes);

	// ---- 2) a shorter tape: nothing of the first one may be left behind
	zstart;
	save_chunk(5, 100, 0);
	check_bytes(5, 0, 100, 0);
	check_ff(100, 65535);

	// ---- 3) an exact multiple of 512 bytes
	zstart;
	save_chunk(6, 1024, 0);
	check_bytes(6, 0, 1024, 0);
	check_ff(1024, 65535);

	// ---- 4) not mounted: nothing happens, the Z80 is never held up
	img_size = 0; img_mounted = 1; @(posedge clk); img_mounted = 0;
	repeat (10) @(posedge clk);
	n = writes;
	zstart;
	for (i = 0; i < 700; i = i + 1) zbyte(8'hA5);
	zflush;
	if (writes != n) begin errors = errors + 1; $display("block written with no image mounted"); end
	if (busy) begin errors = errors + 1; $display("busy with no image mounted"); end
	check_bytes(6, 0, 1024, 0);                  // the image still holds tape 3

	// ---- 5) read only image: same
	img_size = 65536; img_readonly = 1; img_mounted = 1; @(posedge clk); img_mounted = 0;
	repeat (10) @(posedge clk);
	n = writes;
	zstart;
	for (i = 0; i < 700; i = i + 1) zbyte(8'hA5);
	zflush;
	if (writes != n) begin errors = errors + 1; $display("block written to a read only image"); end

	// ---- 6) images that are not exactly 64 KB are refused (they may be game tapes): nothing is written, no hang
	for (i = 0; i < 65536; i = i + 1) img[i] = 8'h5A;
	img_size = 2048; img_readonly = 0; img_mounted = 1; @(posedge clk); img_mounted = 0;
	repeat (10) @(posedge clk);
	n = writes;
	zstart;
	for (i = 0; i < 3000; i = i + 1) zbyte(pat(7, i));
	zflush;
	if (writes != n) begin errors = errors + 1; $display("wrote to a 2 KB image"); end
	img_size = 65536 + 512; img_mounted = 1; @(posedge clk); img_mounted = 0;
	repeat (10) @(posedge clk);
	zstart;
	for (i = 0; i < 700; i = i + 1) zbyte(8'hA5);
	zflush;
	if (writes != n) begin errors = errors + 1; $display("wrote to an image of the wrong size"); end
	for (i = 0; i < 65536; i = i + 1)
		if (img[i] !== 8'h5A) begin errors = errors + 1; if (errors < 10) $display("image touched at %0d", i); i = 65536; end

	if (errors == 0) $display("MTX SAVE TEST PASSED, %0d block writes", writes);
	else $display("MTX SAVE TEST FAILED, %0d errors", errors);
	$finish;
end

initial begin
	#2000000000;
	$display("TIMEOUT");
	$finish;
end

endmodule
