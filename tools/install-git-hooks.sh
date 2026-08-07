#!/bin/bash
# tools/install-git-hooks.sh — tools/hooks/ のmanaged hookを .git/hooks へ導入・確認・除去する。
# 冪等であり、marker行を持たない既存hook（unmanaged）へは触れず停止する。意味論はtools/CONTROL.md。
set -euo pipefail

marker='agent-directory managed hook'
hook_names='pre-commit pre-push'

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

hooks_dir="$(git -C "$repo_root" rev-parse --git-path hooks)"
case "$hooks_dir" in
  /*) ;;
  *) hooks_dir="$repo_root/$hooks_dir" ;;
esac

hook_state() {
  # $1=hook名。missing | managed | managed-stale | unmanaged を返す。
  local name="$1" src dst
  src="$repo_root/tools/hooks/$name"
  dst="$hooks_dir/$name"
  if [[ ! -f "$dst" ]]; then
    printf 'missing'
  elif ! grep -Fq "$marker" "$dst"; then
    printf 'unmanaged'
  elif [[ -f "$src" ]] && cmp -s "$src" "$dst"; then
    printf 'managed'
  else
    printf 'managed-stale'
  fi
}

# 全hookの前提を先に検査し、途中で止まって一部だけ導入された状態を作らない。
for name in $hook_names; do
  src="$repo_root/tools/hooks/$name"
  if [[ "$action" != 'remove' && ! -f "$src" ]]; then
    printf 'DETAIL: template not found: %s\n' "$src" >&2
    blocked 'missing-template' "$name"
  fi
  if [[ "$action" == 'install' && "$(hook_state "$name")" == 'unmanaged' ]]; then
    printf 'DETAIL: %s exists without the managed marker; review and remove it manually before installing\n' "$hooks_dir/$name" >&2
    blocked 'unmanaged-hook-exists' "$name"
  fi
done

case "$action" in
  install)
    installed=0
    mkdir -p "$hooks_dir"
    for name in $hook_names; do
      cp "$repo_root/tools/hooks/$name" "$hooks_dir/$name"
      chmod 755 "$hooks_dir/$name"
      installed=$((installed + 1))
    done
    printf 'HOOKS_INSTALLED hooks=%d\n' "$installed"
    ;;
  status)
    line='HOOKS_STATUS'
    for name in $hook_names; do
      line="$line $name=$(hook_state "$name")"
    done
    printf '%s\n' "$line"
    ;;
  remove)
    removed=0
    for name in $hook_names; do
      state="$(hook_state "$name")"
      case "$state" in
        managed|managed-stale)
          rm -f "$hooks_dir/$name"
          removed=$((removed + 1))
          ;;
        unmanaged)
          printf 'DETAIL: %s is not managed by this tool; leaving it untouched\n' "$hooks_dir/$name" >&2
          ;;
      esac
    done
    printf 'HOOKS_REMOVED removed=%d\n' "$removed"
    ;;
esac
