# AGY 任務 Prompt — 實作 FPGA order-by-order 訂單簿 v1.0

以下整段（從「你的任務」到最後）直接貼給 Antigravity CLI。

---

## 你的任務

在 `D:\stock_program\daytrade\AI當沖-GPT1\fpga\order-book-v1\` 這個資料夾裡，
實作一個可合成、可驗證的 **order-by-order 限價訂單簿**（SystemVerilog）。

**第一件事：讀 `docs/V1_IMPLEMENTATION.md`（就在同一個資料夾）。**
那份文件是規格書，介面、語意、錯誤行為、測試與驗收門檻都已定死。
本 prompt 只補充流程與邊界，不重複規格內容。兩者衝突時，以規格書為準。

## 工作邊界（嚴格遵守）

1. **只能修改 `fpga/order-book-v1/` 底下的檔案。**
   - 不要動 `fpga/order-book/`（那是已發布的 v0.1，有 git 歷史）
   - 不要動 `_backtest/`、`data/`、`sim/`、`tw_ai_intraday_trader.py`
   - 不要動 `.env`、`.pylibs/`
2. 不要 git commit、不要 push、不要改任何 remote。
3. 不要安裝新的系統套件；先確認現有工具能不能用。

## 環境

- Windows；可用 WSL 跑 Verilator（`wsl -e bash -lc '...'`）
- Verilator ≥ 5.0、Python 3.12、Yosys、nextpnr-ecp5 已可用
- 參考 `fpga/order-book/Makefile` 的寫法（sim / coverage / mutate / pnr），
  但**複製一份到新資料夾**，不要改原本那份
- 有 `verilator-sim` skill 可用時，先載入它

## 交付物

```
rtl/order_book_v1.sv          主模組（top 只能是這個）
rtl/*.sv                      需要時才拆分（order store / ladder 等）
model/book_v1_model.py        Python golden model + 刺激/期望值產生器
tb/tb_order_book_v1.sv        testbench
tools/mutate_v1.py            突變測試腳本
Makefile                      lint / sim / coverage / mutate / pnr
README.md                     如何跑、量到什麼數字、已知限制
docs/V1_IMPLEMENTATION.md     規格書（只讀，不要改）
```

## 工作方法（重要）

**一次只做一個里程碑，每個里程碑都要先通過測試，再做下一個。**

1. 資料結構 + ADD（先只做聚合，不接 FIFO）
2. 同價位 FIFO + CANCEL
3. REDUCE + 飽和
4. TRADE（多 cycle FSM）
5. 查詢 + queue position
6. best price
7. stall / 危障
8. 突變測試 + 覆蓋率

每個里程碑結束時：
- `make lint`：0 warning
- `make sim`：該里程碑的 directed 測試全過
- 失敗就修，不要跳過、不要用 `-Wno-fatal` 當成通過

## 驗收（缺一不可，最後回報）

| 項目 | 門檻 |
|---|---|
| Directed | ≥ 20 個，全過 |
| 隨機對拍 | 10,000 筆，0 mismatch |
| 突變分數 | ≥ 90% |
| RTL 行覆蓋率 | ≥ 95% |
| Fmax（ECP5 85F，nextpnr） | ≥ 100 MHz |
| 延遲（命令 → best price 更新） | ≤ 10 cycles |
| lint | 0 warning |

## 不要做的事

- 不要發明新介面（照規格書 §3）
- 不要做 AXI-Stream、seq gap、snapshot（那是 v1.1）
- 不要為了讓測試變綠而改語意
- 不要一次寫完 2,000 行再開始測
- 不要聲稱「應該可以」而沒有實際跑過

## 最後回報格式

```
## 完成項目
- <里程碑>：<測試結果>

## 量測數字
- Directed: N passed
- Random: 10000 steps, 0 mismatch
- Mutation: X/Y killed (Z%)
- Coverage: RTL A/B (C%)
- Fmax: D MHz
- Latency: E cycles

## 已知限制
- ...

## 檔案清單
- rtl/...
- tb/...
- model/...
- tools/...
```

如果某個驗收項目做不到（例如 Fmax 不到 100 MHz），**照實回報數字與原因**，不要修飾。
