// MasterDrive - dual-port RAM, inferred as block RAM.
// Port A: read/write. Port B: read/write. Both synchronous, one-cycle read
// latency. Separate clocks are allowed (clk_b may equal clk_a).
//
// This is Quartus's true-dual-port RAM template, which maps onto the Cyclone V
// M10K blocks: a write also puts the written byte on that port's output ("new
// data"). Nothing in the core reads a port's output in the cycle after writing
// through it. A read on one port of the address the other port is writing in
// the same cycle returns either value ("no_rw_check").
`default_nettype none

module mdr_dpram #(
    parameter AW = 10,
    parameter DW = 8,
    parameter INIT_FILE = ""
) (
    input  wire          clk_a,
    input  wire          we_a,
    input  wire [AW-1:0] addr_a,
    input  wire [DW-1:0] din_a,
    output reg  [DW-1:0] dout_a,

    input  wire          clk_b,
    input  wire          we_b,
    input  wire [AW-1:0] addr_b,
    input  wire [DW-1:0] din_b,
    output reg  [DW-1:0] dout_b
);
    /* verilator lint_off MULTIDRIVEN */
    (* ramstyle = "no_rw_check" *) reg [DW-1:0] mem [0:(1<<AW)-1];
    /* verilator lint_on MULTIDRIVEN */

    // Simulation starts from zeroed memory; on the FPGA block RAM powers up
    // zeroed anyway, and leaving the loop out of synthesis keeps a 128 KB
    // array from being expanded into an initialisation list.
    integer i;
    initial begin
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
`ifndef SYNTHESIS
        else for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
`endif
    end

    always @(posedge clk_a) begin
        if (we_a) begin
            mem[addr_a] <= din_a;
            dout_a <= din_a;
        end else
            dout_a <= mem[addr_a];
    end

    always @(posedge clk_b) begin
        if (we_b) begin
            mem[addr_b] <= din_b;
            dout_b <= din_b;
        end else
            dout_b <= mem[addr_b];
    end
endmodule

`default_nettype wire
