#!/bin/bash
# tools/install-git-hooks.sh — managed hookと承認済みsnapshotを導入・確認・除去する。
# 導入元は常にworkspace HEADのblob（Gateを通過してcommitされた版）であり、working tree版を
# 導入しない。materialize済みIndependent repository（projects/<name>/.git/）へも同じhookと
# external snapshot（path-prefix付き）を導入する。意味論はtools/CONTROL.mdが所有する。
set -euo pipefail

marker='agent-directory managed hook'
hook_names='pre-commit pre-push'
control_files='check-boundary.sh control-policy.tsv'

usage() {
  printf 'Usage: %s --install|--status|--remove\n' "${0##*/}" >&2
}

blocked() {
  printf 'HOOKS_BLOCKED reason=%s%s\n' "$1" "${2:+ hook=$2}"
  exit 1
}

action=''
case "${1:-}" in
  --install) action='install' ;;
  --status) action='status' ;;
  --remove) action='remove' ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
if (( $# > 1 )); then usage; exit 2; fi

repo_root="${AGENT_DIRECTORY_ROOT:-}"
if [[ -z "$repo_root" ]]; then
  if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf 'DETAIL: run inside a Git repository or set AGENT_DIRECTORY_ROOT\n' >&2
    blocked 'not-a-git-repository'
  fi
fi
repo_root="$(cd "$repo_root" && pwd -P)"

# HEADに全template・control正本のblobがあることを先に確認する（working treeは導入元にしない）。
head_blob_of() {
  git -C "$repo_root" rev-parse "HEAD:$1" 2>/dev/null
}
for template_path in tools/hooks/pre-commit tools/hooks/pre-push \
  tools/check-boundary.sh tools/control-policy.tsv; do
  if [[ "$action" != 'remove' ]] && ! head_blob_of "$template_path" >/dev/null; then
    printf 'DETAIL: %s is not present in HEAD; commit it through the boundary first\n' "$template_path" >&2
    blocked 'missing-template' "${template_path##*/}"
  fi
done

resolve_dir() {
  # $1=対象repo root $2=git rev-parse --git-path の対象
  local resolved
  resolved="$(git -C "$1" rev-parse --git-path "$2")"
  case "$resolved" in
    /*) printf '%s' "$resolved" ;;
    *) printf '%s/%s' "$1" "$resolved" ;;
  esac
}

hook_state() {
  # $1=対象repo root $2=hook名。missing | managed | managed-stale | unmanaged を返す。
  local target_root="$1" name="$2" dst dst_blob head_blob
  dst="$(resolve_dir "$target_root" hooks)/$name"
  if [[ ! -f "$dst" ]]; then
    printf 'missing'
    return 0
  fi
  if ! grep -Fq "$marker" "$dst"; then
    printf 'unmanaged'
    return 0
  fi
  dst_blob="$(git hash-object "$dst")"
  head_blob="$(head_blob_of "tools/hooks/$name" || true)"
  if [[ -n "$head_blob" && "$dst_blob" == "$head_blob" ]]; then
    printf 'managed'
  else
    printf 'managed-stale'
  fi
}

install_into() {
  # $1=対象repo root $2=refresh-source（head|external） $3=path-prefix（空可）
  local target_root="$1" source_mode="$2" prefix="$3" hooks_dir control_dir name blob
  hooks_dir="$(resolve_dir "$target_root" hooks)"
  control_dir="$(resolve_dir "$target_root" agent-control)"
  mkdir -p "$hooks_dir" "$control_dir/receipts"
  for name in $hook_names; do
    blob="$(head_blob_of "tools/hooks/$name")"
    git -C "$repo_root" cat-file blob "$blob" > "$hooks_dir/$name"
    chmod 755 "$hooks_dir/$name"
  done
  : > "$control_dir/approved.sha256"
  for name in $control_files; do
    blob="$(head_blob_of "tools/$name")"
    git -C "$repo_root" cat-file blob "$blob" > "$control_dir/$name"
    printf '%s %s\n' "$blob" "$name" >> "$control_dir/approved.sha256"
  done
  chmod 755 "$control_dir/check-boundary.sh"
  printf '%s\n' "$source_mode" > "$control_dir/refresh-source"
  printf '%s\n' "$prefix" > "$control_dir/path-prefix"
}

remove_from() {
  # $1=対象repo root。managed hookだけを除去し、除去数を返す。
  local target_root="$1" hooks_dir name state removed_here=0
  hooks_dir="$(resolve_dir "$target_root" hooks)"
  for name in $hook_names; do
    state="$(hook_state "$target_root" "$name")"
    case "$state" in
      managed|managed-stale)
        rm -f "$hooks_dir/$name"
        removed_here=$((removed_here + 1))
        ;;
      unmanaged)
        printf 'DETAIL: %s is not managed by this tool; leaving it untouched\n' "$hooks_dir/$name" >&2
        ;;
    esac
  done
  printf '%d' "$removed_here"
}

# materialize済みIndependent repository（projects/<name>/.git/が実directory）を列挙する。
independent_roots=()
for candidate in "$repo_root"/projects/*/; do
  [[ -d "$candidate" ]] || continue
  if [[ -d "$candidate/.git" && ! -L "${candidate%/}/.git" ]]; then
    independent_roots+=("${candidate%/}")
  fi
done

# 全対象repoの前提を先に検査し、一部だけ導入された状態を作らない。
if [[ "$action" == 'install' ]]; then
  for name in $hook_names; do
    if [[ "$(hook_state "$repo_root" "$name")" == 'unmanaged' ]]; then
      printf 'DETAIL: %s has an unmanaged %s hook; review and remove it manually before installing\n' \
        "$repo_root" "$name" >&2
      blocked 'unmanaged-hook-exists' "$name"
    fi
  done
  if (( ${#independent_roots[@]} > 0 )); then
    for independent_root in "${independent_roots[@]}"; do
      for name in $hook_names; do
        if [[ "$(hook_state "$independent_root" "$name")" == 'unmanaged' ]]; then
          printf 'DETAIL: %s has an unmanaged %s hook; review and remove it manually before installing\n' \
            "$independent_root" "$name" >&2
          blocked 'unmanaged-hook-exists' "$name"
        fi
      done
    done
  fi
fi

case "$action" in
  install)
    install_into "$repo_root" 'head' ''
    independent_installed=0
    if (( ${#independent_roots[@]} > 0 )); then
      for independent_root in "${independent_roots[@]}"; do
        install_into "$independent_root" 'external' "projects/${independent_root##*/}/"
        independent_installed=$((independent_installed + 1))
      done
    fi
    printf 'HOOKS_INSTALLED hooks=2 independent=%d\n' "$independent_installed"
    ;;
  status)
    line='HOOKS_STATUS'
    for name in $hook_names; do
      line="$line $name=$(hook_state "$repo_root" "$name")"
    done
    independent_managed=0
    if (( ${#independent_roots[@]} > 0 )); then
      for independent_root in "${independent_roots[@]}"; do
        repo_ok=true
        for name in $hook_names; do
          [[ "$(hook_state "$independent_root" "$name")" == 'managed' ]] || repo_ok=false
        done
        [[ "$repo_ok" == true ]] && independent_managed=$((independent_managed + 1))
      done
    fi
    printf '%s independent=%d/%d\n' "$line" "$independent_managed" "${#independent_roots[@]}"
    ;;
  remove)
    removed="$(remove_from "$repo_root")"
    independent_cleaned=0
    if (( ${#independent_roots[@]} > 0 )); then
      for independent_root in "${independent_roots[@]}"; do
        independent_removed="$(remove_from "$independent_root")"
        (( independent_removed > 0 )) && independent_cleaned=$((independent_cleaned + 1))
      done
    fi
    printf 'HOOKS_REMOVED removed=%d independent=%d\n' "$removed" "$independent_cleaned"
    ;;
esac
