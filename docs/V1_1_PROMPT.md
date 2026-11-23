# AGY 任務 Prompt — v1.1（Fmax 120 MHz + AXI-Stream + seq gap + snapshot）

以下整段（從「你的任務」到最後）直接貼給 Antigravity CLI。

---

## 你的任務

在 `D:\stock_program\daytrade\AI當沖-GPT1\fpga\order-book-v1\` 繼續開發 **v1.1**。

**第一件事：讀 `docs/V1_1_IMPLEMENTATION.md`（同資料夾）。**
那是 v1.1 的規格書：介面、欄位、seq gap 規則、snapshot 格式、驗收門檻都已定死。
本 prompt 只補充流程與邊界；衝突時以規格書為準。

## 現況（v1.0 已驗證，不要破壞）

| 項目 | 數字 |
|---|---|
| Directed | 27/27 |
| Random | 10,000 steps，0 mismatch |
| 突變 | 34 killed / 1 equivalent / 0 survived = 100% |
| RTL 覆蓋率 | 411/419 = 98.1% |
| Fmax | 100.01 MHz（ECP5 85F，nextpnr） |
| 延遲 | 10 cycles |
| lint | 0 warning |

**開工前先跑一次 `make sim`，確認 27/27 與 10,000 筆都過。** 如果不過，先停在這裡回報，不要繼續。
**TRADE 的 `cmd_side` 選邊語意已實作並有 D27 覆蓋，不要改回舊行為。**

## 工作邊界

1. 只能修改 `fpga/order-book-v1/` 底下的檔案。
2. 不要動 `fpga/order-book/`（v0.1）、`_backtest/`、`data/`、`sim/`、`.env`、`.pylibs/`。
3. 不要 git commit / push。
4. 不要安裝新套件。

## 兩個任務（依序）

### 任務 A：Fmax ≥ 120 MHz

- 現況 100.01 MHz，餘裕 0.01%，不可接受
- 允許加一級暫存、拆 ladder 讀取、提前算加減法、降低 best-price 樹深度
- **不可改變語意**：27 個 directed 與 10,000 筆隨機必須全過
- 延遲放寬到 ≤ 12 cycles（多一級可以），但要如實更新 tb 與 README
- 驗收：`nextpnr-ecp5` 量到 ≥ 120 MHz，**至少 3 個 placement seed 都要過**

### 任務 B：seq gap → snapshot → AXI-Stream（照這個順序）

1. **seq gap**：16-bit seq、跳號設 stale、重複不設 stale、計數器
2. **snapshot**：HEADER/LEVEL/ORDER/FOOTER、載入期間丟命令、count 不一致報錯
3. **AXI4-Stream**：64-bit 命令 slave、best-price master、由 `USE_AXIS` 參數切換

每個子任務都要先補 directed 測試，再做下一個。

## 測試要求

| 項目 | 要求 |
|---|---|
| 既有 directed | 27 個，全過（不得修改預期值來遷就新實作） |
| 新增 directed | ≥ 8 個（AXIS 握手、seq 跳號/重複、snapshot 空簿/多價位/載入中命令/count 不一致） |
| 隨機 | 10,000 筆 AXI-Stream 正常 seq + 2,000 筆含 5% 跳號/重複 |
| 突變 | ≥ 95%，且必須涵蓋 seq 比較、stale 鎖定、snapshot 清空、FIFO append |
| 覆蓋率 | RTL ≥ 95% |
| lint | 0 warning |

## 驗收（缺一不可，最後回報）

| 項目 | 門檻 |
|---|---|
| 既有功能 | 27/27 + 10,000 筆，0 mismatch |
| 新 directed | ≥ 8，全過 |
| 突變 | ≥ 95% |
| 覆蓋率 | ≥ 95% |
| Fmax | ≥ 120 MHz（3 seeds） |
| 延遲 | ≤ 12 cycles |
| lint | 0 warning |

## 不要做的事

- 不要為了 Fmax 而改變語意（例如省略 counter、跳過 stale 檢查）
- 不要放寬既有測試的預期值
- 不要用 `-Wno-fatal` 當成 lint 通過
- 不要一次做完三個功能再測
- 不要回報沒實際跑過的數字

## 最後回報格式

```
## 任務 A：Fmax
- seed1: X MHz, seed2: Y MHz, seed3: Z MHz
- latency: N cycles
- 改了什麼（一兩句）

## 任務 B
- seq gap: <測試結果>
- snapshot: <測試結果>
- AXI-Stream: <測試結果>

## 量測數字
- Directed: N/M
- Random: 10,000 + 2,000 steps, K mismatch
- Mutation: X/Y killed (Z%)
- Coverage: RTL A/B (C%)
- Fmax: D MHz (worst of 3 seeds)
- Latency: E cycles

## 已知限制
- ...

## 檔案清單（新增/修改）
- ...
```

若某項做不到（例如 3 個 seed 只有 2 個過 120 MHz），**照實回報是哪個 seed、差多少**，不要挑最好的報。
