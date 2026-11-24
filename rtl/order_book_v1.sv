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
    parameter int SYMBOLS    = 2,
    parameter int SW         = (SYMBOLS <= 1) ? 1 : $clog2(SYMBOLS),
    parameter int LW         = (LEVELS <= 2) ? 1 : $clog2(LEVELS),
    parameter int OW         = (MAX_ORDERS <= 2) ? 1 : $clog2(MAX_ORDERS)
) (
    input  logic             clk,
    input  logic             rst_n,

    // Legacy command interface (§3.1 + v1.1 seq + v1.2 sym, active when USE_AXIS=0)
    input  logic             cmd_valid,
    output logic             cmd_ready,
    input  logic [1:0]       cmd_op,      // 0=ADD, 1=CANCEL, 2=REDUCE, 3=TRADE
    input  logic             cmd_side,    // 0=bid, 1=ask
    input  logic [OID_W-1:0] cmd_oid,     // ignored for TRADE
    input  logic [LW-1:0]    cmd_level,   // required for ADD, TRADE
    input  logic [QTY_W-1:0] cmd_qty,     // 0 is invalid
    input  logic [SW-1:0]    cmd_sym,     // symbol index (0..SYMBOLS-1)
    input  logic             cmd_seq_en,  // 1 = check 16-bit cmd_seq (legacy mode)
    input  logic [15:0]      cmd_seq,     // 16-bit sequence number (mod 65536)

    // AXI4-Stream command slave (§B.1 / v1.2 §A.1, active when USE_AXIS=1)
    input  logic             s_axis_cmd_tvalid,
    output logic             s_axis_cmd_tready,
    input  logic [63:0]      s_axis_cmd_tdata,

    // AXI4-Stream best-price master (§B.2 / v1.2 §A.1: [63:61]=sym, [53:0]=best)
    output logic             s_axis_best_tvalid,
    input  logic             s_axis_best_tready,
    output logic [63:0]      s_axis_best_tdata,

    // Query interface (§3.2 + v1.2 sym)
    input  logic             qry_valid,
    output logic             qry_ready,
    input  logic [SW-1:0]    qry_sym,
    input  logic [OID_W-1:0] qry_oid,
    output logic             qry_found,
    output logic [LW-1:0]    qry_level,
    output logic [QTY_W-1:0] qry_qty,
    output logic [5:0]       qry_pos,

    // Best price outputs (v1.2 §A.4: per-symbol arrays)
    output logic [SYMBOLS-1:0]            bid_valid,
    output logic [SYMBOLS-1:0][LW-1:0]    best_bid,
    output logic [SYMBOLS-1:0][QTY_W-1:0] best_bid_qty,
    output logic [SYMBOLS-1:0]            ask_valid,
    output logic [SYMBOLS-1:0][LW-1:0]    best_ask,
    output logic [SYMBOLS-1:0][QTY_W-1:0] best_ask_qty,

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

    // Link pointer: MSB=1 valid, MSB=0 INVALID (per-symbol slot index)
    localparam int PW = OW + 1;
    localparam logic [PW-1:0] PTR_INVALID = '0;

    // Multi-symbol BRAM depths & address widths
    localparam int TOT_ORDERS = SYMBOLS * MAX_ORDERS;
    localparam int TOT_LEVELS = SYMBOLS * LEVELS;
    localparam int OAW        = (TOT_ORDERS <= 2) ? 1 : $clog2(TOT_ORDERS);
    localparam int LAW        = (TOT_LEVELS <= 2) ? 1 : $clog2(TOT_LEVELS);

    function automatic logic [OAW-1:0] mk_o_addr(input logic [SW-1:0] sym, input logic [OW-1:0] slot);
        if (SYMBOLS == 1) mk_o_addr = OAW'(slot);
        else              mk_o_addr = OAW'({sym, slot});
    endfunction

    function automatic logic [LAW-1:0] mk_l_addr(input logic [SW-1:0] sym, input logic [LW-1:0] lvl);
        if (SYMBOLS == 1) mk_l_addr = LAW'(lvl);
        else              mk_l_addr = LAW'({sym, lvl});
    endfunction

    // ---------------- Command FSM (one-hot encoded for >=120 MHz ECP5) ----------------
    localparam int ST_INIT       = 0;
    localparam int ST_IDLE       = 1;
    localparam int ST_RD_ADDR    = 2;
    localparam int ST_RD_WAIT    = 3;
    localparam int ST_RD_PIPE    = 4;
    localparam int ST_EXEC1      = 5;
    localparam int ST_ADD_LINK   = 6;
    localparam int ST_LVL_WAIT   = 7;
    localparam int ST_LVL_PIPE   = 8;
    localparam int ST_UPD_LVL    = 9;
    localparam int ST_TRD_ADDR   = 10;
    localparam int ST_TRD_WAIT   = 11;
    localparam int ST_TRD_PIPE   = 12;
    localparam int ST_TRD_CMP    = 13;
    localparam int ST_TRADE_STEP = 14;
    localparam int ST_WR_COMMIT  = 15;
    localparam int ST_SNAP_WAIT  = 16;

    localparam logic [16:0] S_INIT       = 17'd1 << ST_INIT;
    localparam logic [16:0] S_IDLE       = 17'd1 << ST_IDLE;
    localparam logic [16:0] S_RD_ADDR    = 17'd1 << ST_RD_ADDR;
    localparam logic [16:0] S_RD_WAIT    = 17'd1 << ST_RD_WAIT;
    localparam logic [16:0] S_RD_PIPE    = 17'd1 << ST_RD_PIPE;
    localparam logic [16:0] S_EXEC1      = 17'd1 << ST_EXEC1;
    localparam logic [16:0] S_ADD_LINK   = 17'd1 << ST_ADD_LINK;
    localparam logic [16:0] S_LVL_WAIT   = 17'd1 << ST_LVL_WAIT;
    localparam logic [16:0] S_LVL_PIPE   = 17'd1 << ST_LVL_PIPE;
    localparam logic [16:0] S_UPD_LVL    = 17'd1 << ST_UPD_LVL;
    localparam logic [16:0] S_TRD_ADDR   = 17'd1 << ST_TRD_ADDR;
    localparam logic [16:0] S_TRD_WAIT   = 17'd1 << ST_TRD_WAIT;
    localparam logic [16:0] S_TRD_PIPE   = 17'd1 << ST_TRD_PIPE;
    localparam logic [16:0] S_TRD_CMP    = 17'd1 << ST_TRD_CMP;
    localparam logic [16:0] S_TRADE_STEP = 17'd1 << ST_TRADE_STEP;
    localparam logic [16:0] S_WR_COMMIT  = 17'd1 << ST_WR_COMMIT;
    localparam logic [16:0] S_SNAP_WAIT  = 17'd1 << ST_SNAP_WAIT;

    (* fsm_encoding = "none" *) logic [16:0] state;

    // Command source mux (USE_AXIS=1 -> AXI4-Stream slave; USE_AXIS=0 -> legacy cmd_*)
    wire             eff_cmd_valid  = USE_AXIS ? s_axis_cmd_tvalid          : cmd_valid;
    wire [1:0]       eff_cmd_op     = USE_AXIS ? s_axis_cmd_tdata[1:0]      : cmd_op;
    wire             eff_cmd_side   = USE_AXIS ? s_axis_cmd_tdata[2]        : cmd_side;
    wire [OID_W-1:0] eff_cmd_oid    = USE_AXIS ? s_axis_cmd_tdata[3 +: OID_W] : cmd_oid;
    wire [LW-1:0]    eff_cmd_level  = USE_AXIS ? s_axis_cmd_tdata[19 +: LW] : cmd_level;
    wire [QTY_W-1:0] eff_cmd_qty    = USE_AXIS ? s_axis_cmd_tdata[29 +: QTY_W] : cmd_qty;
    wire [SW-1:0]    eff_cmd_sym    = (SYMBOLS == 1) ? '0 :
                                      (USE_AXIS ? s_axis_cmd_tdata[60 +: SW] : cmd_sym);
    wire [15:0]      eff_cmd_seq    = USE_AXIS ? ((SYMBOLS > 1) ? {1'b0, s_axis_cmd_tdata[59:45]} :
                                                                  s_axis_cmd_tdata[60:45]) : cmd_seq;
    wire             eff_cmd_seq_en = USE_AXIS ? 1'b1                       : cmd_seq_en;
    wire _unused_axis_cmd = &{1'b0, s_axis_cmd_tdata[63:60], cmd_sym, qry_sym};

    // ---------------- Pipelined ADD Fast Path (v1.2 Task B: >= 0.5 cmd/cycle) ----------------
    // 1-entry issue register (iss) + 3-stage BRAM read/exec pipeline (P0 -> P1 -> P2)
    // with 1-cycle link_pend freeze for non-empty level tail linking and exact RAW hazard stall.
    logic             iss_valid;
    logic [1:0]       iss_op;
    logic             iss_side;
    logic [SW-1:0]    iss_sym;
    logic [OID_W-1:0] iss_oid;
    logic [LW-1:0]    iss_level;
    logic [QTY_W-1:0] iss_qty;
    logic [OW-1:0]    iss_slot;
    logic             iss_seq_en;
    logic [15:0]      iss_seq;
    logic             iss_bad_cmd;
    logic             iss_drop_stale_r;
    logic             iss_drop_dup_r;
    logic             iss_drop_gap_r;
    logic [2:0]       iss_wait_r;

    logic             p0_valid, p1_valid, p2_valid, p3_valid;
    logic             p0_side,  p1_side,  p2_side,  p3_side;
    logic [SW-1:0]    p0_sym,   p1_sym,   p2_sym,   p3_sym;
    logic [LW-1:0]    p0_level, p1_level, p2_level, p3_level;
    logic [QTY_W-1:0] p0_qty,   p1_qty,   p2_qty,   p3_qty;
    logic [OW-1:0]    p0_slot,  p1_slot,  p2_slot,  p3_slot;

    logic             link_pend;
    logic [OAW-1:0]   link_addr;
    logic [PW-1:0]    link_data;
    logic             wr_pipe_busy;
    logic             wr_pipe_busy_d;
    logic             pipe_idle_r;

    wire pipe_any = !pipe_idle_r;
    wire pipe_re  = 1'b1;

    // 1-bit per-symbol capacity flags (eliminates 14-bit CCU2C comparator from iss_can_fire)
    logic [SYMBOLS-1:0] sym_near_full_r;
    wire [SYMBOLS-1:0]  sym_is_full;
    generate
        for (genvar s = 0; s < SYMBOLS; s++) begin : g_cap
            assign sym_is_full[s] = total_orders[s][OW]; // MAX_ORDERS = 2^OW
        end
    endgenerate

    // Precompute RAW hazard against P0/P1/P2/P3 when loading iss (feeds only 3-bit iss_wait_r FF,
    // removing all 24-bit hazard comparators from iss_can_fire -> state/ord_rd_addr_r).
    wire load_hit_p0 = p0_valid && (p0_sym == eff_cmd_sym) &&
                       ((p0_slot == cmd_slot) || ((p0_side == eff_cmd_side) && (p0_level == eff_cmd_level)));
    wire load_hit_p1 = p1_valid && (p1_sym == eff_cmd_sym) &&
                       ((p1_slot == cmd_slot) || ((p1_side == eff_cmd_side) && (p1_level == eff_cmd_level)));
    wire load_hit_p2 = p2_valid && (p2_sym == eff_cmd_sym) &&
                       ((p2_slot == cmd_slot) || ((p2_side == eff_cmd_side) && (p2_level == eff_cmd_level)));
    wire load_hit_p3 = p3_valid && (p3_sym == eff_cmd_sym) &&
                       ((p3_slot == cmd_slot) || ((p3_side == eff_cmd_side) && (p3_level == eff_cmd_level)));
    wire iss_add_hazard = (iss_wait_r != 3'd0) || (sym_near_full_r[iss_sym] && pipe_any);

    wire iss_can_fire_add    = state[ST_IDLE] && iss_valid && (iss_op == OP_ADD) && !iss_add_hazard;
    wire iss_can_fire_nonadd = state[ST_IDLE] && iss_valid && (iss_op != OP_ADD) && !pipe_any;
    wire iss_can_fire        = iss_can_fire_add || iss_can_fire_nonadd;
    wire iss_seq_drop        = iss_drop_stale_r || iss_drop_dup_r || iss_drop_gap_r;
    wire iss_is_full         = sym_is_full[iss_sym];
    wire iss_fire_add        = iss_can_fire_add && !iss_seq_drop && !iss_bad_cmd && !iss_is_full;

    // 2-cycle cadence (!iss_valid) guarantees P2 only runs on even cycles and link_pend on odd cycles,
    // achieving 0.500 cmd/cycle even on 100% non-empty levels with zero BRAM CEB stall fanout.
    wire cmd_ready_r = state[ST_IDLE] && !snap_loading && !iss_valid;
    assign snapshot_ready = (state[ST_IDLE] && !iss_valid && !pipe_any) || state[ST_SNAP_WAIT];

    logic [OAW-1:0] init_idx;
    logic [OW:0]    total_orders [SYMBOLS];

    // Snapshot reload state (v1.2 §A.3: [1:0]=sym for SYMBOLS>1, [44]=side; v1.1 compat for SYMBOLS==1)
    localparam logic [1:0] SNAP_HEADER = 2'd0;
    localparam logic [1:0] SNAP_LEVEL  = 2'd1;
    localparam logic [1:0] SNAP_ORDER  = 2'd2;
    localparam logic [1:0] SNAP_FOOTER = 2'd3;

    wire [1:0]       snap_type  = snapshot_data[63:62];
    wire [SW-1:0]    snap_sym   = (SYMBOLS == 1) ? '0 : snapshot_data[0 +: SW];
    wire             snap_side  = (SYMBOLS == 1) ? snapshot_data[1] : snapshot_data[44];
    wire [LW-1:0]    snap_level = snapshot_data[2 +: LW];
    wire [QTY_W-1:0] snap_qty   = snapshot_data[12 +: QTY_W];
    wire [OID_W-1:0] snap_oid   = snapshot_data[28 +: OID_W];
    wire [OW-1:0]    snap_slot  = snapshot_data[28 +: OW];
    wire [31:0]      snap_cnt   = snapshot_data[31:0];
    wire _unused_snap = &{1'b0, snapshot_data[1:0], snapshot_data[61:44]};

    logic        snap_loading;
    logic [31:0] snap_exp_cnt;
    logic [31:0] snap_obs_cnt;
    logic        bm_clear_r;
    logic        drop_load_seen;

    // Latched command registers
    logic [1:0]       r_op;
    logic             r_side;
    logic [SW-1:0]    r_sym;
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
    logic [SW-1:0] q_sym;
    wire cmd_busy = !state[ST_IDLE] || eff_cmd_valid || iss_valid || pipe_any;
    wire [OW-1:0] qry_slot = qry_oid[OW-1:0];
    wire [SW-1:0] eff_qry_sym = (SYMBOLS == 1) ? '0 : qry_sym;
    wire qry_oob = (qry_oid >= OID_W'(MAX_ORDERS));

    // ---------------- Synchronous BRAM Read Pipeline ----------------
    wire [OW-1:0]   cmd_slot    = eff_cmd_oid[OW-1:0];
    logic [OAW-1:0] ord_rd_addr_r;
    logic [LAW-1:0] lvl_rd_addr_r;
    wire  [LAW-1:0] lvl_rd_addr = state[ST_EXEC1] ? mk_l_addr(r_sym, r2_o_meta[LW-1:0]) : lvl_rd_addr_r;

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
            lvl_rd_addr_r <= '0;
        end else begin
            if (state[ST_IDLE]) begin
                if (iss_valid) begin
                    ord_rd_addr_r <= mk_o_addr(iss_sym, iss_slot);
                    lvl_rd_addr_r <= mk_l_addr(iss_sym, iss_level);
                end else if (q_state == Q_IDLE) begin
                    ord_rd_addr_r <= mk_o_addr(eff_qry_sym, qry_slot);
                end else if ((q_state == Q_READ0) || (q_state == Q_WALK)) begin
                    ord_rd_addr_r <= mk_o_addr(q_sym, r2_o_prev[OW-1:0]);
                end
            end else if (state[ST_SNAP_WAIT]) begin
                ord_rd_addr_r <= mk_o_addr(snap_sym, snap_slot);
                lvl_rd_addr_r <= mk_l_addr(snap_sym, snap_level);
            end else if (state[ST_EXEC1]) begin
                ord_rd_addr_r <= mk_o_addr(r_sym, add_l_head[OW-1:0]);
            end else if (state[ST_TRADE_STEP]) begin
                ord_rd_addr_r <= mk_o_addr(r_sym, r2_o_next[OW-1:0]);
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

    // ---------------- BRAM Write Ports (registered inputs for >=130 MHz ECP5) ----------------
    logic             wr_oval_en,   wr_oval_en_r;
    logic [OAW-1:0]   wr_oval_addr, wr_oval_addr_r;
    logic             wr_oval_data, wr_oval_data_r;

    logic             wr_oqty_en,   wr_oqty_en_r;
    logic [OAW-1:0]   wr_oqty_addr, wr_oqty_addr_r;
    logic [QTY_W-1:0] wr_oqty_data, wr_oqty_data_r;

    logic             wr_ometa_en,   wr_ometa_en_r;
    logic [OAW-1:0]   wr_ometa_addr, wr_ometa_addr_r;
    logic [LW:0]      wr_ometa_data, wr_ometa_data_r;

    logic             wr_oprev_en,   wr_oprev_en_r;
    logic [OAW-1:0]   wr_oprev_addr, wr_oprev_addr_r;
    logic [PW-1:0]    wr_oprev_data, wr_oprev_data_r;

    logic             wr_onext_en,   wr_onext_en_r;
    logic [OAW-1:0]   wr_onext_addr, wr_onext_addr_r;
    logic [PW-1:0]    wr_onext_data, wr_onext_data_r;

    logic             wr_bid_en,    wr_bid_en_r;
    logic             wr_ask_en,    wr_ask_en_r;
    logic [LAW-1:0]   wr_lvl_addr;
    (* keep = "true" *) logic [LAW-1:0]   wr_bid_addr_r, wr_ask_addr_r;
    // Ladder quantity & count write pipeline:
    // Stage 1 (*_r): single shared CCU2C add/sub from registered operands.
    // Stage 2 (*_r2): pure FFs driving DP16KD.DIA directly (0 LUT/CCU2C before BRAM).
    logic             qwr_zero, qwr_zero_r;
    logic             qwr_add,  qwr_add_r;
    logic [QTY_W-1:0] qwr_a,    qwr_a_r;
    logic [QTY_W-1:0] qwr_b,    qwr_b_r;
    wire  [QTY_W-1:0] wr_lvl_qty_r = qwr_zero_r ? '0 : (qwr_add_r ? (qwr_a_r + qwr_b_r) : (qwr_a_r - qwr_b_r));

    logic             cwr_zero, cwr_zero_r;
    logic             cwr_inc,  cwr_inc_r;
    logic             cwr_dec,  cwr_dec_r;
    logic [OW:0]      cwr_val,  cwr_val_r;
    wire  [OW:0]      cwr_step_r   = cwr_dec_r ? {(OW+1){1'b1}} : {{OW{1'b0}}, cwr_inc_r};
    wire  [OW:0]      wr_lvl_cnt_r = cwr_zero_r ? '0 : (cwr_val_r + cwr_step_r);

    logic [PW-1:0]    wr_lvl_head, wr_lvl_head_r;
    logic [PW-1:0]    wr_lvl_tail, wr_lvl_tail_r;

    logic             wr_bid_en_r2,   wr_ask_en_r2;
    logic [LAW-1:0]   wr_bid_addr_r2, wr_ask_addr_r2;
    logic [QTY_W-1:0] wr_bid_qty_r2,  wr_ask_qty_r2;
    logic [OW:0]      wr_bid_cnt_r2,  wr_ask_cnt_r2;
    logic [PW-1:0]    wr_bid_head_r2, wr_ask_head_r2;
    logic [PW-1:0]    wr_bid_tail_r2, wr_ask_tail_r2;

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
            wr_bid_addr_r   <= '0;
            wr_ask_addr_r   <= '0;
            qwr_zero_r      <= 1'b1;
            qwr_add_r       <= 1'b0;
            qwr_a_r         <= '0;
            qwr_b_r         <= '0;
            cwr_zero_r      <= 1'b1;
            cwr_inc_r       <= 1'b0;
            cwr_dec_r       <= 1'b0;
            cwr_val_r       <= '0;
            wr_lvl_head_r   <= PTR_INVALID;
            wr_lvl_tail_r   <= PTR_INVALID;
            wr_bid_en_r2    <= 1'b0;
            wr_ask_en_r2    <= 1'b0;
            wr_bid_addr_r2  <= '0;
            wr_ask_addr_r2  <= '0;
            wr_bid_qty_r2   <= '0;
            wr_ask_qty_r2   <= '0;
            wr_bid_cnt_r2   <= '0;
            wr_ask_cnt_r2   <= '0;
            wr_bid_head_r2  <= PTR_INVALID;
            wr_ask_head_r2  <= PTR_INVALID;
            wr_bid_tail_r2  <= PTR_INVALID;
            wr_ask_tail_r2  <= PTR_INVALID;
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
            wr_bid_addr_r   <= wr_lvl_addr;
            wr_ask_addr_r   <= wr_lvl_addr;
            qwr_zero_r      <= qwr_zero;
            qwr_add_r       <= qwr_add;
            qwr_a_r         <= qwr_a;
            qwr_b_r         <= qwr_b;
            cwr_zero_r      <= cwr_zero;
            cwr_inc_r       <= cwr_inc;
            cwr_dec_r       <= cwr_dec;
            cwr_val_r       <= cwr_val;
            wr_lvl_head_r   <= wr_lvl_head;
            wr_lvl_tail_r   <= wr_lvl_tail;

            wr_bid_en_r2    <= wr_bid_en_r;
            wr_ask_en_r2    <= wr_ask_en_r;
            if (wr_bid_en_r) begin
                wr_bid_addr_r2 <= wr_bid_addr_r;
                wr_bid_qty_r2  <= wr_lvl_qty_r;
                wr_bid_cnt_r2  <= wr_lvl_cnt_r;
                wr_bid_head_r2 <= wr_lvl_head_r;
                wr_bid_tail_r2 <= wr_lvl_tail_r;
            end
            if (wr_ask_en_r) begin
                wr_ask_addr_r2 <= wr_ask_addr_r;
                wr_ask_qty_r2  <= wr_lvl_qty_r;
                wr_ask_cnt_r2  <= wr_lvl_cnt_r;
                wr_ask_head_r2 <= wr_lvl_head_r;
                wr_ask_tail_r2 <= wr_lvl_tail_r;
            end
        end
    end

    // Order store & Price ladder BRAMs with built-in DP16KD OUTREG (2-cycle read latency)
    bram_sdp #(.DEPTH(TOT_ORDERS), .WIDTH(1))     u_o_valid (.clk(clk), .we(wr_oval_en_r),  .waddr(wr_oval_addr_r),  .wdata(wr_oval_data_r),  .re(pipe_re), .raddr(ord_rd_addr_r), .rdata(dp_o_valid));
    bram_sdp #(.DEPTH(TOT_ORDERS), .WIDTH(QTY_W)) u_o_qty   (.clk(clk), .we(wr_oqty_en_r),  .waddr(wr_oqty_addr_r),  .wdata(wr_oqty_data_r),  .re(pipe_re), .raddr(ord_rd_addr_r), .rdata(dp_o_qty));
    bram_sdp #(.DEPTH(TOT_ORDERS), .WIDTH(LW+1))  u_o_meta  (.clk(clk), .we(wr_ometa_en_r), .waddr(wr_ometa_addr_r), .wdata(wr_ometa_data_r), .re(pipe_re), .raddr(ord_rd_addr_r), .rdata(dp_o_meta));
    bram_sdp #(.DEPTH(TOT_ORDERS), .WIDTH(PW))    u_o_prev  (.clk(clk), .we(wr_oprev_en_r), .waddr(wr_oprev_addr_r), .wdata(wr_oprev_data_r), .re(pipe_re), .raddr(ord_rd_addr_r), .rdata(dp_o_prev));
    bram_sdp #(.DEPTH(TOT_ORDERS), .WIDTH(PW))    u_o_next  (.clk(clk), .we(wr_onext_en_r), .waddr(wr_onext_addr_r), .wdata(wr_onext_data_r), .re(pipe_re), .raddr(ord_rd_addr_r), .rdata(dp_o_next));

    bram_sdp #(.DEPTH(TOT_LEVELS), .WIDTH(QTY_W)) u_bid_qty  (.clk(clk), .we(wr_bid_en_r2), .waddr(wr_bid_addr_r2), .wdata(wr_bid_qty_r2),  .re(pipe_re), .raddr(lvl_rd_addr), .rdata(r2_bid_qty));
    bram_sdp #(.DEPTH(TOT_LEVELS), .WIDTH(OW+1))  u_bid_cnt  (.clk(clk), .we(wr_bid_en_r2), .waddr(wr_bid_addr_r2), .wdata(wr_bid_cnt_r2),  .re(pipe_re), .raddr(lvl_rd_addr), .rdata(r2_bid_cnt));
    bram_sdp #(.DEPTH(TOT_LEVELS), .WIDTH(PW))    u_bid_head (.clk(clk), .we(wr_bid_en_r2), .waddr(wr_bid_addr_r2), .wdata(wr_bid_head_r2), .re(pipe_re), .raddr(lvl_rd_addr), .rdata(r2_bid_head));
    bram_sdp #(.DEPTH(TOT_LEVELS), .WIDTH(PW))    u_bid_tail (.clk(clk), .we(wr_bid_en_r2), .waddr(wr_bid_addr_r2), .wdata(wr_bid_tail_r2), .re(pipe_re), .raddr(lvl_rd_addr), .rdata(r2_bid_tail));

    bram_sdp #(.DEPTH(TOT_LEVELS), .WIDTH(QTY_W)) u_ask_qty  (.clk(clk), .we(wr_ask_en_r2), .waddr(wr_ask_addr_r2), .wdata(wr_ask_qty_r2),  .re(pipe_re), .raddr(lvl_rd_addr), .rdata(r2_ask_qty));
    bram_sdp #(.DEPTH(TOT_LEVELS), .WIDTH(OW+1))  u_ask_cnt  (.clk(clk), .we(wr_ask_en_r2), .waddr(wr_ask_addr_r2), .wdata(wr_ask_cnt_r2),  .re(pipe_re), .raddr(lvl_rd_addr), .rdata(r2_ask_cnt));
    bram_sdp #(.DEPTH(TOT_LEVELS), .WIDTH(PW))    u_ask_head (.clk(clk), .we(wr_ask_en_r2), .waddr(wr_ask_addr_r2), .wdata(wr_ask_head_r2), .re(pipe_re), .raddr(lvl_rd_addr), .rdata(r2_ask_head));
    bram_sdp #(.DEPTH(TOT_LEVELS), .WIDTH(PW))    u_ask_tail (.clk(clk), .we(wr_ask_en_r2), .waddr(wr_ask_addr_r2), .wdata(wr_ask_tail_r2), .re(pipe_re), .raddr(lvl_rd_addr), .rdata(r2_ask_tail));

    // ---------------- Helper Signals ----------------
    // Pre-register bad_cmd, is_full, and 1-bit S_EXEC1 guards during S_RD_WAIT / S_RD_PIPE
    // (zero extra cycles) to flatten wr_bid_en/wr_ask_en -> bm_upd_r logic depth.
    logic r_bad_cmd;
    logic r_is_full;
    logic r_exec_ok;
    logic r_add_ok;

    // Capture ladder BRAM outputs into local fabric FFs during S_RD_PIPE (for S_EXEC1)
    // and S_LVL_PIPE (for S_UPD_LVL) so zero ladder BRAM DOB nets feed combinational logic.
    logic            r_add_lvl_nz;
    logic [QTY_W-1:0] r2_lvl_qty;
    logic [OW:0]      r2_lvl_cnt;
    logic [PW-1:0]    r2_lvl_head;
    logic [PW-1:0]    r2_lvl_tail;
    wire              lvl_sel_side = state[ST_LVL_PIPE] ? w_side : r_side;
    always_ff @(posedge clk) begin
        r2_lvl_qty  <= lvl_sel_side ? r2_ask_qty  : r2_bid_qty;
        r2_lvl_cnt  <= lvl_sel_side ? r2_ask_cnt  : r2_bid_cnt;
        r2_lvl_head <= lvl_sel_side ? r2_ask_head : r2_bid_head;
        r2_lvl_tail <= lvl_sel_side ? r2_ask_tail : r2_bid_tail;
    end
    wire             add_lvl_nz  = r_add_lvl_nz;
    wire [QTY_W-1:0] add_l_qty   = r2_lvl_qty;
    wire [OW:0]      add_l_cnt   = r2_lvl_cnt;
    wire [PW-1:0]    add_l_head  = r2_lvl_head;
    wire [PW-1:0]    add_l_tail  = r2_lvl_tail;

    wire [QTY_W-1:0] upd_l_qty   = r2_lvl_qty;
    wire [OW:0]      upd_l_cnt   = r2_lvl_cnt;
    wire [PW-1:0]    upd_l_head  = r2_lvl_head;
    wire [PW-1:0]    upd_l_tail  = r2_lvl_tail;

    // 16-bit comparisons computed from local fabric FF r2_o_qty (decoupled from
    // DP16KD dp_o_qty cross-chip routing); TRADE comparisons pre-registered in S_TRD_CMP.
    wire             red_remove = (r_qty >= r2_o_qty);
    wire             red_sat    = (r_qty >  r2_o_qty);
    logic            t_partial;
    logic            t_rem_eq;
    wire [QTY_W-1:0] red_dec    = red_remove ? r2_o_qty : r_qty;

    // Trade step helpers
    // TRADE selects the side from cmd_side (r_side); the other side is untouched.
    logic            t_cnt_is_one;
    wire             trade_sel_empty = !r_add_lvl_nz;
    wire [QTY_W-1:0] next_t_qty    = t_qty - r2_o_qty;
    wire [OW:0]      next_t_cnt    = t_cnt - 1'b1;
    wire [QTY_W-1:0] next_t_rem    = t_rem - r2_o_qty;
    wire             t_consume_end = t_rem_eq || t_cnt_is_one;

    logic [QTY_W-1:0] p3_l_qty;
    logic [OW:0]      p3_l_cnt;
    logic [PW-1:0]    p3_l_head;
    logic [PW-1:0]    p3_l_tail;
    wire              p3_lvl_nz   = p3_l_head[OW];
    wire              p3_exec_add = state[ST_IDLE] && p3_valid && !link_pend && !r2_o_valid;

    always_ff @(posedge clk) begin
        p3_l_qty  <= p2_side ? r2_ask_qty  : r2_bid_qty;
        p3_l_cnt  <= p2_side ? r2_ask_cnt  : r2_bid_cnt;
        p3_l_head <= p2_side ? r2_ask_head : r2_bid_head;
        p3_l_tail <= p2_side ? r2_ask_tail : r2_bid_tail;
    end

    // ---------------- Combinational BRAM Write Controls ----------------
    always_comb begin
        wr_oval_en    = 1'b0;
        wr_oval_addr  = state[ST_INIT]       ? init_idx :
                        state[ST_IDLE]       ? mk_o_addr(p3_sym, p3_slot) :
                        state[ST_TRADE_STEP] ? mk_o_addr(r_sym, t_head[OW-1:0]) :
                                               mk_o_addr(r_sym, r_slot);
        wr_oval_data  = state[ST_IDLE] || (state[ST_EXEC1] && (r_op == OP_ADD));

        wr_oqty_en    = 1'b0;
        wr_oqty_addr  = state[ST_IDLE]       ? mk_o_addr(p3_sym, p3_slot) :
                        state[ST_TRADE_STEP] ? mk_o_addr(r_sym, t_head[OW-1:0]) :
                                               mk_o_addr(r_sym, r_slot);
        wr_oqty_data  = state[ST_IDLE]       ? p3_qty :
                        state[ST_TRADE_STEP] ? (r2_o_qty - t_rem) :
                        (r_op == OP_REDUCE)  ? (r2_o_qty - r_qty) : r_qty;

        wr_ometa_en   = 1'b0;
        wr_ometa_addr = state[ST_IDLE] ? mk_o_addr(p3_sym, p3_slot) : mk_o_addr(r_sym, r_slot);
        wr_ometa_data = state[ST_IDLE] ? {p3_side, p3_level} : {r_side, r_level};

        wr_oprev_en   = 1'b0;
        wr_oprev_addr = state[ST_IDLE]       ? mk_o_addr(p3_sym, p3_slot) :
                        state[ST_TRADE_STEP] ? mk_o_addr(r_sym, r2_o_next[OW-1:0]) :
                        (r_op == OP_ADD)     ? mk_o_addr(r_sym, r_slot) :
                                               mk_o_addr(r_sym, r2_o_next[OW-1:0]);
        wr_oprev_data = state[ST_IDLE]       ? (p3_lvl_nz ? p3_l_tail : PTR_INVALID) :
                        state[ST_TRADE_STEP] ? PTR_INVALID :
                        (r_op == OP_ADD)     ? (add_lvl_nz ? add_l_tail : PTR_INVALID) :
                                               r2_o_prev;

        wr_onext_en   = 1'b0;
        wr_onext_addr = link_pend          ? link_addr :
                        state[ST_IDLE]     ? mk_o_addr(p3_sym, p3_slot) :
                        state[ST_ADD_LINK] ? mk_o_addr(r_sym, w_old_tail) :
                        (r_op == OP_ADD)   ? mk_o_addr(r_sym, r_slot) :
                                             mk_o_addr(r_sym, r2_o_prev[OW-1:0]);
        wr_onext_data = link_pend          ? link_data :
                        state[ST_IDLE]     ? PTR_INVALID :
                        state[ST_ADD_LINK] ? {1'b1, r_slot} :
                        (r_op == OP_ADD)   ? PTR_INVALID : r2_o_next;

        wr_bid_en     = 1'b0;
        wr_ask_en     = 1'b0;
        wr_lvl_addr   = state[ST_INIT]    ? init_idx[LAW-1:0] :
                        state[ST_IDLE]    ? mk_l_addr(p3_sym, p3_level) :
                        state[ST_UPD_LVL] ? mk_l_addr(r_sym, w_level) :
                                            mk_l_addr(r_sym, r_level);
        qwr_zero      = 1'b1;
        qwr_add       = 1'b0;
        qwr_a         = '0;
        qwr_b         = '0;
        cwr_zero      = 1'b1;
        cwr_inc       = 1'b0;
        cwr_dec       = 1'b0;
        cwr_val       = '0;
        wr_lvl_head   = PTR_INVALID;
        wr_lvl_tail   = PTR_INVALID;

        if (state[ST_INIT]) begin
            wr_oval_en = 1'b1;
            if (init_idx < OAW'(TOT_LEVELS)) begin
                wr_bid_en = 1'b1;
                wr_ask_en = 1'b1;
            end
        end else if (state[ST_IDLE]) begin
            qwr_zero    = 1'b0;
            qwr_add     = 1'b1;
            qwr_a       = p3_l_qty;
            qwr_b       = p3_qty;
            cwr_zero    = 1'b0;
            cwr_inc     = 1'b1;
            cwr_val     = p3_l_cnt;
            wr_lvl_head = p3_lvl_nz ? p3_l_head : {1'b1, p3_slot};
            wr_lvl_tail = {1'b1, p3_slot};
            if (link_pend) begin
                wr_onext_en = 1'b1;
            end else if (p3_exec_add) begin
                wr_oval_en  = 1'b1;
                wr_oqty_en  = 1'b1;
                wr_ometa_en = 1'b1;
                wr_oprev_en = 1'b1;
                wr_onext_en = 1'b1;
                wr_bid_en   = !p3_side;
                wr_ask_en   =  p3_side;
            end
        end else if (state[ST_EXEC1]) begin
            if (r_exec_ok) begin
                if (r_add_ok && !r2_o_valid) begin
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
                    cwr_zero    = 1'b0;
                    cwr_inc     = 1'b1;
                    cwr_val     = add_l_cnt;
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
            cwr_zero    = 1'b0;
            cwr_dec     = w_remove;
            cwr_val     = upd_l_cnt;
            wr_lvl_head = w_remove ? (w_prev[OW] ? upd_l_head : w_next) : upd_l_head;
            wr_lvl_tail = w_remove ? (w_next[OW] ? upd_l_tail : w_prev) : upd_l_tail;
        end else if (state[ST_TRADE_STEP]) begin
            wr_lvl_tail = (!t_partial && t_cnt_is_one) ? PTR_INVALID : t_tail;
            if (t_partial) begin
                wr_oqty_en  = 1'b1;
                wr_bid_en   = !t_side;
                wr_ask_en   =  t_side;
                qwr_zero    = 1'b0;
                qwr_add     = 1'b0;
                qwr_a       = t_qty;
                qwr_b       = t_rem;
                cwr_zero    = 1'b0;
                cwr_val     = t_cnt;
                wr_lvl_head = t_head;
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
                    cwr_zero    = 1'b0;
                    cwr_dec     = 1'b1;
                    cwr_val     = t_cnt;
                    wr_lvl_head = r2_o_next;
                end
            end
        end
    end

    // ---------------- Main Sequential FSM & Counters ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_INIT;
            init_idx         <= '0;
            sym_near_full_r  <= '0;
            r_op             <= '0;
            r_side           <= 1'b0;
            r_sym            <= '0;
            r_oid            <= '0;
            r_level          <= '0;
            r_qty            <= '0;
            r_slot           <= '0;
            iss_valid        <= 1'b0;
            iss_op           <= '0;
            iss_side         <= 1'b0;
            iss_sym          <= '0;
            iss_oid          <= '0;
            iss_level        <= '0;
            iss_qty          <= '0;
            iss_slot         <= '0;
            iss_seq_en       <= 1'b0;
            iss_seq          <= '0;
            iss_bad_cmd      <= 1'b0;
            iss_drop_stale_r <= 1'b0;
            iss_drop_dup_r   <= 1'b0;
            iss_drop_gap_r   <= 1'b0;
            iss_wait_r       <= 3'd0;
            p0_valid         <= 1'b0;
            p0_side          <= 1'b0;
            p0_sym           <= '0;
            p0_level         <= '0;
            p0_qty           <= '0;
            p0_slot          <= '0;
            p1_valid         <= 1'b0;
            p1_side          <= 1'b0;
            p1_sym           <= '0;
            p1_level         <= '0;
            p1_qty           <= '0;
            p1_slot          <= '0;
            p2_valid         <= 1'b0;
            p2_side          <= 1'b0;
            p2_sym           <= '0;
            p2_level         <= '0;
            p2_qty           <= '0;
            p2_slot          <= '0;
            p3_valid         <= 1'b0;
            p3_side          <= 1'b0;
            p3_sym           <= '0;
            p3_level         <= '0;
            p3_qty           <= '0;
            p3_slot          <= '0;
            link_pend        <= 1'b0;
            link_addr        <= '0;
            link_data        <= PTR_INVALID;
            wr_pipe_busy     <= 1'b0;
            wr_pipe_busy_d   <= 1'b0;
            pipe_idle_r      <= 1'b1;
            r_add_lvl_nz     <= 1'b0;
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
            r_exec_ok        <= 1'b0;
            r_add_ok         <= 1'b0;
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
            t_partial        <= 1'b0;
            t_rem_eq         <= 1'b0;
            t_cnt_is_one     <= 1'b0;
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
            wr_pipe_busy_d <= wr_pipe_busy;
            pipe_idle_r    <= !(iss_fire_add || p0_valid || p1_valid || p2_valid || p3_valid || link_pend || wr_pipe_busy || wr_pipe_busy_d);
            for (int s = 0; s < SYMBOLS; s++) begin
                sym_near_full_r[s] <= total_orders[s][OW] || (&total_orders[s][OW-1:3]);
            end
            drop_load_seen <= snap_loading && eff_cmd_valid;
            if (snap_loading && eff_cmd_valid && !drop_load_seen) begin
                cnt_drop_load <= cnt_drop_load + 1'b1;
            end
            (* parallel_case *) case (1'b1)
                state[ST_INIT]: begin
                    if (init_idx == OAW'(TOT_ORDERS - 1)) begin
                        state <= S_WR_COMMIT;
                    end else begin
                        init_idx <= init_idx + 1'b1;
                    end
                end

                state[ST_IDLE]: begin
                    wr_pipe_busy <= 1'b0;

                    // Pipeline shift (unconditional in S_IDLE; when snap_hdr_req fires, pipe_idle_r==1 so all stages are 0)
                    link_pend <= 1'b0;
                    if (link_pend) begin
                        wr_pipe_busy <= 1'b1;
                    end

                    // Advance P0 -> P1 -> P2 -> P3
                    p1_valid <= p0_valid;
                    p1_side  <= p0_side;
                    p1_sym   <= p0_sym;
                    p1_level <= p0_level;
                    p1_qty   <= p0_qty;
                    p1_slot  <= p0_slot;

                    p2_valid <= p1_valid;
                    p2_side  <= p1_side;
                    p2_sym   <= p1_sym;
                    p2_level <= p1_level;
                    p2_qty   <= p1_qty;
                    p2_slot  <= p1_slot;

                    p3_valid <= p2_valid;
                    p3_side  <= p2_side;
                    p3_sym   <= p2_sym;
                    p3_level <= p2_level;
                    p3_qty   <= p2_qty;
                    p3_slot  <= p2_slot;

                    if (snapshot_valid && (snap_type == SNAP_HEADER) && !iss_valid && pipe_idle_r) begin
                        snap_loading   <= 1'b1;
                        snap_exp_cnt   <= snap_cnt;
                        snap_obs_cnt   <= '0;
                        snapshot_error <= 1'b0;
                        init_idx       <= '0;
                        bm_clear_r     <= 1'b1;
                        state          <= S_INIT;
                    end else if (eff_cmd_valid && cmd_ready_r) begin
                        // 1) Accept incoming command into 1-entry issue register (iss)
                        iss_valid        <= 1'b1;
                        iss_op           <= eff_cmd_op;
                        iss_side         <= eff_cmd_side;
                        iss_sym          <= eff_cmd_sym;
                        iss_oid          <= eff_cmd_oid;
                        iss_level        <= eff_cmd_level;
                        iss_qty          <= eff_cmd_qty;
                        iss_slot         <= cmd_slot;
                        iss_seq_en       <= eff_cmd_seq_en;
                        iss_seq          <= eff_cmd_seq;
                        iss_bad_cmd      <= (eff_cmd_qty == '0) ||
                                            ((eff_cmd_op != OP_TRADE) && (eff_cmd_oid >= OID_W'(MAX_ORDERS)));
                        iss_drop_stale_r <= eff_cmd_seq_en && stale;
                        iss_drop_dup_r   <= eff_cmd_seq_en && !stale && seq_init && (eff_cmd_seq == prev_seq);
                        iss_drop_gap_r   <= eff_cmd_seq_en && !stale && seq_init &&
                                            (eff_cmd_seq != prev_seq) && (eff_cmd_seq != prev_seq_plus1);
                        iss_wait_r       <= load_hit_p0 ? 3'd4 :
                                            (load_hit_p1 ? 3'd3 :
                                            (load_hit_p2 ? 3'd2 :
                                            (load_hit_p3 ? 3'd1 : 3'd0)));
                    end else if (iss_can_fire) begin
                        iss_valid <= 1'b0;
                    end else if (iss_valid && (iss_wait_r != 3'd0)) begin
                        iss_wait_r <= iss_wait_r - 3'd1;
                    end

                    // Stage P3 execution (mutually exclusive with snap_hdr_req since pipe_idle_r==1)
                    if (p3_valid) begin
                        if (r2_o_valid) begin
                            cnt_drop_dup <= cnt_drop_dup + 1'b1;
                        end else begin
                            cnt_add              <= cnt_add + 1'b1;
                            wr_pipe_busy         <= 1'b1;
                            if (p3_lvl_nz) begin
                                link_pend <= 1'b1;
                                link_addr <= mk_o_addr(p3_sym, p3_l_tail[OW-1:0]);
                                link_data <= {1'b1, p3_slot};
                            end
                        end
                    end

                    // Stage iss firing (mutually exclusive with snap_hdr_req since iss_valid==0)
                    p0_valid <= 1'b0;
                    if (iss_can_fire) begin
                        if (iss_drop_stale_r) begin
                            cnt_drop_stale <= cnt_drop_stale + 1'b1;
                        end else if (iss_drop_dup_r) begin
                            cnt_dup_seq <= cnt_dup_seq + 1'b1;
                        end else if (iss_drop_gap_r) begin
                            cnt_seq_gap <= cnt_seq_gap + 1'b1;
                            stale       <= 1'b1;
                        end else begin
                            if (iss_seq_en) begin
                                seq_init       <= 1'b1;
                                prev_seq       <= iss_seq;
                                prev_seq_plus1 <= (USE_AXIS && (SYMBOLS > 1)) ?
                                                  {1'b0, (iss_seq[14:0] + 15'd1)} : (iss_seq + 16'd1);
                            end
                            if (iss_bad_cmd) begin
                                cnt_drop_bad <= cnt_drop_bad + 1'b1;
                            end else if (iss_op == OP_ADD) begin
                                if (iss_is_full) begin
                                    cnt_drop_full <= cnt_drop_full + 1'b1;
                                end else begin
                                    p0_valid <= 1'b1;
                                    p0_side  <= iss_side;
                                    p0_sym   <= iss_sym;
                                    p0_level <= iss_level;
                                    p0_qty   <= iss_qty;
                                    p0_slot  <= iss_slot;
                                end
                            end else begin
                                r_op     <= iss_op;
                                r_side   <= iss_side;
                                r_sym    <= iss_sym;
                                r_oid    <= iss_oid;
                                r_level  <= iss_level;
                                r_qty    <= iss_qty;
                                r_slot   <= iss_slot;
                                r_seq_en <= 1'b0;
                                state    <= S_RD_ADDR;
                            end
                        end
                    end
                end

                state[ST_RD_ADDR]: begin
                    r_bad_cmd    <= (r_qty == '0) || ((r_op != OP_TRADE) && (r_oid >= OID_W'(MAX_ORDERS)));
                    r_is_full    <= (total_orders[r_sym] == (OW+1)'(MAX_ORDERS));
                    r_drop_stale <= r_seq_en && stale;
                    r_drop_dup   <= r_seq_en && !stale && seq_init && (r_seq == prev_seq);
                    r_drop_gap   <= r_seq_en && !stale && seq_init && (r_seq != prev_seq) && (r_seq != prev_seq_plus1);
                    state        <= S_RD_WAIT;
                end

                state[ST_RD_WAIT]: begin
                    state <= S_RD_PIPE;
                end

                state[ST_RD_PIPE]: begin
                    r_add_lvl_nz <= r_side ? r2_ask_head[OW] : r2_bid_head[OW];
                    r_exec_ok    <= !r_seq_drop && !r_bad_cmd;
                    r_add_ok     <= !r_seq_drop && !r_bad_cmd && (r_op == OP_ADD) && !r_is_full;
                    state        <= S_EXEC1;
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
                            prev_seq_plus1 <= (USE_AXIS && (SYMBOLS > 1)) ?
                                              {1'b0, (r_seq[14:0] + 15'd1)} : (r_seq + 16'd1);
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
                                t_qty     <= add_l_qty;
                                t_cnt     <= add_l_cnt;
                                t_head    <= add_l_head;
                                t_tail    <= add_l_tail;
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
                    state <= S_LVL_PIPE;
                end

                state[ST_LVL_PIPE]: begin
                    state <= S_UPD_LVL;
                end

                state[ST_UPD_LVL]: begin
                    if (w_is_reduce) begin
                        cnt_reduce <= cnt_reduce + 1'b1;
                        if (w_sat) cnt_sat <= cnt_sat + 1'b1;
                    end else begin
                        cnt_cancel <= cnt_cancel + 1'b1;
                    end
                    state <= S_WR_COMMIT;
                end

                state[ST_TRD_ADDR]: begin
                    state <= S_TRD_WAIT;
                end

                state[ST_TRD_WAIT]: begin
                    state <= S_TRD_PIPE;
                end

                state[ST_TRD_PIPE]: begin
                    state <= S_TRD_CMP;
                end

                state[ST_TRD_CMP]: begin
                    t_partial    <= (t_rem <  r2_o_qty);
                    t_rem_eq     <= (t_rem == r2_o_qty);
                    t_cnt_is_one <= (t_cnt == (OW+1)'(1));
                    state        <= S_TRADE_STEP;
                end

                state[ST_TRADE_STEP]: begin
                    if (t_partial) begin
                        state <= S_WR_COMMIT;
                    end else begin
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
                            init_idx       <= '0;
                            bm_clear_r     <= 1'b1;
                            state          <= S_INIT;
                        end else if (snap_type == SNAP_LEVEL) begin
                            state <= S_SNAP_WAIT;
                        end else if (snap_type == SNAP_ORDER) begin
                            r_op     <= OP_ADD;
                            r_side   <= snap_side;
                            r_sym    <= snap_sym;
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

    // Decoupled per-symbol total_orders counter (shallow 2-LUT CE, zero snapshot_valid fan-in)
    wire          tot_inc = (state[ST_IDLE] && p3_valid && !r2_o_valid) ||
                            (state[ST_EXEC1] && r_add_ok && !r2_o_valid);
    wire          tot_dec = (state[ST_UPD_LVL] && w_remove) ||
                            (state[ST_TRADE_STEP] && !t_partial);
    wire [SW-1:0] tot_sym = state[ST_IDLE] ? p3_sym : r_sym;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < SYMBOLS; s++) total_orders[s] <= '0;
        end else if (bm_clear_r) begin
            for (int s = 0; s < SYMBOLS; s++) total_orders[s] <= '0;
        end else if (tot_inc) begin
            total_orders[tot_sym] <= total_orders[tot_sym] + 1'b1;
        end else if (tot_dec) begin
            total_orders[tot_sym] <= total_orders[tot_sym] - 1'b1;
        end
    end

    // ---------------- Query FSM (read-only; command always has priority) ----------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_state   <= Q_IDLE;
            q_sym     <= '0;
            qry_found <= 1'b0;
            qry_level <= '0;
            qry_qty   <= '0;
            qry_pos   <= 6'd0;
        end else begin
            case (q_state)
                Q_IDLE: begin
                    if (qry_valid && !cmd_busy) begin
                        q_sym <= eff_qry_sym;
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

    // ---------------- Per-Symbol Best Price via Pipelined Occupancy Bitmaps ----------------
    logic bm_bid_upd_set, bm_ask_upd_set;
    always_comb begin
        if (state[ST_UPD_LVL])         bm_bid_upd_set = !(w_remove && (upd_l_cnt == (OW+1)'(1)));
        else if (state[ST_TRADE_STEP]) bm_bid_upd_set = t_partial || !t_cnt_is_one;
        else                           bm_bid_upd_set = 1'b1;

        if (state[ST_UPD_LVL])         bm_ask_upd_set = !(w_remove && (upd_l_cnt == (OW+1)'(1)));
        else if (state[ST_TRADE_STEP]) bm_ask_upd_set = t_partial || !t_cnt_is_one;
        else                           bm_ask_upd_set = 1'b1;
    end

    logic [SW-1:0] wr_lvl_sym, wr_bid_sym_r, wr_ask_sym_r;
    generate
        if (SYMBOLS == 1) begin : g_sym_addr_1
            assign wr_lvl_sym   = '0;
            assign wr_bid_sym_r = '0;
            assign wr_ask_sym_r = '0;
        end else begin : g_sym_addr_n
            assign wr_lvl_sym   = wr_lvl_addr[LAW-1:LW];
            assign wr_bid_sym_r = wr_bid_addr_r[LAW-1:LW];
            assign wr_ask_sym_r = wr_ask_addr_r[LAW-1:LW];
        end
    endgenerate
    wire [LW-1:0] wr_lvl_idx   = wr_lvl_addr[LW-1:0];
    wire [LW-1:0] wr_bid_idx_r = wr_bid_addr_r[LW-1:0];
    wire [LW-1:0] wr_ask_idx_r = wr_ask_addr_r[LW-1:0];

    logic [53:0] best_pack [SYMBOLS];

    generate
        for (genvar s = 0; s < SYMBOLS; s++) begin : g_sym
            (* keep = "true" *) logic          bm_bid_upd_r, bm_ask_upd_r;
            (* keep = "true" *) logic          bm_bid_set_r, bm_ask_set_r;
            (* keep = "true" *) logic [LW-1:0] bm_bid_idx_r, bm_ask_idx_r;

            wire sym_hit       = (SYMBOLS == 1) ? 1'b1 : (wr_lvl_sym   == SW'(s));
            wire sym_bid_hit_r = (SYMBOLS == 1) ? 1'b1 : (wr_bid_sym_r == SW'(s));
            wire sym_ask_hit_r = (SYMBOLS == 1) ? 1'b1 : (wr_ask_sym_r == SW'(s));

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    bm_bid_upd_r <= 1'b0;
                    bm_ask_upd_r <= 1'b0;
                    bm_bid_set_r <= 1'b0;
                    bm_ask_set_r <= 1'b0;
                    bm_bid_idx_r <= '0;
                    bm_ask_idx_r <= '0;
                end else begin
                    bm_bid_upd_r <= wr_bid_en && !state[ST_INIT] && sym_hit;
                    bm_ask_upd_r <= wr_ask_en && !state[ST_INIT] && sym_hit;
                    if (sym_hit) begin
                        bm_bid_set_r <= bm_bid_upd_set;
                        bm_bid_idx_r <= wr_lvl_idx;
                        bm_ask_set_r <= bm_ask_upd_set;
                        bm_ask_idx_r <= wr_lvl_idx;
                    end
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

            logic             bid_valid_r, ask_valid_r;
            logic [LW-1:0]    bid_idx_r,   ask_idx_r;
            logic             bid_valid_d, ask_valid_d;
            logic [LW-1:0]    best_bid_d,  best_ask_d;
            logic             bid_valid_q, ask_valid_q;
            logic [LW-1:0]    best_bid_q,  best_ask_q;
            logic [QTY_W-1:0] best_bid_qty_dp, best_ask_qty_dp;

            logic             sh_bid_en_r,  sh_ask_en_r;
            logic [LW-1:0]    sh_bid_idx_r, sh_ask_idx_r;
            logic [QTY_W-1:0] sh_bid_qty_r, sh_ask_qty_r;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    sh_bid_en_r  <= 1'b0;
                    sh_ask_en_r  <= 1'b0;
                    sh_bid_idx_r <= '0;
                    sh_ask_idx_r <= '0;
                    sh_bid_qty_r <= '0;
                    sh_ask_qty_r <= '0;
                end else begin
                    sh_bid_en_r <= wr_bid_en_r && sym_bid_hit_r;
                    sh_ask_en_r <= wr_ask_en_r && sym_ask_hit_r;
                    if (wr_bid_en_r && sym_bid_hit_r) begin
                        sh_bid_idx_r <= wr_bid_idx_r;
                        sh_bid_qty_r <= wr_lvl_qty_r;
                    end
                    if (wr_ask_en_r && sym_ask_hit_r) begin
                        sh_ask_idx_r <= wr_ask_idx_r;
                        sh_ask_qty_r <= wr_lvl_qty_r;
                    end
                end
            end

            bram_sdp #(.DEPTH(LEVELS), .WIDTH(QTY_W)) u_bid_shadow (
                .clk(clk), .we(sh_bid_en_r), .waddr(sh_bid_idx_r), .wdata(sh_bid_qty_r),
                .re(1'b1), .raddr(bid_idx_r), .rdata(best_bid_qty_dp)
            );
            bram_sdp #(.DEPTH(LEVELS), .WIDTH(QTY_W)) u_ask_shadow (
                .clk(clk), .we(sh_ask_en_r), .waddr(sh_ask_idx_r), .wdata(sh_ask_qty_r),
                .re(1'b1), .raddr(ask_idx_r), .rdata(best_ask_qty_dp)
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

            assign bid_valid[s]    = bid_valid_q;
            assign best_bid[s]     = best_bid_q;
            assign best_bid_qty[s] = bid_valid_q ? best_bid_qty_dp : '0;
            assign ask_valid[s]    = ask_valid_q;
            assign best_ask[s]     = best_ask_q;
            assign best_ask_qty[s] = ask_valid_q ? best_ask_qty_dp : '0;

            assign best_pack[s] = {best_ask_qty[s], best_ask[s], ask_valid[s],
                                   best_bid_qty[s], best_bid[s], bid_valid[s]};
        end
    endgenerate

    // ---------------- AXI4-Stream Best-Price Master (v1.2 §A.1: [63:61]=sym) ----------------
    // Pipelined 27-bit half comparators decouple 54-bit equality from s_axis_best_tready & mux.
    logic [53:0]        best_pack_r [SYMBOLS];
    logic [53:0]        best_prev_r [SYMBOLS];
    logic [SYMBOLS-1:0] dirty_lo_r;
    logic [SYMBOLS-1:0] dirty_hi_r;
    logic [SYMBOLS-1:0] just_sent_r;
    logic               axis_best_valid_r;
    logic [63:0]        axis_best_data_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < SYMBOLS; s++) begin
                best_pack_r[s] <= '0;
                best_prev_r[s] <= '0;
            end
            dirty_lo_r        <= '0;
            dirty_hi_r        <= '0;
            just_sent_r       <= '0;
            axis_best_valid_r <= 1'b0;
            axis_best_data_r  <= '0;
        end else begin
            for (int s = 0; s < SYMBOLS; s++) begin
                best_pack_r[s] <= best_pack[s];
                dirty_lo_r[s]  <= (best_pack_r[s][26:0]  != best_prev_r[s][26:0]);
                dirty_hi_r[s]  <= (best_pack_r[s][53:27] != best_prev_r[s][53:27]);
            end
            just_sent_r <= '0;
            if (!axis_best_valid_r || s_axis_best_tready) begin
                logic        found_dirty;
                logic [2:0]  dirty_sym;
                logic [53:0] dirty_pack;
                found_dirty = 1'b0;
                dirty_sym   = 3'd0;
                dirty_pack  = '0;
                for (int s = SYMBOLS - 1; s >= 0; s--) begin
                    if ((dirty_lo_r[s] || dirty_hi_r[s]) && !just_sent_r[s]) begin
                        found_dirty = 1'b1;
                        dirty_sym   = 3'(s);
                        dirty_pack  = best_pack_r[s];
                    end
                end
                if (found_dirty) begin
                    axis_best_valid_r              <= 1'b1;
                    axis_best_data_r               <= {dirty_sym, 7'd0, dirty_pack};
                    best_prev_r[dirty_sym[SW-1:0]] <= dirty_pack;
                    just_sent_r[dirty_sym[SW-1:0]] <= 1'b1;
                end else begin
                    axis_best_valid_r <= 1'b0;
                end
            end
        end
    end

    assign s_axis_best_tvalid = axis_best_valid_r;
    assign s_axis_best_tdata  = axis_best_data_r;

endmodule
