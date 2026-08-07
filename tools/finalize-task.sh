#!/usr/bin/env bash
set -euo pipefail

# tools/finalize-task.sh — work/state タスクの決定的な終端処理。
# staged差分の確認 → 境界検査（check-boundary） → profile準拠の検証 → commit → backup を
# 1回のTool呼び出しへまとめ、段階ごとのモデル再判断を排除する。profileの写像は
# prepare-context.sh と同一とする（scoped=--changed、meta work/state=--full）。
#
# 扱わないもの（tools/CONTROL.md の手動経路へ返す）:
# - boundary class（full検証、承認、workspace backup、receipt）
# - guarded / contract 差分（境界検査が拒否する。ack環境変数の設定済み呼び出しも拒否し、
#   ackの自動付与・常用（制御系違反）の経路にならない）
# 再試行の上限（検証失敗後の再finalizeは1回まで）は tools/TOOLS.md#自己修復と停止 が所有する。
# このToolは状態を持たない。
#
# 出力: 合格 FINALIZE_OK commit=<sha> validation=<profile> backup=<status>
#       拒否 FINALIZE_BLOCKED reason=<reason>
# いずれもstdoutへ1行。詳細はstderrのDETAIL:。backupの失敗・未設定はcommit成功を
# 取り消さず、statusで分けて報告する（tools/BACKUP.md#backupが失敗したとき）。

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${AGENT_DIRECTORY_ROOT:-$(cd "$tool_root/.." && pwd)}"
route=''
target=''
task_class=''
message=''

usage() {
  printf 'Usage: %s --route knowledge|skill|project|meta --class work|state [--target <repo-relative-path>] --message <commit message>\n' \
    "${0##*/}" >&2
}

blocked() {
  local reason="$1"
  local detail
  shift
  for detail in "$@"; do
    [[ -n "$detail" ]] || continue
    printf 'DETAIL: %s\n' "$detail" >&2
  done
  printf 'FINALIZE_BLOCKED reason=%s\n' "$reason"
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --route)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      route="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      target="$2"
      shift 2
      ;;
    --class)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      task_class="$2"
      shift 2
      ;;
    --message)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      message="$2"
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

case "$route" in knowledge|skill|project|meta) ;; *) usage; exit 2 ;; esac
case "$task_class" in
  work|state) ;;
  read) blocked 'usage' 'read has no finalize: no validation, commit, or backup' ;;
  boundary) blocked 'boundary-class' 'boundary follows tools/CONTROL.md manually (full validation, receipt, workspace backup)' ;;
  *) usage; exit 2 ;;
esac
[[ -n "$message" ]] || { usage; exit 2; }
target="${target%/}"
if [[ "$target" == /* || "$target" == *..* ]]; then
  printf 'ERROR: --target must be a repository-relative path without ..\n' >&2
  exit 2
fi

# The escalation acks are per-commit human-flow markers; a finalize call that arrives with
# them set is an attempted guarded/contract shortcut, which CONTROL.md classifies as a
# control violation. Refuse instead of forwarding.
if [[ "${AGENT_GUARDED_COMMIT:-}" == 'true' || "${AGENT_CONTRACT_COMMIT:-}" == 'true' ]]; then
  blocked 'ack-env-set' 'guarded / contract commits follow tools/CONTROL.md manually, never through finalize-task.sh'
fi

# Same owner detection as prepare-context.sh: a projects/<name> that is its own Git
# toplevel is an Independent repository and becomes the write root.
git_root_rel='.'
repository_owner='root'
path_prefix=''
if [[ "$route" == 'project' ]]; then
  if [[ -z "$target" || "$target" != projects/* ]]; then
    blocked 'usage' 'project route requires --target projects/<name>'
  fi
  project_name="${target#projects/}"
  project_name="${project_name%%/*}"
  project_dir="projects/$project_name"
  [[ -d "$repo_root/$project_dir" ]] || blocked 'usage' "project does not exist: $project_dir"
  if toplevel="$(git -C "$repo_root/$project_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    if [[ "$(cd "$toplevel" && pwd -P)" == "$(cd "$repo_root/$project_dir" && pwd -P)" ]]; then
      repository_owner='independent'
      git_root_rel="$project_dir"
      path_prefix="$project_dir/"
    fi
  else
    blocked 'usage' "cannot resolve a Git root for $project_dir"
  fi
fi

validation_profile='scoped'
backup_profile='root-only'
[[ "$route" != 'meta' ]] || validation_profile='full'
if [[ "$repository_owner" == 'independent' ]]; then
  # The workspace validator does not see Independent diffs; the Project's own fixed
  # verification (owned by PROJECT.md) must have run before finalize. Push follows the
  # Project's Push Policy and is never issued from here.
  validation_profile='project-owned'
  backup_profile='push-policy'
fi
git_root_abs="$(cd "$repo_root/$git_root_rel" && pwd -P)"

# 1. Staged diff must exist: the agent stages exactly this task's changes first.
if git -C "$git_root_abs" diff --cached --quiet 2>/dev/null; then
  blocked 'staged-empty' 'stage exactly the changes of this task before finalize'
fi

# 2. Boundary preflight with the working-tree verifier (the hook re-checks the approved
#    snapshot at commit). Fails fast before the validator run. ${path_prefix:+..} keeps
#    bash 3.2 "set -u" safe without an empty-array expansion.
if ! boundary_out="$(cd "$git_root_abs" && AGENT_DIRECTORY_ROOT="$git_root_abs" \
    bash "$tool_root/check-boundary.sh" --staged \
    --policy "$repo_root/tools/control-policy.tsv" \
    ${path_prefix:+--path-prefix "$path_prefix"})"; then
  blocked 'boundary' "$boundary_out"
fi
printf 'DETAIL: %s\n' "$boundary_out" >&2

# 3. One validation run per the deterministic profile. Repeating the validator during
#    editing is what TOOLS.md#自己修復と停止 forbids; this is the single terminal run.
if [[ "$validation_profile" != 'project-owned' ]]; then
  validator_flag='--changed'
  [[ "$validation_profile" != 'full' ]] || validator_flag='--full'
  if ! (cd "$repo_root" && bash tools/validate-agent-directory.sh "$validator_flag" >&2); then
    blocked 'validation' \
      "validator $validator_flag failed; fix the cause and rerun finalize once (tools/TOOLS.md#自己修復と停止)"
  fi
fi

# 4. Commit. The installed pre-commit hook re-verifies the boundary from the approved
#    snapshot; a hook rejection surfaces here as commit-failed with its DETAIL on stderr.
if ! git -C "$git_root_abs" commit -m "$message" >&2; then
  blocked 'commit-failed' 'git commit failed (a hook rejection or an empty/invalid commit; see stderr)'
fi
sha="$(git -C "$git_root_abs" rev-parse --short HEAD)"

# 5. Backup per profile. A blocked or unconfigured backup never cancels the local commit.
backup_status='skipped'
case "$backup_profile" in
  push-policy)
    backup_status='push-policy'
    ;;
  root-only)
    set +e
    backup_out="$(cd "$repo_root" && bash tools/backup-to-github.sh --root-only 2>&1)"
    backup_rc=$?
    set -e
    [[ -z "$backup_out" ]] || printf '%s\n' "$backup_out" >&2
    if (( backup_rc == 0 )); then
      backup_status='ok'
    else
      backup_reason="$(printf '%s\n' "$backup_out" | sed -n 's/^BACKUP_BLOCKED reason=//p' | head -n 1)"
      [[ -n "$backup_reason" ]] || backup_reason='failed'
      if [[ "$backup_reason" == 'missing-remote' ]]; then
        backup_status='not-configured'
      else
        backup_status="blocked-$backup_reason"
      fi
    fi
    ;;
esac

printf 'FINALIZE_OK commit=%s validation=%s backup=%s\n' "$sha" "$validation_profile" "$backup_status"
