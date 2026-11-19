#!/usr/bin/env bash
# worktree-create.sh — create a sibling worktree on a new or existing branch.
#
#   worktree-create.sh [--config F] [--force] [--no-base-update] [--background] [--no-install] [--no-hook-setup] <branch>
#   worktree-create.sh [--config F] [--force] [--no-base-update] [--background] [--no-install] [--no-hook-setup] <n>... [<branch>]
#
# Leading numeric words (comma lists allowed) are issue numbers: the branch name is derived from the first issue's
# title unless a branch name follows them. --force skips ISSUE_GUARD_CMD. --background runs POST_CREATE_CMD detached
# whatever POST_CREATE_MODE says. --no-install skips POST_CREATE_CMD (setup=skipped). --no-hook-setup runs it with
# HUSKY=0 and LEFTHOOK=0 set, and undoes any change it makes to the repository's core.hooksPath (the shared git config,
# so a hooks manager the install switches on would otherwise reach every checkout). Exit codes and the result line:
# see worktree-lib.sh.
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-lib.sh"
# shellcheck source=skills/worktree/bin/worktree-lib.sh
. "$LIB" || { echo "worktree-lib missing or broken" >&2; exit 2; }
WT_SCRIPT="worktree-create"

FORCE=0; BASE_UPDATE=1; BACKGROUND=0; NO_INSTALL=0; NO_HOOK_SETUP=0; ISSUES=""; BRANCH=""; OPTS_DONE=0
usage() { wt_die 2 usage "usage: worktree-create.sh [--config F] [--force] [--no-base-update] [--background] [--no-install] [--no-hook-setup] <branch> | <issue>... [<branch>]${1:+ ($1)}"; }
while [ "$#" -gt 0 ]; do
  a="$1"; shift
  if [ "$OPTS_DONE" -eq 0 ]; then
    case "$a" in
      --config) [ "$#" -gt 0 ] || usage "--config needs a file"; WT_CONFIG="$1"; shift; continue ;;
      --force) FORCE=1; continue ;;
      --no-base-update) BASE_UPDATE=0; continue ;;
      --background) BACKGROUND=1; continue ;;
      --no-install) NO_INSTALL=1; continue ;;
      --no-hook-setup) NO_HOOK_SETUP=1; continue ;;
      --) OPTS_DONE=1; continue ;;
      -*) usage "unknown option $a" ;;
    esac
  fi
  [ -n "$a" ] || usage "empty argument"
  [ -z "$BRANCH" ] || usage "extra argument after the branch name: $a"
  case "$a" in
    *[!0-9,]*) BRANCH="$a" ;;
    ,*|*,|*,,*) usage "not an issue list: $a" ;;
    *)
      for n in $(printf '%s' "$a" | tr ',' ' '); do
        case "$n" in 0*) usage "not an issue number: $n" ;; esac
        case " $ISSUES " in *" $n "*) usage "issue $n given twice" ;; esac
        ISSUES="${ISSUES:+$ISSUES }$n"
      done ;;
  esac
done
[ -n "$ISSUES" ] || [ -n "$BRANCH" ] || usage
# The first issue as typed names the branch; the set itself has no order, so it is recorded sorted.
FIRST_ISSUE="${ISSUES%% *}"
ISSUES=$(printf '%s\n' $ISSUES | sort -n | tr '\n' ' '); ISSUES="${ISSUES% }"
NUM_PREFIX=$(printf '%s' "$ISSUES" | tr ' ' '-')

wt_load_config
wt_repo_init
[ "$BACKGROUND" -eq 0 ] || WT_POST_MODE=background

# --- Branch name -------------------------------------------------------------------------------------------------
if [ -n "$ISSUES" ] && [ -z "$BRANCH" ]; then
  TITLE_CMD=$(wt_cfg ISSUE_TITLE_CMD "")
  SLUG=""
  if [ -n "$TITLE_CMD" ]; then
    TITLE=$(ISSUE="$FIRST_ISSUE" ISSUES="$ISSUES" wt_slot "$TITLE_CMD" 2>/dev/null); rc=$?
    [ "$rc" -eq 0 ] || wt_die 3 title-failed "ISSUE_TITLE_CMD failed for issue $FIRST_ISSUE (exit $rc); nothing was created"
    [ -n "$TITLE" ] || wt_die 3 title-failed "ISSUE_TITLE_CMD printed nothing for issue $FIRST_ISSUE; nothing was created"
    case "$TITLE" in *"
"*) wt_die 3 title-failed "ISSUE_TITLE_CMD printed more than one line for issue $FIRST_ISSUE; nothing was created" ;; esac
    # Lowercase, everything else to spaces, filler words dropped, first six words.
    SLUG=$(printf '%s\n' "$TITLE" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9]/ /g' | awk '
      BEGIN { split("the a an to of for and or is in on with", f, " "); for (i in f) skip[f[i]] = 1 }
      { for (i = 1; i <= NF && n < 6; i++) if (!($i in skip)) w[n++] = $i }
      END { for (i = 0; i < n; i++) printf "%s%s", (i ? "-" : ""), w[i]; printf "\n" }')
  fi
  # The cap applies to the slug; the number prefix is never cut.
  ROOM=$((WT_MAX_LEN - ${#NUM_PREFIX} - 1))
  if [ -n "$SLUG" ] && [ "$ROOM" -gt 0 ]; then
    BRANCH="$NUM_PREFIX-$(printf '%s' "$SLUG" | cut -c1-"$ROOM")"
    BRANCH="${BRANCH%-}"
  else
    BRANCH="$NUM_PREFIX"
  fi
  echo "Branch: $BRANCH"
fi
case "$BRANCH" in -*) usage "a branch name cannot start with '-': $BRANCH" ;; esac
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || usage "not a valid branch name: $BRANCH"
[ "$BRANCH" != "$WT_BASE" ] || wt_die 1 is-base "$BRANCH is the base branch; it keeps its own working copy"
FOLDER=$(wt_folder_for_branch "$BRANCH")
WT_PATH="$WT_PARENT/$FOLDER"

# --- Guard (issue flow): before anything is created --------------------------------------------------------------
if [ -n "$ISSUES" ]; then
  GUARD_CMD=$(wt_cfg ISSUE_GUARD_CMD "")
  if [ -z "$GUARD_CMD" ]; then
    echo "guard: not configured"
  elif [ "$FORCE" -eq 1 ]; then
    echo "guard: skipped (--force)"
  else
    for n in $ISSUES; do
      ISSUE="$n" ISSUES="$ISSUES" BRANCH="$BRANCH" wt_slot "$GUARD_CMD"; rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "STOP: the guard refused issue $n (exit $rc). Nothing was created. Re-run with --force only on the user's say-so."
        wt_result FAIL guard-refused "issue=$n"; exit 1
      fi
    done
  fi
fi

# --- Lock on the folder name: covers the checks through the marker write -----------------------------------------
LOCK="$WT_COMMON/worktree-locks/$FOLDER"; HAVE_LOCK=0
release_lock() { [ "$HAVE_LOCK" -eq 1 ] && rmdir "$LOCK" 2>/dev/null; HAVE_LOCK=0; return 0; }
trap release_lock EXIT
mkdir -p "$WT_COMMON/worktree-locks" 2>/dev/null
if ! mkdir "$LOCK" 2>/dev/null; then
  # A lock older than ten minutes belongs to a create that died. Take it over by rename (one racer wins), then retry once.
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ] && mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
    # Re-judge what was actually moved: another racer may have taken over and re-created the lock in between.
    if [ -n "$(find "$LOCK.stale.$$" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rm -rf "$LOCK.stale.$$"
    elif [ ! -e "$LOCK" ]; then mv "$LOCK.stale.$$" "$LOCK" 2>/dev/null || rm -rf "$LOCK.stale.$$"
    else rm -rf "$LOCK.stale.$$"; fi
  fi
  mkdir "$LOCK" 2>/dev/null || wt_die 1 create-in-progress "another create holds $LOCK; if none is running, it clears itself after ten minutes"
fi
HAVE_LOCK=1

git worktree prune >/dev/null 2>&1
if [ -e "$WT_PATH" ]; then
  echo "STOP: $WT_PATH already exists; this script never creates into an existing folder"
  wt_result FAIL path-exists "path=$WT_PATH"; exit 1
fi

HELD=$(wt_worktree_for_branch "$BRANCH")
[ -z "$HELD" ] || wt_die 1 branch-exists "$BRANCH is already checked out at $HELD"

# --- Remote reads ------------------------------------------------------------------------------------------------
ON_REMOTE=0
if [ -n "$WT_REMOTE" ]; then
  git config --get "remote.$WT_REMOTE.url" >/dev/null 2>&1 \
    || wt_die 2 config-remote "this repository has no remote named $WT_REMOTE; fix BASE_REMOTE (set it empty for a repository with no remote)"
  # A bare clone made with `git clone --bare` has no fetch refspec, so fetches update nothing under refs/remotes.
  if [ -z "$(git config --get-all "remote.$WT_REMOTE.fetch" 2>/dev/null)" ]; then
    git config "remote.$WT_REMOTE.fetch" "+refs/heads/*:refs/remotes/$WT_REMOTE/*" \
      || wt_die 3 fetch-failed "could not repair the fetch refspec for $WT_REMOTE"
    echo "fetch refspec repaired for $WT_REMOTE"
  fi
  ERR=$(git fetch -q "$WT_REMOTE" "+refs/heads/$WT_BASE:refs/remotes/$WT_REMOTE/$WT_BASE" 2>&1) \
    || wt_die 3 fetch-failed "could not fetch $WT_BASE from $WT_REMOTE: $ERR"
  # The full ref name: a bare name matches any ref that ends with it.
  git ls-remote --exit-code "$WT_REMOTE" "refs/heads/$BRANCH" >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) ON_REMOTE=1
       ERR=$(git fetch -q "$WT_REMOTE" "+refs/heads/$BRANCH:refs/remotes/$WT_REMOTE/$BRANCH" 2>&1) \
         || wt_die 3 fetch-failed "could not fetch $BRANCH from $WT_REMOTE: $ERR" ;;
    2) ON_REMOTE=0 ;;
    *) wt_die 3 ls-remote-failed "could not ask $WT_REMOTE whether $BRANCH exists (exit $rc); a failed read is not 'absent'" ;;
  esac
fi
git rev-parse --verify -q "$WT_BASE_REF^{commit}" >/dev/null 2>&1 \
  || wt_die 1 no-commits "$WT_BASE has no commits to branch from (${WT_BASE_REF})"

LOCAL=0
git rev-parse --verify -q "refs/heads/$BRANCH" >/dev/null 2>&1 && LOCAL=1
if [ "$LOCAL" -eq 1 ] && [ "$ON_REMOTE" -eq 0 ]; then
  wt_die 1 branch-exists "a local branch $BRANCH already exists and is not on the remote; this script does not guess what it holds"
fi

# --- Create ------------------------------------------------------------------------------------------------------
# Never pre-create the folder: `git worktree add` creates it as part of the checkout. Its parent, the repository's
# default worktree folder, is made here the first time.
if [ "$WT_PARENT_NEW" -eq 1 ]; then
  mkdir -p "$WT_PARENT" 2>/dev/null || wt_die 2 config-parent-dir "cannot create the worktree folder $WT_PARENT (set WORKTREE_PARENT_DIR to choose another)"
fi
if [ "$LOCAL" -eq 1 ]; then
  # A local branch of the same name as the remote one: usable only when one contains the other.
  R_REF="refs/remotes/$WT_REMOTE/$BRANCH"
  if git merge-base --is-ancestor "refs/heads/$BRANCH" "$R_REF" 2>/dev/null; then LOCAL_STATE=behind
  elif git merge-base --is-ancestor "$R_REF" "refs/heads/$BRANCH" 2>/dev/null; then LOCAL_STATE=ahead
  else wt_die 1 branch-exists "the local branch $BRANCH and $WT_REMOTE/$BRANCH have diverged; reconcile them by hand first"; fi
  # Bring the branch to the remote tip and set its upstream BEFORE the checkout (it is checked out nowhere, and the
  # move is a pure fast-forward), so a failure here refuses with nothing created instead of leaving a stale checkout.
  if [ "$LOCAL_STATE" = "behind" ]; then
    git branch -f "$BRANCH" "$R_REF" >/dev/null 2>&1 \
      || wt_die 1 branch-exists "could not fast-forward the local branch $BRANCH to $WT_REMOTE/$BRANCH"
  fi
  git branch -q --set-upstream-to="$WT_REMOTE/$BRANCH" "$BRANCH" >/dev/null 2>&1 \
    || wt_die 1 branch-exists "could not set the upstream of the local branch $BRANCH to $WT_REMOTE/$BRANCH"
  ERR=$(git worktree add "$WT_PATH" "$BRANCH" 2>&1); rc=$?
elif [ "$ON_REMOTE" -eq 1 ]; then
  ERR=$(git worktree add --track -b "$BRANCH" "$WT_PATH" "refs/remotes/$WT_REMOTE/$BRANCH" 2>&1); rc=$?
else
  # --no-track: otherwise the new branch's upstream is the base, and "unpushed" checks and plain pushes aim at it.
  ERR=$(git worktree add --no-track -b "$BRANCH" "$WT_PATH" "$WT_BASE_REF" 2>&1); rc=$?
fi
if [ "$rc" -ne 0 ]; then
  # git removes what it began on failure; anything still at the path was put there by someone else in the meantime.
  if [ -e "$WT_PATH" ]; then echo "STOP: git could not create $WT_PATH: $ERR"; wt_result FAIL path-exists "path=$WT_PATH"; exit 1; fi
  # A failed `add -b` can leave the branch it just made. Remove it only when this run created it and it still sits
  # exactly where it was started, so a retry is not refused by our own leftover.
  if [ "$LOCAL" -eq 0 ] && [ "$ON_REMOTE" -eq 0 ] \
     && [ "$(git rev-parse -q --verify "refs/heads/$BRANCH" 2>/dev/null)" = "$(git rev-parse -q --verify "$WT_BASE_REF" 2>/dev/null)" ]; then
    git branch -D "$BRANCH" >/dev/null 2>&1
  fi
  wt_die 1 add-failed "git could not create the worktree: $ERR"
fi
if wt_stop_after add; then HAVE_LOCK=0; exit 99; fi   # test seam: a create killed here leaves its lock behind

FAILED=""; DETAIL=""
fail_step() { [ -n "$FAILED" ] || FAILED="$1"; DETAIL="${DETAIL:+$DETAIL }$2"; }

if [ -n "$ISSUES" ]; then
  MARKER=$(wt_gitpath "$WT_PATH" worktree-issues) && printf '%s\n' "$NUM_PREFIX" > "$MARKER" || fail_step marker-failed marker=failed
fi
release_lock
if wt_stop_after marker; then exit 99; fi

# --- Copy configured files from the calling checkout -------------------------------------------------------------
set -f   # entries are names, not patterns
for f in $(wt_cfg COPY_FILES ""); do
  if [ -z "$WT_TOP" ] || [ ! -e "$WT_TOP/$f" ]; then echo "warning: $f not found in ${WT_TOP:-this directory}; not copied"; continue; fi
  if [ -e "$WT_PATH/$f" ]; then echo "note: $f already exists in the new worktree; left as it is"; continue; fi
  if mkdir -p "$(dirname "$WT_PATH/$f")" && cp -R "$WT_TOP/$f" "$WT_PATH/$f"; then echo "copied $f"; else fail_step copy-failed copy=failed; fi
done
set +f
if wt_stop_after copy; then exit 99; fi

# --- Post-create command -----------------------------------------------------------------------------------------
POST_CMD=$(wt_cfg POST_CREATE_CMD "")
SETUP=none
# --no-hook-setup: the install may not switch on git hooks. core.hooksPath lives in the shared config, so a change made
# from this worktree reaches every checkout of the repository; it is put back as it was, and the change is reported.
HP_BEFORE=$(git config --local --get core.hooksPath 2>/dev/null); HP_HAD=$?
keep_hooks_path() {
  [ "$NO_HOOK_SETUP" -eq 1 ] || return 0
  hp_now=$(git -C "$WT_PATH" config --local --get core.hooksPath 2>/dev/null); hp_has=$?
  [ "$hp_has:$hp_now" = "$HP_HAD:$HP_BEFORE" ] && return 0
  if [ "$HP_HAD" -eq 0 ]; then git -C "$WT_PATH" config --local core.hooksPath "$HP_BEFORE"
  else git -C "$WT_PATH" config --local --unset-all core.hooksPath; fi \
    && echo "post-create changed core.hooksPath (to '${hp_now}'); put back as it was (--no-hook-setup)" \
    || { echo "post-create changed core.hooksPath (to '${hp_now}') and it could not be put back"; return 1; }
}
# The off switches go to the install only (a subshell), never to the push and claim that follow.
hooks_off() { [ "$NO_HOOK_SETUP" -eq 0 ] || export HUSKY=0 LEFTHOOK=0; }
if [ -z "$POST_CMD" ]; then
  echo "post-create: none configured (no exit-status file)"
elif [ "$NO_INSTALL" -eq 1 ]; then
  SETUP=skipped; echo "post-create: skipped (--no-install): $POST_CMD"
else
  export WORKTREE_PATH="$WT_PATH" BRANCH ISSUES
  if [ "$WT_POST_MODE" = "wait" ]; then
    if ( cd "$WT_PATH" && hooks_off && wt_slot "$POST_CMD" </dev/null ); then SETUP=ok; else SETUP=failed; fail_step post-create-failed post_create=failed; fi
    keep_hooks_path || fail_step post-create-failed hooks_path=changed
  else
    P_LOG=$(wt_gitpath "$WT_PATH" worktree-post-create.log); P_RC=$(wt_gitpath "$WT_PATH" worktree-post-create.rc)
    P_PID=$(wt_gitpath "$WT_PATH" worktree-post-create.pid)
    if [ -n "$P_LOG" ] && [ -n "$P_RC" ] && [ -n "$P_PID" ]; then
      rm -f "$P_RC"
      # A changed hooks path that cannot be put back turns a clean install into exit 1 in the status file.
      ( cd "$WT_PATH" && hooks_off && { bash -c "$POST_CMD"; rc=$?; keep_hooks_path || [ "$rc" -ne 0 ] || rc=1; echo "$rc" > "$P_RC"; } ) </dev/null >"$P_LOG" 2>&1 &
      echo "$!" > "$P_PID"
      SETUP=background
      echo "post-create running in the background: log $P_LOG, exit status will be in $P_RC"
    else
      SETUP=failed; fail_step post-create-failed post_create=failed
    fi
  fi
fi
if wt_stop_after post-create; then exit 99; fi

# --- Push and claim (issue flow) ---------------------------------------------------------------------------------
PUSHED=0
if [ -n "$ISSUES" ]; then
  PUSH_OK=1
  if [ "$WT_PUSH" -eq 1 ] && [ -n "$WT_REMOTE" ]; then
    if ERR=$(git -C "$WT_PATH" push -q -u "$WT_REMOTE" "$BRANCH" 2>&1); then PUSHED=1
    else PUSH_OK=0; echo "push failed: $ERR"; fail_step push-failed "push=failed claim=skipped"; fi
  fi
  if wt_stop_after push; then exit 99; fi
  CLAIM_CMD=$(wt_cfg ISSUE_CLAIM_CMD "")
  if [ -n "$CLAIM_CMD" ] && [ "$PUSH_OK" -eq 1 ]; then
    for n in $ISSUES; do
      if ISSUE="$n" ISSUES="$ISSUES" BRANCH="$BRANCH" WORKTREE_PATH="$WT_PATH" wt_slot "$CLAIM_CMD"; then echo "claimed issue $n"
      else echo "warning: ISSUE_CLAIM_CMD failed for issue $n"; fail_step claim-failed claim=failed; fi
    done
  fi
  if wt_stop_after claim; then exit 99; fi
fi

# --- Bring the local base forward (never decides the exit) -------------------------------------------------------
BASE_NOTE="skipped"
if [ "$BASE_UPDATE" -eq 1 ] && [ -n "$WT_REMOTE" ]; then
  BASE_WT=$(wt_worktree_for_branch "$WT_BASE")
  if [ -n "$BASE_WT" ]; then
    BASE_DIRTY=$(wt_dirty_count "$BASE_WT" --untracked-files=no) || BASE_DIRTY=unreadable
    if [ "$BASE_DIRTY" != "0" ]; then
      BASE_NOTE="skipped-dirty"; echo "local $WT_BASE not updated: $BASE_WT has uncommitted changes (or its status cannot be read)"
    elif git -C "$BASE_WT" merge -q --ff-only "refs/remotes/$WT_REMOTE/$WT_BASE" >/dev/null 2>&1; then
      BASE_NOTE="updated"
    else
      BASE_NOTE="not-fast-forward"; echo "local $WT_BASE not updated: it has diverged from $WT_REMOTE/$WT_BASE"
    fi
  elif git rev-parse --verify -q "refs/heads/$WT_BASE" >/dev/null 2>&1; then
    if git fetch -q "$WT_REMOTE" "$WT_BASE:$WT_BASE" >/dev/null 2>&1; then BASE_NOTE="updated"
    else BASE_NOTE="not-fast-forward"; echo "local $WT_BASE not updated: it has diverged from $WT_REMOTE/$WT_BASE"; fi
  else
    BASE_NOTE="no-local-base"
  fi
fi

HEAD_SHA=$(git -C "$WT_PATH" rev-parse --short HEAD 2>/dev/null)
echo "Worktree: $WT_PATH (branch $BRANCH at ${HEAD_SHA:-unknown})"
echo "cd $WT_PATH"
if [ -n "$FAILED" ]; then
  echo "STOP: the worktree exists at $WT_PATH, but a later step failed ($DETAIL). Fix that step by hand or remove the worktree."
  wt_result FAIL "$FAILED" "path=$WT_PATH" "branch=$BRANCH" "$DETAIL"; exit 6
fi
wt_result PASS created "path=$WT_PATH" "branch=$BRANCH" "base=$WT_BASE" "attached=$ON_REMOTE" "pushed=$PUSHED" "setup=$SETUP" "base_update=$BASE_NOTE" ${NUM_PREFIX:+"issues=$NUM_PREFIX"}
exit 0
