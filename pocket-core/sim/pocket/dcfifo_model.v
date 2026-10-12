// Simulation model of the Intel dcfifo megafunction, as far as agg23's
// data_loader uses it: normal (not show-ahead) read mode, rdempty in the read
// clock domain. Pointers cross domains through two-flop synchronisers of Gray
// codes, as the real FIFO does; depth 2^lpm_widthu.
`timescale 1ns/1ps
module dcfifo (data, rdclk, rdreq, wrclk, wrreq, q, rdempty,
               aclr, eccstatus, rdfull, rdusedw, wrempty, wrfull, wrusedw);
    parameter lpm_width = 8;
    parameter lpm_widthu = 2;
    parameter lpm_numwords = 4;
    parameter lpm_showahead = "OFF";
    parameter lpm_type = "dcfifo";
    parameter clocks_are_synchronized = "FALSE";
    parameter intended_device_family = "Cyclone V";
    parameter overflow_checking = "OFF";
    parameter underflow_checking = "OFF";
    parameter use_eab = "OFF";
    parameter rdsync_delaypipe = 5;
    parameter wrsync_delaypipe = 5;

    input  wire [lpm_width-1:0] data;
    input  wire                 rdclk, rdreq, wrclk, wrreq;
    output reg  [lpm_width-1:0] q;
    output wire                 rdempty;
    // present for port compatibility; not modelled
    input  wire                 aclr;
    output wire [1:0]           eccstatus;
    output wire                 rdfull, wrempty, wrfull;
    output wire [lpm_widthu-1:0] rdusedw, wrusedw;
    assign eccstatus = 2'b00; assign rdfull = 1'b0; assign wrempty = 1'b0; assign wrfull = 1'b0;
    assign rdusedw = {lpm_widthu{1'b0}}; assign wrusedw = {lpm_widthu{1'b0}};

    localparam W = lpm_widthu + 1;
    reg [lpm_width-1:0] mem [0:(1<<lpm_widthu)-1];
    reg [W-1:0] wptr = 0, rptr = 0;
    reg [W-1:0] wg_s1 = 0, wg_s2 = 0;
    function [W-1:0] g2b; input [W-1:0] g; integer i; begin
        g2b[W-1] = g[W-1];
        for (i = W-2; i >= 0; i = i - 1) g2b[i] = g2b[i+1] ^ g[i];
    end endfunction
    wire [W-1:0] wgray = wptr ^ (wptr >> 1);
    always @(posedge wrclk) if (wrreq) begin
        mem[wptr[lpm_widthu-1:0]] <= data;
        wptr <= wptr + 1'b1;
    end
    always @(posedge rdclk) begin
        wg_s1 <= wgray; wg_s2 <= wg_s1;
        if (rdreq && !rdempty) begin
            q <= mem[rptr[lpm_widthu-1:0]];
            rptr <= rptr + 1'b1;
        end
    end
    assign rdempty = (g2b(wg_s2) == rptr);
endmodule
