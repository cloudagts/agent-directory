#!/usr/bin/env bash
set -euo pipefail

# tools/report-upstream-issue.sh — 上流Issue報告の唯一の送信経路。
# 契約・匿名化規則・停止reasonの正本はtools/UPSTREAM.md。

tool_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "${AGENT_DIRECTORY_ROOT:-$tool_root/..}" 2>/dev/null && pwd -P)" || repo_root=''
cache_dir="${AGENT_CACHE_DIR:-$repo_root/.agent-cache}"
draft_dir="$cache_dir/upstream-reports"
# The destination is a contract (tools/UPSTREAM.md). No flag or environment variable may change it.
upstream_repo='claudagt/agent-directory'

title=''
body_file=''
comment_issue=''
dry_run=false
search_terms=''
violations=()
checked_agent_name_terms=0

usage() {
  printf 'Usage: %s --title <title> --body-file <path> [--comment <issue-number>] [--dry-run]\n' "${0##*/}" >&2
  printf '       %s --search "<terms>" [--dry-run]\n' "${0##*/}" >&2
}

blocked() {
  local reason="$1"
  local detail
  shift
  printf 'UPSTREAM_REPORT_BLOCKED reason=%s\n' "$reason" >&2
  for detail in "$@"; do
    [[ -n "$detail" ]] || continue
    printf 'DETAIL: %s\n' "$detail" >&2
  done
  exit 1
}

note() {
  printf 'DETAIL: %s\n' "$1" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) [[ $# -ge 2 ]] || { usage; blocked usage 'missing value for --title'; }; title="$2"; shift 2 ;;
    --body-file) [[ $# -ge 2 ]] || { usage; blocked usage 'missing value for --body-file'; }; body_file="$2"; shift 2 ;;
    --comment) [[ $# -ge 2 ]] || { usage; blocked usage 'missing value for --comment'; }; comment_issue="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    --search) [[ $# -ge 2 ]] || { usage; blocked usage 'missing value for --search'; }; search_terms="$2"; shift 2 ;;
    *) usage; blocked usage "unknown argument: $1 (destination and attachments are fixed by tools/UPSTREAM.md)" ;;
  esac
done

[[ -n "$repo_root" && -f "$repo_root/AGENTS.md" ]] || blocked no-repo-root 'cannot resolve the workspace root'

gh_ready() {
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status >/dev/null 2>&1 || return 1
}

# --- mode validation -----------------------------------------------------------
# 送信内容（report本文・search検索語）は、どちらのモードでも同じ匿名化検査を通ってから
# 外部へ出る。--searchだけ検査を迂回する経路を作らない。
if [[ -n "$search_terms" ]]; then
  [[ -z "$title$body_file$comment_issue" ]] || blocked usage '--search cannot be combined with report arguments'
else
  [[ -n "$title" ]] || { usage; blocked usage '--title is required'; }
  [[ -n "$body_file" ]] || { usage; blocked usage '--body-file is required'; }
  [[ -f "$body_file" ]] || blocked usage 'body file not found'
  if [[ -n "$comment_issue" && ! "$comment_issue" =~ ^[0-9]+$ ]]; then
    blocked usage '--comment expects an issue number'
  fi
fi

content_file="$(mktemp "${TMPDIR:-/tmp}/upstream-report-content.XXXXXX")"
send_body="$(mktemp "${TMPDIR:-/tmp}/upstream-report-body.XXXXXX")"
trap 'rm -f "$content_file" "$send_body"' EXIT

if [[ -n "$search_terms" ]]; then
  printf '%s\n' "$search_terms" >"$content_file"
else
  # 上流revisionの解決順序はtools/UPSTREAM.md#上流revisionの解決が所有する:
  # 検証済みの採用宣言（git config） → merge-base（clone追従の診断値） → unknown（reason付き）。
  # 宣言値は「採用した」事実、merge-baseは「分岐した」事実であり、後者は採用の進行を追わない。
  # 常にresolved-fromを併記し、実在確認できない宣言値を公開しない。
  has_template_remote=false
  template_ref_present=false
  merge_base=''
  if git -C "$repo_root" remote get-url template >/dev/null 2>&1; then
    has_template_remote=true
    if git -C "$repo_root" rev-parse --verify --quiet refs/remotes/template/main >/dev/null 2>&1; then
      template_ref_present=true
      merge_base="$(git -C "$repo_root" merge-base HEAD refs/remotes/template/main 2>/dev/null || true)"
    fi
  fi
  declared_revision="$(git -C "$repo_root" config agent-directory.upstream-revision 2>/dev/null || true)"
  declared_verified=''
  if [[ -n "$declared_revision" ]]; then
    if ! [[ "$declared_revision" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
      note 'git config agent-directory.upstream-revision is not a revision sha; ignoring it'
    elif git -C "$repo_root" cat-file -e "$declared_revision^{commit}" 2>/dev/null; then
      # git rev-parseが受け付ける表記（大文字・short sha）は正規化して採用する。
      declared_verified="$(git -C "$repo_root" rev-parse --verify "$declared_revision^{commit}" 2>/dev/null || true)"
    else
      note 'git config agent-directory.upstream-revision does not exist in this clone; not publishing an unverifiable sha'
    fi
  fi
  if [[ -n "$declared_verified" ]]; then
    upstream_sha="$declared_verified (resolved-from: declared)"
  elif [[ -n "$merge_base" ]]; then
    upstream_sha="$merge_base (resolved-from: merge-base)"
  elif [[ "$has_template_remote" == true && "$template_ref_present" == false ]]; then
    upstream_sha='unknown (template-not-fetched)'
    note 'template remote is declared but refs/remotes/template/main is absent; run git fetch template, or declare the adopted revision once with: git config agent-directory.upstream-revision <sha>'
  elif [[ "$has_template_remote" == true ]]; then
    upstream_sha='unknown (unrelated-history)'
    note 'template remote is fetched but shares no history (3-way port adoption); declare the adopted revision once with: git config agent-directory.upstream-revision <sha>'
  else
    upstream_sha='unknown (no-template-remote)'
  fi
  sed "s/<upstream-sha>/$upstream_sha/g" "$body_file" >"$send_body"
  { printf '%s\n' "$title"; cat "$send_body"; } >"$content_file"
fi

add_violation() {
  local rule="$1" existing
  for existing in ${violations[@]+"${violations[@]}"}; do
    [[ "$existing" != "$rule" ]] || return 0
  done
  violations+=("$rule")
}

# The matched value itself is never printed: printing it would be the leak.
# 自己定義で宣言された固有名は、長さ・文字体系・localeにかかわらず必ず検査する
# （tools/UPSTREAM.md#公開禁止情報は長さによる免除を定めていない）。
check_declared_term() {
  local rule="$1" term="$2"
  [[ -n "$term" ]] || return 0
  case "$term" in
    'agent-directory') return 0 ;;
    '<'*'>') return 0 ;; # 未置換のtemplateプレースホルダー（<agent-name>等）は固有名ではない
  esac
  checked_agent_name_terms=$((checked_agent_name_terms + 1))
  if grep -Fiq -- "$term" "$content_file"; then
    add_violation "$rule"
  fi
}

# 環境から推測した語（Git root名、OSユーザー名等）は、ありふれた短い語での誤遮断を避けるため
# 3byte未満を飛ばす。長さはbyte数で数えてlocaleへ依存させず、飛ばしたことは黙らずnoteへ残す。
check_derived_term() {
  local rule="$1" term="$2" term_bytes
  [[ -n "$term" ]] || return 0
  case "$term" in
    'agent-directory') return 0 ;;
    '<'*'>') return 0 ;;
  esac
  term_bytes="$(printf %s "$term" | wc -c | tr -d '[:space:]')"
  if [[ "$term_bytes" -lt 3 ]]; then
    note "rule $rule: a derived term shorter than 3 bytes was skipped, not checked"
    return 0
  fi
  if grep -Fiq -- "$term" "$content_file"; then
    add_violation "$rule"
  fi
}

check_pattern() {
  local rule="$1" pattern="$2"
  if grep -Eq -- "$pattern" "$content_file"; then
    add_violation "$rule"
  fi
}

# Agent固有名はAGENTS.md#自己定義の名乗り行（`- あなたは…`）のbacktickトークン全件から導出する。
# 見出しの深さにも記法にも依存させず、応対言語のような固有名でないbacktickを遮断語にしない。
# agent-nameの検査が1件も実行されないまま送信・dry-run成功を成立させない（fail-closed）。
self_definition_section="$(awk '
  /^#+[[:space:]]*自己定義[[:space:]]*$/ { in_section = 1; match($0, /^#+/); depth = RLENGTH; next }
  in_section && /^#+[[:space:]]/ { match($0, /^#+/); if (RLENGTH <= depth) exit }
  in_section' "$repo_root/AGENTS.md")"
if [[ -z "$self_definition_section" ]]; then
  blocked anonymization-source-unparsed \
    'AGENTS.md has no 自己定義 section at any heading depth; the agent-name rule cannot run' \
    'restore a heading whose text is 自己定義 (any depth), then retry (tools/UPSTREAM.md#公開禁止情報)'
fi
self_definition_terms="$(printf '%s\n' "$self_definition_section" \
  | grep -E '^[[:space:]]*-[[:space:]]*あなたは' \
  | grep -o '`[^`][^`]*`' | tr -d '`' | LC_ALL=C sort -u || true)"
if [[ -z "$self_definition_terms" ]]; then
  blocked anonymization-source-unparsed \
    'the identity line (`- あなたは…`) in AGENTS.md#自己定義 has no backticked names; the agent-name rule cannot run' \
    'wrap every agent-specific name on the identity line in backticks, then retry (tools/UPSTREAM.md#公開禁止情報)'
fi
while IFS= read -r self_definition_term; do
  check_declared_term agent-name "$self_definition_term"
done <<<"$self_definition_terms"
if [[ "$checked_agent_name_terms" -eq 0 ]]; then
  blocked anonymization-source-unparsed \
    'every backticked token on the identity line is an unreplaced template placeholder; zero agent-name checks ran' \
    'replace the identity-line placeholders with the real names (README.md 手順2), then retry'
fi
check_derived_term workspace-name "${repo_root##*/}"
check_derived_term os-user-name "${USER:-}"
check_derived_term home-path "${HOME:-}"
check_derived_term git-user-name "$(git -C "$repo_root" config user.name 2>/dev/null || true)"
check_derived_term git-user-email "$(git -C "$repo_root" config user.email 2>/dev/null || true)"
while IFS= read -r remote_url; do
  [[ -n "$remote_url" ]] || continue
  case "$remote_url" in
    *"$upstream_repo"*) continue ;;
  esac
  check_derived_term git-remote-url "$remote_url"
done < <(git -C "$repo_root" remote -v 2>/dev/null | awk '{print $2}' | LC_ALL=C sort -u)

check_pattern absolute-local-path '/(Users|home)/[A-Za-z0-9._-]+'
check_pattern credential-token '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}'
check_pattern authorization-header '[Aa]uthorization[[:space:]]*:'
check_pattern private-key-block 'BEGIN [A-Z ]*PRIVATE KEY'
check_pattern harness-signature 'Generated with|[Cc]o-[Aa]uthored-[Bb]y:'

if [[ ${#violations[@]} -gt 0 ]]; then
  details=()
  for rule in "${violations[@]}"; do
    details+=("violated-rule: $rule")
  done
  if [[ -z "$search_terms" ]]; then
    mkdir -p "$draft_dir"
    draft_path="$draft_dir/blocked-$(date +%Y%m%d-%H%M%S)-$$.md"
    { printf 'title: %s\n\n' "$title"; cat "$send_body"; } >"$draft_path"
    details+=("draft: $draft_path")
  fi
  details+=('abstract the flagged content (tools/UPSTREAM.md#公開禁止情報) and retry; do not weaken the check')
  blocked policy-violation "${details[@]}"
fi

# --- search assist mode --------------------------------------------------------
if [[ -n "$search_terms" ]]; then
  if [[ "$dry_run" == true ]]; then
    note "destination: $upstream_repo"
    printf 'UPSTREAM_REPORT_SEARCH_DRY_RUN_OK\n'
    exit 0
  fi
  gh_ready || blocked gh-unavailable 'install and authenticate gh, or search the upstream issues manually'
  candidates="$(gh issue list --repo "$upstream_repo" --state open --search "$search_terms" \
    --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null || true)"
  count=0
  if [[ -n "$candidates" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      note "open: $line"
      count=$((count + 1))
    done <<<"$candidates"
  fi
  printf 'UPSTREAM_REPORT_SEARCH_OK count=%s\n' "$count"
  exit 0
fi

# --- report mode ---------------------------------------------------------------
if [[ "$dry_run" == true ]]; then
  note "destination: $upstream_repo"
  note "upstream-revision: $upstream_sha"
  printf 'UPSTREAM_REPORT_DRY_RUN_OK\n'
  exit 0
fi

if ! gh_ready; then
  mkdir -p "$draft_dir"
  draft_path="$draft_dir/draft-$(date +%Y%m%d-%H%M%S)-$$.md"
  { printf 'title: %s\n\n' "$title"; cat "$send_body"; } >"$draft_path"
  printf 'UPSTREAM_REPORT_DRAFTED reason=gh-unavailable path=%s\n' "$draft_path"
  exit 0
fi

# 重複処理（tools/UPSTREAM.md#送信フロー）: 正規化タイトルが完全一致するopen Issueがあれば
# 同一問題と確定し、新規作成せず自動で--commentへ切り替える。曖昧な候補では停止せず新規作成する
# （観測を一件も捨てず、人間確認待ちで報告経路を塞がない。重複の統合は上流側の責務）。
normalize_issue_title() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E -e 's/^[[:space:]]*\[(bug|field|improvement)\][[:space:]]*//' \
      -e 's/[[:space:]]+/ /g' -e 's/^ //' -e 's/ $//'
}
if [[ -z "$comment_issue" ]]; then
  candidates="$(gh issue list --repo "$upstream_repo" --state open --search "$title" \
    --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null || true)"
  if [[ -n "$candidates" ]]; then
    normalized_title="$(normalize_issue_title "$title")"
    duplicate_number=''
    while IFS=$'\t' read -r candidate_number candidate_title; do
      [[ -n "$candidate_number" ]] || continue
      if [[ -n "$normalized_title" && "$(normalize_issue_title "$candidate_title")" == "$normalized_title" ]]; then
        duplicate_number="$candidate_number"
        break
      fi
    done <<<"$candidates"
    if [[ -n "$duplicate_number" ]]; then
      comment_issue="$duplicate_number"
      note "an open issue with an identical normalized title exists; appending this observation as a comment on #$duplicate_number instead of creating a duplicate"
    else
      note 'possibly duplicate open issues; if it is the same problem, retry with --comment <number> instead:'
      while IFS=$'\t' read -r candidate_number candidate_title; do
        [[ -n "$candidate_number" ]] || continue
        note "  #$candidate_number $candidate_title"
      done <<<"$candidates"
    fi
  fi
fi

if [[ -n "$comment_issue" ]]; then
  issue_url="$(gh issue comment "$comment_issue" --repo "$upstream_repo" --body-file "$send_body")"
  printf 'UPSTREAM_REPORT_COMMENTED issue=%s\n' "$issue_url"
else
  issue_url="$(gh issue create --repo "$upstream_repo" --title "$title" --body-file "$send_body")"
  printf 'UPSTREAM_REPORT_OK issue=%s\n' "$issue_url"
fi
