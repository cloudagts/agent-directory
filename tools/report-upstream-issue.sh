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

usage() {
  printf 'Usage: %s --title <title> --body-file <path> [--comment <issue-number>] [--dry-run]\n' "${0##*/}" >&2
  printf '       %s --search "<terms>"\n' "${0##*/}" >&2
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

# --- search assist mode --------------------------------------------------------
if [[ -n "$search_terms" ]]; then
  [[ -z "$title$body_file$comment_issue" ]] || blocked usage '--search cannot be combined with report arguments'
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
[[ -n "$title" ]] || { usage; blocked usage '--title is required'; }
[[ -n "$body_file" ]] || { usage; blocked usage '--body-file is required'; }
[[ -f "$body_file" ]] || blocked usage 'body file not found'
if [[ -n "$comment_issue" && ! "$comment_issue" =~ ^[0-9]+$ ]]; then
  blocked usage '--comment expects an issue number'
fi

content_file="$(mktemp "${TMPDIR:-/tmp}/upstream-report-content.XXXXXX")"
send_body="$(mktemp "${TMPDIR:-/tmp}/upstream-report-body.XXXXXX")"
trap 'rm -f "$content_file" "$send_body"' EXIT

# 上流SHAはtemplate remote（tools/BACKUP.mdの読み取り用remote）から解決する。無ければunknown。
upstream_sha='unknown'
if git -C "$repo_root" remote get-url template >/dev/null 2>&1; then
  upstream_sha="$(git -C "$repo_root" merge-base HEAD refs/remotes/template/main 2>/dev/null || printf 'unknown')"
fi
sed "s/<upstream-sha>/$upstream_sha/g" "$body_file" >"$send_body"
{ printf '%s\n' "$title"; cat "$send_body"; } >"$content_file"

add_violation() {
  local rule="$1" existing
  for existing in ${violations[@]+"${violations[@]}"}; do
    [[ "$existing" != "$rule" ]] || return 0
  done
  violations+=("$rule")
}

# The matched value itself is never printed: printing it would be the leak.
check_term() {
  local rule="$1" term="$2"
  [[ -n "$term" ]] || return 0
  [[ ${#term} -ge 4 ]] || return 0
  case "$term" in
    'agent-directory'|'<agent-name>'|'<agent-role>') return 0 ;;
  esac
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

agent_name="$(sed -n 's/.*あなたは`\([^`]*\)`.*/\1/p' "$repo_root/AGENTS.md" | head -n 1)"
check_term agent-name "$agent_name"
check_term workspace-name "${repo_root##*/}"
check_term os-user-name "${USER:-}"
check_term home-path "${HOME:-}"
check_term git-user-name "$(git -C "$repo_root" config user.name 2>/dev/null || true)"
check_term git-user-email "$(git -C "$repo_root" config user.email 2>/dev/null || true)"
while IFS= read -r remote_url; do
  [[ -n "$remote_url" ]] || continue
  case "$remote_url" in
    *"$upstream_repo"*) continue ;;
  esac
  check_term git-remote-url "$remote_url"
done < <(git -C "$repo_root" remote -v 2>/dev/null | awk '{print $2}' | LC_ALL=C sort -u)

check_pattern absolute-local-path '/(Users|home)/[A-Za-z0-9._-]+'
check_pattern credential-token '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}'
check_pattern authorization-header '[Aa]uthorization[[:space:]]*:'
check_pattern private-key-block 'BEGIN [A-Z ]*PRIVATE KEY'
check_pattern harness-signature 'Generated with|[Cc]o-[Aa]uthored-[Bb]y:'

if [[ ${#violations[@]} -gt 0 ]]; then
  mkdir -p "$draft_dir"
  draft_path="$draft_dir/blocked-$(date +%Y%m%d-%H%M%S)-$$.md"
  { printf 'title: %s\n\n' "$title"; cat "$send_body"; } >"$draft_path"
  details=()
  for rule in "${violations[@]}"; do
    details+=("violated-rule: $rule")
  done
  details+=("draft: $draft_path")
  details+=('abstract the flagged content (tools/UPSTREAM.md#公開禁止情報) and retry; do not weaken the check')
  blocked policy-violation "${details[@]}"
fi

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

if [[ -z "$comment_issue" ]]; then
  candidates="$(gh issue list --repo "$upstream_repo" --state open --search "$title" \
    --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null || true)"
  if [[ -n "$candidates" ]]; then
    note 'possibly duplicate open issues; if it is the same problem, retry with --comment <number> instead:'
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      note "  $line"
    done <<<"$candidates"
  fi
fi

if [[ -n "$comment_issue" ]]; then
  issue_url="$(gh issue comment "$comment_issue" --repo "$upstream_repo" --body-file "$send_body")"
  printf 'UPSTREAM_REPORT_COMMENTED issue=%s\n' "$issue_url"
else
  issue_url="$(gh issue create --repo "$upstream_repo" --title "$title" --body-file "$send_body")"
  printf 'UPSTREAM_REPORT_OK issue=%s\n' "$issue_url"
fi
