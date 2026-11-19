#!/usr/bin/env bash
# worktree-start (the launcher): reuse or create, model words, strict words, the background setup, the wait bound,
# races, interrupted creates, and START_CMD's own exit code. START_CMD is a real shell script that records what the
# launcher gave it: its directory, MODEL and ISSUES.
. "$(dirname "$0")/../lib.sh"
RS='WORKTREE-RESULT worktree-start'
start() { run bash "$B/worktree-start.sh" "$@"; }
recs() { if [ -f "$FIX/start.rec" ]; then wc -l < "$FIX/start.rec" | tr -d ' '; else echo 0; fi; }
lastrec() { tail -1 "$FIX/start.rec" 2>/dev/null; }
rec_path() { lastrec | cut -d'|' -f1; }
rec_model() { lastrec | cut -d'|' -f2; }
rec_issues() { lastrec | cut -d'|' -f3; }
branch_of() { git -C "$1" rev-parse --abbrev-ref HEAD; }
marker_of() { printf '%s/worktree-issues' "$(t_wt_gitdir "$1")"; }
st_fix() {
  local n="$1"; shift
  t_wt_fixture "$n" "ISSUE_TITLE_CMD=echo Fix login" "START_MODELS=sonnet opus haiku" "START_DEFAULT_MODEL=sonnet" \
    "START_CMD=bash $T_TMP/$n/stub.sh" "$@"
  printf '#!/bin/sh\nprintf "%%s|%%s|%%s\\n" "$PWD" "$MODEL" "$ISSUES" >> "%s/start.rec"\nexit "$(cat "%s/stub.rc" 2>/dev/null || echo 0)"\n' "$FIX" "$FIX" > "$FIX/stub.sh"
}

# --- create when absent, each model word ---------------------------------------------------------------------------------------
st_fix s1
start 7 opus
expect 0 "$RS PASS launching path=[^ ]*/7-fix-login( [a-z-]+=[^ ]*)* model=opus" "no worktree for 7: it is created and the harness launched"
check "the worktree exists" test -e "$FIX/7-fix-login/.git"
check "its branch is 7-fix-login" test "$(branch_of "$FIX/7-fix-login")" = 7-fix-login
check "the marker records issue 7" grep -Eq '(^|[^0-9])7([^0-9]|$)' "$(marker_of "$FIX/7-fix-login")"
check "START_CMD ran once" test "$(recs)" = 1
check "START_CMD ran in the worktree" test "$(rec_path | sed 's|.*/||')" = 7-fix-login
check "START_CMD got MODEL=opus" test "$(rec_model)" = opus
check "START_CMD got ISSUES=7" test "$(rec_issues)" = 7
n="$(t_wt_count)"

start 8 haiku
expect 0 "$RS PASS launching path=[^ ]*/8-fix-login( [a-z-]+=[^ ]*)* model=haiku" "model word haiku"
check "MODEL=haiku reached START_CMD" test "$(rec_model)" = haiku
start sonnet 9
expect 0 "$RS PASS launching path=[^ ]*/9-fix-login( [a-z-]+=[^ ]*)* model=sonnet" "model word first, then the number"
check "MODEL=sonnet reached START_CMD" test "$(rec_model)" = sonnet
start 10 opus 11
expect 0 "$RS PASS launching path=[^ ]*/10-11(-[a-z0-9-]+)?( [a-z-]+=[^ ]*)* model=opus" "a model in the middle of a bundle"
check "ISSUES carries both numbers" test -n "$(rec_issues | grep -E '^10[ ,]11$')"
start 12,13 haiku
expect 0 "$RS PASS launching path=[^ ]*/12-13(-[a-z0-9-]+)?( [a-z-]+=[^ ]*)* model=haiku" "a comma-joined list"
start 14 opus opus
expect 0 "$RS PASS launching path=[^ ]*/14-fix-login( [a-z-]+=[^ ]*)* model=opus" "the same model twice is fine"
n="$(t_wt_count)"

# --- the default model --------------------------------------------------------------------------------------------------------------
start 15
expect 0 "$RS PASS launching path=[^ ]*/15-fix-login( [a-z-]+=[^ ]*)* model=sonnet" "no model word: START_DEFAULT_MODEL"
check "MODEL=sonnet reached START_CMD by default" test "$(rec_model)" = sonnet
n="$(t_wt_count)"; r0="$(recs)"

# --- reuse -----------------------------------------------------------------------------------------------------------------------------
start 7
expect 0 "$RS PASS launching path=[^ ]*/7-fix-login( [a-z-]+=[^ ]*)* model=sonnet" "an existing worktree for 7 is reused"
check "no second worktree" test "$(t_wt_count)" = "$n"
check "START_CMD ran in the existing worktree" test "$(rec_path | sed 's|.*/||')" = 7-fix-login
t_wt_run_in "$FIX/8-fix-login" bash "$PRIMARY/$B/worktree-start.sh" 7 opus
expect 0 "$RS PASS launching path=[^ ]*/7-fix-login( [a-z-]+=[^ ]*)* model=opus" "reuse by marker, run from another worktree"
check "still no new worktree" test "$(t_wt_count)" = "$n"
check "the harness started in 7's worktree, not the caller's" test "$(rec_path | sed 's|.*/||')" = 7-fix-login
mkdir -p .claude/sub
t_wt_run_in "$PRIMARY/.claude/sub" bash "$PRIMARY/$B/worktree-start.sh" 8
expect 0 "$RS PASS launching path=[^ ]*/8-fix-login " "reuse, run from a subdirectory of the primary"
check "and no new worktree (subdirectory)" test "$(t_wt_count)" = "$n"

# exact number lists: 7 never matches 7-8-..., 70 never matches 7
start 7 8
expect 0 "$RS PASS launching path=[^ ]*/7-8(-[a-z0-9-]+)? " "the bundle 7 8 is its own worktree"
check "a new worktree was made for the bundle" test "$(t_wt_count)" = "$((n + 1))"
bundle_path="$(rec_path)"
nb="$(t_wt_count)"
start 8 7
expect 0 "$RS PASS launching path=[^ ]*/7-8(-[a-z0-9-]+)? .*issues=7-8" "8 7 is the same set as 7 8"
check "8 7 reused the bundle's worktree" test "$(rec_path)" = "$bundle_path"
check "and made no new worktree" test "$(t_wt_count)" = "$nb"
start 7
check "7 alone still goes to the 7 worktree, not the bundle" test "$(rec_path | sed 's|.*/||')" = 7-fix-login
check "(and not to $bundle_path)" test "$(rec_path)" != "$bundle_path"
start 70
expect 0 "$RS PASS launching path=[^ ]*/70-fix-login " "70 does not reuse 7 by prefix"
check "a new worktree for 70" test "$(t_wt_count)" = "$((n + 2))"
check "70's worktree is its own branch" test "$(branch_of "$(rec_path)")" = 70-fix-login
start 70 7
check "70 7 is the sorted set 7-70, a different set from 7 and from 70" test "$(rec_path | sed 's|.*/||' | grep -c '^7-70')" = 1
check "(and not 7's or 70's worktree)" test "$(rec_path | sed 's|.*/||')" != 7-fix-login -a "$(rec_path | sed 's|.*/||')" != 70-fix-login
n="$(t_wt_count)"; r0="$(recs)"

# --- strict words: nothing created, START_CMD not run --------------------------------------------------------------------------
USAGE="$RS FAIL (usage|config-[a-z-]+)"
untouched() { # <label>
  if [ "$(t_wt_count)" = "$n" ] && [ "$(recs)" = "$r0" ]; then t_pass "$1"
  else OUT="worktrees=$(t_wt_count) (was $n) recs=$(recs) (was $r0)"; t_fail "$1" "something was created or launched"; fi
}
start 12 opus haiku
expect 2 "$USAGE" "a second, different model is exit 2"
untouched "two models: nothing created or launched"
start 16 turbo
expect 2 "$USAGE" "an unknown word is exit 2"
untouched "unknown word: nothing created"
check "and no branch 16*" test -z "$(git for-each-ref 'refs/heads/16*')"
start 16a
expect 2 "$USAGE" "7a-style word is exit 2"
start 0
expect 2 "$USAGE" "issue 0 is exit 2"
start 007
expect 2 "$USAGE" "issue 007 is exit 2"
start 17 17
expect 2 "$USAGE" "a duplicated issue is exit 2"
start ""
expect 2 "$USAGE" "an empty word is exit 2"
start --bogus 17
expect 2 "$USAGE" "an unknown option is exit 2"
start
expect 2 "$USAGE" "no words at all is exit 2"
start opus
expect 2 "$USAGE" "a model with no issue is exit 2"
start '$(touch pwned)' 17
expect 2 "$USAGE" "a word that is a command substitution is exit 2"
check "and it ran nothing" test ! -e pwned
untouched "hostile words: nothing created or launched"

# --- START_CMD unset, START_WAIT_SECONDS malformed ------------------------------------------------------------------------------------
t_wt_cfg nocmd.env "ISSUE_TITLE_CMD=echo Fix login" "START_MODELS=sonnet opus" "START_DEFAULT_MODEL=sonnet"
start --config "$CFG" 18
expect 2 "$RS FAIL config-[a-z-]+" "START_CMD unset is exit 2"
untouched "START_CMD unset: nothing created before the check"
t_wt_cfg badwait.env "ISSUE_TITLE_CMD=echo Fix login" "START_MODELS=sonnet" "START_CMD=bash $FIX/stub.sh" START_WAIT_SECONDS=abc
start --config "$CFG" 18
expect 2 "$RS FAIL config-[a-z-]+" "a non-numeric START_WAIT_SECONDS is exit 2"
untouched "bad wait: nothing created"

# --- START_CMD's own exit code ----------------------------------------------------------------------------------------------------------
echo 42 > "$FIX/stub.rc"
start 19
expect_out "$RS PASS launching path=[^ ]*/19-fix-login( [a-z-]+=[^ ]*)* model=sonnet" "the launching line is printed before the harness runs"
expect_rc 42 "START_CMD's exit code is the launcher's exit code"
echo 0 > "$FIX/stub.rc"
start 19
expect_rc 0 "and 0 stays 0"
n="$(t_wt_count)"; r0="$(recs)"

# --- background setup, always ------------------------------------------------------------------------------------------------------------
# Post-create waits on a gate file opened only after the launcher returns (no stopwatch). The gate gives up after 30 s,
# leaving <gate>.timeout and failing, so a launcher that waits (in any mode) fails rather than hangs.
printf 'i=0; while [ ! -e "$1" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done\n[ -e "$1" ] || { : > "$1.timeout"; echo gate-timeout; exit 1; }\necho bg-done\n' > "$FIX/gate.sh"
t_wt_cfg bg.env "ISSUE_TITLE_CMD=echo Fix login" "START_MODELS=sonnet" "START_DEFAULT_MODEL=sonnet" "START_CMD=bash $FIX/stub.sh" \
  POST_CREATE_MODE=wait "POST_CREATE_CMD=bash $FIX/gate.sh $FIX/20.go"
start --config "$CFG" 20
expect 0 "$RS PASS launching path=[^ ]*/20-fix-login " "launcher with a slow post-create"
check "the launcher did not wait for post-create, even with POST_CREATE_MODE=wait (it is still held at its gate)" \
  test ! -e "$FIX/20.go.timeout" -a -z "$(t_wt_gitfile "$FIX/20-fix-login" status)"
touch "$FIX/20.go"
check "the setup is still running or recorded in the git dir" test -n "$(t_wt_gitfile "$FIX/20-fix-login" log)"
check "the status file appears once setup ends" t_wt_wait_gitfile "$FIX/20-fix-login" status 120

# --- guard and --force ----------------------------------------------------------------------------------------------------------------------
printf '#!/bin/sh\necho launcher guard says no\nexit 1\n' > "$FIX/guard.sh"
t_wt_cfg gd.env "ISSUE_TITLE_CMD=echo Fix login" "START_MODELS=sonnet" "START_DEFAULT_MODEL=sonnet" "START_CMD=bash $FIX/stub.sh" "ISSUE_GUARD_CMD=bash $FIX/guard.sh"
n="$(t_wt_count)"; r0="$(recs)"
start --config "$CFG" 21
expect_rc 1 "a refusing guard stops the launcher with exit 1"
expect 1 "$RS FAIL guard-refused issues=21 create-exit=1" "and its last line carries the create's reason and code"
untouched "guard refused: nothing created or launched"
start --config "$CFG" --force 21
expect 0 "$RS PASS launching path=[^ ]*/21-fix-login " "--force passes through to the create"
check "the forced launch ran START_CMD" test "$(recs)" = "$((r0 + 1))"

# --- a parent directory with a space -------------------------------------------------------------------------------------------------------
mkdir "$FIX/sp ace"
start --parent "$FIX/sp ace" 22
expect 0 "$RS PASS launching " "--parent with a space"
check "the worktree is under that parent" test -e "$FIX/sp ace/22-fix-login/.git"
check "START_CMD ran there" test "$(rec_path)" = "$FIXP/sp ace/22-fix-login" -o "$(rec_path)" = "$FIX/sp ace/22-fix-login"

# --- leftover folder that never becomes a checkout: exit 3 -----------------------------------------------------------------------------------
t_wt_cfg wt.env "ISSUE_TITLE_CMD=echo Fix login" "START_MODELS=sonnet" "START_DEFAULT_MODEL=sonnet" "START_CMD=bash $FIX/stub.sh" START_WAIT_SECONDS=2
mkdir "$FIX/23-fix-login"
r0="$(recs)"; n="$(t_wt_count)"
SECONDS=0; start --config "$CFG" 23; elapsed=$SECONDS
expect 3 "$RS FAIL not-a-checkout" "a folder that never becomes a checkout is exit 3"
check "the wait was bounded (well under the default)" test "$elapsed" -lt 30
check "START_CMD was not run" test "$(recs)" = "$r0"
check "the leftover folder is untouched" test -d "$FIX/23-fix-login" -a -z "$(ls -A "$FIX/23-fix-login")"
untouched "wait expired: no worktree registered"

# --- an unreadable marker is a failed read ----------------------------------------------------------------------------------------------------
if ! t_can_unreadable; then t_skip "an unreadable marker: chmod cannot take read access away here (root, or Windows)"
else
  start 24
  mk="$(marker_of "$FIX/24-fix-login")"; chmod 000 "$mk"
  n="$(t_wt_count)"; r0="$(recs)"
  start 24
  expect 3 "$RS FAIL marker-unreadable" "an unreadable marker is exit 3, never 'no worktree'"
  untouched "unreadable marker: no second worktree, no launch"
  chmod 644 "$mk"
fi

# --- the marker is read from a primary checkout -------------------------------------------------------------------------------------------------
st_fix s2
start 31
expect 0 "$RS PASS launching " "setup: a worktree and its marker for issue 31"
mk_content="$(cat "$(marker_of "$FIX/31-fix-login")")"
git worktree remove --force "$FIX/31-fix-login"
git branch -D 31-fix-login >/dev/null
printf '%s\n' "$mk_content" > "$(cd "$(git rev-parse --git-dir)" && pwd -P)/worktree-issues"
n="$(t_wt_count)"; r0="$(recs)"
start 31
expect 0 "$RS PASS launching path=[^ ]*/31-fix-login " "a marker in the primary checkout on the base branch is not a match: a new worktree"
check "a worktree was created" test "$(t_wt_count)" = "$((n + 1))"
check "START_CMD did not run in the primary" test "$(rec_path | sed 's|.*/||')" != primary

# --- interrupted creates: the launcher reuses what is there --------------------------------------------------------------------------------------
st_fix s3
t_wt_cfg int.env "ISSUE_TITLE_CMD=echo Fix login" "START_MODELS=sonnet" "START_DEFAULT_MODEL=sonnet" "START_CMD=bash $FIX/stub.sh" \
  PUSH_ON_ISSUE=1 "ISSUE_CLAIM_CMD=echo claimed \$ISSUE >> $FIX/claims.rec"
num=40
for step in add marker copy post-create push claim; do
  num=$((num + 1))
  run env WORKTREE_TEST_MODE=1 "WORKTREE_TEST_STOP_AFTER=$step" bash "$B/worktree-create.sh" --config "$CFG" "$num"
  expect_rc 99 "create stopped after $step: exit 99 (the seam fired)"
  refute_out '^WORKTREE-RESULT' "create stopped after $step: no result line"
  check "create stopped after $step: the worktree exists" test -e "$FIX/$num-fix-login/.git"
  n="$(t_wt_count)"; r0="$(recs)"
  start --config "$CFG" "$num"
  expect 0 "$RS PASS launching path=[^ ]*/$num-fix-login " "launcher after a create stopped after $step reuses the worktree"
  check "after $step: no second worktree" test "$(t_wt_count)" = "$n"
  check "after $step: START_CMD ran there" test "$(rec_path | sed 's|.*/||')" = "$num-fix-login"
  check "after $step: exactly one branch for the issue" test "$(git for-each-ref "refs/heads/$num-*" | wc -l | tr -d ' ')" = 1
done

# --- races ---------------------------------------------------------------------------------------------------------------------------------------------
st_fix s4
t_wt_cfg race.env "ISSUE_TITLE_CMD=echo Fix login" "START_MODELS=sonnet" "START_DEFAULT_MODEL=sonnet" "START_CMD=bash $FIX/stub.sh" START_WAIT_SECONDS=20
t_wt_hold_install; t_wt_hold_on
bash "$B/worktree-start.sh" --config "$CFG" 81 > "$FIX/s1.out" 2>&1 &
p1=$!
t_wt_wait_file "$FIX/hold.reached" 100
check "the first launcher is inside its create (held in the add)" test -f "$FIX/hold.reached"
( sleep 3; : > "$FIX/go" ) &
bash "$B/worktree-start.sh" --config "$CFG" 81 > "$FIX/s2.out" 2>&1; rc2=$?
wait "$p1"; rc1=$?
t_wt_hold_off
check "both launchers ended with START_CMD's exit code 0" test "$rc1" = 0 -a "$rc2" = 0
check "exactly one worktree for issue 81" test "$(git worktree list --porcelain | grep -c 'branch refs/heads/81-')" = 1
check "both launched START_CMD" test "$(recs)" = 2
check "both launched in the same worktree" test "$(cut -d'|' -f1 "$FIX/start.rec" | sort -u | wc -l | tr -d ' ')" = 1
check "each printed its launching line" test "$(cat "$FIX/s1.out" "$FIX/s2.out" | grep -c "$RS PASS launching")" = 2
rm -f "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/hooks/post-checkout"

for k in 1 2 3; do
  rm -f "$FIX/start.rec"
  ( bash "$B/worktree-start.sh" --config "$CFG" "9$k" > "$FIX/r1.out" 2>&1; echo $? > "$FIX/r1.rc" ) &
  ( bash "$B/worktree-start.sh" --config "$CFG" "9$k" > "$FIX/r2.out" 2>&1; echo $? > "$FIX/r2.rc" ) &
  wait
  check "race $k: both launchers succeed" test "$(cat "$FIX/r1.rc")$(cat "$FIX/r2.rc")" = 00
  check "race $k: one worktree" test "$(git worktree list --porcelain | grep -c "branch refs/heads/9$k-")" = 1
  check "race $k: both launched in it" test "$(recs)" = 2 -a "$(cut -d'|' -f1 "$FIX/start.rec" | sort -u | wc -l | tr -d ' ')" = 1
done

# --- reuse lookup on unmarked branches: whole number lists only, and the recorded marker wins -----------------------------------
# (worktrees made with plain git have no marker, like a create that died before writing it)
st_fix s20
git worktree add -q --no-track -b 7-8-wip "$FIX/7-8-wip" origin/main || exit 2
start 7
expect 0 "$RS PASS launching path=[^ ]*/7-fix-login " "an unmarked 7-8-wip is the bundle 7 8, not issue 7"
check "issue 7 got its own worktree" test -e "$FIX/7-fix-login/.git"
check "(and 7-8-wip was left alone)" test "$(rec_path | sed 's|.*/||')" = 7-fix-login
start 7 8
expect 0 "$RS PASS launching path=[^ ]*/7-8-wip " "the unmarked bundle branch is reused for 7 8"
check "no extra worktree for the bundle" test "$(t_wt_count)" = 3

# a bundled branch name, read the way start's Step 0 says: every leading number, stopping at the first segment that is not one
leading_numbers() { printf '%s\n' "$1" | awk '{ n = split($0, s, "-"); o = ""; for (i = 1; i <= n; i++) { if (s[i] !~ /^[0-9]+$/) break; o = o (o == "" ? "" : " ") s[i] } print o }'; }
st_fix s21
start 12 13
bb="$(branch_of "$(rec_path)")"
check "the bundle branch is 12-13-fix-login" test "$bb" = 12-13-fix-login
check "its leading numbers are 12 and 13" test "$(leading_numbers "$bb")" = "12 13"
check "12-fix-13-login stops at the first word" test "$(leading_numbers 12-fix-13-login)" = 12
check "7-2fa-login stops at 2fa" test "$(leading_numbers 7-2fa-login)" = 7
check "a branch with no leading number has none" test -z "$(leading_numbers fix-12)"
p1="$(rec_path)"
# shellcheck disable=SC2046
start $(leading_numbers "$bb")
check "starting the parsed numbers goes back to the same worktree" test "$(rec_path)" = "$p1"
git worktree add -q --no-track -b 31-2fa-login "$FIX/31-2fa-login" origin/main || exit 2
# shellcheck disable=SC2046
start $(leading_numbers 31-2fa-login)
expect 0 "$RS PASS launching path=[^ ]*/31-2fa-login " "an unmarked 31-2fa-login is issue 31 (2fa is not a number)"

# two worktrees answer to issue 7: the unmarked one is listed first, the one whose marker says 7 second
st_fix s22
git worktree add -q --no-track -b 7-aaa-experiment "$FIX/7-aaa-experiment" origin/main || exit 2
run bash "$B/worktree-create.sh" 7
expect 0 'WORKTREE-RESULT worktree-create PASS' "setup: the marked worktree for 7 is created after the unmarked one"
start 7
expect 0 "$RS PASS launching path=[^ ]*/7-fix-login " "the worktree whose recorded marker says 7 wins over an unmarked branch that merely starts with 7"

# --- a refusal that cannot clear returns at once ----------------------------------------------------------------------------------
st_fix s23
# A wide margin, not a tight stopwatch: returning at once takes a second or two even on a loaded machine; waiting
# would take all 60.
t_wt_cfg be.env "START_MODELS=sonnet" "START_CMD=bash $FIX/stub.sh" START_WAIT_SECONDS=60
git branch 42
r0="$(recs)"
SECONDS=0; start --config "$CFG" 42; elapsed=$SECONDS
expect 1 "$RS FAIL branch-exists issues=42 create-exit=1" "a local branch 42 that is not on the remote: exit 1 branch-exists"
check "it did not wait out START_WAIT_SECONDS (60)" test "$elapsed" -lt 30
check "START_CMD was not run" test "$(recs)" = "$r0"

# --- no model at all ---------------------------------------------------------------------------------------------------------------------
t_wt_cfg nm.env "START_MODELS=sonnet" "START_CMD=bash $FIX/stub.sh"
start --config "$CFG" 62
expect 0 "$RS PASS launching path=[^ ]*/62 .*model=none" "no model word and no START_DEFAULT_MODEL: model=none"
check "START_CMD got an empty MODEL" test -z "$(rec_model)"

# --- start's pre-flight snippet, run for real --------------------------------------------------------------------------------------
snip="$(awk '/^```bash$/ { buf = ""; inb = 1; next } /^```$/ { if (inb && buf ~ /git-common-dir/) { printf "%s", buf; exit } inb = 0 } inb { buf = buf $0 "\n" }' "$T_ROOT/skills/start/SKILL.md")"
check "the pre-flight snippet was found in start's SKILL.md" test -n "$snip"
st_fix s24
mkdir -p sub
git worktree add -q --no-track -b linked-one "$FIX/linked-one" origin/main || exit 2
t_wt_run_in "$PRIMARY" bash -c "$snip"
expect 0 '^PRIMARY$' "pre-flight in the primary root: PRIMARY"
t_wt_run_in "$PRIMARY/sub" bash -c "$snip"
expect 0 '^PRIMARY$' "pre-flight in a primary subdirectory: PRIMARY"
t_wt_run_in "$FIX/linked-one" bash -c "$snip"
expect 0 '^LINKED$' "pre-flight in a linked worktree: LINKED"

t_done
