#!/usr/bin/env python3
"""Mutation testing for rtl/order_book_v1.sv (v1.1).

Tests 43 single-edit mutations covering FIFO pointers & append, level/order counts,
quantity arithmetic, TRADE FSM loop, query/queue-pos, best-price bitmap,
stall/priority hazard logic, seq comparison, stale lock, snapshot clear/error,
and AXI4-Stream best-price output.

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
        "wr_lvl_cnt  = add_l_cnt + 1'b1;",
        "wr_lvl_cnt  = add_l_cnt;",
        False,
    ),
    (
        "cnt_upd_lvl_count_not_dec",
        "wr_lvl_cnt  = w_remove ? (upd_l_cnt - 1'b1) : upd_l_cnt;",
        "wr_lvl_cnt  = upd_l_cnt;",
        False,
    ),
    (
        "cnt_total_orders_not_inc",
        "total_orders <= total_orders + 1'b1;",
        "total_orders <= total_orders;",
        False,
    ),
    (
        "cnt_total_orders_not_dec_upd",
        "if (w_remove) total_orders <= total_orders - 1'b1;",
        "if (1'b0) total_orders <= total_orders - 1'b1;",
        False,
    ),
    (
        "cnt_is_full_always_false",
        "r_is_full    <= (total_orders == (OW+1)'(MAX_ORDERS));",
        "r_is_full    <= 1'b0;",
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
        "r_bad_cmd    <= (r_qty == '0) || ((r_op != OP_TRADE) && (r_oid >= OID_W'(MAX_ORDERS)));",
        "r_bad_cmd    <= (r_op != OP_TRADE) && (r_oid >= OID_W'(MAX_ORDERS));",
        False,
    ),
    (
        "cnt_oid_oob_disabled",
        "r_bad_cmd    <= (r_qty == '0) || ((r_op != OP_TRADE) && (r_oid >= OID_W'(MAX_ORDERS)));",
        "r_bad_cmd    <= (r_qty == '0);",
        False,
    ),
    # ---- Quantity add/sub & REDUCE saturation ----
    (
        "qty_add_subtracts",
        "qwr_add     = 1'b1;\n                    qwr_a       = add_l_qty;",
        "qwr_add     = 1'b0;\n                    qwr_a       = add_l_qty;",
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
        "red_remove <= (r_qty >= dp_o_qty);",
        "red_remove <= (r_qty > dp_o_qty);",
        False,
    ),
    (
        "qty_reduce_sat_gte",
        "red_sat    <= (r_qty >  dp_o_qty);",
        "red_sat    <= (r_qty >= dp_o_qty);",
        False,
    ),
    (
        "qty_trade_partial_oqty_wrong",
        "wr_oqty_data  = state[ST_TRADE_STEP] ? (r2_o_qty - t_rem) :",
        "wr_oqty_data  = state[ST_TRADE_STEP] ? r2_o_qty :",
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
        "t_partial <= (t_rem <  dp_o_qty);",
        "t_partial <= (t_rem <= dp_o_qty);",
        False,
    ),
    (
        "trade_consume_always_stops",
        "wire             t_consume_end = t_rem_eq || (t_cnt == (OW+1)'(1));",
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
        "wr_lvl_tail = (next_t_cnt == '0) ? PTR_INVALID : t_tail;",
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
        "if (state[ST_UPD_LVL])         bm_upd_set = !(w_remove && (upd_l_cnt == (OW+1)'(1)));",
        "if (state[ST_UPD_LVL])         bm_upd_set = 1'b1;",
        False,
    ),
    (
        "best_bid_valid_stuck_low",
        "assign bid_valid    = bid_valid_q;",
        "assign bid_valid    = 1'b0;",
        False,
    ),
    (
        "best_ask_valid_stuck_low",
        "assign ask_valid    = ask_valid_q;",
        "assign ask_valid    = 1'b0;",
        False,
    ),
    # ---- Stall / hazard / priority ----
    (
        "hazard_cmd_ready_always_high",
        "wire cmd_ready_r = state[ST_IDLE];",
        "wire cmd_ready_r = !state[ST_INIT];",
        False,
    ),
    (
        "hazard_cmd_priority_disabled",
        "wire cmd_busy = !cmd_ready_r || eff_cmd_valid;",
        "wire cmd_busy = 1'b0;",
        False,
    ),
    # ---- v1.1 seq comparison & stale lock ----
    (
        "v11_seq_dup_disabled",
        "r_drop_dup   <= r_seq_en && !stale && seq_init && (r_seq == prev_seq);",
        "r_drop_dup   <= 1'b0;",
        False,
    ),
    (
        "v11_seq_gap_disabled",
        "r_drop_gap   <= r_seq_en && !stale && seq_init && (r_seq != prev_seq) && (r_seq != prev_seq_plus1);",
        "r_drop_gap   <= 1'b0;",
        False,
    ),
    (
        "v11_stale_lock_disabled",
        "r_drop_stale <= r_seq_en && stale;",
        "r_drop_stale <= 1'b0;",
        False,
    ),
    (
        "v11_seq_gap_no_set_stale",
        "cnt_seq_gap <= cnt_seq_gap + 1'b1;\n                        stale       <= 1'b1;",
        "cnt_seq_gap <= cnt_seq_gap + 1'b1;\n                        stale       <= 1'b0;",
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
            [str(mdir / "obj" / "Vtb_order_book_v1")],
            cwd=ROOT,
            timeout=60,
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
