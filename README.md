# Order-by-Order Limit Order Book v1.1 (`order_book_v1`)

Synthesizable, verified FPGA **order-by-order** limit order book in SystemVerilog, implemented per [`docs/V1_IMPLEMENTATION.md`](docs/V1_IMPLEMENTATION.md) and [`docs/V1_1_IMPLEMENTATION.md`](docs/V1_1_IMPLEMENTATION.md).

## Architecture

- **Core module**: [`rtl/order_book_v1.sv`](rtl/order_book_v1.sv) (`LEVELS=1024`, `MAX_ORDERS=8192`, `QTY_W=16`, `OID_W=16`, `CNT_W=16`, `USE_AXIS=0|1`).
- **ECP5 synthesis top**: [`rtl/order_book_v1_top.sv`](rtl/order_book_v1_top.sv) (thin 263-pin `USE_AXIS=1` wrapper with multiplexed readout of all 13 counters so the full v1.1 core fits within `LFE5U-85F-CABGA756`'s 365 user I/O pins).
- **BRAM primitive**: [`rtl/bram_sdp.sv`](rtl/bram_sdp.sv) — behavioral 2-cycle read-first SDP RAM in simulation; explicit Lattice ECP5 `DP16KD` with `REGMODE_B("OUTREG")` (`Tco = 0.96 ns`) in synthesis.
- **Order store & price ladder (39 × DP16KD)**: `o_valid`, `o_qty`, `o_meta ({side, level})`, `o_prev`, `o_next` with `(OW+1)`-bit link pointers (`MSB=1` valid, `0` = INVALID); separate bid/ask ladders (`l_qty`, `l_count`, `l_head`, `l_tail`) plus shadow quantity BRAMs for best-price lookup.
- **Best price**: two single-direction instances of [`rtl/bitmap_best.sv`](rtl/bitmap_best.sv) (`FIND_HI=1` for bid, `FIND_HI=0` for ask) with synchronous `clear`, direct-bit updates, and a 2-level 4×4 parallel quadrant reduction tree.
- **Timing pipeline (Task A)**: one-hot FSM, registered BRAM read/write ports, operand-registered ladder quantity adder/subtractor (`qwr_*`), and pre-registered 16-bit comparisons achieve **≥ 122 MHz** across 3 ECP5 placement seeds with command-to-best-price latency **≤ 12 cycles**.
- **v1.1 features (Task B)**:
  - **Sequence gap detection**: 16-bit `seq` (mod 65536); first command establishes baseline; duplicates drop (`cnt_dup_seq++`, no `stale`); gaps increment `cnt_seq_gap++`, set `stale=1`, and drop subsequent commands (`cnt_drop_stale++`) until snapshot recovery.
  - **Snapshot reload**: `snapshot_valid`/`snapshot_ready`/`snapshot_data[63:0]` supporting `HEADER` (clears book & bitmaps, `cmd_ready=0`), `LEVEL`, `ORDER` (FIFO append reusing the ADD pipeline), and `FOOTER` (count check; clears `stale` on match, sets `snapshot_error=1` & keeps `stale=1` on mismatch). Commands arriving during load are dropped (`cnt_drop_load++`).
  - **AXI4-Stream (`USE_AXIS=1`)**: 64-bit `s_axis_cmd_*` slave and 54-bit `s_axis_best_*` master (backpressure-compliant), selected cleanly via `USE_AXIS`.

## How to Run

From `fpga/order-book-v1/` (WSL / Linux with Verilator ≥ 5.0, Python 3, Yosys, and nextpnr-ecp5):

```bash
make lint        # Verilator -Wall on order_book_v1, order_book_v1_top, and tb (0 warnings)
make sim         # 38 directed tests + 10k legacy + 10k AXIS normal + 2k AXIS gap/dup random
make coverage    # Line coverage report (target RTL >= 95%)
make mutate      # 43-mutant mutation testing (target >= 95%)
make pnr-3seeds  # Yosys + nextpnr-ecp5 (LFE5U-85F CABGA756, target >= 120 MHz, seeds 1/2/3)
make clean       # Remove build artifacts
```

## Measured Results (v1.1)

| Metric | Target | Measured |
|---|---|---|
| Verilator `-Wall` lint | 0 warnings | **0 warnings** |
| Directed tests | 27 legacy + ≥ 8 new | **38/38 passed** (27 legacy + 11 v1.1) |
| Legacy random co-sim | 10,000 steps, 0 mismatch | **10,000 steps, 0 mismatches** |
| AXI-Stream random co-sim | 10,000 normal + 2,000 (5% gap/dup) | **10,000 + 2,000 steps, 0 mismatches** |
| Mutation testing | ≥ 95% | **42/42 killed (100.0%)**, 1 equivalent, 0 survived, 0 invalid |
| RTL line coverage | ≥ 95% | **583/598 (97.5%)** (`bitmap_best.sv` 100.0%, `bram_sdp.sv` 100.0%, `order_book_v1.sv` 97.2%) |
| Fmax (ECP5 85F, 3 seeds) | ≥ 120 MHz (all 3 seeds) | **123.69 / 122.19 / 128.44 MHz** (worst **122.19 MHz**, 39/208 DP16KD, 7,565 LUT4) |
| Latency (cmd → best price) | ≤ 12 cycles | **12 cycles** max |

## Known Limitations

1. **Reset / snapshot clear duration**: Because ECP5 `DP16KD` block RAMs lack asynchronous bulk clear, `S_INIT` clears `o_valid` and ladder BRAMs sequentially (`MAX_ORDERS` = 8,192 cycles, ~67 µs at 122 MHz) on reset and snapshot `HEADER`, holding `cmd_ready = 0` and `qry_ready = 0`.
2. **Query latency at deep queue positions**: `qry_pos` walks `o_prev` pointers so middle-`CANCEL` stays O(1), taking `2 * min(pos, 63) + 4` cycles (aborting/restarting cleanly if a command arrives mid-walk).
3. **`cmd_qty == 0` on CANCEL**: Checked uniformly across all operations (`cnt_drop_bad++`); valid `CANCEL` commands must drive a non-zero `qty` (e.g., 1).
4. **TRADE side selection**: `TRADE` uses `cmd_side` to select bid vs ask and ignores `cmd_oid`.
5. **ECP5 package pin count**: Exposing both legacy `cmd_*` + `s_axis_cmd_*` + `s_axis_best_*` + `snapshot_*` + 13 parallel 16-bit counters simultaneously totals 569 pins (> CABGA756's 365 user I/Os). `order_book_v1_top.sv` wraps `order_book_v1 #(.USE_AXIS(1))` with a 4-bit counter selector (`263` pins) while preserving 100% of core logic and all 13 counters for P&R timing verification.
6. **Out of scope**: Multi-symbol books and multi-level sweep `TRADE`.
