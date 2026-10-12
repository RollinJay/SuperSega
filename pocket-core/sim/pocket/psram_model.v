// Behavioural model of one Pocket PSRAM chip (AS1C8M16PL class, two dies) in
// asynchronous mode, address/data multiplexed: the address is latched from
// {A[21:16], DQ[15:0]} while ADV# is low; OE# low drives read data; a write
// stores DQ when WE# rises (or CE# rises) with the byte enables. Each die is
// modelled at DEPTH words (enough for the test ROMs); higher addresses wrap.
// No timing checks: the controller's timing comes from its own parameters.
`timescale 1ns/1ps
module psram_model #(parameter AW = 20) (
    input  wire [21:16] a,
    inout  wire [15:0]  dq,
    output wire         wait_o,
    input  wire         clk,
    input  wire         adv_n,
    input  wire         cre,
    input  wire         ce0_n,
    input  wire         ce1_n,
    input  wire         oe_n,
    input  wire         we_n,
    input  wire         ub_n,
    input  wire         lb_n
);
    reg [15:0] die0 [0:(1<<AW)-1];
    reg [15:0] die1 [0:(1<<AW)-1];
    reg [21:0] addr;
    reg        sel1;
    integer i;
    initial for (i = 0; i < (1<<AW); i = i + 1) begin die0[i] = 16'h0000; die1[i] = 16'h0000; end

    wire ce = !ce0_n || !ce1_n;
    always @* if (ce && !adv_n) begin addr = {a, dq}; sel1 = !ce1_n; end

    wire [15:0] rd = sel1 ? die1[addr[AW-1:0]] : die0[addr[AW-1:0]];
    assign dq = (ce && adv_n && !oe_n && we_n) ? rd : 16'hzzzz;
    assign wait_o = 1'b0;

    reg we_d = 1'b1;
    reg [15:0] wdat;
    reg wub, wlb;
    // capture data while WE# is low and ADV# is high; commit on the rising edge of WE#
    always @(dq or we_n or adv_n or ub_n or lb_n) if (ce && !we_n && adv_n) begin
        wdat = dq; wub = !ub_n; wlb = !lb_n;
    end
    always @(posedge we_n) begin
        if (sel1) begin
            if (wub) die1[addr[AW-1:0]][15:8] = wdat[15:8];
            if (wlb) die1[addr[AW-1:0]][7:0]  = wdat[7:0];
        end else begin
            if (wub) die0[addr[AW-1:0]][15:8] = wdat[15:8];
            if (wlb) die0[addr[AW-1:0]][7:0]  = wdat[7:0];
        end
    end
endmodule
