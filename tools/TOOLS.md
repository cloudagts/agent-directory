# TOOLS.md — 構造保守と限定取得

`tools/`は利用者の成果を作るSkillではなく、このAgent Workspace自体を保守するmeta層である。
固定Toolは`#Tool一覧`の登録だけとし、依存関係を増やさず、入出力、fallback、検証方法を
Tool個別契約の所有正本へ明記する。
macOS標準のbash 3.2を最低条件とし、GNU専用option、associative array、`mapfile`を
使わずBSD `find`と`sed`で動かす。`set -u`下の空配列は件数で守ってから展開する。変更時は
`/bin/bash tools/*.sh`とvalidator隔離fixture（実GitHub接続なしのbare remote）で検証し、
`shellcheck`があれば併用する（必須依存にしない）。

責務は次で固定する。Toolへ判断を持たせず、Agentへ決定的操作を再実装させない。

```text
Tool  = 決定的な操作を安全に実行する
Agent = いつ実行するかを規約に従って判断し、検証と記録まで完結する
Human = 例外と方針変更を決定する
```

## 正本と派生物

Markdown、原資料、Project入出力、eval、Toolコードが正本である。`.agent-cache/`はGit管理外の派生物で、
削除して正本から再生成できる。cacheだけに情報を保存せず、恒久参照先にもGit追跡対象にもしない。

## 相互参照

恒久参照は`<repository-relative-path>#<target>`（見出しまたはfrontmatter key）を使い、
行番号を使わない。同じProject内でも対象ファイル名を省略しない。

## 一時作業と固定化

- 一時コードと中間ファイルは`.tmp/`に置き、正式処理から参照せず、完了時に削除する。
- 2回目に使う不安定なコードは所有先の`candidates/`へ、3回目の前に固定化を判断する。
- 固定コードはProjectまたはSkillの`scripts/`、構造保守はこの`tools/`が所有し、実行・検証方法を持つ。
- 外部共有、本番、金銭、権限、機密へ影響する処理は初回から固定コード相当の品質を要求する。
- 全件監査でも同時入力せず、バッチで検査して`.tmp/`の集約結果と必要な正本だけを次段階へ渡す。

## 自律実行の標準完了

work/stateの終端は`tools/finalize-task.sh`の1回で検証・commit・backupまで完結させ、可否を質問しない。次をすべて満たすとき自動commitする。

- 依頼範囲内の変更であり、変更対象のOwnerが明確である。
- 必須検証が合格している（未検証・不合格を完了commitとして扱わない）。
- 秘密情報を含まず、unrelated changeを混ぜていない。
- 作業ツリーから自分の変更を安全に分離できる（書込Git rootはsession毎に1つ）。
- commitが意味的に一つの作業単位である。

hooks導入済み環境では、commit・push境界を`tools/check-boundary.sh`が機械検査する（正本は
`tools/CONTROL.md`。guarded正本の変更は明示エスカレーションと`--full`検証を要する）。

commit messageは変更内容と理由が分かる一文を先頭に置く。中断時は残件を明記した
checkpoint commitを作ってよいが、完了報告にも成果契約の達成にもしない。commit後は`tools/BACKUP.md`の
triggerとpolicyが許す場合だけbackupまたは通常pushへ進む。

次のいずれかでは自動commitせず停止し、`AGENTS.md#人間へ上げる例外`として報告する。

- 秘密情報を含む、または所有者不明の変更と安全に分離できない。
- 同じ行や成果物で別sessionと競合している。
- 不可逆操作を前提とする、または成果契約の変更を含む。
- 何を正本とするか決定できない。

## 自己修復と停止

安全で可逆な内部エラーは利用者へ判断を返さず、原因を調査して自律修正し再検証する。対象は
サイズ超過、参照切れ、lint/format失敗、stale cache、validatorが示した構造違反、再生成漏れ、
Toolへの決定的な入力不備、自分の変更が壊したtestである。

検証は終端の1回に集約する。変更の途中でvalidatorを反復実行せず、編集直後の確認は対象の最小検査
（構文、lint、対象test）に限る。finalize検証の失敗後の再finalizeは1回まで。2回目の失敗は停止し、
事実・試行・推奨判断を報告する。その他の内部エラーへの修正再試行は3回まで。次のいずれかは
試行回数によらず停止する。

- 修正方法が成果契約、目的、優先順位を変える。
- 解決策が複数あり、選択で成果や安全性が変わる。
- 不可逆操作または外部状態の変更が必要である。
- 所有者不明の変更へ触れる必要がある。
- 二つの正本が矛盾し、正本が一意に決まらない。

正本同士が矛盾した場合は片方を推測で書き換えない。両方のpath、矛盾する記述、`AGENTS.md#参照順序`上の
上位、影響範囲を示し、推奨する一つの解決を添えて停止する。

### タスク分類と終端処理

| class | 対象 | 終端処理 |
|---|---|---|
| read | 照会、監査、説明 | 検証・STATE・commit・backup・manifest生成なし |
| work | 成果物・コード・文書の変更 | `finalize-task.sh` 1回（`--changed`検証、commit、`--root-only` backup） |
| state | 目標・到達点・検証結果の変化 | STATE更新後に同じfinalize 1回 |
| boundary | 契約、attachment、registry、移行、復旧 | full検証、必要な承認、workspace backup（手動経路） |

classはAgentが決め、必須の`prepare-context.sh --class`がprofileへ写像する（metaのwork/stateはfull）。未指定classを暗黙のworkとして扱わない。決定的なコマンド列は1回の
Tool呼び出しへまとめ、成功時出力は短く保つ。現在目標、到達点、検証結果、ブロッカー、次の一手が
変わらなければ`STATE.md`は不変とし、実行した事実や日付だけで更新しない。

## Tool一覧

固定Toolの登録は本表が正本である。呼び出し形・入出力・生成物・停止reasonなどTool個別の契約は
「詳細正本」列の所有先だけが持ち、扱うToolの節だけを条件付きロードで読む。下流Workspaceの
固有Toolも本表へ1行で登録し、詳細は`tools/REFERENCE.md`へ節を追加する（本書へ詳細を書き戻さない）。

| Tool | 責務 | 詳細正本 |
|---|---|---|
| `build-context-cache.sh` | catalog・manifest・検索索引の再生成 | `tools/REFERENCE.md` |
| `find-context.sh` | Route確定後の候補検索（metadata最大5件） | `tools/REFERENCE.md` |
| `prepare-context.sh` | Context Packetとclass→profile写像 | `tools/REFERENCE.md` |
| `finalize-task.sh` | work/state専用の決定的終端（検証・commit・backup） | `tools/REFERENCE.md` |
| `append-knowledge-log.sh` | LOG追記とローテーション | `tools/REFERENCE.md` |
| `backup-to-github.sh` | root backup remoteへpushする唯一の標準経路 | `tools/BACKUP.md` |
| `report-upstream-issue.sh` | 上流Issue送信の唯一の経路（宛先固定・添付なし） | `tools/UPSTREAM.md` |
| `materialize-project-repositories.sh` | registryからclone再現（復旧・移行・partial解消） | `tools/REFERENCE.md` |
| `run-routine.sh` | Scheduler起点のRoutine Executor | `routines/ROUTINES.md` |
| `manage-routine-schedule.sh` | user crontab / LaunchAgentのSchedule管理 | `tools/REFERENCE.md` |
| `routine-reasoner.py` | 任意推論アダプター（provider・keyは`.env`） | `routines/ROUTINES.md` |
| `validate-agent-directory.sh` | 構造・境界・サイズの機械検査 | `tools/REFERENCE.md` |
| `check-boundary.sh` / `install-git-hooks.sh` | commit・push境界検査とhook導入 | `tools/CONTROL.md` |

## サイズ予算

モデル非依存で安定するUTF-8 byteをhard limitに使い、行数と見出し数は可読性警告だけに使う。
実行時の読込予算は`AGENTS.md`が所有する。90%到達のwarningは質問事項ではなく、
次節の標準処理を自律実行する合図である。

| 対象 | hard limit |
|---|---:|
| `AGENTS.md`（ルート） | 8KiB。6KiB超はwarning |
| `projects/AGENTS.md` | 2KiB |
| `projects/<name>/AGENTS.md` | 2KiB |
| `knowledge/KNOWLEDGE.md`・`tools/*.md`・`PROJECT.md` / `SKILL.md` | 20KiB |
| `projects/PROJECTS.md`・`evals/EVALS.md`・`ARCHITECTURE.md`・`docs/<DOMAIN>.md` | 24KiB |
| `skills/SKILLS.md` | 12KiB |
| `routines/ROUTINES.md` | 16KiB |
| `STATE.md`・`routines/<id>/ROUTINE.md` | 8KiB |
| `knowledge/wiki/INDEX.md` | 8KiB・50項目 |
| active Wiki | 64KiB。24KiB超はRetrieval Map必須 |
| `knowledge/wiki/LOG.md` | 128KiB・1,000記録 |

### 超過時の標準処理

入口正本が上限またはその90%へ達したら、利用者への質問も残課題報告もせず次の順で処理し、
**上限の80%以下**まで代謝して完了とする。90%直下で止めると次の追記で警告が再発し境界へ
張り付くため、発火点より深く下げる。

1. 同じ意味の重複記述を除去する。
2. 詳細を既存の正しい所有先へ移す。
3. 条件付きロードへ変更する。
4. 残る詳細を責務単位で詳細文書へ分割する。
5. 元の正本には現在有効な原則、境界、Route、参照だけを残す。
6. 移動前後で意味・禁止事項・例外・参照の欠落がないことを確認し、validatorを実行してcommitし報告する。

「圧縮」は曖昧な要約置換ではなく、意味を保持した重複除去、責務移管、段階的開示である。上限拡大は、
既存の責務分離で収容できず、そのファイル自身が所有すべき明確な根拠がある構造変更としてだけ検討し、
validatorを通すためだけの拡大とwarning閾値の変更は禁止する。原資料、Knowledge、研究証拠、
Project成果物は大きさを理由に圧縮・要約置換・削除しない（正本は
`knowledge/KNOWLEDGE.md#大きいKnowledgeの扱い`）。
