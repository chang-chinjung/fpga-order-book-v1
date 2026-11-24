# AGY 任務 Prompt — v1.2（多商品 + 接受率 + 時序）

以下整段直接貼給 Antigravity CLI。

---

## 你的任務

在 `D:\stock_program\daytrade\AI當沖-GPT1\fpga\order-book-v1\` 繼續開發 **v1.2**。

**第一件事：讀 `docs/V1_2_IMPLEMENTATION.md`（同資料夾）。**
那是 v1.2 的規格書：介面、位址映射、snapshot 格式、接受率目標、驗收門檻都已定死。
本 prompt 只補充流程與邊界；衝突時以規格書為準。

## 現況（v1.1 已驗證，不要破壞）

| 項目 | 數字 |
|---|---|
| Directed | 38/38 |
| Random | 10k legacy + 10k AXIS + 2k gap，0 mismatch |
| 突變 | 42 killed / 1 equivalent / 0 survived = 100% |
| RTL 覆蓋率 | 583/598 = 97.5% |
| Fmax | 123.69 / 122.19 / 128.44 MHz（3 seeds） |
| 延遲 | 12 cycles |
| lint | 0 warning |

**開工前先跑一次 `make sim`，確認 38/38 與三組隨機都過。** 不過就停在這裡回報。

**已完成、不得回退**：TRADE 由 `cmd_side` 選邊、seq gap、snapshot、AXI-Stream。

## 工作邊界

1. 只能修改 `fpga/order-book-v1/` 底下的檔案。
2. 不要動 `fpga/order-book/`、`_backtest/`、`data/`、`sim/`、`templates/`、`.env`、`.pylibs/`。
3. 不要 git commit / push。
4. 不要修改既有測試的預期值。

## 三個任務（依序）

### 任務 A：多商品（SYMBOLS=2，可到 4）

- 位址映射：`slot = {sym, oid}`、`level = {sym, level}`
- 每商品獨立的 order store / ladder / bitmap
- `s_axis_cmd_tdata` 加 sym 欄位（bit[61:60]）
- snapshot 的 LEVEL/ORDER 記錄加 sym
- 輸出改為每商品一組 best bid/ask
- **先確認資源**：`SYMBOLS=2` 時 DP16KD ≤ 80

### 任務 B：接受率 ≥ 0.5 command/cycle

- 先量現況（10,000 筆 ADD 的總 cycle 數）
- 可以拆成「解碼/讀取」與「寫回」兩級交錯
- 衝突（同 oid / 同 level 的 RAW）仍可 stall
- 量測方式：10,000 筆 ADD（不同 oid、分散 level、sym 交錯）÷ 總 cycle ≥ 0.5

### 任務 C：Fmax ≥ 130 MHz（3 seeds 最差）

- 延遲放寬到 ≤ 14 cycles
- 不能為了時序而改變語意

## 測試要求

| 項目 | 要求 |
|---|---|
| 既有 directed | 38 個，全過（不得改預期值） |
| 新增 directed | ≥ 10 個（商品隔離、snapshot 多商品、AXIS sym、接受率、衝突） |
| 隨機 | 10,000 筆多商品 + 2,000 筆含 gap/dup |
| 突變 | ≥ 95%，涵蓋 sym 映射、per-symbol ladder 選擇、bypass 邏輯 |
| 覆蓋率 | RTL ≥ 95% |
| lint | 0 warning |

## 驗收（缺一不可）

| 項目 | 門檻 |
|---|---|
| 既有功能 | 38/38 + 3 萬筆隨機，0 mismatch |
| 新 directed | ≥ 10，全過 |
| 突變 | ≥ 95% |
| 覆蓋率 | ≥ 95% |
| 接受率 | ≥ 0.5 command/cycle |
| Fmax | ≥ 130 MHz（3 seeds 最差） |
| 延遲 | ≤ 14 cycles |
| 資源 | SYMBOLS=2 時 DP16KD ≤ 80 |
| lint | 0 warning |

## 不要做的事

- 不要為了接受率而省略計數器或 stale 檢查
- 不要一次做完三個任務再測
- 不要挑最好的 seed 回報
- 不要把「應該可以」當結果

## 最後回報格式

```
## 任務 A：多商品
- 資源：DP16KD = N
- sym 隔離測試：<結果>

## 任務 B：接受率
- 現況：X cycles / 10,000 筆
- 改後：Y cycles（接受率 Z cmd/cycle）

## 任務 C：Fmax
- seed1 / seed2 / seed3: X / Y / Z MHz
- latency: N cycles

## 量測數字
- Directed: N/M
- Random: ... mismatch
- Mutation: X/Y killed (Z%)
- Coverage: RTL A/B (C%)
- Fmax: worst D MHz
- Latency: E cycles

## 已知限制
- ...

## 檔案清單（新增/修改）
- ...
```

若某項做不到，照實回報數字與原因，不要修飾。
