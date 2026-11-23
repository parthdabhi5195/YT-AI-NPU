// =============================================================================
// True Dual-Port SRAM - BRAM Inferred for Xilinx
// means it can read or write different addresses at the same time
// =============================================================================
`default_nettype none

module sram_dp #(
    parameter int DEPTH  = 4096, // slots in the array
    parameter int WIDTH  = 8, // each slot 8 bytes wide
    parameter int ADDR_W = $clog2(DEPTH) // calculates how many address bits are needed
)(
    input  wire                 clk, // reads and writes happen on rising edge
    // Port A
    input  wire                 en_a, // wake up port
    input  wire                 we_a, // write enable
    input  wire  [ADDR_W-1:0]  addr_a, // selects which address to access (read or write)
    input  wire  [WIDTH-1:0]   din_a, // data input bus
    output logic [WIDTH-1:0]   dout_a, // data output bus
    // Port B
    input  wire                 en_b,
    input  wire                 we_b,
    input  wire  [ADDR_W-1:0]  addr_b,
    input  wire  [WIDTH-1:0]   din_b,
    output logic [WIDTH-1:0]   dout_b
);

    // declares array of DEPTH elements, each WIDTH bits wide
    (* ram_style = "block" *) logic [WIDTH-1:0] mem [0:DEPTH-1];

    // Port A: write-first
    always_ff @(posedge clk) begin // only on rising edge
        if (en_a) begin // only if port a is enabled
            if (we_a) begin // write first
                mem[addr_a] <= din_a;
                dout_a      <= din_a; // <= non-blocking assignment (assign on the clock edge)
            end else begin
                dout_a <= mem[addr_a];
            end
        end
    end

    // Port B: write-first
    always_ff @(posedge clk) begin
        if (en_b) begin
            if (we_b) begin
                mem[addr_b] <= din_b;
                dout_b      <= din_b;
            end else begin
                dout_b <= mem[addr_b];
            end
        end
    end

// only compiled during simulation (Verilator)
`ifndef SYNTHESIS
    // Assertions
    always @(posedge clk) begin
        if (en_a) begin
            assert (addr_a < DEPTH)
                else $error("SRAM Port A address out of bounds: %0d >= %0d", addr_a, DEPTH);
        end
        if (en_b) begin
            assert (addr_b < DEPTH)
                else $error("SRAM Port B address out of bounds: %0d >= %0d", addr_b, DEPTH);
        end
    end
`endif

endmodule

`default_nettype wire
