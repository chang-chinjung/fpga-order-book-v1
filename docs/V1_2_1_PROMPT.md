# AGY 任務 Prompt — v1.2.1 時序修正

以下整段直接貼給 Antigravity CLI。

---

## 你的任務

在 `D:\stock_program\daytrade\AI當沖-GPT1\fpga\order-book-v1\` 做 **v1.2.1：時序修正**。

**第一件事：讀 `docs/V1_2_1_IMPLEMENTATION.md`（同資料夾）。**

## 現況（v1.2 功能全過，只有時序沒過）

| 項目 | 數字 |
|---|---|
| Directed | 48/48 |
| Random | 34,000 steps，0 mismatch |
| 接受率 | 0.500 cmd/cycle |
| 突變 | 49 killed / 1 equivalent / 0 survived = 100% |
| 覆蓋率 | 846/884 = 95.7% |
| 資源 | 76 DP16KD / 14,207 LUT4 |
| 延遲 | 14 cycles |
| **Fmax** | **107.30 / 111.64 / 122.10 MHz（門檻 130，未達）** |

**開工前先跑 `make sim` 確認 48/48 與 34k 隨機全過。**

## 根因（你自己量的，照這個方向修）

邏輯延遲已壓到 1.7–2.1 ns；瓶頸是 **76 個 DP16KD 跨 BRAM row 走線 6.0–6.6 ns**。
單商品（39 BRAM）可以到 122 MHz，雙商品（76 BRAM）掉到 107 MHz。

## 任務

1. 找出最長路徑（哪條 net、跨幾個 row）
2. **在該路徑加一級暫存**（候選：ladder 寫回、shadow 寫入、best-price 輸出、ord_rd_addr 選擇）
3. 每加一級就重跑：`make sim`、接受率、`make mutate`
4. 目標：**3 個 seed 最差 ≥ 130 MHz**，延遲 **≤ 16 cycles**

## 不可變（回退就視為失敗）

- 語意：TRADE 選邊、seq gap、snapshot、多商品隔離
- 既有 48 個 directed 的預期值
- 接受率 ≥ 0.5 cmd/cycle
- 突變 ≥ 95%
- 覆蓋率 ≥ 95%
- BRAM ≤ 80

## 驗收

| 項目 | 門檻 |
|---|---|
| 48 directed + 34k 隨機 | 全過 |
| 接受率 | ≥ 0.5 cmd/cycle |
| 突變 | ≥ 95% |
| 覆蓋率 | ≥ 95% |
| **Fmax** | **≥ 130 MHz（3 seeds 最差）** |
| 延遲 | ≤ 16 cycles |
| 資源 | DP16KD ≤ 80 |
| lint | 0 warning |

## 若 130 仍達不到

照實回報：三個 seed 的數字、加了幾級、每級切在哪、剩下最長路徑是什麼。
**不要**為了達標而降低測試強度或改語意。

## 回報格式

```
## 改了什麼
- <第 1 級切在...>：Fmax 從 A → B
- <第 2 級切在...>：Fmax 從 B → C

## 量測
- Fmax: seed1 / seed2 / seed3 = X / Y / Z（worst = W）
- Latency: N cycles
- Acceptance: X.XXX cmd/cycle
- Directed: N/M
- Random: 34,000，K mismatch
- Mutation: X/Y killed (Z%)
- Coverage: RTL A/B (C%)
- BRAM: N

## 已知限制
- ...
```
