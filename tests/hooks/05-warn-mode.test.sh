#!/usr/bin/env bash
# Warn-only mode (HOOKS_MODE=warn): the installer's --mode is in the plan and its hash and lands in hooks.env; the
# guard and the commit check allow and print what they would have done, except that the settings files are still
# asked about; no HOOKS_MODE line = enforce (the behaviour before the key existed).
# Mutations this file must catch: ignore HOOKS_MODE in the guard · let warn mode skip the settings files · leave the
# mode out of the hashed plan · treat a missing key as warn.
. "$(dirname "$0")/../lib.sh"
command -v jq >/dev/null 2>&1 || { echo "  SKIP  jq is required by hooks-install.sh and by this test"; t_done; exit $?; }

unset CLAUDE_PROJECT_DIR
SRC="${HOOKS_UNDER_TEST:-$T_ROOT/hooks}"
I="$SRC/bin/hooks-install.sh"
ALL=protected-file-guard,commit-check,pending-question-reprint
mkdir -p "$T_TMP/claude-bin" && printf '#!/bin/sh\necho "2.1.326 (Claude Code)"\n' > "$T_TMP/claude-bin/claude" && chmod +x "$T_TMP/claude-bin/claude"
NEWP="$T_TMP/claude-bin:$PATH"
plan() { run env PATH="$NEWP" bash "$I" plan "$@"; HASH="$(printf '%s\n' "$LAST" | sed -n 's/.*PLAN hash=//p')"; }
apply() { run env PATH="$NEWP" bash "$I" apply "$@" --approved "$HASH"; }
modes() { grep -c '^HOOKS_MODE=' .claude/hooks/hooks.env; }

# --- installer ---------------------------------------------------------------------------------------------------------
T_HOOK_LIST='.gitignore' t_hook_fixture inst 'COMMIT_CHECK_CMD=true' COMMIT_CHECK_TIMEOUT_SECS=30
rm -f .claude/hooks/*.sh
plan --hooks "$ALL" --settings .claude/settings.json
expect 0 'PLAN hash=' "plan without --mode and no HOOKS_MODE line → PLAN"
expect_out '^Mode: enforce .*now: absent' "default mode is enforce, shown in the plan"
plan --hooks "$ALL" --settings .claude/settings.json --mode enforce; HE="$HASH"
expect_out '^Mode: enforce' "plan --mode enforce shows the mode"
plan --hooks "$ALL" --settings .claude/settings.json --mode warn; HW="$HASH"
expect 0 'PLAN hash=' "plan --mode warn → PLAN"
expect_out '^Mode: warn' "plan --mode warn shows the mode"
expect_out 'warn-only' "plan --mode warn says what warn mode does"
expect_out '^onFailure: left out \(warn mode\)' "plan --mode warn leaves onFailure out and says so"
check "plan wrote nothing (mode)" bash -c '! grep -q HOOKS_MODE .claude/hooks/hooks.env'
if [ -n "$HW" ] && [ "$HW" != "$HE" ]; then t_pass "the hash covers the mode (warn and enforce differ)"; else t_fail "the hash covers the mode (warn and enforce differ)" "warn=$HW enforce=$HE"; fi
HASH="$HW"; apply --hooks "$ALL" --settings .claude/settings.json --mode enforce
expect 4 'FAIL plan-changed' "apply --mode enforce with the warn plan's hash → refused (exit 4)"
check "a refused apply wrote no settings" test ! -e .claude/settings.json
run env PATH="$NEWP" bash "$I" plan --hooks "$ALL" --settings .claude/settings.json --mode off
expect 2 'FAIL usage mode-must-be-warn-or-enforce' "--mode with another value → usage"
HASH="$HW"; apply --hooks "$ALL" --settings .claude/settings.json --mode warn
expect 0 'PASS applied' "apply --mode warn with its hash → applied"
check "hooks.env has HOOKS_MODE=warn" grep -qx 'HOOKS_MODE=warn' .claude/hooks/hooks.env
check "hooks.env keeps its other lines" grep -qx 'COMMIT_CHECK_CMD=true' .claude/hooks/hooks.env
check "warn mode: no onFailure written (a crash lets the call through)" jq -e '[.. | objects | select(has("onFailure"))] == [] and (.hooks.PreToolUse | length == 2)' .claude/settings.json
run bash .claude/hooks/hooks-check.sh
expect 0 'PASS verified hooks=3' "hooks-check in warn mode → verified"
expect_out '^NOTE: mode: warn — NOT ENFORCED' "hooks-check reports warn mode as a NOTE (a follow-up), never as ok"
expect_out '^NOTE: mode: warn.*--mode enforce.*--approved' "…naming the plan-then-apply command that switches it on"
refute_out '^FAIL' "…and warn mode alone is never a FAIL (the install runs in warn mode and must pass)"
expect_out 'guard \(warn mode\) allows an edit' "hooks-check probes the warn answer"
expect_out 'the registered guard handler, run as the harness runs it, asks before an edit of \.claude/settings\.json' "hooks-check: the wired handler still asks for the settings file in warn mode"
plan --hooks "$ALL" --settings .claude/settings.json
expect_out '^Mode: warn .*now: warn' "plan without --mode keeps the current mode (an --update never switches warn on by accident)"
plan --hooks "$ALL" --settings .claude/settings.json --mode enforce
expect_out '^Mode: enforce .*now: warn' "switching on: plan --mode enforce shows the change"
apply --hooks "$ALL" --settings .claude/settings.json --mode enforce
expect 0 'PASS applied' "switching on: apply --mode enforce → applied"
check "hooks.env now says HOOKS_MODE=enforce" grep -qx 'HOOKS_MODE=enforce' .claude/hooks/hooks.env
if [ "$(modes)" = 1 ]; then t_pass "one HOOKS_MODE line, replaced in place"; else t_fail "one HOOKS_MODE line, replaced in place" "got $(modes)"; fi
check "switching on: the guard and the commit check get onFailure block back, without --update" \
  jq -e '[.hooks.PreToolUse[].hooks[] | select(.command | test("guard|commit-check")) | .onFailure] == ["block","block"] and (.hooks.PreToolUse | length == 2)' .claude/settings.json
run bash .claude/hooks/hooks-check.sh
expect 0 'PASS verified hooks=3' "hooks-check in enforce mode → verified"
expect_out '^ok: mode: enforce' "hooks-check reports enforce mode"

# A new hooks.env (copied from the example, which says enforce) gets the requested mode.
T_HOOK_LIST='.gitignore' t_hook_fixture inst-new
rm -f .claude/hooks/*.sh .claude/hooks/hooks.env
plan --hooks protected-file-guard --settings .claude/settings.local.json --mode warn
expect 0 'PLAN hash=' "plan --mode warn with no hooks.env → PLAN"
apply --hooks protected-file-guard --settings .claude/settings.local.json --mode warn
expect 0 'PASS applied' "apply --mode warn with no hooks.env → applied"
check "new hooks.env: HOOKS_MODE=warn" grep -qx 'HOOKS_MODE=warn' .claude/hooks/hooks.env
if [ "$(modes)" = 1 ]; then t_pass "new hooks.env: one HOOKS_MODE line"; else t_fail "new hooks.env: one HOOKS_MODE line" "got $(modes)"; fi

# The git pre-commit line honours warn mode, with the commit check installed and with it missing.
T_HOOK_LIST='.gitignore' t_hook_fixture inst-pc 'COMMIT_CHECK_CMD=false' COMMIT_CHECK_TIMEOUT_SECS=5
rm -f .claude/hooks/*.sh
plan --hooks commit-check --settings .claude/settings.json --git-pre-commit --mode warn
apply --hooks commit-check --settings .claude/settings.json --git-pre-commit --mode warn
expect 0 'PASS applied' "apply --mode warn --git-pre-commit → applied"
run sh .git/hooks/pre-commit; expect_rc 0 "warn mode: the pre-commit hook does not block a failing check"
expect_out '^warn-only: would have refused this commit' "warn mode: the pre-commit hook warns"
rm -f .claude/hooks/commit-check.sh
run sh .git/hooks/pre-commit; expect_rc 0 "warn mode: the pre-commit line with commit-check.sh missing does not block"
expect_out '^warn-only: would have refused this commit' "warn mode: …and warns"
cp .claude/hooks/hooks.env "$T_TMP/env.lf"; t_crlf "$T_TMP/env.lf" .claude/hooks/hooks.env
run sh .git/hooks/pre-commit; expect_rc 0 "warn mode in a CRLF hooks.env: the pre-commit line with commit-check.sh missing does not block"
cat "$T_TMP/env.lf" > .claude/hooks/hooks.env
grep -v '^HOOKS_MODE=' .claude/hooks/hooks.env > "$T_TMP/env" && cat "$T_TMP/env" > .claude/hooks/hooks.env
run sh .git/hooks/pre-commit; expect_rc 1 "enforce (no key): the pre-commit line with commit-check.sh missing refuses"

# --- the guard ---------------------------------------------------------------------------------------------------------
E() { t_hook protected-file-guard "$(t_tool_json Edit file_path "$1" "${2:-default}")"; }
B() { t_hook protected-file-guard "$(t_tool_json Bash command "$1" "${2:-default}")"; }
warned() {  # warned <label> — allowed (rc 0, no decision) with a warn-only line
  if [ "$RC" = 0 ] && ! printf '%s' "$OUT" | grep -q permissionDecision && printf '%s\n' "$OUT" | grep -q '^warn-only: '; then t_pass "$1"
  else t_fail "$1" "want rc=0, no permissionDecision, a warn-only: line" "got rc=$RC"; fi
}

t_hook_fixture g-default
E "$HR/.gitignore"; expect_decision ask "no HOOKS_MODE line → enforce: the guard asks"
t_hook_fixture g-enforce HOOKS_MODE=enforce
E "$HR/.gitignore"; expect_decision ask "HOOKS_MODE=enforce → the guard asks"
t_hook_fixture g-other HOOKS_MODE=Warn
E "$HR/.gitignore"; expect_decision ask "HOOKS_MODE with another spelling → enforce"
t_hook_fixture g-warn HOOKS_MODE=warn
E "$HR/.gitignore"; warned "warn mode: an Edit of a listed file is allowed with a warning"
expect_out '^warn-only: \.gitignore matches "\.gitignore" in \.claude/protected-files\.txt' "the warning names file, glob and list"
expect_out '"systemMessage":"warn-only: ' "the warning is also the hook's systemMessage"
E "$HR/.github/workflows/ci.yml" bypassPermissions; warned "warn mode: no deny in bypassPermissions either"
E "$HR/.claude/hooks/hooks.env"; warned "warn mode: the hooks folder is warned about, not asked"
B "rm .gitignore"; warned "warn mode: a Bash write to a listed file is allowed with a warning"
B "git clean -fdx"; warned "warn mode: a wholesale tree rewrite is allowed with a warning"
E "$HR/src/app.ts"; expect_decision none "warn mode: an unlisted file stays silent"
B "cat .gitignore"; expect_decision none "warn mode: a read stays silent"
E "$HR/.claude/settings.json"; expect_decision ask "warn mode: .claude/settings.json is still asked about"
E "$HR/.claude/settings.local.json"; expect_decision ask "warn mode: .claude/settings.local.json is still asked about"
E "$HR/.claude/settings.json" bypassPermissions; expect_decision deny "warn mode: settings file in bypassPermissions → deny"
B "echo {} > .claude/settings.json"; expect_decision ask "warn mode: a Bash write to settings.json is still asked about"
B "cp x .claude/settings.local.json"; expect_decision ask "warn mode: a Bash write to settings.local.json is still asked about"
NONE="$(t_path_without jq python3)"
T_STDIN="$(t_tool_json Edit file_path "$HR/.claude/settings.json")"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"
expect_decision ask "warn mode, no JSON parser: a settings file is still asked about"
T_STDIN="$(t_tool_json Edit file_path "$HR/.gitignore")"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"
warned "warn mode, no JSON parser: a file edit is allowed with a warning"
mkdir -p "$T_TMP/elsewhere/.claude"
E "$T_TMP/elsewhere/.claude/settings.json"; expect_decision ask "warn mode: a settings file outside the repository is still asked about"

# --- the commit check ----------------------------------------------------------------------------------------------------
C() { t_hook commit-check "$(t_tool_json Bash command "$1")"; }
t_hook_fixture c-default 'COMMIT_CHECK_CMD=echo failing-check-output; false' COMMIT_CHECK_TIMEOUT_SECS=5
C 'git commit -m x'; expect_rc 2 "no HOOKS_MODE line → enforce: a failing check refuses the commit"
expect_out 'Commit refused' "enforce: the refusal is said"
run bash .claude/hooks/commit-check.sh --git-hook; expect_rc 1 "enforce: the git pre-commit mode refuses (exit 1)"
t_hook_fixture c-warn 'COMMIT_CHECK_CMD=echo failing-check-output; false' COMMIT_CHECK_TIMEOUT_SECS=5 HOOKS_MODE=warn
C 'git commit -m x'; expect_rc 0 "warn mode: a failing check does not block the commit"
expect_out '^warn-only: would have refused this commit' "warn mode: says what it would have refused"
expect_out 'failing-check-output' "warn mode: the check still ran and its output is shown"
expect_out '"systemMessage":"warn-only: ' "warn mode: the warning is also the hook's systemMessage"
C 'cd "$X" && git commit -m x'; expect_rc 0 "warn mode: a non-literal cd is not refused either"
expect_out '^warn-only: ' "warn mode: the non-literal cd is warned about"
run bash .claude/hooks/commit-check.sh --git-hook; expect_rc 0 "warn mode: the git pre-commit mode does not block"
expect_out '^warn-only: would have refused this commit' "warn mode: the git pre-commit mode warns"
C 'git status'; expect_decision none "warn mode: a non-commit stays silent"
# One command, two worktrees: a warn-mode target's failing check must not end the call before an enforce target's.
git add -A >/dev/null && git commit -qm base && git worktree add -q -b enf "$T_TMP/c-warn-enf" || exit 2
ENF="$(cd "$T_TMP/c-warn-enf" && pwd -P)"
printf 'COMMIT_CHECK_CMD=echo enforce-check-ran; false\nCOMMIT_CHECK_TIMEOUT_SECS=5\n' > "$ENF/.claude/hooks/hooks.env"
C "git commit -m x && git -C $ENF commit -m y"; expect_rc 2 "warn target then enforce target: the enforce target's failing check still refuses"
expect_out 'enforce-check-ran' "…and the enforce target's check ran after the warn target's warning"
printf 'COMMIT_CHECK_CMD=echo second-warn-ran; false\nCOMMIT_CHECK_TIMEOUT_SECS=5\nHOOKS_MODE=warn\n' > "$ENF/.claude/hooks/hooks.env"
C "git commit -m x && git -C $ENF commit -m y"; expect_rc 0 "two warn targets: allowed"
expect_out 'second-warn-ran' "…both targets' checks ran"
if [ "$(printf '%s\n' "$OUT" | grep -c '"systemMessage"')" = 1 ]; then t_pass "…with one systemMessage for both warnings"; else t_fail "…with one systemMessage for both warnings" "$OUT"; fi

# review-nudge installs through the same plan/apply flow, under Stop, without onFailure, and hooks-check probes it.
T_HOOK_LIST='.gitignore' t_hook_fixture inst-nudge
rm -f .claude/hooks/*.sh
plan --hooks protected-file-guard,review-nudge --settings .claude/settings.json --mode warn
expect 0 'PLAN hash=' "plan with review-nudge → PLAN"
expect_out 'add +review-nudge \(Stop\)' "review-nudge is wired under Stop"
apply --hooks protected-file-guard,review-nudge --settings .claude/settings.json --mode warn
expect 0 'PASS applied' "apply with review-nudge → applied"
check "review-nudge's handler: Stop, timeout 30, no onFailure" \
  jq -e '[.hooks.Stop[].hooks[] | select(.command | test("review-nudge"))] | length == 1 and (.[0].timeout == 30) and (.[0] | has("onFailure") | not)' .claude/settings.json
run bash .claude/hooks/hooks-check.sh
expect 0 'PASS verified hooks=2' "hooks-check with review-nudge → verified"
expect_out '^ok: review-nudge is silent on a repeated stop' "hooks-check probes review-nudge"
expect_out '^NOTE: review-nudge installed, but the review-code or ship skill is not' "hooks-check says review-nudge is idle without the review and ship skills"

t_done
