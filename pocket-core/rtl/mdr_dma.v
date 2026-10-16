// MasterDrive - DMA engine (Technical Reference section 9)
//
// $F4/$F5 source, $F6 bits 1-0 the source of a memory transfer (0 the CPU
// address space, 1 the card, 2 work RAM; 3 is reserved and acts as 0) and
// bits 3-2 the mode (0 memory to VRAM or CRAM, 1 VRAM to VRAM, 2 fill; 3 is
// reserved and runs as 0), $F7/$F8 bits 5-0 the destination and $F8 bit 6
// CRAM, $F9/$FA bits 5-0 the length (0 = 16,384), $FA bit 7 starts. The
// registers keep their values (mdr_io holds them); the transfer counts its
// own addresses: a VRAM destination on through address bit 14, VRAM to VRAM
// reading source bits 14-0, CRAM bytes in its 512-byte space.
//
// The CPU is held from the start until the transfer is done and it has been
// charged what the emulator charges (open question Q26): one T-state per
// byte, and for a transfer from the CPU address space the cartridge wait
// state on each byte read from $0000-$BFFF at 200 %. The CPU goes on to the
// T1 of its next opcode fetch and is held from that fetch's T2: the charge is
// counted in the CPU enables at which it waits (ce_held), one wait state
// each, so it is a T-state at any turbo step. The fetch's own cartridge wait
// state at 200 % (fetch_ws, from mdr_top) is added to the charge, since it
// would otherwise fall inside the hold. When the memory is slower than the
// charge, the CPU waits for the transfer.
//
// Memory reads go through mdr_mem while the CPU is held: the engine drives
// its address and read strobe (mdr_top multiplexes them), card reads force
// $4000-$7FFF to the card, and work RAM reads use $C000-$DFFF, the selected
// bank. VRAM and CRAM are reached through the VDP's CPU port.
`default_nettype none

module mdr_dma (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_held,         // a CPU enable at which the CPU waits (T2 or a wait state)
    input  wire        fetch_ws,        // the held fetch takes the cartridge wait state: charge it
    input  wire        start,           // $FA written with bit 7 set (MasterDrive mode)
    input  wire [7:0]  r_f4, r_f5, r_f6, r_f7, r_f8, r_f9,
    input  wire [7:0]  r_fa,            // the value being written to $FA
    input  wire        ws200,           // the cartridge wait state is on (200 %)
    output wire        busy,            // hold the CPU (its WAIT line)
    output wire        bus,             // the engine owns the memory bus
    // memory, through mdr_mem
    output reg  [15:0] m_a,
    output reg         m_rd,            // one-clock read strobe
    output reg  [1:0]  m_src,           // 1: read the card (bank $0B), 2: the selected work RAM bank
    input  wire        m_wait_n,        // low while a read is in progress
    input  wire [7:0]  m_data,
    // the VDP's CPU port
    output reg         v_we,
    output reg         v_re,
    output reg  [14:0] v_addr,
    output reg  [7:0]  v_din,
    input  wire [7:0]  v_dout,
    output reg         c_we,            // CRAM byte write
    output reg  [8:0]  c_addr,
    output reg  [7:0]  c_din,
    input  wire        c_ready          // the VDP can take a CRAM byte
);
    localparam S_IDLE = 3'd0, S_READ = 3'd1, S_MWAIT = 3'd2, S_VWAIT = 3'd3, S_WRITE = 3'd4, S_CWAIT = 3'd5;
    reg [2:0]  st;
    reg [15:0] src;
    reg [14:0] dst;
    reg [14:0] left;                     // bytes still to move (1-16384)
    reg [1:0]  sel, mode;
    reg        to_c;
    reg [7:0]  fill, data;
    reg [16:0] owe;                      // T-states still to charge
    reg [1:0]  vw;
    reg [2:0]  md;                       // clocks before mdr_mem's wait line is meaningful
    reg [2:0]  tail;                     // clocks the CPU stays held after the bus is handed back
    // the hold outlasts the bus by a few clocks, so that the CPU's fetch, which
    // mdr_top makes when the bus is handed back, holds it through mdr_mem by then
    assign busy = (st != S_IDLE) || (owe != 17'd0) || (tail != 3'd0);
    assign bus  = (st != S_IDLE);

    wire [15:0] rd_a = (sel == 2'd1) ? {2'b01, src[13:0]} : (sel == 2'd2) ? {3'b110, src[12:0]} : src;
    // the cartridge wait state of a byte read from the CPU address space at 200 %
    wire        extra = ws200 && (mode == 2'd0 || mode == 2'd3) && (sel == 2'd0 || sel == 2'd3) && (src < 16'hC000);
    // the charge: a byte's T-state (and wait state) as it is written, less one
    // for each enable at which the CPU waits
    // a byte is written when the VDP can take it: a CRAM byte waits for the
    // VDP to finish the one before (it reads the entry and writes it back),
    // while the engine has already read the next one
    wire        wr_go   = (st == S_WRITE) && (!to_c || c_ready);
    wire [1:0]  owe_add = (wr_go ? 2'd1 + {1'b0, extra} : 2'd0) + {1'b0, fetch_ws};
    wire        owe_dec = ce_held && (owe != 17'd0);

    always @(posedge clk) begin
        m_rd <= 1'b0; v_we <= 1'b0; v_re <= 1'b0; c_we <= 1'b0;
        if (rst) begin
            st <= S_IDLE; owe <= 17'd0; m_src <= 2'd0; tail <= 3'd0;
        end else begin
            owe <= owe + {15'd0, owe_add} - {16'd0, owe_dec};
            if (tail != 3'd0) tail <= tail - 3'd1;
            case (st)
            S_IDLE: if (start) begin
                src  <= {r_f5, r_f4};
                sel  <= r_f6[1:0];
                mode <= r_f6[3:2];
                dst  <= {1'b0, r_f8[5:0], r_f7};
                to_c <= r_f8[6];
                fill <= r_f4;
                left <= ({r_fa[5:0], r_f9} == 14'd0) ? 15'd16384 : {1'b0, r_fa[5:0], r_f9};
                st   <= S_READ;
            end
            S_READ: begin
                if (mode == 2'd2) begin data <= fill; st <= S_WRITE; end
                else if (mode == 2'd1) begin v_re <= 1'b1; v_addr <= src[14:0]; vw <= 2'd2; st <= S_VWAIT; end
                else begin m_a <= rd_a; m_src <= (sel == 2'd1) ? 2'd1 : (sel == 2'd2) ? 2'd2 : 2'd0; m_rd <= 1'b1; md <= 3'd4; st <= S_MWAIT; end
            end
            // the strobe reaches mdr_mem through mdr_top's register stage; its wait
            // line then stays low until the byte is there
            S_MWAIT: if (md != 3'd0) md <= md - 3'd1;
                     else if (m_wait_n) begin data <= m_data; st <= S_WRITE; end
            S_VWAIT: begin
                vw <= vw - 2'd1;
                if (vw == 2'd0) begin data <= v_dout; st <= S_WRITE; end
            end
            S_WRITE: if (wr_go) begin
                if (to_c) begin c_we <= 1'b1; c_addr <= dst[8:0]; c_din <= data; end
                else begin v_we <= 1'b1; v_addr <= dst; v_din <= data; end
                if (left != 15'd1) st <= S_READ;
                else if (to_c) st <= S_CWAIT;            // the last CRAM byte: let the VDP finish it
                else begin st <= S_IDLE; tail <= 3'd5; end
                src <= src + 16'd1;
                dst <= dst + 15'd1;
                left <= left - 15'd1;
            end
            S_CWAIT: if (!c_we && c_ready) begin st <= S_IDLE; tail <= 3'd5; end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
