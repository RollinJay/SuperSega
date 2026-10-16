`timescale 1ns/1ps
// Z80 wrapper timing test: runs prog.hex, logs each instruction start (M1) with
// the T-state count, and every I/O access (full 16-bit address, direction,
// value) with the T-state at which io_sample fired.
module tb;
    reg clk = 0; always #5 clk = ~clk;
    reg reset_n = 0;
    reg [3:0] div = 0;
    wire cen = (div == 0);
    always @(posedge clk) div <= (div == 2) ? 0 : div + 1;   // cen every 3 clocks
    wire [15:0] a; wire [7:0] dout; reg [7:0] din;
    wire mreq_n, iorq_n, rd_n, wr_n, m1_n, rfsh_n, halt_n;
    wire mem_rd_start, mem_wr_start, io_sample, io_cycle, io_write, int_ack;
    reg [7:0] mem [0:65535];
    integer tcount = 0, i, f;
    reg int_n = 1;
    mdr_z80 dut(.clk(clk), .reset_n(reset_n), .cen(cen), .wait_n(1'b1), .int_n(int_n), .nmi_n(1'b1),
        .a(a), .dout(dout), .din(din), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n), .wr_n(wr_n),
        .m1_n(m1_n), .rfsh_n(rfsh_n), .halt_n(halt_n), .mem_rd_start(mem_rd_start),
        .mem_wr_start(mem_wr_start), .io_sample(io_sample), .io_cycle(io_cycle), .io_write(io_write),
        .int_ack(int_ack));
    always @* begin
        if (!iorq_n && !rd_n) din = a[7:0] ^ 8'h5A;
        else if (int_ack) din = 8'hFF;
        else din = mem[a];
    end
    always @(posedge clk) if (!mreq_n && !wr_n) mem[a] <= dout;
    always @(posedge clk) if (cen) tcount <= tcount + 1;
    reg m1_prev = 1;
    always @(posedge clk) begin
        m1_prev <= m1_n;
        if (m1_prev && !m1_n) $fdisplay(f, "M1 %0d %04x", tcount, a);
        if (io_sample) $fdisplay(f, "IO %0d %04x %0d %02x", tcount, a, io_write, io_write ? dout : (a[7:0] ^ 8'h5A));
        if (mem_rd_start && !m1_n && 0) ;
    end
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = 0;
        $readmemh("prog.hex", mem);
        f = $fopen("z80_rtl.log", "w");
        #100 reset_n = 1;
        #(3*10*4000);
        $fclose(f);
        $finish;
    end
endmodule
