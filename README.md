# Order-by-Order Limit Order Book v1.2.1 (`order_book_v1`)

Synthesizable, verified FPGA **multi-symbol order-by-order** limit order book in SystemVerilog, implemented per [`docs/V1_IMPLEMENTATION.md`](docs/V1_IMPLEMENTATION.md), [`docs/V1_1_IMPLEMENTATION.md`](docs/V1_1_IMPLEMENTATION.md), [`docs/V1_2_IMPLEMENTATION.md`](docs/V1_2_IMPLEMENTATION.md), and [`docs/V1_2_1_IMPLEMENTATION.md`](docs/V1_2_1_IMPLEMENTATION.md).

## Architecture

- **Core module**: [`rtl/order_book_v1.sv`](rtl/order_book_v1.sv) (`SYMBOLS=1..4`, `LEVELS=1024`, `MAX_ORDERS=8192`, `QTY_W=16`, `OID_W=16`, `CNT_W=16`, `USE_AXIS=0|1`).
- **ECP5 synthesis top**: [`rtl/order_book_v1_top.sv`](rtl/order_book_v1_top.sv) (thin 274-pin `SYMBOLS=2, USE_AXIS=1` wrapper with multiplexed readout of all 13 counters so the full core fits within `LFE5U-85F-CABGA756`'s 365 user I/O pins).
- **BRAM primitive**: [`rtl/bram_sdp.sv`](rtl/bram_sdp.sv) — behavioral 2-cycle read-first SDP RAM in simulation; explicit Lattice ECP5 `DP16KD` with `REGMODE_B("OUTREG")` (`Tco = 0.96 ns`) supporting depths `1K` (`1Kx18`), `2K` (`2Kx9`), `4K` (`4Kx4`), `8K` (`8Kx2`), `16K` (`16Kx1`), and `32K` (`2×16Kx1`).
- **Multi-symbol order store & price ladder (76 × DP16KD for `SYMBOLS=2`, ≤ 80)**:
  - Address mapping: `slot = {sym, oid[OW-1:0]}`, `level_addr = {sym, level[LW-1:0]}`.
  - Per-symbol independent `total_orders[SYMBOLS]`, occupancy bitmaps (`u_bid_bm`/`u_ask_bm`), shadow quantity BRAMs (`u_bid_shadow`/`u_ask_shadow`), and best-price outputs (`bid_valid[s]`, `best_bid[s]`, `best_bid_qty[s]`, `ask_valid[s]`, `best_ask[s]`, `best_ask_qty[s]`).
- **Pipelined ADD fast path (0.500 cmd/cycle)**:
  - 1-entry issue register (`iss_*`) + 4-stage BRAM read/exec pipeline (`P0 -> P1 -> P2 -> P3`) with 2-cycle cadence (`cmd_ready_r = state[ST_IDLE] && !snap_loading && !iss_valid`), 1-cycle non-colliding `link_pend` tail-link write, and pre-registered 3-bit RAW hazard countdown (`iss_wait_r`) covering same-OID and same-level conflicts across `P0..P3`.
  - Achieves **20,000 cycles for 10,000 ADDs (0.500 cmd/cycle)** vs baseline **65,360 cycles (0.153 cmd/cycle)**.
- **Timing pipeline (v1.2.1, ≥ 133.5 MHz across 3 seeds on ECP5-85F `-6`)**:
  - 17-state one-hot FSM with `(* fsm_encoding = "none" *)` and `(* parallel_case *)` (prevents Yosys `fsm_extract` from synthesizing a 16-bit equality decoder).
  - Ladder BRAM read isolation (`S_LVL_PIPE` + `r2_lvl_*` local fabric registers) and 2-stage ladder BRAM write pipeline (`*_r` add/sub → `*_r2` pure FFs driving `DP16KD.DIA`).
  - Per-word reduction register stage (`w_any_r` / `w_bit_r`) + group (`g_*_r`) + quadrant (`q_*_r`) stages in [`rtl/bitmap_best.sv`](rtl/bitmap_best.sv) (max 3 LUT4 levels per stage).
  - Decoupled per-symbol `total_orders` counter (`bm_clear_r` + `r_add_ok`), local per-symbol shadow write registers (`sh_*_r`), `S_TRD_CMP` trade comparison stage, and split 27-bit AXIS dirty comparators.
  - Command-to-best-price latency: **13 cycles (ADD) / 16 cycles (CANCEL)** (max **16 cycles ≤ 16**).
- **v1.1 features (preserved)**:
  - Sequence gap detection (`seq` gap sets `stale=1`, dup drops without `stale`, counters `cnt_seq_gap`/`cnt_dup_seq`/`cnt_drop_stale`).
  - Snapshot reload (`HEADER`/`LEVEL`/`ORDER`/`FOOTER`, drops commands during load into `cnt_drop_load`, verifies count match).
  - AXI4-Stream (`USE_AXIS=1`): 64-bit `s_axis_cmd_*` slave (`[61:60]=sym`) and 64-bit `s_axis_best_*` master (`[63:61]=sym`).

## How to Run

From `fpga/order-book-v1/` (WSL / Linux with Verilator ≥ 5.0, Python 3, Yosys, and nextpnr-ecp5):

```bash
make lint        # Verilator -Wall on order_book_v1, order_book_v1_top, and tb (0 warnings)
make sim         # 48 directed tests + 10k ADD throughput + 34,000 random steps (legacy + AXIS + M2)
make coverage    # Line coverage report (target RTL >= 95%)
make mutate      # 50-mutant mutation testing (target >= 95%)
make pnr-3seeds  # Yosys + nextpnr-ecp5 (LFE5U-85F CABGA756, target >= 130 MHz, seeds 1/2/3)
make clean       # Remove build artifacts
```

## Measured Results (v1.2.1)

| Metric | Target | Measured |
|---|---|---|
| Verilator `-Wall` lint | 0 warnings | **0 warnings** |
| Directed tests | 48/48 | **48/48 passed** (38 v1.0/v1.1 + 10 v1.2) |
| Legacy + AXIS random co-sim | 10k + 10k + 2k, 0 mismatch | **10,000 + 10,000 + 2,000 steps, 0 mismatches** |
| Multi-symbol (`SYMBOLS=2`) random co-sim | 10k normal + 2k (5% gap/dup) | **10,000 + 2,000 steps, 0 mismatches** |
| Acceptance rate (10,000 ADDs) | ≥ 0.5 cmd/cycle | **0.500 cmd/cycle** (20,000 cycles vs 65,360 baseline) |
| Mutation testing | ≥ 95% | **49/49 killed (100.0%)**, 1 equivalent, 0 survived, 0 invalid |
| RTL line coverage | ≥ 95% | **866/903 (95.9%)** (`bitmap_best.sv` 100.0%, `bram_sdp.sv` 100.0%, `order_book_v1.sv` 95.5%) |
| `SYMBOLS=2` BRAM (`DP16KD`) | ≤ 80 | **76 / 208 DP16KD** (12,674 LUT4, 7,961 FF) |
| Fmax (ECP5 85F `-6`, 3 seeds) | ≥ 130 MHz (all 3 seeds) | **141.82 / 135.12 / 133.53 MHz** (worst **133.53 MHz**, PASS) |
| Latency (cmd → best price) | ≤ 16 cycles | **16 cycles** max (13 ADD, 16 CANCEL) |

## Known Limitations

1. **`s_axis_cmd_tdata` `seq` width for `SYMBOLS > 1`**: v1.1 placed 16-bit `seq` in `[60:45]` while v1.2 §A.1 places `sym` in `[61:60]`. For `SYMBOLS == 1` backward compatibility, `seq` uses full 16-bit `[60:45]`; for `SYMBOLS > 1`, `sym = [60 +: SW]` and `seq = {1'b0, [59:45]}` (15-bit mod 32768).
2. **`snapshot_data` `side` bit for `SYMBOLS > 1`**: v1.1 placed `side` in `[1]` while v1.2 §A.3 places `sym` in `[1:0]`. For `SYMBOLS == 1`, `side = [1]`; for `SYMBOLS > 1`, `sym = [0 +: SW]` and `side = [44]` (in the previously reserved `[61:44]` region).
3. **Reset / snapshot clear duration**: `S_INIT` clears `o_valid` and ladder BRAMs sequentially (`SYMBOLS * MAX_ORDERS` = 16,384 cycles for `SYMBOLS=2`), holding `cmd_ready = 0` and `qry_ready = 0`.
4. **Query latency at deep queue positions**: `qry_pos` walks `o_prev` pointers so middle-`CANCEL` stays O(1), taking `2 * min(pos, 63) + 4` cycles (aborting/restarting cleanly if a command arrives mid-walk).
5. **Out of scope**: Multi-level sweep `TRADE`.
