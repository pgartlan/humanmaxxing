#!/usr/bin/env bash
# review-code's reviewer budget: bin/lens-score.sh (how much review each lens and the whole change needs) and
# bin/reviewer-fold.sh (MAX_REVIEWERS as a hard total of agents, solo lenses, hybrids with full profiles), and the text
# that uses them.
# Mutations this file must catch (run once by hand): drop the critical multiplier · drop a bonus · count the zero-context
# reader outside the cap · ignore --max · drop a protected lens · rank by input order instead of score · fold by load
# before domain · a budget that does not grow · a hybrid prompt without the full profile files.
. "$(dirname "$0")/../lib.sh"
cd "$T_ROOT" || exit 2
F="${FOLD_UNDER_TEST:-$T_ROOT/skills/review-code/bin/reviewer-fold.sh}"
SC="${SCORE_UNDER_TEST:-$T_ROOT/skills/review-code/bin/lens-score.sh}"
fold() { T_STDIN="$(cat "$T_TMP/in")"; run bash "$F" "$@"; }
lens() { printf '%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" >> "$T_TMP/in"; [ -z "${6:-}" ] || printf '\t%s' "$6" >> "$T_TMP/in"; printf '\n' >> "$T_TMP/in"; }
has() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }

# --- lens-score.sh: weights, bonuses, the critical multiplier --------------------------------------------------------
R="$T_TMP/score-repo"; git init -q "$R" && cd "$R" || exit 2
git config user.email t@example.com; git config user.name t
mkdir -p src/auth docs tests .github/workflows
seq 10 > src/auth/a.js; seq 10 > src/b.js; seq 10 > docs/x.md; seq 10 > old.js; echo x > .github/workflows/ci.yml
seq 10 > app.json; printf '#!/bin/sh\n' > tool.sh
git add -A && git commit -qm base || exit 2
BASE="$(git rev-parse HEAD)"
printf '# why these are critical\nsrc/auth/**\n# off: src/b.js\n' > crit.txt
seq 20 > src/auth/a.js                         # +10 lines on a critical path: 10 x 3 = 30
seq 15 > src/b.js                              # +5 code lines (its critical line is commented out): 5
seq 30 > docs/x.md                             # +20 docs lines: 20 x 0.1 = 2
git rm -q old.js                               # -10 code lines + deleted bonus 10 = 20
echo y > .github/workflows/ci.yml              # 2 config lines + gate bonus 40 = 42
printf '#!/bin/sh\necho\n' > run.sh; chmod +x run.sh   # new executable, 2 lines: 2 + 25 = 27
seq 4 > tests/t.test.js                        # 4 test lines x 0.5 = 2
chmod +x tool.sh                               # a mode change: permission bonus 25, 0 lines
seq 10 > app.json; echo '"permissions": 1' >> app.json   # 1 config line + permission bonus 25 = 26
printf 'sec\tsrc/auth/a.js\napi\tsrc/b.js\napi\told.js\ndocs\tdocs/x.md\ninfra\t.github/workflows/ci.yml\ninfra\trun.sh\ntest\ttests/t.test.js\nperm\ttool.sh\nperm\tapp.json\nsec\tsrc/auth/a.js\n' > "$T_TMP/lf"
T_STDIN="$(cat "$T_TMP/lf")"; run bash "$SC" --base "$BASE" --critical crit.txt
expect 0 'SCORE-RESULT PASS' "lens-score runs on a working-tree diff"
check "a critical path weighs 3 per line (and a file listed twice counts once)" has 'SCORE sec 30 files=1 critical=1'
check "code weighs 1 per line, a deleted file adds its bonus, a commented-out critical line is not critical" has 'SCORE api 25 files=2 critical=0'
check "docs weigh 0.1 per line" has 'SCORE docs 2 files=1 critical=0'
check "a CI step change and a new executable file add their bonuses" has 'SCORE infra 69 files=2 critical=0'
check "tests weigh 0.5 per line" has 'SCORE test 2 files=1 critical=0'
if t_tracks_mode; then
  check "a mode change and a changed permissions line add the permission bonus" has 'SCORE perm 51 files=2 critical=0'
  check "the total covers every changed file, matched or not" sh -c 'printf "%s\n" "$1" | grep -qE "^TOTAL [0-9]+ files=10$"' _ "$OUT"
else
  # git records no mode here (core.fileMode=false, Windows): tool.sh is unchanged, so only app.json scores.
  t_skip "a mode change's permission bonus: git does not record the executable bit here (core.fileMode=false, Windows)"
  check "a changed permissions line adds the permission bonus" has 'SCORE perm 26 files=1 critical=0'
  check "the total covers every changed file, matched or not" sh -c 'printf "%s\n" "$1" | grep -qE "^TOTAL [0-9]+ files=9$"' _ "$OUT"
fi
T_STDIN="$(cat "$T_TMP/lf")"; run bash "$SC" --base "$BASE" --critical crit.txt --weights "critical=1 gate=0"
check "--weights overrides a weight and a bonus" sh -c 'printf "%s\n" "$1" | grep -qx "SCORE sec 10 files=1 critical=1" && printf "%s\n" "$1" | grep -qx "SCORE infra 29 files=2 critical=0"' _ "$OUT"
T_STDIN="$(cat "$T_TMP/lf")"; run bash "$SC" --base "$BASE" --weights "bogus=1"
expect 2 'SCORE-RESULT FAIL usage' "an unknown weight → exit 2"
T_STDIN="only-one-column"; run bash "$SC" --base "$BASE"
expect 2 'SCORE-RESULT FAIL malformed' "a malformed input line → exit 2"
T_STDIN=""; run bash "$SC" --base no-such-ref
expect 2 'SCORE-RESULT FAIL usage' "a base that is not a commit → exit 2, never a zero score"
# Hostile inputs and git-read failures, in a repository of their own.
R2="$T_TMP/score-repo2"; git init -q "$R2" && cd "$R2" || exit 2
git config user.email t@example.com; git config user.name t
mkdir -p "my dir"; seq 5 > "my dir/a b.js"; git add -A && git commit -qm base || exit 2
BASE2="$(git rev-parse HEAD)"
seq 9 > "my dir/a b.js"                          # +4 code lines in a path with spaces
seq 3 > "new file.js"                            # untracked: new, 3 lines added
printf '#!/bin/sh\n' > untracked.sh; chmod +x untracked.sh   # untracked executable: 1 line + 25
printf 'l\tmy dir/a b.js\nl\tnew file.js\nl\tuntracked.sh\n' > "$T_TMP/lf2"
T_STDIN="$(cat "$T_TMP/lf2")"; run bash "$SC" --base "$BASE2"
expect 0 'SCORE-RESULT PASS' "paths with spaces and untracked files are scored"
check "a path with spaces is matched, and untracked files count as new (4 + 3 + 1 + 25)" has 'SCORE l 33 files=3 critical=0'
check "the total counts the untracked files too" has 'TOTAL 33 files=3'
T_STDIN=""; run bash "$SC" --base "$BASE2"
expect 0 'SCORE-RESULT PASS' "an empty lens list is not an error: only the total is printed"
check "…and the total is still computed" has 'TOTAL 33 files=3'
# A non-ASCII path: git would quote it, and a matched lens must still score it (never a silent zero).
NA="$(printf 'caf\303\251.js')"; printf 'x\n' > "$R2/$NA"; git -C "$R2" add -A && git -C "$R2" commit -qm accent || exit 2
BASE3="$(git -C "$R2" rev-parse HEAD)"; seq 4 > "$R2/$NA"
T_STDIN="$(printf 'l\t%s\n' "$NA")"; run bash "$SC" --base "$BASE3"
check "a non-ASCII path is matched and scored (3 lines added, 1 changed: 4 + 1)" has 'SCORE l 5 files=1 critical=0'
T_STDIN=""; run bash "$SC" --base "$BASE2" --critical "$T_TMP/no-such-critical-file"
expect 3 'SCORE-RESULT FAIL critical-unreadable' "an unreadable critical-paths file → exit 3, never a pass with no critical paths"
T_STDIN=""; run bash "$SC" --base --weights
expect 2 'SCORE-RESULT FAIL usage' "a flag-looking value for --base is a base that is not a commit → exit 2"
T_STDIN=""; run bash "$SC" --base "$BASE2" --weights "code="
expect 2 'SCORE-RESULT FAIL usage' "an empty weight value → exit 2"
T_STDIN=""; run bash "$SC" --base "$BASE2" --weights "code=-1"
expect 2 'SCORE-RESULT FAIL usage' "a negative weight → exit 2"
T_STDIN=""; run bash "$SC" --base "$BASE2" --bogus x
expect 2 'SCORE-RESULT FAIL usage' "an unknown argument → exit 2"
T_STDIN=""; run bash "$SC" --base
expect 2 'SCORE-RESULT FAIL usage' "an option with no value → exit 2"
T_STDIN=""; run bash "$SC"
expect 2 'SCORE-RESULT FAIL usage' "no --base → exit 2"
T_STDIN="$(printf 'l\t\n')"; run bash "$SC" --base "$BASE2"
expect 2 'SCORE-RESULT FAIL malformed' "a lens line with an empty path → exit 2"
mkdir -p "$T_TMP/not-a-repo"; cd "$T_TMP/not-a-repo" || exit 2
T_STDIN=""; run bash "$SC" --base HEAD
expect 3 'SCORE-RESULT FAIL not-a-repository' "outside a git repository → exit 3, never a zero score"
cd "$T_ROOT" || exit 2

# --- reviewer-fold.sh: a hard total ----------------------------------------------------------------------------------
: > "$T_TMP/in"
lens api-reviewer      120 0 api   other
lens security-reviewer 150 1 api   security
lens test-engineer      30 1 tests test
lens perf-reviewer     200 0 data  other
lens obs-reviewer       10 0 ops   other
lens data-reviewer      45 1 data  other
lens frontend-reviewer  80 0 ui    other
fold --max 3 --total-score 900
expect 0 'FOLD-RESULT PASS agents=3 folded=5 skipped=0' "a cap of 3 with 7 matched lenses gives exactly 3 agents"
check "the zero-context reader counts toward the cap" has 'AGENTS total=3 reviewers=2 fixed=1 earned=7 max=3'
check "the protected lenses run (test, and security on a critical change), and count" sh -c 'printf "%s\n" "$1" | grep -qx "LENS security-reviewer score=150 solo" && printf "%s\n" "$1" | grep -qx "LENS test-engineer score=30 solo"' _ "$OUT"
check "a lens folds into the agent of its domain first" has 'LENS api-reviewer score=120 folded into security-reviewer (by domain)'
check "…else into the agent with the lowest load" has 'LENS perf-reviewer score=200 folded into test-engineer (by load)'
check "the decision table names a lens below the min score" has 'LENS obs-reviewer score=10 folded into test-engineer (by load), below min score'
check "the budget grows by half per extra profile (3 profiles: 60)" has 'RUN security-reviewer budget=60 profiles=security-reviewer,api-reviewer,data-reviewer'
check "4 profiles: 75" has 'RUN test-engineer budget=75 profiles=test-engineer,perf-reviewer,frontend-reviewer,obs-reviewer'
fold --max 3 --fixed 2 --total-score 900
check "an intent-fidelity agent counts too: cap 3 with 2 fixed → one reviewer" sh -c 'printf "%s\n" "$1" | grep -qx "AGENTS total=3 reviewers=1 fixed=2 earned=7 max=3" && [ "$(printf "%s\n" "$1" | grep -c "^RUN ")" -eq 1 ]' _ "$OUT"
check "…and the two protected lenses share that one agent, never dropped" sh -c 'printf "%s\n" "$1" | grep -q "^RUN security-reviewer .*profiles=security-reviewer,.*test-engineer"' _ "$OUT"

# The score earns reviewers: 1 below 60, 2 at 60, one more per 150.
: > "$T_TMP/in"; lens a 90 0 x other; lens b 80 0 y other; lens c 70 0 z other; lens d 60 0 w other
fold --max 7 --total-score 59
check "below the small-diff score: one reviewer carries every lens" sh -c 'printf "%s\n" "$1" | grep -qx "AGENTS total=2 reviewers=1 fixed=1 earned=1 max=7" && printf "%s\n" "$1" | grep -qx "SECOND-PASS only-on-critical"' _ "$OUT"
fold --max 7 --total-score 60
check "at the small-diff score: two reviewers" has 'AGENTS total=3 reviewers=2 fixed=1 earned=2 max=7'
fold --max 7 --total-score 210
check "one more per further step of 150" has 'AGENTS total=4 reviewers=3 fixed=1 earned=3 max=7'
check "lenses are ranked by score: the top ones run solo" sh -c 'printf "%s\n" "$1" | grep -qx "LENS a score=90 solo" && printf "%s\n" "$1" | grep -qx "LENS c score=70 solo" && printf "%s\n" "$1" | grep -q "^LENS d score=60 folded"' _ "$OUT"
fold --max 3 --total-score 2000
check "never above the cap, whatever the score earns" has 'AGENTS total=3 reviewers=2 fixed=1 earned=14 max=3'

# The min score and mechanical checks.
: > "$T_TMP/in"; lens a 39 0 x other; lens c 5 0 z other clean
fold --max 7 --total-score 400
check "no lens at the min score: the general reviewer takes the place" sh -c 'printf "%s\n" "$1" | grep -qx "LENS a score=39 folded into general (by load), below min score" && printf "%s\n" "$1" | grep -q "^RUN general "' _ "$OUT"
check "a clean check below the min score: no agent for that lens" has 'LENS c score=5 skipped (its check ran clean, below min score)'
: > "$T_TMP/in"; lens a 39 0 x other; lens b 5 0 y other found
fold --max 7 --total-score 400
check "a check that found something lets its lens run solo, below the min score" has 'LENS b score=5 solo'

# Hybrid prompts load each profile's full file.
AG="$T_TMP/agents"; mkdir -p "$AG"
for x in security-reviewer api-reviewer test-engineer; do
  printf -- '---\nname: %s\ntools: Read\n---\n# %s\nThe full definition of %s, line 2 of its body.\n' "$x" "$x" "$x" > "$AG/$x.md"
done
: > "$T_TMP/in"
lens security-reviewer 150 1 api security; lens api-reviewer 120 0 api other; lens test-engineer 30 1 tests test
fold --max 3 --total-score 900 --agents-dir "$AG" --out-dir "$T_TMP/hy"
check "a hybrid prompt file is written for the shared agent" test -f "$T_TMP/hy/security-reviewer.hybrid.md"
check "…framed as acting as both" grep -q '^You are acting as both security-reviewer and api-reviewer\. ' "$T_TMP/hy/security-reviewer.hybrid.md"
check "…holding both FULL profile files, verbatim" sh -c 'for x in security-reviewer api-reviewer; do grep -qxF "The full definition of $x, line 2 of its body." "$2" && grep -qxF "name: $x" "$2" || exit 1; done; [ "$(grep -c "^=== PROFILE" "$2")" -eq 2 ]' _ "$AG" "$T_TMP/hy/security-reviewer.hybrid.md"
check "…asking for each finding's profile label" grep -qF '"[<agent>] ## BLOCK' "$T_TMP/hy/security-reviewer.hybrid.md"
check "a solo agent gets no hybrid file" test ! -f "$T_TMP/hy/test-engineer.hybrid.md"
check "the result names the hybrid file" sh -c 'printf "%s\n" "$1" | grep -q "^HYBRID security-reviewer .*/security-reviewer.hybrid.md$"' _ "$OUT"
UA="$T_TMP/user-agents"; mkdir -p "$UA"; mv "$AG/api-reviewer.md" "$UA/"
fold --max 3 --total-score 900 --agents-dir "$AG" --agents-dir "$UA" --out-dir "$T_TMP/hy3"
check "an agent kept at user level is found in the second agents folder, project folder first" sh -c 'grep -qxF "The full definition of api-reviewer, line 2 of its body." "$1" && grep -qF "=== PROFILE api-reviewer ($2/api-reviewer.md)" "$1"' _ "$T_TMP/hy3/security-reviewer.hybrid.md" "$UA"
fold --max 3 --total-score 900 --agents-dir "$AG" --agents-dir "$T_TMP/no-such-folder" --out-dir "$T_TMP/hy4"
expect 2 'FOLD-RESULT FAIL profile-missing' "a missing user-level folder is not an error, but the missing profile still is"
rm "$UA/api-reviewer.md"
fold --max 3 --total-score 900 --agents-dir "$AG" --out-dir "$T_TMP/hy2"
expect 2 'FOLD-RESULT FAIL profile-missing' "a folded lens with no agent file → exit 2, never a hybrid without its profile"
check "…and no partial hybrid file is left behind" test ! -f "$T_TMP/hy2/security-reviewer.hybrid.md"

# No lens folded, with --agents-dir (the call review-code makes): the table still prints in full.
: > "$T_TMP/in"; lens security-reviewer 150 1 api security; lens test-engineer 30 1 tests test
fold --max 5 --total-score 900 --agents-dir "$AG" --out-dir "$T_TMP/hy0"
expect 0 'FOLD-RESULT PASS agents=3 folded=0 skipped=0' "no fold with --agents-dir: the decision table and FOLD-RESULT still print"
check "…every LENS and RUN line is there" sh -c '[ "$(printf "%s\n" "$1" | grep -c "^LENS ")" -eq 2 ] && [ "$(printf "%s\n" "$1" | grep -c "^RUN ")" -eq 2 ]' _ "$OUT"
# The general reviewer hosting folded lenses: its hybrid names it and loads every folded profile.
: > "$T_TMP/in"; lens security-reviewer 30 0 api other; lens test-engineer 20 0 sec other
fold --max 3 --total-score 90 --agents-dir "$AG" --out-dir "$T_TMP/hyg"
check "the general host lists itself among the profiles" has 'RUN general budget=60 profiles=general,security-reviewer,test-engineer'
check "…and gets a hybrid file with each folded profile" sh -c 'grep -q "^=== PROFILE general " "$1" && grep -qxF "The full definition of security-reviewer, line 2 of its body." "$1" && grep -qxF "The full definition of test-engineer, line 2 of its body." "$1"' _ "$T_TMP/hyg/general.hybrid.md"
# Refusals.
: > "$T_TMP/in"; lens a 9 2 x other
fold --max 3 --total-score 9
expect 2 'FOLD-RESULT FAIL malformed' "a critical flag that is not 0 or 1 → exit 2"
: > "$T_TMP/in"; lens a 9 0 x reviewer
fold --max 3 --total-score 9
expect 2 'FOLD-RESULT FAIL malformed' "an unknown kind → exit 2"
: > "$T_TMP/in"; lens ../x 9 0 x other
fold --max 3 --total-score 9
expect 2 'FOLD-RESULT FAIL malformed' "an agent name with a slash (it names a file) → exit 2"
: > "$T_TMP/in"; lens a 9 0 x other; lens a 8 0 y other
fold --max 3 --total-score 9
expect 2 'FOLD-RESULT FAIL malformed' "the same agent on two lines → exit 2"
fold --max 1 --total-score 9
expect 2 'FOLD-RESULT FAIL usage' "a cap that leaves no place beside the zero-context reader → usage"
fold --max 3
expect 2 'FOLD-RESULT FAIL usage' "no total score → usage"

# --- the text that uses them -----------------------------------------------------------------------------------------
G=getting-started.claude.md
for f in skills/review-code/SKILL.md skills/review-plan/SKILL.md; do
  check "$f: MAX_REVIEWERS is a hard total, default 5" grep -q '^MAX_REVIEWERS  *— the HARD TOTAL of reviewer agents' "$f"
  check "$f: runs the scripts and may run them" sh -c 'grep -q "bin/reviewer-fold.sh" "$1" && head -6 "$1" | grep -qF "Bash(bash .claude/skills/review-code/bin/reviewer-fold.sh *)" && head -6 "$1" | grep -qF "Bash(bash .claude/skills/review-code/bin/lens-score.sh *)"' _ "$f"
done
RC=skills/review-code/SKILL.md
for slot in LENS_WEIGHTS SMALL_DIFF_SCORE REVIEWER_STEP_SCORE LENS_MIN_SCORE 'LENS_CHECK_<agent>'; do
  check "review-code: has the $slot slot with a default" sh -c 'grep -A3 -- "^$2  *— " "$1" | grep -qi "default"' _ "$RC" "$slot"
done
check "review-code: the decision table is printed" grep -q 'Print the decision table' "$RC"
check "review-code: the second pass reuses the same agents" grep -q 'reuses the same agents' "$RC"
check "reviewer prompt: hybrids load the full profiles" grep -q 'full definition file' skills/review-code/references/reviewer-prompt.md
check "bootstrap-agents: the Lens section is an index, the full file is what a hybrid loads" grep -q 'A `## Lens` section of three to six lines: an index' skills/bootstrap-agents/SKILL.md
check "onboarding: MAX_REVIEWERS is in the slot map, the others as defaults" sh -c 'grep -q "^| \`MAX_REVIEWERS\` (\`review-code\`, \`review-plan\`) |" "$1" && grep -q "^| \`LENS_WEIGHTS\`, \`SMALL_DIFF_SCORE\`, \`REVIEWER_STEP_SCORE\`, \`LENS_MIN_SCORE\`, \`LENS_CHECK_<agent>\` (\`review-code\`) | Not asked" "$1"' _ "$G"
check "onboarding: the reviewer-cap question, in plain words, with 5 recommended" grep -qF 'Your setup has N reviewer agents. How many may review one change at the same time? A) 5 (recommended); B) 3; C) 7' "$G"
check "onboarding: the question is skipped when the roster is at or under the cap" grep -qF 'Skipped when the roster has no more reviewer agents than 5' "$G"
check "onboarding: it is the last question, after the merge step" sh -c 'a="$(grep -n "Your setup has N reviewer agents" "$1" | head -1 | cut -d: -f1)"; b="$(grep -n "^\*\*12\. Merge\.\*\*" "$1" | cut -d: -f1)"; [ -n "$a" ] && [ -n "$b" ] && [ "$a" -gt "$b" ]' _ "$G"
t_done
