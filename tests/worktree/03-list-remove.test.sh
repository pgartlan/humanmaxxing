#!/usr/bin/env bash
# worktree-list and worktree-remove: the list format, every remove finding and gate, branch deletion rules, and the
# "nothing half-removed" guarantee. Worktrees are built with plain git so these tests do not depend on create.
. "$(dirname "$0")/../lib.sh"
RL='WORKTREE-RESULT worktree-list'
RM='WORKTREE-RESULT worktree-remove'
rm_() { run bash "$B/worktree-remove.sh" "$@"; }
# findings line: dirty, unpushed, unmerged, setup-running in that order; other k=v fields may sit around them
fl() { printf '%s FAIL findings( [a-z-]+=[^ ]*)* dirty=%s unpushed=%s unmerged=%s setup-running=%s' "$RM" "$1" "$2" "$3" "$4"; }
removed() { printf '%s PASS removed( [a-z-]+=[^ ]*)* branch-deleted=%s' "$RM" "$1"; }
folder_of() { printf '%s' "$1" | tr / -; }
mkwt() { git worktree add -q --no-track -b "$1" "$FIX/$(folder_of "$1")" origin/main || exit 2; }
wtcommit() { local d; d="$FIX/$(folder_of "$1")"; echo "$2" > "$d/$2"; git -C "$d" add "$2" && git -C "$d" commit -qm "c $2" || exit 2; }
wtpush() { git -C "$FIX/$(folder_of "$1")" push -q origin "$1" || exit 2; }
branch_exists() { git rev-parse -q --verify "refs/heads/$1" >/dev/null; }
# squash the branch's content onto the remote base from the second clone (a different commit with the same change)
squash_onto_main() {
  [ -d "$FIX/other" ] || git clone -q "$ORIGIN" "$FIX/other" || exit 2
  ( cd "$FIX/other" && git fetch -q origin && git checkout -q -B main origin/main && echo "$1" > "$1" && git add "$1" \
    && git commit -qm "squash $1" && git push -q origin main ) || exit 2
}
ff_main_to() {
  [ -d "$FIX/other" ] || git clone -q "$ORIGIN" "$FIX/other" || exit 2
  ( cd "$FIX/other" && git fetch -q origin && git checkout -q -B main origin/main && git merge -q --ff-only "origin/$1" && git push -q origin main ) || exit 2
}

# --- list -----------------------------------------------------------------------------------------------------------------------
t_wt_fixture l1 "ISSUE_TITLE_CMD=echo Fix login"
run bash "$B/worktree-create.sh" 7
expect 0 'WORKTREE-RESULT worktree-create PASS' "setup: an issue worktree through create"
iw="$FIX/7-fix-login"
mkwt feat/plain
run bash "$B/worktree-list.sh"
expect 0 "$RL PASS" "list passes"
check "one data line per worktree" test "$(printf '%s\n' "$OUT" | grep -Ec '[[:space:]](clean|dirty)([[:space:]]|$)')" = "$(t_wt_count)"
expect_out "$FIXP/primary[[:space:]]+main[[:space:]]+[0-9a-f]{7,40}[[:space:]]+clean" "the primary: path, branch, sha, clean"
expect_out "/feat-plain[[:space:]]+feat/plain[[:space:]]+[0-9a-f]{7,40}[[:space:]]+clean" "a plain sibling: its branch with the slash"
expect_out "/7-fix-login[[:space:]]+7-fix-login[[:space:]]+[0-9a-f]{7,40}[[:space:]]+clean[[:space:]]+(issues=)?7([^0-9]|\$)" "an issue worktree shows its issue number"
echo x >> "$iw/README"
run bash "$B/worktree-list.sh"
expect_out "/7-fix-login[[:space:]]+7-fix-login[[:space:]]+[0-9a-f]{7,40}[[:space:]]+dirty" "a tracked modification flags dirty"
git -C "$iw" checkout -q README
echo u > "$FIX/feat-plain/untracked.txt"
run bash "$B/worktree-list.sh"
expect_out "/feat-plain[[:space:]]+feat/plain[[:space:]]+[0-9a-f]{7,40}[[:space:]]+dirty" "an untracked file flags dirty"
rm -f "$FIX/feat-plain/untracked.txt"
# The shipped example copied in with CRLF line ends (a Git for Windows checkout, core.autocrlf=true) is a working config.
cp .claude/skills/worktree/worktree.env "$FIX/wt-env.bak"
t_crlf "$T_ROOT/skills/worktree/worktree.env.example" .claude/skills/worktree/worktree.env
run bash "$B/worktree-list.sh"
expect 0 "$RL PASS" "list passes with a CRLF copy of worktree.env.example as worktree.env"
expect_out "$FIXP/primary[[:space:]]+main[[:space:]]+[0-9a-f]{7,40}[[:space:]]+dirty" "…and lists the primary (dirty: its worktree.env was just rewritten)"
cp "$FIX/wt-env.bak" .claude/skills/worktree/worktree.env
run bash "$B/worktree-list.sh" --bogus
expect 2 "$RL FAIL usage" "an unknown option is exit 2"
run bash "$B/worktree-list.sh" extra
expect 2 "$RL FAIL usage" "an extra argument is exit 2"

# the same list from the primary, a subdirectory, a sibling worktree
run bash "$B/worktree-list.sh"; base_out="$OUT"
mkdir -p .claude/sub
t_wt_run_in .claude/sub bash "$PRIMARY/$B/worktree-list.sh"
check "run from a subdirectory prints the same list" test "$OUT" = "$base_out"
t_wt_run_in "$FIX/feat-plain" bash "$PRIMARY/$B/worktree-list.sh"
check "run from a sibling worktree prints the same list" test "$OUT" = "$base_out"
t_wt_run_in "$iw/.claude" bash "$PRIMARY/$B/worktree-list.sh"
check "run from a subdirectory of a sibling prints the same list" test "$OUT" = "$base_out"

t_wt_bare_fixture l2
git worktree add -q --no-track -b feat/bare "$FIX/feat-bare" main
t_wt_run_in "$FIX/main" bash "$PRIMARY/$B/worktree-list.sh"; ob1="$OUT"; rc1=$RC
t_wt_run_in "$FIX/main/.claude" bash "$PRIMARY/$B/worktree-list.sh"; ob2="$OUT"
t_wt_run_in "$FIX/.bare" bash "$PRIMARY/$B/worktree-list.sh"; ob3="$OUT"; rc3=$RC
check "bare layout: list passes from a worktree" test "$rc1" = 0
check "bare layout: list passes from the bare root" test "$rc3" = 0
check "bare layout: subdirectory prints the same list" test "$ob1" = "$ob2"
check "bare layout: the bare root prints the same list" test "$ob1" = "$ob3"
check "bare layout: both worktrees are listed" test "$(printf '%s\n' "$ob3" | grep -Ec '/(main|feat-bare)[[:space:]]')" = 2

# --- remove: argument handling ---------------------------------------------------------------------------------------------------
t_wt_fixture r0
mkwt feat/c
rm_ ""
expect 2 "$RM FAIL usage" "an empty verb is a usage error"
rm_ remove
expect 2 "$RM FAIL usage" "remove without a branch is a usage error"
rm_ check
expect 2 "$RM FAIL usage" "check without a branch is a usage error"
rm_ wipe feat/c
expect 2 "$RM FAIL usage" "an unknown verb is a usage error"
rm_ remove ""
expect 2 "$RM FAIL usage" "an empty branch is a usage error"
rm_ remove -x
expect 2 "$RM FAIL usage" "a branch that looks like a flag is a usage error"
rm_ remove feat/c --bogus
expect 2 "$RM FAIL usage" "an unknown option is a usage error"
rm_ check feat/c extra
expect 2 "$RM FAIL usage" "a second branch is a usage error"
rm_ remove nosuch
expect 1 "$RM FAIL not-found" "no such worktree"
rm_ check nosuch
expect 1 "$RM FAIL not-found" "check: no such worktree"
rm_ remove feat-c
expect 1 "$RM FAIL not-found" "the target is a branch name: the folder name does not resolve"
check "nothing was removed by any of these" test -e "$FIX/feat-c/.git"

# --- clean, merged ---------------------------------------------------------------------------------------------------------------
rm_ check feat/c
expect 0 "$RM PASS clean" "a branch at the base tip is clean"
rm_ remove feat/c
expect 0 "$(removed 0)" "remove without --delete-branch"
check "the folder is gone" test ! -e "$FIX/feat-c"
check "git no longer lists it" test -z "$(git worktree list --porcelain | grep 'feat/c')"
check "the branch stays without --delete-branch" branch_exists feat/c
mkwt feat/d
rm_ remove feat/d --delete-branch
expect 0 "$(removed 1)" "remove --delete-branch on a merged branch"
check "the folder is gone (d)" test ! -e "$FIX/feat-d"
check "the branch is deleted" test -z "$(git for-each-ref refs/heads/feat/d)"

# --- refused outright ------------------------------------------------------------------------------------------------------------
rm_ remove main
expect 1 "$RM FAIL is-base" "the worktree holding the base branch is never removed"
check "the primary is intact" test -e "$PRIMARY/.git"
check "the base branch is intact" branch_exists main
rm_ remove main --confirmed --discard-uncommitted --delete-branch
expect 1 "$RM FAIL is-base" "no flag overrides is-base"
mkwt feat/h
t_wt_run_in "$FIX/feat-h" bash "$PRIMARY/$B/worktree-remove.sh" remove feat/h
expect 1 "$RM FAIL is-current" "a worktree cannot remove the one it is run from"
check "and it is still there" test -e "$FIX/feat-h/.git"
t_wt_run_in "$FIX/feat-h/.claude/skills" bash "$PRIMARY/$B/worktree-remove.sh" remove feat/h --confirmed --discard-uncommitted --delete-branch
expect 1 "$RM FAIL is-current" "a subdirectory of the target counts as the target, whatever the flags"
check "still there after the subdirectory attempt" test -e "$FIX/feat-h/.git"
mkwt feat/i
t_wt_run_in "$FIX/feat-i" bash "$PRIMARY/$B/worktree-remove.sh" remove feat/h
expect 0 "$(removed 0)" "run from ANOTHER sibling worktree, removing a clean one"
check "the target is gone" test ! -e "$FIX/feat-h"
check "the caller is intact" test -e "$FIX/feat-i/.git"
git worktree remove --force "$FIX/feat-i"

# --- dirty -----------------------------------------------------------------------------------------------------------------------
t_wt_fixture r1
mkwt feat/dirty
echo mod >> "$FIX/feat-dirty/README"; echo new > "$FIX/feat-dirty/new.txt"
rm_ check feat/dirty
expect 5 "$(fl 2 0 0 0)" "tracked + untracked changes: dirty=2"
rm_ remove feat/dirty
expect 5 "$(fl 2 0 0 0)" "remove without --confirmed stops at the findings"
check "nothing was removed (folder)" test -e "$FIX/feat-dirty/.git"
check "uncommitted work intact" grep -q mod "$FIX/feat-dirty/README"
check "untracked work intact" test -f "$FIX/feat-dirty/new.txt"
rm_ remove feat/dirty --confirmed
expect 5 "$(fl 2 0 0 0)" "--confirmed on a dirty tree is still exit 5"
check "still nothing removed" test -e "$FIX/feat-dirty/new.txt"
rm_ remove feat/dirty --discard-uncommitted
expect 5 "$(fl 2 0 0 0)" "--discard-uncommitted without --confirmed is exit 5"
check "still nothing removed (discard alone)" test -e "$FIX/feat-dirty/new.txt"
rm_ remove feat/dirty --confirmed --discard-uncommitted
expect 0 "$(removed 0)" "both flags remove a dirty worktree"
check "the folder is gone (dirty)" test ! -e "$FIX/feat-dirty"
check "the branch stays" branch_exists feat/dirty

# --- unpushed, unmerged ----------------------------------------------------------------------------------------------------------
mkwt feat/up
wtcommit feat/up u1.txt; wtcommit feat/up u2.txt
rm_ check feat/up
expect 5 "$(fl 0 2 1 0)" "two commits never pushed: unpushed=2, unmerged=1"
rm_ remove feat/up --delete-branch
expect 5 "$(fl 0 2 1 0)" "remove without --confirmed stops"
check "nothing removed, nothing deleted" test -e "$FIX/feat-up/.git" -a -n "$(git for-each-ref refs/heads/feat/up)"
rm_ remove feat/up --confirmed --delete-branch
expect 0 "$RM PASS removed( [a-z-]+=[^ ]*)* branch-deleted=0( [a-z-]+=[^ ]*)* kept=only-copy" "an unmerged, unpushed branch is never deleted, whatever the flags"
check "the worktree went" test ! -e "$FIX/feat-up"
check "the branch stayed with its commits" test "$(git rev-list --count origin/main..feat/up)" = 2

# a pushed branch with one more local commit: still the only copy of that commit
mkwt feat/part
wtcommit feat/part p1.txt; wtpush feat/part; wtcommit feat/part p2.txt
rm_ check feat/part
expect 5 "$(fl 0 1 1 0)" "pushed then one more commit: unpushed=1"
rm_ remove feat/part --confirmed --delete-branch
expect 0 "branch-deleted=0( [a-z-]+=[^ ]*)* kept=only-copy" "partially pushed: the branch is kept"
check "branch kept (part)" branch_exists feat/part

# --- pushed but unmerged ---------------------------------------------------------------------------------------------------------
mkwt feat/pu
wtcommit feat/pu pu.txt; wtpush feat/pu
rm_ check feat/pu
expect 5 "$(fl 0 0 1 0)" "pushed but not merged is a finding"
rm_ remove feat/pu --delete-branch
expect 5 "$(fl 0 0 1 0)" "no --confirmed: exit 5"
check "nothing half-removed (folder and branch intact)" test -e "$FIX/feat-pu/.git" -a -n "$(git for-each-ref refs/heads/feat/pu)"
rm_ remove feat/pu --confirmed --delete-branch
expect 0 "$(removed 1)" "confirmed: the commits exist on the remote branch, so the branch goes"
check "the local branch is deleted" test -z "$(git for-each-ref refs/heads/feat/pu)"
check "the remote branch is untouched" test -n "$(git ls-remote origin refs/heads/feat/pu)"
check "the folder is gone (pu)" test ! -e "$FIX/feat-pu"
mkwt feat/pu2
wtcommit feat/pu2 pu2.txt; wtpush feat/pu2
rm_ remove feat/pu2 --confirmed
expect 0 "$(removed 0)" "confirmed, no --delete-branch: the branch stays"
check "branch stays (pu2)" branch_exists feat/pu2

# --- merged on the remote while the local base is stale --------------------------------------------------------------------------
mkwt feat/e
wtcommit feat/e e.txt; wtpush feat/e
ff_main_to feat/e
stale="$(git rev-parse main)"
rm_ check feat/e
expect 0 "$RM PASS clean" "merged on the remote: judged against the fetched base, not a stale local one"
rm_ remove feat/e --delete-branch
expect 0 "$(removed 1)" "the branch is deleted even though the local base is stale"
check "the local base was not needed or moved by remove" test -n "$(git rev-parse main)"
check "the branch is gone" test -z "$(git for-each-ref refs/heads/feat/e)"
check "stale local base really was stale" test "$stale" != "$(t_wt_tip main)"

# --- squash-merged is a finding, and nothing is half-removed ---------------------------------------------------------------------
mkwt feat/sq
wtcommit feat/sq sq.txt; wtpush feat/sq
squash_onto_main sq.txt
rm_ check feat/sq
expect 5 "$(fl 0 0 1 0)" "squash-merged looks unmerged: a finding"
expect_out 'squash' "the finding says it may be squash-merged"
rm_ remove feat/sq --delete-branch
expect 5 "$(fl 0 0 1 0)" "remove stops at the finding"
check "folder intact" test -e "$FIX/feat-sq/.git"
check "branch intact" branch_exists feat/sq
check "remote branch intact" test -n "$(git ls-remote origin refs/heads/feat/sq)"
# squash-merged and dirty, both flags
echo mod >> "$FIX/feat-sq/README"; echo new > "$FIX/feat-sq/new.txt"
rm_ remove feat/sq --confirmed --delete-branch
expect 5 "$(fl 2 0 1 0)" "squash-merged and dirty: --confirmed alone is not enough"
check "still intact" test -e "$FIX/feat-sq/new.txt"
rm_ remove feat/sq --confirmed --discard-uncommitted --delete-branch
expect 0 "$(removed 1)" "squash-merged and dirty, both flags: removed, branch deleted (it is on the remote)"
check "folder gone (sq)" test ! -e "$FIX/feat-sq"
check "branch gone (sq)" test -z "$(git for-each-ref refs/heads/feat/sq)"

# --- stashes are not findings (the stack is shared) ------------------------------------------------------------------------------
mkwt feat/st
echo s >> "$FIX/feat-st/README"; git -C "$FIX/feat-st" stash -q
check "setup: a stash entry exists" test "$(git stash list | wc -l | tr -d ' ')" = 1
rm_ check feat/st
expect 0 "$RM PASS clean" "a stash entry is not a finding"
git stash drop -q
git worktree remove --force "$FIX/feat-st"

# --- setup still running / died ----------------------------------------------------------------------------------------------------
t_wt_fixture r2
# The setup waits on a gate file the test opens after its last assertion (not a fixed sleep the three runs must beat
# on a loaded machine); it gives up after 60 s so nothing outlives the test.
t_wt_cfg bg.env POST_CREATE_MODE=background "POST_CREATE_CMD=i=0; while [ ! -e $FIX/bg1.go ] && [ \$i -lt 600 ]; do sleep 0.1; i=\$((i + 1)); done"
run bash "$B/worktree-create.sh" --config "$CFG" bg1
expect 0 'WORKTREE-RESULT worktree-create PASS created' "setup: create with a background command"
# The install is a process sitting in the folder, so the in-use check refuses before the setup-running finding is
# reached (that finding stays for an install whose process works from elsewhere). No flag gets past it.
rm_ check bg1
expect 1 "$RM FAIL in-use" "a running post-create is a process in the folder: refused"
rm_ remove bg1 --confirmed --discard-uncommitted --delete-branch --discard-commits
expect 1 "$RM FAIL in-use" "remove refuses while setup runs, whatever the flags"
check "nothing removed while setup runs" test -e "$FIX/bg1/.git"
touch "$FIX/bg1.go"
# An install whose live process is not in the folder: the setup-running finding is what stops it. Stand-in: a finished
# install's status file removed and its pid file pointed at a live process that runs elsewhere.
t_wt_cfg bg3.env POST_CREATE_MODE=background 'POST_CREATE_CMD=true'
run bash "$B/worktree-create.sh" --config "$CFG" bg3
t_wt_wait_gitfile "$FIX/bg3" status 80
s3="$(t_wt_gitfile "$FIX/bg3" status)"; p3="$(dirname "$s3")/worktree-post-create.pid"
rm -f "$s3"; ( cd "$FIX" && exec sleep 30 ) & live=$!; echo "$live" > "$p3"
rm_ check bg3
expect 5 "$(fl 0 0 0 1)" "a running post-create is a finding"
rm_ remove bg3
expect 5 "$(fl 0 0 0 1)" "remove stops while setup runs"
check "nothing removed while that setup runs" test -e "$FIX/bg3/.git"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
t_wt_cfg bg2.env POST_CREATE_MODE=background 'POST_CREATE_CMD=true'
run bash "$B/worktree-create.sh" --config "$CFG" bg2
t_wt_wait_gitfile "$FIX/bg2" status 80
rm_ check bg2
expect 0 "$RM PASS clean" "a finished post-create is not a finding"
statf="$(t_wt_gitfile "$FIX/bg2" status)"
pidf="$(t_wt_gitfile "$FIX/bg2" pid)"; [ -n "$pidf" ] || pidf="$(dirname "$statf")/worktree-post-create.pid"
rm -f "$statf"; sleep 0 & dead=$!; wait "$dead"; echo "$dead" > "$pidf"
rm_ check bg2
expect 5 "$RM FAIL findings.*setup-running=0.*setup-died=1|$RM FAIL findings.*setup-died=1.*setup-running=0" "no status file and a dead pid is setup-died, not running"

# --- no remote ------------------------------------------------------------------------------------------------------------------------
t_wt_fixture r3
git remote remove origin
t_wt_cfg nr.env BASE_REMOTE=
git worktree add -q --no-track -b nr1 "$FIX/nr1" main
rm_ --config "$CFG" check nr1
expect 0 "$RM PASS clean" "no remote: a branch at the local base is clean"
rm_ --config "$CFG" remove nr1 --delete-branch
expect 0 "$(removed 1)" "no remote: merged into the local base, so the branch goes"
git worktree add -q --no-track -b nr2 "$FIX/nr2" main
echo w > "$FIX/nr2/w.txt"; git -C "$FIX/nr2" add w.txt; git -C "$FIX/nr2" commit -qm w
rm_ --config "$CFG" check nr2
expect 5 "$RM FAIL findings( [a-z-]+=[^ ]*)* .*unmerged=1" "no remote: unmerged is judged against the local base"
rm_ --config "$CFG" remove nr2 --delete-branch
expect 5 "$RM FAIL findings" "no remote: remove stops at the finding"
rm_ --config "$CFG" remove nr2 --confirmed --delete-branch
expect 0 "branch-deleted=0( [a-z-]+=[^ ]*)* kept=only-copy" "no remote: an unmerged branch is always kept"
check "the worktree went (nr2)" test ! -e "$FIX/nr2"
check "the branch with the only copy of the commit stayed" test "$(git rev-list --count main..nr2)" = 1

# --- list: the dirty count, the abbreviated sha, and a hand-edited marker ------------------------------------------------------
t_wt_fixture l3
mkwt feat/a; mkwt feat/b; mkwt feat/m
echo u > "$FIX/feat-a/u.txt"; echo u > "$FIX/feat-b/u.txt"
run bash "$B/worktree-list.sh"
expect 0 "$RL PASS listed count=4 dirty=2\$" "the result line counts every worktree and every dirty one"
expect_out "[[:space:]]main[[:space:]]+[0-9a-f]{7}[[:space:]]+clean" "the sha column is seven characters"
printf ' 7 \n' > "$(t_wt_gitdir "$FIX/feat-m")/worktree-issues"
run bash "$B/worktree-list.sh"
expect_out "/feat-m[[:space:]]+feat/m[[:space:]]+[0-9a-f]{7}[[:space:]]+clean[[:space:]]+7\$" "a marker with stray whitespace still lists as 7"

# --- a failing git status is never "clean" ----------------------------------------------------------------------------------------
t_wt_fixture l4
mkwt feat/c; mkwt feat/d
echo u > "$FIX/feat-c/u.txt"
printf 'junk' > "$(t_wt_gitdir "$FIX/feat-c")/index"
rm_ check feat/c
expect 3 "$RM FAIL status-failed" "check: an unreadable index is exit 3 status-failed, never PASS clean"
rm_ remove feat/c --confirmed --discard-uncommitted
expect 3 "$RM FAIL status-failed" "remove: the same"
check "the worktree is still there" test -e "$FIX/feat-c/.git"
run bash "$B/worktree-list.sh"
expect 0 "$RL PASS listed" "list still passes"
expect_out "/feat-c[[:space:]]+feat/c[[:space:]]+[0-9a-f]{7}[[:space:]]+unreadable" "list says unreadable in the state column"
expect_out "/feat-d[[:space:]]+feat/d[[:space:]]+[0-9a-f]{7}[[:space:]]+clean" "and still lists the healthy one as clean"

# --- a base that does not exist ----------------------------------------------------------------------------------------------------
t_wt_fixture l5
mkwt feat/e
t_wt_cfg nobase.env BASE_BRANCH=nomain BASE_REMOTE=
rm_ --config "$CFG" check feat/e
expect 2 "$RM FAIL config-base-branch" "a base branch with no ref is exit 2 config-base-branch, not a read failure"

# --- --discard-commits ---------------------------------------------------------------------------------------------------------------
t_wt_fixture l6
mkwt feat/dc; wtcommit feat/dc dc1
rm_ remove feat/dc --confirmed --discard-commits
expect 2 "$RM FAIL usage" "--discard-commits without --delete-branch is a usage error"
rm_ remove feat/dc --delete-branch --discard-commits
expect 5 "$RM FAIL findings" "--discard-commits without --confirmed still stops at the findings"
check "nothing was removed (findings)" test -e "$FIX/feat-dc/.git"
rm_ remove feat/dc --delete-branch --confirmed
expect 0 "branch-deleted=0( [a-z-]+=[^ ]*)* kept=only-copy" "--confirmed alone never deletes an only-copy branch"
check "its commit is still reachable" branch_exists feat/dc
git worktree add -q "$FIX/feat-dc" feat/dc || exit 2
rm_ remove feat/dc --delete-branch --confirmed --discard-commits
expect 0 "$(removed 1)" "with --discard-commits the unmerged, unpushed branch is deleted"
check "the branch is gone" test -z "$(git for-each-ref refs/heads/feat/dc)"
check "and so is the folder" test ! -e "$FIX/feat-dc"

# --- branch-only mode: the worktree is gone, the branch is left ------------------------------------------------------------------
t_wt_fixture l7
mkwt feat/bo; wtcommit feat/bo bo1
rm_ remove feat/bo --delete-branch --confirmed
expect 0 "branch-deleted=0( [a-z-]+=[^ ]*)* kept=only-copy" "setup: the worktree is gone and the branch kept"
check "setup: no worktree has the branch" test -z "$(git worktree list --porcelain | grep -x 'branch refs/heads/feat/bo')"
rm_ check feat/bo
expect 5 "$RM FAIL findings path=\\(none\\)( [a-z-]+=[^ ]*)* dirty=0 unpushed=1 unmerged=1" "check on the branch alone reports the findings with no path"
rm_ remove feat/bo
expect 1 "$RM FAIL not-found" "remove without --delete-branch has nothing to remove"
check "and the branch is still there" branch_exists feat/bo
rm_ remove feat/bo --delete-branch --confirmed
expect 0 "$RM PASS removed( [a-z-]+=[^ ]*)* branch-deleted=0( [a-z-]+=[^ ]*)* kept=only-copy" "branch-only: --confirmed alone keeps the only copy"
check "the ref is still present" branch_exists feat/bo
rm_ remove feat/bo --delete-branch --confirmed --discard-commits
expect 0 "$(removed 1)" "branch-only: --discard-commits deletes it"
check "the ref is gone" test -z "$(git for-each-ref refs/heads/feat/bo)"
rm_ remove no/such-branch --delete-branch
expect 1 "$RM FAIL not-found" "a name that is neither a worktree nor a branch is not-found"
rm_ check no/such-branch
expect 1 "$RM FAIL not-found" "check on such a name is not-found too"
mkwt feat/mg
rm_ remove feat/mg
expect 0 "$RM PASS removed( [a-z-]+=[^ ]*)* branch-deleted=0" "setup: a merged branch's worktree removed, branch left"
check "setup: the merged branch is still there" branch_exists feat/mg
rm_ remove feat/mg --delete-branch
expect 0 "$(removed 1)" "branch-only for a branch contained in the base: deleted with no extra flags"
check "and it is gone" test -z "$(git for-each-ref refs/heads/feat/mg)"

t_done
