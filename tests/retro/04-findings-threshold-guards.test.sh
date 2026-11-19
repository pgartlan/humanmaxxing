#!/usr/bin/env bash
# retro-data.sh: review-findings files written in the window, the repeat-bug threshold read from the rules file's own
# sentence (never defaulted), and the optional guard-growth count.
. "$(dirname "$0")/../lib.sh"

# --- review findings ------------------------------------------------------------------------------------------------
t_retro_fixture fnd "FINDINGS_DIR=docs/findings"
t_retro_commit 20 "docs: an old review" docs/findings/old.md docs/findings/updated.md
t_retro_commit 2 "docs: a new review" docs/findings/new.md
t_retro_commit 1 "docs: append to a review" docs/findings/updated.md
t_retro_commit 1 "docs: not a finding" docs/other.md
t_retro_commit 3 "docs: a review later deleted" docs/findings/gone.md
git rm -q docs/findings/gone.md && t_retro_commit 2 "chore: drop it"
t_retro_push
run bash "$R"
expect 0 'PASS complete' "findings read: complete"
expect_out '^FINDINGS files=2$' "two findings files were written or updated in the window"
expect_out '^FINDINGS-FILE docs/findings/new\.md$' "a new file"
expect_out '^FINDINGS-FILE docs/findings/updated\.md$' "a file appended to in the window"
refute_out 'FINDINGS-FILE docs/findings/old\.md' "a file untouched in the window is left out"
refute_out 'FINDINGS-FILE docs/findings/gone\.md' "a file that no longer exists is left out"
refute_out 'FINDINGS-FILE docs/other\.md' "a file outside the folder is left out"
t_retro_cfg "FINDINGS_DIR=docs/nope"; run bash "$R"
expect 3 'PARTIAL unavailable=findings$' "a configured folder that does not exist: partial"
expect_out '^UNAVAILABLE findings reason=folder-missing docs/nope at refs/remotes/origin/main$' "folder-missing, named"
refute_out '^FINDINGS files' "no count"
t_retro_cfg; run bash "$R"
expect_out '^NOT-CONFIGURED findings reason=no-findings-folder$' "no folder configured: not configured"

# Findings are read from the base branch's history, not the working tree: a run from a feature branch, or from a tree
# that is behind origin/main after a fetch, still sees every file merged in the window.
t_retro_cfg "FINDINGS_DIR=docs/findings/"
git clone -q "$ORIGIN" "$FIX/other" 2>/dev/null || exit 2
( cd "$FIX/other" && mkdir -p docs/findings && echo x > docs/findings/merged-elsewhere.md && git add -A \
  && git commit -qm "docs: a review merged from another clone" && git push -q origin main ) || exit 2
git fetch -q origin || exit 2
git checkout -q -b feature "$(git rev-list --max-parents=0 HEAD)" || exit 2
check "the checkout has no findings folder at all" test ! -e docs/findings
run bash "$R"
expect 0 'PASS complete' "a tree behind origin/main: complete"
expect_out '^FINDINGS files=3$' "the file merged from another clone is counted (a trailing / in the folder is fine)"
expect_out '^FINDINGS-FILE docs/findings/merged-elsewhere\.md$' "and listed"
git checkout -q main && git merge -q --ff-only origin/main || exit 2
# --- the repeat-bug threshold ---------------------------------------------------------------------------------------
LINE="$(grep -F 'this fix included, reaches `<YOUR-CLASS-GUARD-THRESHOLD>`' "$T_ROOT/templates/CLAUDE.template.md")"
check "the template states the threshold in the sentence the script reads" test -n "$LINE"
run bash "$R"; expect_out '^THRESHOLD value=3 CLAUDE\.md$' "the fixture's rules file says 3"
# rules <file> <content> — commit a rules file and push it, so the base branch carries it
rules() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1" && git add -A && git commit -qm "rules" && t_retro_push; }
rules CLAUDE.md "$(printf '# Rules\n%s' "$(printf '%s\n' "$LINE" | sed 's/<YOUR-CLASS-GUARD-THRESHOLD>/7/')")"
run bash "$R"; expect_out '^THRESHOLD value=7 CLAUDE\.md$' "a filled 7 is read as 7"
printf '%s\n' "$LINE" | sed 's/<YOUR-CLASS-GUARD-THRESHOLD>/5/' > CLAUDE.md
run bash "$R"; expect_out '^THRESHOLD value=7 CLAUDE\.md$' "an uncommitted edit in the working tree is not read: the base branch's rules are"
git checkout -q -- CLAUDE.md
rules CLAUDE.md "$LINE"
run bash "$R"
expect 3 'PARTIAL unavailable=threshold$' "an unfilled slot is no threshold"
expect_out '^UNAVAILABLE threshold reason=rule-not-found ' "rule-not-found"
refute_out '^THRESHOLD ' "and never a default"
rules CLAUDE.md "# Rules without the class rule"
run bash "$R"; expect_out '^UNAVAILABLE threshold reason=rule-not-found ' "a rules file without the sentence: rule-not-found"
refute_out '^THRESHOLD ' "no threshold printed"
rules CLAUDE.md "$(printf '%s\n' "$LINE" | sed 's/<YOUR-CLASS-GUARD-THRESHOLD>/3/'; printf '%s\n' "$LINE" | sed 's/<YOUR-CLASS-GUARD-THRESHOLD>/5/')"
run bash "$R"; expect_out '^UNAVAILABLE threshold reason=ambiguous ' "two different numbers: ambiguous"
git rm -q CLAUDE.md && git commit -qm "drop rules" && t_retro_push; run bash "$R"
expect_out '^UNAVAILABLE threshold reason=claude-md-missing CLAUDE\.md at refs/remotes/origin/main$' "no rules file: claude-md-missing"
rules rules/AGENTS.md "$(printf '%s\n' "$LINE" | sed 's/<YOUR-CLASS-GUARD-THRESHOLD>/5/')"
t_retro_cfg "CLAUDE_MD=rules/AGENTS.md"; run bash "$R"
expect_out '^THRESHOLD value=5 rules/AGENTS\.md$' "CLAUDE_MD points at another rules file"

# --- guard growth -----------------------------------------------------------------------------------------------------
t_retro_fixture grd
run bash "$R"; expect_out '^NOT-CONFIGURED guards reason=no-guard-globs$' "guard count off by default"
t_retro_commit 20 "chore: an old guard" lint/rules/old.yml
t_retro_commit 2 "chore: a lint rule" lint/rules/deep/new.yml
t_retro_commit 1 "chore: a check script" scripts/check-links.sh
t_retro_commit 1 "chore: not a guard" scripts/build.sh
t_retro_commit 1 "chore: change an old guard" lint/rules/old.yml
t_retro_push
t_retro_cfg "GUARD_GLOBS=lint/rules/** scripts/check-*" "GUARD_BUDGET_PER_MONTH=4"
run bash "$R"
expect 0 'PASS complete' "guards counted: complete"
expect_out '^GUARDS added=2 budget-per-month=4 days=7$' "two guards added in the window, with the budget"
expect_out '^GUARD-FILE lint/rules/deep/new\.yml$' "** reaches a nested file"
expect_out '^GUARD-FILE scripts/check-links\.sh$' "a single-star pattern"
refute_out 'GUARD-FILE scripts/build\.sh' "a file outside the patterns is not a guard"
refute_out 'GUARD-FILE lint/rules/old\.yml' "a guard changed in the window, added before it, is not new"
t_retro_cfg "GUARD_GLOBS=lint/rules/**"; run bash "$R"
expect_out '^GUARDS added=1 budget-per-month=none days=7$' "no budget: none"
t_retro_cfg "GUARD_GLOBS=nothing/here/*"; run bash "$R"
expect_out '^GUARDS added=0 budget-per-month=none days=7$' "patterns that match nothing: a real zero"
t_retro_cfg "GUARD_GLOBS=lint/**" "GUARD_BUDGET_PER_MONTH=ten"; run bash "$R"
expect 2 'FAIL config-malformed' "a budget that is not a number is refused"

# --- session summaries (same rules as findings: the window, read from the base branch) -------------------------------
t_retro_commit 20 "docs: an old session" docs/sessions/old.md
t_retro_commit 2 "docs: a session" docs/sessions/s1.md
t_retro_push
t_retro_cfg "SESSION_NOTES_DIR=docs/sessions/"; run bash "$R"
expect_out '^SESSIONS files=1$' "one session summary written in the window"
expect_out '^SESSIONS-FILE docs/sessions/s1\.md$' "and listed"
refute_out 'SESSIONS-FILE docs/sessions/old\.md' "an older one is left out"
t_retro_cfg "SESSION_NOTES_DIR=docs/nope"; run bash "$R"
expect 3 'PARTIAL unavailable=sessions$' "a configured folder that does not exist: partial, never zero"
refute_out '^SESSIONS files' "no count"
t_retro_cfg; run bash "$R"
expect_out '^NOT-CONFIGURED sessions reason=no-session-folder$' "not set: not configured"
t_retro_cfg "SESSION_NOTES_DIR=../elsewhere"; run bash "$R"
expect 2 'FAIL config-malformed' "a folder outside the repository is refused"
t_done
