// sdram_model.sv - a behavioural SDRAM chip (16 bit, 4 banks, 8192 rows, 512 columns, like the MT48LC16M16A2 on the
// MiSTer's SDRAM board) for the logic simulation. It does the part of the data sheet the core uses: ACTIVE, READ and
// WRITE with auto precharge, burst length 1, CAS latency 2, byte masks, AUTO REFRESH, LOAD MODE REGISTER, and it checks
// what the controller does:
//   - the start-up order: PRECHARGE ALL, two AUTO REFRESH, LOAD MODE (CL 2, burst 1), and nothing else before
//   - tRCD (20ns), tRC (66ns), tRP (20ns), tWR (15ns), tRFC (66ns), a bank not active when it is opened
//   - the refresh interval after start-up: no more than 7.8us (8192 refreshes in 64ms) between two
// A read puts its data on DQ from 45ns to 62.5ns after the edge that clocks the READ in (CL 2 at 50MHz, tAC 5ns, tOH 2.5ns).
`timescale 1ns/1ps

module sdram_model
(
	input         clk,
	input         cke,
	input         cs_n, ras_n, cas_n, we_n,
	input   [1:0] ba,
	input  [12:0] a,
	input         dqml, dqmh,
	inout  [15:0] dq
);

parameter CLK_NS = 20.0;

reg [15:0] mem [longint];
reg [15:0] dq_o  = 16'h0000;
reg        dq_oe = 0;
assign dq = dq_oe ? dq_o : 16'hzzzz;

reg        bank_open [0:3];
reg [12:0] bank_row  [0:3];
real       bank_t_act [0:3];
real       bank_t_free [0:3];
real       t_busy = 0;
integer    init_step = 0;          // 0 want PRECHARGE ALL, 1 and 2 want AUTO REFRESH, 3 want LOAD MODE, 4 running
real       t_last_ref = -1;
real       max_gap = 0;
integer    refreshes = 0, reads = 0, writes = 0, errors = 0;
reg  [1:0] dqm_h0 = 0, dqm_h1 = 0;  // the byte masks one and two clocks ago (a read's data is masked by the mask two clocks later)
reg  [1:0] dqm_now;

task err(input [255*8:1] msg);
begin
	errors = errors + 1;
	$display("SDRAM MODEL ERROR at %0t: %0s", $time, msg);
end
endtask

integer i;
initial for (i = 0; i < 4; i = i + 1) begin bank_open[i] = 0; bank_t_act[i] = -1000; bank_t_free[i] = 0; end

wire [2:0] cmd = {ras_n, cas_n, we_n};

always @(posedge clk) begin
	reg [15:0] w;
	longint    key;
	real       t;
	t = $realtime;
	dqm_now = {dqmh, dqml};
	dqm_h1 <= dqm_h0;
	dqm_h0 <= dqm_now;

	if (cke && !cs_n) begin
		case (cmd)
		3'b011: begin   // ACTIVE
			if (init_step != 4) err("ACTIVE before the mode register is set");
			if (t < t_busy) err("ACTIVE too soon after a refresh");
			if (bank_open[ba]) err("ACTIVE on a bank that is open");
			if (t < bank_t_free[ba]) err("ACTIVE too soon after the previous use of the bank (tRP/tRC)");
			if (t - bank_t_act[ba] < 66.0 - 0.01) err("ACTIVE to ACTIVE of a bank under tRC");
			bank_open[ba] = 1; bank_row[ba] = a; bank_t_act[ba] = t;
		end
		3'b101, 3'b100: begin   // READ, WRITE
			if (init_step != 4) err("READ/WRITE before the mode register is set");
			if (!bank_open[ba]) err("READ/WRITE on a bank that is not active");
			else begin
				if (t - bank_t_act[ba] < 20.0 - 0.01) err("READ/WRITE under tRCD");
				key = {ba, bank_row[ba], a[8:0]};
				if (cmd == 3'b101) begin
					reads = reads + 1;
					w = mem.exists(key) ? mem[key] : 16'hxxxx;
					fork
						begin
							#(2 * CLK_NS + 5.0 - 0.001);
							dq_o = w; dq_oe = 1;
							if (dqm_h0[0]) dq_o[7:0]  = 8'hzz;
							if (dqm_h0[1]) dq_o[15:8] = 8'hzz;
							#(CLK_NS - 2.5 + 0.002);
							dq_oe = 0;
						end
					join_none
				end else begin
					writes = writes + 1;
					w = mem.exists(key) ? mem[key] : 16'hxxxx;
					if (!dqml) w[7:0]  = dq[7:0];
					if (!dqmh) w[15:8] = dq[15:8];
					mem[key] = w;
				end
				if (a[10]) begin     // auto precharge
					bank_open[ba] = 0;
					begin
						real pre_start;
						pre_start = (cmd == 3'b100) ? t + CLK_NS + 15.0 : t + CLK_NS;
						if (pre_start < bank_t_act[ba] + 42.0) pre_start = bank_t_act[ba] + 42.0;
						bank_t_free[ba] = pre_start + 20.0;
					end
				end
			end
		end
		3'b010: begin   // PRECHARGE
			if (a[10]) begin
				for (i = 0; i < 4; i = i + 1) begin bank_open[i] = 0; bank_t_free[i] = t + 20.0; end
				if (init_step == 0) init_step = 1;
			end else begin
				bank_open[ba] = 0; bank_t_free[ba] = t + 20.0;
			end
		end
		3'b001: begin   // AUTO REFRESH
			if (bank_open[0] | bank_open[1] | bank_open[2] | bank_open[3]) err("AUTO REFRESH with a bank open");
			if (t < t_busy) err("AUTO REFRESH too soon after a refresh (tRFC)");
			for (i = 0; i < 4; i = i + 1) if (t < bank_t_free[i]) err("AUTO REFRESH too soon after a precharge");
			t_busy = t + 66.0;
			if (init_step == 1 || init_step == 2) init_step = init_step + 1;
			else if (init_step == 0) err("AUTO REFRESH before PRECHARGE ALL");
			else if (init_step == 4) begin
				refreshes = refreshes + 1;
				if (t_last_ref >= 0 && (t - t_last_ref) > max_gap) max_gap = t - t_last_ref;
				if (t_last_ref >= 0 && (t - t_last_ref) > 7800.0) err("refresh interval over 7.8us");
				t_last_ref = t;
			end
		end
		3'b000: begin   // LOAD MODE REGISTER
			if (t < t_busy) err("LOAD MODE too soon after a refresh");
			if (init_step != 3) err("LOAD MODE out of order");
			else begin
				if (a !== 13'b000_1_00_010_0_000) err("mode register is not CL2, burst 1, single write");
				init_step = 4;
				t_busy = t + 2 * CLK_NS;
			end
		end
		default: ;
		endcase
	end
end

endmodule
