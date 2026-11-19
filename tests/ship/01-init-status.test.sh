#!/usr/bin/env bash
# ship-init / ship-status: the contract check, skill-dir check, argument handling, resume, config validation.
. "$(dirname "$0")/../lib.sh"

t_fixture init "DEFAULT_MODE=offload" "CRITICAL_GLOBS_FILE=.claude/critical-paths.txt" "FIX_ROUND_CAP=2"
t_branch feat/7-x

run bash "$B/ship-status.sh" --contract=2
expect 2 'SHIP-RESULT ship-status FAIL mode-missing' "status before init is a usage error"

run bash "$B/ship-init.sh" --contract=2 --skill-dir /tmp
expect 9 'SHIP-RESULT ship-init FAIL skill-dir-mismatch' "init with another directory's skill is exit 9"

run bash "$B/ship-init.sh" --skill-dir "$SKILL"
expect 9 'FAIL contract-mismatch' "a pointer with no --contract fails closed"

run bash "$B/ship-init.sh" --contract=99 --skill-dir "$SKILL"
expect 9 'FAIL contract-mismatch' "a wrong contract number is exit 9"

t_init "--loacl"
expect 2 'SHIP-RESULT ship-init FAIL (bad|unknown)-argument' "a misspelled flag is refused, never ignored"

t_init "there were no merge conflicts"
expect 0 'SHIP-RESULT ship-init PASS' "init accepts free text"
expect_out '^START: fresh' "first init is a fresh start"
refute_out '^NO-MERGE' "'no merge conflicts' in prose is not the no-merge instruction"

t_init "fixes #12 -- see notes, no merge please"
expect 0 'SHIP-RESULT ship-init PASS' "init accepts a lone -- token in prose"
expect_out '^NO-MERGE' "'no merge please' is the no-merge instruction"
check "the annotation is recorded for the PR body" grep -q 'see notes' "$ST/ship-args.body.md"
if grep -Eq 'fixes #12' "$ST/ship-args.body.md"; then OUT="$(cat "$ST/ship-args.body.md")"; t_fail "the body-safe copy defuses a closing keyword"
else t_pass "the body-safe copy defuses a closing keyword"; fi

run bash "$B/ship-status.sh" --contract=2
expect 0 'SHIP-RESULT ship-status PASS' "status after init"

run bash "$B/ship-status.sh" --contract=2 cfg BASE_BRANCH
expect 0 '^main$' "cfg prints one value and no result line"
run bash "$B/ship-status.sh" --contract=2 cfg NOPE
expect_rc 1 "cfg on an unset key is exit 1"
t_kv_crlf_agree "$T_ROOT/skills/ship/bin/ship-lib.sh" ship_kv_get "$T_ROOT/skills/ship/ship.env.example" \
  "a CRLF copy of ship.env.example reads every key as the LF original does, with no CR in any value"

# Resume: the same arguments on the same tree re-init as a resume; changed arguments or --fresh start over.
t_init "fixes #12 -- see notes, no merge please"
expect_out '^START: resume' "re-init with the same arguments on an unchanged tree resumes"
t_init ""
expect_out '^START: fresh \(reason=no-merge-changed\)' "dropping the no-merge instruction starts fresh and says why"
t_init "--fresh"
expect_out '^START: fresh' "--fresh starts over"

# SKILL.md changed under a running ship: every other script stops with exit 9, and the re-init resumes.
echo "# touched" >> .claude/skills/ship/SKILL.md
run bash "$B/ship-status.sh" --contract=2
expect 9 'SHIP-RESULT ship-status FAIL skill-changed' "a changed SKILL.md stops the next script"
t_init ""
expect 0 'SHIP-RESULT ship-init PASS' "re-init after skill-changed succeeds"
expect_out '^START: resume.*skill-changed' "and resumes, naming the reason"
git checkout -q .claude/skills/ship/SKILL.md

# Configuration is validated before any gate.
mv .claude/skills/ship/ship.env "$FIX/ship.env.bak"
run bash "$B/ship-status.sh" --contract=2
expect 2 'FAIL ship-env-missing' "a missing ship.env is a usage error"
echo "DEFAULT_MODE=offload" > .claude/skills/ship/ship.env
run bash "$B/ship-status.sh" --contract=2
expect 2 'FAIL base-branch-unset' "BASE_BRANCH is required"
printf 'BASE_BRANCH=main\nthis is not a key value line\n' > .claude/skills/ship/ship.env
run bash "$B/ship-status.sh" --contract=2
expect 2 'FAIL ship-env-malformed' "a malformed line is refused"
printf 'BASE_BRANCH=main\nTEST_CMD= # no test runner yet\n' > .claude/skills/ship/ship.env
run bash "$B/ship-status.sh" --contract=2
expect 2 'FAIL ship-env-malformed' "a comment where a value should be is refused, never run as a command that reads green"
expect_out 'a value may not begin with #' "the refusal says what is wrong with the line"
printf 'BASE_BRANCH=main\nTEST_CMD=\t# no test runner yet\n' > .claude/skills/ship/ship.env
run bash "$B/ship-status.sh" --contract=2
expect 2 'FAIL ship-env-malformed' "a comment after a tab, where a value should be, is refused too"
mv "$FIX/ship.env.bak" .claude/skills/ship/ship.env

git checkout -q --detach
t_init ""
expect 2 'FAIL detached-head' "init on a detached HEAD is refused"

# --- old pointers: every script refuses the previous contract number --------------------------------------------
for s in ship-init ship-status ship-sentinel ship-run ship-sync ship-push ship-census ship-watch ship-log; do
  run bash "$B/$s.sh" --contract=1 --skill-dir "$SKILL"
  expect 9 'FAIL contract-mismatch' "$s refuses --contract=1"
done

# --- the issues this branch targets -----------------------------------------------------------------------------
iss() { run bash "$B/ship-status.sh" --contract=2 issues; }
t_fixture iss "DEFAULT_MODE=offload" "ISSUE_MARKER_FILE=./.issue-numbers"
iss; expect 0 '^$' "on main, no marker: no issues, exit 0 before any ship-init"
# The branch's leading decimal digits of the WHOLE name, the reference derivation (a prefix like feat/ names none; the
# name is never parsed for a second number).
git checkout -q -b feat/7-x; iss; expect 0 '^$' "feat/7-x: no leading digits, no issue"
git checkout -q -b 12; iss; expect 0 '^12$' "a branch that is only a number"
git checkout -q -b 7-8-x; iss; expect 0 '^7$' "7-8-x: only the leading number (never a second one from the name)"
git checkout -q -b 18201-forecast-847-x; iss; expect 0 '^18201$' "a later number in the name is never an issue"
git checkout -q -b 12-x
echo 3 > .issue-numbers; iss; expect 0 '^3 12$' "the marker file joins, numerically sorted"
printf '010, 08\n12\n' > .issue-numbers; iss; expect 0 '^8 10 12$' "leading zeros are stripped as text, duplicates once"
printf '007' > .issue-numbers; iss; expect 0 '^7 12$' "007 reads as 7"
echo abc > .issue-numbers; iss; expect 3 '' "a malformed marker is exit 3"
if t_can_unreadable; then echo 3 > .issue-numbers; chmod 000 .issue-numbers; iss; expect 3 '' "an unreadable marker is exit 3"; chmod 644 .issue-numbers
else t_skip "an unreadable marker: chmod cannot take read access away here (root, or Windows)"; fi
rm -f .issue-numbers
mkdir .issue-numbers; iss; expect 3 '' "a marker path that is a directory is exit 3, never skipped"
rmdir .issue-numbers
printf '1*\n' > .issue-numbers; touch 12; iss; expect 3 '' "a marker holding a glob character is malformed, never expanded"
rm -f .issue-numbers 12
# A symlinked absolute spelling of the marker path names the same file everywhere.
if ! t_can_symlink; then t_skip "a marker path through a symlink: ln -s copies instead of linking here (Windows without developer mode)"
else
ln -s "$PWD" "$FIX/alias"; sed -i.bak 's#^ISSUE_MARKER_FILE=.*#ISSUE_MARKER_FILE='"$FIX/alias"'/.issue-numbers#' .claude/skills/ship/ship.env; rm -f .claude/skills/ship/ship.env.bak
echo 5 > .issue-numbers; iss; expect 0 '^5 12$' "an absolute marker path through a symlink is read"
run bash "$B/ship-sentinel.sh" --contract=2 untracked; refute_out 'issue-numbers' "and is never an untracked finding"
rm -f .issue-numbers
fi

# The worktree skill's own per-worktree file, written by its real create script.
cp -R "$T_ROOT/skills/worktree" .claude/skills/worktree && echo "BASE_BRANCH=main" > .claude/skills/worktree/worktree.env
run bash .claude/skills/worktree/bin/worktree-create.sh --no-base-update 7 9 12 bundle-7-9-12
expect 0 'PASS created' "the worktree skill creates a bundled worktree"
WT=$(printf '%s\n' "$OUT" | sed -n 's/.*path=\([^ ]*\).*/\1/p' | tail -1)
check "the worktree path was reported" test -d "$WT"
t_wt_run_in "$WT" bash "$B/ship-status.sh" --contract=2 issues
expect 0 '^7 9 12$' "ship reads the worktree skill's issue list"
mkdir -p "$WT/lib/sub"
t_wt_run_in "$WT/lib/sub" bash "../../$B/ship-status.sh" --contract=2 issues
expect 0 '^7 9 12$' "from a subdirectory too"
WI=$(git -C "$WT" rev-parse --path-format=absolute --git-path worktree-issues)
echo abc > "$WI"; t_wt_run_in "$WT" bash "$B/ship-status.sh" --contract=2 issues; expect 3 '' "a malformed worktree issue list is exit 3"
rm -f "$WI"; mkdir "$WI"; t_wt_run_in "$WT" bash "$B/ship-status.sh" --contract=2 issues; expect 3 '' "one that is a directory too, never an empty list"
rmdir "$WI"
: > "$WI"; t_wt_run_in "$WT" bash "$B/ship-status.sh" --contract=2 issues; expect 3 '' "an empty worktree issue list is exit 3, never 'no issues'"
printf -- '-\n' > "$WI"; t_wt_run_in "$WT" bash "$B/ship-status.sh" --contract=2 issues; expect 3 '' "a worktree issue list of separators only is exit 3"
printf '7\r9\n' > "$WI"; t_wt_run_in "$WT" bash "$B/ship-status.sh" --contract=2 issues; expect 3 '' "a carriage return inside the line is malformed, never 79"
printf '7-9-12\r\n' > "$WI"; t_wt_run_in "$WT" bash "$B/ship-status.sh" --contract=2 issues; expect 3 '' "a CRLF line ending is malformed too (refused, never guessed at)"
printf '07-9\n' > "$WI"; t_wt_run_in "$WT" bash "$B/ship-status.sh" --contract=2 issues; expect 3 '' "a leading zero is malformed"
printf '7--9\n' > "$WI"; t_wt_run_in "$WT" bash "$B/ship-status.sh" --contract=2 issues; expect 3 '' "a double dash is malformed"
printf '7-9-12\n' > "$WI"
if t_can_unreadable; then echo 7 > "$WI"; chmod 000 "$WI"; t_wt_run_in "$WT" bash "$B/ship-status.sh" --contract=2 issues; expect 3 '' "and an unreadable one"; chmod 644 "$WI"
else t_skip "an unreadable worktree marker: chmod cannot take read access away here (root, or Windows)"; fi

t_done
