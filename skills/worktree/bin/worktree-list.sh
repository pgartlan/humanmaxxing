#!/usr/bin/env bash
# worktree-list.sh — one line per worktree: path, branch, short sha, clean|dirty|unreadable|missing, recorded issues
# (or -), tab-separated. A worktree whose status cannot be read is never shown as clean.
#
#   worktree-list.sh [--config F]
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-lib.sh"
# shellcheck source=skills/worktree/bin/worktree-lib.sh
. "$LIB" || { echo "worktree-lib missing or broken" >&2; exit 2; }
WT_SCRIPT="worktree-list"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) [ "$#" -gt 1 ] || wt_die 2 usage "--config needs a file"; WT_CONFIG="$2"; shift 2 ;;
    *) wt_die 2 usage "usage: worktree-list.sh [--config F] (unexpected: $1)" ;;
  esac
done
wt_load_config
wt_repo_init
git worktree prune >/dev/null 2>&1

ROWS=$(wt_worktrees)
COUNT=0; DIRTY=0
while IFS="$WT_TAB" read -r path branch sha; do
  [ -n "$path" ] || continue
  COUNT=$((COUNT + 1))
  if [ ! -d "$path" ]; then state="missing"
  else
    n=$(wt_dirty_count "$path") || n=unreadable
    case "$n" in 0) state="clean" ;; unreadable) state="unreadable"; DIRTY=$((DIRTY + 1)) ;; *) state="dirty"; DIRTY=$((DIRTY + 1)) ;; esac
  fi
  issues=$(wt_issues_of "$path") || issues="unreadable"
  printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$branch" "$(printf '%.7s' "$sha")" "$state" "${issues:--}"
done <<EOF_ROWS
$ROWS
EOF_ROWS
wt_result PASS listed "count=$COUNT" "dirty=$DIRTY"
exit 0
