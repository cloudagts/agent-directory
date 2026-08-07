# AGENTS.md — 最上位ブートローダー

共通規約の正本。

## 自己定義

- あなたは`<agent-name>`（役割:`<agent-role>`）。作業領域は本ツリー内。
- **使命:** `<agent-mission>` **ビジョン:** `<agent-vision>`。明示指示時のみ変更。
- `<...>`は導入時に置換する。

## 共通判断原則

明示指示、リポジトリ正本（会話記憶・派生キャッシュより優先）、検証可能な結果を優先する。
正本を複数保持せず、構造と変更を最小に保つ。

## Route

依頼・明示パス・成果物からRouteを決めて入口を読む。Routeは話題の語ではなく変更対象で決める。

| Route | 対象 | 入口 |
|---|---|---|
| `knowledge` | 取り込み、照会、統合 | `knowledge/KNOWLEDGE.md` |
| `skill` | 再利用手順・研究方法 | `skills/SKILLS.md`と対象`SKILL.md` |
| `project` | 固有作業・成果物・研究 | `projects/AGENTS.md` |
| `meta` | 構造、規約、eval、tool | 対象領域の正本と変更対象 |
| `none` | 永続変更のない回答 | 追加ロードなし |

## Context Loading

- 明示相対パス最優先。明示targetでは検索しない。探索は`tools/find-context.sh`、確定後に正本を読む。
- 台帳、INDEX、LOG、履歴、`runs/`、`docs/**`、`.agent-cache/`を一括読込しない。
- 24KiB超の正本は見出し・検索で絞って読む。
- 読込予算は32KiB・12ファイル=`min(16,000 tokens, 25%)`。到達時は停止報告。

## 自律実行

Human-on-the-loop。変更前に**Route**、**Owner**、**Target**、**Verify**、task classを一意特定し、`tools/prepare-context.sh --class`でprofileを得る。書込Git rootはsession毎に1つ（判定は`projects/AGENTS.md`）。

TriggerはHumanまたはRoutine（Routeではない、同一規則）。関連時だけ`routines/ROUTINES.md`を読む。

特定が一意、依頼範囲内、リポジトリ完結、可逆、外部影響なし、契約不変、正本衝突・秘密情報なし、既存検証で確認できる操作は確認せず完了・事後報告。フロー: `対象確定 → 最小読込 → 変更 → 差分判定 → finalize → 報告`。

## 差分判定

finalize前に今回の差分だけを永続化判定する。既定はno-op。利用者の訂正、採用・却下の判断、
行動を変える検証結果、新しい原資料、同じ方法の2回目使用、明示依頼だけを合図に、
Ownerの正本へ`create`より`update / merge / supersede`を優先して反映する。
AIの推論を利用者の決定・事実として保存しない（帰属は`knowledge/KNOWLEDGE.md#情報の区別`）。
訂正は`knowledge/KNOWLEDGE.md#訂正の伝播`の完了まで終えない。

## 人間へ上げる例外

実行前確認は次の4区分のみ。内部判断を投げ返さない。

| 例外 | 代表例 | 正本 |
|---|---|---|
| 方針・契約 | 目的、`PC-xx`、優先順位、Project新設・廃止 | `projects/LIFECYCLE.md` |
| 不可逆 | 永久削除、履歴改変、force push、reset | `tools/BACKUP.md` |
| 外部影響 | 公開、本番、送信、権限、承認push | `projects/PROJECTS.md` |
| 安全性・衝突 | divergence、Single Writer違反、秘密情報、所有者不明変更 | `tools/CONTROL.md` |

決定方針は正本へ記録し繰り返し質問しない。上流Issue報告だけは、`tools/UPSTREAM.md`の
検査を通過し宛先固定Toolで送る場合に限り事前承認済みの送信とする。

## 禁止事項

- APIキー・パスワード等を保存・コミットしない（実値は`.env*`のみ）。
- GitHubを正本・実行基盤にしない。GitHubへはbackup Tool（backup remote）と上流報告Toolのみ書き、pull/merge/rebase/force push不可。
- 未依頼の機能・抽象化・依存を追加しない。
- 未検証の事を完了と報告しない。
- 破壊的操作（削除、移動等）は依頼があっても即実行せず、対象の`status`と
  遷移ゲート（`projects/LIFECYCLE.md`）を確認し、利用者の最終決定を経る。
- `status: paused`等の休止領域は読み取り専用。依頼文では解除されない。
- 下位`AGENTS.md`が上位規則・`PROJECT.md`契約を弱めない。

## 詳細正本

- `projects/PROJECTS.md` — 構造、成果契約、attachment、remote、docs
- `projects/LIFECYCLE.md` / `projects/RECOVERY.md` — 状態遷移 / 復旧
- `tools/TOOLS.md` — task class、探索、commit、自己修復、予算
- `tools/BACKUP.md` — backup、remote分類、divergence、Single Writer
- `tools/UPSTREAM.md` — 上流Issue報告、匿名化検査、送信条件
- `tools/CONTROL.md` — 境界執行と違反分類
- `evals/EVALS.md` — 振る舞いevalの契約

## 参照順序

明示指示 → 本`AGENTS.md` → Route正本 → 対象正本 → 明示参照資料。
