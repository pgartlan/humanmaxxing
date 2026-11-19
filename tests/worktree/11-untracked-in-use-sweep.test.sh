#!/usr/bin/env bash
# Removal safety that no flag overrides, and the bulk sweep:
#   - untracked files are a finding even when git is configured to hide them (status.showUntrackedFiles=no), and git's
#     own remove check never deletes them silently;
#   - a process sitting in the folder, or a mount point at or below it, refuses the remove whatever the flags; a
#     process list or mount table that cannot be read stops it (exit 3), never passes;
#   - the sweep skips in-use, recently edited, uncommitted, setup-running, unmerged and mounted worktrees, removes only
#     the approved names that are still candidates, and prints a restore line.
. "$(dirname "$0")/../lib.sh"
RM='WORKTREE-RESULT worktree-remove'
SW='WORKTREE-RESULT worktree-sweep'
rm_() { run bash "$B/worktree-remove.sh" "$@"; }
sw_() { run bash "$B/worktree-sweep.sh" "$@"; }
mkwt() { git worktree add -q --no-track -b "$1" "$FIX/$1" origin/main || exit 2; }
# age every file in a worktree (git's .git file included) so the recent-edits rule does not see it
# (an absolute date: `touch -t` is the same on GNU and BSD)
age() { find "$1" -exec touch -t 202001010000 {} + || exit 2; }
BGPIDS=""; BGN=0
cleanup_bg() { for p in $BGPIDS; do kill "$p" 2>/dev/null; done; BGPIDS=""; }
# bg_in <dir> — start a process whose working directory is <dir>, and return once it is there (it writes a marker
# outside <dir> after the cd; observed, not a fixed sleep)
bg_in() {
  local i=0 m; BGN=$((BGN + 1)); m="$T_TMP/ready.$BGN"
  ( cd "$1" && : > "$m" && exec sleep 60 ) & BGPIDS="$BGPIDS $!"
  while [ "$i" -lt 100 ] && [ ! -e "$m" ]; do sleep 0.1; i=$((i + 1)); done
}
# lib.sh's EXIT trap removes the temporary folder: chain onto it, never replace it.
trap 'cleanup_bg; rm -rf "$T_TMP"' EXIT

# --- untracked files hidden by the user's git config ------------------------------------------------------------------------
t_wt_fixture u1
mkwt hid
echo secret > "$FIX/hid/notes.txt"
git config status.showUntrackedFiles no
check "setup: git's own status hides the untracked file" test -z "$(git -C "$FIX/hid" status --porcelain)"
run bash "$B/worktree-list.sh"
expect_out "/hid[[:space:]]+hid[[:space:]]+[0-9a-f]{7,40}[[:space:]]+dirty" "list shows it dirty too"
rm_ check hid
expect 5 "$RM FAIL findings( [a-z-]+=[^ ]*)* dirty=1 " "an untracked file is a finding even with showUntrackedFiles=no"
rm_ remove hid
expect 5 "$RM FAIL findings" "remove stops on it"
check "the untracked file is still there" test -e "$FIX/hid/notes.txt"
rm_ remove hid --confirmed
expect 5 "$RM FAIL findings" "--confirmed alone does not discard it: --discard-uncommitted is still needed"
check "and it is still there" test -e "$FIX/hid/notes.txt"
mkdir -p "$FIX/hid/deep/er" && echo x > "$FIX/hid/deep/er/a" && echo y > "$FIX/hid/deep/er/b"
rm_ check hid
expect 5 "dirty=3 " "untracked files are counted one by one, not one per folder"
git config status.showUntrackedFiles normal
rm_ remove hid --confirmed --discard-uncommitted
expect 0 "$RM PASS removed" "with the user's answer it goes"

# --- a process in the folder ------------------------------------------------------------------------------------------------
t_wt_fixture u2
mkwt busy
bg_in "$FIX/busy/"
mkdir -p "$FIX/busy/sub"; bg_in "$FIX/busy/sub"
mkwt busy-2
rm_ check busy
expect 1 "$RM FAIL in-use" "a process sitting in the folder: refused"
rm_ remove busy --confirmed --discard-uncommitted --delete-branch --discard-commits
expect 1 "$RM FAIL in-use" "no flag gets past it"
check "the folder is still there" test -d "$FIX/busy"
rm_ check busy-2
expect 0 "$RM PASS clean" "a sibling folder whose name only starts the same is not in use"
cleanup_bg; BGPIDS=""; wait 2>/dev/null
rm_ remove busy --delete-branch
expect 0 "$RM PASS removed" "once the process ends, the remove goes through"

# --- the process list or the mount table cannot be read: stop, never pass -----------------------------------------------------
mkwt blind
export WORKTREE_TEST_MODE=1
mkdir -p "$FIX/emptyproc/self"
WORKTREE_TEST_PROC_ROOT="$FIX/emptyproc" rm_ check blind
expect 3 "$RM FAIL live-unknown" "a process scan that does not see this script itself is untrustworthy: exit 3"
WORKTREE_TEST_PS_USERS='echo "4242 someoneelse"' rm_ check blind
expect 3 "$RM FAIL live-unknown" "another person's processes, invisible to this account: exit 3"
WORKTREE_TEST_PS_USERS='echo "0 root"; echo "2 daemon"; echo "65534 nobody"' rm_ check blind
expect 0 "$RM PASS clean" "root, system and nobody processes do not make the list partial"
WORKTREE_TEST_PS_USERS='exit 1' rm_ check blind
expect 3 "$RM FAIL live-unknown" "a failed owner scan: exit 3"
blindp="$(cd "$FIX/blind" && pwd -P)"
printf '36 25 0:32 / %s/cache rw - tmpfs tmpfs rw\n' "$blindp" > "$FIX/mi"
WORKTREE_TEST_MOUNTINFO="$FIX/mi" rm_ remove blind --confirmed --discard-uncommitted --delete-branch
expect 1 "$RM FAIL mount-below" "a mount point below the folder: refused whatever the flags"
WORKTREE_TEST_MOUNTINFO="$FIX/no-such-mountinfo" rm_ check blind
expect 3 "$RM FAIL mount-unknown" "an unreadable mount table: exit 3"
WORKTREE_TEST_UNAME=MINGW64_NT-10.0 rm_ check blind
expect 5 "$RM FAIL findings.* in-use-unknown=1" "Git Bash cannot see native programs: a finding for the user, not exit 3 and not clean"
WORKTREE_TEST_UNAME=CYGWIN_NT-10.0 rm_ remove blind
expect 5 "in-use-unknown=1" "Cygwin too: remove stops for the user's answer"
check "nothing removed without the answer" test -d "$FIX/blind"
WORKTREE_TEST_PROC_ROOT="$FIX/emptyproc" WORKTREE_TEST_MODE=0 rm_ check blind
expect 0 "$RM PASS clean" "the seams do nothing outside test mode"
unset WORKTREE_TEST_MODE
check "the folder survived all of it" test -d "$FIX/blind"

# --- sweep ------------------------------------------------------------------------------------------------------------------
t_wt_fixture s1
for b in done1 done2 fresh dirty unm busy mnt; do mkwt "$b"; done
echo x > "$FIX/dirty/scratch.txt"
( cd "$FIX/unm" && echo u > u && git add u && git commit -qm unmerged ) || exit 2
for b in done1 done2 dirty unm busy mnt; do age "$FIX/$b"; done
bg_in "$FIX/busy"
mntp="$(cd "$FIX/mnt" && pwd -P)"
cat /proc/self/mountinfo > "$FIX/mi" 2>/dev/null || : > "$FIX/mi"
printf '36 25 0:32 / %s rw - tmpfs tmpfs rw\n' "$mntp" >> "$FIX/mi"
export WORKTREE_TEST_MODE=1 WORKTREE_TEST_MOUNTINFO="$FIX/mi"
sw_
expect 0 "$SW PASS listed candidates=2 skipped=5" "the list: two candidates, five skips"
expect_out "^candidate	done1	" "a clean, merged, idle worktree is a candidate"
expect_out "^candidate	done2	" "so is the second"
expect_out "^skip	fresh	.*	recent-edits$" "edited in the last 72 hours: skipped"
expect_out "^skip	dirty	.*	uncommitted$" "an untracked file: skipped"
expect_out "^skip	unm	.*	unmerged$" "a commit the base lacks: skipped"
expect_out "^skip	busy	.*	in-use$" "a process in it: skipped"
expect_out "^skip	mnt	.*	mount-below$" "a mount point: skipped"
refute_out "	main	" "the base branch's folder is never listed"
git -C "$PRIMARY" checkout -q -b side || exit 2
t_wt_run_in "$FIX/fresh" bash "$PRIMARY/$B/worktree-sweep.sh"
expect 0 "$SW PASS listed" "a sweep run from another worktree"
refute_out "	side	" "the main working tree is never listed, even off the base branch"
git -C "$PRIMARY" checkout -q main || exit 2
check "the list removes nothing" test -d "$FIX/done1"

git config status.showUntrackedFiles no
sw_
expect_out "^skip	dirty	.*	uncommitted$" "hidden untracked files still make it uncommitted"
git config status.showUntrackedFiles normal

sw_ done1 done2
expect 2 "$SW FAIL usage" "branch names without --confirmed are a usage error"
echo late > "$FIX/done2/late.txt"
sw_ --confirmed done1 done2 dirty no-such
expect 0 "$SW PASS swept removed=1 not-swept=3 failed=0" "only what is still a candidate is swept"
expect_out "^removed	done1	.*	restore: git branch done1 [0-9a-f]{40}$" "a removed branch prints its restore line"
expect_out "^not-swept	done2	.*	recent-edits$" "a candidate edited since the list is re-judged and kept"
expect_out "^not-swept	dirty	.*	uncommitted$" "an approved name that is not a candidate is never swept in"
expect_out "^not-swept	no-such	-	not-found$" "an approved name with no worktree is reported"
check "done1's folder is gone" test ! -e "$FIX/done1"
check "done1's branch is gone" test -z "$(git for-each-ref refs/heads/done1)"
check "done2 is kept" test -e "$FIX/done2/late.txt"
check "the unmerged branch is untouched" git rev-parse -q --verify refs/heads/unm
check "no remote branch was touched" test "$(git ls-remote origin 'refs/heads/*' | wc -l | tr -d ' ')" = 1

mkdir -p "$FIX/emptyproc/self"
WORKTREE_TEST_PROC_ROOT="$FIX/emptyproc" sw_ --confirmed done2
expect 3 "$SW FAIL live-unknown" "an untrustworthy process list stops the sweep before anything is removed"
check "and done2 is still there" test -d "$FIX/done2"
age "$FIX/done2"; rm -f "$FIX/done2/late.txt"
WORKTREE_TEST_UNAME=MSYS_NT-10.0 sw_
expect 0 "$SW PASS listed candidates=0 " "Git Bash: nothing is a candidate"
expect_out "^skip	done2	.*	in-use-unknown$" "an otherwise clean worktree is skipped as in-use-unknown"
WORKTREE_TEST_UNAME=MSYS_NT-10.0 sw_ --confirmed done2
expect_out "^not-swept	done2	.*	in-use-unknown$" "and an approved name is not swept there either"
check "done2 survives" test -d "$FIX/done2"
unset WORKTREE_TEST_MODE WORKTREE_TEST_MOUNTINFO
cleanup_bg; BGPIDS=""

t_done
