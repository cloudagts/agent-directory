# CONTROL.md — 境界執行と違反処理

commit・push境界の機械検査、違反の分類と代謝、将来拡張の導入基準を扱うときに読む。
通常のKnowledge・Skill・Project作業では読まず、設定済みhooksの検査を受けるだけなら読込は不要である。

## 目的と非ゴール

目的は、`AGENTS.md`と各正本が定める境界のうち機械判定できるものを、エージェントの自己申告に
依存しない層で実行前に拒否すること。判定の正本（policy）と判定器（verifier）はこのリポジトリ内で
完結し、特定のAIハーネス・モデル・実行環境に依存しない。非ゴール（実装しない）:

- 監査用LLM、常駐daemon、Message Bus、Tool Brokerを通常経路へ入れること
- 数値スコアの通信簿と、それを目的関数としてエージェントへ渡すこと
- Git hookからのbackup、validator、ネットワーク操作の起動（hookは境界検査だけを行い、
  `tools/BACKUP.md`の非ゴールを変更しない）
- validatorの代替。hookは差分境界の最終防壁であり、構造検証はvalidatorが所有する

## 執行の三層

```text
第1層 Policy Canon   tools/control-policy.tsv   何が境界かの機械可読正本
第2層 Verifier       tools/check-boundary.sh    差分をpolicyへ照らす決定的Tool
第3層 Adapter        git hooks ほか             判定を強制する環境側の接続点
```

判定は第1層・第2層だけで完結し、どの環境でも同一である。第3層はverifierを呼ぶ数行に限定し、
判定ロジックをadapterへ複製しない。git hooksの導入は`tools/install-git-hooks.sh`で行う。

### 承認済みsnapshot

hookはworking treeのverifier・policyを実行しない。実行するのは`.git/agent-control/`の
承認済みsnapshotであり、その更新元は**HEADのblob（Gateを通過してcommitされた版）だけ**である。
installerもHEAD blobから導入し、working tree版を導入元にしない。これにより、未stage・未commitの
改変で判定者や判定基準を差し替える迂回は構造的に判定へ入らない。hookは実行時に
`AGENT_DIRECTORY_ROOT`を現在のGit rootへ固定し、verifier自身もrootの食い違いを
`root-mismatch`で拒否する（判定の別リポジトリへの転送を塞ぐ）。

### Independent repositoryへの適用

installerはworkspace rootに加え、materialize済みの全Independent repository
（`projects/<name>/.git/`）へ同じhookとexternal snapshotを導入する。判定pathは
`projects/<name>/`のpath-prefixでworkspace相対へ正規化し、同じpolicyで判定する。
external snapshotはHEAD追従を持たないため、control正本の変更後はworkspace rootで
installerを再実行して配り直す。Independent側はfull validatorを持たないため、下記のreceiptは
適用されず、明示ackだけが要求される（既知の限界）。

### 拘束力の限界

この執行は改ざん検知・拒否であり、絶対拘束ではない。残る迂回経路は次で、いずれも使用自体を
境界違反（制御系違反）として扱う。

- `git commit --no-verify` — pre-commitを飛ばせる。ただしforbidden / frozen違反はpre-pushの
  送信内容再検査で止まる。guarded / contractのack・receiptはcommit時の性質であり、
  push時には再要求しない（ackの常用を要求しない設計）。
- `git push --no-verify` — pre-pushも飛ばせる。remote側の保護（PR必須等）が最後の防壁になる。
- shellによる`.git/`直接操作 — snapshot・receiptは同一OSユーザーのshellからは書換可能である。
  OS権限分離はStrict Mode（導入基準参照）まで導入しない。

`AGENT_GUARDED_COMMIT` / `AGENT_CONTRACT_COMMIT`の常用・自動付与・環境への恒久設定も
境界違反である。唯一の迂回不能な拘束は資格情報の不在である（backup remoteへの書込を
`tools/backup-to-github.sh`だけに置く、remote側でPRとFF-onlyを強制する等）。

## control-policy.tsv

tab区切り3列`tier	pattern	note`。`#`開始行と空行は無視し、上から先勝ちで判定する。
patternはリポジトリ相対pathへのshell globである。

| tier | 意味 |
|---|---|
| `exempt` | 以降の行を適用しない明示的な例外 |
| `forbidden` | 追加を含め、Git追跡・stagingを常に拒否する |
| `frozen` | 追記専用領域。新規追加だけを許し、変更・削除・改名を拒否する |
| `guarded` | meta正本。`AGENT_GUARDED_COMMIT=true`の明示がない変更を拒否する |
| `contract` | Project成果契約。人間の決定事項であり、`AGENT_CONTRACT_COMMIT=true`の明示がない変更を拒否する |

`guarded`集合は、validator `--changed`がfull検査へfallbackするmeta正本集合と一致させる。
片方だけを変更しない。policyの緩和・行削除はそれ自体がguarded変更であり、下記の
エスカレーション条件と`--full`検証を要求する。

## 明示エスカレーション

`AGENT_GUARDED_COMMIT=true`（guarded）と`AGENT_CONTRACT_COMMIT=true`（contract。対応する
人間の決定が先に存在すること）は、該当正本を変更するcommitへの明示的な承認記録であり、
次をすべて満たす1回のcommitだけへ付与する。

- task classが`boundary`、またはmeta Routeのwork/stateであり、`--full`検証を同じ作業内で実行する。
- 変更が依頼範囲内であり、`AGENTS.md#人間へ上げる例外`の4区分に該当しない
  （contractは`方針・契約`の決定が済んでいる場合だけ）。
- validatorやevalを通すことだけを目的にpolicy、採点基準、size budgetを弱める変更を含まない。

ackは自己申告であり、それ単独では通らない。workspace rootでは次の機械的な束縛が加わる。

- **mixed-scope拒否** — guarded / contractの変更と通常の成果を同じcommitへstageしたら、
  ackの有無にかかわらず`mixed-scope`で拒否する。commitを分ける。
- **full検証receipt** — guarded / contractのcommitは、stage済みindex tree（`git write-tree`）へ
  束縛された一回限りのreceiptを要求する。receiptは`--full`validatorがPASS時に
  `.git/agent-control/receipts/<tree>`へ発行し、pre-commitが消費する。手順は
  `stage → bash tools/validate-agent-directory.sh --full → commit`の順とする
  （検証後にstageを変えるとtreeが変わり、receiptは無効になる）。

## 違反の分類

普通の失敗と境界違反を混同しない。失敗は再計画の入力であり、ペナルティの対象ではない。

| 事象 | 分類 | 処理 |
|---|---|---|
| テスト・検証の失敗 | 能力・品質の失敗 | `tools/TOOLS.md#自己修復と停止`で再試行。権限・範囲を縮めない |
| 予算・読込上限への到達 | 運用停止 | 停止して事実を報告する。ペナルティなし |
| forbidden / frozen違反 | 境界違反 | commitを拒否し、違反部分を除いてやり直す |
| ackなしのguarded変更 | 境界違反 | commitを拒否し、classとエスカレーション条件を再判定する |
| 承認なしのcontract変更 | 境界違反 | commitを拒否し、`方針・契約`の決定を人間から先に得る |
| mixed-scope / receipt欠落 | 境界違反 | commitを拒否し、分割または`--full`検証からやり直す |
| verifier・policy・hooksの迂回、弱体化、無効化 | 制御系違反 | 停止し`安全性・衝突`例外として人間へ上げる |

境界違反は違反した操作だけを拒否し、無関係な能力（読込、分析、別領域の作業）を制限しない。
一方向に権限を失い続ける設計を採らず、拒否 → 修正 → 再実行を通常の回復経路とする。

## 違反の代謝

sessionは使い捨てであり、永続する唯一の再発防止は正本へのcommitである。実際に境界違反・
制御系違反が発生したら、同じ作業内で次を完結する。

1. 原因（誤認したtask class、欠けたpolicy行、曖昧な正本記述）を特定する。
2. 原因がpolicy・正本の欠陥なら、該当正本を修正する。
3. 同じ違反を再現するevalケースまたはvalidator fixtureを追加する。
4. `--full`検証の合格後にcommitし、違反・原因・追加した再発防止を報告する。

hookの拒否で実害なく止まった通常の誤操作は、やり直すだけでよく、代謝を要求しない。

## 委譲の境界

通常タスクは単一の推論主体で完結し、既定でサブエージェントへ委譲しない。委譲は次のすべてが
成立する場合だけ行う。

- 作業が独立して並列実行でき、対象が読み取り専用か、書込先が衝突しない。
- 出力を既存の検証方法で確認できる。
- 並列化・隔離・独立評価の利益が、contextの受け渡しと統合のコストを上回る。

委譲の深さは1段まで（子の再委譲を禁止）。同一Git rootのWriterは常に1つであり
（`tools/BACKUP.md#Single Writer`）、子には親が持つ権限の部分集合だけを渡す。

## 導入基準（将来拡張の凍結）

次の機構は現時点で実装しない。導入は場当たりに判断せず、条件成立時に`meta` Routeの
方針判断（`AGENTS.md#人間へ上げる例外`の`方針・契約`）として人間と設計する。

- **Capability State永続化と復権プロトコル** — 外部作用（公開、送信、本番反映、課金）を持つ
  Routineが稼働し、人間が全commitを目視しなくなったとき。
- **Strict Mode（Workspace外のcontrol state、資格情報のController分離、OS権限分離）** —
  本番・金銭・公開の資格情報をWorkspace内のエージェントが扱う必要が生じたとき。
- **ハーネスadapter（Claude Code hooks等の環境固有hook）** — 利用ハーネスが固定され、追加防壁の
  利益が設定の保守コストを上回るとき。adapterは`tools/check-boundary.sh`を呼ぶだけの数行に限定する。

いずれを導入する場合も、判定の正本は第1層・第2層に置いたまま動かさない。
