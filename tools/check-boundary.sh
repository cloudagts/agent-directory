#!/bin/bash
# tools/check-boundary.sh — commit・push境界のPortable Verifier。
# tools/control-policy.tsv を正本として差分を判定する。意味論は tools/CONTROL.md が所有する。
# stdoutの1行が機械可読結果、stderrのDETAIL:が人間向け補足。ネットワークへ接続しない。
# 執行時はhookが .git/agent-control/ の承認済みsnapshotを実行する（working tree版ではない）。
set -euo pipefail

usage() {
  printf 'Usage: %s [--staged | --base <git-ref> | --range <old> <new>] [--policy <file>] [--path-prefix <prefix>]\n' "${0##*/}" >&2
}

blocked() {
  # $1=reason $2=violation count
  printf 'BOUNDARY_BLOCKED reason=%s paths=%s\n' "$1" "$2"
  exit 1
}

mode='staged'
base_ref=''
range_old=''
range_new=''
policy_file=''
path_prefix=''
while (( $# > 0 )); do
  case "$1" in
    --staged) mode='staged'; shift ;;
    --base)
      mode='base'
      base_ref="${2:-}"
      if [[ -z "$base_ref" ]]; then usage; exit 2; fi
      shift 2
      ;;
    --range)
      mode='range'
      range_old="${2:-}"
      range_new="${3:-}"
      if [[ -z "$range_old" || -z "$range_new" ]]; then usage; exit 2; fi
      shift 3
      ;;
    --policy)
      policy_file="${2:-}"
      if [[ -z "$policy_file" ]]; then usage; exit 2; fi
      shift 2
      ;;
    --path-prefix)
      path_prefix="${2:-}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

# rootの決定と固定: 環境変数のrootとcwdのGit rootが両方見えて食い違うなら、
# 判定の転送（別リポジトリを検査させる迂回）として拒否する。
env_root="${AGENT_DIRECTORY_ROOT:-}"
cwd_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$env_root" && -n "$cwd_root" ]]; then
  env_root_physical="$(cd "$env_root" 2>/dev/null && pwd -P || true)"
  cwd_root_physical="$(cd "$cwd_root" && pwd -P)"
  if [[ -z "$env_root_physical" || "$env_root_physical" != "$cwd_root_physical" ]]; then
    printf 'DETAIL: AGENT_DIRECTORY_ROOT (%s) does not match the working Git root (%s)\n' \
      "$env_root" "$cwd_root" >&2
    blocked 'root-mismatch' 0
  fi
fi
repo_root="${env_root:-$cwd_root}"
if [[ -z "$repo_root" ]]; then
  printf 'DETAIL: run inside a Git repository or set AGENT_DIRECTORY_ROOT\n' >&2
  blocked 'not-a-git-repository' 0
fi

[[ -n "$policy_file" ]] || policy_file="$repo_root/tools/control-policy.tsv"
if [[ ! -f "$policy_file" ]]; then
  printf 'DETAIL: %s not found\n' "$policy_file" >&2
  blocked 'missing-policy' 0
fi

# policyを先勝ち順の平行配列へ読む（bash 3.2: 連想配列不可）。
tiers=()
patterns=()
policy_line=0
while IFS=$'\t' read -r tier pattern _note; do
  policy_line=$((policy_line + 1))
  case "$tier" in ''|'#'*) continue ;; esac
  case "$tier" in
    exempt|forbidden|frozen|guarded|contract) ;;
    *)
      printf 'DETAIL: line %d has an unknown tier: %s\n' "$policy_line" "$tier" >&2
      blocked 'invalid-policy' 0
      ;;
  esac
  if [[ -z "$pattern" ]]; then
    printf 'DETAIL: line %d has no pattern\n' "$policy_line" >&2
    blocked 'invalid-policy' 0
  fi
  tiers+=("$tier")
  patterns+=("$pattern")
done < "$policy_file"

tier_for() {
  # $1=repo相対path（path-prefix適用済み）。最初に一致した行のtierを返す（一致なしはnone）。
  local path="$1" i
  if (( ${#patterns[@]} == 0 )); then
    printf 'none'
    return 0
  fi
  for (( i = 0; i < ${#patterns[@]}; i++ )); do
    # shellcheck disable=SC2254 # patternはpolicy正本のglobとして展開する
    case "$path" in
      ${patterns[$i]}) printf '%s' "${tiers[$i]}"; return 0 ;;
    esac
  done
  printf 'none'
}

case "$mode" in
  base)
    if ! git -C "$repo_root" rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1; then
      printf 'DETAIL: base ref does not resolve to a commit: %s\n' "$base_ref" >&2
      blocked 'invalid-base' 0
    fi
    diff_output="$(git -C "$repo_root" diff --name-status -M "$base_ref" --)"
    ;;
  range)
    for range_ref in "$range_old" "$range_new"; do
      if ! git -C "$repo_root" rev-parse --verify "$range_ref^{tree}" >/dev/null 2>&1; then
        printf 'DETAIL: range ref does not resolve: %s\n' "$range_ref" >&2
        blocked 'invalid-base' 0
      fi
    done
    diff_output="$(git -C "$repo_root" diff --name-status -M "$range_old" "$range_new" --)"
    ;;
  *)
    diff_output="$(git -C "$repo_root" diff --cached --name-status -M --)"
    ;;
esac

guarded_ack="${AGENT_GUARDED_COMMIT:-}"
contract_ack="${AGENT_CONTRACT_COMMIT:-}"
checked=0
violations=0
first_reason=''
guarded_count=0
contract_count=0
normal_count=0

record_violation() {
  # $1=reason $2=op $3=path
  violations=$((violations + 1))
  [[ -n "$first_reason" ]] || first_reason="$1"
  printf 'DETAIL: %s %s %s\n' "$1" "$2" "$3" >&2
}

check_op() {
  # $1=op（add|modify|delete） $2=repo相対path
  local op="$1" path="$2" tier
  tier="$(tier_for "$path_prefix$path")"
  case "$tier" in
    exempt|none) normal_count=$((normal_count + 1)) ;;
    forbidden)
      record_violation 'forbidden-path' "$op" "$path"
      ;;
    frozen)
      if [[ "$op" == 'add' ]]; then
        normal_count=$((normal_count + 1))
      else
        record_violation 'frozen-path-modified' "$op" "$path"
      fi
      ;;
    guarded)
      guarded_count=$((guarded_count + 1))
      # rangeモード（push再検査）ではcommit時に執行済みのackを再要求しない。
      # 客観的なforbidden/frozenだけを再検査し、ackの常用を要求する設計を避ける。
      if [[ "$mode" != 'range' && "$guarded_ack" != 'true' ]]; then
        record_violation 'guarded-path-without-ack' "$op" "$path"
      fi
      ;;
    contract)
      contract_count=$((contract_count + 1))
      if [[ "$mode" != 'range' && "$contract_ack" != 'true' ]]; then
        record_violation 'contract-path-without-approval' "$op" "$path"
      fi
      ;;
  esac
}

while IFS=$'\t' read -r status path1 path2; do
  [[ -n "$status" ]] || continue
  checked=$((checked + 1))
  case "$status" in
    A) check_op 'add' "$path1" ;;
    M|T) check_op 'modify' "$path1" ;;
    D) check_op 'delete' "$path1" ;;
    R*)
      # renameは旧pathの削除と新pathの追加へ分解して判定する。
      check_op 'delete' "$path1"
      check_op 'add' "$path2"
      ;;
    C*) check_op 'add' "$path2" ;;
    *)
      record_violation 'unknown-diff-status' "$status" "${path1:-}"
      ;;
  esac
done <<EOF
$diff_output
EOF

# guarded / contractの変更は、通常の成果と同じcommitへ混ぜない（stagedモードだけの機械拒否）。
if [[ "$mode" == 'staged' ]] && (( guarded_count + contract_count > 0 )) && (( normal_count > 0 )); then
  printf 'DETAIL: meta/contract changes and ordinary work are staged together; split them into separate commits\n' >&2
  record_violation 'mixed-scope' 'staged' '(guarded/contract + ordinary paths)'
fi

if (( violations > 0 )); then
  case "$first_reason" in
    guarded-path-without-ack)
      printf 'DETAIL: meta canon changes require AGENT_GUARDED_COMMIT=true for this one commit and --full validation (tools/CONTROL.md#明示エスカレーション)\n' >&2
      ;;
    contract-path-without-approval)
      printf 'DETAIL: Project contract changes are decided by the human; commit them alone with AGENT_CONTRACT_COMMIT=true after that approval (tools/CONTROL.md#明示エスカレーション)\n' >&2
      ;;
  esac
  blocked "$first_reason" "$violations"
fi
printf 'BOUNDARY_OK checked=%d guarded=%d contract=%d\n' "$checked" "$guarded_count" "$contract_count"
