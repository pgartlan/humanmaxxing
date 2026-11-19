#!/usr/bin/env bash
# worktree-sweep.sh — bulk cleanup of finished worktrees, with the skip rules a sweep must never relax.
#
#   worktree-sweep.sh [--config F]                              list: one line per worktree, candidate or skip + reason
#   worktree-sweep.sh [--config F] --confirmed <branch>...      remove exactly these, each re-judged right now
#
# A worktree is a candidate only when ALL hold; otherwise it is skipped with the first reason that applies:
#   in-use         a process sits in the folder (a session, a server, a shell)
#   recent-edits   a file under it changed in the last 72 hours (an isolated subagent's worktree is not its process's
#                  working directory, so the in-use check cannot see it; its edits can)
#   uncommitted    any uncommitted or untracked path (untracked counted even when git is set to hide them)
#   setup-running  its post-create install has not recorded a result
#   unmerged       its branch tip is not contained in the base (a squash-merged branch lands here too: `remove` and
#                  the user's answer handle it, never a sweep)
#   mount-below    a mount point is at or below it
# A check that cannot be read is a skip, never a pass (unreadable, compare-failed, mount-unknown). The main working
# tree, the base branch's folder, the folder this runs in and a detached checkout are never listed.
#
# --confirmed is the user's approval of the batch they were shown; an agent never adds it on its own. The named
# branches are intersected with a fresh judgement: one that changed since the list (new edits, a session started) is
# not swept. Removal is sequential, never --force; a removed branch is deleted only because its tip is in the base, and
# its restore line is printed. Remote branches are never touched.
# Exit: 0 listed / swept · 1 a removal failed (sweep-incomplete) · 2 usage or configuration · 3 a read failed before
# anything was removed (fetch, the process list).
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-lib.sh"
# shellcheck source=skills/worktree/bin/worktree-lib.sh
. "$LIB" || { echo "worktree-lib missing or broken" >&2; exit 2; }
WT_SCRIPT="worktree-sweep"
RECENT_HOURS=72

CONFIRMED=0; WANT=""
usage() { wt_die 2 usage "usage: worktree-sweep.sh [--config F] [--confirmed <branch>...]${1:+ ($1)}"; }
while [ "$#" -gt 0 ]; do
  a="$1"; shift
  case "$a" in
    --config) [ "$#" -gt 0 ] || usage "--config needs a file"; WT_CONFIG="$1"; shift ;;
    --confirmed) CONFIRMED=1 ;;
    -*) usage "unknown option $a" ;;
    *) [ "$CONFIRMED" -eq 1 ] || usage "branches are named only after --confirmed"; WANT="$WANT$a
" ;;
  esac
done
[ "$CONFIRMED" -eq 0 ] || [ -n "$WANT" ] || usage "--confirmed needs the approved branch names"

wt_load_config
wt_repo_init
git worktree prune >/dev/null 2>&1

if [ -n "$WT_REMOTE" ]; then
  ERR=$(git fetch -q "$WT_REMOTE" "+refs/heads/$WT_BASE:refs/remotes/$WT_REMOTE/$WT_BASE" 2>&1) \
    || wt_die 3 fetch-failed "could not fetch $WT_BASE from $WT_REMOTE, so merged cannot be judged: $ERR"
fi
git rev-parse -q --verify "$WT_BASE_REF^{commit}" >/dev/null 2>&1 \
  || wt_die 2 config-base-branch "the base ref $WT_BASE_REF does not exist; check BASE_BRANCH and BASE_REMOTE"
LIVE_RC=0; LIVE=$(wt_live_cwds) || LIVE_RC=$?
case "$LIVE_RC" in
  0) ;;
  4) ;;   # the platform cannot see the processes (Git Bash, Cygwin): every worktree is skipped as in-use-unknown
  *) wt_die 3 live-unknown "the processes using the worktrees could not be listed (reason above); nothing is swept on a partial list" ;;
esac

# judge <path> <branch> — prints `candidate` or the skip reason.
judge() {
  local p="$1" b="$2" n pf rf pid rc mb=0
  [ -d "$p" ] || { echo missing; return; }
  [ "$LIVE_RC" -eq 0 ] || { echo in-use-unknown; return; }
  if wt_is_live "$p" "$LIVE"; then echo in-use; return; fi
  if wt_touched_within "$p" "$RECENT_HOURS"; then echo recent-edits; return; fi
  n=$(wt_dirty_count "$p") || { echo unreadable; return; }
  [ "$n" -eq 0 ] || { echo uncommitted; return; }
  pf=$(wt_gitpath "$p" worktree-post-create.pid) || pf=""; rf=$(wt_gitpath "$p" worktree-post-create.rc) || rf=""
  if [ -n "$pf" ] && [ -f "$pf" ] && [ ! -f "$rf" ]; then echo setup-running; return; fi
  git merge-base --is-ancestor "refs/heads/$b" "$WT_BASE_REF" 2>/dev/null; rc=$?
  case "$rc" in 0) ;; 1) echo unmerged; return ;; *) echo compare-failed; return ;; esac
  wt_mount_below "$p" || mb=$?
  case "$mb" in 0) echo mount-below; return ;; 1) ;; *) echo mount-unknown; return ;; esac
  echo candidate
}

# The main working tree is never a sweep candidate, whatever it has checked out. It is wt_worktrees' first row unless
# the repository is bare (then every row is a linked worktree). Taken from wt_worktrees, not a second `git worktree
# list`, so both sides of the comparison spell paths the same way.
ROWS=$(wt_worktrees)
MAIN=""
[ "$(git -C "$WT_COMMON" rev-parse --is-bare-repository 2>/dev/null)" = true ] || MAIN=$(printf '%s\n' "$ROWS" | sed -n '1p' | cut -f1)
NC=0; NS=0; NR=0; NN=0; NF=0
while IFS="$WT_TAB" read -r path branch sha; do
  [ -n "$path" ] || continue
  [ "$path" != "$MAIN" ] || continue
  [ "$branch" != "$WT_BASE" ] || continue
  [ "$branch" != "(detached)" ] || continue
  abs="$(cd "$path" 2>/dev/null && pwd -P)" || abs="$path"
  [ -z "$WT_TOP" ] || [ "$abs" != "$WT_TOP" ] || continue
  if [ "$CONFIRMED" -eq 1 ]; then
    case "
$WANT" in *"
$branch
"*) ;; *) continue ;; esac
  fi
  v=$(judge "$abs" "$branch")
  issues=$(wt_issues_of "$abs" 2>/dev/null) || issues=""
  if [ "$CONFIRMED" -eq 0 ]; then
    if [ "$v" = candidate ]; then NC=$((NC + 1)); printf 'candidate\t%s\t%s\t%s\n' "$branch" "$abs" "${issues:--}"
    else NS=$((NS + 1)); printf 'skip\t%s\t%s\t%s\n' "$branch" "$abs" "$v"; fi
    continue
  fi
  WANT=$(printf '%s' "$WANT" | grep -vxF -- "$branch")
  [ -z "$WANT" ] || WANT="$WANT
"
  if [ "$v" != candidate ]; then NN=$((NN + 1)); printf 'not-swept\t%s\t%s\t%s\n' "$branch" "$abs" "$v"; continue; fi
  tip=$(git rev-parse -q --verify "refs/heads/$branch") || { NF=$((NF + 1)); printf 'failed\t%s\t%s\tcannot read the tip\n' "$branch" "$abs"; continue; }
  if ! ERR=$(git -c status.showUntrackedFiles=all worktree remove "$abs" 2>&1); then
    NF=$((NF + 1)); printf 'failed\t%s\t%s\t%s\n' "$branch" "$abs" "$(printf '%s' "$ERR" | head -1)"; continue
  fi
  if ERR=$(git --git-dir="$WT_COMMON" branch -D "$branch" 2>&1); then
    NR=$((NR + 1)); printf 'removed\t%s\t%s\trestore: git branch %s %s\n' "$branch" "$abs" "$branch" "$tip"
  else
    NF=$((NF + 1)); printf 'failed\t%s\t%s\tfolder removed, branch kept: %s\n' "$branch" "$abs" "$(printf '%s' "$ERR" | head -1)"
  fi
done <<EOF_ROWS
$ROWS
EOF_ROWS

if [ "$CONFIRMED" -eq 0 ]; then wt_result PASS listed "candidates=$NC" "skipped=$NS"; exit 0; fi
# A name the user approved that no worktree carries any more: reported, never guessed at.
while IFS= read -r b; do
  [ -n "$b" ] || continue
  NN=$((NN + 1)); printf 'not-swept\t%s\t-\tnot-found\n' "$b"
done <<EOF_LEFT
$WANT
EOF_LEFT
if [ "$NF" -gt 0 ]; then wt_result FAIL sweep-incomplete "removed=$NR" "not-swept=$NN" "failed=$NF"; exit 1; fi
wt_result PASS swept "removed=$NR" "not-swept=$NN" "failed=0"
exit 0
