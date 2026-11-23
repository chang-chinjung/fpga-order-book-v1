# V1.1 驗證紀錄（2026-11-23，lead 重跑）

> 由 lead（DSH）實際重跑，不是轉述 AGY 的回報。

## 最終數字

| 項目 | 目標 | 實測 | 判定 |
|---|---|---|---|
| `make lint` | 0 warning | 0 warning | ✅ |
| Directed | 27 legacy + ≥8 | **38/38**（27 + 11） | ✅ |
| Random | 10k legacy + 10k AXIS + 2k gap | 全部 0 mismatch | ✅ |
| 突變 | ≥ 95% | **42 killed / 1 equivalent / 0 survived = 100%** | ✅ |
| RTL 覆蓋率 | ≥ 95% | **583/598 = 97.5%** | ✅ |
| Fmax（3 seeds） | 全部 ≥ 120 MHz | **123.69 / 122.19 / 128.44 MHz**（最差 122.19） | ✅ |
| 延遲 | ≤ 12 cycles | **12 cycles** | ✅ |

## 我抓到的問題：AGY 回報的突變 100% 不成立

AGY 回報「42/42 killed（100%）」。我重跑第一次得到：

```
killed 41 / survived 1 / equivalent 1 → 97.6%
survivor: hazard_cmd_priority_disabled
```

我手動套用該 mutant 重跑整套測試，**全過**——測試真的抓不到。

### 根因

mutant 把 `cmd_busy` 固定為 0。正確行為是：**多 cycle 的 TRADE 進行中，查詢必須等待**。
原本的 D22 是「命令與查詢同時發出」，但兩者查**同一個 oid**，位址相同，碰撞不會產生錯誤資料。

### 修正

- 先加 **D37**（命令 oid A + 查詢 oid B，不同位址）→ 仍然抓不到
- 再加 **D38**（TRADE 進行中查詢另一個 oid）→ **抓到**

```
FAIL [D38 qry qty]: got=5 exp=77
FAIL [D38 qry level]: got=300 exp=400
```

mutant 讓查詢在 TRADE 期間就回傳，拿到的是 TRADE 正在讀的訂單資料，而不是查詢目標。

補上 D38 後：**42 killed / 1 equivalent / 0 survived = 100%**。

## 仍存在的限制

1. **Fmax 餘裕約 2%**（最差 122.19 vs 門檻 120）。比 v1.0 的 0.01% 好很多，但仍不寬裕。
2. **P&R 使用 CABGA756 封裝**（頂層 298 pins，含 13 組 counter 多工）。若目標板是 CABGA381 需確認腳位。
3. **reset 需 8,192 cycles**（約 67 µs @122 MHz）清 BRAM。
4. **`qry_pos` 是 O(pos)**，最深 63 步。

## 結論

v1.1 的七項驗收全部通過，且突變 100% 是我重跑確認的（不是採信回報）。
唯一需要留意的是時序餘裕與封裝腳位，不是功能正確性。
