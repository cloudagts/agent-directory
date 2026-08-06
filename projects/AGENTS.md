# projects/AGENTS.md — Project作業の入口

詳細は`projects/PROJECTS.md`が所有する。

## 着手

1. 対象を一つに確定する（明示パスがなければ`tools/find-context.sh --route project`）。
   明示依頼なく新設しない。
2. 作業cwdは`projects/<name>/`。classを決め`tools/prepare-context.sh --class`で
   Git所有境界とprofileを得る。
3. `AGENTS.md`（あれば）→`PROJECT.md`全文→`STATE.md`の順に読み、対象契約
   （`#PC-xx`か`#status`）と合格条件を特定。
4. 成立したDocs Route条件の正本とRequired参照だけを読む。

## Git所有境界

- toplevel=Workspace rootならEmbedded（root Gitへcommit）、`projects/<name>/`自身なら
  Independent（Project固有Gitへcommit）。
- 解決不能時だけ`projects/REPOSITORIES.md`を読みmaterializeへ進む。
- 書込は常に`projects/<name>/**`。本体sessionはregistryを、root sessionは本体を書かない。

## 実行と完了

- 成果契約の範囲で最小かつ完全に変更。契約自体の変更は`projects/LIFECYCLE.md#人間が決める遷移`。
- `PROJECT.md`の検証を実行。未実行を合格扱いしない。
- 状態変化と同じ作業内で`STATE.md`を更新。
- 検証合格後はscoped commitまで確認なしで完結し、結果、証拠、commit、未完了を区別して
  事後報告（`tools/TOOLS.md#自律実行の標準完了`）。

## PROJECTS.mdを読む条件

新設、状態遷移、契約種別変更、Independent昇格・移行、remote操作、docs構造、
個別`AGENTS.md`、復旧、規約保守、明示参照。
