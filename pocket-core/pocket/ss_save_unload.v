// Super Sega - save slot read-out for the APF bridge
//
// Answers APF bridge reads at $2xxx_xxxx from the machine's cartridge-RAM
// save port. Each read fetches all four bytes of the 32-bit word in the
// machine clock domain and hands the whole word back in one step, with a
// toggle handshake in each direction.
//
// Why not agg23's data_unloader: it sends each byte back through its own FIFO
// entry and its bridge side reads the second to fourth entries without
// checking that they have arrived, which only works when the memory side is
// much faster than clk_74a. The machine's save port is not (simulation showed
// the fourth byte repeated in all four positions).
//
// Timing: the APF bridge peripheral sends the data it already holds and only
// then raises bridge_rd for the new address, so a read has a full bridge
// transaction (>800 ns) to complete. This one takes about 18 clk_sys cycles.
`default_nettype none

module ss_save_unload (
    input  wire        clk_74a,
    input  wire        bridge_rd,
    input  wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    output reg  [31:0] bridge_rd_data,

    input  wire        clk_sys,
    output reg         rd_active,      // owns the save port address this cycle
    output reg  [14:0] rd_addr,
    input  wire [7:0]  rd_data         // one cycle after rd_addr
);
    // Handshake registers of the clk_sys side, read by the clk_74a side.
    reg        ack_t = 1'b0;
    reg [31:0] word = 32'd0;          // byte at the lowest address in [31:24]

    // ------------------------------------------------ clk_74a side
    reg        rd_prev = 1'b0;
    reg        req_t = 1'b0;
    reg [14:0] req_addr = 15'd0;
    reg [2:0]  ack_s = 3'd0;
    reg [31:0] word_s;
    always @(posedge clk_74a) begin
        rd_prev <= bridge_rd;
        if (bridge_rd && !rd_prev && bridge_addr[31:28] == 4'h2) begin
            req_addr <= {bridge_addr[14:2], 2'b00};
            req_t    <= ~req_t;
        end
        ack_s <= {ack_s[1:0], ack_t};
        if (ack_s[2] != ack_s[1])
            bridge_rd_data <= bridge_endian_little ? {word_s[7:0], word_s[15:8], word_s[23:16], word_s[31:24]}
                                                   : word_s;
    end
    always @(posedge clk_74a) word_s <= word;   // stable for many cycles before ack toggles

    // ------------------------------------------------ clk_sys side
    // Per byte: cycle 0 drive the address, cycle 1 the RAM registers it,
    // cycle 2 the byte is on rd_data and is shifted in.
    reg [2:0]  req_s = 3'd0;
    reg [2:0]  n = 3'd0;              // byte index
    reg [1:0]  ph = 2'd0;             // phase within the byte
    reg        busy = 1'b0;
    always @(posedge clk_sys) begin
        req_s <= {req_s[1:0], req_t};
        rd_active <= busy;
        if (!busy) begin
            if (req_s[2] != req_s[1]) begin
                busy <= 1'b1; n <= 3'd0; ph <= 2'd0;
                rd_addr <= req_addr;
            end
        end else begin
            case (ph)
                2'd0: ph <= 2'd1;                      // address on the RAM port
                2'd1: ph <= 2'd2;                      // RAM output register loads
                default: begin                         // byte available
                    word <= {word[23:0], rd_data};
                    ph <= 2'd0;
                    if (n == 3'd3) begin busy <= 1'b0; ack_t <= ~ack_t; end
                    else begin n <= n + 3'd1; rd_addr <= {req_addr[14:2], n[1:0] + 2'd1}; end
                end
            endcase
        end
    end
endmodule

`default_nettype wire
