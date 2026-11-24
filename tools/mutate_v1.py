#!/usr/bin/env python3
"""Mutation testing for rtl/order_book_v1.sv (v1.2).

Tests 50 single-edit mutations covering FIFO pointers & append, level/order counts,
quantity arithmetic, TRADE FSM loop, query/queue-pos, best-price bitmap,
stall/priority hazard logic, seq comparison, stale lock, snapshot clear/error,
AXI4-Stream best-price output, multi-symbol address mapping & per-symbol
ladder/bitmap selection, and pipelined ADD RAW hazard logic.

Usage: python3 tools/mutate_v1.py [--workers 6] [--timeout 180]
"""

from __future__ import annotations

import argparse
import concurrent.futures
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RTL_BRAM = ROOT / "rtl" / "bram_sdp.sv"
RTL_BM = ROOT / "rtl" / "bitmap_best.sv"
RTL_MAIN = ROOT / "rtl" / "order_book_v1.sv"
TB = ROOT / "tb" / "tb_order_book_v1.sv"

# (name, old, new, equivalent?)
MUTATIONS: list[tuple[str, str, str, bool]] = [
    # ---- FIFO pointers & append ----
    (
        "fifo_add_prev_always_invalid",
        "(r_op == OP_ADD)     ? (add_lvl_nz ? add_l_tail : PTR_INVALID) :",
        "(r_op == OP_ADD)     ? PTR_INVALID :",
        False,
    ),
    (
        "fifo_add_head_always_overwrite",
        "wr_lvl_head = add_lvl_nz ? add_l_head : {1'b1, r_slot};",
        "wr_lvl_head = {1'b1, r_slot};",
        False,
    ),
    (
        "fifo_add_skip_old_tail_link",
        "if (add_lvl_nz) begin\n                                    w_old_tail <= add_l_tail[OW-1:0];",
        "if (1'b0) begin\n                                    w_old_tail <= add_l_tail[OW-1:0];",
        False,
    ),
    (
        "fifo_cancel_skip_prev_unlink",
        "if (r2_o_prev[OW]) wr_onext_en = 1'b1;",
        "if (1'b0) wr_onext_en = 1'b1;",
        False,
    ),
    (
        "fifo_cancel_skip_next_unlink",
        "if (r2_o_prev[OW]) wr_onext_en = 1'b1;\n                    if (r2_o_next[OW]) wr_oprev_en = 1'b1;",
        "if (r2_o_prev[OW]) wr_onext_en = 1'b1;\n                    if (1'b0) wr_oprev_en = 1'b1;",
        False,
    ),
    (
        "fifo_upd_lvl_head_not_updated",
        "wr_lvl_head = w_remove ? (w_prev[OW] ? upd_l_head : w_next) : upd_l_head;",
        "wr_lvl_head = upd_l_head;",
        False,
    ),
    (
        "fifo_upd_lvl_tail_not_updated",
        "wr_lvl_tail = w_remove ? (w_next[OW] ? upd_l_tail : w_prev) : upd_l_tail;",
        "wr_lvl_tail = upd_l_tail;",
        False,
    ),
    (
        "fifo_trade_skip_clear_next_prev",
        "if (r2_o_next[OW]) wr_oprev_en = 1'b1;\n                if (t_consume_end)",
        "if (1'b0) wr_oprev_en = 1'b1;\n                if (t_consume_end)",
        False,
    ),
    # ---- Counts & capacity ----
    (
        "cnt_add_lvl_count_stuck",
        "cwr_inc     = 1'b1;\n            cwr_val     = p3_l_cnt;",
        "cwr_inc     = 1'b0;\n            cwr_val     = p3_l_cnt;",
        False,
    ),
    (
        "cnt_upd_lvl_count_not_dec",
        "cwr_dec     = w_remove;\n            cwr_val     = upd_l_cnt;",
        "cwr_dec     = 1'b0;\n            cwr_val     = upd_l_cnt;",
        False,
    ),
    (
        "cnt_total_orders_not_inc",
        "total_orders[tot_sym] <= total_orders[tot_sym] + 1'b1;",
        "total_orders[tot_sym] <= total_orders[tot_sym];",
        False,
    ),
    (
        "cnt_total_orders_not_dec_upd",
        "wire          tot_dec = (state[ST_UPD_LVL] && w_remove) ||",
        "wire          tot_dec = (1'b0) ||",
        False,
    ),
    (
        "cnt_is_full_always_false",
        "assign sym_is_full[s] = total_orders[s][OW];",
        "assign sym_is_full[s] = 1'b0;",
        False,
    ),
    (
        "cnt_dup_check_disabled",
        "end else if (r2_o_valid) begin\n                                if (!snap_loading) cnt_drop_dup <= cnt_drop_dup + 1'b1;",
        "end else if (1'b0) begin\n                                if (!snap_loading) cnt_drop_dup <= cnt_drop_dup + 1'b1;",
        False,
    ),
    (
        "cnt_bad_qty_zero_allowed",
        "iss_bad_cmd      <= (eff_cmd_qty == '0) ||\n                                            ((eff_cmd_op != OP_TRADE) && (eff_cmd_oid >= OID_W'(MAX_ORDERS)));",
        "iss_bad_cmd      <= ((eff_cmd_op != OP_TRADE) && (eff_cmd_oid >= OID_W'(MAX_ORDERS)));",
        False,
    ),
    (
        "cnt_oid_oob_disabled",
        "iss_bad_cmd      <= (eff_cmd_qty == '0) ||\n                                            ((eff_cmd_op != OP_TRADE) && (eff_cmd_oid >= OID_W'(MAX_ORDERS)));",
        "iss_bad_cmd      <= (eff_cmd_qty == '0);",
        False,
    ),
    # ---- Quantity add/sub & REDUCE saturation ----
    (
        "qty_add_subtracts",
        "qwr_add     = 1'b1;\n            qwr_a       = p3_l_qty;",
        "qwr_add     = 1'b0;\n            qwr_a       = p3_l_qty;",
        False,
    ),
    (
        "qty_upd_lvl_adds",
        "qwr_add     = 1'b0;\n            qwr_a       = upd_l_qty;",
        "qwr_add     = 1'b1;\n            qwr_a       = upd_l_qty;",
        False,
    ),
    (
        "qty_reduce_partial_no_sub",
        "(r_op == OP_REDUCE)  ? (r2_o_qty - r_qty) : r_qty;",
        "(r_op == OP_REDUCE)  ? r2_o_qty : r_qty;",
        False,
    ),
    (
        "qty_reduce_remove_strict_gt",
        "wire             red_remove = (r_qty >= r2_o_qty);",
        "wire             red_remove = (r_qty > r2_o_qty);",
        False,
    ),
    (
        "qty_reduce_sat_gte",
        "wire             red_sat    = (r_qty >  r2_o_qty);",
        "wire             red_sat    = (r_qty >= r2_o_qty);",
        False,
    ),
    (
        "qty_trade_partial_oqty_wrong",
        "state[ST_TRADE_STEP] ? (r2_o_qty - t_rem) :",
        "state[ST_TRADE_STEP] ? r2_o_qty :",
        False,
    ),
    (
        "qty_trade_partial_lqty_wrong",
        "qwr_a       = t_qty;\n                qwr_b       = t_rem;",
        "qwr_a       = t_qty;\n                qwr_b       = '0;",
        False,
    ),
    # ---- TRADE FSM loop ----
    (
        "trade_partial_lte",
        "t_partial    <= (t_rem <  r2_o_qty);",
        "t_partial    <= (t_rem <= r2_o_qty);",
        False,
    ),
    (
        "trade_consume_always_stops",
        "wire             t_consume_end = t_rem_eq || t_cnt_is_one;",
        "wire             t_consume_end = 1'b1;",
        False,
    ),
    (
        "trade_empty_not_dropped",
        "if (trade_sel_empty) begin",
        "if (1'b0) begin",
        False,
    ),
    (
        "trade_next_rem_wrong",
        "wire [QTY_W-1:0] next_t_rem    = t_rem - r2_o_qty;",
        "wire [QTY_W-1:0] next_t_rem    = t_rem;",
        False,
    ),
    (
        "trade_tail_not_cleared_on_empty",
        "wr_lvl_tail = (!t_partial && t_cnt_is_one) ? PTR_INVALID : t_tail;",
        "wr_lvl_tail = t_tail;",
        # Equivalent: l_tail is never read while l_count == 0; the next ADD on
        # an empty level overwrites both head and tail.
        True,
    ),
    # ---- Query & queue position ----
    (
        "qry_pos_cap_31",
        "end else if (!r2_o_prev[OW] || (qry_pos == 6'd63)) begin",
        "end else if (!r2_o_prev[OW] || (qry_pos == 6'd31)) begin",
        False,
    ),
    (
        "qry_pos_stuck_zero",
        "qry_pos <= qry_pos + 6'd1;",
        "qry_pos <= qry_pos;",
        False,
    ),
    # ---- Best price & bitmap ----
    (
        "bm_upd_set_stuck_one",
        "if (state[ST_UPD_LVL])         bm_bid_upd_set = !(w_remove && (upd_l_cnt == (OW+1)'(1)));",
        "if (state[ST_UPD_LVL])         bm_bid_upd_set = 1'b1;",
        False,
    ),
    (
        "best_bid_valid_stuck_low",
        "assign bid_valid[s]    = bid_valid_q;",
        "assign bid_valid[s]    = 1'b0;",
        False,
    ),
    (
        "best_ask_valid_stuck_low",
        "assign ask_valid[s]    = ask_valid_q;",
        "assign ask_valid[s]    = 1'b0;",
        False,
    ),
    # ---- Stall / hazard / priority ----
    (
        "hazard_cmd_ready_always_high",
        "wire cmd_ready_r = state[ST_IDLE] && !snap_loading && !iss_valid;",
        "wire cmd_ready_r = !state[ST_INIT];",
        False,
    ),
    (
        "hazard_cmd_priority_disabled",
        "wire cmd_busy = !state[ST_IDLE] || eff_cmd_valid || iss_valid || pipe_any;",
        "wire cmd_busy = 1'b0;",
        False,
    ),
    # ---- v1.1 seq comparison & stale lock ----
    (
        "v11_seq_dup_disabled",
        "iss_drop_dup_r   <= eff_cmd_seq_en && !stale && seq_init && (eff_cmd_seq == prev_seq);",
        "iss_drop_dup_r   <= 1'b0;",
        False,
    ),
    (
        "v11_seq_gap_disabled",
        "iss_drop_gap_r   <= eff_cmd_seq_en && !stale && seq_init &&\n                                            (eff_cmd_seq != prev_seq) && (eff_cmd_seq != prev_seq_plus1);",
        "iss_drop_gap_r   <= 1'b0;",
        False,
    ),
    (
        "v11_stale_lock_disabled",
        "iss_drop_stale_r <= eff_cmd_seq_en && stale;",
        "iss_drop_stale_r <= 1'b0;",
        False,
    ),
    (
        "v11_seq_gap_no_set_stale",
        "cnt_seq_gap <= cnt_seq_gap + 1'b1;\n                            stale       <= 1'b1;",
        "cnt_seq_gap <= cnt_seq_gap + 1'b1;\n                            stale       <= 1'b0;",
        False,
    ),
    # ---- v1.1 snapshot clear, count check, drop during load, AXIS best ----
    (
        "v11_snap_clear_bm_disabled",
        "init_idx       <= '0;\n                        bm_clear_r     <= 1'b1;\n                        state          <= S_INIT;",
        "init_idx       <= '0;\n                        bm_clear_r     <= 1'b0;\n                        state          <= S_INIT;",
        False,
    ),
    (
        "v11_snap_count_mismatch_ignored",
        "if ((snap_cnt == snap_exp_cnt) && (snap_obs_cnt == snap_exp_cnt)) begin",
        "if (1'b1) begin",
        False,
    ),
    (
        "v11_snap_drop_load_disabled",
        "if (snap_loading && eff_cmd_valid && !drop_load_seen) begin",
        "if (1'b0) begin",
        False,
    ),
    (
        "v11_axis_best_valid_stuck_low",
        "assign s_axis_best_tvalid = axis_best_valid_r;",
        "assign s_axis_best_tvalid = 1'b0;",
        False,
    ),
    # ---- v1.2 multi-symbol address mapping & per-symbol ladder/bitmap selection ----
    (
        "v12_sym_o_addr_ignored",
        "else              mk_o_addr = OAW'({sym, slot});",
        "else              mk_o_addr = OAW'(slot);",
        False,
    ),
    (
        "v12_sym_l_addr_ignored",
        "else              mk_l_addr = LAW'({sym, lvl});",
        "else              mk_l_addr = LAW'(lvl);",
        False,
    ),
    (
        "v12_per_sym_bm_hit_always_one",
        "wire sym_hit       = (SYMBOLS == 1) ? 1'b1 : (wr_lvl_sym   == SW'(s));",
        "wire sym_hit       = 1'b1;",
        False,
    ),
    (
        "v12_per_sym_shadow_hit_always_one",
        "wire sym_bid_hit_r = (SYMBOLS == 1) ? 1'b1 : (wr_bid_sym_r == SW'(s));",
        "wire sym_bid_hit_r = 1'b1;",
        False,
    ),
    # ---- v1.2 pipelined ADD RAW hazard, dup check, and tail-link ----
    (
        "v12_pipe_raw_hazard_disabled",
        "wire iss_add_hazard = (iss_wait_r != 3'd0) || (sym_near_full_r[iss_sym] && pipe_any);",
        "wire iss_add_hazard = (sym_near_full_r[iss_sym] && pipe_any);",
        False,
    ),
    (
        "v12_pipe_add_dup_check_disabled",
        "if (p3_valid) begin\n                        if (r2_o_valid) begin",
        "if (p3_valid) begin\n                        if (1'b0) begin",
        False,
    ),
    (
        "v12_pipe_link_pend_disabled",
        "if (p3_lvl_nz) begin\n                                link_pend <= 1'b1;",
        "if (1'b0) begin\n                                link_pend <= 1'b1;",
        False,
    ),
]


def test_mutant(
    idx: int,
    name: str,
    old: str,
    new: str,
    is_equiv: bool,
    src: str,
    work_root: Path,
    timeout: int,
) -> tuple[str, str, bool]:
    count = src.count(old)
    if count != 1:
        return (name, f"INVALID (pattern found {count}x)", is_equiv)

    mdir = work_root / f"m_{idx:02d}_{name}"
    mdir.mkdir(parents=True, exist_ok=True)
    mut_sv = mdir / "order_book_v1.sv"
    mut_sv.write_text(src.replace(old, new, 1), encoding="utf-8")

    try:
        build = subprocess.run(
            [
                "verilator",
                "--binary",
                "--timing",
                "--assert",
                "-j",
                "4",
                "--output-split",
                "2000",
                "-CFLAGS",
                "-O0",
                "-Wno-fatal",
                "--top-module",
                "tb_order_book_v1",
                "--Mdir",
                str(mdir / "obj"),
                str(RTL_BRAM),
                str(RTL_BM),
                str(mut_sv),
                str(TB),
            ],
            cwd=ROOT,
            timeout=timeout,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except subprocess.TimeoutExpired:
        return (name, "INVALID (build timeout)", is_equiv)

    if build.returncode != 0:
        return (name, "INVALID (build failed)", is_equiv)

    try:
        sim = subprocess.run(
            [str(mdir / "obj" / "Vtb_order_book_v1"), "+FAST_FAIL"],
            cwd=ROOT,
            timeout=180,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        out = sim.stdout
        failed = (
            sim.returncode != 0
            or "FAILED" in out
            or "ALL TESTS PASS" not in out
        )
    except subprocess.TimeoutExpired:
        failed = True

    shutil.rmtree(mdir, ignore_errors=True)
    if failed:
        return (name, "EQUIV" if is_equiv else "KILLED", is_equiv)
    return (name, "EQUIV" if is_equiv else "SURVIVED", is_equiv)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=180)
    args = ap.parse_args()

    src = RTL_MAIN.read_text(encoding="utf-8")
    work_root = Path(tempfile.mkdtemp(prefix="obv1_mut_"))

    killed = 0
    survived: list[str] = []
    invalid: list[str] = []
    equivalent = 0

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
            futs = [
                ex.submit(
                    test_mutant,
                    i,
                    name,
                    old,
                    new,
                    is_equiv,
                    src,
                    work_root,
                    args.timeout,
                )
                for i, (name, old, new, is_equiv) in enumerate(MUTATIONS)
            ]
            for fut in futs:
                name, status, _ = fut.result()
                print(f"{status:8s} {name}", flush=True)
                if status == "KILLED":
                    killed += 1
                elif status == "SURVIVED":
                    survived.append(name)
                elif status == "EQUIV":
                    equivalent += 1
                else:
                    invalid.append(f"{name}: {status}")
    finally:
        shutil.rmtree(work_root, ignore_errors=True)

    total = killed + len(survived)
    score = (killed / total * 100.0) if total else 0.0

    print()
    print(f"mutants       : {len(MUTATIONS)}")
    print(f"killed        : {killed}")
    print(f"survived      : {len(survived)}")
    print(f"equivalent    : {equivalent}")
    print(f"invalid       : {len(invalid)}")
    print(f"mutation score: {score:.1f}%  (target >= 95%)")
    if invalid:
        print("invalid:", *invalid, sep="\n  ")
    if survived:
        print("survivors:", *survived, sep="\n  ")
    return 0 if (score >= 95.0 and not invalid) else 1


if __name__ == "__main__":
    sys.exit(main())
