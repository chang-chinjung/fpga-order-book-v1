`timescale 1ns / 1ps

// Simple dual-port BRAM with 2-cycle read latency (built-in output register).
// - Simulation: behavioral read-first RAM + output register stage.
// - ECP5 Synthesis (`SYNTHESIS`): native DP16KD with REGMODE_B="OUTREG",
//   cutting BRAM clk-to-q from 5.83 ns (NOREG) to ~1.1 ns for >=120 MHz timing.
module bram_sdp #(
    parameter int DEPTH = 1024,
    parameter int WIDTH = 16,
    parameter int AW    = (DEPTH <= 2) ? 1 : $clog2(DEPTH)
) (
    input  logic             clk,
    input  logic             we,
    input  logic [AW-1:0]    waddr,
    input  logic [WIDTH-1:0] wdata,
    input  logic [AW-1:0]    raddr,
    output logic [WIDTH-1:0] rdata
);

`ifdef SYNTHESIS
    generate
        if (DEPTH == 8192) begin : g_8k
            localparam int NBLK = (WIDTH + 1) / 2;
            for (genvar i = 0; i < NBLK; i++) begin : g_blk
                localparam int B0 = 2 * i;
                localparam int B1 = 2 * i + 1;
                wire d0 = wdata[B0];
                wire d1 = (B1 < WIDTH) ? wdata[B1] : 1'b0;
                wire q0, q1;

                DP16KD #(
                    .DATA_WIDTH_A(2),
                    .DATA_WIDTH_B(2),
                    .REGMODE_A("NOREG"),
                    .REGMODE_B("OUTREG"),
                    .RESETMODE("SYNC"),
                    .ASYNC_RESET_RELEASE("SYNC"),
                    .CSDECODE_A("0b000"),
                    .CSDECODE_B("0b000"),
                    .CLKAMUX("CLKA"),
                    .CLKBMUX("CLKB"),
                    .GSR("AUTO")
                ) u_dp (
                    .CLKA(clk), .WEA(we),   .CEA(1'b1), .OCEA(1'b0), .RSTA(1'b0),
                    .CSA0(1'b0), .CSA1(1'b0), .CSA2(1'b0),
                    .ADA0(1'b0),
                    .ADA1(waddr[0]),  .ADA2(waddr[1]),  .ADA3(waddr[2]),
                    .ADA4(waddr[3]),  .ADA5(waddr[4]),  .ADA6(waddr[5]),
                    .ADA7(waddr[6]),  .ADA8(waddr[7]),  .ADA9(waddr[8]),
                    .ADA10(waddr[9]), .ADA11(waddr[10]), .ADA12(waddr[11]),
                    .ADA13(waddr[12]),
                    .DIA0(d0), .DIA1(d1),
                    .CLKB(clk), .WEB(1'b0), .CEB(1'b1), .OCEB(1'b1), .RSTB(1'b0),
                    .CSB0(1'b0), .CSB1(1'b0), .CSB2(1'b0),
                    .ADB0(1'b0),
                    .ADB1(raddr[0]),  .ADB2(raddr[1]),  .ADB3(raddr[2]),
                    .ADB4(raddr[3]),  .ADB5(raddr[4]),  .ADB6(raddr[5]),
                    .ADB7(raddr[6]),  .ADB8(raddr[7]),  .ADB9(raddr[8]),
                    .ADB10(raddr[9]), .ADB11(raddr[10]), .ADB12(raddr[11]),
                    .ADB13(raddr[12]),
                    .DOB0(q0), .DOB1(q1)
                );

                assign rdata[B0] = q0;
                if (B1 < WIDTH) begin : g_b1
                    assign rdata[B1] = q1;
                end
            end
        end else begin : g_1k
            // 1024-deep, WIDTH <= 18 fits in a single DP16KD (1Kx18)
            wire [17:0] di_pad = {{(18 - WIDTH){1'b0}}, wdata};
            wire [17:0] do_raw;

            DP16KD #(
                .DATA_WIDTH_A(18),
                .DATA_WIDTH_B(18),
                .REGMODE_A("NOREG"),
                .REGMODE_B("OUTREG"),
                .RESETMODE("SYNC"),
                .ASYNC_RESET_RELEASE("SYNC"),
                .CSDECODE_A("0b000"),
                .CSDECODE_B("0b000"),
                .CLKAMUX("CLKA"),
                .CLKBMUX("CLKB"),
                .GSR("AUTO")
            ) u_dp (
                .CLKA(clk), .WEA(1'b1), .CEA(1'b1), .OCEA(1'b0), .RSTA(1'b0),
                .CSA0(1'b0), .CSA1(1'b0), .CSA2(1'b0),
                .ADA0(we), .ADA1(we), .ADA2(1'b0), .ADA3(1'b0),
                .ADA4(waddr[0]), .ADA5(waddr[1]), .ADA6(waddr[2]), .ADA7(waddr[3]),
                .ADA8(waddr[4]), .ADA9(waddr[5]), .ADA10(waddr[6]), .ADA11(waddr[7]),
                .ADA12(waddr[8]), .ADA13(waddr[9]),
                .DIA0(di_pad[0]),   .DIA1(di_pad[1]),   .DIA2(di_pad[2]),
                .DIA3(di_pad[3]),   .DIA4(di_pad[4]),   .DIA5(di_pad[5]),
                .DIA6(di_pad[6]),   .DIA7(di_pad[7]),   .DIA8(di_pad[8]),
                .DIA9(di_pad[9]),   .DIA10(di_pad[10]), .DIA11(di_pad[11]),
                .DIA12(di_pad[12]), .DIA13(di_pad[13]), .DIA14(di_pad[14]),
                .DIA15(di_pad[15]), .DIA16(di_pad[16]), .DIA17(di_pad[17]),
                .CLKB(clk), .WEB(1'b0), .CEB(1'b1), .OCEB(1'b1), .RSTB(1'b0),
                .CSB0(1'b0), .CSB1(1'b0), .CSB2(1'b0),
                .ADB0(1'b0), .ADB1(1'b0), .ADB2(1'b0), .ADB3(1'b0),
                .ADB4(raddr[0]), .ADB5(raddr[1]), .ADB6(raddr[2]), .ADB7(raddr[3]),
                .ADB8(raddr[4]), .ADB9(raddr[5]), .ADB10(raddr[6]), .ADB11(raddr[7]),
                .ADB12(raddr[8]), .ADB13(raddr[9]),
                .DOB0(do_raw[0]),   .DOB1(do_raw[1]),   .DOB2(do_raw[2]),
                .DOB3(do_raw[3]),   .DOB4(do_raw[4]),   .DOB5(do_raw[5]),
                .DOB6(do_raw[6]),   .DOB7(do_raw[7]),   .DOB8(do_raw[8]),
                .DOB9(do_raw[9]),   .DOB10(do_raw[10]), .DOB11(do_raw[11]),
                .DOB12(do_raw[12]), .DOB13(do_raw[13]), .DOB14(do_raw[14]),
                .DOB15(do_raw[15]), .DOB16(do_raw[16]), .DOB17(do_raw[17])
            );

            assign rdata = do_raw[WIDTH-1:0];
        end
    endgenerate
`else
    logic [WIDTH-1:0] mem [DEPTH];
    logic [WIDTH-1:0] rd_q;

    always_ff @(posedge clk) begin
        rd_q  <= mem[raddr];
        rdata <= rd_q;
        if (we) mem[waddr] <= wdata;
    end
`endif

endmodule
