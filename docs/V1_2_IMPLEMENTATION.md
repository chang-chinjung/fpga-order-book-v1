# V1.2 實作規格 — 多商品 + 接受率提升 + 時序餘裕

> 前置：v1.1 已完成並驗證（38/38 directed、3 萬筆隨機、突變 100%、覆蓋率 97.5%、
> Fmax 123.69 / 122.19 / 128.44 MHz、延遲 12 cycles）。本文件只描述 **v1.2 的增量**。
> 現有語意（含 TRADE 由 `cmd_side` 選邊、seq gap、snapshot）**不得改變**。

## 任務 A：多商品（SYMBOLS = 2，可參數化到 4）

### A.1 介面

| 訊號 | 方向 | 寬度 | 說明 |
|---|---|---|---|
| `cmd_sym` | in | `SW = $clog2(SYMBOLS)` | 商品編號（0..SYMBOLS-1） |
| `qry_sym` | in | SW | 查詢的商品 |
| `s_axis_cmd_tdata` | in | 64 | bit[63:62] 保留；**bit[61:60] = sym**（改版） |
| `s_axis_best_tdata` | out | 64 | 新增 bit[63:61] = sym；其餘欄位不變 |
| `snapshot_data` | in | 64 | ORDER/LEVEL 記錄新增 sym 欄位（見 A.3） |

- 既有 `cmd_*` 介面保留；`cmd_sym` 為新增輸入。
- `SYMBOLS` 參數預設 2，合法範圍 1..4。

### A.2 儲存

- 每個商品有獨立的 order store、bid/ask ladder、occupancy bitmap。
- 以 `generate` 複製，或把 BRAM 深度擴充為 `SYMBOLS * MAX_ORDERS`（位址高位放 sym）。
- 位址映射：`slot = {sym, oid[OW-1:0]}`、`level_addr = {sym, level[LW-1:0]}`。
- 資源上限：`SYMBOLS=2` 時 DP16KD ≤ 80；`SYMBOLS=4` 時 ≤ 160（不得超過 208）。

### A.3 snapshot 格式調整

| type | 內容 |
|---|---|
| 0 | HEADER：`[31:0]` order_count（全商品合計） |
| 1 | LEVEL：`[1:0]` sym、`[11:2]` level、`[27:12]` qty |
| 2 | ORDER：`[1:0]` sym、`[11:2]` level、`[27:12]` qty、`[43:28]` oid |
| 3 | FOOTER：`[31:0]` order_count |

### A.4 輸出

`best_bid/best_ask/best_*_qty` 改為**每商品一組**（`SYMBOLS` 組），
或加 `best_sym` 選擇器（由上層決定）。**規格採用「每商品一組」**，避免額外仲裁。

## 任務 B：接受率提升（≥ 0.5 command/cycle）

**現況**：`cmd_ready` 只在 `S_IDLE` 為高，平均約 4~6 cycles 才吃一筆命令。

**目標**：在「連續命令打到不同 oid / 不同 level」時，**達到 0.5 command/cycle**
（即 2 cycles 吃一筆）；量測方式：

- 送 10,000 筆 ADD（oid 0..8191 循環、level 分散、sym 交錯）
- 記錄總 cycle 數，`10,000 / cycles ≥ 0.5`

**允許的改法**：

1. 把命令處理拆成「解碼/讀取」與「寫回」兩級，交錯執行（skid buffer）
2. 前一筆寫回時就接受下一筆
3. 衝突時（同 oid 或同 level 的 RAW）仍可 stall

**不可**：為了達到 0.5 而改變語意、或省略計數器。

## 任務 C：時序餘裕

- 三個 placement seed 的 **最差 Fmax ≥ 130 MHz**
- 延遲放寬到 **≤ 14 cycles**（多一級可接受），但 tb 與 README 要如實更新

## 測試計畫

### Directed（至少 10 個）

1. 兩個商品同時存在，best bid/ask 互不干擾
2. 同一 oid 在兩個商品各自獨立（sym 0 的 oid 5 與 sym 1 的 oid 5）
3. CANCEL 只影響指定商品
4. TRADE 只影響指定商品
5. snapshot 載入兩個商品，FIFO 順序與 qty 正確
6. snapshot count 不一致 → `snapshot_error`
7. seq gap 在多商品下仍正確（global seq）
8. AXI-Stream sym 欄位解碼正確
9. 接受率：連續 100 筆不同 oid，cycles ≤ 200
10. 衝突時 stall：同 oid 連續兩筆，結果仍正確

### 隨機

- 10,000 筆多商品命令（sym 隨機），與 Python model 對拍
- 2,000 筆含 seq 跳號/重複（沿用 v1.1 的產生器，加 sym 欄位）

### 突變

- ≥ 95%，必須涵蓋：sym 位址映射、per-symbol ladder 選擇、接受率改動的 bypass 邏輯

### 覆蓋率

- RTL ≥ 95%

## 驗收門檻

| # | 項目 | 門檻 |
|---|---|---|
| 1 | 既有 38 directed + 3 萬筆隨機 | 全過，語意不變 |
| 2 | 新 directed | ≥ 10，全過 |
| 3 | 突變 | ≥ 95% |
| 4 | 覆蓋率 | ≥ 95% |
| 5 | **接受率** | **≥ 0.5 command/cycle（10k ADD 量測）** |
| 6 | Fmax | **≥ 130 MHz（3 seeds 最差）** |
| 7 | 延遲 | ≤ 14 cycles |
| 8 | 資源 | `SYMBOLS=2` 時 DP16KD ≤ 80 |
| 9 | lint | 0 warning |

## 實作順序

1. 任務 A（多商品）先做：位址映射 + 每商品輸出 + snapshot 欄位
2. 任務 B（接受率）：先量現況，再改
3. 任務 C（時序）：最後調
4. 突變與覆蓋率補齊

## 非目標

- 不做 1 event/cycle（那是 v1.3）
- 不做跨商品撮合
- 不改 seq/snapshot 的既有語意
