# TOOLS.md — 構造保守と限定取得

`tools/`は利用者の成果を作るSkillではなく、このAgent Workspace自体を保守するmeta層である。
固定Toolは本書の各節が定める一覧だけとし、依存関係を増やさず、入出力、fallback、検証方法を明記する。
macOS標準のbash 3.2を最低条件とし、GNU専用option、associative array、`mapfile`、`readarray`を
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

## build-context-cache.sh

```bash
bash tools/build-context-cache.sh [--check|--check-routing|--routing-only]
```

生成物:

- `catalog.tsv` — routeable正本の最小metadata。通常検索のFast Path
- `manifest.tsv` — 全正本のinventory。Maintenance・full検証・boundary専用のSlow Path監査物
- `cache.meta` — schema、generator hash、fingerprint、件数、検索backend
- `stat.meta` — warm fast path用stat指紋。`--check`の比較対象にしない
- `search.sqlite` — routeable Knowledge 1,000件またはcatalog 5,000行で自動生成するFTS5 trigram派生索引

`--routing-only`はcatalog系だけをpath順で決定的に再生成し、manifestへ触れない。
`--check-routing`はstat指紋（path+size+mtime）一致なら本文再読なしで即PASSし、不一致・欠損時だけ
routeable正本を再計算して比較する（Git HEADは鮮度入力にしない）。

`ARCHITECTURE.md`、Project docs、`knowledge/raw/`はrouteable catalogへ入れず、通常検索結果へ
全件投入しない。Embeddedはroot indexの`projects/*/PROJECT.md`、Independentは
`projects/REPOSITORIES.md`から列挙し、採用revisionのfrontmatterだけを`git show`で読む。
登録済み`projects/<name>/`の本体はmanifest・fingerprint・SQLite body・fallback grepへ入れない。

`search.sqlite`はGit管理外で毎回正本から作り、外部content table、DBだけへの保存、ベクトルDBの
既定導入は行わない。閾値上書き（`AGENT_SQLITE_*_THRESHOLD`）はfixture検証専用。
`AGENT_DIRECTORY_ROOT`は各Toolの対象root、`AGENT_CACHE_DIR`はcache出力先を差し替える（既定値運用）。

## find-context.sh

```bash
tools/find-context.sh --route knowledge|skill|project|meta [--limit 1..5] [--include-inactive] -- "検索語"
```

- limitは1〜5。通常はactiveだけを返す。
- name完全一致、alias完全一致、metadata部分一致、本文一致の順に候補を決め、pathで同順位を固定する。
- cacheが欠損・stale・破損なら`--routing-only`で一度だけ再生成し、manifestを作らない。
- 本文検索はFTS5 trigramが使えれば`search.sqlite`、なければ`rg`、それもなければ警告して
  `grep`/`find`へfallbackする。
- 出力は最大5件のmetadataだけ。結果は候補であり、判断前にpathの正本を読む。

## prepare-context.sh

```bash
tools/prepare-context.sh --route project --target projects/<name> --class work
```

Route確定後の初期読込を1回のContext Packetへまとめ、Git root、attachment、Required参照、
読込順序を決定的に列挙する（本文は出力しない）。classからvalidation（none|scoped|full）と
backup（none|root-only|workspace|independent-origin）のprofileを決定的に返す。
Conditionalの成立判断はエージェントが行い、読込予算・読込順序の規約は変えない。
出力は`TASK_CONTEXT v1`のkey=value行と`READ:`/`CONDITIONAL:`/`MISSING:`のpath列。

## finalize-task.sh

```bash
tools/finalize-task.sh --route project --target projects/<name> --class work --message "変更の一文"
```

work/state専用の決定的終端。staged差分の確認、境界検査、profile準拠の検証（scoped=`--changed`、
meta=`--full`）、commit、backupを1回で実行し、段階ごとの再判断を排除する。profile写像は
`prepare-context.sh`と同一。guarded / contract差分とboundary classは扱わず`tools/CONTROL.md`の
手動経路へ返し、ack環境変数が設定済みの呼び出しは拒否する。Independent Projectでは検証を
Projectの固定検証に委ね（`project-owned`）、pushはPush Policyに従いここから実行しない。
合格は`FINALIZE_OK commit=<sha> validation=<profile> backup=<status>`、拒否は
`FINALIZE_BLOCKED reason=<reason>`をstdoutへ1行で出し非0で終了する。backup失敗はcommit成功を
取り消さない（`tools/BACKUP.md#backupが失敗したとき`）。

## append-knowledge-log.sh

```bash
tools/append-knowledge-log.sh --type ingest --target knowledge/wiki/topics/example.md --summary "変更内容"
```

- 入力は例のとおり（任意で`--date YYYY-MM-DD`）。
- 出力: `APPENDED: <date> <target>`、ローテーション時は`ROTATED: <path> (<記録数>, <byte数>)`を追加。
- 追記先は`knowledge/wiki/LOG.md`だけとし、サイズ予算表のLOG閾値で`logs/YYYY-QN[-NN].md`へ閉じ、
  現在のLOGをヘッダーだけへ戻す。閉鎖済みlogは以後変更しない。
- 記録の種別と意味的な運用規則は`knowledge/KNOWLEDGE.md#LOG`が所有する。

## backup-to-github.sh

```bash
bash tools/backup-to-github.sh [--remote backup] [--branch main] [--dry-run] [--root-only]
```

有効なPrivate backup remoteが設定済みなら、`tools/BACKUP.md`のtriggerで確認を求めず実行する。
scopeはタスク分類表に従う。root backup remoteへpushする唯一の標準経路であり、Independent remoteへは
pushせず、`--dry-run`はremoteへ書き込まない。成功とdry-runはstdoutへ1行の機械可読結果、停止は
`BACKUP_BLOCKED reason=<reason>`をstderrへ出して非0で終了する。trigger、scope、前提条件、
停止reason、divergence、Independent監査項目、復旧・移行手順は`tools/BACKUP.md`が所有し、
扱うときだけ読む。

## materialize-project-repositories.sh

```bash
bash tools/materialize-project-repositories.sh --all|--project <name> [--check]
```

registryの登録と採用revisionから`projects/<name>/`へ通常cloneを再現する（復旧、移行、partial解消）。

- 入力: `--all`か`--project <name>`と任意の`--check`（cloneせず整合だけを検査）。列挙は
  `projects/REPOSITORIES.md`だけを正本とし、`PROJECT.md`のfrontmatterを走査しない。
- 出力: 成功は`MATERIALIZATION_OK total=<n> cloned=<n> verified=<n>`をstdoutへ1行、停止は
  `MATERIALIZATION_BLOCKED reason=<reason> project=<name>`をstderrへ出し非0で終了する
  （停止reasonの正本はTool出力とvalidator隔離fixture）。
- targetが無いときだけ採用revisionをdetached checkoutし、branch tipへ勝手に進めない。既存cloneは
  HEADと採用SHAの一致まで検査し（detached HEADは要求しない）、reset、clean、stash、merge、rebaseで
  変形しない。認証情報を保存せず、絶対pathを正本へ書かない。
  `AGENT_ALLOW_LOCAL_REPOSITORY_URL=true`は隔離fixture専用。

## run-routine.sh

```bash
bash tools/run-routine.sh maintenance [--dry-run|--full]
```

Scheduler起点のRoutine Executor。lock、preflight、cache鮮度、検証、任意推論、scoped commit、
policy準拠backupの規則は`routines/ROUTINES.md`と各`ROUTINE.md`が所有する。出力はstdout最終1行の
`ROUTINE_NOOP|OK|SKIPPED|BLOCKED|FAILED`、詳細はstderrと`.agent-cache/routines/logs/`。

## manage-routine-schedule.sh

```bash
bash tools/manage-routine-schedule.sh --routine maintenance --scheduler auto --at 03:00 --print
```

user crontabとuser LaunchAgentだけを扱うSchedule管理。`--scheduler auto|cron|launchd`と
`--print|--install|--status|--remove`を持ち、冪等で無関係entryを保持する。installは利用者の明示操作であり、Routine実行やclone直後に
OS scheduleを変更しない。出力は`SCHEDULE_*`の1行。

## routine-reasoner.py

Python 3標準ライブラリだけの任意推論アダプター（`--request` / `--inspect-patch`）。
Provider（`deepseek | openai | anthropic`）、model ID、APIキーは`.env`が所有し、
未設定でも決定的Maintenanceは動作する。送信境界とpatch上限は`routines/ROUTINES.md`が
所有し、モデル出力のshell commandは実行しない。

## validate-agent-directory.sh

```bash
bash tools/validate-agent-directory.sh [--strict] [--full] [--changed] [--base <ref>]
```

- 通常: 必須構造、`AGENTS.md`/`CLAUDE.md`階層、metadata、Project契約とdocs境界、STATE、
  attachmentとroot ownership、サイズ、INDEX/LOG、eval schemaの静的検査
- `--changed`: Git差分で変更されたProject・Knowledge・Skillだけを検査するFast Path。meta正本
  （tools、evals、routines、領域正本、registry、template）へ及ぶ変更は全体静的検査へ自動fallbackする
- `--strict`: 導入後に残してはいけない自己定義・Skillプレースホルダーも失敗にする
- `--full`: 全参照、全Knowledge/Skill/Projectに加え、cache再生成、実Git・backup・materializer・
  context Toolの隔離fixtureを検査。Tool、eval、正本規約を変更した作業では必須とする
- `--base <ref>`: Git差分から`knowledge/raw/`、閉鎖済みlog、Project物理移動の禁止を検査
- 終了コード0と`PASS: agent-directory structure is valid`が合格条件。

機械検査する境界の網羅的な正本はvalidator本体、`evals/EVALS.md`の各最低条件、`tools/BACKUP.md`で
ある。AGENTS三層とProject docsの完全な構造規則は`projects/PROJECTS.md`が所有し、validatorは
境界とサイズだけを固定する。どのmodeも実GitHub接続、`gh` CLI、認証情報を必要としない。

## check-boundary.sh / install-git-hooks.sh

commit・push境界のPortable Verifierと、managed hook・承認済みsnapshotのinstaller。usage、
結果line、導入・除去の契約、tier意味論、ack・receipt条件、違反分類は`tools/CONTROL.md`が
所有し、扱うときだけ読む。hookは境界検査だけを行い、backup・validator・ネットワーク操作を
起動しない（`tools/BACKUP.md`の非ゴールを変更しない）。

## サイズ予算

モデル非依存で安定するUTF-8 byteをhard limitに使い、行数と見出し数は可読性警告だけに使う。
実行時の読込予算は`AGENTS.md`が所有する。90%到達のwarningは質問事項ではなく、
次節の標準処理を自律実行する合図である。

| 対象 | hard limit |
|---|---:|
| `AGENTS.md`（ルート） | 8KiB。6KiB超はwarning |
| `projects/AGENTS.md` | 2KiB |
| `projects/<name>/AGENTS.md` | 2KiB |
| `knowledge/KNOWLEDGE.md`・`tools/TOOLS.md`・`tools/BACKUP.md`・`tools/CONTROL.md`・`PROJECT.md` / `SKILL.md` | 20KiB |
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
