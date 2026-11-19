#!/usr/bin/env bash
# hooks-install.sh, settings.fragment.json and hooks-check.sh: the settings entries the onboarding would write are
# valid JSON with the right event and matcher shape; plan writes nothing; apply writes exactly the approved plan, keeps
# everything it did not write, and is idempotent; hooks-check reports what is and is not wired.
# Mutations this file must catch (run once by hand on a temp copy of hooks/): apply without checking --approved ·
# overwrite a differing installed script without --update · keep onFailure for an old harness.
. "$(dirname "$0")/../lib.sh"
command -v jq >/dev/null 2>&1 || { echo "  SKIP  jq is required by hooks-install.sh and by this test"; t_done; exit $?; }

SRC="${HOOKS_UNDER_TEST:-$T_ROOT/hooks}"
FRAG="$SRC/settings.fragment.json"
I="$SRC/bin/hooks-install.sh"
ALL=protected-file-guard,commit-check,pending-question-reprint

# --- the fragment ---------------------------------------------------------------------------------------------------
check "fragment is valid JSON" jq -e . "$FRAG"
check "fragment has exactly the four pack hooks" jq -e 'keys == ["commit-check","pending-question-reprint","protected-file-guard","review-nudge"]' "$FRAG"
check "review-nudge's fragment: Stop, no matcher, no onFailure" jq -e '.["review-nudge"] | .event == "Stop" and (has("matcher") | not) and (.handler | has("onFailure") | not)' "$FRAG"
for h in protected-file-guard commit-check pending-question-reprint; do
  check "fragment: $h names a script that exists" test -f "$SRC/$h.sh"
  check "fragment: $h handler is a command hook running its script from the repository's top folder" \
    jq -e --arg h "$h" '.[$h].handler | .type == "command" and (.command | contains("/.claude/hooks/" + $h + ".sh") and contains("rev-parse --show-toplevel") and contains("$CLAUDE_PROJECT_DIR")) and (.timeout | type) == "number"' "$FRAG"
done
check "fragment: the guard is PreToolUse on Edit|Write|NotebookEdit|Bash, onFailure block" \
  jq -e '.["protected-file-guard"] | .event == "PreToolUse" and .matcher == "Edit|Write|NotebookEdit|Bash" and .handler.onFailure == "block"' "$FRAG"
check "fragment: the commit check is PreToolUse on Bash, onFailure block" \
  jq -e '.["commit-check"] | .event == "PreToolUse" and .matcher == "Bash" and .handler.onFailure == "block"' "$FRAG"
check "fragment: the reprint is Stop, no matcher, no onFailure (it has no effect on Stop)" \
  jq -e '.["pending-question-reprint"] | .event == "Stop" and (has("matcher") | not) and (.handler | has("onFailure") | not)' "$FRAG"
check "fragment: only documented handler keys" \
  jq -e '[.[].handler | keys[]] | unique - ["command","onFailure","timeout","type"] == []' "$FRAG"

# A stub claude on PATH answers the version the onFailure gate reads.
stub() { mkdir -p "$T_TMP/claude-$1" && printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" > "$T_TMP/claude-$1/claude" && chmod +x "$T_TMP/claude-$1/claude"; printf '%s' "$T_TMP/claude-$1:$PATH"; }
NEWP="$(stub 2.1.326)"; OLDP="$(stub 2.1.294)"
plan() { run env PATH="$NEWP" bash "$I" plan "$@"; HASH="$(printf '%s\n' "$LAST" | sed -n 's/.*PLAN hash=//p')"; }
apply() { run env PATH="$NEWP" bash "$I" apply "$@" --approved "$HASH"; }
fixture() {
  T_HOOK_LIST='.gitignore' t_hook_fixture "$1" 'COMMIT_CHECK_CMD=true' COMMIT_CHECK_TIMEOUT_SECS=30
  rm -rf .claude/hooks/*.sh   # the installer copies them; only hooks.env and the list are pre-written
}

# --- no settings file ---------------------------------------------------------------------------------------------------
fixture fresh
plan --hooks "$ALL" --settings .claude/settings.json
expect 0 'PLAN hash=' "plan with no settings file → PLAN"
check "plan wrote nothing (no settings file)" test ! -e .claude/settings.json
check "plan wrote nothing (no scripts)" test ! -e .claude/hooks/hook-lib.sh
expect_out '^\+\+\+ b/\.claude/settings\.json' "plan shows a unified diff of the settings file"
expect_out 'onFailure: block' "a current harness gets onFailure"
apply --hooks "$ALL" --settings .claude/settings.json
expect 0 'PASS applied' "apply with the plan's hash → applied"
check "settings file is valid JSON" jq -e . .claude/settings.json
check "settings: only a hooks key and the default subagent model" jq -e 'keys == ["env","hooks"] and .env == {"CLAUDE_CODE_SUBAGENT_MODEL":"sonnet"}' .claude/settings.json
check "settings: PreToolUse has the guard (matcher, onFailure) then the commit check" jq -e '
  .hooks.PreToolUse | length == 2
  and .[0].matcher == "Edit|Write|NotebookEdit|Bash" and .[0].hooks[0].onFailure == "block" and (.[0].hooks[0].command | contains("/.claude/hooks/protected-file-guard.sh"))
  and .[1].matcher == "Bash" and (.[1].hooks[0].command | contains("/.claude/hooks/commit-check.sh"))' .claude/settings.json
check "settings: the commit check's timeout is COMMIT_CHECK_TIMEOUT_SECS + 10" jq -e '.hooks.PreToolUse[1].hooks[0].timeout == 40' .claude/settings.json
check "settings: Stop has the reprint with no matcher" jq -e '.hooks.Stop | length == 1 and (.[0] | has("matcher") | not) and (.[0].hooks[0].command | contains("/.claude/hooks/pending-question-reprint.sh"))' .claude/settings.json
for f in protected-file-guard.sh commit-check.sh pending-question-reprint.sh hook-lib.sh hooks-check.sh; do
  check "installed: $f, identical to the download" cmp -s "$SRC/$f" ".claude/hooks/$f"
done
check "hooks.env was kept, not replaced by the example" grep -qx 'COMMIT_CHECK_CMD=true' .claude/hooks/hooks.env
run bash .claude/hooks/hooks-check.sh
expect 0 'PASS verified hooks=3' "hooks-check after install → verified"
expect_out 'the registered guard handler, run as the harness runs it, asks before an edit' "hooks-check runs the wired guard handler itself, offline"
cp .claude/settings.json "$T_TMP/after-first.json"
plan --hooks "$ALL" --settings .claude/settings.json
expect_out 'already wired  protected-file-guard' "re-plan: already wired"
expect_out '\(no change\)' "re-plan: no settings change"
apply --hooks "$ALL" --settings .claude/settings.json
check "re-apply is a no-op" cmp -s .claude/settings.json "$T_TMP/after-first.json"

# --- an existing file with unrelated keys and a foreign handler on the same event and matcher ---------------------------------
fixture foreign
cat > .claude/settings.json <<'EOF'
{"permissions": {"allow": ["Bash(ls:*)"], "deny": ["Read(./.env)"]}, "model": "x",
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-own-check.sh"}]}],
           "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "fmt.sh"}]}]}}
EOF
cp .claude/settings.json "$T_TMP/foreign-before.json"
plan --hooks "$ALL" --settings .claude/settings.json
expect_out 'everything outside "hooks" unchanged, except env\.CLAUDE_CODE_SUBAGENT_MODEL added when absent: yes; every other handler still present, in order: yes' "plan states both invariants as checked"
check "plan left the file byte-equal" cmp -s .claude/settings.json "$T_TMP/foreign-before.json"
apply --hooks "$ALL" --settings .claude/settings.json
expect 0 'PASS applied' "apply over foreign hooks → applied"
check "everything outside hooks is unchanged but the added subagent-model key" sh -c '[ "$(jq -S -c "del(.hooks)" "$1")" = "$(jq -S -c "del(.hooks) | del(.env)" "$2")" ]' _ "$T_TMP/foreign-before.json" .claude/settings.json
check "…and that key is the only thing in env" jq -e '.env == {"CLAUDE_CODE_SUBAGENT_MODEL":"sonnet"}' .claude/settings.json
check "the foreign handler on the same event and matcher survives, first" jq -e '.hooks.PreToolUse[0] == {"matcher":"Bash","hooks":[{"type":"command","command":"my-own-check.sh"}]}' .claude/settings.json
check "another event's handler survives" jq -e '.hooks.PostToolUse == [{"matcher":"Edit","hooks":[{"type":"command","command":"fmt.sh"}]}]' .claude/settings.json
check "the previous file is saved under the git directory" sh -c 'ls "$(git rev-parse --git-path hooks-install)"/settings.*.json >/dev/null 2>&1'
check "nothing new in the tree but .claude" sh -c '[ -z "$(git status --porcelain | grep -v "^?? \.claude/" | grep -v "^?? \.gitignore")" ]'

# --- the default subagent model: added only when absent, in the hashed plan, opt-out by flag -------------------------------------
fixture submodel
echo '{"model":"x"}' > .claude/settings.json
plan --hooks "$ALL" --settings .claude/settings.json; HS="$HASH"
expect_out '^Subagent model: sets env\.CLAUDE_CODE_SUBAGENT_MODEL = "sonnet" in \.claude/settings\.json \(the mid tier\)' "absent → the plan says it sets the subagent model"
expect_out '^\+.*"CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"' "…and the key is in the settings diff"
plan --hooks "$ALL" --settings .claude/settings.json --no-subagent-model; HN="$HASH"
expect_out '^Subagent model: not set \(--no-subagent-model\)\.' "--no-subagent-model → the plan says it is not set"
refute_out 'CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"' "--no-subagent-model → not in the diff"
if [ -n "$HS" ] && [ -n "$HN" ] && [ "$HS" != "$HN" ]; then t_pass "the hash covers the subagent-model key"; else t_fail "the hash covers the subagent-model key" "with=$HS without=$HN"; fi
HASH="$HN"; apply --hooks "$ALL" --settings .claude/settings.json
expect 4 'FAIL plan-changed' "apply with the opt-out plan's hash but without the flag → refused (exit 4)"
check "…and wrote nothing" jq -e '. == {"model":"x"}' .claude/settings.json
HASH="$HN"; apply --hooks "$ALL" --settings .claude/settings.json --no-subagent-model
expect 0 'PASS applied' "apply --no-subagent-model → applied"
check "…without the subagent-model key" jq -e '(.env // {}) | has("CLAUDE_CODE_SUBAGENT_MODEL") | not' .claude/settings.json
fixture submodel-kept
echo '{"env":{"CLAUDE_CODE_SUBAGENT_MODEL":"opus","OTHER":"1"}}' > .claude/settings.json
plan --hooks "$ALL" --settings .claude/settings.json
expect_out '^Subagent model: kept env\.CLAUDE_CODE_SUBAGENT_MODEL = "opus" \(already set in \.claude/settings\.json; never overwritten\)\.' "present (any value) → kept, and the plan says so"
apply --hooks "$ALL" --settings .claude/settings.json
expect 0 'PASS applied' "apply with the key present → applied"
check "…the user's value and the rest of env are kept" jq -e '.env == {"CLAUDE_CODE_SUBAGENT_MODEL":"opus","OTHER":"1"}' .claude/settings.json
fixture submodel-new
plan --hooks "$ALL" --settings .claude/settings.local.json
apply --hooks "$ALL" --settings .claude/settings.local.json
expect 0 'PASS applied' "no settings file → applied"
check "…and the new file has the subagent model" jq -e '.env.CLAUDE_CODE_SUBAGENT_MODEL == "sonnet"' .claude/settings.local.json

# --- refusals ---------------------------------------------------------------------------------------------------------------------
fixture invalid
printf '{"hooks": [oops' > .claude/settings.json; cp .claude/settings.json "$T_TMP/invalid-before"
plan --hooks "$ALL" --settings .claude/settings.json
expect 2 'FAIL settings-unparseable' "invalid JSON → exit 2"
check "invalid JSON → file untouched" cmp -s .claude/settings.json "$T_TMP/invalid-before"
fixture noplan
HASH=0-0; apply --hooks "$ALL" --settings .claude/settings.json
expect 4 'FAIL plan-changed' "apply without the plan's hash → refused"
check "refused apply wrote nothing" test ! -e .claude/settings.json
plan --hooks "$ALL" --settings .claude/settings.json
echo extra >> .claude/protected-files.txt
apply --hooks "$ALL" --settings .claude/settings.json
expect 4 'FAIL plan-changed' "apply after the state changed under the plan → refused"
fixture nolist
rm .claude/protected-files.txt
plan --hooks "$ALL" --settings .claude/settings.json
expect 1 'FAIL blocker list-missing' "guard ticked with no protected list → blocker"
plan --hooks commit-check --settings .claude/settings.json
expect 0 'PLAN hash=' "without the guard, no list is needed"
run env PATH="$NEWP" bash "$I" plan --hooks "$ALL" --settings settings.json
expect 2 'FAIL usage' "a settings path other than the two → usage"
run env PATH="$NEWP" bash "$I" plan --hooks bogus --settings .claude/settings.json
expect 2 'FAIL usage' "an unknown hook → usage"
run env PATH="$NEWP" bash "$I" plan --hooks pending-question-reprint --settings .claude/settings.json --git-pre-commit
expect 2 'FAIL usage' "--git-pre-commit without the commit check → usage"
run env PATH="$(t_path_without jq)" bash "$I" plan --hooks "$ALL" --settings .claude/settings.json
expect 2 'FAIL no-jq' "no jq → exit 2 with the hand-wiring fallback"

# --- a differing installed script is kept without --update, replaced with it --------------------------------------------------------
fixture differs
plan --hooks "$ALL" --settings .claude/settings.local.json; apply --hooks "$ALL" --settings .claude/settings.local.json
expect 0 'PASS applied' "install into settings.local.json"
check "settings.local.json was written, settings.json was not" sh -c 'test -f .claude/settings.local.json && test ! -e .claude/settings.json'
echo '# local edit' >> .claude/hooks/commit-check.sh
plan --hooks "$ALL" --settings .claude/settings.local.json
expect_out 'KEPT +\.claude/hooks/commit-check\.sh differs' "a differing script is reported and kept"
apply --hooks "$ALL" --settings .claude/settings.local.json
check "…and not overwritten by apply" grep -q '# local edit' .claude/hooks/commit-check.sh
plan --hooks "$ALL" --settings .claude/settings.local.json --update; apply --hooks "$ALL" --settings .claude/settings.local.json --update
check "--update replaces it" cmp -s "$SRC/commit-check.sh" .claude/hooks/commit-check.sh

# --- an old harness gets no onFailure; --update re-registers the pack's own entry only ---------------------------------------------
fixture oldharness
run env PATH="$OLDP" bash "$I" plan --hooks "$ALL" --settings .claude/settings.json
HASH="$(printf '%s\n' "$LAST" | sed -n 's/.*PLAN hash=//p')"
expect_out 'onFailure: left out \(Claude Code 2\.1\.294' "an old harness: the plan says onFailure is left out and why"
run env PATH="$OLDP" bash "$I" apply --hooks "$ALL" --settings .claude/settings.json --approved "$HASH"
check "an old harness: no onFailure written" jq -e '[.. | objects | select(has("onFailure"))] == []' .claude/settings.json
jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"keep-me.sh"}]}]' .claude/settings.json > "$T_TMP/s" && mv "$T_TMP/s" .claude/settings.json
plan --hooks "$ALL" --settings .claude/settings.json
expect_out 'in another form than the download' "a newer harness: the old registration is reported"
plan --hooks "$ALL" --settings .claude/settings.json --update
expect_out 'a wrapper of your own included' "--update re-registering: the plan says it removes any handler naming the pack's script"
apply --hooks "$ALL" --settings .claude/settings.json --update
check "--update: the pack's entries now carry onFailure" jq -e '[.hooks.PreToolUse[].hooks[] | select(.command | test("guard|commit-check")) | .onFailure] == ["block","block"]' .claude/settings.json
check "--update: each pack hook is registered once" jq -e '[.. | objects | select(has("command")) | .command | select(test("\\.claude/hooks/"))] | length == 3' .claude/settings.json
check "--update: the foreign handler survives" jq -e '[.hooks.PreToolUse[].hooks[].command] | index("keep-me.sh") != null' .claude/settings.json

# --- the git-native pre-commit --------------------------------------------------------------------------------------------------------
fixture gitpc
plan --hooks "$ALL" --settings .claude/settings.json --git-pre-commit; apply --hooks "$ALL" --settings .claude/settings.json --git-pre-commit
check "pre-commit installed and executable" test -x .git/hooks/pre-commit
check "pre-commit runs the commit check in git-hook mode" sh -c 'grep -q "/.claude/hooks/commit-check.sh" "$1" && grep -q "exec bash \"\$f\" --git-hook" "$1"' _ .git/hooks/pre-commit
fixture gitpc-exists
printf '#!/bin/sh\necho mine\n' > .git/hooks/pre-commit
plan --hooks "$ALL" --settings .claude/settings.json --git-pre-commit
expect_out 'not installed .*already exists' "an existing pre-commit is never overwritten; the line is printed"
apply --hooks "$ALL" --settings .claude/settings.json --git-pre-commit
check "…and stays as it was" grep -q 'echo mine' .git/hooks/pre-commit
fixture gitpc-manager
git config core.hooksPath .husky
plan --hooks "$ALL" --settings .claude/settings.json --git-pre-commit
expect_out 'core.hooksPath is \.husky' "core.hooksPath set → not installed, the line is printed"

# --- review findings: a session started in a subfolder, a worktree's local settings, the hash, the timeout ----------------------
fixture subfolder
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
GCMD="$(jq -r '.hooks.PreToolUse[] | .hooks[] | .command | select(contains("protected-file-guard"))' .claude/settings.json | tr -d '\r')"   # a Windows jq.exe ends lines with CRLF
mkdir -p "$HR/src/deep"
T_STDIN="$(t_tool_json Edit file_path "$HR/.gitignore")"; run env CLAUDE_PROJECT_DIR="$HR/src/deep" sh -c "$GCMD"
expect_decision ask "the handler finds the guard when the session started in a subfolder"
mkdir -p "$T_TMP/elsewhere"
T_STDIN="$(t_tool_json Edit file_path "$HR/.gitignore")"; run env CLAUDE_PROJECT_DIR="$T_TMP/elsewhere" sh -c "$GCMD"
expect_rc 0 "a folder without the pack: the handler exits 0 instead of blocking every call"
expect_out 'not installed in this folder' "…and says the hook is off there"
rm "$HR/.claude/hooks/protected-file-guard.sh"
T_STDIN="$(t_tool_json Edit file_path "$HR/.gitignore")"; run env CLAUDE_PROJECT_DIR="$HR" sh -c "$GCMD"
expect_decision ask "guard script removed while hooks.env and the list remain → ask, never a silent allow"
expect_out 'guard script is missing' "…and the answer says the guard is missing"
T_STDIN="$(t_tool_json Edit file_path "$HR/src/a.ts" bypassPermissions)"; run env CLAUDE_PROJECT_DIR="$HR" sh -c "$GCMD"
expect_decision deny "…deny in bypassPermissions"
rm "$HR/.claude/hooks/hooks.env"
T_STDIN="$(t_tool_json Edit file_path "$HR/src/a.ts")"; run env CLAUDE_PROJECT_DIR="$HR" sh -c "$GCMD"
expect_decision ask "only the list left → still ask"
fixture wt-local
git add -A >/dev/null && git commit -qm base && git worktree add -q -b wt "$T_TMP/wt-local-tree" || exit 2
MAINROOT="$HR"
cd "$T_TMP/wt-local-tree" || exit 2
plan --hooks "$ALL" --settings .claude/settings.local.json
expect_out "settings.local.json is read from the main checkout" "plan says where Claude Code reads the local file in a worktree"
apply --hooks "$ALL" --settings .claude/settings.local.json
check "local settings written at the main checkout's root" test -f "$MAINROOT/.claude/settings.local.json"
check "…not in the worktree" test ! -e "$T_TMP/wt-local-tree/.claude/settings.local.json"
cd "$MAINROOT" || exit 2
fixture hash
cp -R "$SRC" "$T_TMP/dl-copy"
run env PATH="$NEWP" bash "$T_TMP/dl-copy/bin/hooks-install.sh" plan --hooks "$ALL" --settings .claude/settings.json
HASH="$(printf '%s\n' "$LAST" | sed -n 's/.*PLAN hash=//p')"
echo '# changed after the plan' >> "$T_TMP/dl-copy/protected-file-guard.sh"
run env PATH="$NEWP" bash "$T_TMP/dl-copy/bin/hooks-install.sh" apply --hooks "$ALL" --settings .claude/settings.json --approved "$HASH"
expect 4 'FAIL plan-changed' "a script changed in the download after the plan → apply refused (the hash covers script content)"
fixture timeout
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
sed 's/^COMMIT_CHECK_TIMEOUT_SECS=.*/COMMIT_CHECK_TIMEOUT_SECS=300/' .claude/hooks/hooks.env > "$T_TMP/e" && cat "$T_TMP/e" > .claude/hooks/hooks.env
run bash .claude/hooks/hooks-check.sh
expect 1 'FAIL timeout-mismatch' "a raised COMMIT_CHECK_TIMEOUT_SECS the handler does not allow for → FAIL"
expect_out 'plan --update' "…and says how to re-register"

# --- review findings, round 2 -------------------------------------------------------------------------------------------------------
envset() { sed "s|^$1=.*|$1=$2|" .claude/hooks/hooks.env > "$T_TMP/e" && cat "$T_TMP/e" > .claude/hooks/hooks.env; }
fixture timeout-zero-lead
envset COMMIT_CHECK_TIMEOUT_SECS 08
plan --hooks "$ALL" --settings .claude/settings.json
expect 0 'PLAN hash=' "a timeout with a leading zero (08): the plan is printed, not an arithmetic error"
refute_out 'value too great for base' "…with no arithmetic error on the way"
apply --hooks "$ALL" --settings .claude/settings.json
check "…and the handler timeout is 08 + 10 = 18 (base 10)" jq -e '[.hooks.PreToolUse[].hooks[] | select(.command | contains("commit-check")) | .timeout] == [18]' .claude/settings.json
run bash .claude/hooks/hooks-check.sh
expect 0 'PASS verified' "…and hooks-check reads 08 in base 10 and passes"
refute_out 'value too great for base' "…with no arithmetic error"
envset COMMIT_CHECK_TIMEOUT_SECS 0
run bash .claude/hooks/hooks-check.sh
expect 1 'FAIL timeout-invalid' "hooks-check: a timeout of 0 → FAIL"
plan --hooks "$ALL" --settings .claude/settings.json
expect 1 'FAIL blocker timeout-invalid' "plan: a timeout of 0 with the commit check ticked → blocker"
plan --hooks protected-file-guard,pending-question-reprint --settings .claude/settings.json
expect 0 'PLAN hash=' "…but not when the commit check is not ticked"
fixture "time out spaced"
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
envset COMMIT_CHECK_TIMEOUT_SECS 300
run bash .claude/hooks/hooks-check.sh
expect 1 'FAIL timeout-mismatch' "a repository path with a space: the timeout mismatch is still found"
fixture badlist
printf '%s\n' '.gitignore' 'config/' './x' > .claude/protected-files.txt
plan --hooks "$ALL" --settings .claude/settings.json
expect 1 'FAIL blocker list-broken' "a protected list the guard would refuse → blocker"
expect_out "'config/'" "…naming the trailing-slash glob"
expect_out "'\./x'" "…and the ./ glob"
check "…and nothing was written" test ! -e .claude/settings.json
rm .claude/hooks/hooks.env
plan --hooks "$ALL" --settings .claude/settings.json
expect 1 'FAIL blocker list-broken' "…also on a first install, before hooks.env exists"
plan --hooks commit-check --settings .claude/settings.json
expect 0 'PLAN hash=' "…and not when the guard is not ticked"
fixture xnote
plan --hooks "$ALL" --settings .claude/settings.local.json
XF="$(cd "$(git rev-parse --git-path info)" && pwd -P)/exclude"
expect_out 'settings\.local\.json is not ignored by git' "settings.local.json not ignored: the plan says so"
expect_out "add this line to $XF .*: /\.claude/settings\.local\.json\$" "…and names the line and the exclude file"
cp "$XF" "$T_TMP/xnote-exclude" 2>/dev/null || : > "$T_TMP/xnote-exclude"
echo '/.claude/settings.local.json' >> "$XF"
apply --hooks "$ALL" --settings .claude/settings.local.json
expect 0 'PASS applied' "…adding the line between plan and apply does not change the approved plan"
plan --hooks "$ALL" --settings .claude/settings.local.json
refute_out 'not ignored by git' "…and once ignored, the note is gone"
# The shared settings file must reach the team: an ignored one is a WARNING with the rule and the un-ignore lines.
fixture ign-shared
printf '*.json\n' >> .gitignore
plan --hooks "$ALL" --settings .claude/settings.json
expect_out 'WARNING: \.claude/settings\.json is ignored by git \(\.gitignore:[0-9]+:\*\.json\)' "an ignored shared settings file: the plan warns and names the rule"
expect_out "add '!/\.claude/settings\.json' and '!/\.claude/hooks/' below that line" "…and names the un-ignore lines"
H1="$HASH"
fixture ign-folder
printf '.claude/\n' >> .gitignore
plan --hooks "$ALL" --settings .claude/settings.json
expect_out "ignores the folder's contents, not the folder \(for example '\.claude/' becomes '\.claude/\*'\)" "a whole ignored .claude folder: the plan gives the dir/* form"
printf '.claude/*\n!/.claude/settings.json\n!/.claude/hooks/\n' > .gitignore
plan --hooks "$ALL" --settings .claude/settings.json
refute_out 'is ignored by git' "…and with the un-ignore lines in place, no warning"
check "the warning sits outside the hashed plan" test -n "$H1"
fixture ign-none
plan --hooks "$ALL" --settings .claude/settings.json
refute_out 'is ignored by git' "a shared settings file git does not ignore: no warning"
fixture xnote-nowrite
plan --hooks "$ALL" --settings .claude/settings.local.json; apply --hooks "$ALL" --settings .claude/settings.local.json
check "the installer itself never writes the exclude file" sh -c '! grep -q settings.local "$(git rev-parse --git-path info/exclude)" 2>/dev/null'
if ! t_can_symlink || ! t_can_unreadable; then
  t_skip "a symlinked settings file and a mode-600 one: ln -s copies and chmod 600 does not hold here (Windows, or root)"
else
fixture symlink
mkdir -p "$T_TMP/dotfiles"; echo '{"model":"x"}' > "$T_TMP/dotfiles/settings.json"; chmod 600 "$T_TMP/dotfiles/settings.json"
ln -s "$T_TMP/dotfiles/settings.json" .claude/settings.json
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
expect 0 'PASS applied' "a symlinked settings file: applied"
check "…it is still a symlink" test -L .claude/settings.json
check "…the target got the handlers" jq -e '.model == "x" and (.hooks.PreToolUse | length) == 2' "$T_TMP/dotfiles/settings.json"
check "…and kept its mode" sh -c '[ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")" = 600 ]' _ "$T_TMP/dotfiles/settings.json"
fixture mode
echo '{"model":"x"}' > .claude/settings.json; chmod 600 .claude/settings.json
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
check "a settings file with mode 600 keeps its mode" sh -c '[ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")" = 600 ]' _ .claude/settings.json
fi
fixture dupkey
printf '{"model": "a", "model": "b"}\n' > .claude/settings.json
plan --hooks "$ALL" --settings .claude/settings.json
expect_out 'a key that appears twice keeps only its last value' "a rewritten file: the plan says what jq's reading can lose"
fixture cmdhash
plan --hooks "$ALL" --settings .claude/settings.json
expect_out "this runs from the repository's top level: true\$" "commit check ticked: the plan prints the COMMIT_CHECK_CMD it will run"
envset COMMIT_CHECK_CMD false
apply --hooks "$ALL" --settings .claude/settings.json
expect 4 'FAIL plan-changed' "COMMIT_CHECK_CMD changed after the plan → apply refused (the hash covers it)"
fixture firstinstall-wording
run env PATH="$OLDP" bash "$I" plan --hooks protected-file-guard,pending-question-reprint --settings .claude/settings.json
expect_out 'crash or timeout of the protected-file guard lets the call through' "an old harness, guard + reprint: the plan names the one guard onFailure is for"
refute_out 'two guards|commit check' "…and mentions no second guard"

# --- review findings, round 3: settings shape, timeout overflow, stale matcher, mixed versions, pre-commit without the pack --------
fixture hooks-shape
printf '{"hooks":"x"}' > .claude/settings.json
plan --hooks "$ALL" --settings .claude/settings.json
expect 2 'FAIL settings-unparseable' "a hooks value that is not an object → exit 2, never 'already wired'"
printf '{"hooks":{"PreToolUse":"x"}}' > .claude/settings.json
plan --hooks "$ALL" --settings .claude/settings.json
expect 2 'FAIL settings-unparseable' "an event value that is not an array → exit 2 with a result line"
fixture timeout-huge
envset COMMIT_CHECK_TIMEOUT_SECS 99999999999999999999
plan --hooks "$ALL" --settings .claude/settings.json
expect 1 'FAIL blocker timeout-invalid' "a 20-digit timeout → blocker, never a wrapped number"
fixture stale-matcher
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
jq '(.hooks.PreToolUse[] | select(.hooks[0].command | contains("protected-file-guard"))).matcher = "Bash"' .claude/settings.json > "$T_TMP/s" && mv "$T_TMP/s" .claude/settings.json
run bash .claude/hooks/hooks-check.sh
expect 1 'FAIL wrong-matcher' "hooks-check: a guard whose matcher misses Edit, Write, NotebookEdit → FAIL"
plan --hooks "$ALL" --settings .claude/settings.json
expect_out 'in another form than the download' "a stale matcher is another form, not 'already wired'"
plan --hooks "$ALL" --settings .claude/settings.json --update; apply --hooks "$ALL" --settings .claude/settings.json --update
check "--update re-registers the guard with the download's matcher" jq -e '[.hooks.PreToolUse[] | select(.hooks[0].command | contains("protected-file-guard")) | .matcher] == ["Edit|Write|NotebookEdit|Bash"]' .claude/settings.json
run bash .claude/hooks/hooks-check.sh
expect 0 'PASS verified' "…and hooks-check passes again"
fixture mixed
plan --hooks protected-file-guard --settings .claude/settings.json; apply --hooks protected-file-guard --settings .claude/settings.json
echo '# local edit' >> .claude/hooks/hook-lib.sh
plan --hooks protected-file-guard,commit-check --settings .claude/settings.json
expect 1 'FAIL blocker mixed-pack-version' "a new script beside a kept, different hook-lib.sh → blocker"
plan --hooks protected-file-guard,commit-check --settings .claude/settings.json --update
expect 0 'PLAN hash=' "…and --update clears it"
fixture gitpc-no-pack
git commit -q --allow-empty -m base || exit 2
plan --hooks "$ALL" --settings .claude/settings.json --git-pre-commit; apply --hooks "$ALL" --settings .claude/settings.json --git-pre-commit
git worktree add -q -b before-pack "$T_TMP/no-pack-tree" HEAD || exit 2
run git -C "$T_TMP/no-pack-tree" commit -q --allow-empty -m x
expect_rc 0 "pre-commit in a worktree without the pack: the commit goes through"
expect_out 'off here' "…and the hook says the check is off there"

# --- hooks-check failures ------------------------------------------------------------------------------------------------------------
fixture check-unwired
cp "$SRC"/*.sh .claude/hooks/
run bash .claude/hooks/hooks-check.sh
expect 1 'FAIL not-wired' "installed but not wired → FAIL"
fixture check-disabled
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
jq '.disableAllHooks = true' .claude/settings.json > "$T_TMP/s" && mv "$T_TMP/s" .claude/settings.json
run bash .claude/hooks/hooks-check.sh
expect 1 'FAIL hooks-disabled' "disableAllHooks → FAIL"
fixture check-missing-script
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
rm .claude/hooks/commit-check.sh
run bash .claude/hooks/hooks-check.sh
expect 1 'FAIL wired-but-missing' "a handler pointing at a missing script → FAIL"
fixture check-nolist
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
rm .claude/protected-files.txt
run bash .claude/hooks/hooks-check.sh
expect 1 'FAIL list-broken' "a missing protected list → FAIL"
fixture check-wired-path
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
# A wiring string that looks for the pack in the wrong folder: the script probes pass, the handler does not.
jq '(.hooks.PreToolUse[] | .hooks[] | select(.command | contains("protected-file-guard.sh")) | .command) |= gsub("\\$CLAUDE_PROJECT_DIR"; "$CLAUDE_PROJECT_DIR/elsewhere")' .claude/settings.json > "$T_TMP/s" && mv "$T_TMP/s" .claude/settings.json
run bash .claude/hooks/hooks-check.sh
expect 1 'FAIL probe-wired' "a guard handler whose wiring cannot find the script → FAIL, offline"
fixture check-version
plan --hooks "$ALL" --settings .claude/settings.json; apply --hooks "$ALL" --settings .claude/settings.json
sed 's/^# hooks-pack: [0-9]*$/# hooks-pack: 999/' .claude/hooks/commit-check.sh > "$T_TMP/c" && cat "$T_TMP/c" > .claude/hooks/commit-check.sh
run bash .claude/hooks/hooks-check.sh
expect 1 'FAIL version-mismatch' "a script from another pack version → FAIL"
t_done
