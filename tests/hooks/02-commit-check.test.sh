#!/usr/bin/env bash
# commit-check.sh: every way of spelling a commit runs the repository's check, a failing / slow / unstartable check
# refuses the commit, and nothing that is not a commit is ever refused.
# Mutations this file must catch (run once by hand with HOOKS_UNDER_TEST=<mutated copy of hooks/>):
#   return 0 when the check exits non-zero · ignore -C (always check cwd) · a timeout counts as a pass.
. "$(dirname "$0")/../lib.sh"

M="$T_TMP/marker"; FAILF="$T_TMP/fail"
CHECK="COMMIT_CHECK_CMD=echo \"ran in \$(pwd -P)\" >> $M; echo check-output-line; test ! -f $FAILF"
t_hook_fixture cc "$CHECK" COMMIT_CHECK_TIMEOUT_SECS=5
MAIN="$HR"
C() { rm -f "$M"; t_hook commit-check "$(t_tool_json Bash command "$1")"; }
ran() { [ -f "$M" ]; }
ran_in() { grep -qx "ran in $1" "$M" 2>/dev/null; }

# --- trigger table: each form runs the check (proven by the marker) and passes -------------------------------------
for c in 'git commit -m x' 'git commit --amend --no-edit' 'git -c user.name=x commit -m y' "git -C $MAIN commit -m x" \
         "cd $MAIN && git commit -m x" 'GIT_AUTHOR_NAME=x git commit -m y' 'git add -A && git commit -m x' \
         'git status; git commit -qm x' '/usr/bin/git commit -m x' 'git --no-pager commit -m x' \
         'bash -c "git commit -m x"' 'git commit'; do
  C "$c"; expect_rc 0 "passes: $c"
  if ran_in "$MAIN"; then t_pass "check ran in the repository: $c"; else OUT="$(cat "$M" 2>/dev/null)"; t_fail "check ran in the repository: $c"; fi
done
C 'git commit -m x'; refute_out 'check-output-line' "a passing check is silent"

# --- not a commit: never refused ----------------------------------------------------------------------------------------
: > "$FAILF"
for c in 'git status' 'git log --grep=commit' 'echo commit' 'git commit-tree HEAD^{tree}' 'ls commit' 'npm run commitlint'; do
  C "$c"; expect_rc 0 "not refused: $c"
done
C 'git status'; if ran; then t_fail "git status does not run the check"; else t_pass "git status does not run the check"; fi
rm -f "$FAILF"

# --- failing, slow, unstartable --------------------------------------------------------------------------------------------
: > "$FAILF"
C 'git commit -m x'; expect_rc 2 "a failing check refuses the commit (exit 2)"
expect_out 'Commit refused: the commit check failed' "the refusal says what was refused"
expect_out 'check-output-line' "the refusal shows the check's output tail"
expect_out 'passes the repository.s check before it is committed' "the refusal names the rule"
rm -f "$FAILF"
# No stopwatch (wall time varies with the machine's load): the check leaves a marker only if it runs to its end, so a
# refusal that arrives while the marker is absent came from the timeout, not from waiting the check out.
SLOWDONE="$T_TMP/slow.done"
t_hook_fixture cc-slow "COMMIT_CHECK_CMD=sleep 60; touch $SLOWDONE" COMMIT_CHECK_TIMEOUT_SECS=1
C 'git commit -m x'
expect_rc 2 "a check that outlives its timeout refuses the commit"
expect_out 'did not finish within 1s' "the refusal names the timeout"
check "the refusal comes before the check ends (its end-marker is absent)" test ! -e "$SLOWDONE"
t_hook_fixture cc-missing 'COMMIT_CHECK_CMD=no-such-check-binary-here --run'
C 'git commit -m x'; expect_rc 2 "a check command that cannot start refuses the commit"
t_hook_fixture cc-empty 'COMMIT_CHECK_CMD='
C 'git commit -m x'; expect_rc 0 "an empty COMMIT_CHECK_CMD is not configured: allowed, nothing run"
t_hook_fixture cc-nokey
C 'git commit -m x'; expect_rc 0 "no COMMIT_CHECK_CMD line: allowed"
t_hook_fixture cc-bad "$CHECK"
echo 'garbage line' >> .claude/hooks/hooks.env
C 'git commit -m x'; expect_rc 2 "malformed hooks.env refuses the commit"
expect_out 'malformed' "the refusal says hooks.env is malformed"
t_hook_fixture cc-badto "$CHECK" COMMIT_CHECK_TIMEOUT_SECS=soon
C 'git commit -m x'; expect_rc 2 "a non-numeric timeout refuses the commit"
t_hook_fixture cc-zero-lead "$CHECK" COMMIT_CHECK_TIMEOUT_SECS=08
C 'git commit -m x'; expect_rc 0 "a timeout with a leading zero (08) is read in base 10: the check runs and passes"
if ran; then t_pass "…and the check ran"; else t_fail "…and the check ran"; fi
t_hook_fixture cc-zero "$CHECK" COMMIT_CHECK_TIMEOUT_SECS=0
C 'git commit -m x'; expect_rc 2 "a timeout of 0 refuses the commit"
expect_out '1 or more' "…and says the timeout must be 1 or more"
# A check that starts a background child: on the timeout the whole process group is stopped, so the child never writes.
# The child writes only once the test opens its gate, after the hook has returned (no race between a fixed sleep and a
# late kill on a loaded machine); a surviving child then writes within a tenth of a second.
PGF="$T_TMP/pg-child-wrote"; rm -f "$T_TMP/pg.go"
t_hook_fixture cc-pgroup "COMMIT_CHECK_CMD=(i=0; while [ ! -e $T_TMP/pg.go ] && [ \$i -lt 300 ]; do sleep 0.1; i=\$((i + 1)); done; : > $PGF) & sleep 30" COMMIT_CHECK_TIMEOUT_SECS=1
C 'git commit -m x'; expect_rc 2 "a check with a background child: refused on the timeout"
touch "$T_TMP/pg.go"; sleep 1
check "…and the check's background child was stopped with it (nothing written after the timeout)" test ! -e "$PGF"
# A child that ignores TERM is killed too (the hook sends KILL to the group after the timeout).
PGK="$T_TMP/pg-child-ignored-term"; rm -f "$T_TMP/pgk.go"
t_hook_fixture cc-pgkill "COMMIT_CHECK_CMD=(trap '' TERM; i=0; while [ ! -e $T_TMP/pgk.go ] && [ \$i -lt 300 ]; do sleep 0.1; i=\$((i + 1)); done; : > $PGK) & sleep 30" COMMIT_CHECK_TIMEOUT_SECS=1
C 'git commit -m x'; expect_rc 2 "a check whose child ignores TERM: refused on the timeout"
touch "$T_TMP/pgk.go"; sleep 1
check "…and that child was killed (nothing written)" test ! -e "$PGK"
# A passing check leaves no watcher sleep behind.
WT=$((3000 + RANDOM % 5000))
t_hook_fixture cc-nostray "$CHECK" COMMIT_CHECK_TIMEOUT_SECS=$WT
C 'git commit -m x'; expect_rc 0 "a passing check with a long timeout: allowed"
sleep 0.5
if t_is_windows; then t_skip "the watcher's sleep is gone: MSYS ps has no -o, so it cannot be listed by its arguments (Windows)"
else check "…and its watcher's sleep did not outlive the hook" sh -c '[ "$(ps -A -o args= | grep -cx "sleep $1")" = 0 ]' _ "$WT"; fi
if t_is_windows; then
  t_skip "a TERM sent to the hook's pid alone: MSYS emulates signals, and here it did not reach the hook's trap while it waited (a console Ctrl-C goes to every process on the console instead)"
else
# A TERM sent to the hook (git-hook mode, as a Ctrl-C would) stops the check too.
# The TERM is sent only once the check has started (its marker exists), so it can never land before the check runs and
# pass without testing anything; the child writes only after the test opens its gate.
PGS="$T_TMP/pg-hook-stopped"; rm -f "$T_TMP/pgs.go" "$T_TMP/pgs.started"
t_hook_fixture cc-sig "COMMIT_CHECK_CMD=: > $T_TMP/pgs.started; (i=0; while [ ! -e $T_TMP/pgs.go ] && [ \$i -lt 300 ]; do sleep 0.1; i=\$((i + 1)); done; : > $PGS) & sleep 30" COMMIT_CHECK_TIMEOUT_SECS=60
bash "$HD/commit-check.sh" --git-hook >/dev/null 2>&1 &
HP=$!
i=0; while [ ! -e "$T_TMP/pgs.started" ] && [ $i -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
check "the check started before the TERM was sent" test -e "$T_TMP/pgs.started"
kill -TERM "$HP"; wait "$HP" 2>/dev/null
touch "$T_TMP/pgs.go"; sleep 1
check "a TERM to the hook stops the check it started (nothing written)" test ! -e "$PGS"
fi

# --- targets ------------------------------------------------------------------------------------------------------------------
# A second worktree of the session's repository (same git common dir) with its own hooks.env.
cd "$MAIN" || exit 2; HR="$MAIN"; HD="$MAIN/.claude/hooks"
git add -A >/dev/null && git commit -qm base && git worktree add -q -b second "$T_TMP/cc-second" || exit 2
SECOND="$(cd "$T_TMP/cc-second" && pwd -P)"
printf 'COMMIT_CHECK_CMD=echo "ran in $(pwd -P)" >> %s; test ! -f %s\n' "$M" "$T_TMP/fail-second" > "$SECOND/.claude/hooks/hooks.env"
C "git -C $SECOND commit -m x"; expect_rc 0 "-C to a second governed worktree passes its own check"
if ran_in "$SECOND" && ! ran_in "$MAIN"; then t_pass "…and runs that worktree's check, not the session's"; else OUT="$(cat "$M" 2>/dev/null)"; t_fail "…and runs that worktree's check, not the session's"; fi
: > "$T_TMP/fail-second"
C "git -C $SECOND commit -m x"; expect_rc 2 "-C: the second worktree's failing check refuses the commit"
C "cd $SECOND && git commit -m x"; expect_rc 2 "cd: the second worktree's failing check refuses the commit"
C "git -C ../cc-second commit -m x"; expect_rc 2 "a relative -C is resolved against cwd"
rm -f "$T_TMP/fail-second"
# A cd inside a subshell, ( ... ) or $( ... ), ends at its ")": the commit after it runs in the session's folder.
: > "$FAILF"; C "(cd $SECOND && ls) && git commit -m x"; expect_rc 2 "a subshell cd does not leak: the session's failing check still runs"
C "echo \$(cd $SECOND && pwd) && git commit -m x"; expect_rc 2 "a \$( ) cd does not leak: the session's failing check still runs"
# A cd in a pipeline element or a background job runs in a subshell: the session's failing check still runs.
C "cd $SECOND | true; git commit -m x"; expect_rc 2 "a cd piped into another command does not leak"
C "cd $SECOND & git commit -m x"; expect_rc 2 "a backgrounded cd does not leak"
C "true | cd $SECOND && git commit -m x"; expect_rc 2 "a cd at the end of a pipeline does not leak"
C "{ cd $SECOND; } | true; git commit -m x"; expect_rc 2 "a cd in a brace group joined by a pipe does not leak"
C "cd $SECOND && true & git commit -m x"; expect_rc 2 "a cd in a backgrounded && list does not leak"
C "cd $SECOND && ls | wc -l; git commit -m x 2>&1 | tail -1"; expect_rc 0 "a cd before a pipeline later in its list still moves the commit"
C "cd $SECOND && git commit -m x 2>&1 | tail -1"; expect_rc 0 "a plain cd before a piped commit still moves the commit (no false refusal)"
rm -f "$FAILF"; : > "$T_TMP/fail-second"
C "(cd $SECOND && git commit -m x)"; expect_rc 2 "a commit inside the subshell still targets the cd folder"
C "(cd $SECOND; echo 'x)'; git commit -m y)"; expect_rc 2 "a quoted ')' does not end the subshell early"
# A nested shell that changes directory is not followed: refused, not silently allowed.
C "bash -c 'cd $SECOND && git commit -m x'"; expect_rc 2 "bash -c 'cd X && git commit': not silently allowed"
expect_out 'nested shell' "…and the refusal names the nested shell"
C "sh -c \"git -C $SECOND commit -m x\""; expect_rc 2 "sh -c \"git -C X commit\": not silently allowed"
C "bash <<< 'cd $SECOND && git commit -m x'"; expect_rc 2 "a nested shell fed by <<< that changes directory: not silently allowed"
C "echo 'cd $SECOND && git commit -m x' | bash"; expect_rc 2 "a nested shell fed by a pipe: not silently allowed"
C "printf 'cd $SECOND\\ngit commit -m x\\n' | sh"; expect_rc 2 "printf ... | sh: not silently allowed"
C "echo 'cd $SECOND && git commit -m x' | xargs -0 bash -c"; expect_rc 2 "... | xargs bash -c (no script word): not silently allowed"
C "cd $SECOND && bash -c 'git commit -m x'"; expect_rc 2 "a nested shell after a plain cd: that folder's failing check refuses"
rm -f "$T_TMP/fail-second"
C "cd $SECOND && bash -c 'git commit -m x'"; expect_rc 0 "…and with a passing check the nested commit is allowed"
# A commit message that names these shell forms is text, not a nested shell (the standard heredoc message form).
# CN: like C, for a command with newlines (t_tool_json does not escape them).
CN() {
  local v; v="$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{ printf "%s%s", (NR > 1 ? "\\n" : ""), $0 }')"
  rm -f "$M"; t_hook commit-check "{\"cwd\":\"$HR\",\"permission_mode\":\"default\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$v\"}}"
}
CN "git add -A && git commit -m \"\$(cat <<'EOF'
Refuse bash <<< and | sh forms; cd into a worktree first
EOF
)\""; expect_rc 0 "a heredoc commit message naming bash <<<, | sh and cd is not a nested shell"
CN "git commit -F - <<'EOF'
Refuse bash <<< and | sh forms; cd into a worktree first
EOF"; expect_rc 0 "an unquoted heredoc message body naming them is not a nested shell either"
CN "bash <<EOF
cd $SECOND
git commit -m x
EOF"; expect_rc 2 "a shell fed a heredoc that changes directory and commits: still refused"
C "bash -c 'cd $SECOND && ls'"; expect_rc 0 "a nested shell that changes directory but makes no commit is allowed"
C 'git -C "$X" commit -m x'; expect_rc 2 "-C with a variable is refused"
expect_out 'not a literal path' "the refusal asks for a literal path"
C 'cd $(mktemp -d) && git commit -m x'; expect_rc 2 "cd to a substitution is refused"
C "cd $T_TMP/not-yet && git commit -m x"; expect_rc 2 "a commit target that does not exist yet is refused"
# A worktree whose path has a space, named with quotes.
git worktree add -q -b spaced "$T_TMP/cc space" || exit 2
SPACED="$(cd "$T_TMP/cc space" && pwd -P)"
printf 'COMMIT_CHECK_CMD=echo "ran in $(pwd -P)" >> %s\n' "$M" > "$SPACED/.claude/hooks/hooks.env"
C "git -C \"$SPACED\" commit -m x"; expect_rc 0 "-C with a quoted path that has a space: passes"
if ran_in "$SPACED"; then t_pass "…and that worktree's check ran"; else OUT="$(cat "$M" 2>/dev/null)"; t_fail "…and that worktree's check ran"; fi
C "cd '$SPACED' && git commit -m x"; expect_rc 0 "cd with a single-quoted path that has a space: passes"
if ran_in "$SPACED"; then t_pass "…and that worktree's check ran"; else OUT="$(cat "$M" 2>/dev/null)"; t_fail "…and that worktree's check ran"; fi
C "cd $T_TMP/not-yet && git commit -m x"; expect_out 'could not be read from the command' "a missing target: the refusal does not claim more than it knows"
mkdir -p "$T_TMP/ungoverned" && (cd "$T_TMP/ungoverned" && git init -q -b main .)
: > "$FAILF"
C "git -C $T_TMP/ungoverned commit -m x"; expect_rc 0 "a target repository with no hooks.env is not governed"
rm -f "$FAILF"

# --- review findings: other spellings of a commit -------------------------------------------------------------------
C 'git --git-dir .git --work-tree . commit -m x'; expect_rc 0 "separated --git-dir/--work-tree: passes"
if ran_in "$MAIN"; then t_pass "separated --git-dir/--work-tree: the check ran"; else OUT="$(cat "$M" 2>/dev/null)"; t_fail "separated --git-dir/--work-tree: the check ran"; fi
C "git --work-tree $SECOND --git-dir $MAIN/.git commit -m x"
if ran_in "$SECOND"; then t_pass "separated --work-tree <dir>: that tree's check ran"; else OUT="$(cat "$M" 2>/dev/null)"; t_fail "separated --work-tree <dir>: that tree's check ran"; fi
C 'git --git-dir=.git commit -m x'
if ran_in "$MAIN"; then t_pass "--git-dir=X alone: the check ran for the work tree"; else t_fail "--git-dir=X alone: the check ran for the work tree"; fi
C "pushd $SECOND && git commit -m x"
if ran_in "$SECOND"; then t_pass "pushd: the target folder's check ran"; else OUT="$(cat "$M" 2>/dev/null)"; t_fail "pushd: the target folder's check ran"; fi
git config alias.ci commit
C 'git ci -m x'
if ran_in "$MAIN"; then t_pass "an alias for commit (git ci): the check ran"; else t_fail "an alias for commit (git ci): the check ran"; fi
git config alias.sv '!git commit -am wip'
C 'git sv'
if ran_in "$MAIN"; then t_pass "a shell alias that commits: the check ran"; else t_fail "a shell alias that commits: the check ran"; fi
git config alias.st status
C 'git st'; if ran; then t_fail "an alias for status does not run the check"; else t_pass "an alias for status does not run the check"; fi
: > "$FAILF"; C 'git ci -m x'; expect_rc 2 "an alias for commit: a failing check refuses"; rm -f "$FAILF"

rm -f "$M"; t_hook commit-check "$(t_tool_json Bash command "cd /tmp && GIT_DIR=$MAIN/.git GIT_WORK_TREE=$MAIN git commit -m x")"
if ran_in "$MAIN"; then t_pass "GIT_DIR=/GIT_WORK_TREE= from outside the repository: the check ran"; else OUT="$(cat "$M" 2>/dev/null)"; t_fail "GIT_DIR=/GIT_WORK_TREE= from outside the repository: the check ran"; fi
rm -f "$M"; t_hook commit-check "$(t_tool_json Bash command "GIT_WORK_TREE=$SECOND git commit -m x")"
if ran_in "$SECOND"; then t_pass "GIT_WORK_TREE=<dir>: that tree's check ran"; else OUT="$(cat "$M" 2>/dev/null)"; t_fail "GIT_WORK_TREE=<dir>: that tree's check ran"; fi

# --- review findings: another repository's check is never run before you approve -------------------------------------
cd "$T_TMP" || exit 2
t_hook_fixture cc-foreign "COMMIT_CHECK_CMD=echo \"ran in \$(pwd -P)\" >> $M"
FOREIGN="$HR"
cd "$MAIN" || exit 2; HR="$MAIN"; HD="$MAIN/.claude/hooks"
C "cd $FOREIGN && git commit -m x"; expect_decision ask "a commit in another repository → ask"
expect_out 'another repository' "the answer says it is another repository"
if ran; then t_fail "…and that repository's check was not run"; else t_pass "…and that repository's check was not run"; fi
C "git -C $FOREIGN commit -m x"; expect_decision ask "git -C another repository → ask"
rm -f "$M"; t_hook commit-check "$(t_tool_json Bash command "git -C $FOREIGN commit -m x" bypassPermissions)"
expect_decision deny "another repository in bypassPermissions → deny"
# An alias defined only in the other repository's configuration is still recognized there.
git -C "$FOREIGN" config alias.fci commit
C "git -C $FOREIGN fci -m x"; expect_decision ask "an alias defined only in the -C target → ask"
C "cd $FOREIGN && git fci -m x"; expect_decision ask "an alias defined only in the cd target → ask"
C 'git fci -m x'; expect_decision none "that alias is not a commit in the session's own folder"

# --- parsers --------------------------------------------------------------------------------------------------------------------
NOJQ="$(t_path_without jq)"
if PATH="$NOJQ" python3 -I -c 'import json' >/dev/null 2>&1; then   # a python3 that runs (not Windows' Store alias)
  rm -f "$M"; T_STDIN="$(t_tool_json Bash command "git -C $MAIN commit -m x")"; run env PATH="$NOJQ" bash "$HD/commit-check.sh"
  expect_rc 0 "python3 only: -C commit passes"; if ran_in "$MAIN"; then t_pass "python3 only: the check ran"; else t_fail "python3 only: the check ran"; fi
else
  echo "  SKIP  python3 is not installed here"
fi
NONE="$(t_path_without jq python3)"
rm -f "$M"; T_STDIN="$(t_tool_json Bash command 'git commit -m x')"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$MAIN" bash "$HD/commit-check.sh"
expect_rc 0 "no parser: a plain commit passes"; if ran_in "$MAIN"; then t_pass "no parser: the check ran for the session repository"; else t_fail "no parser: the check ran for the session repository"; fi
: > "$FAILF"
T_STDIN="$(t_tool_json Bash command 'git commit -m x')"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$MAIN" bash "$HD/commit-check.sh"
expect_rc 2 "no parser: a failing check refuses"
rm -f "$FAILF"
T_STDIN="$(t_tool_json Bash command "git -C $SECOND commit -m x")"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$MAIN" bash "$HD/commit-check.sh"
expect_rc 2 "no parser: a commit naming another directory is refused (asks for a parser)"
T_STDIN="$(t_tool_json Bash command 'git status')"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$MAIN" bash "$HD/commit-check.sh"
expect_rc 0 "no parser: not a commit → allowed"
# A python3 that is on PATH but does not run (Windows' Microsoft Store alias exits 49) is no parser: never exit 2 for
# every Bash call.
mkdir -p "$T_TMP/stubpy" && printf '#!/bin/sh\necho "Python was not found" >&2\nexit 49\n' > "$T_TMP/stubpy/python3" && chmod +x "$T_TMP/stubpy/python3"
T_STDIN="$(t_tool_json Bash command 'git status')"; run env PATH="$T_TMP/stubpy:$NONE" CLAUDE_PROJECT_DIR="$MAIN" bash "$HD/commit-check.sh"
expect_rc 0 "a python3 that does not run: not a commit → allowed"
rm -f "$M"; T_STDIN="$(t_tool_json Bash command 'git commit -m x')"; run env PATH="$T_TMP/stubpy:$NONE" CLAUDE_PROJECT_DIR="$MAIN" bash "$HD/commit-check.sh"
expect_rc 0 "a python3 that does not run: a plain commit takes the no-parser path and passes"
if ran_in "$MAIN"; then t_pass "…and the check ran"; else t_fail "…and the check ran"; fi

# --- input and the git-native mode ----------------------------------------------------------------------------------------------
t_hook commit-check 'not json'; expect_rc 2 "unreadable input → exit 2"
t_hook commit-check '{"tool_name":"Bash","tool_input":{}}'; expect_rc 0 "no command → allowed"
run bash "$HD/commit-check.sh" --bogus; expect_rc 2 "unknown argument → exit 2"
rm -f "$M"; run bash "$HD/commit-check.sh" --git-hook; expect_rc 0 "--git-hook: passing check → 0"
if ran_in "$MAIN"; then t_pass "--git-hook: the check ran in the repository"; else t_fail "--git-hook: the check ran in the repository"; fi
: > "$FAILF"
run bash "$HD/commit-check.sh" --git-hook; expect_rc 1 "--git-hook: failing check → 1 (git refuses the commit)"
printf '#!/bin/sh\nexec bash "$(git rev-parse --show-toplevel)/.claude/hooks/commit-check.sh" --git-hook\n' > "$MAIN/.git/hooks/pre-commit"
chmod +x "$MAIN/.git/hooks/pre-commit"
echo change >> "$MAIN/x.txt"; git add -A >/dev/null 2>&1; run git commit -qm "through git"; expect_rc 1 "a real git commit is refused by the pre-commit line when the check fails"
rm -f "$FAILF"
run git commit -qm "through git"; expect_rc 0 "…and goes through when it passes"
# From a linked worktree (git sets GIT_DIR and GIT_INDEX_FILE for the hook): a check that runs git in another folder
# acts on that folder, not on the worktree being committed.
SCR="$T_TMP/check-scratch"
git worktree add -q -b gitenv "$T_TMP/cc-gitenv" || exit 2
printf 'COMMIT_CHECK_CMD=rm -rf %s && mkdir -p %s && cd %s && git init -q && echo x > scratch-file && git add scratch-file\n' "$SCR" "$SCR" "$SCR" \
  > "$T_TMP/cc-gitenv/.claude/hooks/hooks.env"
cd "$T_TMP/cc-gitenv" || exit 2
echo change >> y.txt; git add y.txt >/dev/null 2>&1; run git commit -qm "from a worktree"
expect_rc 0 "a pre-commit from a linked worktree: the check passes"
check "…the check's own git ran in its scratch folder" sh -c 'git -C "$1" ls-files | grep -qx scratch-file' _ "$SCR"
check "…and did not touch the worktree's index" sh -c '! git ls-files | grep -qx scratch-file'
check "…nor the commit" sh -c '! git show --name-only --format= HEAD | grep -qx scratch-file'
cd "$MAIN" || exit 2

# --- the settings fragment's handler when the script is missing ----------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  H="$(jq -r '."commit-check".handler.command' "$T_ROOT/hooks/settings.fragment.json" | tr -d '\r')"   # a Windows jq.exe ends lines with CRLF
  check "the fragment is valid JSON with a commit-check command" test -n "$H"
  check "the handler command parses" bash -n -c "$H"
  frag() { T_STDIN="$(t_tool_json Bash command "$1" "${2:-default}")"; run env CLAUDE_PROJECT_DIR="$HR" bash -c "$H"; }
  t_hook_fixture cc-frag "$CHECK"; rm -f "$HD/commit-check.sh"
  frag 'git commit -m x'; expect_decision ask "script missing, COMMIT_CHECK_CMD still set: a commit → ask"
  expect_out 'commit check script is missing' "…and the reason says the script is missing"
  frag 'git commit -m x' bypassPermissions; expect_decision deny "…and deny in bypassPermissions"
  frag 'git status'; expect_rc 0 "script missing: not a commit → allowed"; refute_out permissionDecision "…with no decision"
  t_hook_fixture cc-frag-off 'COMMIT_CHECK_CMD='; rm -f "$HD/commit-check.sh"
  frag 'git commit -m x'; expect_rc 0 "script missing, COMMIT_CHECK_CMD empty → allowed"
  refute_out permissionDecision "…with no decision"; expect_out 'not installed' "…and the not-installed note"
  cd "$MAIN" || exit 2; HR="$MAIN"; HD="$MAIN/.claude/hooks"
else
  echo "  SKIP  jq is not installed here (fragment handler)"
fi
t_done
