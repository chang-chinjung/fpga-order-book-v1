`timescale 1ns / 1ps

// Thin ECP5 synthesis top for order_book_v1 (SYMBOLS=2, USE_AXIS=1).
// Keeps 100% of RTL logic, BRAMs (76 DP16KD <= 80), and all 13 counters alive
// within the LFE5U-85F-CABGA756 365-pin user I/O budget (274 pins total).
module order_book_v1_top #(
    parameter int LEVELS     = 1024,
    parameter int MAX_ORDERS = 8192,
    parameter int QTY_W      = 16,
    parameter int OID_W      = 16,
    parameter int CNT_W      = 16,
    parameter int SYMBOLS    = 2,
    parameter int SW         = (SYMBOLS <= 1) ? 1 : $clog2(SYMBOLS),
    parameter int LW         = (LEVELS <= 2) ? 1 : $clog2(LEVELS)
) (
    input  logic             clk,
    input  logic             rst_n,

    // AXI4-Stream command slave
    input  logic             s_axis_cmd_tvalid,
    output logic             s_axis_cmd_tready,
    input  logic [63:0]      s_axis_cmd_tdata,

    // AXI4-Stream best-price master ([63:61]=sym, [53:0]=best)
    output logic             s_axis_best_tvalid,
    input  logic             s_axis_best_tready,
    output logic [63:0]      s_axis_best_tdata,

    // Snapshot slave
    input  logic             snapshot_valid,
    output logic             snapshot_ready,
    input  logic [63:0]      snapshot_data,

    // Query interface
    input  logic             qry_valid,
    output logic             qry_ready,
    input  logic [SW-1:0]    qry_sym,
    input  logic [OID_W-1:0] qry_oid,
    output logic             qry_found,
    output logic [LW-1:0]    qry_level,
    output logic [QTY_W-1:0] qry_qty,
    output logic [5:0]       qry_pos,

    // Status & multiplexed counter readout (preserves all 13 counters in P&R)
    output logic             stale,
    output logic             snapshot_error,
    input  logic [3:0]       cnt_sel,
    output logic [CNT_W-1:0] cnt_val
);

    logic                        cmd_ready_nc;
    logic [SYMBOLS-1:0]          bid_valid_nc, ask_valid_nc;
    logic [SYMBOLS-1:0][LW-1:0]  best_bid_nc, best_ask_nc;
    logic [SYMBOLS-1:0][QTY_W-1:0] best_bid_qty_nc, best_ask_qty_nc;

    logic [CNT_W-1:0] cnt_add, cnt_cancel, cnt_reduce, cnt_trade;
    logic [CNT_W-1:0] cnt_drop_dup, cnt_drop_unknown, cnt_drop_full, cnt_drop_bad, cnt_sat;
    logic [CNT_W-1:0] cnt_seq_gap, cnt_dup_seq, cnt_drop_stale, cnt_drop_load;

    wire _unused_nc = &{1'b0, cmd_ready_nc, bid_valid_nc, ask_valid_nc,
                        best_bid_nc, best_ask_nc, best_bid_qty_nc, best_ask_qty_nc};

    order_book_v1 #(
        .LEVELS    (LEVELS),
        .MAX_ORDERS(MAX_ORDERS),
        .QTY_W     (QTY_W),
        .OID_W     (OID_W),
        .CNT_W     (CNT_W),
        .USE_AXIS  (1'b1),
        .SYMBOLS   (SYMBOLS)
    ) u_core (
        .clk               (clk),
        .rst_n             (rst_n),
        .cmd_valid         (1'b0),
        .cmd_ready         (cmd_ready_nc),
        .cmd_op            (2'd0),
        .cmd_side          (1'b0),
        .cmd_oid           ('0),
        .cmd_level         ('0),
        .cmd_qty           ('0),
        .cmd_sym           ('0),
        .cmd_seq_en        (1'b0),
        .cmd_seq           ('0),
        .s_axis_cmd_tvalid (s_axis_cmd_tvalid),
        .s_axis_cmd_tready (s_axis_cmd_tready),
        .s_axis_cmd_tdata  (s_axis_cmd_tdata),
        .s_axis_best_tvalid(s_axis_best_tvalid),
        .s_axis_best_tready(s_axis_best_tready),
        .s_axis_best_tdata (s_axis_best_tdata),
        .qry_valid         (qry_valid),
        .qry_ready         (qry_ready),
        .qry_sym           (qry_sym),
        .qry_oid           (qry_oid),
        .qry_found         (qry_found),
        .qry_level         (qry_level),
        .qry_qty           (qry_qty),
        .qry_pos           (qry_pos),
        .bid_valid         (bid_valid_nc),
        .best_bid          (best_bid_nc),
        .best_bid_qty      (best_bid_qty_nc),
        .ask_valid         (ask_valid_nc),
        .best_ask          (best_ask_nc),
        .best_ask_qty      (best_ask_qty_nc),
        .cnt_add           (cnt_add),
        .cnt_cancel        (cnt_cancel),
        .cnt_reduce        (cnt_reduce),
        .cnt_trade         (cnt_trade),
        .cnt_drop_dup      (cnt_drop_dup),
        .cnt_drop_unknown  (cnt_drop_unknown),
        .cnt_drop_full     (cnt_drop_full),
        .cnt_drop_bad      (cnt_drop_bad),
        .cnt_sat           (cnt_sat),
        .snapshot_valid    (snapshot_valid),
        .snapshot_ready    (snapshot_ready),
        .snapshot_data     (snapshot_data),
        .stale             (stale),
        .snapshot_error    (snapshot_error),
        .cnt_seq_gap       (cnt_seq_gap),
        .cnt_dup_seq       (cnt_dup_seq),
        .cnt_drop_stale    (cnt_drop_stale),
        .cnt_drop_load     (cnt_drop_load)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_val <= '0;
        end else begin
            case (cnt_sel)
                4'd0:    cnt_val <= cnt_add;
                4'd1:    cnt_val <= cnt_cancel;
                4'd2:    cnt_val <= cnt_reduce;
                4'd3:    cnt_val <= cnt_trade;
                4'd4:    cnt_val <= cnt_drop_dup;
                4'd5:    cnt_val <= cnt_drop_unknown;
                4'd6:    cnt_val <= cnt_drop_full;
                4'd7:    cnt_val <= cnt_drop_bad;
                4'd8:    cnt_val <= cnt_sat;
                4'd9:    cnt_val <= cnt_seq_gap;
                4'd10:   cnt_val <= cnt_dup_seq;
                4'd11:   cnt_val <= cnt_drop_stale;
                4'd12:   cnt_val <= cnt_drop_load;
                default: cnt_val <= '0;
            endcase
        end
    end

endmodule
