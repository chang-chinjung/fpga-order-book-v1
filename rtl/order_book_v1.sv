`timescale 1ns / 1ps

// Order-by-order limit order book v1.0
// Full implementation: ADD / CANCEL / REDUCE (with saturation) / TRADE (multi-cycle FSM),
// per-level FIFO linked list, read-only query with queue position (capped at 63),
// occupancy bitmap best bid/ask, BRAM-registered read pipeline for >=100 MHz ECP5 timing.
module order_book_v1 #(
    parameter int LEVELS     = 1024,
    parameter int MAX_ORDERS = 8192,
    parameter int QTY_W      = 16,
    parameter int OID_W      = 16,
    parameter int CNT_W      = 16,
    parameter bit USE_AXIS   = 1'b0,
    parameter int LW         = (LEVELS <= 2) ? 1 : $clog2(LEVELS),
    parameter int OW         = (MAX_ORDERS <= 2) ? 1 : $clog2(MAX_ORDERS)
) (
    input  logic             clk,
    input  logic             rst_n,

    // Legacy command interface (§3.1 + v1.1 seq, active when USE_AXIS=0)
    input  logic             cmd_valid,
    output logic             cmd_ready,
    input  logic [1:0]       cmd_op,      // 0=ADD, 1=CANCEL, 2=REDUCE, 3=TRADE
    input  logic             cmd_side,    // 0=bid, 1=ask
    input  logic [OID_W-1:0] cmd_oid,     // ignored for TRADE
    input  logic [LW-1:0]    cmd_level,   // required for ADD, TRADE
    input  logic [QTY_W-1:0] cmd_qty,     // 0 is invalid
    input  logic             cmd_seq_en,  // 1 = check 16-bit cmd_seq (legacy mode)
    input  logic [15:0]      cmd_seq,     // 16-bit sequence number (mod 65536)

    // AXI4-Stream command slave (§B.1, active when USE_AXIS=1)
    input  logic             s_axis_cmd_tvalid,
    output logic             s_axis_cmd_tready,
    input  logic [63:0]      s_axis_cmd_tdata,

    // AXI4-Stream best-price master (§B.2)
    output logic             s_axis_best_tvalid,
    input  logic             s_axis_best_tready,
    output logic [53:0]      s_axis_best_tdata,

    // Query interface (§3.2)
    input  logic             qry_valid,
    output logic             qry_ready,
    input  logic [OID_W-1:0] qry_oid,
    output logic             qry_found,
    output logic [LW-1:0]    qry_level,
    output logic [QTY_W-1:0] qry_qty,
    output logic [5:0]       qry_pos,

    // Best price outputs (§3.3)
    output logic             bid_valid,
    output logic [LW-1:0]    best_bid,
    output logic [QTY_W-1:0] best_bid_qty,
    output logic             ask_valid,
    output logic [LW-1:0]    best_ask,
    output logic [QTY_W-1:0] best_ask_qty,

    // Counters (§3.4, §5, §7)
    output logic [CNT_W-1:0] cnt_add,
    output logic [CNT_W-1:0] cnt_cancel,
    output logic [CNT_W-1:0] cnt_reduce,
    output logic [CNT_W-1:0] cnt_trade,
    output logic [CNT_W-1:0] cnt_drop_dup,
    output logic [CNT_W-1:0] cnt_drop_unknown,
    output logic [CNT_W-1:0] cnt_drop_full,
    output logic [CNT_W-1:0] cnt_drop_bad,
    output logic [CNT_W-1:0] cnt_sat,

    // v1.1 snapshot interface (§B.4)
    input  logic             snapshot_valid,
    output logic             snapshot_ready,
    input  logic [63:0]      snapshot_data,

    // v1.1 seq gap & snapshot status/counters (§B.3, §B.4, §B.5)
    output logic             stale,
    output logic             snapshot_error,
    output logic [CNT_W-1:0] cnt_seq_gap,
    output logic [CNT_W-1:0] cnt_dup_seq,
    output logic [CNT_W-1:0] cnt_drop_stale,
    output logic [CNT_W-1:0] cnt_drop_load
);

    localparam logic [1:0] OP_ADD    = 2'd0;
    localparam logic [1:0] OP_CANCEL = 2'd1;
    localparam logic [1:0] OP_REDUCE = 2'd2;
    localparam logic [1:0] OP_TRADE  = 2'd3;

    // Link pointer: MSB=1 valid, MSB=0 INVALID
    localparam int PW = OW + 1;
    localparam logic [PW-1:0] PTR_INVALID = '0;

    // ---------------- Command FSM (one-hot encoded for >=120 MHz ECP5) ----------------
    localparam int ST_INIT       = 0;
    localparam int ST_IDLE       = 1;
    localparam int ST_RD_ADDR    = 2;
    localparam int ST_RD_WAIT    = 3;
    localparam int ST_RD_PIPE    = 4;
    localparam int ST_EXEC1      = 5;
    localparam int ST_ADD_LINK   = 6;
    localparam int ST_LVL_WAIT   = 7;
    localparam int ST_UPD_LVL    = 8;
    localparam int ST_TRD_ADDR   = 9;
    localparam int ST_TRD_WAIT   = 10;
    localparam int ST_TRD_PIPE   = 11;
    localparam int ST_TRADE_STEP = 12;
    localparam int ST_WR_COMMIT  = 13;
    localparam int ST_SNAP_WAIT  = 14;

    localparam logic [14:0] S_INIT       = 15'd1 << ST_INIT;
    localparam logic [14:0] S_IDLE       = 15'd1 << ST_IDLE;
    localparam logic [14:0] S_RD_ADDR    = 15'd1 << ST_RD_ADDR;
    localparam logic [14:0] S_RD_WAIT    = 15'd1 << ST_RD_WAIT;
    localparam logic [14:0] S_RD_PIPE    = 15'd1 << ST_RD_PIPE;
    localparam logic [14:0] S_EXEC1      = 15'd1 << ST_EXEC1;
    localparam logic [14:0] S_ADD_LINK   = 15'd1 << ST_ADD_LINK;
    localparam logic [14:0] S_LVL_WAIT   = 15'd1 << ST_LVL_WAIT;
    localparam logic [14:0] S_UPD_LVL    = 15'd1 << ST_UPD_LVL;
    localparam logic [14:0] S_TRD_ADDR   = 15'd1 << ST_TRD_ADDR;
    localparam logic [14:0] S_TRD_WAIT   = 15'd1 << ST_TRD_WAIT;
    localparam logic [14:0] S_TRD_PIPE   = 15'd1 << ST_TRD_PIPE;
    localparam logic [14:0] S_TRADE_STEP = 15'd1 << ST_TRADE_STEP;
    localparam logic [14:0] S_WR_COMMIT  = 15'd1 << ST_WR_COMMIT;
    localparam logic [14:0] S_SNAP_WAIT  = 15'd1 << ST_SNAP_WAIT;

    (* fsm_encoding = "user" *) logic [14:0] state;
    wire cmd_ready_r = state[ST_IDLE];
    assign snapshot_ready = state[ST_IDLE] || state[ST_SNAP_WAIT];

    // Command source mux (USE_AXIS=1 -> AXI4-Stream slave; USE_AXIS=0 -> legacy cmd_*)
    wire             eff_cmd_valid  = USE_AXIS ? s_axis_cmd_tvalid          : cmd_valid;
    wire [1:0]       eff_cmd_op     = USE_AXIS ? s_axis_cmd_tdata[1:0]      : cmd_op;
    wire             eff_cmd_side   = USE_AXIS ? s_axis_cmd_tdata[2]        : cmd_side;
    wire [OID_W-1:0] eff_cmd_oid    = USE_AXIS ? s_axis_cmd_tdata[3 +: OID_W] : cmd_oid;
    wire [LW-1:0]    eff_cmd_level  = USE_AXIS ? s_axis_cmd_tdata[19 +: LW] : cmd_level;
    wire [QTY_W-1:0] eff_cmd_qty    = USE_AXIS ? s_axis_cmd_tdata[29 +: QTY_W] : cmd_qty;
    wire [15:0]      eff_cmd_seq    = USE_AXIS ? s_axis_cmd_tdata[60:45]    : cmd_seq;
    wire             eff_cmd_seq_en = USE_AXIS ? 1'b1                       : cmd_seq_en;
    wire _unused_axis_cmd = &{1'b0, s_axis_cmd_tdata[63:61]};

    logic [OW-1:0] init_idx;
    logic [OW:0]   total_orders;

    // Snapshot reload state
    localparam logic [1:0] SNAP_HEADER = 2'd0;
    localparam logic [1:0] SNAP_LEVEL  = 2'd1;
    localparam logic [1:0] SNAP_ORDER  = 2'd2;
    localparam logic [1:0] SNAP_FOOTER = 2'd3;

    wire [1:0]       snap_type  = snapshot_data[63:62];
    wire             snap_side  = snapshot_data[1];
    wire [LW-1:0]    snap_level = snapshot_data[2 +: LW];
    wire [QTY_W-1:0] snap_qty   = snapshot_data[12 +: QTY_W];
    wire [OID_W-1:0] snap_oid   = snapshot_data[28 +: OID_W];
    wire [OW-1:0]    snap_slot  = snapshot_data[28 +: OW];
    wire [31:0]      snap_cnt   = snapshot_data[31:0];
    wire _unused_snap = &{1'b0, snapshot_data[0], snapshot_data[61:44]};

    logic        snap_loading;
    logic [31:0] snap_exp_cnt;
    logic [31:0] snap_obs_cnt;
    logic        bm_clear_r;
    logic        drop_load_seen;

    // Latched command registers
    logic [1:0]       r_op;
    logic             r_side;
    logic [OID_W-1:0] r_oid;
    logic [LW-1:0]    r_level;
    logic [QTY_W-1:0] r_qty;
    logic [OW-1:0]    r_slot;
    logic             r_seq_en;
    logic [15:0]      r_seq;

    // Sequence gap tracking (16-bit mod 65536)
    logic             seq_init;
    logic [15:0]      prev_seq;
    logic [15:0]      prev_seq_plus1;
    logic             r_drop_stale;
    logic             r_drop_dup;
    logic             r_drop_gap;
    wire              r_seq_drop = r_drop_stale || r_drop_dup || r_drop_gap;

    // Working registers for multi-cycle ADD / CANCEL / REDUCE
    logic [OW-1:0]    w_old_tail;
    logic             w_side;
    logic [LW-1:0]    w_level;
    logic [QTY_W-1:0] w_qty;
    logic [PW-1:0]    w_prev;
    logic [PW-1:0]    w_next;
    logic             w_remove;
    logic             w_is_reduce;
    logic             w_sat;

    // Trade loop working registers
    logic             t_side;
    logic [QTY_W-1:0] t_qty;
    logic [OW:0]      t_cnt;
    logic [PW-1:0]    t_head;
    logic [PW-1:0]    t_tail;
    logic [QTY_W-1:0] t_rem;

    // ---------------- Query FSM ----------------
    typedef enum logic [3:0] {
        Q_IDLE  = 4'd0,
        Q_ADDR0 = 4'd1,
        Q_WAIT0 = 4'd2,
        Q_PIPE0 = 4'd3,
        Q_READ0 = 4'd4,
        Q_ADDRW = 4'd5,
        Q_WAITW = 4'd6,
        Q_PIPEW = 4'd7,
        Q_WALK  = 4'd8,
        Q_DONE  = 4'd9
    } q_state_t;

    q_state_t q_state;
    wire cmd_busy = !cmd_ready_r || eff_cmd_valid;
    wire [OW-1:0] qry_slot = qry_oid[OW-1:0];
    wire qry_oob = (qry_oid >= OID_W'(MAX_ORDERS));

    // ---------------- Synchronous BRAM Read Pipeline ----------------
    // ord_rd_addr_r: dedicated FF before the 29 order-store DP16KD ADB pins (0 LUTs)
    // lvl_rd_addr:   simple 2:1 mux before the 8 ladder DP16KD ADB pins (1 LUT)
    // dp_*:          DP16KD built-in OUTREG (Tco = 0.96 ns)
    // r2_*:          fabric FF placed next to ALU (absorbs BRAM-column routing)
    wire [OW-1:0] cmd_slot = eff_cmd_oid[OW-1:0];
    logic [OW-1:0] ord_rd_addr_r;
    wire  [LW-1:0] lvl_rd_addr = state[ST_EXEC1] ? r2_o_meta[LW-1:0] : r_level;

    logic             dp_o_valid,  r2_o_valid;
    logic [QTY_W-1:0] dp_o_qty,    r2_o_qty;
    logic [LW:0]      dp_o_meta,   r2_o_meta;
    logic [PW-1:0]    dp_o_prev,   r2_o_prev;
    logic [PW-1:0]    dp_o_next,   r2_o_next;
    logic [QTY_W-1:0] r2_bid_qty;
    logic [OW:0]      r2_bid_cnt;
    logic [PW-1:0]    r2_bid_head;
    logic [PW-1:0]    r2_bid_tail;
    logic [QTY_W-1:0] r2_ask_qty;
    logic [OW:0]      r2_ask_cnt;
    logic [PW-1:0]    r2_ask_head;
    logic [PW-1:0]    r2_ask_tail;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ord_rd_addr_r <= '0;
        end else begin
            if (state[ST_IDLE] && eff_cmd_valid) begin
                ord_rd_addr_r <= cmd_slot;
            end else if (state[ST_SNAP_WAIT] && snapshot_valid && (snap_type == SNAP_ORDER)) begin
                ord_rd_addr_r <= snap_slot;
            end else if (state[ST_EXEC1]) begin
                ord_rd_addr_r <= r_side ? r2_ask_head[OW-1:0] : r2_bid_head[OW-1:0];
            end else if (state[ST_TRADE_STEP]) begin
                ord_rd_addr_r <= r2_o_next[OW-1:0];
            end else if (!cmd_busy) begin
                if (q_state == Q_IDLE) begin
                    ord_rd_addr_r <= qry_slot;
                end else if ((q_state == Q_READ0) || (q_state == Q_WALK)) begin
                    ord_rd_addr_r <= r2_o_prev[OW-1:0];
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        r2_o_valid <= dp_o_valid;
        r2_o_qty   <= dp_o_qty;
        r2_o_meta  <= dp_o_meta;
        r2_o_prev  <= dp_o_prev;
        r2_o_next  <= dp_o_next;
    end

    // ---------------- BRAM Write Ports (registered inputs for >=120 MHz ECP5) ----------------
    logic             wr_oval_en,   wr_oval_en_r;
    logic [OW-1:0]    wr_oval_addr, wr_oval_addr_r;
    logic             wr_oval_data, wr_oval_data_r;

    logic             wr_oqty_en,   wr_oqty_en_r;
    logic [OW-1:0]    wr_oqty_addr, wr_oqty_addr_r;
    logic [QTY_W-1:0] wr_oqty_data, wr_oqty_data_r;

    logic             wr_ometa_en,   wr_ometa_en_r;
    logic [OW-1:0]    wr_ometa_addr, wr_ometa_addr_r;
    logic [LW:0]      wr_ometa_data, wr_ometa_data_r;

    logic             wr_oprev_en,   wr_oprev_en_r;
    logic [OW-1:0]    wr_oprev_addr, wr_oprev_addr_r;
    logic [PW-1:0]    wr_oprev_data, wr_oprev_data_r;

    logic             wr_onext_en,   wr_onext_en_r;
    logic [OW-1:0]    wr_onext_addr, wr_onext_addr_r;
    logic [PW-1:0]    wr_onext_data, wr_onext_data_r;

    logic             wr_bid_en,    wr_bid_en_r;
    logic             wr_ask_en,    wr_ask_en_r;
    logic [LW-1:0]    wr_lvl_addr,  wr_lvl_addr_r;
    logic             qwr_zero,     qwr_zero_r;
    logic             qwr_add,      qwr_add_r;
    logic [QTY_W-1:0] qwr_a,        qwr_a_r;
    logic [QTY_W-1:0] qwr_b,        qwr_b_r;
    wire  [QTY_W-1:0] wr_lvl_qty_r = qwr_zero_r ? '0 : (qwr_add_r ? (qwr_a_r + qwr_b_r) : (qwr_a_r - qwr_b_r));
    logic [OW:0]      wr_lvl_cnt,   wr_lvl_cnt_r;
    logic [PW-1:0]    wr_lvl_head,  wr_lvl_head_r;
    logic [PW-1:0]    wr_lvl_tail,  wr_lvl_tail_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_oval_en_r    <= 1'b0;
            wr_oval_addr_r  <= '0;
            wr_oval_data_r  <= 1'b0;
            wr_oqty_en_r    <= 1'b0;
            wr_oqty_addr_r  <= '0;
            wr_oqty_data_r  <= '0;
            wr_ometa_en_r   <= 1'b0;
            wr_ometa_addr_r <= '0;
            wr_ometa_data_r <= '0;
            wr_oprev_en_r   <= 1'b0;
            wr_oprev_addr_r <= '0;
            wr_oprev_data_r <= PTR_INVALID;
            wr_onext_en_r   <= 1'b0;
            wr_onext_addr_r <= '0;
            wr_onext_data_r <= PTR_INVALID;
            wr_bid_en_r     <= 1'b0;
            wr_ask_en_r     <= 1'b0;
            wr_lvl_addr_r   <= '0;
            qwr_zero_r      <= 1'b1;
            qwr_add_r       <= 1'b0;
            qwr_a_r         <= '0;
            qwr_b_r         <= '0;
            wr_lvl_cnt_r    <= '0;
            wr_lvl_head_r   <= PTR_INVALID;
            wr_lvl_tail_r   <= PTR_INVALID;
        end else begin
            wr_oval_en_r    <= wr_oval_en;
            wr_oval_addr_r  <= wr_oval_addr;
            wr_oval_data_r  <= wr_oval_data;
            wr_oqty_en_r    <= wr_oqty_en;
            wr_oqty_addr_r  <= wr_oqty_addr;
            wr_oqty_data_r  <= wr_oqty_data;
            wr_ometa_en_r   <= wr_ometa_en;
            wr_ometa_addr_r <= wr_ometa_addr;
            wr_ometa_data_r <= wr_ometa_data;
            wr_oprev_en_r   <= wr_oprev_en;
            wr_oprev_addr_r <= wr_oprev_addr;
            wr_oprev_data_r <= wr_oprev_data;
            wr_onext_en_r   <= wr_onext_en;
            wr_onext_addr_r <= wr_onext_addr;
            wr_onext_data_r <= wr_onext_data;
            wr_bid_en_r     <= wr_bid_en;
            wr_ask_en_r     <= wr_ask_en;
            wr_lvl_addr_r   <= wr_lvl_addr;
            qwr_zero_r      <= qwr_zero;
            qwr_add_r       <= qwr_add;
            qwr_a_r         <= qwr_a;
            qwr_b_r         <= qwr_b;
            wr_lvl_cnt_r    <= wr_lvl_cnt;
            wr_lvl_head_r   <= wr_lvl_head;
            wr_lvl_tail_r   <= wr_lvl_tail;
        end
    end

    // Order store & Price ladder BRAMs with built-in DP16KD OUTREG (2-cycle read latency)
    bram_sdp #(.DEPTH(MAX_ORDERS), .WIDTH(1))     u_o_valid (.clk(clk), .we(wr_oval_en_r),  .waddr(wr_oval_addr_r),  .wdata(wr_oval_data_r),  .raddr(ord_rd_addr_r), .rdata(dp_o_valid));
    bram_sdp #(.DEPTH(MAX_ORDERS), .WIDTH(QTY_W)) u_o_qty   (.clk(clk), .we(wr_oqty_en_r),  .waddr(wr_oqty_addr_r),  .wdata(wr_oqty_data_r),  .raddr(ord_rd_addr_r), .rdata(dp_o_qty));
    bram_sdp #(.DEPTH(MAX_ORDERS), .WIDTH(LW+1))  u_o_meta  (.clk(clk), .we(wr_ometa_en_r), .waddr(wr_ometa_addr_r), .wdata(wr_ometa_data_r), .raddr(ord_rd_addr_r), .rdata(dp_o_meta));
    bram_sdp #(.DEPTH(MAX_ORDERS), .WIDTH(PW))    u_o_prev  (.clk(clk), .we(wr_oprev_en_r), .waddr(wr_oprev_addr_r), .wdata(wr_oprev_data_r), .raddr(ord_rd_addr_r), .rdata(dp_o_prev));
    bram_sdp #(.DEPTH(MAX_ORDERS), .WIDTH(PW))    u_o_next  (.clk(clk), .we(wr_onext_en_r), .waddr(wr_onext_addr_r), .wdata(wr_onext_data_r), .raddr(ord_rd_addr_r), .rdata(dp_o_next));

    bram_sdp #(.DEPTH(LEVELS), .WIDTH(QTY_W)) u_bid_qty  (.clk(clk), .we(wr_bid_en_r), .waddr(wr_lvl_addr_r), .wdata(wr_lvl_qty_r),  .raddr(lvl_rd_addr), .rdata(r2_bid_qty));
    bram_sdp #(.DEPTH(LEVELS), .WIDTH(OW+1))  u_bid_cnt  (.clk(clk), .we(wr_bid_en_r), .waddr(wr_lvl_addr_r), .wdata(wr_lvl_cnt_r),  .raddr(lvl_rd_addr), .rdata(r2_bid_cnt));
    bram_sdp #(.DEPTH(LEVELS), .WIDTH(PW))    u_bid_head (.clk(clk), .we(wr_bid_en_r), .waddr(wr_lvl_addr_r), .wdata(wr_lvl_head_r), .raddr(lvl_rd_addr), .rdata(r2_bid_head));
    bram_sdp #(.DEPTH(LEVELS), .WIDTH(PW))    u_bid_tail (.clk(clk), .we(wr_bid_en_r), .waddr(wr_lvl_addr_r), .wdata(wr_lvl_tail_r), .raddr(lvl_rd_addr), .rdata(r2_bid_tail));

    bram_sdp #(.DEPTH(LEVELS), .WIDTH(QTY_W)) u_ask_qty  (.clk(clk), .we(wr_ask_en_r), .waddr(wr_lvl_addr_r), .wdata(wr_lvl_qty_r),  .raddr(lvl_rd_addr), .rdata(r2_ask_qty));
    bram_sdp #(.DEPTH(LEVELS), .WIDTH(OW+1))  u_ask_cnt  (.clk(clk), .we(wr_ask_en_r), .waddr(wr_lvl_addr_r), .wdata(wr_lvl_cnt_r),  .raddr(lvl_rd_addr), .rdata(r2_ask_cnt));
    bram_sdp #(.DEPTH(LEVELS), .WIDTH(PW))    u_ask_head (.clk(clk), .we(wr_ask_en_r), .waddr(wr_lvl_addr_r), .wdata(wr_lvl_head_r), .raddr(lvl_rd_addr), .rdata(r2_ask_head));
    bram_sdp #(.DEPTH(LEVELS), .WIDTH(PW))    u_ask_tail (.clk(clk), .we(wr_ask_en_r), .waddr(wr_lvl_addr_r), .wdata(wr_lvl_tail_r), .raddr(lvl_rd_addr), .rdata(r2_ask_tail));

    // ---------------- Helper Signals ----------------
    // Pre-register bad_cmd and is_full during S_RD_WAIT (zero extra cycles)
    // and decouple S_EXEC1 (r_side) from S_UPD_LVL (w_side) to eliminate state->state loops.
    logic r_bad_cmd;
    logic r_is_full;

    // Single-bit head valid MSB is equivalent to (l_count != 0) by FIFO invariant,
    // eliminating two 14-bit OR trees from S_EXEC1.
    wire             r_bid_nz    = r2_bid_head[OW];
    wire             r_ask_nz    = r2_ask_head[OW];
    wire             add_lvl_nz  = r_side ? r_ask_nz    : r_bid_nz;
    wire [QTY_W-1:0] add_l_qty   = r_side ? r2_ask_qty  : r2_bid_qty;
    wire [OW:0]      add_l_cnt   = r_side ? r2_ask_cnt  : r2_bid_cnt;
    wire [PW-1:0]    add_l_head  = r_side ? r2_ask_head : r2_bid_head;
    wire [PW-1:0]    add_l_tail  = r_side ? r2_ask_tail : r2_bid_tail;

    wire [QTY_W-1:0] upd_l_qty   = w_side ? r2_ask_qty  : r2_bid_qty;
    wire [OW:0]      upd_l_cnt   = w_side ? r2_ask_cnt  : r2_bid_cnt;
    wire [PW-1:0]    upd_l_head  = w_side ? r2_ask_head : r2_bid_head;
    wire [PW-1:0]    upd_l_tail  = w_side ? r2_ask_tail : r2_bid_tail;

    // Pre-registered 16-bit comparisons (computed during S_RD_PIPE / S_TRD_PIPE
    // from dp_o_qty so S_EXEC1 and S_TRADE_STEP have zero carry chains into FSM).
    logic red_remove;
    logic red_sat;
    logic t_partial;
    logic t_rem_eq;
    wire [QTY_W-1:0] red_dec = red_remove ? r2_o_qty : r_qty;

    // Trade step helpers
    // TRADE selects the side from cmd_side (r_side); the other side is untouched.
    wire             trade_sel_empty = r_side ? !r_ask_nz : !r_bid_nz;
    wire [QTY_W-1:0] next_t_qty    = t_qty - r2_o_qty;
    wire [OW:0]      next_t_cnt    = t_cnt - 1'b1;
    wire [QTY_W-1:0] next_t_rem    = t_rem - r2_o_qty;
    wire             t_consume_end = t_rem_eq || (t_cnt == (OW+1)'(1));

    // ---------------- Combinational BRAM Write Controls ----------------
    // Drive write addresses purely from state (independent of data comparisons)
    // so data comparators only gate write-enable, keeping BRAM addr timing fast.
    always_comb begin
        wr_oval_en    = 1'b0;
        wr_oval_addr  = state[ST_INIT]       ? init_idx :
                        state[ST_TRADE_STEP] ? t_head[OW-1:0] : r_slot;
        wr_oval_data  = state[ST_EXEC1] && (r_op == OP_ADD);

        wr_oqty_en    = 1'b0;
        wr_oqty_addr  = state[ST_TRADE_STEP] ? t_head[OW-1:0] : r_slot;
        wr_oqty_data  = state[ST_TRADE_STEP] ? (r2_o_qty - t_rem) :
                        (r_op == OP_REDUCE)  ? (r2_o_qty - r_qty) : r_qty;

        wr_ometa_en   = 1'b0;
        wr_ometa_addr = r_slot;
        wr_ometa_data = {r_side, r_level};

        wr_oprev_en   = 1'b0;
        wr_oprev_addr = state[ST_TRADE_STEP] ? r2_o_next[OW-1:0] :
                        (r_op == OP_ADD)     ? r_slot : r2_o_next[OW-1:0];
        wr_oprev_data = state[ST_TRADE_STEP] ? PTR_INVALID :
                        (r_op == OP_ADD)     ? (add_lvl_nz ? add_l_tail : PTR_INVALID) :
                                               r2_o_prev;

        wr_onext_en   = 1'b0;
        wr_onext_addr = state[ST_ADD_LINK] ? w_old_tail :
                        (r_op == OP_ADD)   ? r_slot : r2_o_prev[OW-1:0];
        wr_onext_data = state[ST_ADD_LINK] ? {1'b1, r_slot} :
                        (r_op == OP_ADD)   ? PTR_INVALID : r2_o_next;

        wr_bid_en     = 1'b0;
        wr_ask_en     = 1'b0;
        wr_lvl_addr   = state[ST_INIT]    ? init_idx[LW-1:0] :
                        state[ST_UPD_LVL] ? w_level : r_level;
        qwr_zero      = 1'b1;
        qwr_add       = 1'b0;
        qwr_a         = '0;
        qwr_b         = '0;
        wr_lvl_cnt    = '0;
        wr_lvl_head   = PTR_INVALID;
        wr_lvl_tail   = PTR_INVALID;

        if (state[ST_INIT]) begin
            wr_oval_en = 1'b1;
            if (init_idx < OW'(LEVELS)) begin
                wr_bid_en = 1'b1;
                wr_ask_en = 1'b1;
            end
        end else if (state[ST_EXEC1]) begin
            if (!r_seq_drop && !r_bad_cmd) begin
                if ((r_op == OP_ADD) && !r_is_full && !r2_o_valid) begin
                    wr_oval_en  = 1'b1;
                    wr_oqty_en  = 1'b1;
                    wr_ometa_en = 1'b1;
                    wr_oprev_en = 1'b1;
                    wr_onext_en = 1'b1;

                    wr_bid_en   = !r_side;
                    wr_ask_en   =  r_side;
                    qwr_zero    = 1'b0;
                    qwr_add     = 1'b1;
                    qwr_a       = add_l_qty;
                    qwr_b       = r_qty;
                    wr_lvl_cnt  = add_l_cnt + 1'b1;
                    wr_lvl_head = add_lvl_nz ? add_l_head : {1'b1, r_slot};
                    wr_lvl_tail = {1'b1, r_slot};
                end else if (((r_op == OP_CANCEL) || ((r_op == OP_REDUCE) && red_remove)) && r2_o_valid) begin
                    wr_oval_en = 1'b1;
                    if (r2_o_prev[OW]) wr_onext_en = 1'b1;
                    if (r2_o_next[OW]) wr_oprev_en = 1'b1;
                end else if ((r_op == OP_REDUCE) && r2_o_valid && !red_remove) begin
                    wr_oqty_en = 1'b1;
                end
            end
        end else if (state[ST_ADD_LINK]) begin
            wr_onext_en = 1'b1;
        end else if (state[ST_UPD_LVL]) begin
            wr_bid_en   = !w_side;
            wr_ask_en   =  w_side;
            qwr_zero    = 1'b0;
            qwr_add     = 1'b0;
            qwr_a       = upd_l_qty;
            qwr_b       = w_qty;
            wr_lvl_cnt  = w_remove ? (upd_l_cnt - 1'b1) : upd_l_cnt;
            wr_lvl_head = w_remove ? (w_prev[OW] ? upd_l_head : w_next) : upd_l_head;
            wr_lvl_tail = w_remove ? (w_next[OW] ? upd_l_tail : w_prev) : upd_l_tail;
        end else if (state[ST_TRADE_STEP]) begin
            if (t_partial) begin
                wr_oqty_en  = 1'b1;
                wr_bid_en   = !t_side;
                wr_ask_en   =  t_side;
                qwr_zero    = 1'b0;
                qwr_add     = 1'b0;
                qwr_a       = t_qty;
                qwr_b       = t_rem;
                wr_lvl_cnt  = t_cnt;
                wr_lvl_head = t_head;
                wr_lvl_tail = t_tail;
            end else begin
                wr_oval_en = 1'b1;
                if (r2_o_next[OW]) wr_oprev_en = 1'b1;
                if (t_consume_end) begin
                    wr_bid_en   = !t_side;
                    wr_ask_en   =  t_side;
                    qwr_zero    = 1'b0;
                    qwr_add     = 1'b0;
                    qwr_a       = t_qty;
                    qwr_b       = r2_o_qty;
                    wr_lvl_cnt  = next_t_cnt;
                    wr_lvl_head = r2_o_next;
                    wr_lvl_tail = (next_t_cnt == '0) ? PTR_INVALID : t_tail;
                end
            end
        end
    end

    // ---------------- Main Sequential FSM & Counters ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_INIT;
            init_idx         <= '0;
            total_orders     <= '0;
            r_op             <= '0;
            r_side           <= 1'b0;
            r_oid            <= '0;
            r_level          <= '0;
            r_qty            <= '0;
            r_slot           <= '0;
            r_seq_en         <= 1'b0;
            r_seq            <= '0;
            seq_init         <= 1'b0;
            prev_seq         <= '0;
            prev_seq_plus1   <= 16'd1;
            r_drop_stale     <= 1'b0;
            r_drop_dup       <= 1'b0;
            r_drop_gap       <= 1'b0;
            stale            <= 1'b0;
            snapshot_error   <= 1'b0;
            snap_loading     <= 1'b0;
            snap_exp_cnt     <= '0;
            snap_obs_cnt     <= '0;
            bm_clear_r       <= 1'b0;
            drop_load_seen   <= 1'b0;
            r_bad_cmd        <= 1'b0;
            r_is_full        <= 1'b0;
            red_remove       <= 1'b0;
            red_sat          <= 1'b0;
            t_partial        <= 1'b0;
            t_rem_eq         <= 1'b0;
            w_old_tail       <= '0;
            w_side           <= 1'b0;
            w_level          <= '0;
            w_qty            <= '0;
            w_prev           <= PTR_INVALID;
            w_next           <= PTR_INVALID;
            w_remove         <= 1'b0;
            w_is_reduce      <= 1'b0;
            w_sat            <= 1'b0;
            t_side           <= 1'b0;
            t_qty            <= '0;
            t_cnt            <= '0;
            t_head           <= PTR_INVALID;
            t_tail           <= PTR_INVALID;
            t_rem            <= '0;
            cnt_add          <= '0;
            cnt_cancel       <= '0;
            cnt_reduce       <= '0;
            cnt_trade        <= '0;
            cnt_drop_dup     <= '0;
            cnt_drop_unknown <= '0;
            cnt_drop_full    <= '0;
            cnt_drop_bad     <= '0;
            cnt_sat          <= '0;
            cnt_seq_gap      <= '0;
            cnt_dup_seq      <= '0;
            cnt_drop_stale   <= '0;
            cnt_drop_load    <= '0;
        end else begin
            bm_clear_r     <= 1'b0;
            drop_load_seen <= snap_loading && eff_cmd_valid;
            if (snap_loading && eff_cmd_valid && !drop_load_seen) begin
                cnt_drop_load <= cnt_drop_load + 1'b1;
            end
            case (1'b1)
                state[ST_INIT]: begin
                    if (init_idx == OW'(MAX_ORDERS - 1)) begin
                        state <= S_WR_COMMIT;
                    end else begin
                        init_idx <= init_idx + 1'b1;
                    end
                end

                state[ST_IDLE]: begin
                    if (snapshot_valid && (snap_type == SNAP_HEADER)) begin
                        snap_loading   <= 1'b1;
                        snap_exp_cnt   <= snap_cnt;
                        snap_obs_cnt   <= '0;
                        snapshot_error <= 1'b0;
                        total_orders   <= '0;
                        init_idx       <= '0;
                        bm_clear_r     <= 1'b1;
                        state          <= S_INIT;
                    end else if (eff_cmd_valid) begin
                        r_op     <= eff_cmd_op;
                        r_side   <= eff_cmd_side;
                        r_oid    <= eff_cmd_oid;
                        r_level  <= eff_cmd_level;
                        r_qty    <= eff_cmd_qty;
                        r_slot   <= cmd_slot;
                        r_seq_en <= eff_cmd_seq_en;
                        r_seq    <= eff_cmd_seq;
                        state    <= S_RD_ADDR;
                    end
                end

                state[ST_RD_ADDR]: begin
                    r_bad_cmd    <= (r_qty == '0) || ((r_op != OP_TRADE) && (r_oid >= OID_W'(MAX_ORDERS)));
                    r_is_full    <= (total_orders == (OW+1)'(MAX_ORDERS));
                    r_drop_stale <= r_seq_en && stale;
                    r_drop_dup   <= r_seq_en && !stale && seq_init && (r_seq == prev_seq);
                    r_drop_gap   <= r_seq_en && !stale && seq_init && (r_seq != prev_seq) && (r_seq != prev_seq_plus1);
                    state        <= S_RD_WAIT;
                end

                state[ST_RD_WAIT]: begin
                    state <= S_RD_PIPE;
                end

                state[ST_RD_PIPE]: begin
                    red_remove <= (r_qty >= dp_o_qty);
                    red_sat    <= (r_qty >  dp_o_qty);
                    state      <= S_EXEC1;
                end

                state[ST_EXEC1]: begin
                    if (r_drop_stale) begin
                        cnt_drop_stale <= cnt_drop_stale + 1'b1;
                        state          <= S_IDLE;
                    end else if (r_drop_dup) begin
                        cnt_dup_seq <= cnt_dup_seq + 1'b1;
                        state       <= S_IDLE;
                    end else if (r_drop_gap) begin
                        cnt_seq_gap <= cnt_seq_gap + 1'b1;
                        stale       <= 1'b1;
                        state       <= S_IDLE;
                    end else begin
                        if (r_seq_en) begin
                            seq_init       <= 1'b1;
                            prev_seq       <= r_seq;
                            prev_seq_plus1 <= r_seq + 16'd1;
                        end
                        if (r_bad_cmd) begin
                            if (!snap_loading) cnt_drop_bad <= cnt_drop_bad + 1'b1;
                            state <= snap_loading ? S_SNAP_WAIT : S_IDLE;
                        end else if (r_op == OP_ADD) begin
                            if (r_is_full) begin
                                if (!snap_loading) cnt_drop_full <= cnt_drop_full + 1'b1;
                                state <= snap_loading ? S_SNAP_WAIT : S_IDLE;
                            end else if (r2_o_valid) begin
                                if (!snap_loading) cnt_drop_dup <= cnt_drop_dup + 1'b1;
                                state <= snap_loading ? S_SNAP_WAIT : S_IDLE;
                            end else begin
                                if (snap_loading) begin
                                    snap_obs_cnt <= snap_obs_cnt + 1'b1;
                                end else begin
                                    cnt_add <= cnt_add + 1'b1;
                                end
                                total_orders <= total_orders + 1'b1;
                                if (add_lvl_nz) begin
                                    w_old_tail <= add_l_tail[OW-1:0];
                                    state      <= S_ADD_LINK;
                                end else begin
                                    state <= S_WR_COMMIT;
                                end
                            end
                        end else if ((r_op == OP_CANCEL) || (r_op == OP_REDUCE)) begin
                            if (!r2_o_valid) begin
                                cnt_drop_unknown <= cnt_drop_unknown + 1'b1;
                                state            <= S_IDLE;
                            end else begin
                                w_side      <= r2_o_meta[LW];
                                w_level     <= r2_o_meta[LW-1:0];
                                w_qty       <= (r_op == OP_CANCEL) ? r2_o_qty : red_dec;
                                w_prev      <= r2_o_prev;
                                w_next      <= r2_o_next;
                                w_remove    <= (r_op == OP_CANCEL) ? 1'b1 : red_remove;
                                w_is_reduce <= (r_op == OP_REDUCE);
                                w_sat       <= (r_op == OP_REDUCE) && red_sat;
                                state       <= S_LVL_WAIT;
                            end
                        end else if (r_op == OP_TRADE) begin
                            if (trade_sel_empty) begin
                                cnt_drop_unknown <= cnt_drop_unknown + 1'b1;
                                state            <= S_IDLE;
                            end else begin
                                t_side    <= r_side;
                                t_qty     <= r_side ? r2_ask_qty  : r2_bid_qty;
                                t_cnt     <= r_side ? r2_ask_cnt  : r2_bid_cnt;
                                t_head    <= r_side ? r2_ask_head : r2_bid_head;
                                t_tail    <= r_side ? r2_ask_tail : r2_bid_tail;
                                t_rem     <= r_qty;
                                cnt_trade <= cnt_trade + 1'b1;
                                state     <= S_TRD_ADDR;
                            end
                        end else begin
                            state <= S_IDLE;
                        end
                    end
                end

                state[ST_ADD_LINK]: begin
                    state <= S_WR_COMMIT;
                end

                state[ST_LVL_WAIT]: begin
                    state <= S_UPD_LVL;
                end

                state[ST_UPD_LVL]: begin
                    if (w_is_reduce) begin
                        cnt_reduce <= cnt_reduce + 1'b1;
                        if (w_sat) cnt_sat <= cnt_sat + 1'b1;
                    end else begin
                        cnt_cancel <= cnt_cancel + 1'b1;
                    end
                    if (w_remove) total_orders <= total_orders - 1'b1;
                    state <= S_WR_COMMIT;
                end

                state[ST_TRD_ADDR]: begin
                    state <= S_TRD_WAIT;
                end

                state[ST_TRD_WAIT]: begin
                    state <= S_TRD_PIPE;
                end

                state[ST_TRD_PIPE]: begin
                    t_partial <= (t_rem <  dp_o_qty);
                    t_rem_eq  <= (t_rem == dp_o_qty);
                    state     <= S_TRADE_STEP;
                end

                state[ST_TRADE_STEP]: begin
                    if (t_partial) begin
                        state <= S_WR_COMMIT;
                    end else begin
                        total_orders <= total_orders - 1'b1;
                        if (t_consume_end) begin
                            state <= S_WR_COMMIT;
                        end else begin
                            t_qty  <= next_t_qty;
                            t_cnt  <= next_t_cnt;
                            t_rem  <= next_t_rem;
                            t_head <= r2_o_next;
                            state  <= S_TRD_ADDR;
                        end
                    end
                end

                state[ST_WR_COMMIT]: begin
                    state <= snap_loading ? S_SNAP_WAIT : S_IDLE;
                end

                state[ST_SNAP_WAIT]: begin
                    if (snapshot_valid) begin
                        if (snap_type == SNAP_HEADER) begin
                            snap_exp_cnt   <= snap_cnt;
                            snap_obs_cnt   <= '0;
                            snapshot_error <= 1'b0;
                            total_orders   <= '0;
                            init_idx       <= '0;
                            bm_clear_r     <= 1'b1;
                            state          <= S_INIT;
                        end else if (snap_type == SNAP_LEVEL) begin
                            state <= S_SNAP_WAIT;
                        end else if (snap_type == SNAP_ORDER) begin
                            r_op     <= OP_ADD;
                            r_side   <= snap_side;
                            r_oid    <= snap_oid;
                            r_level  <= snap_level;
                            r_qty    <= snap_qty;
                            r_slot   <= snap_slot;
                            r_seq_en <= 1'b0;
                            state    <= S_RD_ADDR;
                        end else if (snap_type == SNAP_FOOTER) begin
                            snap_loading <= 1'b0;
                            if ((snap_cnt == snap_exp_cnt) && (snap_obs_cnt == snap_exp_cnt)) begin
                                stale          <= 1'b0;
                                seq_init       <= 1'b0;
                                snapshot_error <= 1'b0;
                            end else begin
                                snapshot_error <= 1'b1;
                                stale          <= 1'b1;
                            end
                            state <= S_IDLE;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign cmd_ready         = USE_AXIS ? 1'b0 : cmd_ready_r;
    assign s_axis_cmd_tready = USE_AXIS ? cmd_ready_r : 1'b0;

    // ---------------- Query FSM (read-only; command always has priority) ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_state   <= Q_IDLE;
            qry_found <= 1'b0;
            qry_level <= '0;
            qry_qty   <= '0;
            qry_pos   <= 6'd0;
        end else begin
            case (q_state)
                Q_IDLE: begin
                    if (qry_valid && !cmd_busy) begin
                        if (qry_oob) begin
                            qry_found <= 1'b0;
                            qry_level <= '0;
                            qry_qty   <= '0;
                            qry_pos   <= 6'd0;
                            q_state   <= Q_DONE;
                        end else begin
                            q_state <= Q_ADDR0;
                        end
                    end
                end

                Q_ADDR0: begin
                    if (cmd_busy || !qry_valid) q_state <= Q_IDLE;
                    else                        q_state <= Q_WAIT0;
                end

                Q_WAIT0: begin
                    if (cmd_busy || !qry_valid) q_state <= Q_IDLE;
                    else                        q_state <= Q_PIPE0;
                end

                Q_PIPE0: begin
                    if (cmd_busy || !qry_valid) q_state <= Q_IDLE;
                    else                        q_state <= Q_READ0;
                end

                Q_READ0: begin
                    if (cmd_busy || !qry_valid) begin
                        q_state <= Q_IDLE;
                    end else if (!r2_o_valid) begin
                        qry_found <= 1'b0;
                        qry_level <= '0;
                        qry_qty   <= '0;
                        qry_pos   <= 6'd0;
                        q_state   <= Q_DONE;
                    end else begin
                        qry_found <= 1'b1;
                        qry_level <= r2_o_meta[LW-1:0];
                        qry_qty   <= r2_o_qty;
                        if (!r2_o_prev[OW]) begin
                            qry_pos <= 6'd0;
                            q_state <= Q_DONE;
                        end else begin
                            qry_pos <= 6'd1;
                            q_state <= Q_ADDRW;
                        end
                    end
                end

                Q_ADDRW: begin
                    if (cmd_busy || !qry_valid) q_state <= Q_IDLE;
                    else                        q_state <= Q_WAITW;
                end

                Q_WAITW: begin
                    if (cmd_busy || !qry_valid) q_state <= Q_IDLE;
                    else                        q_state <= Q_PIPEW;
                end

                Q_PIPEW: begin
                    if (cmd_busy || !qry_valid) q_state <= Q_IDLE;
                    else                        q_state <= Q_WALK;
                end

                Q_WALK: begin
                    if (cmd_busy || !qry_valid) begin
                        q_state <= Q_IDLE;
                    end else if (!r2_o_prev[OW] || (qry_pos == 6'd63)) begin
                        q_state <= Q_DONE;
                    end else begin
                        qry_pos <= qry_pos + 6'd1;
                        q_state <= Q_ADDRW;
                    end
                end

                Q_DONE: begin
                    q_state <= Q_IDLE;
                end

                default: q_state <= Q_IDLE;
            endcase
        end
    end

    assign qry_ready = (q_state == Q_DONE);

    // ---------------- Best price via pipelined occupancy bitmaps ----------------
    // Separate bid/ask update registers prevent cross-chip fanout between u_bid_bm and u_ask_bm.
    (* keep = "true" *) logic          bm_bid_upd_r, bm_ask_upd_r;
    (* keep = "true" *) logic          bm_bid_set_r, bm_ask_set_r;
    (* keep = "true" *) logic [LW-1:0] bm_bid_idx_r, bm_ask_idx_r;

    logic bm_upd_set;
    always_comb begin
        if (state[ST_UPD_LVL])         bm_upd_set = !(w_remove && (upd_l_cnt == (OW+1)'(1)));
        else if (state[ST_TRADE_STEP]) bm_upd_set = t_partial || (t_cnt != (OW+1)'(1));
        else                           bm_upd_set = 1'b1;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bm_bid_upd_r <= 1'b0;
            bm_ask_upd_r <= 1'b0;
            bm_bid_set_r <= 1'b0;
            bm_ask_set_r <= 1'b0;
            bm_bid_idx_r <= '0;
            bm_ask_idx_r <= '0;
        end else begin
            bm_bid_upd_r <= wr_bid_en && !state[ST_INIT];
            bm_ask_upd_r <= wr_ask_en && !state[ST_INIT];
            bm_bid_set_r <= bm_upd_set;
            bm_ask_set_r <= bm_upd_set;
            bm_bid_idx_r <= wr_lvl_addr;
            bm_ask_idx_r <= wr_lvl_addr;
        end
    end

    logic          bid_hi_valid, ask_lo_valid;
    logic [LW-1:0] bid_hi_idx,   ask_lo_idx;
    logic          bid_lo_valid_nc, ask_hi_valid_nc;
    logic [LW-1:0] bid_lo_idx_nc,   ask_hi_idx_nc;
    wire _unused_bm = &{1'b0, bid_lo_valid_nc, bid_lo_idx_nc, ask_hi_valid_nc, ask_hi_idx_nc};

    bitmap_best #(.LEVELS(LEVELS), .FIND_HI(1'b1)) u_bid_bm (
        .clk      (clk),
        .rst_n    (rst_n),
        .clear    (bm_clear_r),
        .upd_valid(bm_bid_upd_r),
        .upd_set  (bm_bid_set_r),
        .upd_index(bm_bid_idx_r),
        .hi_valid (bid_hi_valid),
        .hi_index (bid_hi_idx),
        .lo_valid (bid_lo_valid_nc),
        .lo_index (bid_lo_idx_nc)
    );

    bitmap_best #(.LEVELS(LEVELS), .FIND_HI(1'b0)) u_ask_bm (
        .clk      (clk),
        .rst_n    (rst_n),
        .clear    (bm_clear_r),
        .upd_valid(bm_ask_upd_r),
        .upd_set  (bm_ask_set_r),
        .upd_index(bm_ask_idx_r),
        .hi_valid (ask_hi_valid_nc),
        .hi_index (ask_hi_idx_nc),
        .lo_valid (ask_lo_valid),
        .lo_index (ask_lo_idx)
    );

    // Output pipeline:
    // Stage 1: register bitmap_best output (bid_idx_r / ask_idx_r)
    // Stage 2+3: shadow qty BRAM with built-in DP16KD OUTREG (2 cycles, Tco = 0.96 ns)
    logic             bid_valid_r, ask_valid_r;
    logic [LW-1:0]    bid_idx_r,   ask_idx_r;
    logic             bid_valid_d, ask_valid_d;
    logic [LW-1:0]    best_bid_d,  best_ask_d;
    logic             bid_valid_q, ask_valid_q;
    logic [LW-1:0]    best_bid_q,  best_ask_q;
    logic [QTY_W-1:0] best_bid_qty_dp, best_ask_qty_dp;

    bram_sdp #(.DEPTH(LEVELS), .WIDTH(QTY_W)) u_bid_shadow (
        .clk(clk), .we(wr_bid_en_r), .waddr(wr_lvl_addr_r), .wdata(wr_lvl_qty_r),
        .raddr(bid_idx_r), .rdata(best_bid_qty_dp)
    );
    bram_sdp #(.DEPTH(LEVELS), .WIDTH(QTY_W)) u_ask_shadow (
        .clk(clk), .we(wr_ask_en_r), .waddr(wr_lvl_addr_r), .wdata(wr_lvl_qty_r),
        .raddr(ask_idx_r), .rdata(best_ask_qty_dp)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bid_valid_r <= 1'b0;
            bid_idx_r   <= '0;
            ask_valid_r <= 1'b0;
            ask_idx_r   <= '0;
            bid_valid_d <= 1'b0;
            best_bid_d  <= '0;
            ask_valid_d <= 1'b0;
            best_ask_d  <= '0;
            bid_valid_q <= 1'b0;
            best_bid_q  <= '0;
            ask_valid_q <= 1'b0;
            best_ask_q  <= '0;
        end else begin
            bid_valid_r <= bid_hi_valid;
            bid_idx_r   <= bid_hi_idx;
            ask_valid_r <= ask_lo_valid;
            ask_idx_r   <= ask_lo_idx;
            bid_valid_d <= bid_valid_r;
            best_bid_d  <= bid_idx_r;
            ask_valid_d <= ask_valid_r;
            best_ask_d  <= ask_idx_r;
            bid_valid_q <= bid_valid_d;
            best_bid_q  <= bid_valid_d ? best_bid_d : '0;
            ask_valid_q <= ask_valid_d;
            best_ask_q  <= ask_valid_d ? best_ask_d : '0;
        end
    end

    assign bid_valid    = bid_valid_q;
    assign best_bid     = best_bid_q;
    assign best_bid_qty = bid_valid_q ? best_bid_qty_dp : '0;
    assign ask_valid    = ask_valid_q;
    assign best_ask     = best_ask_q;
    assign best_ask_qty = ask_valid_q ? best_ask_qty_dp : '0;

    // ---------------- AXI4-Stream Best-Price Master (§B.2) ----------------
    // Emits a beat whenever best bid/ask (valid, level, qty) changes; holds tdata stable on backpressure.
    wire [53:0] best_pack = {best_ask_qty, best_ask, ask_valid, best_bid_qty, best_bid, bid_valid};
    logic [53:0] best_prev_r;
    logic        axis_best_valid_r;
    logic [53:0] axis_best_data_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            best_prev_r       <= '0;
            axis_best_valid_r <= 1'b0;
            axis_best_data_r  <= '0;
        end else begin
            if (!axis_best_valid_r || s_axis_best_tready) begin
                if (best_pack != best_prev_r) begin
                    axis_best_valid_r <= 1'b1;
                    axis_best_data_r  <= best_pack;
                    best_prev_r       <= best_pack;
                end else begin
                    axis_best_valid_r <= 1'b0;
                end
            end
        end
    end

    assign s_axis_best_tvalid = axis_best_valid_r;
    assign s_axis_best_tdata  = axis_best_data_r;

endmodule
