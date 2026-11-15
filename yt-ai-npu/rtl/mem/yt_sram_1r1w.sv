// =============================================================================
// Foundry-Portable 1R1W Synchronous SRAM Wrapper (yt_sram_1r1w.sv)
// - Maps cleanly to SkyWater SKY130 OpenRAM `sky130_sram_2kbyte_1rw1r_32x512_8`
//   macros during OpenLane 2 ASIC synthesis when `SKY130_OPENRAM_MACRO` is defined
// - Maps cleanly to Block RAM (BRAM / UltraRAM) on Xilinx / Lattice / Intel FPGAs
// - Cycles-accurate 1-cycle read latency in Verilator / Icarus RTL simulation
// =============================================================================
`default_nettype none

module yt_sram_1r1w #(
    parameter int DEPTH  = 1024,
    parameter int WIDTH  = 32,
    parameter int ADDR_W = $clog2(DEPTH)
)(
    input  wire                 clk,
    // Read Port (1-cycle synchronous read latency)
    input  wire                 rd_en,
    input  wire  [ADDR_W-1:0]   rd_addr,
    output logic [WIDTH-1:0]    rd_data,
    // Write Port
    input  wire                 wr_en,
    input  wire  [ADDR_W-1:0]   wr_addr,
    input  wire  [WIDTH-1:0]    wr_data
);

`ifdef SKY130_OPENRAM_MACRO
    // -------------------------------------------------------------------------
    // ASIC Hard Macro Decomposition Hook for SkyWater SKY130 OpenRAM
    // Standard macro: sky130_sram_2kbyte_1rw1r_32x512_8 (512 words x 32-bit)
    // Automatically tiles across depth (N_ROWS) and width (N_COLS)
    // -------------------------------------------------------------------------
    localparam int MACRO_DEPTH = 512;
    localparam int MACRO_WIDTH = 32;
    localparam int N_ROWS = (DEPTH + MACRO_DEPTH - 1) / MACRO_DEPTH;
    localparam int N_COLS = (WIDTH + MACRO_WIDTH - 1) / MACRO_WIDTH;

    // Padded buses to match integer multiples of 32-bit macro width
    wire [N_COLS*32-1:0] wr_data_pad = {{(N_COLS*32 - WIDTH > 0 ? N_COLS*32 - WIDTH : 1){1'b0}}, wr_data};
    wire [N_COLS*32-1:0] rd_dout_grid [N_ROWS];
    logic [$clog2(N_ROWS > 1 ? N_ROWS : 2)-1:0] rd_row_sel_q;

    genvar gr, gc;
    generate
        for (gr = 0; gr < N_ROWS; gr++) begin : gen_sram_row
            wire row_wr_sel = wr_en && ((N_ROWS == 1) ? 1'b1 : (wr_addr[ADDR_W-1:9] == gr[ADDR_W-10:0]));
            wire row_rd_sel = rd_en && ((N_ROWS == 1) ? 1'b1 : (rd_addr[ADDR_W-1:9] == gr[ADDR_W-10:0]));
            wire [8:0] local_wr_addr = (DEPTH < 512) ? {{(9-ADDR_W){1'b0}}, wr_addr} : wr_addr[8:0];
            wire [8:0] local_rd_addr = (DEPTH < 512) ? {{(9-ADDR_W){1'b0}}, rd_addr} : rd_addr[8:0];

            for (gc = 0; gc < N_COLS; gc++) begin : gen_sram_col
                sky130_sram_2kbyte_1rw1r_32x512_8 u_sky130_sram (
                    .clk0   (clk),
                    .csb0   (~row_wr_sel),   // Active-low chip select (Port 0: Write)
                    .web0   (~row_wr_sel),   // Active-low write enable
                    .wmask0 (4'b1111),
                    .addr0  (local_wr_addr),
                    .din0   (wr_data_pad[gc*32 +: 32]),
                    .dout0  (),
                    .clk1   (clk),
                    .csb1   (~row_rd_sel),   // Active-low chip select (Port 1: Read)
                    .addr1  (local_rd_addr),
                    .dout1  (rd_dout_grid[gr][gc*32 +: 32])
                );
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rd_en) begin
            if (N_ROWS > 1)
                rd_row_sel_q <= rd_addr[ADDR_W-1:9];
            else
                rd_row_sel_q <= '0;
        end
    end

    assign rd_data = rd_dout_grid[rd_row_sel_q][WIDTH-1:0];

`else
    // -------------------------------------------------------------------------
    // Synthesizable Behavioral / FPGA BRAM Model (Yosys / Vivado / Verilator)
    // Write-first bypass if reading & writing identical address on same edge
    // -------------------------------------------------------------------------
    (* ram_style = "block" *) logic [WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
        if (rd_en) begin
            if (wr_en && (wr_addr == rd_addr))
                rd_data <= wr_data;
            else
                rd_data <= mem[rd_addr];
        end
    end
`endif

endmodule

`default_nettype wire
