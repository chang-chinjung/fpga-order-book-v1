# V1.1 實作規格 — 時序餘裕 + AXI-Stream + seq gap + snapshot

> 前置：v1.0 已完成並驗證（27/27 directed、10,000 筆隨機、突變 100%、覆蓋率 98.1%、
> Fmax 100.01 MHz、延遲 10 cycles）。本文件只描述 **v1.1 的增量**。
> 現有語意（含 TRADE 由 `cmd_side` 選邊）**不得改變**。

## 任務 A：時序餘裕（Fmax ≥ 120 MHz）

**現況**：100.01 MHz，餘裕 0.01%。critical path 在 `o_qty_mem` BRAM 輸出 → 加法 → 寫回，
以及 best-price 更新路徑。

**目標**：`nextpnr-ecp5 --85k` 量到 **≥ 120 MHz**（至少 3 個 placement seed 都要過 120）。

**允許的改法**（擇一或組合）：

1. 在 best-price 更新路徑加一級暫存（bitmap 更新與輸出分離）
2. 把階梯（ladder）讀取與計算拆成兩級
3. 將 `o_qty` 的加法/減法提前一級，用 forwarded value
4. 減少 best-price 樹的組合深度（例如 16 組 → 兩級 4×4）

**不可變**：

- 所有現有 directed（27 個）與 10,000 筆隨機對拍必須全過
- 突變分數維持 100%（新增的暫存不可讓 mutant 存活）
- 延遲放寬到 **≤ 12 cycles**（因為可能多一級），但必須在 README 與 tb 中如實更新

**驗收**：Fmax ≥ 120 MHz、延遲 ≤ 12 cycles、其餘門檻不變。

## 任務 B：AXI4-Stream + seq gap + snapshot

### B.1 命令介面（AXI4-Stream slave）

新增 `s_axis_cmd_*`，保留既有 `cmd_*`（兩者擇一使用，由參數 `USE_AXIS=1` 切換）。

| 訊號 | 方向 | 寬度 |
|---|---|---|
| `s_axis_cmd_tvalid` | in | 1 |
| `s_axis_cmd_tready` | out | 1 |
| `s_axis_cmd_tdata` | in | 64 |

`tdata` 欄位（little-endian 位元編排）：

| bits | 欄位 |
|---|---|
| [1:0] | op（0=ADD, 1=CANCEL, 2=REDUCE, 3=TRADE） |
| [2] | side |
| [18:3] | oid（16） |
| [28:19] | level（10） |
| [44:29] | qty（16） |
| [60:45] | **seq**（16，遞增；gap 偵測用） |
| [63:61] | 保留（0） |

- `tvalid && tready` 握手一筆命令；`TLAST`/`TKEEP` 不使用
- 命令處理期間 `tready` 可拉低（沿用現有 stall 語意）

### B.2 輸出介面（AXI4-Stream master）

`s_axis_best_*`：每次 best bid/ask 變更輸出一筆（或每週期輸出，`tvalid` 表示有效）。

| bits | 欄位 |
|---|---|
| [0] | bid_valid |
| [10:1] | best_bid |
| [26:11] | best_bid_qty |
| [27] | ask_valid |
| [37:28] | best_ask |
| [53:38] | best_ask_qty |

### B.3 seq gap 偵測

- 每筆命令帶 16-bit `seq`，正常情況每次 +1（mod 65536）
- 第一個命令建立基準；之後若 `seq != prev_seq + 1`：
  - `cnt_seq_gap++`
  - 設 `stale = 1`，**之後所有命令丟棄**（`cnt_drop_stale++`），直到 snapshot 重載完成
- 重複的 seq（`seq == prev_seq`）視為重送：丟棄，`cnt_dup_seq++`，**不**設 stale

### B.4 snapshot 重載

新增 snapshot 介面（AXI4-Stream slave，32-bit 或簡單 valid/data）：

```
snapshot_valid / snapshot_ready / snapshot_data[63:0]
```

記錄格式（`[63:62]` = type）：

| type | 內容 | 行為 |
|---|---|---|
| 0 | HEADER：`[31:0]` = order_count | 清空全簿、進入載入模式（`cmd_ready=0`） |
| 1 | LEVEL：`[1]` side、`[11:2]` level、`[27:12]` total_qty | 寫入 ladder（僅 qty，供比對） |
| 2 | ORDER：`[1]` side、`[11:2]` level、`[27:12]` qty、`[43:28]` oid | 依序 append 到該價位 FIFO |
| 3 | FOOTER：`[31:0]` = order_count（必須等於 HEADER） | 結束載入、`stale=0`、`cmd_ready=1` |

- 載入期間收到的命令：丟棄並計數 `cnt_drop_load++`
- HEADER/FOOTER 的 count 不一致 → `snapshot_error=1`，維持 stale
- 載入順序必須讓每個價位的 ORDER 由 FIFO 頭到尾出現

### B.5 計數器新增

`cnt_seq_gap, cnt_dup_seq, cnt_drop_stale, cnt_drop_load, snapshot_error`

## 測試計畫（新增）

### Directed（至少 8 個）

1. AXI-Stream 握手：tvalid/tready 正常與 stall
2. seq 正常遞增 → 無 gap
3. seq 跳號 → `cnt_seq_gap=1`、stale 生效、後續命令被丟
4. seq 重複 → `cnt_dup_seq=1`，不設 stale
5. snapshot 空簿（HEADER + FOOTER）
6. snapshot 兩個價位、各兩張訂單 → FIFO 順序與 qty 正確
7. 載入期間命令被丟（`cnt_drop_load`）
8. HEADER/FOOTER count 不一致 → `snapshot_error=1`

### 隨機

- 10,000 筆 AXI-Stream 命令，seq 正常遞增，與 Python model 對拍
- 額外 2,000 筆含 5% 跳號/重複，驗證 gap/dup 計數與 stale 行為

### 突變與覆蓋率

- 突變 ≥ 95%，且必須涵蓋：seq 比較、stale 鎖定、snapshot 清空、FIFO append
- RTL 覆蓋率 ≥ 95%

## 驗收門檻

| # | 項目 | 門檻 |
|---|---|---|
| 1 | 既有 27 directed + 10,000 隨機 | 全過，語意不變 |
| 2 | 新增 directed | ≥ 8，全過 |
| 3 | 突變 | ≥ 95% |
| 4 | 覆蓋率 | ≥ 95% |
| 5 | **Fmax** | **≥ 120 MHz（3 個 seed）** |
| 6 | 延遲 | ≤ 12 cycles |
| 7 | lint | 0 warning |

## 實作順序

1. 任務 A 先做（改動小、可獨立驗收），量到 ≥120 MHz 再往下
2. seq gap（不涉及介面，最容易）
3. snapshot（狀態機最大）
4. AXI-Stream（包裝既有介面）
5. 突變與覆蓋率補齊
