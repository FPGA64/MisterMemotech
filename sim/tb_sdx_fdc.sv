`timescale 1ns/1ps
// tb_sdx_fdc - the SDX floppy controller against a model of the HPS block interface, driven the way the SDX ROM
// driver drives the chip (poll DRQ on port 14h, then the data register).
module tb_sdx_fdc;

reg clk = 0, clk_sys = 0;
always #120 clk = ~clk;                 // 4.166MHz
always #10 clk_sys = ~clk_sys;          // 50MHz
reg reset = 1;

reg        cs = 0, wr = 0, rd = 0;
reg  [2:0] a = 0;
reg  [7:0] din = 0;
wire [7:0] dout;

reg  [1:0] d_mnt = 2'b01, d_ro = 2'b00, d_t40 = 2'b00, d_ss = 2'b00;
reg [22:0] d_blks0 = 23'd1280, d_blks1 = 23'd1280;     // 655360 bytes

wire        sd_rd_o, sd_wr_o, sd_drv;
wire [31:0] sd_lba;
reg         sd_ack = 0;
reg   [8:0] sd_buff_addr = 0;
reg   [7:0] sd_buff_dout = 0;
reg         sd_buff_wr = 0;
wire  [7:0] sd_buff_din;

sdx_fdc dut
(
	.clk(clk), .clk_sys(clk_sys), .reset(reset),
	.cs(cs), .a(a), .wr(wr), .rd(rd), .din(din), .dout(dout),
	.d_mnt(d_mnt), .d_ro(d_ro), .d_t40(d_t40), .d_ss(d_ss), .d_blks0(d_blks0), .d_blks1(d_blks1),
	.sd_rd_o(sd_rd_o), .sd_wr_o(sd_wr_o), .sd_drv(sd_drv), .sd_lba(sd_lba), .sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr), .sd_buff_din(sd_buff_din)
);

// ---- the two disc images and the HPS
reg [7:0] img0 [0:655359];
reg [7:0] img1 [0:655359];
reg [7:0] ref0 [0:655359];
integer   blk_reads = 0, blk_writes = 0;
integer   hk, hlba;
reg       hdrv;
initial forever begin
	@(posedge clk_sys);
	if (sd_rd_o) begin                          // HPS -> core
		repeat (20) @(posedge clk_sys);
		hlba = sd_lba; hdrv = sd_drv;
		sd_ack = 1;
		for (hk = 0; hk < 512; hk = hk + 1) begin
			@(posedge clk_sys);
			sd_buff_addr = hk; sd_buff_dout = hdrv ? img1[hlba * 512 + hk] : img0[hlba * 512 + hk]; sd_buff_wr = 1;
			@(posedge clk_sys); sd_buff_wr = 0;
		end
		repeat (3) @(posedge clk_sys);
		sd_ack = 0; blk_reads = blk_reads + 1;
		repeat (3) @(posedge clk_sys);
	end
	else if (sd_wr_o) begin                     // core -> HPS
		repeat (20) @(posedge clk_sys);
		hlba = sd_lba; hdrv = sd_drv;
		sd_ack = 1;
		for (hk = 0; hk < 512; hk = hk + 1) begin
			sd_buff_addr = hk;
			repeat (3) @(posedge clk_sys);
			if (hdrv) img1[hlba * 512 + hk] = sd_buff_din; else img0[hlba * 512 + hk] = sd_buff_din;
		end
		repeat (3) @(posedge clk_sys);
		sd_ack = 0; blk_writes = blk_writes + 1;
		repeat (3) @(posedge clk_sys);
	end
end

// ---- the Z80 side
task iowr(input [2:0] port, input [7:0] v);
begin
	@(posedge clk); cs <= 1; a <= port; din <= v; wr <= 1;
	@(posedge clk); @(posedge clk); wr <= 0; cs <= 0;
	@(posedge clk); @(posedge clk);
end
endtask

task iord(input [2:0] port, output [7:0] v);
begin
	@(posedge clk); cs <= 1; a <= port; rd <= 1;
	@(posedge clk); @(posedge clk);
	v = dout;
	@(posedge clk); rd <= 0; cs <= 0;
	@(posedge clk); @(posedge clk);
end
endtask

integer errors = 0;
task check(input cond, input [255:0] what);
begin
	if (!cond) begin errors = errors + 1; $display("FAIL: %0s (t=%0t)", what, $time); end
end
endtask

reg [7:0] v;
integer n, i, j;

// wait until DRQ (port 14h bit 7) is up; false on a timeout
reg ok;
task wait_drq;
begin
	ok = 0;
	for (n = 0; n < 40000 && !ok; n = n + 1) begin iord(3'd4, v); if (v[7]) ok = 1; end
end
endtask

// wait until the command is over (status bit 0 low)
task wait_idle;
begin
	ok = 0;
	for (n = 0; n < 40000 && !ok; n = n + 1) begin iord(3'd0, v); if (!v[0]) ok = 1; end
end
endtask

// offset of a sector in the image (256 byte sectors, 2 sides)
function integer secoff(input integer t, input integer sd, input integer s);
	secoff = ((2 * t + sd) * 16 + s - 1) * 256;
endfunction

task command(input [7:0] c);
begin
	iowr(3'd0, c);
end
endtask

reg [7:0] st;
reg [7:0] ctlv;

initial begin
	for (i = 0; i < 655360; i = i + 1) begin
		img0[i] = (i * 7 + (i >> 8) * 13) & 8'hFF;
		img1[i] = (i * 5 + (i >> 9) * 3 + 1) & 8'hFF;
		ref0[i] = img0[i];
	end
	repeat (10) @(posedge clk); reset = 0; repeat (10) @(posedge clk);

	// ---- port 14h: READY needs the motor bits and the disc
	iord(3'd4, v); check(v == 8'h10, "idle port 14h: jumper only");
	ctlv = 8'h1C; iowr(3'd4, ctlv);
	iord(3'd4, v); check(v == 8'h30, "port 14h with motor on and ready: READY and the jumper");

	// ---- restore
	command(8'h08);
	iord(3'd4, v); check(v[6], "INTRQ after restore");
	iord(3'd0, v); check(v == 8'h24, "restore status: head loaded, track 00");
	iord(3'd4, v); check(!v[6], "reading the status register reset INTRQ");
	iord(3'd1, v); check(v == 8'd0, "track register 0");

	// ---- seek to track 5
	iowr(3'd3, 8'd5); command(8'h18);
	iord(3'd0, v); check(v == 8'h20, "seek status: head loaded, not track 00");
	iord(3'd1, v); check(v == 8'd5, "track register 5 after the seek");

	// ---- read sector 3, side 0
	iowr(3'd2, 8'd3); command(8'h80);
	wait_drq; check(ok, "DRQ for the read");
	iord(3'd0, v); check(v == 8'h03, "status during the read: DRQ and busy");
	for (i = 0; i < 256; i = i + 1) begin
		iord(3'd3, v);
		if (v !== ref0[secoff(5, 0, 3) + i]) begin errors = errors + 1; if (errors < 10) $display("FAIL: sector 3 byte %0d: %h want %h", i, v, ref0[secoff(5,0,3)+i]); end
	end
	wait_idle; check(ok, "read ended");
	iord(3'd0, v); check(v == 8'h00, "status after the read");

	// ---- the sector next to it in the same block (no new fetch)
	n = blk_reads;
	iowr(3'd2, 8'd4); command(8'h80); wait_drq;
	for (i = 0; i < 256; i = i + 1) begin
		iord(3'd3, v);
		if (v !== ref0[secoff(5, 0, 4) + i]) begin errors = errors + 1; if (errors < 10) $display("FAIL: sector 4 byte %0d", i); end
	end
	wait_idle;

	// ---- several sectors: 15, 16 then 17 does not exist
	iowr(3'd2, 8'd15); command(8'h90);
	for (j = 15; j <= 16; j = j + 1) begin
		wait_drq; check(ok, "DRQ for a sector of the multiple read");
		for (i = 0; i < 256; i = i + 1) begin
			iord(3'd3, v);
			if (v !== ref0[secoff(5, 0, j) + i]) begin errors = errors + 1; if (errors < 10) $display("FAIL: multi read sector %0d byte %0d", j, i); end
		end
	end
	// the command ends with INTRQ (port 14h bit 6); the status register then says record not found
	ok = 0; for (n = 0; n < 40000 && !ok; n = n + 1) begin iord(3'd4, v); if (v[6]) ok = 1; end
	check(ok, "INTRQ after the multiple read");
	iord(3'd0, v); check(v == 8'h10, "record not found after the last sector");

	// ---- side 1
	ctlv = 8'h1E; iowr(3'd4, ctlv);
	iowr(3'd2, 8'd9); command(8'h80); wait_drq;
	for (i = 0; i < 256; i = i + 1) begin
		iord(3'd3, v);
		if (v !== ref0[secoff(5, 1, 9) + i]) begin errors = errors + 1; if (errors < 10) $display("FAIL: side 1 sector 9 byte %0d", i); end
	end
	wait_idle;
	ctlv = 8'h1C; iowr(3'd4, ctlv);

	// ---- write sector 4 (the other half of its block must survive: read, change, write)
	iowr(3'd2, 8'd4); command(8'hA0);
	wait_drq; check(ok, "DRQ for the write");
	for (i = 0; i < 256; i = i + 1) begin
		iowr(3'd3, (8'hA0 ^ i[7:0]) + 8'd1);
		ref0[secoff(5, 0, 4) + i] = (8'hA0 ^ i[7:0]) + 8'd1;
	end
	wait_idle; check(ok, "write ended");
	iord(3'd0, v); check(v == 8'h00, "status after the write");
	for (i = 0; i < 655360; i = i + 1)
		if (img0[i] !== ref0[i]) begin errors = errors + 1; if (errors < 10) $display("FAIL: image byte %0d is %h, want %h", i, img0[i], ref0[i]); i = 655360; end

	// ---- write two sectors (several sector write): 6 and 7
	iowr(3'd2, 8'd6); command(8'hB0);
	for (j = 6; j <= 7; j = j + 1) begin
		wait_drq; check(ok, "DRQ for a sector of the multiple write");
		for (i = 0; i < 256; i = i + 1) begin
			iowr(3'd3, i[7:0] ^ (8'h30 + j));
			ref0[secoff(5, 0, j) + i] = i[7:0] ^ (8'h30 + j);
		end
	end
	// the command goes on to sector 8; it is not wanted: wait for its DRQ (so sector 7 is on the disc), then stop it
	wait_drq; check(ok, "DRQ for sector 8 of the multiple write");
	command(8'hD0); wait_idle;
	for (i = 0; i < 655360; i = i + 1)
		if (img0[i] !== ref0[i]) begin errors = errors + 1; if (errors < 10) $display("FAIL: image byte %0d is %h, want %h after the multiple write", i, img0[i], ref0[i]); i = 655360; end

	// ---- single density: 128 byte sectors (density bit off)
	ctlv = 8'h0C; iowr(3'd4, ctlv);
	iowr(3'd2, 8'd2); command(8'h80); wait_drq;
	for (i = 0; i < 128; i = i + 1) begin
		iord(3'd3, v);
		if (v !== ref0[((2 * 5 + 0) * 16 + 1) * 128 + i]) begin errors = errors + 1; if (errors < 10) $display("FAIL: single density byte %0d: %h", i, v); end
	end
	wait_idle; check(ok, "single density read ended");
	ctlv = 8'h1C; iowr(3'd4, ctlv);

	// ---- read address
	command(8'hC0); wait_drq;
	iord(3'd3, v); check(v == 8'd5, "ID track");
	iord(3'd3, v); check(v == 8'd0, "ID side");
	iord(3'd3, v); check(v >= 8'd1 && v <= 8'd16, "ID sector");
	iord(3'd3, v); check(v == 8'd1, "ID length code: 256");
	iord(3'd3, v); iord(3'd3, v);
	wait_idle; check(ok, "read address ended");

	// ---- errors
	iowr(3'd2, 8'd17); command(8'h80); wait_idle; iord(3'd0, v); check(v == 8'h10, "sector 17: record not found");
	iowr(3'd2, 8'd0);  command(8'h80); wait_idle; iord(3'd0, v); check(v == 8'h10, "sector 0: record not found");
	iowr(3'd1, 8'd9);  iowr(3'd2, 8'd1); command(8'h80); wait_idle; iord(3'd0, v); check(v == 8'h10, "track register that is not the head: record not found");
	iowr(3'd1, 8'd5);
	ctlv = 8'h10; iowr(3'd4, ctlv);            // motor off
	iowr(3'd2, 8'd1); command(8'h80); wait_idle; iord(3'd0, v); check(v == 8'h80, "motor off: not ready");
	ctlv = 8'h1C; iowr(3'd4, ctlv);
	d_ro = 2'b01; repeat (10) @(posedge clk);
	iowr(3'd2, 8'd1); command(8'hA0); wait_idle; iord(3'd0, v); check(v == 8'h40, "read only disc: write protected");
	d_ro = 2'b00; repeat (10) @(posedge clk);

	// ---- stepping: in is towards higher tracks; the update bit moves the track register
	command(8'h58);                            // step in, update, head load: head 6, TR 6
	iord(3'd1, v); check(v == 8'd6, "step in with update: track register 6");
	command(8'h48);                            // step in, no update: head 7, TR stays
	iord(3'd1, v); check(v == 8'd6, "step in without update: track register unchanged");
	command(8'h68);                            // step out, no update: head 6
	command(8'h78);                            // step out with update: head 5, TR 5
	iord(3'd1, v); check(v == 8'd5, "step out with update: track register 5");
	iowr(3'd2, 8'd3); command(8'h80); wait_drq;                       // the head should be at 5 again: sector 3 reads right
	for (i = 0; i < 256; i = i + 1) begin
		iord(3'd3, v);
		if (v !== ref0[secoff(5, 0, 3) + i]) begin errors = errors + 1; if (errors < 10) $display("FAIL: after stepping, byte %0d", i); end
	end
	wait_idle;
	command(8'h08);
	iord(3'd0, v); check(v[2], "restore: track 00");

	// ---- drive B
	d_mnt = 2'b11; repeat (10) @(posedge clk);
	ctlv = 8'h1D; iowr(3'd4, ctlv);            // drive B, side 0
	command(8'h08);
	iowr(3'd2, 8'd2); command(8'h80); wait_drq;
	for (i = 0; i < 256; i = i + 1) begin
		iord(3'd3, v);
		if (v !== img1[secoff(0, 0, 2) + i]) begin errors = errors + 1; if (errors < 10) $display("FAIL: drive B byte %0d: %h want %h", i, v, img1[secoff(0,0,2)+i]); end
	end
	wait_idle;
	ctlv = 8'h1C; iowr(3'd4, ctlv);

	// ---- format (write track): the stream of the ROM driver for one track: gaps, 16 interleaved sectors
	iowr(3'd3, 8'd1); command(8'h18);          // seek to 1 (head from 0)
	begin : fmt
		integer il [0:15];
		integer k, s, b;
		il[0]=1; il[1]=12; il[2]=7; il[3]=2; il[4]=13; il[5]=8; il[6]=3; il[7]=14; il[8]=9; il[9]=4; il[10]=15; il[11]=10; il[12]=5; il[13]=16; il[14]=11; il[15]=6;
		command(8'hF4);
		wait_drq; check(ok, "DRQ for write track");
		for (b = 0; b < 80; b = b + 1) begin wait_drq; iowr(3'd3, 8'h4E); end
		for (b = 0; b < 12; b = b + 1) begin wait_drq; iowr(3'd3, 8'h00); end
		for (b = 0; b < 3; b = b + 1) begin wait_drq; iowr(3'd3, 8'hF6); end
		wait_drq; iowr(3'd3, 8'hFC);
		for (k = 0; k < 16; k = k + 1) begin
			s = il[k];
			for (b = 0; b < 50; b = b + 1) begin wait_drq; iowr(3'd3, 8'h4E); end
			for (b = 0; b < 12; b = b + 1) begin wait_drq; iowr(3'd3, 8'h00); end
			for (b = 0; b < 3; b = b + 1) begin wait_drq; iowr(3'd3, 8'hF5); end
			wait_drq; iowr(3'd3, 8'hFE);
			wait_drq; iowr(3'd3, 8'd1);        // track
			wait_drq; iowr(3'd3, 8'd0);        // side
			wait_drq; iowr(3'd3, s[7:0]);      // sector
			wait_drq; iowr(3'd3, 8'd1);        // 256 bytes
			wait_drq; iowr(3'd3, 8'hF7);
			for (b = 0; b < 22; b = b + 1) begin wait_drq; iowr(3'd3, 8'h4E); end
			for (b = 0; b < 12; b = b + 1) begin wait_drq; iowr(3'd3, 8'h00); end
			for (b = 0; b < 3; b = b + 1) begin wait_drq; iowr(3'd3, 8'hF5); end
			wait_drq; iowr(3'd3, 8'hFB);
			for (b = 0; b < 256; b = b + 1) begin wait_drq; iowr(3'd3, 8'hE5); end
			wait_drq; iowr(3'd3, 8'hF7);
			for (b = 0; b < 256; b = b + 1) ref0[secoff(1, 0, s) + b] = 8'hE5;
		end
		wait_idle; check(ok, "write track ended");
		iord(3'd0, v); check(v == 8'h00, "status after write track");
	end
	for (i = 0; i < 655360; i = i + 1)
		if (img0[i] !== ref0[i]) begin errors = errors + 1; if (errors < 10) $display("FAIL: after the format, image byte %0d is %h, want %h", i, img0[i], ref0[i]); i = 655360; end

	if (errors == 0) $display("SDX FDC TEST PASSED: %0d block reads, %0d block writes", blk_reads, blk_writes);
	else $display("SDX FDC TEST FAILED: %0d errors", errors);
	$finish;
end

initial begin
	#900000000;
	$display("TIMEOUT");
	$finish;
end

endmodule
