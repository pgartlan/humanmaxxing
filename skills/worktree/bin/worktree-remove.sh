#!/usr/bin/env bash
# worktree-remove.sh — report what removing a worktree would lose, and remove it.
#
#   worktree-remove.sh [--config F] check  <branch>
#   worktree-remove.sh [--config F] remove <branch> [--delete-branch] [--confirmed] [--discard-uncommitted] [--discard-commits]
#
# `check` only reports: exit 0 clean, exit 5 findings. `remove` runs the same checks itself before touching anything.
# --confirmed, --discard-uncommitted and --discard-commits are the user's answers to the findings; an agent never adds
# them on its own. --discard-commits is the only way a branch whose commits exist nowhere else is deleted (the usual
# case: it was merged by squash and its remote branch is gone).
# "Merged" is judged by ancestry against the base, never by `git branch -d`, whose answer depends on where it runs.
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-lib.sh"
# shellcheck source=skills/worktree/bin/worktree-lib.sh
. "$LIB" || { echo "worktree-lib missing or broken" >&2; exit 2; }
WT_SCRIPT="worktree-remove"

ACTION=""; BRANCH=""; DELETE=0; CONFIRMED=0; DISCARD=0; DISCARD_COMMITS=0
usage() { wt_die 2 usage "usage: worktree-remove.sh [--config F] check <branch> | remove <branch> [--delete-branch] [--confirmed] [--discard-uncommitted] [--discard-commits]${1:+ ($1)}"; }
while [ "$#" -gt 0 ]; do
  a="$1"; shift
  case "$a" in
    --config) [ "$#" -gt 0 ] || usage "--config needs a file"; WT_CONFIG="$1"; shift ;;
    --delete-branch) DELETE=1 ;;
    --confirmed) CONFIRMED=1 ;;
    --discard-uncommitted) DISCARD=1 ;;
    --discard-commits) DISCARD_COMMITS=1 ;;
    -*) usage "unknown option $a" ;;
    check|remove) if [ -z "$ACTION" ]; then ACTION="$a"; elif [ -z "$BRANCH" ]; then BRANCH="$a"; else usage "extra argument $a"; fi ;;
    *) [ -n "$ACTION" ] || usage "expected check or remove, got $a"; [ -z "$BRANCH" ] || usage "extra argument $a"; BRANCH="$a" ;;
  esac
done
[ -n "$ACTION" ] && [ -n "$BRANCH" ] || usage
if [ "$ACTION" = "check" ] && [ $((DELETE + CONFIRMED + DISCARD + DISCARD_COMMITS)) -gt 0 ]; then usage "check takes no flags"; fi
if [ "$DISCARD_COMMITS" -eq 1 ] && [ "$DELETE" -eq 0 ]; then usage "--discard-commits only applies with --delete-branch"; fi

wt_load_config
wt_repo_init
git worktree prune >/dev/null 2>&1

[ "$BRANCH" != "$WT_BASE" ] || wt_die 1 is-base "$BRANCH is the base branch; its working copy is never removed by this script"
TARGET=$(wt_worktree_for_branch "$BRANCH")
# BRANCH_ONLY: the worktree is already gone and only the branch is left (a remove that ended `kept=only-copy`). The
# same checks and the same delete gate then apply to the branch alone.
BRANCH_ONLY=0
if [ -z "$TARGET" ]; then
  git rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null 2>&1 || wt_die 1 not-found "no worktree has $BRANCH checked out, and no local branch has that name"
  BRANCH_ONLY=1; TARGET_ABS="(none)"
  if [ "$ACTION" = "remove" ] && [ "$DELETE" -eq 0 ]; then
    wt_die 1 not-found "no worktree has $BRANCH checked out; the branch itself still exists (pass --delete-branch to act on it)"
  fi
else
  TARGET_ABS="$(cd "$TARGET" 2>/dev/null && pwd -P)" || wt_die 1 not-found "the worktree for $BRANCH is registered at $TARGET but the folder is unreadable"
  if [ "$ACTION" = "remove" ] && [ -n "$WT_TOP" ] && [ "$WT_TOP" = "$TARGET_ABS" ]; then
    wt_die 1 is-current "this command is running inside $TARGET_ABS; run it from another worktree"
  fi
  wt_in_use_or_die "$TARGET_ABS"
fi

# --- Findings ----------------------------------------------------------------------------------------------------
if [ "$BRANCH_ONLY" -eq 1 ]; then DIRTY=0
else DIRTY=$(wt_dirty_count "$TARGET_ABS") || wt_die 3 status-failed "git status failed in $TARGET_ABS, so it cannot be called clean; fix that first"; fi
UNPUSHED=0; UNMERGED=0; PUSHED_FULLY=0
if [ -n "$WT_REMOTE" ]; then
  ERR=$(git fetch -q "$WT_REMOTE" "+refs/heads/$WT_BASE:refs/remotes/$WT_REMOTE/$WT_BASE" 2>&1) \
    || wt_die 3 fetch-failed "could not fetch $WT_BASE from $WT_REMOTE, so merged and pushed cannot be judged: $ERR"
  git ls-remote --exit-code "$WT_REMOTE" "refs/heads/$BRANCH" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) ERR=$(git fetch -q "$WT_REMOTE" "+refs/heads/$BRANCH:refs/remotes/$WT_REMOTE/$BRANCH" 2>&1) \
         || wt_die 3 fetch-failed "could not fetch $BRANCH from $WT_REMOTE: $ERR"
       UNPUSHED=$(git rev-list --count "refs/remotes/$WT_REMOTE/$BRANCH..refs/heads/$BRANCH" 2>/dev/null) || wt_die 3 compare-failed "could not compare $BRANCH with its remote branch"
       [ "$UNPUSHED" -ne 0 ] || PUSHED_FULLY=1 ;;
    2) UNPUSHED=$(git rev-list --count "$WT_BASE_REF..refs/heads/$BRANCH" 2>/dev/null) || wt_die 3 compare-failed "could not compare $BRANCH with $WT_BASE" ;;
    *) wt_die 3 ls-remote-failed "could not ask $WT_REMOTE whether $BRANCH exists (exit $rc)" ;;
  esac
fi
git rev-parse -q --verify "$WT_BASE_REF^{commit}" >/dev/null 2>&1 \
  || wt_die 2 config-base-branch "the base ref $WT_BASE_REF does not exist; check BASE_BRANCH and BASE_REMOTE"
git merge-base --is-ancestor "refs/heads/$BRANCH" "$WT_BASE_REF" 2>/dev/null; rc=$?
case "$rc" in
  0) UNMERGED=0 ;;
  1) UNMERGED=1 ;;
  *) wt_die 3 compare-failed "could not compare $BRANCH with $WT_BASE_REF (does the base ref exist?)" ;;
esac

SETUP_RUNNING=0; SETUP_DIED=0
P_PID=""; P_RC=""
if [ "$BRANCH_ONLY" -eq 0 ]; then
  P_PID=$(wt_gitpath "$TARGET_ABS" worktree-post-create.pid); P_RC=$(wt_gitpath "$TARGET_ABS" worktree-post-create.rc)
fi
if [ -n "$P_PID" ] && [ -f "$P_PID" ] && [ ! -f "$P_RC" ]; then
  pid=$(sed -n 1p "$P_PID" 2>/dev/null | tr -d '[:space:]')
  if wt_is_number "$pid" && { kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; }; then SETUP_RUNNING=1; else SETUP_DIED=1; fi
fi

FIELDS="dirty=$DIRTY unpushed=$UNPUSHED unmerged=$UNMERGED setup-running=$SETUP_RUNNING setup-died=$SETUP_DIED"
FOUND=0
[ "$DIRTY" -eq 0 ] || { FOUND=1; echo "finding: $DIRTY uncommitted or untracked path(s) in $TARGET_ABS"; }
if [ "$UNPUSHED" -ne 0 ]; then FOUND=1; echo "finding: $UNPUSHED commit(s) on $BRANCH that are not on a remote branch"; fi
if [ "$UNMERGED" -ne 0 ]; then FOUND=1; echo "finding: $BRANCH is not an ancestor of $WT_BASE (unmerged, or merged by squash)"; fi
[ "$SETUP_RUNNING" -eq 0 ] || { FOUND=1; echo "finding: the post-create command is still running in $TARGET_ABS"; }
[ "$SETUP_DIED" -eq 0 ] || { FOUND=1; echo "finding: the post-create command for this worktree died before recording an exit status (setup-died)"; }
if [ "$WT_IN_USE_UNKNOWN" -eq 1 ]; then
  FOUND=1; FIELDS="$FIELDS in-use-unknown=1"
  echo "finding: this platform cannot see which programs have $TARGET_ABS open (in-use-unknown); ask the user whether a session, editor or server is still using it"
fi

if [ "$ACTION" = "check" ]; then
  # shellcheck disable=SC2086
  if [ "$FOUND" -eq 0 ]; then wt_result PASS clean "path=$TARGET_ABS" $FIELDS; exit 0; fi
  # shellcheck disable=SC2086
  wt_result FAIL findings "path=$TARGET_ABS" $FIELDS; exit 5
fi

# --- Remove ------------------------------------------------------------------------------------------------------
if [ "$FOUND" -eq 1 ] && [ "$CONFIRMED" -eq 0 ]; then
  echo "STOP: show these findings to the user. Re-run with --confirmed only after they answer."
  # shellcheck disable=SC2086
  wt_result FAIL findings "path=$TARGET_ABS" $FIELDS; exit 5
fi
if [ "$DIRTY" -ne 0 ] && [ "$DISCARD" -eq 0 ]; then
  echo "STOP: $TARGET_ABS has uncommitted work. Removing it needs --discard-uncommitted as well, on the user's say-so."
  # shellcheck disable=SC2086
  wt_result FAIL findings "path=$TARGET_ABS" $FIELDS; exit 5
fi

# Decide the branch's fate BEFORE removing anything, so a refusal never leaves a half-removed state.
DELETE_OK=0; KEPT=""
if [ "$DELETE" -eq 1 ]; then
  if [ "$UNMERGED" -eq 0 ]; then DELETE_OK=1
  elif [ "$CONFIRMED" -eq 1 ] && [ "$PUSHED_FULLY" -eq 1 ]; then DELETE_OK=1
  elif [ "$CONFIRMED" -eq 1 ] && [ "$DISCARD_COMMITS" -eq 1 ]; then DELETE_OK=1
  else KEPT="only-copy"; fi
fi

# The in-use and mount checks run again right before the remove: a session can start while the user is answering.
[ "$BRANCH_ONLY" -eq 1 ] || wt_in_use_or_die "$TARGET_ABS"
# -c status.showUntrackedFiles=all: git's own "is it clean?" check reads that setting too, and with `no` it deletes
# untracked files without a word.
if [ "$BRANCH_ONLY" -eq 1 ]; then rc=0
elif [ "$DIRTY" -ne 0 ]; then ERR=$(git -c status.showUntrackedFiles=all worktree remove --force "$TARGET_ABS" 2>&1); rc=$?
else ERR=$(git -c status.showUntrackedFiles=all worktree remove "$TARGET_ABS" 2>&1); rc=$?; fi
[ "$rc" -eq 0 ] || wt_die 1 remove-failed "git could not remove $TARGET_ABS: $ERR"

DELETED=0
if [ "$DELETE_OK" -eq 1 ]; then
  if ERR=$(git --git-dir="$WT_COMMON" branch -D "$BRANCH" 2>&1); then DELETED=1
  else echo "warning: the worktree is gone but the branch could not be deleted: $ERR"; KEPT="delete-failed"; fi
elif [ -n "$KEPT" ]; then
  echo "The branch $BRANCH was kept: it is not contained in $WT_BASE and its commits are not all on a remote branch."
  echo "If it was merged by squash, or its commits can go, that is the user's call: remove with --delete-branch --confirmed --discard-commits,"
  echo "or delete the branch by name later."
fi
wt_result PASS removed "path=$TARGET_ABS" "branch=$BRANCH" "branch-deleted=$DELETED" ${KEPT:+"kept=$KEPT"}
exit 0
