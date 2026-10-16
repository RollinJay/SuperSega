// MasterDrive - Z80 wrapper
//
// Wraps the TV80 core (MIT licence, third_party/tv80) with a clock enable so the
// CPU runs at the turbo step's rate inside the 53.693175 MHz system clock, and
// turns its internal M-cycle/T-state view into bus strobes plus two one-cycle
// pulses the rest of the machine uses:
//
//   mem_rd_start  - first system cycle of T1 of a memory read (opcode fetch or
//                   operand read). The address is valid; slow memory starts here.
//   io_sample     - the enable edge at which the CPU latches I/O read data, and the
//                   point at which I/O writes take effect: the end of T2 of the I/O
//                   cycle, ten T-states into IN A,(n) or OUT (n),A. Gearsystem
//                   performs the access at the same point.
//
// Bus strobes follow tv80s: they change only on enable edges.
`default_nettype none

module mdr_z80 (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        cen,          // one pulse per T-state
    input  wire        wait_n,
    input  wire        int_n,
    input  wire        nmi_n,
    output wire [15:0] a,
    output wire [7:0]  dout,
    input  wire [7:0]  din,
    output reg         mreq_n,
    output reg         iorq_n,
    output reg         rd_n,
    output reg         wr_n,
    output wire        m1_n,
    output wire        rfsh_n,
    output wire        halt_n,
    // decoded bus view
    output wire        mem_rd_start,
    output wire        mem_wr_start,
    output wire        io_sample,
    output wire        io_cycle,
    output wire        io_write,
    output wire        int_ack,      // interrupt acknowledge cycle in progress
    // simulation visibility (zero in synthesis)
    output wire        dbg_fetch,    // opcode byte latched this cycle
    output wire [7:0]  dbg_op,
    output wire [15:0] dbg_sp,
    output wire [7:0]  dbg_a,
    output wire [7:0]  dbg_f
);

    wire        intcycle_n;
    wire        no_read;
    wire        write;
    wire        iorq;
    wire [6:0]  mcycle;
    wire [6:0]  tstate;
    reg  [7:0]  di_reg;

    tv80_core #(.Mode(0), .IOWait(1)) u_core (
        .cen        (cen),
        .m1_n       (m1_n),
        .iorq       (iorq),
        .no_read    (no_read),
        .write      (write),
        .rfsh_n     (rfsh_n),
        .halt_n     (halt_n),
        .wait_n     (wait_n),
        .int_n      (int_n),
        .nmi_n      (nmi_n),
        .reset_n    (reset_n),
        .busrq_n    (1'b1),
        .busak_n    (),
        .clk        (clk),
        .IntE       (),
        .stop       (),
        .A          (a),
        .dinst      (din),
        .di         (di_reg),
        .dout       (dout),
        .mc         (mcycle),
        .ts         (tstate),
        .intcycle_n (intcycle_n)
    );

    // ---------------------------------------------------------------- strobes
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rd_n   <= 1'b1;
            wr_n   <= 1'b1;
            iorq_n <= 1'b1;
            mreq_n <= 1'b1;
            di_reg <= 8'h00;
        end else if (cen) begin
            rd_n   <= 1'b1;
            wr_n   <= 1'b1;
            iorq_n <= 1'b1;
            mreq_n <= 1'b1;
            if (mcycle[0]) begin
                if (tstate[1] || (tstate[2] && !wait_n)) begin
                    rd_n   <= ~intcycle_n;
                    mreq_n <= ~intcycle_n;
                    iorq_n <= intcycle_n;
                end
            end else begin
                if ((tstate[1] || (tstate[2] && !wait_n)) && !no_read && !write) begin
                    rd_n   <= 1'b0;
                    iorq_n <= ~iorq;
                    mreq_n <= iorq;
                end
                // T2Write = 1: write strobe through T2 (and waits)
                if ((tstate[1] || (tstate[2] && !wait_n)) && write) begin
                    wr_n   <= 1'b0;
                    iorq_n <= ~iorq;
                    mreq_n <= iorq;
                end
            end
            if (tstate[2] && wait_n && !write && !no_read)
                di_reg <= din;
        end
    end

    // ---------------------------------------------------------------- bus view
    // T1 of a memory access: the core has put out the address for this M-cycle.
    // Opcode fetch (M1, not an interrupt acknowledge) or a memory read/write.
    wire mem_m1   = mcycle[0] && intcycle_n;
    wire mem_rdwr = !mcycle[0] && !iorq && !no_read;
    reg  t1_seen;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) t1_seen <= 1'b0;
        else if (cen) t1_seen <= 1'b0;
        else if (tstate[1]) t1_seen <= 1'b1;
    end
    assign mem_rd_start = tstate[1] && !t1_seen && (mem_m1 || (mem_rdwr && !write));
    assign mem_wr_start = tstate[1] && !t1_seen && mem_rdwr && write;

    // I/O: TV80 inserts the automatic I/O wait by repeating T1, so the cycle is
    // T1 T1w T2 T3 and the data is sampled once, at the T2 enable edge with
    // wait_n high (any bus-sync hold repeats T2 with wait_n low first).
    assign io_cycle  = !mcycle[0] && iorq && !no_read;
    assign io_write  = write;
    assign io_sample = cen && io_cycle && tstate[2] && wait_n;
    assign int_ack   = mcycle[0] && !intcycle_n;

    assign dbg_fetch = cen && mcycle[0] && tstate[2] && wait_n && intcycle_n;
    assign dbg_op    = din;
`ifdef VERILATOR
    assign dbg_sp = u_core.SP;
    assign dbg_a  = u_core.ACC;
    assign dbg_f  = u_core.F;
`else
    assign dbg_sp = 16'h0000;
    assign dbg_a  = 8'h00;
    assign dbg_f  = 8'h00;
`endif

endmodule

`default_nettype wire
