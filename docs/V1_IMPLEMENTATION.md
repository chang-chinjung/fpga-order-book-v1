# V1.0 實作規格書 — order-by-order 訂單簿

> 對象：實作這個模組的工程師（或 coding agent）。
> 這份文件是「可直接開工」的規格，不是願景。所有介面、狀態、錯誤行為、驗收數字都已定死；
> 沒定的部分標成 TBD，實作者必須先問，不能自己猜。

## 1. 目的與範圍

在 FPGA 上維護一份 **order-by-order**（逐筆訂單）的限價訂單簿：
每個價位有 FIFO 佇列，可以查某張訂單在佇列中的位置，TRADE 從佇列頭端扣量。

**In scope**

- ADD / CANCEL / REDUCE / TRADE（單一價位）
- 每價位時間優先 FIFO
- order_id 查詢（存在、價位、剩餘量、佇列位置）
- 最佳買賣價與其數量
- 資源計數器（事件數、錯誤數）

**Out of scope（留給 v1.1）**

- AXI4-Stream 介面（v1.0 用簡單 valid/ready）
- seq gap 偵測、snapshot 重載
- 多商品
- 跨多價位的 TRADE（一筆吃多檔）
- bitmap 最佳價整合（v1.0 可用簡單掃描或既有 bitmap 模組）

## 2. 參數

| 參數 | 預設 | 說明 |
|---|---|---|
| `LEVELS` | 1024 | 價位數（tick 階梯） |
| `MAX_ORDERS` | 8192 | 同時存在的訂單上限 |
| `QTY_W` | 16 | 數量寬度 |
| `OID_W` | 16 | order_id 寬度 |
| `LW` | 10 | level 索引寬度（$clog2(LEVELS)） |
| `OW` | 13 | order slot 索引寬度（$clog2(MAX_ORDERS)） |

## 3. 介面

### 3.1 命令介面（單一時脈）

| 訊號 | 方向 | 寬度 | 說明 |
|---|---|---|---|
| `cmd_valid` | in | 1 | 命令有效 |
| `cmd_ready` | out | 1 | 模組可接受命令；低態時上游必須保留 |
| `cmd_op` | in | 2 | 0=ADD, 1=CANCEL, 2=REDUCE, 3=TRADE |
| `cmd_side` | in | 1 | 0=bid, 1=ask（TRADE 用它選邊） |
| `cmd_oid` | in | OID_W | 訂單編號（TRADE 忽略，可為 0） |
| `cmd_level` | in | LW | 價位索引（TRADE 必填） |
| `cmd_qty` | in | QTY_W | 數量；0 視為非法 |

### 3.2 查詢介面（唯讀）

| 訊號 | 方向 | 寬度 | 說明 |
|---|---|---|---|
| `qry_valid` | in | 1 | 發起查詢 |
| `qry_ready` | out | 1 | 接受查詢 |
| `qry_oid` | in | OID_W | 要查的訂單 |
| `qry_found` | out | 1 | 存在且有效 |
| `qry_level` | out | LW | 所在價位 |
| `qry_qty` | out | QTY_W | 剩餘量 |
| `qry_pos` | out | 6 | 佇列位置（前面有幾張），**上限 63** |

查詢延遲 ≤ 4 cycles；查詢與命令可同時進行，但同一 cycle 的衝突以命令優先（`qry_ready` 拉低）。

### 3.3 輸出

| 訊號 | 寬度 | 說明 |
|---|---|---|
| `bid_valid` | 1 | 有買方價位 |
| `best_bid` | LW | 最高非空買價位 |
| `best_bid_qty` | QTY_W | 該價位總量 |
| `ask_valid` / `best_ask` / `best_ask_qty` | 同上 | 最低非空賣價位 |

### 3.4 計數器（AXI-Lite 或簡單暫存器輸出，v1.0 用後者）

`cnt_add, cnt_cancel, cnt_reduce, cnt_trade, cnt_drop_dup, cnt_drop_unknown, cnt_drop_full`

## 4. 狀態與資料結構

### 4.1 Order store（MAX_ORDERS 筆）

| 欄位 | 寬度 | 說明 |
|---|---|---|
| `o_qty` | QTY_W | 剩餘量 |
| `o_level` | LW | 價位 |
| `o_side` | 1 | 買/賣 |
| `o_prev` | OW | 同價位前一張（頭端為 INVALID） |
| `o_next` | OW | 同價位下一張（尾端為 INVALID） |
| `o_valid` | 1 | 佔用 |

**映射**：order_id 直接映射到 slot（`slot = oid[OW-1:0]`），假設上游已把 id 壓到範圍內。
若 `oid >= MAX_ORDERS`，視為非法 → 丟棄並計數。

### 4.2 Price ladder（LEVELS 筆）

| 欄位 | 寬度 | 說明 |
|---|---|---|
| `l_qty` | QTY_W | 該價位總量 |
| `l_count` | OW | 該價位訂單數 |
| `l_head` | OW | FIFO 頭 |
| `l_tail` | OW | FIFO 尾 |

### 4.3 最佳價

v1.0 可用「掃描」或直接實例化既有的 `bitmap_best`（1,024 級已驗證）。
若用 bitmap，`upd_set = (l_qty != 0)`，只在 0↔非 0 轉換時更新。

## 5. 命令語意

| 命令 | 前置條件 | 行為 | 失敗時 |
|---|---|---|---|
| **ADD** | slot 未被佔用、qty>0 | 寫 order（qty、level、side、valid）；接到該價位 FIFO 尾端；`l_qty += qty`；`l_count++` | slot 已佔用 → `cnt_drop_dup++`，丟棄 |
| **CANCEL** | slot 有效 | 從 FIFO 移除該張；`l_qty -= qty`；`l_count--`；清 valid | slot 無效 → `cnt_drop_unknown++` |
| **REDUCE** | slot 有效、qty ≤ 剩餘 | 只減 `o_qty` 與 `l_qty`；若減到 0 則同 CANCEL | qty > 剩餘 → 飽和到 0（整張移除），計數 `cnt_sat++` |
| **TRADE** | `cmd_side` 指定的那一邊在該價位非空 | 從該邊 **FIFO 頭端**逐張扣量，直到扣完或價位空；可跨多張訂單，但**不跨價位**；另一邊完全不動 | 指定邊為空 → 丟棄，計數 |

**TRADE 的執行方式**：v1.0 允許 TRADE 佔用多個 cycle。進入 TRADE 後 `cmd_ready` 拉低，
內部以 FSM 逐張扣除，完成後恢復。最長 N 個 cycle（N = 被吃掉的訂單數）。

**FIFO 不變量**

- `l_head`/`l_tail` 為 INVALID 時，`l_count == 0` 且 `l_qty == 0`
- `o_prev`/`o_next` 必須對稱
- 佇列長度必須等於 `l_count`

## 6. 危障處理

| 危障 | 處理 |
|---|---|
| 連續兩筆命令打到同一價位 | **stall**：`cmd_ready` 拉低一個 cycle（forwarding 留給 v1.1） |
| ADD 後立刻 CANCEL 同一 oid | 同上，stall |
| TRADE 期間收到新命令 | `cmd_ready` 持續拉低，直到 TRADE 完成 |
| 查詢與寫入同 slot | 命令優先，查詢回 `qry_ready=0` 重試 |

## 7. 錯誤與邊界

| 情況 | 行為 |
|---|---|
| `cmd_qty == 0` | 丟棄，`cnt_drop_bad++`（新增計數器） |
| `cmd_level >= LEVELS` | 不可能（寬度已限制） |
| `oid >= MAX_ORDERS` | 丟棄，`cnt_drop_bad++` |
| ADD 時 order store 已滿 | 丟棄，`cnt_drop_full++` |
| 重置 | `rst_n` 非同步低態；清所有儲存與計數器 |

## 8. 檔案佈局（實作者必須遵守）

```
rtl/order_book_v1.sv        主模組（唯一的 top）
rtl/order_store.sv          訂單儲存 + FIFO 指標（可選拆分）
rtl/price_ladder.sv         價位聚合（可選拆分）
model/book_v1_model.py      Python golden model + 刺激產生器
tb/tb_order_book_v1.sv      testbench（讀 stim/exp，逐筆比對）
docs/V1_IMPLEMENTATION.md   本文件
```

## 9. 測試計畫

### 9.1 Directed（至少 20 個）

1. 空簿查詢
2. ADD → 查詢（level、qty、pos=0）
3. 同價位 ADD 三張 → pos 0/1/2
4. 中間取消 → 後續 pos 遞減
5. TRADE 部分成交（跨兩張）
6. TRADE 完全吃掉價位 → 該價位消失
7. REDUCE 到 0 → 同取消
8. REDUCE 超過剩餘 → 飽和
9. 重複 oid ADD → 丟棄
10. 未知 oid CANCEL → 丟棄
11. 滿載時 ADD → 丟棄
12. best bid/ask 在價位出現/消失時正確
13. 連續命令打同一價位 → stall 後仍正確
14. TRADE 期間的命令必須等待
15. 邊界 level 0 與 LEVELS-1
16. qty = 1 的極端案例
17. 查詢不存在訂單
18. 重置後狀態乾淨
19. 兩個價位交錯 ADD/CANCEL
20. FIFO 順序驗證（先進先出）

### 9.2 隨機

- 10,000 筆隨機命令（ADD 50%、CANCEL 20%、REDUCE 15%、TRADE 15%）
- 與 Python golden model 逐筆比對：best bid/ask、qty、查詢結果、計數器

### 9.3 突變測試

- ≥ 30 個 mutant，score ≥ 90%
- 必須包含：FIFO 指標、count、qty 加減、TRADE 迴圈、stall 條件

### 9.4 覆蓋率

- RTL 行覆蓋率 ≥ 95%

### 9.5 時序

- Yosys + nextpnr ECP5 85F，Fmax ≥ 100 MHz
- 延遲：命令進到 best price 更新 ≤ 10 cycles

## 10. 驗收標準（缺一不可）

| # | 項目 | 門檻 |
|---|---|---|
| 1 | Directed 測試 | 全過 |
| 2 | 隨機對拍 | 10,000 筆 0 mismatch |
| 3 | 突變分數 | ≥ 90% |
| 4 | RTL 覆蓋率 | ≥ 95% |
| 5 | Fmax | ≥ 100 MHz（ECP5） |
| 6 | 延遲 | ≤ 10 cycles |
| 7 | lint | 0 warning（Verilator -Wall） |

## 11. 實作順序（建議）

1. 資料結構 + ADD（先不接 FIFO，只做聚合）
2. FIFO 指標 + CANCEL
3. REDUCE + 飽和
4. TRADE（含多 cycle FSM）
5. 查詢 + queue position
6. best price + bitmap
7. stall/危障
8. Python model + TB + 突變

**每一步都要先讓對拍通過，再做下一步。** 不要在沒有測試的情況下累積功能。

## 12. 非目標（不要做）

- 不要發明新的介面（照 §3）
- 不要做 AXI-Stream、seq gap、snapshot（v1.1）
- 不要最佳化到 300 MHz（ECP5 做不到）
- 不要修改 `fpga/order-book/` 底下既有的 v0.1 檔案；新工作放在 `fpga/order-book-v1/`
