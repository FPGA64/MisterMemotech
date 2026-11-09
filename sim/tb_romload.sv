// tb_romload.sv - rtl/mtx_romload.sv: where each kind of ROM file lands in the ROM memory and which "ok" flags it sets.
//
// A downloaded file is driven like the MiSTer firmware does it (ioctl_download high, ioctl_wr once per byte with ioctl_addr
// counting from 0). The bench keeps its own picture of the 128KB ROM memory from the writes (rom_we, rom_waddr, rom_wdata)
// and compares it with what the file should have put where.
`timescale 1ns/1ps

module tb_romload;

reg clk = 0;
always #10 clk = ~clk;

reg         dl = 0, wr = 0;
reg   [7:0] idx = 0;
reg  [26:0] addr = 0;
reg   [7:0] dout = 0;
wire        loading, we;
wire [16:0] waddr;
wire        os_ok, basic_ok, sdx_ok, cpm_ok, waddr_hi;
wire  [3:0] rom2_ok;
wire        cg_we, cg_ok;
wire [12:0] cg_addr;

mtx_romload dut
(
	.clk(clk), .ioctl_download(dl), .ioctl_wr(wr), .ioctl_index(idx), .ioctl_addr(addr), .ioctl_dout(dout),
	.rom_loading(loading), .rom_waddr(waddr), .rom_waddr_hi(waddr_hi), .rom_we(we),
	.os_ok(os_ok), .basic_ok(basic_ok), .sdx_ok(sdx_ok), .cpm_ok(cpm_ok), .rom2_ok(rom2_ok),
	.cg_we(cg_we), .cg_addr(cg_addr), .cg_ok(cg_ok)
);

reg  [7:0] mem [0:262143];            // 18 bit addresses: 0x20000 and up is the CP/M PROM page
reg        wrt [0:262143];            // written at least once since the last clear
reg  [7:0] cgm [0:8191];
reg        cgw [0:8191];
integer    cg_writes = 0;
integer    errors = 0, writes = 0, loading_seen_low = 0;
integer    i;

always @(posedge clk) if (we) begin
	if (!waddr_hi && waddr < 17'h10000) begin errors = errors + 1; $display("ERROR write below the ROMs: %05x", waddr); end
	if (waddr_hi && waddr >= 17'h02000) begin errors = errors + 1; $display("ERROR write beyond the CP/M page: %05x", waddr); end
	mem[{waddr_hi, waddr}] <= dout; wrt[{waddr_hi, waddr}] <= 1; writes = writes + 1;
end

always @(posedge clk) if (cg_we) begin
	cgm[cg_addr] <= dout; cgw[cg_addr] <= 1; cg_writes = cg_writes + 1;
	if (we) begin errors = errors + 1; $display("ERROR a byte went to both the ROM memory and the character ROM"); end
end

function [7:0] pat(input integer file, input integer i);
	pat = (file * 53 + i * 7 + (i / 256) * 13) & 255;
endfunction

// one file: n bytes of pattern 'file', sdxsig puts 08 07 06 ... at offset sigoff
task download(input [7:0] index, input integer n, input integer file, input integer sigoff);
	integer k;
	reg [7:0] b;
begin
	@(posedge clk); idx <= index; dl <= 1; addr <= 0; wr <= 0;
	for (k = 0; k < n; k = k + 1) begin
		@(posedge clk);
		b = pat(file, k);
		if (sigoff >= 0 && k >= sigoff && k < sigoff + 8) b = 8'h08 - (k - sigoff);
		addr <= k; dout <= b; wr <= 1;
		@(posedge clk); wr <= 0;
	end
	@(posedge clk); dl <= 0; wr <= 0;
	repeat (3) @(posedge clk);
end
endtask

task clear_model;
begin
	for (i = 0; i < 262144; i = i + 1) begin mem[i] = 8'hxx; wrt[i] = 0; end
	for (i = 0; i < 8192; i = i + 1) begin cgm[i] = 8'hxx; cgw[i] = 0; end
	writes = 0; cg_writes = 0;
end
endtask

task check(input bit cond, input [255*8:1] what);
begin
	if (!cond) begin errors = errors + 1; $display("FAIL: %0s", what); end
end
endtask

// does memory [base, base+n) hold pattern 'file' (with the signature if sigoff >= 0)?
function bit holds(input integer base, input integer n, input integer file, input integer sigoff);
	integer k;
	reg [7:0] b;
begin
	holds = 1;
	for (k = 0; k < n; k = k + 1) begin
		b = pat(file, k);
		if (sigoff >= 0 && k >= sigoff && k < sigoff + 8) b = 8'h08 - (k - sigoff);
		if (!wrt[base + k] || mem[base + k] !== b) holds = 0;
	end
end
endfunction

function integer count_written(input integer lo, input integer hi);
	integer k;
begin
	count_written = 0;
	for (k = lo; k < hi; k = k + 1) if (wrt[k]) count_written = count_written + 1;
end
endfunction

initial begin
	repeat (5) @(posedge clk);

	// ---- a 64KB boot.rom: OS, BASIC, ASSEM, SDX ROM (with its signature), four ROM 2 sub-pages
	clear_model;
	if ($test$plusargs("NOSIG")) begin
		// filler in the SDX section: the SDX card must stay off
		download(8'h00, 65536, 1, -1);
		check(!sdx_ok, "boot.rom 64KB without the SDX signature: sdx_ok stays 0");
		check(os_ok && basic_ok && rom2_ok == 4'b1111, "boot.rom 64KB without signature: os, basic and ROM 2 flags");
		$display("RESULT errors %0d (no-signature run)", errors);
		if (errors == 0) $display("PASS"); else $display("FAIL");
		$finish;
	end
	download(8'h00, 65536, 1, 24576);                   // the signature at 0x6000 of the file = the start of the SDX section
	check(os_ok && basic_ok, "boot.rom 64KB: os_ok and basic_ok");
	check(sdx_ok, "boot.rom 64KB with the SDX signature: sdx_ok");
	check(rom2_ok == 4'b1111, "boot.rom 64KB: all four ROM 2 sub-pages");
	check(holds(17'h10000, 24576, 1, -1) && count_written(17'h10000, 131072) == 65536, "boot.rom 64KB lands at 0x10000..0x1FFFF");
	check(!loading, "loading low after the file");

	// ---- boot1, boot2 and boot3 as separate files
	clear_model;
	download(8'h40, 8192, 2, -1);
	check(holds(17'h12000, 8192, 2, -1) && count_written(17'h10000, 131072) == 8192, "boot1.rom (index 0x40) at 0x12000");
	clear_model;
	download(8'h80, 8192, 3, -1);
	check(holds(17'h14000, 8192, 3, -1) && count_written(17'h10000, 131072) == 8192, "boot2.rom (index 0x80) at 0x14000");
	clear_model;
	download(8'hC0, 8192, 4, 0);
	check(holds(17'h16000, 8192, 4, 0) && count_written(17'h10000, 131072) == 8192, "boot3.rom (index 0xC0) at 0x16000");

	// ---- a file of 200KB as boot.rom: the part beyond 128KB of ROM memory is dropped, not wrapped
	clear_model;
	download(8'h00, 204800, 5, -1);
	check(count_written(17'h10000, 131072) == 65536 && writes == 65536, "boot.rom of 200KB: only the first 64KB are written");
	// ---- boot3.rom bigger than 8KB: the second 8KB is the 80 column character ROM, the rest is dropped
	clear_model;
	download(8'hC0, 50000, 6, -1);
	check(count_written(17'h10000, 131072) == 8192 && count_written(17'h16000, 17'h18000) == 8192 && holds(17'h16000, 8192, 6, -1), "boot3.rom of 50000 bytes: the first 8KB at 0x16000, nothing else below 0x20000");
	check(cg_writes == 8192 && cg_ok, "boot3.rom of 50000 bytes: 8KB go to the character ROM, cg_ok");
	begin : cpmchk
		integer k; integer bad;
		bad = 0;
		for (k = 0; k < 8192; k = k + 1) if (!wrt[18'h20000 + k] || mem[18'h20000 + k] !== pat(6, k + 16384)) bad = bad + 1;
		check(bad == 0, "boot3.rom of 50000 bytes: the third 8KB is in the CP/M page (page 16, 0x20000)");
	end
	check(!cpm_ok, "boot3.rom without the signature in the third part: cpm_ok stays 0");
	check(writes == 16384, "boot3.rom of 50000 bytes: 16KB written to the ROM memory in all, the rest dropped");
	begin : cgchk
		integer k; integer bad;
		bad = 0;
		for (k = 0; k < 8192; k = k + 1) if (!cgw[k] || cgm[k] !== pat(6, k + 8192)) bad = bad + 1;
		check(bad == 0, "boot3.rom: the character ROM holds bytes 8192..16383 of the file");
	end

	// ---- boot3.rom of three parts with the signature at the start of the third: the CP/M PROM is fitted
	clear_model;
	download(8'hC0, 24576, 12, 16384);
	check(cpm_ok, "boot3.rom of 24KB with the signature at 16KB: cpm_ok");
	check(cg_writes == 8192 && cg_ok, "boot3.rom of 24KB: the middle 8KB is the character ROM");
	begin : cpmchk2
		integer k; integer bad;
		bad = 0;
		for (k = 0; k < 8192; k = k + 1) begin
			if (!wrt[18'h20000 + k]) bad = bad + 1;
			else if (k < 8 && mem[18'h20000 + k] !== 8'h08 - k) bad = bad + 1;
		end
		check(bad == 0, "boot3.rom of 24KB: the CP/M page holds the third part, signature first");
	end
	check(count_written(17'h10000, 131072) == 8192, "boot3.rom of 24KB: only the first 8KB below 0x20000");

	// ---- the OSD entry for the character ROM, index 3: 8KB, no reset of the machine, nothing in the ROM memory
	clear_model;
	@(posedge clk); idx <= 8'h03; dl <= 1; addr <= 0; wr <= 0;
	@(posedge clk); @(posedge clk);
	check(!loading, "rom_loading stays low during a character ROM file");
	@(posedge clk); dl <= 0;
	repeat (3) @(posedge clk);
	clear_model;
	download(8'h03, 9000, 11, -1);
	check(writes == 0 && cg_writes == 8192, "Load char ROM (index 3), 9000 bytes: 8KB to the character ROM, nothing else");
	begin : cgchk2
		integer k; integer bad;
		bad = 0;
		for (k = 0; k < 8192; k = k + 1) if (!cgw[k] || cgm[k] !== pat(11, k)) bad = bad + 1;
		check(bad == 0, "Load char ROM: the character ROM holds the file");
	end
	check(os_ok && basic_ok, "the character ROM leaves os_ok and basic_ok alone");

	// ---- OSD "Load ROM 2" (index 2; the extension number is in bits 7:6)
	clear_model;
	download(8'h02, 16384, 7, -1);
	check(holds(17'h18000, 16384, 7, -1) && count_written(17'h10000, 131072) == 16384, "Load ROM 2, 16KB: at 0x18000..0x1BFFF");
	check(rom2_ok == 4'b0011, "Load ROM 2, 16KB: rom2_ok is 0011 (a new file forgets the 32KB one)");
	clear_model;
	download(8'h42, 8192, 8, -1);                       // extension 1 (.BIN)
	check(holds(17'h18000, 8192, 8, -1) && count_written(17'h10000, 131072) == 8192, "Load ROM 2, 8KB with extension 1: at 0x18000");
	check(rom2_ok == 4'b0001, "Load ROM 2, 8KB: rom2_ok is 0001");
	clear_model;
	download(8'h82, 40960, 9, -1);                      // 40KB: only 32KB are used
	check(holds(17'h18000, 32768, 9, -1) && writes == 32768, "Load ROM 2, 40KB: 32KB at 0x18000, the rest dropped");
	check(rom2_ok == 4'b1111, "Load ROM 2, 32KB: rom2_ok is 1111");
	check(os_ok && basic_ok, "ROM 2 loads leave os_ok and basic_ok alone");

	// ---- loading is high during a ROM 2 file, low for other indexes
	clear_model;
	@(posedge clk); idx <= 8'h02; dl <= 1; addr <= 0; wr <= 0;
	@(posedge clk); @(posedge clk);
	check(loading, "rom_loading is high during a Load ROM 2 file");
	@(posedge clk); dl <= 0;
	@(posedge clk); @(posedge clk);
	check(!loading, "rom_loading falls after it");
	clear_model;
	download(8'h01, 1000, 10, -1);                      // the tape
	download(8'h41, 1000, 10, -1);
	download(8'h05, 1000, 10, -1);
	check(writes == 0 && cg_writes == 0, "tape (index 1, 0x41) and other indexes write nothing");
	clear_model;
	download(8'h43, 100, 10, -1);                       // index 0x43: the same entry, with the extension 1 (.BIN)
	check(cg_writes == 100 && writes == 0, "index 0x43 (the OSD entry, extension 1) writes the character ROM too");
	clear_model;
	download(8'h04, 1000, 10, -1);
	check(cg_writes == 0 && writes == 0, "index 4 writes nothing");

	$display("RESULT errors %0d", errors);
	if (errors == 0) $display("PASS"); else $display("FAIL");

	$finish;
end

endmodule
