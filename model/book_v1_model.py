#!/usr/bin/env python3
"""Golden reference model and stimulus/expected generator for order_book_v1."""

from __future__ import annotations

import argparse
import pathlib
import random
from dataclasses import dataclass

OP_ADD = 0
OP_CANCEL = 1
OP_REDUCE = 2
OP_TRADE = 3


@dataclass
class Order:
    side: int
    level: int
    qty: int


class OrderBookV1Model:
    def __init__(
        self,
        levels: int = 1024,
        max_orders: int = 8192,
        qty_w: int = 16,
        cnt_w: int = 16,
    ) -> None:
        self.levels = levels
        self.max_orders = max_orders
        self.qty_mask = (1 << qty_w) - 1
        self.cnt_mask = (1 << cnt_w) - 1
        self.reset()

    def reset(self) -> None:
        self.orders: dict[int, Order] = {}
        # ladders[side][level] -> list of oids in FIFO order
        self.ladders: list[dict[int, list[int]]] = [{}, {}]
        self.cnt_add = 0
        self.cnt_cancel = 0
        self.cnt_reduce = 0
        self.cnt_trade = 0
        self.cnt_drop_dup = 0
        self.cnt_drop_unknown = 0
        self.cnt_drop_full = 0
        self.cnt_drop_bad = 0
        self.cnt_sat = 0
        # v1.1 seq / stale / snapshot state
        self.seq_init = False
        self.prev_seq = 0
        self.stale = False
        self.cnt_seq_gap = 0
        self.cnt_dup_seq = 0
        self.cnt_drop_stale = 0
        self.cnt_drop_load = 0

    def _inc(self, attr: str) -> None:
        setattr(self, attr, (getattr(self, attr) + 1) & self.cnt_mask)

    def snapshot_reload(self, items: list[tuple[int, int, int, int]]) -> None:
        """Clear book, append (side, level, qty, oid) in FIFO order, clear stale & seq_init."""
        self.orders.clear()
        self.ladders = [{}, {}]
        for side, level, qty, oid in items:
            if qty == 0 or oid >= self.max_orders:
                continue
            if len(self.orders) >= self.max_orders or oid in self.orders:
                continue
            self.orders[oid] = Order(side=side, level=level, qty=qty)
            self.ladders[side].setdefault(level, []).append(oid)
        self.stale = False
        self.seq_init = False

    def step_seq(self, op: int, side: int, oid: int, level: int, qty: int, seq: int) -> None:
        seq &= 0xFFFF
        if self.stale:
            self._inc("cnt_drop_stale")
            return
        if self.seq_init:
            if seq == self.prev_seq:
                self._inc("cnt_dup_seq")
                return
            if seq != ((self.prev_seq + 1) & 0xFFFF):
                self._inc("cnt_seq_gap")
                self.stale = True
                return
        self.seq_init = True
        self.prev_seq = seq
        self.step(op, side, oid, level, qty)

    def _level_qty(self, side: int, level: int) -> int:
        q = self.ladders[side].get(level)
        if not q:
            return 0
        total = 0
        for oid in q:
            total = (total + self.orders[oid].qty) & self.qty_mask
        return total

    def step(self, op: int, side: int, oid: int, level: int, qty: int) -> None:
        if qty == 0 or (op != OP_TRADE and oid >= self.max_orders):
            self._inc("cnt_drop_bad")
            return

        if op == OP_ADD:
            if len(self.orders) >= self.max_orders:
                self._inc("cnt_drop_full")
                return
            if oid in self.orders:
                self._inc("cnt_drop_dup")
                return
            self.orders[oid] = Order(side=side, level=level, qty=qty)
            self.ladders[side].setdefault(level, []).append(oid)
            self._inc("cnt_add")

        elif op == OP_CANCEL:
            ord_obj = self.orders.get(oid)
            if ord_obj is None:
                self._inc("cnt_drop_unknown")
                return
            q = self.ladders[ord_obj.side][ord_obj.level]
            q.remove(oid)
            if not q:
                del self.ladders[ord_obj.side][ord_obj.level]
            del self.orders[oid]
            self._inc("cnt_cancel")

        elif op == OP_REDUCE:
            ord_obj = self.orders.get(oid)
            if ord_obj is None:
                self._inc("cnt_drop_unknown")
                return
            if qty >= ord_obj.qty:
                if qty > ord_obj.qty:
                    self._inc("cnt_sat")
                q = self.ladders[ord_obj.side][ord_obj.level]
                q.remove(oid)
                if not q:
                    del self.ladders[ord_obj.side][ord_obj.level]
                del self.orders[oid]
            else:
                ord_obj.qty -= qty
            self._inc("cnt_reduce")

        elif op == OP_TRADE:
            tside = side
            if level not in self.ladders[tside]:
                self._inc("cnt_drop_unknown")
                return

            q = self.ladders[tside][level]
            rem = qty
            while rem > 0 and q:
                head_oid = q[0]
                head_ord = self.orders[head_oid]
                if rem < head_ord.qty:
                    head_ord.qty -= rem
                    rem = 0
                else:
                    rem -= head_ord.qty
                    q.pop(0)
                    del self.orders[head_oid]
            if not q:
                del self.ladders[tside][level]
            self._inc("cnt_trade")

    def query(self, oid: int) -> tuple[int, int, int, int]:
        if oid >= self.max_orders or oid not in self.orders:
            return (0, 0, 0, 0)
        ord_obj = self.orders[oid]
        pos = self.ladders[ord_obj.side][ord_obj.level].index(oid)
        return (1, ord_obj.level, ord_obj.qty, min(pos, 63))

    def best(self) -> tuple[int, int, int, int, int, int]:
        if self.ladders[0]:
            b_lvl = max(self.ladders[0].keys())
            b_val = 1
            b_qty = self._level_qty(0, b_lvl)
        else:
            b_val, b_lvl, b_qty = 0, 0, 0

        if self.ladders[1]:
            a_lvl = min(self.ladders[1].keys())
            a_val = 1
            a_qty = self._level_qty(1, a_lvl)
        else:
            a_val, a_lvl, a_qty = 0, 0, 0

        return (b_val, b_lvl, b_qty, a_val, a_lvl, a_qty)

    def counters(self) -> tuple[int, ...]:
        return (
            self.cnt_add,
            self.cnt_cancel,
            self.cnt_reduce,
            self.cnt_trade,
            self.cnt_drop_dup,
            self.cnt_drop_unknown,
            self.cnt_drop_full,
            self.cnt_drop_bad,
            self.cnt_sat,
        )


def generate_random(n: int, seed: int, out_dir: pathlib.Path) -> None:
    rng = random.Random(seed)
    model = OrderBookV1Model()

    out_dir.mkdir(parents=True, exist_ok=True)
    stim_lines: list[str] = []
    exp_lines: list[str] = []

    # Concentrate some levels so multi-order FIFOs and trades happen frequently,
    # while also touching boundary levels 0 and 1023 and spread levels across 0..1023.
    hot_bids = [0, 1, 15, 16, 100, 250, 400, 500, 511]
    hot_asks = [512, 520, 600, 750, 900, 1000, 1022, 1023]

    next_oid = 0
    for i in range(n):
        r = rng.random()
        # Spec §9.2: ADD 50%, CANCEL 20%, REDUCE 15%, TRADE 15%
        if r < 0.50:
            op = OP_ADD
            side = rng.randint(0, 1)
            if rng.random() < 0.03 and model.orders:
                # Duplicate OID
                oid = rng.choice(list(model.orders.keys()))
            elif rng.random() < 0.01:
                # OOB OID
                oid = rng.randint(model.max_orders, model.max_orders + 100)
            else:
                oid = next_oid % model.max_orders
                next_oid += 1
            if rng.random() < 0.7:
                level = rng.choice(hot_bids if side == 0 else hot_asks)
            else:
                level = rng.randint(0, 511) if side == 0 else rng.randint(512, 1023)
            qty = 0 if rng.random() < 0.01 else rng.randint(1, 100)

        elif r < 0.70:
            op = OP_CANCEL
            side = rng.randint(0, 1)
            if model.orders and rng.random() < 0.85:
                oid = rng.choice(list(model.orders.keys()))
            else:
                oid = rng.randint(0, model.max_orders + 10)
            level = rng.randint(0, model.levels - 1)
            qty = 0 if rng.random() < 0.01 else 1

        elif r < 0.85:
            op = OP_REDUCE
            side = rng.randint(0, 1)
            if model.orders and rng.random() < 0.85:
                oid = rng.choice(list(model.orders.keys()))
                cur_q = model.orders[oid].qty
                # Mix partial, exact, and saturating reduces
                kind = rng.random()
                if kind < 0.5 and cur_q > 1:
                    qty = rng.randint(1, cur_q - 1)
                elif kind < 0.75:
                    qty = cur_q
                else:
                    qty = cur_q + rng.randint(1, 50)
            else:
                oid = rng.randint(0, model.max_orders - 1)
                qty = rng.randint(1, 50)
            level = rng.randint(0, model.levels - 1)

        else:
            op = OP_TRADE
            side = rng.randint(0, 1)  # ignored by TRADE
            oid = rng.randint(0, 65535)  # ignored by TRADE
            all_lvls = list(model.ladders[0].keys()) + list(model.ladders[1].keys())
            if all_lvls and rng.random() < 0.85:
                level = rng.choice(all_lvls)
            else:
                level = rng.randint(0, model.levels - 1)
            qty = 0 if rng.random() < 0.01 else rng.randint(1, 250)

        model.step(op, side, oid, level, qty)

        # Pick an OID to query after this command
        if model.orders and rng.random() < 0.8:
            qry_oid = rng.choice(list(model.orders.keys()))
        elif rng.random() < 0.1:
            qry_oid = rng.randint(model.max_orders, model.max_orders + 50)
        else:
            qry_oid = rng.randint(0, model.max_orders - 1)

        q_res = model.query(qry_oid)
        b_res = model.best()
        c_res = model.counters()

        stim_lines.append(f"{op} {side} {oid} {level} {qty} {qry_oid}\n")
        exp_lines.append(
            " ".join(str(x) for x in (*b_res, *q_res, *c_res)) + "\n"
        )

    (out_dir / "stim_rand.txt").write_text("".join(stim_lines), encoding="utf-8")
    (out_dir / "exp_rand.txt").write_text("".join(exp_lines), encoding="utf-8")
    print(f"Generated {n} random steps (seed={seed}) in {out_dir}")


def _rand_cmd(
    rng: random.Random,
    model: OrderBookV1Model,
    next_oid: int,
    hot_bids: list[int],
    hot_asks: list[int],
) -> tuple[int, int, int, int, int, int]:
    r = rng.random()
    if r < 0.50:
        op = OP_ADD
        side = rng.randint(0, 1)
        if rng.random() < 0.03 and model.orders:
            oid = rng.choice(list(model.orders.keys()))
        elif rng.random() < 0.01:
            oid = rng.randint(model.max_orders, model.max_orders + 100)
        else:
            oid = next_oid % model.max_orders
            next_oid += 1
        if rng.random() < 0.7:
            level = rng.choice(hot_bids if side == 0 else hot_asks)
        else:
            level = rng.randint(0, 511) if side == 0 else rng.randint(512, 1023)
        qty = 0 if rng.random() < 0.01 else rng.randint(1, 100)
    elif r < 0.70:
        op = OP_CANCEL
        side = rng.randint(0, 1)
        if model.orders and rng.random() < 0.85:
            oid = rng.choice(list(model.orders.keys()))
        else:
            oid = rng.randint(0, model.max_orders + 10)
        level = rng.randint(0, model.levels - 1)
        qty = 0 if rng.random() < 0.01 else 1
    elif r < 0.85:
        op = OP_REDUCE
        side = rng.randint(0, 1)
        if model.orders and rng.random() < 0.85:
            oid = rng.choice(list(model.orders.keys()))
            cur_q = model.orders[oid].qty
            kind = rng.random()
            if kind < 0.5 and cur_q > 1:
                qty = rng.randint(1, cur_q - 1)
            elif kind < 0.75:
                qty = cur_q
            else:
                qty = cur_q + rng.randint(1, 50)
        else:
            oid = rng.randint(0, model.max_orders - 1)
            qty = rng.randint(1, 50)
        level = rng.randint(0, model.levels - 1)
    else:
        op = OP_TRADE
        side = rng.randint(0, 1)
        oid = rng.randint(0, 65535)
        all_lvls = list(model.ladders[0].keys()) + list(model.ladders[1].keys())
        if all_lvls and rng.random() < 0.85:
            level = rng.choice(all_lvls)
        else:
            level = rng.randint(0, model.levels - 1)
        qty = 0 if rng.random() < 0.01 else rng.randint(1, 250)
    return op, side, oid, level, qty, next_oid


def generate_axis_random(
    n_norm: int, n_gap: int, seed: int, out_dir: pathlib.Path
) -> None:
    hot_bids = [0, 1, 15, 16, 100, 250, 400, 500, 511]
    hot_asks = [512, 520, 600, 750, 900, 1000, 1022, 1023]
    out_dir.mkdir(parents=True, exist_ok=True)

    # 1) 10,000 AXI-Stream steps with normal incrementing seq (including 16-bit wrap)
    rng = random.Random(seed)
    model = OrderBookV1Model()
    stim_lines: list[str] = []
    exp_lines: list[str] = []
    next_oid = 0
    seq = 65000
    for _ in range(n_norm):
        op, side, oid, level, qty, next_oid = _rand_cmd(
            rng, model, next_oid, hot_bids, hot_asks
        )
        model.step_seq(op, side, oid, level, qty, seq)
        if model.orders and rng.random() < 0.8:
            qry_oid = rng.choice(list(model.orders.keys()))
        else:
            qry_oid = rng.randint(0, model.max_orders - 1)
        q_res = model.query(qry_oid)
        b_res = model.best()
        c_res = model.counters()
        stim_lines.append(f"{op} {side} {oid} {level} {qty} {seq} {qry_oid}\n")
        exp_lines.append(
            " ".join(
                str(x)
                for x in (
                    *b_res,
                    *q_res,
                    *c_res,
                    int(model.stale),
                    model.cnt_seq_gap,
                    model.cnt_dup_seq,
                    model.cnt_drop_stale,
                )
            )
            + "\n"
        )
        seq = (seq + 1) & 0xFFFF

    (out_dir / "stim_axis_norm.txt").write_text("".join(stim_lines), encoding="utf-8")
    (out_dir / "exp_axis_norm.txt").write_text("".join(exp_lines), encoding="utf-8")

    # 2) 2,000 AXI-Stream steps with ~5% seq gap/dup (2.5% gap, 2.5% dup),
    #    with periodic empty snapshot recovery after 15 stale drops so multiple
    #    gaps, dups, stale locks, and recoveries are exercised.
    rng = random.Random(seed + 1)
    model = OrderBookV1Model()
    stim_lines = []
    exp_lines = []
    next_oid = 0
    seq = 100
    stale_run = 0
    for _ in range(n_gap):
        do_snap = 0
        if model.stale and stale_run >= 15:
            do_snap = 1
            model.snapshot_reload([])
            stale_run = 0
            seq = (seq + 10) & 0xFFFF

        op, side, oid, level, qty, next_oid = _rand_cmd(
            rng, model, next_oid, hot_bids, hot_asks
        )
        p = rng.random()
        if not model.stale and model.seq_init and p < 0.025:
            # Duplicate seq
            cmd_seq = model.prev_seq
        elif not model.stale and model.seq_init and p < 0.050:
            # Gap seq (+2..+5)
            cmd_seq = (model.prev_seq + rng.randint(2, 5)) & 0xFFFF
            seq = (cmd_seq + 1) & 0xFFFF
        else:
            cmd_seq = seq
            seq = (seq + 1) & 0xFFFF

        was_stale = model.stale
        model.step_seq(op, side, oid, level, qty, cmd_seq)
        if was_stale:
            stale_run += 1

        if model.orders and rng.random() < 0.8:
            qry_oid = rng.choice(list(model.orders.keys()))
        else:
            qry_oid = rng.randint(0, model.max_orders - 1)
        q_res = model.query(qry_oid)
        b_res = model.best()
        c_res = model.counters()
        stim_lines.append(
            f"{do_snap} {op} {side} {oid} {level} {qty} {cmd_seq} {qry_oid}\n"
        )
        exp_lines.append(
            " ".join(
                str(x)
                for x in (
                    *b_res,
                    *q_res,
                    *c_res,
                    int(model.stale),
                    model.cnt_seq_gap,
                    model.cnt_dup_seq,
                    model.cnt_drop_stale,
                )
            )
            + "\n"
        )

    (out_dir / "stim_axis_gap.txt").write_text("".join(stim_lines), encoding="utf-8")
    (out_dir / "exp_axis_gap.txt").write_text("".join(exp_lines), encoding="utf-8")
    print(
        f"Generated {n_norm} AXIS normal + {n_gap} AXIS gap/dup steps "
        f"(gaps={model.cnt_seq_gap}, dups={model.cnt_dup_seq}, stale_drops={model.cnt_drop_stale})"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=10000)
    ap.add_argument("--n-axis", type=int, default=10000)
    ap.add_argument("--n-gap", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--dir", type=pathlib.Path, default=pathlib.Path("build"))
    args = ap.parse_args()
    generate_random(args.n, args.seed, args.dir)
    generate_axis_random(args.n_axis, args.n_gap, args.seed + 100, args.dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
