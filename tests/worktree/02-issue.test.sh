#!/usr/bin/env bash
# worktree-create (issue flow): branch names from titles, bundles, the length cap, the title / guard / claim command
# slots, the push option, the marker, and the failure ordering after the worktree exists.
. "$(dirname "$0")/../lib.sh"
R='WORKTREE-RESULT worktree-create'
create() { run bash "$B/worktree-create.sh" "$@"; }
branch_in() { git -C "$1" rev-parse --abbrev-ref HEAD; }
cfg_of() { git config --get "$1" 2>/dev/null; }
marker_of() { printf '%s/worktree-issues' "$(t_wt_gitdir "$1")"; }
# slot scripts live next to the clones; each records what the environment gave it
mkslots() {
  printf '#!/bin/sh\necho "$ISSUE|$ISSUES" >> "%s/title.rec"\necho Fix login page\n' "$FIX" > "$FIX/title-ok.sh"
  printf '#!/bin/sh\nexit 1\n' > "$FIX/title-fail.sh"
  printf '#!/bin/sh\nexit 0\n' > "$FIX/title-empty.sh"
  printf '#!/bin/sh\necho first line\necho second line\n' > "$FIX/title-two.sh"
  printf '#!/bin/sh\necho "!!! ???"\n' > "$FIX/title-punct.sh"
  printf '#!/bin/sh\nprintf "%%s\\n" '"'"'Fix $(touch pwned) "login" page'"'"'\n' > "$FIX/title-hostile.sh"
  printf '#!/bin/sh\necho Rework onboarding pipeline for every tenant account today please\n' > "$FIX/title-long.sh"
  printf '#!/bin/sh\necho "guard saw $ISSUE ($ISSUES)" >> "%s/guard.rec"\n[ -f "%s/guard.rc" ] || exit 0\necho guard says no: blocked\nexit "$(cat "%s/guard.rc")"\n' "$FIX" "$FIX" "$FIX" > "$FIX/guard.sh"
  printf '#!/bin/sh\necho "$ISSUE|$BRANCH|$WORKTREE_PATH" >> "%s/claim.rec"\n[ -f "%s/claim.rc" ] && exit "$(cat "%s/claim.rc")"\nexit 0\n' "$FIX" "$FIX" "$FIX" > "$FIX/claim.sh"
}

# --- names from titles ---------------------------------------------------------------------------------------------------
t_wt_fixture i1
mkslots
t_wt_cfg t-ok.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh"
create --config "$CFG" 7
expect 0 "$R PASS created path=[^ ]*/7-fix-login-page branch=7-fix-login-page base=main attached=0" "one issue: number-slug branch"
check "the folder carries the branch name" test -e "$FIX/7-fix-login-page/.git"
check "the branch is checked out there" test "$(branch_in "$FIX/7-fix-login-page")" = 7-fix-login-page
check "the title command saw ISSUE=7" grep -q '^7|' "$FIX/title.rec"
check "the marker is in the worktree's git dir" test -f "$(marker_of "$FIX/7-fix-login-page")"
check "the marker names issue 7" grep -Eq '(^|[^0-9])7([^0-9]|$)' "$(marker_of "$FIX/7-fix-login-page")"
check "the marker is not in the checkout, so git status is empty" test -z "$(git -C "$FIX/7-fix-login-page" status --porcelain)"
check "no upstream for a new issue branch" test -z "$(cfg_of branch.7-fix-login-page.remote)"
check "PUSH_ON_ISSUE defaults to off: the remote has no such branch" test -z "$(git ls-remote origin refs/heads/7-fix-login-page)"

create --config "$CFG" 8 9
expect 0 "$R PASS created path=[^ ]*/8-9(-[a-z0-9-]+)? branch=8-9(-[a-z0-9-]+)? " "a bundle: both numbers lead the branch"
create --config "$CFG" 12,13 14
expect 0 "$R PASS created path=[^ ]*/12-13-14(-[a-z0-9-]+)? branch=12-13-14(-[a-z0-9-]+)? " "comma-joined and spaced numbers mix"
bundle="$(printf '%s\n' "$LAST" | sed 's/.* branch=\([^ ]*\).*/\1/')"
check "the bundle marker names every issue" test "$(grep -oE '[0-9]+' "$(marker_of "$FIX/$bundle")" | tr '\n' ' ')" = "12 13 14 "
create --config "$CFG" 21,22
expect 0 "$R PASS created path=[^ ]*/21-22(-[a-z0-9-]+)? " "comma-joined alone equals spaced"
create --config "$CFG" 30 feat/mine
expect 0 "$R PASS created path=[^ ]*/feat-mine branch=feat/mine " "issue flow with an explicit branch name"
check "the explicit-branch worktree has the marker with 30" grep -Eq '(^|[^0-9])30([^0-9]|$)' "$(marker_of "$FIX/feat-mine")"

# empty ISSUE_TITLE_CMD: number-only names
t_wt_cfg t-none.env
create --config "$CFG" 41
expect 0 "$R PASS created path=[^ ]*/41 branch=41 " "no ISSUE_TITLE_CMD: the branch is the number alone"
check "and the folder is the number" test -e "$FIX/41/.git"

# punctuation-only title: empty slug, number prefix alone
t_wt_cfg t-punct.env "ISSUE_TITLE_CMD=bash $FIX/title-punct.sh"
create --config "$CFG" 42
expect 0 "$R PASS created path=[^ ]*/42 branch=42 " "an empty slug gives the number prefix alone"

# a hostile title is reduced to [a-z0-9-]; nothing in it runs
t_wt_cfg t-host.env "ISSUE_TITLE_CMD=bash $FIX/title-hostile.sh"
create --config "$CFG" 43
expect 0 "$R PASS created" "a title with quotes and a command substitution"
hb="$(printf '%s\n' "$LAST" | sed 's/.* branch=\([^ ]*\).*/\1/')"
check "the branch contains only [a-z0-9-] after the number" test -n "$(printf '%s\n' "$hb" | grep -E '^43-[a-z0-9-]+$')"
check "the branch keeps the readable words" test -n "$(printf '%s\n' "$hb" | grep -E 'fix.*login')"
check "the title text never ran as a command" test ! -e pwned -a ! -e "$FIX/pwned" -a ! -e "$FIX/$hb/pwned"

# cap: the slug is cut, never the number prefix
t_wt_cfg t-long.env "ISSUE_TITLE_CMD=bash $FIX/title-long.sh" BRANCH_MAX_LEN=20
create --config "$CFG" 51
expect 0 "$R PASS created" "a long title under BRANCH_MAX_LEN=20"
lb="$(printf '%s\n' "$LAST" | sed 's/.* branch=\([^ ]*\).*/\1/')"
check "the capped branch starts with the number" test -n "$(printf '%s\n' "$lb" | grep -E '^51-[a-z0-9-]+$')"
check "the capped branch is short (cap plus the number prefix at most)" test "${#lb}" -le 23
check "the capped branch does not end in a dash" test -z "$(printf '%s\n' "$lb" | grep -E -- '-$')"
check "the capped branch is shorter than the uncapped one" test "${#lb}" -lt 40
t_wt_cfg t-long2.env "ISSUE_TITLE_CMD=bash $FIX/title-long.sh" BRANCH_MAX_LEN=20
create --config "$CFG" 100 101 102 103 104 105 106 107 108 109
expect 0 "$R PASS created" "a bundle whose prefix is longer than the cap"
lb="$(printf '%s\n' "$LAST" | sed 's/.* branch=\([^ ]*\).*/\1/')"
check "the number prefix is never cut" test -n "$(printf '%s\n' "$lb" | grep -E '^100-101-102-103-104-105-106-107-108-109(-|$)')"
t_wt_cfg t-def.env "ISSUE_TITLE_CMD=bash $FIX/title-long.sh"
create --config "$CFG" 52
lb="$(printf '%s\n' "$LAST" | sed 's/.* branch=\([^ ]*\).*/\1/')"
check "the default cap (50) cuts a long title (the number prefix included in the budget or not, never far over)" test "${#lb}" -le 53
check "the default-cap branch starts with the number and the first words" test -n "$(printf '%s
' "$lb" | grep -E '^52-rework-onboarding')"
check "the default-cap branch does not end in a dash" test -z "$(printf '%s
' "$lb" | grep -E -- '-$')"
printf '#!/bin/sh
echo Fix the login page
' > "$FIX/title-the.sh"
t_wt_cfg t-the.env "ISSUE_TITLE_CMD=bash $FIX/title-the.sh"
create --config "$CFG" 53
expect 0 "$R PASS created path=[^ ]*/53-fix-login-page branch=53-fix-login-page " "a title is lowercased, filler words are dropped, spaces become dashes"

# --- title failures: exit 3, nothing created -------------------------------------------------------------------------------
t_wt_fixture i2
mkslots
for kind in fail empty two; do
  t_wt_cfg "tf-$kind.env" "ISSUE_TITLE_CMD=bash $FIX/title-$kind.sh"
  create --config "$CFG" 61
  expect 3 "$R FAIL title-failed" "a title command that gives $kind is exit 3"
  t_wt_pristine "title $kind: nothing was created"
done

# --- guard ---------------------------------------------------------------------------------------------------------------------
t_wt_fixture i3
mkslots
t_wt_cfg g-unset.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh"
create --config "$CFG" 71
expect 0 "$R PASS created" "no guard configured: create goes ahead"
expect_out 'guard: not configured' "an unset guard says so"
create --config "$CFG" 72
expect_out 'guard: not configured' "and says so on every run"
t_wt_cfg g-set.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh" "ISSUE_GUARD_CMD=bash $FIX/guard.sh"
create --config "$CFG" 73
expect 0 "$R PASS created" "a guard that exits 0 lets the create through"
refute_out 'guard: not configured' "a configured guard does not print the not-configured line"
check "the guard ran with ISSUE=73 exported" grep -q '^guard saw 73 ' "$FIX/guard.rec"
echo 1 > "$FIX/guard.rc"
n0="$(t_wt_count)"
create --config "$CFG" 74
expect 1 "$R FAIL guard-refused issue=74" "a refusing guard is exit 1 and names the issue"
expect_out 'guard says no: blocked' "the guard's own output is shown"
check "nothing was created for the refused issue" test "$(t_wt_count)" = "$n0"
check "no branch for it" test -z "$(git for-each-ref 'refs/heads/74*')"
check "and no folder" test -z "$(find "$FIX" -maxdepth 1 -name '74*')"
echo 3 > "$FIX/guard.rc"
create --config "$CFG" 75
expect 1 "$R FAIL guard-refused issue=75" "any non-zero guard exit is a refusal"
create --config "$CFG" --force 76
expect 0 "$R PASS created" "--force bypasses the guard"
check "the forced worktree exists" test -e "$FIX/76-fix-login-page/.git"
rm -f "$FIX/guard.rc" "$FIX/guard.rec"
printf '#!/bin/sh\n[ "$ISSUE" = 82 ] && { echo blocked 82; exit 1; }\necho ok "$ISSUE" >> "%s/guard.rec"\nexit 0\n' "$FIX" > "$FIX/guard.sh"
create --config "$CFG" 81 82
expect 1 "$R FAIL guard-refused issue=82" "in a bundle the refusing issue is the one named"
check "nothing of the bundle was created" test -z "$(find "$FIX" -maxdepth 1 -name '81-82*')"

# --- claim -----------------------------------------------------------------------------------------------------------------------
t_wt_fixture i4
mkslots
t_wt_cfg cl.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh" "ISSUE_CLAIM_CMD=bash $FIX/claim.sh"
create --config "$CFG" 91
expect 0 "$R PASS created" "a claim command that succeeds"
check "the claim ran once with ISSUE, BRANCH and WORKTREE_PATH" test "$(grep -c '^91|91-fix-login-page|.*/91-fix-login-page$' "$FIX/claim.rec")" = 1
rm -f "$FIX/claim.rec"
create --config "$CFG" 92 93
expect 0 "$R PASS created" "a bundle with a claim command"
check "the claim ran once per issue (2 lines)" test "$(wc -l < "$FIX/claim.rec" | tr -d ' ')" = 2
check "once for 92" test "$(grep -c '^92|' "$FIX/claim.rec")" = 1
check "once for 93" test "$(grep -c '^93|' "$FIX/claim.rec")" = 1
echo 1 > "$FIX/claim.rc"
create --config "$CFG" 94
expect 6 "$R FAIL claim-failed path=[^ ]+/94-fix-login-page branch=94-fix-login-page" "a failing claim is exit 6"
check "the worktree is left in place" test -e "$FIX/94-fix-login-page/.git"
check "its marker was written" test -f "$(marker_of "$FIX/94-fix-login-page")"
rm -f "$FIX/claim.rc"

# --- push --------------------------------------------------------------------------------------------------------------------------
t_wt_fixture i5
mkslots
t_wt_cfg po.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh" PUSH_ON_ISSUE=1 "ISSUE_CLAIM_CMD=bash $FIX/claim.sh"
create --config "$CFG" 111
expect 0 "$R PASS created" "PUSH_ON_ISSUE=1"
b=111-fix-login-page
check "the branch is on the remote" test -n "$(git ls-remote origin "refs/heads/$b")"
check "the remote branch is the local branch" test "$(t_wt_tip "$b")" = "$(git -C "$FIX/$b" rev-parse HEAD)"
check "push -u set the upstream remote" test "$(cfg_of "branch.$b.remote")" = origin
check "push -u set the upstream merge ref" test "$(cfg_of "branch.$b.merge")" = "refs/heads/$b"
check "the claim ran after the push" test "$(grep -c "^111|" "$FIX/claim.rec")" = 1
t_wt_cfg po0.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh" PUSH_ON_ISSUE=0
create --config "$CFG" 112
b2=112-fix-login-page
check "PUSH_ON_ISSUE=0: the remote has no such branch" test -z "$(git ls-remote origin "refs/heads/$b2")"
check "PUSH_ON_ISSUE=0: no upstream" test -z "$(cfg_of "branch.$b2.remote")"

# a rejecting remote: push fails, the claim is skipped, the worktree stays
t_wt_fixture i6
mkslots
printf '#!/bin/sh\nwhile read old new ref; do [ "$ref" = refs/heads/main ] || exit 1; done\nexit 0\n' > "$ORIGIN/hooks/pre-receive"
chmod +x "$ORIGIN/hooks/pre-receive"
t_wt_cfg pf.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh" PUSH_ON_ISSUE=1 "ISSUE_CLAIM_CMD=bash $FIX/claim.sh"
create --config "$CFG" 121
expect 6 "$R FAIL push-failed path=[^ ]+/121-fix-login-page branch=121-fix-login-page" "a rejected push is exit 6"
check "the worktree stays" test -e "$FIX/121-fix-login-page/.git"
check "the claim was skipped after the failed push" test ! -s "$FIX/claim.rec"
check "the marker was written before the push" test -f "$(marker_of "$FIX/121-fix-login-page")"
# first failure decides the reason; later steps still run
t_wt_cfg pcf.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh" PUSH_ON_ISSUE=1 "POST_CREATE_CMD=exit 1" "ISSUE_CLAIM_CMD=bash $FIX/claim.sh"
create --config "$CFG" 122
expect 6 "$R FAIL post-create-failed path=[^ ]+ branch=122-fix-login-page" "post-create fails first: that is the reason"
printf '#!/bin/sh\nexit 0\n' > "$ORIGIN/hooks/pre-receive"
t_wt_cfg pcf2.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh" PUSH_ON_ISSUE=1 "POST_CREATE_CMD=exit 1" "ISSUE_CLAIM_CMD=bash $FIX/claim.sh"
create --config "$CFG" 123
expect 6 "$R FAIL post-create-failed" "post-create fails, the remote accepts"
check "the push still ran after the failed post-create" test -n "$(git ls-remote origin refs/heads/123-fix-login-page)"
check "the claim still ran after the failed post-create" test "$(grep -c '^123|' "$FIX/claim.rec")" = 1

# the environment reaches post-create
t_wt_fixture i7
mkslots
t_wt_cfg env.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh" "POST_CREATE_CMD=echo \$ISSUE:\$ISSUES >> $FIX/pc.rec"
create --config "$CFG" 131 132
expect 0 "$R PASS created" "post-create in a bundle"
check "post-create sees ISSUES with both numbers" grep -Eq '131[ ,]132' "$FIX/pc.rec"

# --- no remote, issue flow ---------------------------------------------------------------------------------------------------
t_wt_fixture i8
mkslots
git remote remove origin
t_wt_cfg nr.env BASE_REMOTE= PUSH_ON_ISSUE=1 "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh"
create --config "$CFG" 141
expect 0 "$R PASS created path=[^ ]*/141-fix-login-page " "no remote with PUSH_ON_ISSUE=1: no push is attempted, create passes"
check "no remote appeared" test -z "$(git remote)"
check "the branch is off the local base" test "$(git -C "$FIX/141-fix-login-page" rev-parse HEAD)" = "$(git rev-parse main)"

# --- an existing remote branch for the issue is attached, and still gets its marker -----------------------------------------------
t_wt_fixture i9
mkslots
t_wt_remote_commit 151-fix-login-page a.txt a
t_wt_cfg at.env "ISSUE_TITLE_CMD=bash $FIX/title-ok.sh"
create --config "$CFG" 151
expect 0 "$R PASS created .*attached=1" "the issue's remote branch is attached"
check "it tracks its remote branch" test "$(cfg_of branch.151-fix-login-page.merge)" = refs/heads/151-fix-login-page
check "and has the marker" grep -Eq '(^|[^0-9])151([^0-9]|$)' "$(marker_of "$FIX/151-fix-login-page")"

# --- a cut that lands on a dash never leaves the dash --------------------------------------------------------------------------
# prefix "97-" plus a 17-character room: the 17th character of the slug is the dash after a 16-letter word
t_wt_cfg t-dash.env "ISSUE_TITLE_CMD=echo Abcdefghijklmnop Xyz" BRANCH_MAX_LEN=20
create --config "$CFG" 97
expect 0 "$R PASS created path=[^ ]*/97-abcdefghijklmnop branch=97-abcdefghijklmnop " "a slug cut exactly before a dash"
check "the branch does not end in a dash" test "$(git for-each-ref --format='%(refname:short)' 'refs/heads/97*')" = 97-abcdefghijklmnop

# --- issue sets are unordered: sorted marker and prefix, typed-first title ----------------------------------------------------------
t_wt_fixture o1 'ISSUE_TITLE_CMD=echo Title for $ISSUE'
t_wt_cfg ord.env 'ISSUE_TITLE_CMD=echo Title for $ISSUE'
create --config "$CFG" 8 7
expect 0 "$R PASS created path=[^ ]*/7-8-title-8 branch=7-8-title-8 .*issues=7-8" "8 7 is the set 7-8; the first number typed names the branch"
check "the marker records the sorted set" test "$(cat "$(marker_of "$FIX/7-8-title-8")")" = 7-8
create --config "$CFG" 70 9 100
expect 0 "$R PASS created .*issues=9-70-100" "sorting is numeric, not alphabetical"

t_done
