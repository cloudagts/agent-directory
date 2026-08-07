---
name: pricing-review
description: 見積もり・価格表の改定幅が現在有効な価格方針に沿っているかを検査する再利用可能なレビュー手順。
status: active
aliases: [価格レビュー, pricing review]
---

# `pricing-review` — 価格改定のレビュー

## 発動条件

- 利用者が「`pricing-review`を使って」と明示したとき
- 見積もりや価格表の改定幅を方針と照合したいとき

## 目的

対象文書の改定幅を現在有効な価格方針と照合し、逸脱を根拠付きで報告する。

## 使用するKnowledge

### Required

- `knowledge/wiki/topics/pricing-policy.md`

### Conditional

- 条件: 方針の根拠となる原記録の正確な文言が必要
  参照: `knowledge/raw/internal/2026-08-01-pricing-decision.md`

## 手順

1. `knowledge/wiki/topics/pricing-policy.md`で現在有効な改定幅（標準5%）を確認する。
2. 対象文書の改定幅を抽出し、方針の値と比較する。
3. 逸脱があれば、対象の位置と方針の根拠を対で報告する。
4. 中間ファイルは`.tmp/`に置き、完了時に片付ける。

## 出力契約

```text
## 照合結果
| 対象 | 改定幅 | 方針値 | 判定 |

## 逸脱の根拠
- <対象の位置>: <方針の根拠>
```

## 禁止事項

- この`SKILL.md`を読まずに実行しない。
- 方針値を本手順の記憶だけで判断せず、必ずRequired Knowledgeを読む。
- 秘密情報を出力・保存しない。
- `.tmp/`以外に中間ファイルを残さない。
