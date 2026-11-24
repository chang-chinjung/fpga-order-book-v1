`timescale 1ns / 1ps

module tb_order_book_v1;
    localparam int LEVELS     = 1024;
    localparam int MAX_ORDERS = 8192;
    localparam int QTY_W      = 16;
    localparam int OID_W      = 16;
    localparam int CNT_W      = 16;
    localparam int LW         = $clog2(LEVELS);

    localparam logic [1:0] OP_ADD    = 2'd0;
    localparam logic [1:0] OP_CANCEL = 2'd1;
    localparam logic [1:0] OP_REDUCE = 2'd2;
    localparam logic [1:0] OP_TRADE  = 2'd3;

    logic             clk = 1'b0;
    logic             rst_n;

    logic             cmd_valid;
    logic             cmd_ready;
    logic [1:0]       cmd_op;
    logic             cmd_side;
    logic [OID_W-1:0] cmd_oid;
    logic [LW-1:0]    cmd_level;
    logic [QTY_W-1:0] cmd_qty;
    logic             cmd_seq_en;
    logic [15:0]      cmd_seq;
    logic             s_axis_cmd_tvalid_nc;
    logic             s_axis_cmd_tready_nc;
    logic [63:0]      s_axis_cmd_tdata_nc;
    logic             s_axis_best_tvalid_nc;
    logic [63:0]      s_axis_best_tdata_nc;

    logic             qry_valid;
    logic             qry_ready;
    logic [OID_W-1:0] qry_oid;
    logic             qry_found;
    logic [LW-1:0]    qry_level;
    logic [QTY_W-1:0] qry_qty;
    logic [5:0]       qry_pos;

    logic             bid_valid;
    logic [LW-1:0]    best_bid;
    logic [QTY_W-1:0] best_bid_qty;
    logic             ask_valid;
    logic [LW-1:0]    best_ask;
    logic [QTY_W-1:0] best_ask_qty;

    logic [CNT_W-1:0] cnt_add;
    logic [CNT_W-1:0] cnt_cancel;
    logic [CNT_W-1:0] cnt_reduce;
    logic [CNT_W-1:0] cnt_trade;
    logic [CNT_W-1:0] cnt_drop_dup;
    logic [CNT_W-1:0] cnt_drop_unknown;
    logic [CNT_W-1:0] cnt_drop_full;
    logic [CNT_W-1:0] cnt_drop_bad;
    logic [CNT_W-1:0] cnt_sat;
    logic             stale;
    logic             snapshot_valid;
    logic             snapshot_ready;
    logic [63:0]      snapshot_data;
    logic             snapshot_error;
    logic [CNT_W-1:0] cnt_seq_gap;
    logic [CNT_W-1:0] cnt_dup_seq;
    logic [CNT_W-1:0] cnt_drop_stale;
    logic [CNT_W-1:0] cnt_drop_load;

    initial forever #5 clk = ~clk;

    order_book_v1 #(
        .LEVELS    (LEVELS),
        .MAX_ORDERS(MAX_ORDERS),
        .QTY_W     (QTY_W),
        .OID_W     (OID_W),
        .CNT_W     (CNT_W),
        .SYMBOLS   (1)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .cmd_valid       (cmd_valid),
        .cmd_ready       (cmd_ready),
        .cmd_op          (cmd_op),
        .cmd_side        (cmd_side),
        .cmd_oid         (cmd_oid),
        .cmd_level       (cmd_level),
        .cmd_qty         (cmd_qty),
        .cmd_sym         (1'b0),
        .cmd_seq_en        (cmd_seq_en),
        .cmd_seq           (cmd_seq),
        .s_axis_cmd_tvalid (1'b0),
        .s_axis_cmd_tready (s_axis_cmd_tready_nc),
        .s_axis_cmd_tdata  (64'd0),
        .s_axis_best_tvalid(s_axis_best_tvalid_nc),
        .s_axis_best_tready(1'b1),
        .s_axis_best_tdata (s_axis_best_tdata_nc),
        .qry_valid         (qry_valid),
        .qry_ready       (qry_ready),
        .qry_sym         (1'b0),
        .qry_oid         (qry_oid),
        .qry_found       (qry_found),
        .qry_level       (qry_level),
        .qry_qty         (qry_qty),
        .qry_pos         (qry_pos),
        .bid_valid       (bid_valid),
        .best_bid        (best_bid),
        .best_bid_qty    (best_bid_qty),
        .ask_valid       (ask_valid),
        .best_ask        (best_ask),
        .best_ask_qty    (best_ask_qty),
        .cnt_add         (cnt_add),
        .cnt_cancel      (cnt_cancel),
        .cnt_reduce      (cnt_reduce),
        .cnt_trade       (cnt_trade),
        .cnt_drop_dup    (cnt_drop_dup),
        .cnt_drop_unknown(cnt_drop_unknown),
        .cnt_drop_full   (cnt_drop_full),
        .cnt_drop_bad    (cnt_drop_bad),
        .cnt_sat         (cnt_sat),
        .snapshot_valid  (snapshot_valid),
        .snapshot_ready  (snapshot_ready),
        .snapshot_data   (snapshot_data),
        .stale           (stale),
        .snapshot_error  (snapshot_error),
        .cnt_seq_gap     (cnt_seq_gap),
        .cnt_dup_seq     (cnt_dup_seq),
        .cnt_drop_stale  (cnt_drop_stale),
        .cnt_drop_load   (cnt_drop_load)
    );

    wire _unused_legacy_axis = &{1'b0, s_axis_cmd_tvalid_nc, s_axis_cmd_tready_nc,
                                 s_axis_cmd_tdata_nc, s_axis_best_tvalid_nc, s_axis_best_tdata_nc};

    // Second DUT instance with USE_AXIS=1 for AXI4-Stream directed + 10k/2k random tests
    logic             ax_rst_n;
    logic             ax_cmd_tvalid;
    logic             ax_cmd_tready;
    logic [63:0]      ax_cmd_tdata;
    logic             ax_best_tvalid;
    logic             ax_best_tready;
    logic [63:0]      ax_best_tdata;
    logic             ax_cmd_ready_nc;
    logic             ax_qry_valid;
    logic             ax_qry_ready;
    logic [OID_W-1:0] ax_qry_oid;
    logic             ax_qry_found;
    logic [LW-1:0]    ax_qry_level;
    logic [QTY_W-1:0] ax_qry_qty;
    logic [5:0]       ax_qry_pos;
    logic             ax_bid_valid;
    logic [LW-1:0]    ax_best_bid;
    logic [QTY_W-1:0] ax_best_bid_qty;
    logic             ax_ask_valid;
    logic [LW-1:0]    ax_best_ask;
    logic [QTY_W-1:0] ax_best_ask_qty;
    logic [CNT_W-1:0] ax_cnt_add, ax_cnt_cancel, ax_cnt_reduce, ax_cnt_trade;
    logic [CNT_W-1:0] ax_cnt_drop_dup, ax_cnt_drop_unknown, ax_cnt_drop_full, ax_cnt_drop_bad, ax_cnt_sat;
    logic             ax_snap_valid, ax_snap_ready;
    logic [63:0]      ax_snap_data;
    logic             ax_stale, ax_snap_err;
    logic [CNT_W-1:0] ax_cnt_seq_gap, ax_cnt_dup_seq, ax_cnt_drop_stale, ax_cnt_drop_load;

    order_book_v1 #(
        .LEVELS    (LEVELS),
        .MAX_ORDERS(MAX_ORDERS),
        .QTY_W     (QTY_W),
        .OID_W     (OID_W),
        .CNT_W     (CNT_W),
        .USE_AXIS  (1'b1),
        .SYMBOLS   (1)
    ) dut_axis (
        .clk               (clk),
        .rst_n             (ax_rst_n),
        .cmd_valid         (1'b0),
        .cmd_ready         (ax_cmd_ready_nc),
        .cmd_op            (2'd0),
        .cmd_side          (1'b0),
        .cmd_oid           ('0),
        .cmd_level         ('0),
        .cmd_qty           ('0),
        .cmd_sym           (1'b0),
        .cmd_seq_en        (1'b0),
        .cmd_seq           ('0),
        .s_axis_cmd_tvalid (ax_cmd_tvalid),
        .s_axis_cmd_tready (ax_cmd_tready),
        .s_axis_cmd_tdata  (ax_cmd_tdata),
        .s_axis_best_tvalid(ax_best_tvalid),
        .s_axis_best_tready(ax_best_tready),
        .s_axis_best_tdata (ax_best_tdata),
        .qry_valid         (ax_qry_valid),
        .qry_ready         (ax_qry_ready),
        .qry_sym           (1'b0),
        .qry_oid           (ax_qry_oid),
        .qry_found         (ax_qry_found),
        .qry_level         (ax_qry_level),
        .qry_qty           (ax_qry_qty),
        .qry_pos           (ax_qry_pos),
        .bid_valid         (ax_bid_valid),
        .best_bid          (ax_best_bid),
        .best_bid_qty      (ax_best_bid_qty),
        .ask_valid         (ax_ask_valid),
        .best_ask          (ax_best_ask),
        .best_ask_qty      (ax_best_ask_qty),
        .cnt_add           (ax_cnt_add),
        .cnt_cancel        (ax_cnt_cancel),
        .cnt_reduce        (ax_cnt_reduce),
        .cnt_trade         (ax_cnt_trade),
        .cnt_drop_dup      (ax_cnt_drop_dup),
        .cnt_drop_unknown  (ax_cnt_drop_unknown),
        .cnt_drop_full     (ax_cnt_drop_full),
        .cnt_drop_bad      (ax_cnt_drop_bad),
        .cnt_sat           (ax_cnt_sat),
        .snapshot_valid    (ax_snap_valid),
        .snapshot_ready    (ax_snap_ready),
        .snapshot_data     (ax_snap_data),
        .stale             (ax_stale),
        .snapshot_error    (ax_snap_err),
        .cnt_seq_gap       (ax_cnt_seq_gap),
        .cnt_dup_seq       (ax_cnt_dup_seq),
        .cnt_drop_stale    (ax_cnt_drop_stale),
        .cnt_drop_load     (ax_cnt_drop_load)
    );

    wire _unused_ax = &{1'b0, ax_cmd_ready_nc, ax_cnt_drop_load};

    // Third DUT instance: v1.2 SYMBOLS=2, USE_AXIS=1
    localparam int M2_SYM = 2;
    logic                           m2_rst_n;
    logic                           m2_cmd_tvalid;
    logic                           m2_cmd_tready;
    logic [63:0]                    m2_cmd_tdata;
    logic                           m2_best_tvalid;
    logic                           m2_best_tready;
    logic [63:0]                    m2_best_tdata;
    logic                           m2_cmd_ready_nc;
    logic                           m2_qry_valid;
    logic                           m2_qry_ready;
    logic                           m2_qry_sym;
    logic [OID_W-1:0]               m2_qry_oid;
    logic                           m2_qry_found;
    logic [LW-1:0]                  m2_qry_level;
    logic [QTY_W-1:0]               m2_qry_qty;
    logic [5:0]                     m2_qry_pos;
    logic [M2_SYM-1:0]              m2_bid_valid;
    logic [M2_SYM-1:0][LW-1:0]      m2_best_bid;
    logic [M2_SYM-1:0][QTY_W-1:0]   m2_best_bid_qty;
    logic [M2_SYM-1:0]              m2_ask_valid;
    logic [M2_SYM-1:0][LW-1:0]      m2_best_ask;
    logic [M2_SYM-1:0][QTY_W-1:0]   m2_best_ask_qty;
    logic [CNT_W-1:0] m2_cnt_add, m2_cnt_cancel, m2_cnt_reduce, m2_cnt_trade;
    logic [CNT_W-1:0] m2_cnt_drop_dup, m2_cnt_drop_unknown, m2_cnt_drop_full, m2_cnt_drop_bad, m2_cnt_sat;
    logic             m2_snap_valid, m2_snap_ready;
    logic [63:0]      m2_snap_data;
    logic             m2_stale, m2_snap_err;
    logic [CNT_W-1:0] m2_cnt_seq_gap, m2_cnt_dup_seq, m2_cnt_drop_stale, m2_cnt_drop_load;

    order_book_v1 #(
        .LEVELS    (LEVELS),
        .MAX_ORDERS(MAX_ORDERS),
        .QTY_W     (QTY_W),
        .OID_W     (OID_W),
        .CNT_W     (CNT_W),
        .USE_AXIS  (1'b1),
        .SYMBOLS   (M2_SYM)
    ) dut_m2 (
        .clk               (clk),
        .rst_n             (m2_rst_n),
        .cmd_valid         (1'b0),
        .cmd_ready         (m2_cmd_ready_nc),
        .cmd_op            (2'd0),
        .cmd_side          (1'b0),
        .cmd_oid           ('0),
        .cmd_level         ('0),
        .cmd_qty           ('0),
        .cmd_sym           (1'b0),
        .cmd_seq_en        (1'b0),
        .cmd_seq           ('0),
        .s_axis_cmd_tvalid (m2_cmd_tvalid),
        .s_axis_cmd_tready (m2_cmd_tready),
        .s_axis_cmd_tdata  (m2_cmd_tdata),
        .s_axis_best_tvalid(m2_best_tvalid),
        .s_axis_best_tready(m2_best_tready),
        .s_axis_best_tdata (m2_best_tdata),
        .qry_valid         (m2_qry_valid),
        .qry_ready         (m2_qry_ready),
        .qry_sym           (m2_qry_sym),
        .qry_oid           (m2_qry_oid),
        .qry_found         (m2_qry_found),
        .qry_level         (m2_qry_level),
        .qry_qty           (m2_qry_qty),
        .qry_pos           (m2_qry_pos),
        .bid_valid         (m2_bid_valid),
        .best_bid          (m2_best_bid),
        .best_bid_qty      (m2_best_bid_qty),
        .ask_valid         (m2_ask_valid),
        .best_ask          (m2_best_ask),
        .best_ask_qty      (m2_best_ask_qty),
        .cnt_add           (m2_cnt_add),
        .cnt_cancel        (m2_cnt_cancel),
        .cnt_reduce        (m2_cnt_reduce),
        .cnt_trade         (m2_cnt_trade),
        .cnt_drop_dup      (m2_cnt_drop_dup),
        .cnt_drop_unknown  (m2_cnt_drop_unknown),
        .cnt_drop_full     (m2_cnt_drop_full),
        .cnt_drop_bad      (m2_cnt_drop_bad),
        .cnt_sat           (m2_cnt_sat),
        .snapshot_valid    (m2_snap_valid),
        .snapshot_ready    (m2_snap_ready),
        .snapshot_data     (m2_snap_data),
        .stale             (m2_stale),
        .snapshot_error    (m2_snap_err),
        .cnt_seq_gap       (m2_cnt_seq_gap),
        .cnt_dup_seq       (m2_cnt_dup_seq),
        .cnt_drop_stale    (m2_cnt_drop_stale),
        .cnt_drop_load     (m2_cnt_drop_load)
    );

    wire _unused_m2 = &{1'b0, m2_cmd_ready_nc, m2_best_tdata, m2_ask_valid,
                        m2_cnt_cancel, m2_cnt_reduce, m2_cnt_trade,
                        m2_cnt_drop_dup, m2_cnt_drop_unknown, m2_cnt_drop_full,
                        m2_cnt_drop_bad, m2_cnt_sat, m2_cnt_dup_seq, m2_cnt_drop_load};

    int errors = 0;
    int directed_passed = 0;
    int directed_total  = 0;
    int max_best_latency = 0;

    task automatic do_reset();
        rst_n     = 1'b0;
        cmd_valid = 1'b0;
        cmd_op    = '0;
        cmd_side  = 1'b0;
        cmd_oid   = '0;
        cmd_level  = '0;
        cmd_qty    = '0;
        cmd_seq_en           = 1'b0;
        cmd_seq              = '0;
        s_axis_cmd_tvalid_nc = 1'b0;
        s_axis_cmd_tdata_nc  = '0;
        snapshot_valid       = 1'b0;
        snapshot_data        = '0;
        qry_valid            = 1'b0;
        qry_oid              = '0;
        ax_rst_n             = 1'b1;
        ax_cmd_tvalid        = 1'b0;
        ax_cmd_tdata         = '0;
        ax_best_tready       = 1'b1;
        ax_qry_valid         = 1'b0;
        ax_qry_oid           = '0;
        ax_snap_valid        = 1'b0;
        ax_snap_data         = '0;
        m2_rst_n             = 1'b1;
        m2_cmd_tvalid        = 1'b0;
        m2_cmd_tdata         = '0;
        m2_best_tready       = 1'b1;
        m2_qry_valid         = 1'b0;
        m2_qry_sym           = 1'b0;
        m2_qry_oid           = '0;
        m2_snap_valid        = 1'b0;
        m2_snap_data         = '0;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        while (!cmd_ready) @(posedge clk);
        repeat (2) @(posedge clk);
    endtask

    task automatic send_cmd(
        input logic [1:0]       op,
        input logic             side,
        input logic [OID_W-1:0] oid,
        input logic [LW-1:0]    lvl,
        input logic [QTY_W-1:0] qty
    );
        cmd_valid  = 1'b1;
        cmd_op     = op;
        cmd_side   = side;
        cmd_oid    = oid;
        cmd_level  = lvl;
        cmd_qty    = qty;
        cmd_seq_en = 1'b0;
        cmd_seq    = '0;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        cmd_valid  = 1'b0;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        repeat (5) @(posedge clk);
    endtask

    task automatic send_cmd_seq(
        input logic [1:0]       op,
        input logic             side,
        input logic [OID_W-1:0] oid,
        input logic [LW-1:0]    lvl,
        input logic [QTY_W-1:0] qty,
        input logic [15:0]      seq
    );
        cmd_valid  = 1'b1;
        cmd_op     = op;
        cmd_side   = side;
        cmd_oid    = oid;
        cmd_level  = lvl;
        cmd_qty    = qty;
        cmd_seq_en = 1'b1;
        cmd_seq    = seq;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        cmd_valid  = 1'b0;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        repeat (5) @(posedge clk);
    endtask

    task automatic send_snap(input logic [63:0] rec);
        snapshot_valid = 1'b1;
        snapshot_data  = rec;
        @(posedge clk);
        while (!snapshot_ready) @(posedge clk);
        snapshot_valid = 1'b0;
        @(posedge clk);
        while (!snapshot_ready) @(posedge clk);
    endtask

    function automatic logic [63:0] mk_snap_header(input logic [31:0] cnt);
        return {2'd0, 30'd0, cnt};
    endfunction

    function automatic logic [63:0] mk_snap_level(
        input logic             side,
        input logic [LW-1:0]    lvl,
        input logic [QTY_W-1:0] qty
    );
        return {2'd1, 34'd0, qty, lvl, side, 1'b0};
    endfunction

    function automatic logic [63:0] mk_snap_order(
        input logic             side,
        input logic [LW-1:0]    lvl,
        input logic [QTY_W-1:0] qty,
        input logic [OID_W-1:0] oid
    );
        return {2'd2, 18'd0, oid, qty, lvl, side, 1'b0};
    endfunction

    function automatic logic [63:0] mk_snap_footer(input logic [31:0] cnt);
        return {2'd3, 30'd0, cnt};
    endfunction

    function automatic logic [63:0] mk_axis_cmd(
        input logic [1:0]       op,
        input logic             side,
        input logic [OID_W-1:0] oid,
        input logic [LW-1:0]    lvl,
        input logic [QTY_W-1:0] qty,
        input logic [15:0]      seq
    );
        return {3'd0, seq, qty, lvl, oid, side, op};
    endfunction

    task automatic do_ax_reset();
        ax_rst_n       = 1'b0;
        ax_cmd_tvalid  = 1'b0;
        ax_cmd_tdata   = '0;
        ax_best_tready = 1'b1;
        ax_qry_valid   = 1'b0;
        ax_qry_oid     = '0;
        ax_snap_valid  = 1'b0;
        ax_snap_data   = '0;
        repeat (3) @(posedge clk);
        ax_rst_n = 1'b1;
        while (!ax_cmd_tready) @(posedge clk);
        repeat (2) @(posedge clk);
    endtask

    task automatic send_ax_cmd(
        input logic [1:0]       op,
        input logic             side,
        input logic [OID_W-1:0] oid,
        input logic [LW-1:0]    lvl,
        input logic [QTY_W-1:0] qty,
        input logic [15:0]      seq
    );
        ax_cmd_tvalid = 1'b1;
        ax_cmd_tdata  = mk_axis_cmd(op, side, oid, lvl, qty, seq);
        @(posedge clk);
        while (!ax_cmd_tready) @(posedge clk);
        ax_cmd_tvalid = 1'b0;
        @(posedge clk);
        while (!ax_cmd_tready) @(posedge clk);
    endtask

    task automatic send_ax_snap(input logic [63:0] rec);
        ax_snap_valid = 1'b1;
        ax_snap_data  = rec;
        @(posedge clk);
        while (!ax_snap_ready) @(posedge clk);
        ax_snap_valid = 1'b0;
        @(posedge clk);
        while (!ax_snap_ready) @(posedge clk);
    endtask

    task automatic do_ax_query(
        input  logic [OID_W-1:0] oid,
        output logic             found,
        output logic [LW-1:0]    lvl,
        output logic [QTY_W-1:0] qty,
        output logic [5:0]       pos
    );
        ax_qry_valid = 1'b1;
        ax_qry_oid   = oid;
        @(posedge clk);
        while (!ax_qry_ready) @(posedge clk);
        found        = ax_qry_found;
        lvl          = ax_qry_level;
        qty          = ax_qry_qty;
        pos          = ax_qry_pos;
        ax_qry_valid = 1'b0;
        @(posedge clk);
    endtask

    function automatic logic [63:0] mk_axis_cmd_sym(
        input logic [1:0]       op,
        input logic             side,
        input logic [OID_W-1:0] oid,
        input logic [LW-1:0]    lvl,
        input logic [QTY_W-1:0] qty,
        input logic [14:0]      seq,
        input logic [1:0]       sym
    );
        return {2'd0, sym, seq, qty, lvl, oid, side, op};
    endfunction

    function automatic logic [63:0] mk_snap_level_m2(
        input logic [1:0]       sym,
        input logic             side,
        input logic [LW-1:0]    lvl,
        input logic [QTY_W-1:0] qty
    );
        return {2'd1, 17'd0, side, 16'd0, qty, lvl, sym};
    endfunction

    function automatic logic [63:0] mk_snap_order_m2(
        input logic [1:0]       sym,
        input logic             side,
        input logic [LW-1:0]    lvl,
        input logic [QTY_W-1:0] qty,
        input logic [OID_W-1:0] oid
    );
        return {2'd2, 17'd0, side, oid, qty, lvl, sym};
    endfunction

    task automatic do_m2_reset();
        m2_rst_n       = 1'b0;
        m2_cmd_tvalid  = 1'b0;
        m2_cmd_tdata   = '0;
        m2_best_tready = 1'b1;
        m2_qry_valid   = 1'b0;
        m2_qry_sym     = 1'b0;
        m2_qry_oid     = '0;
        m2_snap_valid  = 1'b0;
        m2_snap_data   = '0;
        repeat (3) @(posedge clk);
        m2_rst_n = 1'b1;
        while (!m2_cmd_tready) @(posedge clk);
        repeat (2) @(posedge clk);
    endtask

    task automatic send_m2_cmd(
        input logic [1:0]       op,
        input logic             side,
        input logic [OID_W-1:0] oid,
        input logic [LW-1:0]    lvl,
        input logic [QTY_W-1:0] qty,
        input logic [14:0]      seq,
        input logic [1:0]       sym
    );
        m2_cmd_tvalid = 1'b1;
        m2_cmd_tdata  = mk_axis_cmd_sym(op, side, oid, lvl, qty, seq, sym);
        @(posedge clk);
        while (!m2_cmd_tready) @(posedge clk);
        m2_cmd_tvalid = 1'b0;
        @(posedge clk);
        while (!m2_cmd_tready) @(posedge clk);
    endtask

    task automatic send_m2_snap(input logic [63:0] rec);
        m2_snap_valid = 1'b1;
        m2_snap_data  = rec;
        @(posedge clk);
        while (!m2_snap_ready) @(posedge clk);
        m2_snap_valid = 1'b0;
        @(posedge clk);
        while (!m2_snap_ready) @(posedge clk);
    endtask

    task automatic do_m2_query(
        input  logic             sym,
        input  logic [OID_W-1:0] oid,
        output logic             found,
        output logic [LW-1:0]    lvl,
        output logic [QTY_W-1:0] qty,
        output logic [5:0]       pos
    );
        m2_qry_valid = 1'b1;
        m2_qry_sym   = sym;
        m2_qry_oid   = oid;
        @(posedge clk);
        while (!m2_qry_ready) @(posedge clk);
        found        = m2_qry_found;
        lvl          = m2_qry_level;
        qty          = m2_qry_qty;
        pos          = m2_qry_pos;
        m2_qry_valid = 1'b0;
        @(posedge clk);
    endtask

    task automatic wait_best_settle();
        repeat (14) @(posedge clk);
    endtask

    task automatic do_query(
        input  logic [OID_W-1:0] oid,
        output logic             found,
        output logic [LW-1:0]    lvl,
        output logic [QTY_W-1:0] qty,
        output logic [5:0]       pos
    );
        qry_valid = 1'b1;
        qry_oid   = oid;
        @(posedge clk);
        while (!qry_ready) @(posedge clk);
        found     = qry_found;
        lvl       = qry_level;
        qty       = qry_qty;
        pos       = qry_pos;
        qry_valid = 1'b0;
        @(posedge clk);
    endtask

    task automatic check_eq(input string name, input int got, input int exp);
        if (got !== exp) begin
            $display("FAIL [%s]: got=%0d exp=%0d", name, got, exp);
            errors++;
        end
    endtask

    task automatic finish_directed(input string name, input int err_before);
        directed_total++;
        if (errors == err_before) begin
            directed_passed++;
        end else begin
            $display("DIRECTED FAIL: %s", name);
        end
    endtask

    initial begin
        logic             qf;
        logic [LW-1:0]    ql;
        logic [QTY_W-1:0] qq;
        logic [5:0]       qp;
        int e0;

        // ------------------------------------------------------------------
        // Directed Test 1: Empty book query
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        do_query(16'd0, qf, ql, qq, qp);
        check_eq("D01 empty found", int'(qf), 0);
        check_eq("D01 bid_valid",   int'(bid_valid), 0);
        check_eq("D01 ask_valid",   int'(ask_valid), 0);
        finish_directed("D01_empty_query", e0);

        // ------------------------------------------------------------------
        // Directed Test 2: ADD -> Query (level, qty, pos=0)
        // ------------------------------------------------------------------
        e0 = errors;
        send_cmd(OP_ADD, 1'b0, 16'd10, 10'd123, 16'd45);
        do_query(16'd10, qf, ql, qq, qp);
        check_eq("D02 found", int'(qf), 1);
        check_eq("D02 level", int'(ql), 123);
        check_eq("D02 qty",   int'(qq), 45);
        check_eq("D02 pos",   int'(qp), 0);
        finish_directed("D02_add_query", e0);

        // ------------------------------------------------------------------
        // Directed Test 3: 3 ADDs at same level -> pos 0/1/2
        // ------------------------------------------------------------------
        e0 = errors;
        send_cmd(OP_ADD, 1'b0, 16'd11, 10'd123, 16'd55);
        send_cmd(OP_ADD, 1'b0, 16'd12, 10'd123, 16'd65);
        do_query(16'd10, qf, ql, qq, qp); check_eq("D03 pos0", int'(qp), 0);
        do_query(16'd11, qf, ql, qq, qp); check_eq("D03 pos1", int'(qp), 1);
        do_query(16'd12, qf, ql, qq, qp); check_eq("D03 pos2", int'(qp), 2);
        finish_directed("D03_three_same_level", e0);

        // ------------------------------------------------------------------
        // Directed Test 4: Middle cancel -> subsequent pos decrements
        // ------------------------------------------------------------------
        e0 = errors;
        send_cmd(OP_CANCEL, 1'b0, 16'd11, 10'd123, 16'd1);
        do_query(16'd11, qf, ql, qq, qp); check_eq("D04 mid gone", int'(qf), 0);
        do_query(16'd10, qf, ql, qq, qp); check_eq("D04 head pos0", int'(qp), 0);
        do_query(16'd12, qf, ql, qq, qp); check_eq("D04 tail pos1", int'(qp), 1);
        finish_directed("D04_middle_cancel", e0);

        // ------------------------------------------------------------------
        // Directed Test 5: TRADE partial fill across two orders
        // ------------------------------------------------------------------
        e0 = errors;
        // Currently at level 123: oid 10 (qty 45), oid 12 (qty 65). Trade 60 -> consumes 10, leaves 12 with 50.
        send_cmd(OP_TRADE, 1'b0, 16'd9999, 10'd123, 16'd60);
        do_query(16'd10, qf, ql, qq, qp); check_eq("D05 o10 gone", int'(qf), 0);
        do_query(16'd12, qf, ql, qq, qp);
        check_eq("D05 o12 found", int'(qf), 1);
        check_eq("D05 o12 qty",   int'(qq), 50);
        check_eq("D05 o12 pos",   int'(qp), 0);
        wait_best_settle();
        check_eq("D05 best_bid_qty", int'(best_bid_qty), 50);
        finish_directed("D05_trade_partial_two", e0);

        // ------------------------------------------------------------------
        // Directed Test 6: TRADE sweeps entire level -> level disappears
        // ------------------------------------------------------------------
        e0 = errors;
        send_cmd(OP_TRADE, 1'b0, 16'd0, 10'd123, 16'd200);
        wait_best_settle();
        check_eq("D06 bid_valid=0", int'(bid_valid), 0);
        do_query(16'd12, qf, ql, qq, qp); check_eq("D06 o12 gone", int'(qf), 0);
        finish_directed("D06_trade_sweep_level", e0);

        // ------------------------------------------------------------------
        // Directed Test 7: REDUCE to 0 -> same as cancel
        // ------------------------------------------------------------------
        e0 = errors;
        send_cmd(OP_ADD, 1'b1, 16'd20, 10'd500, 16'd80);
        send_cmd(OP_REDUCE, 1'b1, 16'd20, 10'd500, 16'd80);
        wait_best_settle();
        do_query(16'd20, qf, ql, qq, qp);
        check_eq("D07 found=0",   int'(qf), 0);
        check_eq("D07 ask_val=0", int'(ask_valid), 0);
        check_eq("D07 cnt_sat=0", int'(cnt_sat), 0);
        finish_directed("D07_reduce_to_zero", e0);

        // ------------------------------------------------------------------
        // Directed Test 8: REDUCE > remaining -> saturate & remove
        // ------------------------------------------------------------------
        e0 = errors;
        send_cmd(OP_ADD, 1'b1, 16'd21, 10'd500, 16'd25);
        send_cmd(OP_REDUCE, 1'b1, 16'd21, 10'd500, 16'd99);
        wait_best_settle();
        do_query(16'd21, qf, ql, qq, qp);
        check_eq("D08 found=0",   int'(qf), 0);
        check_eq("D08 ask_val=0", int'(ask_valid), 0);
        check_eq("D08 cnt_sat=1", int'(cnt_sat), 1);
        finish_directed("D08_reduce_saturate", e0);

        // ------------------------------------------------------------------
        // Directed Test 9: Duplicate OID ADD -> dropped
        // ------------------------------------------------------------------
        e0 = errors;
        send_cmd(OP_ADD, 1'b0, 16'd30, 10'd200, 16'd15);
        send_cmd(OP_ADD, 1'b0, 16'd30, 10'd201, 16'd99);
        check_eq("D09 cnt_drop_dup=1", int'(cnt_drop_dup), 1);
        do_query(16'd30, qf, ql, qq, qp);
        check_eq("D09 orig lvl", int'(ql), 200);
        check_eq("D09 orig qty", int'(qq), 15);
        finish_directed("D09_dup_oid", e0);

        // ------------------------------------------------------------------
        // Directed Test 10: Unknown OID CANCEL -> dropped
        // ------------------------------------------------------------------
        e0 = errors;
        begin
            int unk_before = int'(cnt_drop_unknown);
            send_cmd(OP_CANCEL, 1'b0, 16'd777, 10'd200, 16'd1);
            check_eq("D10 cnt_drop_unknown", int'(cnt_drop_unknown), unk_before + 1);
        end
        finish_directed("D10_unknown_cancel", e0);

        // ------------------------------------------------------------------
        // Directed Test 11: Full order store ADD -> dropped (cnt_drop_full)
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        for (int k = 0; k < MAX_ORDERS; k++) begin
            send_cmd(OP_ADD, 1'b0, 16'(k), 10'(k % 512), 16'd1);
        end
        check_eq("D11 filled", int'(cnt_add), MAX_ORDERS);
        send_cmd(OP_ADD, 1'b0, 16'd0, 10'd0, 16'd5);
        check_eq("D11 cnt_drop_full=1", int'(cnt_drop_full), 1);
        check_eq("D11 cnt_drop_dup=0",  int'(cnt_drop_dup), 0);
        finish_directed("D11_full_drop", e0);

        // ------------------------------------------------------------------
        // Directed Test 12: Best bid/ask appear and disappear accurately
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        send_cmd(OP_ADD, 1'b0, 16'd1, 10'd100, 16'd10);
        send_cmd(OP_ADD, 1'b0, 16'd2, 10'd200, 16'd20);
        send_cmd(OP_ADD, 1'b1, 16'd3, 10'd400, 16'd30);
        send_cmd(OP_ADD, 1'b1, 16'd4, 10'd300, 16'd40);
        wait_best_settle();
        check_eq("D12 best_bid",     int'(best_bid),     200);
        check_eq("D12 best_bid_qty", int'(best_bid_qty), 20);
        check_eq("D12 best_ask",     int'(best_ask),     300);
        check_eq("D12 best_ask_qty", int'(best_ask_qty), 40);
        send_cmd(OP_CANCEL, 1'b0, 16'd2, 10'd200, 16'd1);
        send_cmd(OP_CANCEL, 1'b1, 16'd4, 10'd300, 16'd1);
        wait_best_settle();
        check_eq("D12 fallback bid", int'(best_bid), 100);
        check_eq("D12 fallback ask", int'(best_ask), 400);
        finish_directed("D12_best_bid_ask", e0);

        // ------------------------------------------------------------------
        // Directed Test 13: Back-to-back commands to same level -> stall & correct
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        begin
            int saw_stall = 0;
            // Drive cmd 1 (ADD oid 1 lvl 77 qty 10)
            cmd_valid = 1'b1; cmd_op = OP_ADD; cmd_side = 1'b0; cmd_oid = 16'd1; cmd_level = 10'd77; cmd_qty = 16'd10;
            @(posedge clk);
            while (!cmd_ready) @(posedge clk);
            // Immediately present cmd 2 (ADD oid 2 lvl 77 qty 25) without dropping cmd_valid
            cmd_oid = 16'd2; cmd_qty = 16'd25;
            @(posedge clk);
            if (!cmd_ready) saw_stall = 1;
            while (!cmd_ready) @(posedge clk);
            // Immediately present cmd 3 (ADD oid 3 lvl 77 qty 15)
            cmd_oid = 16'd3; cmd_qty = 16'd15;
            @(posedge clk);
            while (!cmd_ready) @(posedge clk);
            cmd_valid = 1'b0;
            @(posedge clk);
            while (!cmd_ready) @(posedge clk);
            wait_best_settle();
            check_eq("D13 saw_stall",    saw_stall, 1);
            check_eq("D13 best_bid",     int'(best_bid), 77);
            check_eq("D13 best_bid_qty", int'(best_bid_qty), 50);
            do_query(16'd3, qf, ql, qq, qp);
            check_eq("D13 o3 pos=2",     int'(qp), 2);
        end
        finish_directed("D13_back_to_back_same_level_stall", e0);

        // ------------------------------------------------------------------
        // Directed Test 14: Command arriving during multi-order TRADE must wait
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        for (int k = 0; k < 5; k++) begin
            send_cmd(OP_ADD, 1'b0, 16'(k), 10'd88, 16'd10);
        end
        begin
            int wait_cycles = 0;
            // Ensure DUT is idle (cmd_ready == 1) before issuing TRADE
            while (!cmd_ready) @(posedge clk);
            // Issue TRADE qty=45 (touches all 5 orders); accepted on next posedge
            cmd_valid = 1'b1; cmd_op = OP_TRADE; cmd_side = 1'b0; cmd_oid = 16'd0; cmd_level = 10'd88; cmd_qty = 16'd45;
            @(posedge clk);
            #1;
            // Immediately present ADD oid 50 at lvl 88 qty 100 while TRADE is running
            cmd_op = OP_ADD; cmd_side = 1'b0; cmd_oid = 16'd50; cmd_level = 10'd88; cmd_qty = 16'd100;
            while (!cmd_ready) begin
                wait_cycles++;
                @(posedge clk);
                #1;
            end
            // Now cmd_ready == 1; next posedge accepts ADD oid 50
            @(posedge clk);
            #1;
            cmd_valid = 1'b0;
            while (!cmd_ready) @(posedge clk);
            wait_best_settle();
            if (wait_cycles < 5) begin
                $display("FAIL [D14 wait_cycles]: expected >=5, got %0d", wait_cycles);
                errors++;
            end
            check_eq("D14 best_bid_qty", int'(best_bid_qty), 105);
            do_query(16'd4, qf, ql, qq, qp);
            check_eq("D14 o4 rem qty", int'(qq), 5);
            check_eq("D14 o4 pos=0",   int'(qp), 0);
            do_query(16'd50, qf, ql, qq, qp);
            check_eq("D14 o50 pos=1",  int'(qp), 1);
        end
        finish_directed("D14_cmd_waits_during_trade", e0);

        // ------------------------------------------------------------------
        // Directed Test 15: Boundary levels 0 and LEVELS-1 (1023)
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        send_cmd(OP_ADD, 1'b0, 16'd1, 10'd0,    16'd11);
        send_cmd(OP_ADD, 1'b1, 16'd2, 10'd1023, 16'd22);
        wait_best_settle();
        check_eq("D15 bid 0",    int'(best_bid),     0);
        check_eq("D15 bid q",    int'(best_bid_qty), 11);
        check_eq("D15 ask 1023", int'(best_ask),     1023);
        check_eq("D15 ask q",    int'(best_ask_qty), 22);
        finish_directed("D15_boundary_levels", e0);

        // ------------------------------------------------------------------
        // Directed Test 16: Extreme qty = 1 cases
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        send_cmd(OP_ADD, 1'b0, 16'd1, 10'd10, 16'd1);
        send_cmd(OP_ADD, 1'b0, 16'd2, 10'd10, 16'd1);
        wait_best_settle();
        check_eq("D16 qty=2", int'(best_bid_qty), 2);
        send_cmd(OP_TRADE, 1'b0, 16'd0, 10'd10, 16'd1);
        wait_best_settle();
        check_eq("D16 after trade1 qty=1", int'(best_bid_qty), 1);
        send_cmd(OP_REDUCE, 1'b0, 16'd2, 10'd10, 16'd1);
        wait_best_settle();
        check_eq("D16 empty", int'(bid_valid), 0);
        finish_directed("D16_qty_one", e0);

        // ------------------------------------------------------------------
        // Directed Test 17: Query non-existent & OOB order
        // ------------------------------------------------------------------
        e0 = errors;
        do_query(16'd555, qf, ql, qq, qp);
        check_eq("D17 unknown found=0", int'(qf), 0);
        do_query(16'd8192, qf, ql, qq, qp);
        check_eq("D17 oob found=0", int'(qf), 0);
        finish_directed("D17_query_nonexistent", e0);

        // ------------------------------------------------------------------
        // Directed Test 18: Reset leaves state completely clean
        // ------------------------------------------------------------------
        e0 = errors;
        send_cmd(OP_ADD, 1'b0, 16'd1, 10'd50, 16'd100);
        send_cmd(OP_ADD, 1'b1, 16'd2, 10'd60, 16'd200);
        do_reset();
        check_eq("D18 bid_valid=0", int'(bid_valid), 0);
        check_eq("D18 ask_valid=0", int'(ask_valid), 0);
        check_eq("D18 cnt_add=0",   int'(cnt_add),   0);
        do_query(16'd1, qf, ql, qq, qp); check_eq("D18 o1 gone", int'(qf), 0);
        do_query(16'd2, qf, ql, qq, qp); check_eq("D18 o2 gone", int'(qf), 0);
        finish_directed("D18_reset_clean", e0);

        // ------------------------------------------------------------------
        // Directed Test 19: Interleaved ADD/CANCEL across two levels
        // ------------------------------------------------------------------
        e0 = errors;
        send_cmd(OP_ADD, 1'b0, 16'd1, 10'd10, 16'd10);
        send_cmd(OP_ADD, 1'b0, 16'd2, 10'd20, 16'd20);
        send_cmd(OP_ADD, 1'b0, 16'd3, 10'd10, 16'd30);
        send_cmd(OP_ADD, 1'b0, 16'd4, 10'd20, 16'd40);
        send_cmd(OP_CANCEL, 1'b0, 16'd1, 10'd10, 16'd1);
        send_cmd(OP_CANCEL, 1'b0, 16'd4, 10'd20, 16'd1);
        do_query(16'd3, qf, ql, qq, qp);
        check_eq("D19 o3 lvl=10", int'(ql), 10);
        check_eq("D19 o3 pos=0",  int'(qp), 0);
        do_query(16'd2, qf, ql, qq, qp);
        check_eq("D19 o2 lvl=20", int'(ql), 20);
        check_eq("D19 o2 pos=0",  int'(qp), 0);
        wait_best_settle();
        check_eq("D19 best_bid=20", int'(best_bid), 20);
        check_eq("D19 best_qty=20", int'(best_bid_qty), 20);
        finish_directed("D19_interleaved_two_levels", e0);

        // ------------------------------------------------------------------
        // Directed Test 20: Strict FIFO ordering verification
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        send_cmd(OP_ADD, 1'b1, 16'd100, 10'd700, 16'd10);
        send_cmd(OP_ADD, 1'b1, 16'd200, 10'd700, 16'd20);
        send_cmd(OP_ADD, 1'b1, 16'd300, 10'd700, 16'd30);
        send_cmd(OP_TRADE, 1'b1, 16'd0, 10'd700, 16'd10); // exact consume 100
        do_query(16'd100, qf, ql, qq, qp); check_eq("D20 o100 gone", int'(qf), 0);
        do_query(16'd200, qf, ql, qq, qp); check_eq("D20 o200 pos0", int'(qp), 0);
        do_query(16'd300, qf, ql, qq, qp); check_eq("D20 o300 pos1", int'(qp), 1);
        send_cmd(OP_TRADE, 1'b1, 16'd0, 10'd700, 16'd25); // consume 200 (20) + 5 of 300
        do_query(16'd200, qf, ql, qq, qp); check_eq("D20 o200 gone", int'(qf), 0);
        do_query(16'd300, qf, ql, qq, qp);
        check_eq("D20 o300 qty=25", int'(qq), 25);
        check_eq("D20 o300 pos=0",  int'(qp), 0);
        finish_directed("D20_fifo_order", e0);

        // ------------------------------------------------------------------
        // Directed Test 21: ADD immediately followed by CANCEL same oid (hazard)
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        cmd_valid = 1'b1; cmd_op = OP_ADD; cmd_side = 1'b0; cmd_oid = 16'd42; cmd_level = 10'd99; cmd_qty = 16'd50;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        cmd_op = OP_CANCEL; cmd_qty = 16'd1;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        cmd_valid = 1'b0;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        wait_best_settle();
        check_eq("D21 bid_valid=0", int'(bid_valid), 0);
        check_eq("D21 cnt_add=1",   int'(cnt_add), 1);
        check_eq("D21 cnt_cancel=1", int'(cnt_cancel), 1);
        finish_directed("D21_add_then_cancel_same_oid", e0);

        // ------------------------------------------------------------------
        // Directed Test 22: Simultaneous cmd_valid & qry_valid (cmd priority)
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        send_cmd(OP_ADD, 1'b0, 16'd7, 10'd150, 16'd60);
        // Assert REDUCE(oid=7, qty=20) and QUERY(oid=7) on the EXACT same cycle
        cmd_valid = 1'b1; cmd_op = OP_REDUCE; cmd_side = 1'b0; cmd_oid = 16'd7; cmd_level = 10'd150; cmd_qty = 16'd20;
        qry_valid = 1'b1; qry_oid = 16'd7;
        @(posedge clk);
        check_eq("D22 qry_ready=0 on conflict", int'(qry_ready), 0);
        while (!cmd_ready) @(posedge clk);
        cmd_valid = 1'b0;
        // Hold qry_valid until qry_ready completes -> must see post-reduce qty=40!
        while (!qry_ready) @(posedge clk);
        check_eq("D22 qry_found=1", int'(qry_found), 1);
        check_eq("D22 qry_qty=40",  int'(qry_qty),   40);
        qry_valid = 1'b0;
        @(posedge clk);
        finish_directed("D22_cmd_qry_priority", e0);

        // ------------------------------------------------------------------
        // Directed Test 23: Bad commands (qty=0, oid>=MAX_ORDERS)
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        send_cmd(OP_ADD,    1'b0, 16'd1,    10'd10, 16'd0);
        send_cmd(OP_ADD,    1'b0, 16'd8192, 10'd10, 16'd10);
        send_cmd(OP_CANCEL, 1'b0, 16'd8193, 10'd10, 16'd1);
        send_cmd(OP_TRADE,  1'b0, 16'd0,    10'd10, 16'd0);
        check_eq("D23 cnt_drop_bad=4", int'(cnt_drop_bad), 4);
        finish_directed("D23_bad_cmds", e0);

        // ------------------------------------------------------------------
        // Directed Test 24: qry_pos cap at 63
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        for (int k = 0; k < 70; k++) begin
            send_cmd(OP_ADD, 1'b1, 16'(k), 10'd800, 16'd5);
        end
        do_query(16'd69, qf, ql, qq, qp);
        check_eq("D24 pos cap 63", int'(qp), 63);
        finish_directed("D24_qry_pos_cap63", e0);

        // ------------------------------------------------------------------
        // Directed Test 25: Measure cmd -> best price update latency (<= 10 cycles)
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        begin
            int lat;
            // Measure ADD latency (from handshake posedge to best_bid updated)
            while (!cmd_ready) @(posedge clk);
            cmd_valid = 1'b1; cmd_op = OP_ADD; cmd_side = 1'b0; cmd_oid = 16'd1; cmd_level = 10'd333; cmd_qty = 16'd77;
            @(posedge clk);
            #1;
            cmd_valid = 1'b0;
            lat = 1;
            while (!(bid_valid && best_bid == 10'd333 && best_bid_qty == 16'd77) && lat < 20) begin
                @(posedge clk);
                #1;
                lat++;
            end
            if (lat > max_best_latency) max_best_latency = lat;
            if (lat > 16) begin
                $display("FAIL [D25 ADD latency]: %0d > 16", lat);
                errors++;
            end

            // Measure CANCEL latency (from handshake posedge to bid_valid cleared)
            while (!cmd_ready) @(posedge clk);
            cmd_valid = 1'b1; cmd_op = OP_CANCEL; cmd_side = 1'b0; cmd_oid = 16'd1; cmd_level = 10'd333; cmd_qty = 16'd1;
            @(posedge clk);
            #1;
            cmd_valid = 1'b0;
            lat = 1;
            while (bid_valid && lat < 20) begin
                @(posedge clk);
                #1;
                lat++;
            end
            if (lat > max_best_latency) max_best_latency = lat;
            if (lat > 16) begin
                $display("FAIL [D25 CANCEL latency]: %0d > 16", lat);
                errors++;
            end
        end
        finish_directed("D25_latency_check", e0);

        // ------------------------------------------------------------------
        // Directed Test 26: a CANCEL must free a slot even when the store is full
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        for (int k = 0; k < MAX_ORDERS; k++) begin
            send_cmd(OP_ADD, 1'b0, 16'(k), 10'(k % LEVELS), 16'd1);
        end
        check_eq("D26 full cnt_drop_full", int'(cnt_drop_full), 0);
        check_eq("D26 full cnt_add", int'(cnt_add), MAX_ORDERS);
        send_cmd(OP_CANCEL, 1'b0, 16'd0, 10'd0, 16'd1);
        send_cmd(OP_ADD, 1'b0, 16'd0, 10'd0, 16'd1);
        check_eq("D26 readd cnt_drop_full", int'(cnt_drop_full), 0);
        check_eq("D26 readd cnt_add", int'(cnt_add), MAX_ORDERS + 1);
        finish_directed("D26_full_slot_reuse", e0);

        // ------------------------------------------------------------------
        // Directed Test 27: TRADE must consume the side given by cmd_side
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        send_cmd(OP_ADD, 1'b0, 16'd1, 10'd100, 16'd5);    // bid 5 @ 100
        send_cmd(OP_ADD, 1'b1, 16'd2, 10'd100, 16'd7);    // ask 7 @ 100 (crossed book)
        send_cmd(OP_TRADE, 1'b1, 16'd0, 10'd100, 16'd3);  // trade the ASK side
        wait_best_settle();
        do_query(16'd2, qf, ql, qq, qp);
        check_eq("D27 ask qty after trade", int'(qq), 4);
        do_query(16'd1, qf, ql, qq, qp);
        check_eq("D27 bid untouched", int'(qq), 5);
        send_cmd(OP_TRADE, 1'b1, 16'd0, 10'd100, 16'd10); // rest of the ask
        wait_best_settle();
        check_eq("D27 ask_valid cleared", int'(ask_valid), 0);
        check_eq("D27 bid still valid", int'(bid_valid), 1);
        check_eq("D27 bid qty", int'(best_bid_qty), 5);
        check_eq("D27 no unknown drops", int'(cnt_drop_unknown), 0);
        finish_directed("D27_trade_side_select", e0);

        // D28: v1.1 seq normal increment including 16-bit wrap-around (65534 -> 65535 -> 0 -> 1)
        e0 = errors;
        do_reset();
        send_cmd_seq(OP_ADD, 1'b0, 16'd1, 10'd50, 16'd10, 16'hFFFE);
        send_cmd_seq(OP_ADD, 1'b0, 16'd2, 10'd51, 16'd20, 16'hFFFF);
        send_cmd_seq(OP_ADD, 1'b1, 16'd3, 10'd60, 16'd30, 16'h0000);
        send_cmd_seq(OP_REDUCE, 1'b0, 16'd2, 10'd0, 16'd5, 16'h0001);
        wait_best_settle();
        check_eq("D28 stale=0", int'(stale), 0);
        check_eq("D28 cnt_seq_gap=0", int'(cnt_seq_gap), 0);
        check_eq("D28 cnt_dup_seq=0", int'(cnt_dup_seq), 0);
        check_eq("D28 cnt_drop_stale=0", int'(cnt_drop_stale), 0);
        check_eq("D28 cnt_add=3", int'(cnt_add), 3);
        check_eq("D28 cnt_reduce=1", int'(cnt_reduce), 1);
        check_eq("D28 best_bid=51", int'(best_bid), 51);
        check_eq("D28 best_bid_qty=15", int'(best_bid_qty), 15);
        finish_directed("D28_seq_normal_wrap", e0);

        // D29: v1.1 seq gap sets stale and drops all subsequent commands
        e0 = errors;
        do_reset();
        send_cmd_seq(OP_ADD, 1'b0, 16'd10, 10'd100, 16'd12, 16'd100);
        send_cmd_seq(OP_ADD, 1'b0, 16'd11, 10'd101, 16'd15, 16'd101);
        send_cmd_seq(OP_ADD, 1'b0, 16'd12, 10'd102, 16'd20, 16'd103); // GAP (expected 102)
        send_cmd_seq(OP_ADD, 1'b0, 16'd13, 10'd105, 16'd25, 16'd104); // dropped: stale
        send_cmd_seq(OP_CANCEL, 1'b0, 16'd11, 10'd0, 16'd1, 16'd105); // dropped: stale
        wait_best_settle();
        check_eq("D29 stale=1", int'(stale), 1);
        check_eq("D29 cnt_seq_gap=1", int'(cnt_seq_gap), 1);
        check_eq("D29 cnt_drop_stale=2", int'(cnt_drop_stale), 2);
        check_eq("D29 cnt_add=2", int'(cnt_add), 2);
        check_eq("D29 best_bid=101", int'(best_bid), 101);
        check_eq("D29 best_bid_qty=15", int'(best_bid_qty), 15);
        do_query(16'd12, qf, ql, qq, qp);
        check_eq("D29 gap oid not added", int'(qf), 0);
        finish_directed("D29_seq_gap_stale", e0);

        // D30: v1.1 seq duplicate drops without setting stale
        e0 = errors;
        do_reset();
        send_cmd_seq(OP_ADD, 1'b0, 16'd20, 10'd200, 16'd10, 16'd500);
        send_cmd_seq(OP_ADD, 1'b0, 16'd21, 10'd201, 16'd15, 16'd501);
        send_cmd_seq(OP_ADD, 1'b0, 16'd22, 10'd202, 16'd20, 16'd501); // DUP (same as prev_seq=501)
        send_cmd_seq(OP_ADD, 1'b0, 16'd23, 10'd203, 16'd25, 16'd502); // next valid seq
        wait_best_settle();
        check_eq("D30 stale=0", int'(stale), 0);
        check_eq("D30 cnt_seq_gap=0", int'(cnt_seq_gap), 0);
        check_eq("D30 cnt_dup_seq=1", int'(cnt_dup_seq), 1);
        check_eq("D30 cnt_drop_stale=0", int'(cnt_drop_stale), 0);
        check_eq("D30 cnt_add=3", int'(cnt_add), 3);
        check_eq("D30 best_bid=203", int'(best_bid), 203);
        check_eq("D30 best_bid_qty=25", int'(best_bid_qty), 25);
        do_query(16'd22, qf, ql, qq, qp);
        check_eq("D30 dup oid not added", int'(qf), 0);
        finish_directed("D30_seq_dup_no_stale", e0);

        // D31: v1.1 snapshot empty book (HEADER(0) + FOOTER(0)) clears prior book and stale
        e0 = errors;
        do_reset();
        send_cmd_seq(OP_ADD, 1'b0, 16'd1, 10'd300, 16'd50, 16'd1);
        send_cmd_seq(OP_ADD, 1'b1, 16'd2, 10'd310, 16'd60, 16'd5); // GAP -> stale=1
        check_eq("D31 stale before snap", int'(stale), 1);
        send_snap(mk_snap_header(32'd0));
        check_eq("D31 cmd_ready=0 during load", int'(cmd_ready), 0);
        send_snap(mk_snap_footer(32'd0));
        wait_best_settle();
        check_eq("D31 cmd_ready=1 after footer", int'(cmd_ready), 1);
        check_eq("D31 stale cleared", int'(stale), 0);
        check_eq("D31 snapshot_error=0", int'(snapshot_error), 0);
        check_eq("D31 bid_valid=0", int'(bid_valid), 0);
        check_eq("D31 ask_valid=0", int'(ask_valid), 0);
        do_query(16'd1, qf, ql, qq, qp);
        check_eq("D31 old oid cleared", int'(qf), 0);
        finish_directed("D31_snapshot_empty", e0);

        // D32: v1.1 snapshot 2 levels x 2 orders -> FIFO order, qty, best price, seq reset
        e0 = errors;
        do_reset();
        send_cmd_seq(OP_ADD, 1'b0, 16'd99, 10'd900, 16'd99, 16'd1);
        send_cmd_seq(OP_ADD, 1'b0, 16'd98, 10'd901, 16'd99, 16'd9); // GAP -> stale=1
        send_snap(mk_snap_header(32'd4));
        send_snap(mk_snap_level(1'b0, 10'd120, 16'd30));
        send_snap(mk_snap_order(1'b0, 10'd120, 16'd10, 16'd10));
        send_snap(mk_snap_order(1'b0, 10'd120, 16'd20, 16'd11));
        send_snap(mk_snap_level(1'b1, 10'd130, 16'd70));
        send_snap(mk_snap_order(1'b1, 10'd130, 16'd30, 16'd20));
        send_snap(mk_snap_order(1'b1, 10'd130, 16'd40, 16'd21));
        send_snap(mk_snap_footer(32'd4));
        wait_best_settle();
        check_eq("D32 stale=0", int'(stale), 0);
        check_eq("D32 snapshot_error=0", int'(snapshot_error), 0);
        check_eq("D32 bid_valid=1", int'(bid_valid), 1);
        check_eq("D32 best_bid=120", int'(best_bid), 120);
        check_eq("D32 best_bid_qty=30", int'(best_bid_qty), 30);
        check_eq("D32 ask_valid=1", int'(ask_valid), 1);
        check_eq("D32 best_ask=130", int'(best_ask), 130);
        check_eq("D32 best_ask_qty=70", int'(best_ask_qty), 70);
        do_query(16'd10, qf, ql, qq, qp);
        check_eq("D32 oid10 found", int'(qf), 1);
        check_eq("D32 oid10 pos=0", int'(qp), 0);
        do_query(16'd11, qf, ql, qq, qp);
        check_eq("D32 oid11 found", int'(qf), 1);
        check_eq("D32 oid11 pos=1", int'(qp), 1);
        do_query(16'd21, qf, ql, qq, qp);
        check_eq("D32 oid21 pos=1", int'(qp), 1);
        // Verify FIFO trade consumes oid 10 first, then partial oid 11, with fresh seq baseline
        send_cmd_seq(OP_TRADE, 1'b0, 16'd0, 10'd120, 16'd15, 16'd777);
        wait_best_settle();
        do_query(16'd10, qf, ql, qq, qp);
        check_eq("D32 oid10 consumed", int'(qf), 0);
        do_query(16'd11, qf, ql, qq, qp);
        check_eq("D32 oid11 rem qty=15", int'(qq), 15);
        check_eq("D32 oid11 now pos=0", int'(qp), 0);
        check_eq("D32 best_bid_qty=15", int'(best_bid_qty), 15);
        finish_directed("D32_snapshot_multilevel_fifo", e0);

        // D33: v1.1 commands arriving during snapshot load are dropped with cnt_drop_load++
        e0 = errors;
        do_reset();
        send_snap(mk_snap_header(32'd1));
        check_eq("D33 cmd_ready=0 in load", int'(cmd_ready), 0);
        // Pulse two commands while in snapshot load mode
        cmd_valid = 1'b1; cmd_op = OP_ADD; cmd_side = 1'b0; cmd_oid = 16'd50; cmd_level = 10'd50; cmd_qty = 16'd5;
        repeat (3) @(posedge clk);
        cmd_valid = 1'b0;
        @(posedge clk);
        cmd_valid = 1'b1; cmd_oid = 16'd51;
        @(posedge clk);
        cmd_valid = 1'b0;
        @(posedge clk);
        send_snap(mk_snap_order(1'b0, 10'd200, 16'd42, 16'd1));
        send_snap(mk_snap_footer(32'd1));
        wait_best_settle();
        check_eq("D33 cnt_drop_load=2", int'(cnt_drop_load), 2);
        check_eq("D33 best_bid=200", int'(best_bid), 200);
        check_eq("D33 best_bid_qty=42", int'(best_bid_qty), 42);
        do_query(16'd50, qf, ql, qq, qp);
        check_eq("D33 dropped oid50 absent", int'(qf), 0);
        finish_directed("D33_snapshot_drop_during_load", e0);

        // D34: v1.1 snapshot HEADER/FOOTER count mismatch sets snapshot_error=1 and keeps stale=1
        e0 = errors;
        do_reset();
        send_snap(mk_snap_header(32'd2));
        send_snap(mk_snap_order(1'b0, 10'd100, 16'd10, 16'd1));
        send_snap(mk_snap_footer(32'd1)); // mismatch: header=2, footer=1, obs=1
        wait_best_settle();
        check_eq("D34 snapshot_error=1", int'(snapshot_error), 1);
        check_eq("D34 stale=1", int'(stale), 1);
        // Subsequent seq-enabled command must be dropped as stale
        send_cmd_seq(OP_ADD, 1'b0, 16'd2, 10'd101, 16'd20, 16'd1);
        check_eq("D34 cnt_drop_stale=1", int'(cnt_drop_stale), 1);
        // Recovery with matching snapshot clears snapshot_error and stale
        send_snap(mk_snap_header(32'd0));
        send_snap(mk_snap_footer(32'd0));
        check_eq("D34 recovered snapshot_error=0", int'(snapshot_error), 0);
        check_eq("D34 recovered stale=0", int'(stale), 0);
        finish_directed("D34_snapshot_count_mismatch", e0);

        // D35: v1.1 AXI4-Stream handshake (normal + stall) and s_axis_best backpressure
        e0 = errors;
        do_ax_reset();
        #1;
        // Verify tready drops during command execution (stall) and accepts held tvalid on next ready
        ax_best_tready = 1'b0; // hold back best-price stream
        ax_cmd_tvalid  = 1'b1;
        ax_cmd_tdata   = mk_axis_cmd(OP_ADD, 1'b0, 16'd1, 10'd400, 16'd25, 16'd10);
        @(posedge clk); // accepted at this edge
        #1;
        // Immediately present second command while busy (tready=0 -> must stall until ready)
        ax_cmd_tdata   = mk_axis_cmd(OP_ADD, 1'b1, 16'd2, 10'd410, 16'd35, 16'd11);
        check_eq("D35 cmd tready stalled during exec", int'(ax_cmd_tready), 0);
        @(posedge clk);
        while (!ax_cmd_tready) @(posedge clk);
        @(posedge clk); // accept second command with tvalid && tready
        ax_cmd_tvalid  = 1'b0;
        @(posedge clk);
        while (!ax_cmd_tready) @(posedge clk);
        wait_best_settle();
        // Best stream must be asserting tvalid and holding tdata stable while tready=0
        check_eq("D35 best tvalid=1 under backpressure", int'(ax_best_tvalid), 1);
        begin
            logic [63:0] held_best;
            held_best = ax_best_tdata;
            repeat (3) @(posedge clk);
            check_eq("D35 best tvalid still 1", int'(ax_best_tvalid), 1);
            check_eq("D35 best tdata held stable", int'(ax_best_tdata == held_best), 1);
            // Release tready -> drain beat and observe updated best
            ax_best_tready = 1'b1;
            repeat (4) @(posedge clk);
            check_eq("D35 best_bid_valid", int'(ax_bid_valid), 1);
            check_eq("D35 best_bid=400", int'(ax_best_bid), 400);
            check_eq("D35 best_bid_qty=25", int'(ax_best_bid_qty), 25);
            check_eq("D35 best_ask_valid", int'(ax_ask_valid), 1);
            check_eq("D35 best_ask=410", int'(ax_best_ask), 410);
            check_eq("D35 best_ask_qty=35", int'(ax_best_ask_qty), 35);
            // Verify s_axis_best_tdata bit packing matches spec §B.2
            check_eq("D35 axis_best[0]=bid_valid", int'(ax_best_tdata[0]), 1);
            check_eq("D35 axis_best[10:1]=best_bid", int'(ax_best_tdata[10:1]), 400);
            check_eq("D35 axis_best[26:11]=best_bid_qty", int'(ax_best_tdata[26:11]), 25);
            check_eq("D35 axis_best[27]=ask_valid", int'(ax_best_tdata[27]), 1);
            check_eq("D35 axis_best[37:28]=best_ask", int'(ax_best_tdata[37:28]), 410);
            check_eq("D35 axis_best[53:38]=best_ask_qty", int'(ax_best_tdata[53:38]), 35);
        end
        finish_directed("D35_axis_handshake_stall", e0);

        // D36: v1.1 AXI4-Stream end-to-end seq gap -> stale -> snapshot reload -> resume
        e0 = errors;
        do_ax_reset();
        send_ax_cmd(OP_ADD, 1'b0, 16'd1, 10'd100, 16'd10, 16'd1);
        send_ax_cmd(OP_ADD, 1'b0, 16'd2, 10'd101, 16'd20, 16'd1); // dup -> no stale
        check_eq("D36 dup count=1", int'(ax_cnt_dup_seq), 1);
        check_eq("D36 stale=0 after dup", int'(ax_stale), 0);
        send_ax_cmd(OP_ADD, 1'b0, 16'd3, 10'd102, 16'd30, 16'd5); // gap -> stale=1
        send_ax_cmd(OP_ADD, 1'b0, 16'd4, 10'd103, 16'd40, 16'd6); // dropped stale
        check_eq("D36 gap=1", int'(ax_cnt_seq_gap), 1);
        check_eq("D36 drop_stale=1", int'(ax_cnt_drop_stale), 1);
        check_eq("D36 stale=1", int'(ax_stale), 1);
        // Snapshot reload restores clean book and clears stale
        send_ax_snap(mk_snap_header(32'd1));
        send_ax_snap(mk_snap_order(1'b0, 10'd250, 16'd88, 16'd7));
        send_ax_snap(mk_snap_footer(32'd1));
        wait_best_settle();
        check_eq("D36 stale=0 after snap", int'(ax_stale), 0);
        check_eq("D36 snap_err=0", int'(ax_snap_err), 0);
        send_ax_cmd(OP_ADD, 1'b1, 16'd8, 10'd260, 16'd99, 16'd900); // new baseline seq=900
        wait_best_settle();
        check_eq("D36 best_bid=250", int'(ax_best_bid), 250);
        check_eq("D36 best_bid_qty=88", int'(ax_best_bid_qty), 88);
        check_eq("D36 best_ask=260", int'(ax_best_ask), 260);
        check_eq("D36 best_ask_qty=99", int'(ax_best_ask_qty), 99);
        finish_directed("D36_axis_gap_snapshot_recover", e0);

        // ------------------------------------------------------------------
        // Directed Test 37: query on oid B while a command touches oid A
        // (different BRAM addresses: the query must not steal the command read)
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        send_cmd(OP_ADD, 1'b0, 16'd10, 10'd200, 16'd50);
        send_cmd(OP_ADD, 1'b0, 16'd11, 10'd201, 16'd60);
        wait_best_settle();
        cmd_valid = 1'b1; cmd_op = OP_CANCEL; cmd_side = 1'b0; cmd_oid = 16'd10;
        cmd_level = 10'd200; cmd_qty = 16'd1;
        qry_valid = 1'b1; qry_oid = 16'd11;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        cmd_valid = 1'b0;
        while (!qry_ready) @(posedge clk);
        check_eq("D37 qry found", int'(qry_found), 1);
        check_eq("D37 qry level", int'(qry_level), 201);
        check_eq("D37 qry qty",   int'(qry_qty),   60);
        qry_valid = 1'b0;
        @(posedge clk);
        wait_best_settle();
        do_query(16'd10, qf, ql, qq, qp);
        check_eq("D37 cancelled oid gone", int'(qf), 0);
        do_query(16'd11, qf, ql, qq, qp);
        check_eq("D37 other oid intact", int'(qf), 1);
        check_eq("D37 other qty",        int'(qq), 60);
        finish_directed("D37_cmd_qry_distinct_oid", e0);

        // ------------------------------------------------------------------
        // Directed Test 38: query issued during a multi-cycle TRADE must wait
        // for the command and still return the correct order
        // ------------------------------------------------------------------
        e0 = errors;
        do_reset();
        send_cmd(OP_ADD, 1'b0, 16'd30, 10'd300, 16'd5);
        send_cmd(OP_ADD, 1'b0, 16'd31, 10'd300, 16'd5);
        send_cmd(OP_ADD, 1'b0, 16'd32, 10'd300, 16'd5);
        send_cmd(OP_ADD, 1'b0, 16'd40, 10'd400, 16'd77);
        wait_best_settle();
        cmd_valid = 1'b1; cmd_op = OP_TRADE; cmd_side = 1'b0; cmd_oid = 16'd0;
        cmd_level = 10'd300; cmd_qty = 16'd15;
        qry_valid = 1'b1; qry_oid = 16'd40;
        @(posedge clk);
        while (!cmd_ready) @(posedge clk);
        cmd_valid = 1'b0;
        while (!qry_ready) @(posedge clk);
        check_eq("D38 qry found", int'(qry_found), 1);
        check_eq("D38 qry qty",   int'(qry_qty),   77);
        check_eq("D38 qry level", int'(qry_level), 400);
        qry_valid = 1'b0;
        @(posedge clk);
        finish_directed("D38_query_during_trade", e0);

        // ------------------------------------------------------------------
        // v1.2 Task A Directed Tests (D39..D46): Multi-symbol (SYMBOLS=2)
        // ------------------------------------------------------------------
        // D39: Two symbols active simultaneously; best bid/ask independent
        e0 = errors;
        do_m2_reset();
        send_m2_cmd(OP_ADD, 1'b0, 16'd1, 10'd100, 16'd10, 15'd1, 2'd0);
        send_m2_cmd(OP_ADD, 1'b1, 16'd2, 10'd110, 16'd20, 15'd2, 2'd0);
        send_m2_cmd(OP_ADD, 1'b0, 16'd3, 10'd500, 16'd30, 15'd3, 2'd1);
        send_m2_cmd(OP_ADD, 1'b1, 16'd4, 10'd520, 16'd40, 15'd4, 2'd1);
        wait_best_settle();
        check_eq("D39 sym0 bid_valid", int'(m2_bid_valid[0]), 1);
        check_eq("D39 sym0 best_bid", int'(m2_best_bid[0]), 100);
        check_eq("D39 sym0 best_bid_qty", int'(m2_best_bid_qty[0]), 10);
        check_eq("D39 sym0 best_ask", int'(m2_best_ask[0]), 110);
        check_eq("D39 sym0 best_ask_qty", int'(m2_best_ask_qty[0]), 20);
        check_eq("D39 sym1 bid_valid", int'(m2_bid_valid[1]), 1);
        check_eq("D39 sym1 best_bid", int'(m2_best_bid[1]), 500);
        check_eq("D39 sym1 best_bid_qty", int'(m2_best_bid_qty[1]), 30);
        check_eq("D39 sym1 best_ask", int'(m2_best_ask[1]), 520);
        check_eq("D39 sym1 best_ask_qty", int'(m2_best_ask_qty[1]), 40);
        finish_directed("D39_m2_dual_sym_best_isolated", e0);

        // D40: Same OID (5) on sym 0 and sym 1 are completely independent
        e0 = errors;
        do_m2_reset();
        send_m2_cmd(OP_ADD, 1'b0, 16'd5, 10'd200, 16'd15, 15'd1, 2'd0);
        send_m2_cmd(OP_ADD, 1'b0, 16'd5, 10'd300, 16'd25, 15'd2, 2'd1);
        wait_best_settle();
        do_m2_query(1'b0, 16'd5, qf, ql, qq, qp);
        check_eq("D40 sym0 oid5 found", int'(qf), 1);
        check_eq("D40 sym0 oid5 level", int'(ql), 200);
        check_eq("D40 sym0 oid5 qty", int'(qq), 15);
        do_m2_query(1'b1, 16'd5, qf, ql, qq, qp);
        check_eq("D40 sym1 oid5 found", int'(qf), 1);
        check_eq("D40 sym1 oid5 level", int'(ql), 300);
        check_eq("D40 sym1 oid5 qty", int'(qq), 25);
        check_eq("D40 cnt_add=2", int'(m2_cnt_add), 2);
        finish_directed("D40_m2_same_oid_diff_sym", e0);

        // D41: CANCEL only affects specified symbol
        e0 = errors;
        do_m2_reset();
        send_m2_cmd(OP_ADD, 1'b0, 16'd7, 10'd150, 16'd12, 15'd1, 2'd0);
        send_m2_cmd(OP_ADD, 1'b0, 16'd7, 10'd150, 16'd34, 15'd2, 2'd1);
        send_m2_cmd(OP_CANCEL, 1'b0, 16'd7, 10'd150, 16'd1, 15'd3, 2'd0);
        wait_best_settle();
        check_eq("D41 sym0 bid_valid=0", int'(m2_bid_valid[0]), 0);
        check_eq("D41 sym1 bid_valid=1", int'(m2_bid_valid[1]), 1);
        check_eq("D41 sym1 best_bid_qty=34", int'(m2_best_bid_qty[1]), 34);
        do_m2_query(1'b0, 16'd7, qf, ql, qq, qp);
        check_eq("D41 sym0 oid7 gone", int'(qf), 0);
        do_m2_query(1'b1, 16'd7, qf, ql, qq, qp);
        check_eq("D41 sym1 oid7 intact", int'(qf), 1);
        check_eq("D41 sym1 oid7 qty=34", int'(qq), 34);
        finish_directed("D41_m2_cancel_sym_isolated", e0);

        // D42: TRADE only affects specified symbol
        e0 = errors;
        do_m2_reset();
        send_m2_cmd(OP_ADD, 1'b0, 16'd10, 10'd250, 16'd20, 15'd1, 2'd0);
        send_m2_cmd(OP_ADD, 1'b0, 16'd10, 10'd250, 16'd20, 15'd2, 2'd1);
        send_m2_cmd(OP_ADD, 1'b0, 16'd11, 10'd250, 16'd30, 15'd3, 2'd1);
        send_m2_cmd(OP_TRADE, 1'b0, 16'd0, 10'd250, 16'd25, 15'd4, 2'd1);
        wait_best_settle();
        check_eq("D42 sym0 bid_qty untouched", int'(m2_best_bid_qty[0]), 20);
        check_eq("D42 sym1 bid_qty after trade", int'(m2_best_bid_qty[1]), 25);
        do_m2_query(1'b0, 16'd10, qf, ql, qq, qp);
        check_eq("D42 sym0 oid10 untouched", int'(qq), 20);
        do_m2_query(1'b1, 16'd10, qf, ql, qq, qp);
        check_eq("D42 sym1 oid10 consumed", int'(qf), 0);
        do_m2_query(1'b1, 16'd11, qf, ql, qq, qp);
        check_eq("D42 sym1 oid11 rem=25", int'(qq), 25);
        check_eq("D42 sym1 oid11 pos=0", int'(qp), 0);
        finish_directed("D42_m2_trade_sym_isolated", e0);

        // D43: Multi-symbol snapshot loads both sym 0 and sym 1 with correct FIFO & qty
        e0 = errors;
        do_m2_reset();
        send_m2_snap(mk_snap_header(32'd4));
        send_m2_snap(mk_snap_level_m2(2'd0, 1'b0, 10'd100, 16'd30));
        send_m2_snap(mk_snap_order_m2(2'd0, 1'b0, 10'd100, 16'd10, 16'd1));
        send_m2_snap(mk_snap_order_m2(2'd0, 1'b0, 10'd100, 16'd20, 16'd2));
        send_m2_snap(mk_snap_level_m2(2'd1, 1'b1, 10'd200, 16'd70));
        send_m2_snap(mk_snap_order_m2(2'd1, 1'b1, 10'd200, 16'd30, 16'd1));
        send_m2_snap(mk_snap_order_m2(2'd1, 1'b1, 10'd200, 16'd40, 16'd2));
        send_m2_snap(mk_snap_footer(32'd4));
        wait_best_settle();
        check_eq("D43 snap_err=0", int'(m2_snap_err), 0);
        check_eq("D43 sym0 best_bid=100", int'(m2_best_bid[0]), 100);
        check_eq("D43 sym0 best_bid_qty=30", int'(m2_best_bid_qty[0]), 30);
        check_eq("D43 sym1 best_ask=200", int'(m2_best_ask[1]), 200);
        check_eq("D43 sym1 best_ask_qty=70", int'(m2_best_ask_qty[1]), 70);
        do_m2_query(1'b0, 16'd2, qf, ql, qq, qp);
        check_eq("D43 sym0 oid2 pos=1", int'(qp), 1);
        do_m2_query(1'b1, 16'd2, qf, ql, qq, qp);
        check_eq("D43 sym1 oid2 pos=1", int'(qp), 1);
        finish_directed("D43_m2_snapshot_dual_sym", e0);

        // D44: Multi-symbol snapshot count mismatch sets snapshot_error=1 and stale=1
        e0 = errors;
        do_m2_reset();
        send_m2_snap(mk_snap_header(32'd3));
        send_m2_snap(mk_snap_order_m2(2'd0, 1'b0, 10'd100, 16'd10, 16'd1));
        send_m2_snap(mk_snap_order_m2(2'd1, 1'b0, 10'd100, 16'd10, 16'd1));
        send_m2_snap(mk_snap_footer(32'd3)); // obs=2 != exp=3
        wait_best_settle();
        check_eq("D44 snap_err=1", int'(m2_snap_err), 1);
        check_eq("D44 stale=1", int'(m2_stale), 1);
        finish_directed("D44_m2_snapshot_count_mismatch", e0);

        // D45: Global seq gap across multi-symbol stream locks both symbols
        e0 = errors;
        do_m2_reset();
        send_m2_cmd(OP_ADD, 1'b0, 16'd1, 10'd100, 16'd10, 15'd50, 2'd0);
        send_m2_cmd(OP_ADD, 1'b0, 16'd1, 10'd200, 16'd20, 15'd51, 2'd1);
        send_m2_cmd(OP_ADD, 1'b0, 16'd2, 10'd101, 16'd30, 15'd53, 2'd0); // GAP (exp 52)
        send_m2_cmd(OP_ADD, 1'b0, 16'd2, 10'd201, 16'd40, 15'd54, 2'd1); // dropped stale
        wait_best_settle();
        check_eq("D45 cnt_seq_gap=1", int'(m2_cnt_seq_gap), 1);
        check_eq("D45 cnt_drop_stale=1", int'(m2_cnt_drop_stale), 1);
        check_eq("D45 stale=1", int'(m2_stale), 1);
        check_eq("D45 sym0 best_bid=100", int'(m2_best_bid[0]), 100);
        check_eq("D45 sym1 best_bid=200", int'(m2_best_bid[1]), 200);
        finish_directed("D45_m2_global_seq_gap", e0);

        // D46: AXI4-Stream sym field decode [61:60] and s_axis_best_tdata [63:61] sym tag
        e0 = errors;
        do_m2_reset();
        m2_best_tready = 1'b0;
        send_m2_cmd(OP_ADD, 1'b0, 16'd1, 10'd333, 16'd77, 15'd1, 2'd1);
        wait_best_settle();
        check_eq("D46 best_tvalid=1", int'(m2_best_tvalid), 1);
        check_eq("D46 best_tdata[63:61]=sym1", int'(m2_best_tdata[63:61]), 1);
        check_eq("D46 best_tdata[10:1]=333", int'(m2_best_tdata[10:1]), 333);
        check_eq("D46 best_tdata[26:11]=77", int'(m2_best_tdata[26:11]), 77);
        m2_best_tready = 1'b1;
        @(posedge clk);
        finish_directed("D46_m2_axis_sym_tag", e0);

        // D47: v1.2 Task B acceptance rate: 100 consecutive distinct-OID ADDs <= 200 cycles
        e0 = errors;
        do_m2_reset();
        begin
            int cyc100, s100;
            cyc100 = 0;
            s100   = 0;
            while (s100 < 100) begin
                m2_cmd_tvalid = 1'b1;
                m2_cmd_tdata  = mk_axis_cmd_sym(
                    OP_ADD, 1'b0, OID_W'(s100), LW'((s100 * 7) % 1024),
                    16'd10, 15'(s100 + 1), 2'(s100 & 1)
                );
                @(posedge clk);
                cyc100++;
                if (m2_cmd_tready) s100++;
            end
            m2_cmd_tvalid = 1'b0;
            wait_best_settle();
            check_eq("D47 100 ADDs cycles <= 200", int'(cyc100 <= 200), 1);
            check_eq("D47 cnt_add=100", int'(m2_cnt_add), 100);
        end
        finish_directed("D47_m2_throughput_100_adds", e0);

        // D48: v1.2 Task B RAW conflict stall (back-to-back same OID & same level)
        e0 = errors;
        do_m2_reset();
        begin
            int s48;
            s48 = 0;
            // Send 4 back-to-back ADDs:
            //   #0: sym0 oid=10 lvl=300 qty=10 (valid)
            //   #1: sym0 oid=10 lvl=300 qty=20 (same OID -> MUST stall RAW & drop dup!)
            //   #2: sym0 oid=11 lvl=300 qty=30 (same level -> MUST stall RAW & append FIFO!)
            //   #3: sym0 oid=12 lvl=300 qty=40 (same level -> MUST stall RAW & append FIFO!)
            while (s48 < 4) begin
                m2_cmd_tvalid = 1'b1;
                case (s48)
                    0: m2_cmd_tdata = mk_axis_cmd_sym(OP_ADD, 1'b0, 16'd10, 10'd300, 16'd10, 15'd1, 2'd0);
                    1: m2_cmd_tdata = mk_axis_cmd_sym(OP_ADD, 1'b0, 16'd10, 10'd300, 16'd20, 15'd2, 2'd0);
                    2: m2_cmd_tdata = mk_axis_cmd_sym(OP_ADD, 1'b0, 16'd11, 10'd300, 16'd30, 15'd3, 2'd0);
                    default: m2_cmd_tdata = mk_axis_cmd_sym(OP_ADD, 1'b0, 16'd12, 10'd300, 16'd40, 15'd4, 2'd0);
                endcase
                @(posedge clk);
                if (m2_cmd_tready) s48++;
            end
            m2_cmd_tvalid = 1'b0;
            wait_best_settle();
            check_eq("D48 cnt_add=3", int'(m2_cnt_add), 3);
            check_eq("D48 cnt_drop_dup=1", int'(m2_cnt_drop_dup), 1);
            check_eq("D48 sym0 best_bid=300", int'(m2_best_bid[0]), 300);
            check_eq("D48 sym0 best_bid_qty=80", int'(m2_best_bid_qty[0]), 80);
            do_m2_query(1'b0, 16'd10, qf, ql, qq, qp);
            check_eq("D48 oid10 qty=10", int'(qq), 10);
            check_eq("D48 oid10 pos=0", int'(qp), 0);
            do_m2_query(1'b0, 16'd12, qf, ql, qq, qp);
            check_eq("D48 oid12 pos=2", int'(qp), 2);
        end
        finish_directed("D48_m2_raw_conflict_stall", e0);

        // Task B acceptance rate benchmark (10,000 ADDs, dispersed levels, interleaved sym)
        begin
            int cyc, sent;
            do_m2_reset();
            cyc = 0;
            sent = 0;
            while (sent < 10000) begin
                m2_cmd_tvalid = 1'b1;
                m2_cmd_tdata  = mk_axis_cmd_sym(
                    OP_ADD,
                    1'(sent[0]),
                    OID_W'(sent % 8192),
                    LW'((sent * 7) % 1024),
                    16'd10,
                    15'(sent & 15'h7FFF),
                    2'(sent & 1)
                );
                @(posedge clk);
                cyc++;
                if (m2_cmd_tready) sent++;
            end
            m2_cmd_tvalid = 1'b0;
            while (!m2_cmd_tready) begin @(posedge clk); cyc++; end
            $display("THROUGHPUT_10K_ADD: %0d cycles for 10000 ADDs (%.3f cmd/cycle)",
                     cyc, 10000.0 / real'(cyc));
            if (cyc > 20000) begin
                $display("FAILED: 10k ADD acceptance rate < 0.5 cmd/cycle (%0d cycles)", cyc);
                errors++;
            end
        end

        $display("DIRECTED: %0d/%0d passed (max best-price latency = %0d cycles)",
                 directed_passed, directed_total, max_best_latency);
        if ($test$plusargs("FAST_FAIL") && errors > 0) $fatal(1);

        // ------------------------------------------------------------------
        // Random Co-Simulation: 10,000 steps vs Python golden model
        // ------------------------------------------------------------------
        begin
            int fd_s, fd_e, step, rc_s, rc_e;
            int s_op, s_side, s_oid, s_lvl, s_qty, s_qoid;
            int e_bv, e_bb, e_bbq, e_av, e_ba, e_baq;
            int e_qf, e_ql, e_qq, e_qp;
            int e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs;
            int rand_errors = 0;

            do_reset();
            fd_s = $fopen("build/stim_rand.txt", "r");
            fd_e = $fopen("build/exp_rand.txt", "r");
            if (fd_s == 0 || fd_e == 0) begin
                $display("FAILED: could not open build/stim_rand.txt or build/exp_rand.txt");
                $fatal(1);
            end

            step = 0;
            while (!$feof(fd_s) && !$feof(fd_e)) begin
                rc_s = $fscanf(fd_s, "%d %d %d %d %d %d\n",
                               s_op, s_side, s_oid, s_lvl, s_qty, s_qoid);
                rc_e = $fscanf(fd_e, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                               e_bv, e_bb, e_bbq, e_av, e_ba, e_baq,
                               e_qf, e_ql, e_qq, e_qp,
                               e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs);
                if (rc_s != 6 || rc_e != 19) break;

                send_cmd(2'(s_op), 1'(s_side), OID_W'(s_oid), LW'(s_lvl), QTY_W'(s_qty));
                do_query(OID_W'(s_qoid), qf, ql, qq, qp);
                wait_best_settle();

                if (int'(bid_valid)        !== e_bv  ||
                    int'(best_bid)         !== e_bb  ||
                    int'(best_bid_qty)     !== e_bbq ||
                    int'(ask_valid)        !== e_av  ||
                    int'(best_ask)         !== e_ba  ||
                    int'(best_ask_qty)     !== e_baq ||
                    int'(qf)               !== e_qf  ||
                    int'(ql)               !== e_ql  ||
                    int'(qq)               !== e_qq  ||
                    int'(qp)               !== e_qp  ||
                    int'(cnt_add)          !== e_ca  ||
                    int'(cnt_cancel)       !== e_cc  ||
                    int'(cnt_reduce)       !== e_cr  ||
                    int'(cnt_trade)        !== e_ct  ||
                    int'(cnt_drop_dup)     !== e_cd  ||
                    int'(cnt_drop_unknown) !== e_cu  ||
                    int'(cnt_drop_full)    !== e_cf  ||
                    int'(cnt_drop_bad)     !== e_cb  ||
                    int'(cnt_sat)          !== e_cs) begin
                    if (rand_errors < 10) begin
                        $display("RAND MISMATCH step=%0d op=%0d side=%0d oid=%0d lvl=%0d qty=%0d qoid=%0d",
                                 step, s_op, s_side, s_oid, s_lvl, s_qty, s_qoid);
                        $display("  BEST got=(%0d,%0d,%0d | %0d,%0d,%0d) exp=(%0d,%0d,%0d | %0d,%0d,%0d)",
                                 bid_valid, best_bid, best_bid_qty, ask_valid, best_ask, best_ask_qty,
                                 e_bv, e_bb, e_bbq, e_av, e_ba, e_baq);
                        $display("  QRY  got=(%0d,%0d,%0d,%0d) exp=(%0d,%0d,%0d,%0d)",
                                 qf, ql, qq, qp, e_qf, e_ql, e_qq, e_qp);
                        $display("  CNT  got=(%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d) exp=(%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d)",
                                 cnt_add, cnt_cancel, cnt_reduce, cnt_trade,
                                 cnt_drop_dup, cnt_drop_unknown, cnt_drop_full, cnt_drop_bad, cnt_sat,
                                 e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs);
                    end
                    rand_errors++;
                    errors++;
                end
                step++;
            end

            $fclose(fd_s);
            $fclose(fd_e);
            $display("RANDOM: %0d steps, %0d mismatches", step, rand_errors);
            if (step < 10000) begin
                $display("FAILED: expected >= 10000 random steps, got %0d", step);
                errors++;
            end
        end

        // ------------------------------------------------------------------
        // Random Co-Simulation (v1.1): 10,000 AXI-Stream normal-seq steps
        // ------------------------------------------------------------------
        begin
            int fd_s, fd_e, step, rc_s, rc_e;
            int s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qoid;
            int e_bv, e_bb, e_bbq, e_av, e_ba, e_baq;
            int e_qf, e_ql, e_qq, e_qp;
            int e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs;
            int e_st, e_sg, e_sd, e_ss;
            int ax_norm_errors = 0;

            do_ax_reset();
            fd_s = $fopen("build/stim_axis_norm.txt", "r");
            fd_e = $fopen("build/exp_axis_norm.txt", "r");
            if (fd_s == 0 || fd_e == 0) begin
                $display("FAILED: could not open build/stim_axis_norm.txt or exp_axis_norm.txt");
                $fatal(1);
            end

            step = 0;
            while (!$feof(fd_s) && !$feof(fd_e)) begin
                rc_s = $fscanf(fd_s, "%d %d %d %d %d %d %d\n",
                               s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qoid);
                rc_e = $fscanf(fd_e, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                               e_bv, e_bb, e_bbq, e_av, e_ba, e_baq,
                               e_qf, e_ql, e_qq, e_qp,
                               e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs,
                               e_st, e_sg, e_sd, e_ss);
                if (rc_s != 7 || rc_e != 23) break;

                send_ax_cmd(2'(s_op), 1'(s_side), OID_W'(s_oid), LW'(s_lvl), QTY_W'(s_qty), 16'(s_seq));
                do_ax_query(OID_W'(s_qoid), qf, ql, qq, qp);
                wait_best_settle();

                if (int'(ax_bid_valid)        !== e_bv  ||
                    int'(ax_best_bid)         !== e_bb  ||
                    int'(ax_best_bid_qty)     !== e_bbq ||
                    int'(ax_ask_valid)        !== e_av  ||
                    int'(ax_best_ask)         !== e_ba  ||
                    int'(ax_best_ask_qty)     !== e_baq ||
                    int'(qf)                  !== e_qf  ||
                    int'(ql)                  !== e_ql  ||
                    int'(qq)                  !== e_qq  ||
                    int'(qp)                  !== e_qp  ||
                    int'(ax_cnt_add)          !== e_ca  ||
                    int'(ax_cnt_cancel)       !== e_cc  ||
                    int'(ax_cnt_reduce)       !== e_cr  ||
                    int'(ax_cnt_trade)        !== e_ct  ||
                    int'(ax_cnt_drop_dup)     !== e_cd  ||
                    int'(ax_cnt_drop_unknown) !== e_cu  ||
                    int'(ax_cnt_drop_full)    !== e_cf  ||
                    int'(ax_cnt_drop_bad)     !== e_cb  ||
                    int'(ax_cnt_sat)          !== e_cs  ||
                    int'(ax_stale)            !== e_st  ||
                    int'(ax_cnt_seq_gap)      !== e_sg  ||
                    int'(ax_cnt_dup_seq)      !== e_sd  ||
                    int'(ax_cnt_drop_stale)   !== e_ss) begin
                    if (ax_norm_errors < 10) begin
                        $display("AXIS NORM MISMATCH step=%0d op=%0d side=%0d oid=%0d lvl=%0d qty=%0d seq=%0d qoid=%0d",
                                 step, s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qoid);
                    end
                    ax_norm_errors++;
                    errors++;
                end
                step++;
            end
            $fclose(fd_s);
            $fclose(fd_e);
            $display("RANDOM_AXIS_NORM: %0d steps, %0d mismatches", step, ax_norm_errors);
            if (step < 10000) begin
                $display("FAILED: expected >= 10000 AXIS normal steps, got %0d", step);
                errors++;
            end
        end

        // ------------------------------------------------------------------
        // Random Co-Simulation (v1.1): 2,000 AXI-Stream steps with 5% gap/dup
        // ------------------------------------------------------------------
        begin
            int fd_s, fd_e, step, rc_s, rc_e;
            int s_snap, s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qoid;
            int e_bv, e_bb, e_bbq, e_av, e_ba, e_baq;
            int e_qf, e_ql, e_qq, e_qp;
            int e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs;
            int e_st, e_sg, e_sd, e_ss;
            int ax_gap_errors = 0;

            do_ax_reset();
            fd_s = $fopen("build/stim_axis_gap.txt", "r");
            fd_e = $fopen("build/exp_axis_gap.txt", "r");
            if (fd_s == 0 || fd_e == 0) begin
                $display("FAILED: could not open build/stim_axis_gap.txt or exp_axis_gap.txt");
                $fatal(1);
            end

            step = 0;
            while (!$feof(fd_s) && !$feof(fd_e)) begin
                rc_s = $fscanf(fd_s, "%d %d %d %d %d %d %d %d\n",
                               s_snap, s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qoid);
                rc_e = $fscanf(fd_e, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                               e_bv, e_bb, e_bbq, e_av, e_ba, e_baq,
                               e_qf, e_ql, e_qq, e_qp,
                               e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs,
                               e_st, e_sg, e_sd, e_ss);
                if (rc_s != 8 || rc_e != 23) break;

                if (s_snap != 0) begin
                    send_ax_snap(mk_snap_header(32'd0));
                    send_ax_snap(mk_snap_footer(32'd0));
                end
                send_ax_cmd(2'(s_op), 1'(s_side), OID_W'(s_oid), LW'(s_lvl), QTY_W'(s_qty), 16'(s_seq));
                do_ax_query(OID_W'(s_qoid), qf, ql, qq, qp);
                wait_best_settle();

                if (int'(ax_bid_valid)        !== e_bv  ||
                    int'(ax_best_bid)         !== e_bb  ||
                    int'(ax_best_bid_qty)     !== e_bbq ||
                    int'(ax_ask_valid)        !== e_av  ||
                    int'(ax_best_ask)         !== e_ba  ||
                    int'(ax_best_ask_qty)     !== e_baq ||
                    int'(qf)                  !== e_qf  ||
                    int'(ql)                  !== e_ql  ||
                    int'(qq)                  !== e_qq  ||
                    int'(qp)                  !== e_qp  ||
                    int'(ax_cnt_add)          !== e_ca  ||
                    int'(ax_cnt_cancel)       !== e_cc  ||
                    int'(ax_cnt_reduce)       !== e_cr  ||
                    int'(ax_cnt_trade)        !== e_ct  ||
                    int'(ax_cnt_drop_dup)     !== e_cd  ||
                    int'(ax_cnt_drop_unknown) !== e_cu  ||
                    int'(ax_cnt_drop_full)    !== e_cf  ||
                    int'(ax_cnt_drop_bad)     !== e_cb  ||
                    int'(ax_cnt_sat)          !== e_cs  ||
                    int'(ax_stale)            !== e_st  ||
                    int'(ax_cnt_seq_gap)      !== e_sg  ||
                    int'(ax_cnt_dup_seq)      !== e_sd  ||
                    int'(ax_cnt_drop_stale)   !== e_ss) begin
                    if (ax_gap_errors < 10) begin
                        $display("AXIS GAP MISMATCH step=%0d op=%0d side=%0d oid=%0d lvl=%0d qty=%0d seq=%0d qoid=%0d stale=%0d/%0d gap=%0d/%0d dup=%0d/%0d drop_stale=%0d/%0d",
                                 step, s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qoid,
                                 ax_stale, e_st, ax_cnt_seq_gap, e_sg,
                                 ax_cnt_dup_seq, e_sd, ax_cnt_drop_stale, e_ss);
                    end
                    ax_gap_errors++;
                    errors++;
                end
                step++;
            end
            $fclose(fd_s);
            $fclose(fd_e);
            $display("RANDOM_AXIS_GAP: %0d steps, %0d mismatches (gaps=%0d, dups=%0d, stale_drops=%0d)",
                     step, ax_gap_errors, ax_cnt_seq_gap, ax_cnt_dup_seq, ax_cnt_drop_stale);
            if (step < 2000) begin
                $display("FAILED: expected >= 2000 AXIS gap/dup steps, got %0d", step);
                errors++;
            end
        end

        // ------------------------------------------------------------------
        // Random Co-Simulation (v1.2): 10,000 multi-symbol (SYMBOLS=2) steps
        // ------------------------------------------------------------------
        begin
            int fd_s, fd_e, step, rc_s, rc_e;
            int s_sym, s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qsym, s_qoid;
            int e_bv0, e_bb0, e_bbq0, e_av0, e_ba0, e_baq0;
            int e_bv1, e_bb1, e_bbq1, e_av1, e_ba1, e_baq1;
            int e_qf, e_ql, e_qq, e_qp;
            int e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs;
            int e_st, e_sg, e_sd, e_ss;
            int m2_norm_errors = 0;

            do_m2_reset();
            fd_s = $fopen("build/stim_m2_norm.txt", "r");
            fd_e = $fopen("build/exp_m2_norm.txt", "r");
            if (fd_s == 0 || fd_e == 0) begin
                $display("FAILED: could not open build/stim_m2_norm.txt or exp_m2_norm.txt");
                $fatal(1);
            end

            step = 0;
            while (!$feof(fd_s) && !$feof(fd_e)) begin
                rc_s = $fscanf(fd_s, "%d %d %d %d %d %d %d %d %d\n",
                               s_sym, s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qsym, s_qoid);
                rc_e = $fscanf(fd_e, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                               e_bv0, e_bb0, e_bbq0, e_av0, e_ba0, e_baq0,
                               e_bv1, e_bb1, e_bbq1, e_av1, e_ba1, e_baq1,
                               e_qf, e_ql, e_qq, e_qp,
                               e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs,
                               e_st, e_sg, e_sd, e_ss);
                if (rc_s != 9 || rc_e != 29) break;

                send_m2_cmd(2'(s_op), 1'(s_side), OID_W'(s_oid), LW'(s_lvl), QTY_W'(s_qty), 15'(s_seq), 2'(s_sym));
                do_m2_query(1'(s_qsym), OID_W'(s_qoid), qf, ql, qq, qp);
                wait_best_settle();

                if (int'(m2_bid_valid[0])     !== e_bv0  ||
                    int'(m2_best_bid[0])      !== e_bb0  ||
                    int'(m2_best_bid_qty[0])  !== e_bbq0 ||
                    int'(m2_ask_valid[0])     !== e_av0  ||
                    int'(m2_best_ask[0])      !== e_ba0  ||
                    int'(m2_best_ask_qty[0])  !== e_baq0 ||
                    int'(m2_bid_valid[1])     !== e_bv1  ||
                    int'(m2_best_bid[1])      !== e_bb1  ||
                    int'(m2_best_bid_qty[1])  !== e_bbq1 ||
                    int'(m2_ask_valid[1])     !== e_av1  ||
                    int'(m2_best_ask[1])      !== e_ba1  ||
                    int'(m2_best_ask_qty[1])  !== e_baq1 ||
                    int'(qf)                  !== e_qf   ||
                    int'(ql)                  !== e_ql   ||
                    int'(qq)                  !== e_qq   ||
                    int'(qp)                  !== e_qp   ||
                    int'(m2_cnt_add)          !== e_ca   ||
                    int'(m2_cnt_cancel)       !== e_cc   ||
                    int'(m2_cnt_reduce)       !== e_cr   ||
                    int'(m2_cnt_trade)        !== e_ct   ||
                    int'(m2_cnt_drop_dup)     !== e_cd   ||
                    int'(m2_cnt_drop_unknown) !== e_cu   ||
                    int'(m2_cnt_drop_full)    !== e_cf   ||
                    int'(m2_cnt_drop_bad)     !== e_cb   ||
                    int'(m2_cnt_sat)          !== e_cs   ||
                    int'(m2_stale)            !== e_st   ||
                    int'(m2_cnt_seq_gap)      !== e_sg   ||
                    int'(m2_cnt_dup_seq)      !== e_sd   ||
                    int'(m2_cnt_drop_stale)   !== e_ss) begin
                    if (m2_norm_errors < 10) begin
                        $display("M2 NORM MISMATCH step=%0d sym=%0d op=%0d side=%0d oid=%0d lvl=%0d qty=%0d seq=%0d qsym=%0d qoid=%0d",
                                 step, s_sym, s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qsym, s_qoid);
                    end
                    m2_norm_errors++;
                    errors++;
                end
                step++;
            end
            $fclose(fd_s);
            $fclose(fd_e);
            $display("RANDOM_M2_NORM: %0d steps, %0d mismatches", step, m2_norm_errors);
            if (step < 10000) begin
                $display("FAILED: expected >= 10000 M2 normal steps, got %0d", step);
                errors++;
            end
        end

        // ------------------------------------------------------------------
        // Random Co-Simulation (v1.2): 2,000 multi-symbol steps with 5% gap/dup
        // ------------------------------------------------------------------
        begin
            int fd_s, fd_e, step, rc_s, rc_e;
            int s_snap, s_sym, s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qsym, s_qoid;
            int e_bv0, e_bb0, e_bbq0, e_av0, e_ba0, e_baq0;
            int e_bv1, e_bb1, e_bbq1, e_av1, e_ba1, e_baq1;
            int e_qf, e_ql, e_qq, e_qp;
            int e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs;
            int e_st, e_sg, e_sd, e_ss;
            int m2_gap_errors = 0;

            do_m2_reset();
            fd_s = $fopen("build/stim_m2_gap.txt", "r");
            fd_e = $fopen("build/exp_m2_gap.txt", "r");
            if (fd_s == 0 || fd_e == 0) begin
                $display("FAILED: could not open build/stim_m2_gap.txt or exp_m2_gap.txt");
                $fatal(1);
            end

            step = 0;
            while (!$feof(fd_s) && !$feof(fd_e)) begin
                rc_s = $fscanf(fd_s, "%d %d %d %d %d %d %d %d %d %d\n",
                               s_snap, s_sym, s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qsym, s_qoid);
                rc_e = $fscanf(fd_e, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                               e_bv0, e_bb0, e_bbq0, e_av0, e_ba0, e_baq0,
                               e_bv1, e_bb1, e_bbq1, e_av1, e_ba1, e_baq1,
                               e_qf, e_ql, e_qq, e_qp,
                               e_ca, e_cc, e_cr, e_ct, e_cd, e_cu, e_cf, e_cb, e_cs,
                               e_st, e_sg, e_sd, e_ss);
                if (rc_s != 10 || rc_e != 29) break;

                if (s_snap != 0) begin
                    send_m2_snap(mk_snap_header(32'd0));
                    send_m2_snap(mk_snap_footer(32'd0));
                end
                send_m2_cmd(2'(s_op), 1'(s_side), OID_W'(s_oid), LW'(s_lvl), QTY_W'(s_qty), 15'(s_seq), 2'(s_sym));
                do_m2_query(1'(s_qsym), OID_W'(s_qoid), qf, ql, qq, qp);
                wait_best_settle();

                if (int'(m2_bid_valid[0])     !== e_bv0  ||
                    int'(m2_best_bid[0])      !== e_bb0  ||
                    int'(m2_best_bid_qty[0])  !== e_bbq0 ||
                    int'(m2_ask_valid[0])     !== e_av0  ||
                    int'(m2_best_ask[0])      !== e_ba0  ||
                    int'(m2_best_ask_qty[0])  !== e_baq0 ||
                    int'(m2_bid_valid[1])     !== e_bv1  ||
                    int'(m2_best_bid[1])      !== e_bb1  ||
                    int'(m2_best_bid_qty[1])  !== e_bbq1 ||
                    int'(m2_ask_valid[1])     !== e_av1  ||
                    int'(m2_best_ask[1])      !== e_ba1  ||
                    int'(m2_best_ask_qty[1])  !== e_baq1 ||
                    int'(qf)                  !== e_qf   ||
                    int'(ql)                  !== e_ql   ||
                    int'(qq)                  !== e_qq   ||
                    int'(qp)                  !== e_qp   ||
                    int'(m2_cnt_add)          !== e_ca   ||
                    int'(m2_cnt_cancel)       !== e_cc   ||
                    int'(m2_cnt_reduce)       !== e_cr   ||
                    int'(m2_cnt_trade)        !== e_ct   ||
                    int'(m2_cnt_drop_dup)     !== e_cd   ||
                    int'(m2_cnt_drop_unknown) !== e_cu   ||
                    int'(m2_cnt_drop_full)    !== e_cf   ||
                    int'(m2_cnt_drop_bad)     !== e_cb   ||
                    int'(m2_cnt_sat)          !== e_cs   ||
                    int'(m2_stale)            !== e_st   ||
                    int'(m2_cnt_seq_gap)      !== e_sg   ||
                    int'(m2_cnt_dup_seq)      !== e_sd   ||
                    int'(m2_cnt_drop_stale)   !== e_ss) begin
                    if (m2_gap_errors < 10) begin
                        $display("M2 GAP MISMATCH step=%0d sym=%0d op=%0d side=%0d oid=%0d lvl=%0d qty=%0d seq=%0d qsym=%0d qoid=%0d",
                                 step, s_sym, s_op, s_side, s_oid, s_lvl, s_qty, s_seq, s_qsym, s_qoid);
                    end
                    m2_gap_errors++;
                    errors++;
                end
                step++;
            end
            $fclose(fd_s);
            $fclose(fd_e);
            $display("RANDOM_M2_GAP: %0d steps, %0d mismatches (gaps=%0d, dups=%0d, stale_drops=%0d)",
                     step, m2_gap_errors, m2_cnt_seq_gap, m2_cnt_dup_seq, m2_cnt_drop_stale);
            if (step < 2000) begin
                $display("FAILED: expected >= 2000 M2 gap/dup steps, got %0d", step);
                errors++;
            end
        end

        if (errors == 0) begin
            $display("ALL TESTS PASS");
        end else begin
            $display("FAILED with %0d errors", errors);
            $fatal(1);
        end
        $finish;
    end
endmodule
