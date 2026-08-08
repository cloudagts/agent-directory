# BACKUP.md — 遠隔バックアップと復旧

backup trigger、remote分類、失敗、divergence、復旧、マシン移行、監査を扱うときに読む。通常作業では
読まず、設定済み自動backupの実行だけなら`tools/REFERENCE.md#backup-to-github.sh`で足りる。

## 目的と非ゴール

目的は、ローカルの稼働正本が失われたとき、最後に確定したGitコミットから再構築できる
遠隔コピーを1つ持つこと。非ゴール（実装しない）:

- GitHubを正本、実行キュー、タスク管理、デプロイ経路、クラウド同期基盤にすること
- 複数マシンの双方向同期と自動競合解決
- GitHub Actions、CI、Git hook、常駐daemon、schedule到達だけを理由とする時刻駆動のバックアップ
- バックアップ履歴の正本、`BACKUP_STATUS.md`のようなremote SHAをGit追跡で保存するファイル

## 用語

- **Remote Backup** — エージェント1体ごとのGitHub Privateリポジトリ。最後に正常pushされた`main`の
  受動的な復旧コピーで、直接編集しない。
- **Agent Workspace / root repository** — agent-directoryのツリー全体と、そのrootのGit。rootは
  Embedded Projectの履歴とattachment registryを持つ。
- **Embedded / Independent** — attachmentの区別（定義、昇格条件、登録形式は
  `projects/PROJECTS.md#Attachment`）。
- **Materialization** — 登録と採用revisionから`projects/<name>/`のcloneを再現すること。一部だけ
  存在するpartial materializationは、復旧途中のdegraded stateとしてだけ許す。

## バックアップ対象

`main`のコミットから到達可能なGit管理ファイルと履歴を対象とする。永続正本と永続成果物は、領域を問わず
Git追跡されていること。対象外は次で、復旧は別経路で行う。

- `.env`、`.env.local`などの秘密情報、SSH鍵、Git認証情報、ローカルGit設定
- `.tmp/`、`.agent-cache/`、`.DS_Store`、製品側AIメモリ
- 未コミット変更、未追跡ファイル、`git stash`
- `main`から到達できないローカルbranch、reflogだけに存在するコミット
- Independent repository本体。履歴の保全はそのremoteが持ち、rootはregistry entryだけを保全する。

永続正本を`.gitignore`へ追加してバックアップ対象外にすることは禁止する。対象外にしたい情報は、
そもそも正本として置かない。

許可されるnested Gitは登録済みの`projects/<name>/.git/`だけで、それ以外のnested Gitとsubmoduleは
ignore状態にかかわらずToolが停止する（backup対象外の派生領域`.tmp/`・`.agent-cache/`は走査しない。
エージェント側の扱いは`projects/PROJECTS.md#Attachment`）。

## リポジトリ構成

- リポジトリは共用せず、remote名の既定値は`backup`、branchは`main`とする。
- remoteは常にpush先であり、GitHub Web UI、Codespaces、別マシンから直接編集しない。
- Private可視性はセットアップ契約であり利用者が確認する。Toolは可視性を照会・変更しない。

## backup Tool

Toolは1つだけであり、scopeをoptionで選ぶ。別のbackup Toolを追加しない。

### scope

```bash
bash tools/backup-to-github.sh [--dry-run] [--root-only]   # 既定はworkspace scope
```

workspace scope（CLI既定）はroot pushの前に全Independent repositoryを監査し、Independent自体は
pushしない。全repositoryがremoteから復旧可能な場合だけ成功とし、partial materializationでは停止する。
`--root-only`はrootだけを検査・pushする部分結果で（静的metadataとroot ownership違反は検査する）、
workspace全体の成功として報告しない。タスク分類との対応は`tools/TOOLS.md#タスク分類と終端処理`が
所有する。

| scope | 成功（終了コード0） | dry-run成功 |
|---|---|---|
| workspace | `WORKSPACE_BACKUP_OK remote=<r> branch=<b> sha=<sha> independent=<n>` | `WORKSPACE_BACKUP_READY …` |
| `--root-only` | `ROOT_BACKUP_OK remote=<r> branch=<b> sha=<sha> scope=root-only` | `ROOT_BACKUP_READY …` |

### 共通

停止は両scopeとも`BACKUP_BLOCKED reason=<reason>`をstderrへ出し非0で終了する。stdoutの1行が
機械可読結果、stderrの`DETAIL:`が人間向け補足。

root前提条件は次である。ひとつでも満たさない場合、Toolは何も変更せず停止する。

1. `AGENTS.md`と`tools/validate-agent-directory.sh`を持つGitリポジトリrootで、現在branchが
   指定branch（detached HEADでない）、指定remoteが設定済みである。
2. index、tracked working tree、未追跡の非ignoreファイル、`git stash`がすべて空である。
3. 指定branchから到達できないローカルbranch commitがない。
4. `.tmp/`、`.agent-cache/`、`.env`実値、`.DS_Store`がGit追跡されていない。
5. 登録済みIndependent以外のnested Git、submodule、Git LFSがなく、100MiB以上の到達可能blobもない。
6. `projects/REPOSITORIES.md`の構造と、`projects/.gitignore`のmanaged blockが登録集合と一致する。
7. root indexが登録済み`projects/<name>/`配下のpathもmode 160000のgitlinkも持たない。
8. 旧`projects/<name>/repository/`、旧repository frontmatter、旧`## Repository State`が残っていない。
9. rootのremote branchが未作成であるか、remote SHAがローカルHEADのancestorである。

`--root-only`でも6〜8の静的境界は検査する。workspace scopeでは、さらに各Independent repositoryを
次の順で監査する。remote refsとlocal refsの到達性は一時bare repositoryで検査する。

1. **attachment** — `projects/<name>/`に存在し、targetと`.git`がsymlinkでなく`.git`が実directory
   （`.git` fileは非対応）で、toplevelと`remote.origin.url`が登録と完全一致する。
2. **構造** — submodule、追加のnested Git、Git LFSがなく、HEADに`PROJECT.md`と`STATE.md`が存在する。
3. **cleanliness** — staged、tracked dirty、非ignoreのuntracked、stashがない。
4. **到達性** — remoteへ到達でき採用revisionをfetchでき、HEADが採用revisionと一致し、HEADと全local
   branch tipがremote headまたはtagから到達でき、local-onlyなtagがない。

構造的に非対応な状態（2）はcleanliness（3）より先に判定し、原因を未追跡ファイル報告で隠さない。

停止reasonの網羅的な正本はTool出力とvalidatorの隔離fixtureである。

Toolはfast-forward pushだけを行い、push後に`git ls-remote`でremote SHAとローカルHEADの完全一致を
確認する。remote通信はこのpushと事後検証だけで、無条件の事前照会はdry-runに限り、push拒否時だけ
remoteを読んで`remote-diverged`等へ分類する（拒否はremoteを変更しない）。事後検証済みSHAは
`.agent-cache/`のcheckpoint（削除可能な派生状態。remote URLはhash保持）へ記録し、次回の
oversized object監査を新規範囲だけにする。欠損・破損・不一致・非ancestorでは全履歴監査へ
fallbackする。

`AGENT_BACKUP_MAX_BLOB_BYTES`は隔離fixture検証だけで使う閾値上書きであり、通常運用では設定しない。

## Toolが行わないこと

`git add`、`git commit`、`git stash push`、`git pull`、`git merge`、`git rebase`、`git reset`、
`git clean`、作業ツリーを変更する`git checkout`、force push、force-with-lease、mirror push、prune、
remote branch削除、tagや全branchの一括push、remote側の競合自動解決、秘密情報の保存、
GitHubリポジトリの作成・可視性変更、GitHub Actionsの実行、Independent remoteへの書込、
子cloneのfetch・checkout・reset・merge・rebase・stashによる変形。対象を確定するのは
検証済みのcommitである。

## remoteの分類

remoteを目的ごとに分け、許可操作と承認を混同しない。

| remote | 目的 | 許可操作 | 承認 |
|---|---|---|---|
| workspace `backup` | 受動的な復旧コピー | このToolのfast-forward pushだけ | 設定済みなら自動 |
| skeleton `origin` | 公開スケルトンの開発remote | 読み取り専用fetch、検証済みcommitの通常push | スケルトン保守の依頼範囲内 |
| Independent `origin` | Project固有remote | Independent sessionのfetchと通常push | Projectのpush policy |

実運用のAgent Workspaceは開発remoteを持たず`backup`だけを持つ。公開スケルトンへ実運用データをpushせず、
導入時にスケルトンの`origin`を`template`へ改名するか削除する。`AGENTS.md#禁止事項`のpull、merge、rebase、
force push禁止は全分類へ適用する。Independent側の条件とpush policyは
`projects/PROJECTS.md#Remote操作の境界`が所有する。

registryの`repository_url`規則は`projects/REPOSITORIES.md`が所有する。Toolは違反と`-`で始まるURLを
`invalid-registry`で拒否し、報告経路でもuserinfoのpasswordを伏せる。

## Single Writer

Single WriterはAgent単位ではなくGitリポジトリ単位の制約である。同じrepositoryへ同時に書き込む
Writerを持たない。異なるIndependent repositoryは並行して進めてよいが、materializationまたは
migrationの実行中は対象repositoryのWriterを停止する。

## root での `git clean`

登録済みIndependent Projectの`projects/<name>/`はroot Gitからignoreされている。次はrootで実行しない。

- `git clean -x`
- `git clean -X`
- `git clean`への二つ以上の`-f`（`-ff`、`-ffd`、`-ffdx`など）

これらは未pushのIndependent commit、stash、未追跡の作業を不可逆に削除しうる。掃除が必要な場合は
対象pathを明示した最小のコマンドを利用者へ提示し、削除対象と失われる範囲を先に報告する。
危険性の検証は破棄前提の一時fixtureだけで行う。

## 実行trigger

有効なPrivate backup remoteが設定済みなら、次のタスク境界で確認を求めずbackupを実行する。
未設定なら実行せず、その事実を報告する。

- 正常に検証・commitされた意味のある変更の後
- 復旧可能性に関わるmetadata変更後
- Independent Projectの採用revision更新後
- 破壊的変更前や長い作業を中断する際のcleanな検証済みcheckpoint
- マシン移行前

ファイル1件ごとにpushせず、意味のあるcommit境界で実行する。フルvalidatorの合否はbackupの
必須条件ではない。壊れた状態の保全にもbackupを使う。

cron/launchdのScheduled Maintenance Routine（`routines/ROUTINES.md`）でも、schedule到達自体は
backup triggerではない。Routineが検証済みcommitを作った場合だけ上記triggerが成立する。
backup-only Routineは作らない。

## backupが失敗したとき

backup先が未設定、到達不能、一時的に失敗しても、検証済みローカルcommitを取り消さず、
ローカル作業も停止させない。次を区別して報告する。

```text
local task: complete
local commit: complete
backup: failed / skipped / blocked
recoverability: degraded
```

そのタスクの成果契約が「remoteから復旧可能であること」を必須条件としている場合だけ、完了扱いにしない。
backup失敗をタスクの失敗として、backup成功をタスクの検証成功として報告しない。

秘密情報、未コミット状態、remote divergence、対象漏れ、GitHubのhard limit、Single Writer違反、remoteの
想定外変更は停止条件である。これらを自動解決せず、`AGENTS.md#人間へ上げる例外`として上げる。

## divergenceの停止

remote SHAがローカルHEADのancestorでない場合、Toolは何も変更せず`remote-diverged`で停止し、
remote SHAとlocal SHAを報告する。分岐は別マシンからの書込、GitHubでの直接編集、Single Writer違反を
意味し、原因特定と採用は利用者が決定する。

## マシン移行

1. 旧マシンで作業を確定し、`bash tools/backup-to-github.sh`が`WORKSPACE_BACKUP_OK`を出すまで実行する。
2. 旧マシンの書込を停止し読み取り専用として扱う。
3. 新マシンでPrivate backupから新しいディレクトリへcloneする。
4. `git remote rename origin backup`でremote名を揃える。
5. `git rev-parse HEAD`と`git ls-remote --heads backup main`が一致することを確認する。
6. `bash tools/materialize-project-repositories.sh --all`で全Independent repositoryを揃える。
7. `bash tools/validate-agent-directory.sh`と`bash tools/build-context-cache.sh`で構造を検証し、
   `.agent-cache/`を正本から再生成する。
8. `.env`などの秘密情報を別経路から復旧する。
9. 新マシンを唯一の書込者へ昇格し、旧cloneは破棄するか読み取り専用で残す。

Independent cloneは`projects/<name>/`自体へ置き、全件が揃うまではpartial materializationである。
昇格が完了するまで新旧両方から書き込まない。

## 障害復旧

ローカルが失われた場合も手順は移行と同じで、相違点は次だけである。

- 旧マシンの`WORKSPACE_BACKUP_OK`が取れないため、復旧点は最後に成功したバックアップコミットになる。
- 最後のバックアップ以降の未コミット変更、未追跡ファイル、stashは復旧できない。失われた範囲を
  利用者へ明示する。
- 秘密情報はリポジトリに存在しないため、必ず別経路から再設定する。
- 復旧直後の`.agent-cache/`は正本から再生成する（cacheを正本として扱わない）。
- 登録済み`projects/<name>/`はregistryからmaterializerで再現する（branch tipではなくまず採用SHA）。

## 旧構造からの移行

Project rootは`projects/<name>/`だけである。旧`projects/<name>/repository/`方式と、
agent-directory外へcloneを置く旧方式は、残さず併存も認めず、検出時は
`deprecated-repository-layout`として扱う。
手順は共通で、外部cloneは移動元がツリー外である点だけが異なる（cleanで全refがremote-backedな
sourceに限り、fresh cloneで置き換えてよい）。

1. rootとchildの全Writerを停止し、rootでcheckpointコミットを確定する。
2. child repositoryのdirty、staged、untracked、stash、全branch、全tag、未pushを監査する。
3. root側`PROJECT.md`と`STATE.md`から旧repository fieldと`## Repository State`を除いた内容を
   child repoへ移し、両ファイルを含めて検証、commit、`origin`へ通常pushする。
4. rootへregistry entryと`projects/.gitignore`のmanaged entryを追加し、root indexから旧
   `PROJECT.md`と`STATE.md`を削除してroot commitを作成する。
5. `projects/<name>/`を消失させない形でclone全体を移動し、`.git`が`projects/<name>/.git/`に
   あること、`PROJECT.md`、`STATE.md`、`origin`、HEAD、全refを再確認する。
6. validatorとcacheを実行し、`bash tools/backup-to-github.sh`が`WORKSPACE_BACKUP_OK`を出すことを
   確認する。

dirty、staged、untracked、stash、未pushが残るcloneを置換せず、reset、clean、stash作成、force push
で移行しない。旧copyの削除は、新cloneが一致する`origin`を持ち、旧copyの全refが到達可能かつcleanで、
利用者が明示承認した場合だけ行う。マシン固有のsource pathを正本へ保存しない。

## 大容量ファイル

Git LFSは既定構成へ導入しない。

- 通常の対象はテキスト、コード、設定、文書、軽量成果物。大量の動画、音声、モデル、データセット、
  生成物は通常Gitへ入れない（外部artifact保管先とchecksumの定義はProject側、`projects/PROJECTS.md`）。
- submodule、Git LFS、100MiB以上のGit object（`oversized-git-object`）は完全バックアップを
  保証できないため自動処理せず、停止・報告する。
