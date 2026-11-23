`timescale 1ns / 1ps

// Occupancy bitmap with 2-stage balanced tree priority encoding (1,024 levels).
//
// Balanced for >=100 MHz on ECP5:
//   Cycle T  : Direct bit write into words[upd_word][upd_bit] (no 64:1 RMW mux).
//   Cycle T+1: Per-group (16 groups of 4 x 16-bit words) reduction & 4:1 mux registered
//              -> g_any_r[15:0], g_hi_sel_r[16], g_hi_bit_r[16], g_lo_sel_r[16], g_lo_bit_r[16].
//   Cycle T+2: 16-bit hi16/lo16 + 16:1 mux -> hi_valid/hi_index, lo_valid/lo_index.
module bitmap_best #(
    parameter int LEVELS  = 1024,
    parameter int GROUP   = 16,
    parameter bit FIND_HI = 1'b1,
    parameter int W       = LEVELS / GROUP,
    parameter int LW      = (LEVELS <= 2) ? 1 : $clog2(LEVELS),
    parameter int WW      = (W <= 2) ? 1 : $clog2(W),
    parameter int GW      = (GROUP <= 2) ? 1 : $clog2(GROUP)
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          clear,

    input  logic          upd_valid,
    input  logic          upd_set,     // 1 = level became occupied, 0 = level emptied
    input  logic [LW-1:0] upd_index,

    output logic          hi_valid,
    output logic [LW-1:0] hi_index,
    output logic          lo_valid,
    output logic [LW-1:0] lo_index
);

    localparam int NG = W / 4; // 16 groups of 4 words

    // ---------------- Cycle T: direct bit storage update ----------------
    // Explicit per-word/per-bit decode avoids carry-chain comparators and high fanout.
    logic [GROUP-1:0] words [W];

    wire [WW-1:0] upd_word = upd_index[LW-1:GW];
    wire [GW-1:0] upd_bit  = upd_index[GW-1:0];

    wire [GROUP-1:0] bit_oh = {{(GROUP-1){1'b0}}, 1'b1} << upd_bit;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int w = 0; w < W; w++) words[w] <= '0;
        end else if (clear) begin
            for (int w = 0; w < W; w++) words[w] <= '0;
        end else if (upd_valid) begin
            for (int w = 0; w < W; w++) begin
                if (upd_word == WW'(w)) begin
                    for (int b = 0; b < GROUP; b++) begin
                        if (bit_oh[b]) words[w][b] <= upd_set;
                    end
                end
            end
        end
    end

    // ---------------- priority helpers (tree, not a chain) ----------------
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [1:0] hi2(input logic [3:0] v);
        if (v[3])      hi2 = 2'd3;
        else if (v[2]) hi2 = 2'd2;
        else if (v[1]) hi2 = 2'd1;
        else           hi2 = 2'd0;
    endfunction

    function automatic [1:0] lo2(input logic [3:0] v);
        if (v[0])      lo2 = 2'd0;
        else if (v[1]) lo2 = 2'd1;
        else if (v[2]) lo2 = 2'd2;
        else           lo2 = 2'd3;
    endfunction

    function automatic [3:0] hi16(input logic [15:0] v);
        if (v[15:12] != '0)      hi16 = {2'd3, hi2(v[15:12])};
        else if (v[11:8] != '0)  hi16 = {2'd2, hi2(v[11:8])};
        else if (v[7:4] != '0)   hi16 = {2'd1, hi2(v[7:4])};
        else                     hi16 = {2'd0, hi2(v[3:0])};
    endfunction

    function automatic [3:0] lo16(input logic [15:0] v);
        if (v[3:0] != '0)        lo16 = {2'd0, lo2(v[3:0])};
        else if (v[7:4] != '0)   lo16 = {2'd1, lo2(v[7:4])};
        else if (v[11:8] != '0)  lo16 = {2'd2, lo2(v[11:8])};
        else                     lo16 = {2'd3, lo2(v[15:12])};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // ---------------- Cycle T+1: 16 groups of 4 words (registered) ----------------
    logic [NG-1:0] g_any_r;
    logic [1:0]    g_sel_r [NG];
    logic [GW-1:0] g_bit_r [NG];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_any_r <= '0;
            for (int g = 0; g < NG; g++) begin
                g_sel_r[g] <= 2'd0;
                g_bit_r[g] <= '0;
            end
        end else begin
            for (int g = 0; g < NG; g++) begin
                logic [3:0]    s;
                logic [1:0]    sel;
                logic [GW-1:0] wb [4];

                for (int k = 0; k < 4; k++) begin
                    s[k]  = |words[g*4 + k];
                    wb[k] = FIND_HI ? hi16(words[g*4 + k]) : lo16(words[g*4 + k]);
                end
                sel = FIND_HI ? hi2(s) : lo2(s);

                g_any_r[g] <= |s;
                g_sel_r[g] <= sel;
                g_bit_r[g] <= wb[sel];
            end
        end
    end

    // ---------------- Cycle T+2: 2-level 4x4 parallel tree ----------------
    // Splitting the 16-group reduction into 4 parallel quadrants of 4 groups cuts
    // the combinational path from (hi16 + 16:1 mux) to (hi2 + 4:1 mux + 4:1 mux).
    logic [3:0] q_any;
    logic [1:0] q_grp_lo [4];
    logic [1:0] q_sel    [4];
    logic [GW-1:0] q_bit [4];

    always_comb begin
        for (int q = 0; q < 4; q++) begin
            logic [3:0] qv;
            logic [1:0] qs;
            qv = g_any_r[q*4 +: 4];
            qs = FIND_HI ? hi2(qv) : lo2(qv);
            q_any[q]    = |qv;
            q_grp_lo[q] = qs;
            case (qs)
                2'd0: begin q_sel[q] = g_sel_r[q*4 + 0]; q_bit[q] = g_bit_r[q*4 + 0]; end
                2'd1: begin q_sel[q] = g_sel_r[q*4 + 1]; q_bit[q] = g_bit_r[q*4 + 1]; end
                2'd2: begin q_sel[q] = g_sel_r[q*4 + 2]; q_bit[q] = g_bit_r[q*4 + 2]; end
                default: begin q_sel[q] = g_sel_r[q*4 + 3]; q_bit[q] = g_bit_r[q*4 + 3]; end
            endcase
        end
    end

    wire [1:0]    best_q   = FIND_HI ? hi2(q_any) : lo2(q_any);
    wire          best_val = |q_any;
    wire [LW-1:0] best_idx = {best_q, q_grp_lo[best_q], q_sel[best_q], q_bit[best_q]};

    assign hi_valid = FIND_HI ? best_val : 1'b0;
    assign lo_valid = FIND_HI ? 1'b0     : best_val;
    assign hi_index = FIND_HI ? best_idx : '0;
    assign lo_index = FIND_HI ? '0       : best_idx;

endmodule
