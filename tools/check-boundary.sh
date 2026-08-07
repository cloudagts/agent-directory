#!/bin/bash
# tools/check-boundary.sh — commit境界のPortable Verifier。
# tools/control-policy.tsv を正本として差分を判定する。意味論は tools/CONTROL.md が所有する。
# stdoutの1行が機械可読結果、stderrのDETAIL:が人間向け補足。ネットワークへ接続しない。
set -euo pipefail

usage() {
  printf 'Usage: %s [--staged | --base <git-ref>]\n' "${0##*/}" >&2
}

blocked() {
  # $1=reason $2=violation count
  printf 'BOUNDARY_BLOCKED reason=%s paths=%s\n' "$1" "$2"
  exit 1
}

mode='staged'
base_ref=''
while (( $# > 0 )); do
  case "$1" in
    --staged) mode='staged'; shift ;;
    --base)
      mode='base'
      base_ref="${2:-}"
      if [[ -z "$base_ref" ]]; then usage; exit 2; fi
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

repo_root="${AGENT_DIRECTORY_ROOT:-}"
if [[ -z "$repo_root" ]]; then
  if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf 'DETAIL: run inside a Git repository or set AGENT_DIRECTORY_ROOT\n' >&2
    blocked 'not-a-git-repository' 0
  fi
fi

policy_file="$repo_root/tools/control-policy.tsv"
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
    exempt|forbidden|frozen|guarded) ;;
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
  # $1=repo相対path。最初に一致した行のtierを返す（一致なしはnone）。
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

if [[ "$mode" == 'base' ]]; then
  if ! git -C "$repo_root" rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1; then
    printf 'DETAIL: base ref does not resolve to a commit: %s\n' "$base_ref" >&2
    blocked 'invalid-base' 0
  fi
  diff_output="$(git -C "$repo_root" diff --name-status -M "$base_ref" --)"
else
  diff_output="$(git -C "$repo_root" diff --cached --name-status -M --)"
fi

ack="${AGENT_GUARDED_COMMIT:-}"
checked=0
violations=0
first_reason=''

record_violation() {
  # $1=reason $2=op $3=path
  violations=$((violations + 1))
  [[ -n "$first_reason" ]] || first_reason="$1"
  printf 'DETAIL: %s %s %s\n' "$1" "$2" "$3" >&2
}

check_op() {
  # $1=op（add|modify|delete） $2=repo相対path
  local op="$1" path="$2" tier
  tier="$(tier_for "$path")"
  case "$tier" in
    exempt|none) ;;
    forbidden)
      record_violation 'forbidden-path' "$op" "$path"
      ;;
    frozen)
      if [[ "$op" != 'add' ]]; then
        record_violation 'frozen-path-modified' "$op" "$path"
      fi
      ;;
    guarded)
      if [[ "$ack" != 'true' ]]; then
        record_violation 'guarded-path-without-ack' "$op" "$path"
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

if (( violations > 0 )); then
  if [[ "$first_reason" == 'guarded-path-without-ack' ]]; then
    printf 'DETAIL: meta canon changes require AGENT_GUARDED_COMMIT=true for this one commit and --full validation (tools/CONTROL.md#明示エスカレーション)\n' >&2
  fi
  blocked "$first_reason" "$violations"
fi
printf 'BOUNDARY_OK checked=%d\n' "$checked"
