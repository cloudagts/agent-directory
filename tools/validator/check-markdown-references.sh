#!/usr/bin/env bash
set -euo pipefail

# Internal checker used by validate-agent-directory.sh --full. Keep Markdown reference
# resolution isolated from the rest of the workspace validator so path and heading rules can
# be tested without coupling them to Git, Routine, or backup fixtures.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${1:-$(cd "${script_dir}/../.." && pwd)}"
failures=0

report_failure() {
  printf '%s\n' "$1"
  failures=$((failures + 1))
}

target_resolves() {
  local reference_file="$1"
  local reference_target="$2"
  awk -v target="$reference_target" '
    function heading_slug(value, slug) {
      slug = value
      gsub(/`/, "", slug)
      slug = tolower(slug)
      gsub(/[[:space:]]+/, "-", slug)
      gsub(/-+/, "-", slug)
      sub(/^-/, "", slug)
      sub(/-$/, "", slug)
      return slug
    }
    NR == 1 && /^---$/ { in_frontmatter = 1; next }
    in_frontmatter && /^---$/ { in_frontmatter = 0; next }
    in_frontmatter { if (index($0, target ":") == 1) { found = 1; exit }; next }
    /^#+ / {
      heading = $0
      sub(/^#+[[:space:]]*/, "", heading)
      sub(/[[:space:]]*$/, "", heading)
      plain_heading = heading
      gsub(/`/, "", plain_heading)
      if (heading == target || plain_heading == target || heading_slug(heading) == target) {
        found = 1
        exit
      }
    }
    { if (index($0, "**" target "**") > 0) { found = 1; exit } }
    END { exit found ? 0 : 1 }
  ' "$reference_file"
}

reference_md_files="$(git -C "$repo_root" ls-files '*.md' 2>/dev/null || true)"
if [[ -z "$reference_md_files" ]]; then
  reference_md_files="$(cd "$repo_root" && find . -name '*.md' -type f \
    -not -path './.git/*' -not -path './.agent-cache/*' -not -path './.tmp/*' \
    -not -path './projects/*/.git/*' 2>/dev/null | sed 's|^\./||')"
fi

while IFS= read -r reference_md_rel; do
  [[ -n "$reference_md_rel" ]] || continue
  reference_md_abs="$repo_root/$reference_md_rel"
  [[ -f "$reference_md_abs" ]] || continue
  while IFS= read -r markdown_reference; do
    [[ -n "$markdown_reference" ]] || continue
    case "$markdown_reference" in
      *'<'*) continue ;; # Placeholder or notation example.
    esac
    reference_path="${markdown_reference%%#*}"
    reference_target="${markdown_reference#*#}"
    reference_target="${reference_target%%=*}" # Eval-only =<expected> notation.
    [[ -n "$reference_target" && -n "$reference_path" ]] || continue

    sibling_reference="$(dirname "$reference_md_abs")/$reference_path"
    root_reference="$repo_root/$reference_path"
    reference_candidates=()
    first_reference=''
    # A slashless instance reference tries its sibling first, then the root. Resolution is by
    # target rather than file existence alone: projects/AGENTS.md must not shadow a valid root
    # AGENTS.md target, and root AGENTS.md must not shadow a valid Project sibling target.
    if [[ "$reference_path" != */* && -f "$sibling_reference" ]]; then
      reference_candidates+=("$sibling_reference")
      first_reference="$sibling_reference"
    fi
    if [[ -f "$root_reference" && "$root_reference" != "$first_reference" ]]; then
      reference_candidates+=("$root_reference")
    fi
    if [[ "$reference_path" == */* && -f "$sibling_reference" && "$sibling_reference" != "$root_reference" ]]; then
      reference_candidates+=("$sibling_reference")
    fi
    if (( ${#reference_candidates[@]} == 0 )) && [[ "$reference_path" != */* ]]; then
      continue # Generic instance reference resolved only in a concrete downstream Project.
    elif (( ${#reference_candidates[@]} == 0 )); then
      report_failure "$reference_md_rel references a missing file: $reference_path"
      continue
    fi
    reference_resolved=false
    for reference_file in "${reference_candidates[@]}"; do
      if target_resolves "$reference_file" "$reference_target"; then
        reference_resolved=true
        break
      fi
    done
    if [[ "$reference_resolved" != true ]]; then
      report_failure "$reference_md_rel reference does not resolve: $reference_path#$reference_target"
    fi
  done < <(grep -o '`[^`]*\.md#[^`]*`' "$reference_md_abs" 2>/dev/null | tr -d '`' | LC_ALL=C sort -u || true)
done <<<"$reference_md_files"

(( failures == 0 ))
