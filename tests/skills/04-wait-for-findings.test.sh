#!/usr/bin/env bash
# review-code's bin/wait-for-findings.sh (the Step 5 watcher and the Step 14 sentinel hold), plus the text that must
# use it, and the start / review-code / review-plan qualifiers the onboarding relies on.
# Mutations this file must catch: count a file that merely exists · count a marker that is not the last non-empty line ·
# count another run's id · accept R1 for an R2 entry · ignore round1/ for an R1 entry · wait under --check · a missing
# dir read as "nothing yet" · a run.env without EXPECT read as "nothing expected".
. "$(dirname "$0")/../lib.sh"
cd "$T_ROOT" || exit 2
W="${WAIT_UNDER_TEST:-$T_ROOT/skills/review-code/bin/wait-for-findings.sh}"
D="$T_TMP/f"; mkdir -p "$D"
printf 'RUN_ID=rv-1\nEXPECT=api,test,zero-context\n' > "$T_TMP/run.env"

run bash "$W" --check --run-env "$T_TMP/run.env" --dir "$D"
expect 1 '^MISSING: api,test,zero-context$' "--check on an empty dir lists every expected reviewer"

printf 'findings\n' > "$D/api.md"
printf '<!-- REVIEW-COMPLETE test rv-1 -->\nlate edit after the marker\n' > "$D/test.md"
printf 'x\n<!-- REVIEW-COMPLETE zero-context rv-0 -->\n' > "$D/zero-context.md"
run bash "$W" --check --run-env "$T_TMP/run.env" --dir "$D"
expect 1 '^MISSING: api,test,zero-context$' "an existing file, a mid-file marker and another run's marker do not count"

printf 'findings\n<!-- REVIEW-COMPLETE api rv-1 -->\n\n  \n' > "$D/api.md"
printf 'x\n<!-- REVIEW-COMPLETE test rv-1 -->\r\n' > "$D/test.md"
run bash "$W" --check --run-env "$T_TMP/run.env" --dir "$D"
expect 1 '^MISSING: zero-context$' "the last non-empty line counts; trailing blank lines and CR are ignored"
printf 'x\n<!-- REVIEW-COMPLETE zero-context rv-1 -->\n' > "$D/zero-context.md"
run bash "$W" --check --run-env "$T_TMP/run.env" --dir "$D"
expect 0 '^READY: 3/3$' "every marker present → READY"

# Mediated mode: R1 / R2 entries; round 1 may sit in round1/.
M="$T_TMP/m"; mkdir -p "$M/round1"
printf '<!-- REVIEW-COMPLETE api rv-2 R1 -->\n' > "$M/round1/api.md"
printf '<!-- REVIEW-COMPLETE api rv-2 R1 -->\n' > "$M/api.md"
run bash "$W" --check --run-id rv-2 --expect api:R1,api:R2 --dir "$M"
expect 1 '^MISSING: api:R2$' "an R1 marker does not satisfy an R2 entry"
printf 'round 2\n<!-- REVIEW-COMPLETE api rv-2 R2 -->\n' > "$M/api.md"
run bash "$W" --check --run-id rv-2 --expect api:R1,api:R2 --dir "$M"
expect 0 '^READY: 2/2$' "R1 is found in round1/ once round 2 rewrote the file"

# Waiting: a timeout is 124, never READY; it waits at least --timeout.
start=$(date +%s)
run bash "$W" --run-id rv-3 --expect nobody --dir "$D" --timeout 1 --poll 1
expect 124 '^MISSING: nobody$' "a timeout with a missing marker exits 124"
[ $(( $(date +%s) - start )) -ge 1 ] && t_pass "the wait lasts at least --timeout" || t_fail "the wait lasts at least --timeout"

run bash "$W" --check --run-id rv-1 --expect api --dir "$T_TMP/no-such-dir"
expect_rc 3 "a missing findings dir exits 3, never 'nothing yet'"
printf 'RUN_ID=rv-1\n' > "$T_TMP/bad.env"
run bash "$W" --check --run-env "$T_TMP/bad.env" --dir "$D"
expect_rc 2 "a run.env without EXPECT is a usage error, never 'nothing expected'"
run bash "$W" --check --run-id 'rv 1' --expect api --dir "$D"
expect_rc 2 "a run id with a space is refused"
run bash "$W" --check --run-env "$T_TMP/run.env" --run-id rv-1 --dir "$D"
expect_rc 2 "--run-env and --run-id together are refused (no retyped list)"

# --- the text that uses it ---------------------------------------------------------------------------------------
RVC=skills/review-code/SKILL.md; RP=skills/review-plan/SKILL.md; ST=skills/start/SKILL.md
RPR=skills/review-code/references/reviewer-prompt.md; PRP=skills/review-plan/references/plan-reviewer-prompt.md
check "review-code: allowed-tools grants the watcher script" sh -c 'sed -n 5p "$1" | grep -qF "Bash(bash .claude/skills/review-code/bin/wait-for-findings.sh *)"' _ "$RVC"
check "review-plan: allowed-tools grants the watcher script" sh -c 'sed -n 5p "$1" | grep -qF "Bash(bash .claude/skills/review-code/bin/wait-for-findings.sh *)"' _ "$RP"
check "review-code: the Step 14 hold runs --check from run.env before any write" grep -qF 'bash .claude/skills/review-code/bin/wait-for-findings.sh --check --run-env <SCRATCH_DIR>/run.env --dir <SCRATCH_DIR>/findings' "$RVC"
check "review-code: the hold is the only enforcement; ship checks fingerprints, not markers" grep -q 'This is the ONLY place the marker hold is enforced' "$RVC"
check "review-code: continuing without a reviewer gets no sentinel" grep -q 'still prints `MISSING: X` here and gets no sentinel' "$RVC"
check "review-code: no suite re-run after the fix pass, scoped runs and E2E excepted" sh -c 'grep -q "No re-run of the suites after the fix pass" "$1" && grep -q "a scoped run of one specific check that a fix in THIS pass targeted" "$1" && grep -q "which fix edits have no run on the final tree" "$1"' _ "$RVC"
check "review-code: recurrence verification verifies, never decides; malformed is CRITICAL" sh -c 'grep -q "this check verifies, it does not decide" "$1" && grep -q "(malformed: nothing downstream can read it)" "$1"' _ "$RVC"
check "test reviewer: test bugs only, never production code" grep -q 'TEST BUGS ONLY. Never modify production code to' "$RPR"
check "test reviewer: a non-test-bug failure is a BLOCK and no E2E sentinel" sh -c 'grep -q "A failure that is not a test bug is a finding: report it as a BLOCK" "$1" && grep -q "no E2E sentinel is written while it stands" "$1"' _ "$RPR"
check "test reviewer: run before report; never silently fall back to mocks" sh -c 'grep -q "Run before you report" "$1" && grep -q "Never silently fall back to mocks" "$1" && grep -q "## Mocked layers" "$1"' _ "$RPR"
check "test reviewer: a thoroughness gap is written, or WARNING with what stays untested" grep -q 'flag it WARNING and say$' "$RPR"
check "reviewers: the five invariant-guard BLOCK rules and the trace" sh -c 'for f in "$1" "$2"; do grep -q "consumers swept, not writers" "$f" && grep -q "Invariant-guard completeness trace" "$f" || exit 1; done' _ "$RPR" "$PRP"
check "detection table: matches become lenses the cap folds, never 'every match launches'" sh -c 'grep -q "every match becomes a lens" "$1" && ! grep -q "every match launches" "$1"' _ skills/review-code/references/detection-table.md
check "review-plan: non-DOWN or a missing DOWN on a closed-before ticket is a BLOCK" sh -c 'grep -q "\*\*BLOCK\*\* when the plan carries FLAT or UP for #N" "$1" && grep -q "Refs #N. and \"retitle the ticket to the remaining class\" are not remedies" "$1"' _ "$RP"
check "review-plan: an omitted precondition path is BLOCK when it produced the incident" grep -q 'BLOCK when it is the path that produced the incident' "$RP"
check "review-plan: a plan without PRs/Close-out is a WARNING, start's checker refuses it" grep -q 'its `check-plan-sections.sh` refuses a plan without them' skills/review-plan/references/plan-audits.md

check "start: Step 2.95 has gates A, B, C, D and a GROWING population is MASKING" sh -c 'grep -q "^## Step 2.95: Anti-masking gate" "$1" && grep -q "^- \*\*Gate A\*\*" "$1" && grep -q "^- \*\*Gate B\*\*" "$1" && grep -q "^- \*\*Gate C\*\*" "$1" && grep -q "^- \*\*Gate D\*\*" "$1" && grep -q "GROWING population means an alarm-config fix is MASKING" "$1"' _ "$ST"
check "start: Gate B re-tests the prior fix the least-scaffolded way" grep -q 'reproduce the prior fix through the least-scaffolded invocation' "$ST"
check "start: Gate D investigates the convergence mechanism, not the guard" grep -q 'investigate the upstream convergence mechanism that should have kept the invariant true, not the guard' "$ST"
check "start: Gate C records a bare verdict; non-DOWN is a BLOCK and never ships" sh -c 'grep -q "Non-DOWN is a BLOCK" "$1" && grep -q "never ship a non-DOWN verdict" "$1"' _ "$ST"
check "start: anti-masking reference has every gate and the Gate C prompt" sh -c 'for g in A B D; do grep -q "^### Gate $g " "$1" || exit 1; done; grep -q "^## Gate C" "$1" && grep -q "ONE question: a month after this plan ships" "$1"' _ skills/start/references/anti-masking-gates.md
check "start: intended behavior is cited first, mandatory when a behavior flips, UNCONFIRMED otherwise" sh -c 'grep -q "Confirm the intended behavior FIRST, with a citation" "$1" && grep -q "mandatory whenever the fix flips or restores a behavior" "$1" && grep -q "UNCONFIRMED: <what you looked for>" "$1"' _ "$ST"
check "start: foundation reachability — unreachable means unwritten; fixtures from the observed response" sh -c 'grep -q "^## Step 4.6: Foundation-reachability gate" "$1" && grep -q "Treat it as UNWRITTEN, not as proven" "$1" && grep -q "from the OBSERVED response, never from your own interface type" "$1"' _ "$ST"
check "start: Step 7 runs the section check before the summary" sh -c 'grep -qF "bash .claude/skills/start/bin/check-plan-sections.sh <plan path>" "$1" && grep -q "do not print the summary until it exits 0" "$1" && sed -n 5p "$1" | grep -qF "Bash(bash .claude/skills/start/bin/check-plan-sections.sh *)"' _ "$ST"
check "start: the plan is written from the template, not from memory" grep -q 'Read \[`templates/plan.md`\](templates/plan.md) and fill EVERY section' "$ST"
check "start: Step 8 blocks done, ready-to-ship and compact handoffs until review passes" sh -c 'grep -q "^## Step 8: Code-review gate before any completion handoff" "$1" && grep -q "A prepared compact or \`/trim\` handoff, in ANY wording" "$1" && grep -q "it does NOT produce a sentinel" "$1"' _ "$ST"
check "start: Step 8 uses ship's own predicate; its --contract matches ship's SKILL_CONTRACT" sh -c 'n=$(grep -m1 -o "ship-sentinel.sh --contract=[0-9]* verify review" "$1" | sed "s/.*=\([0-9]*\) .*/\1/"); [ -n "$n" ] && grep -qx "SKILL_CONTRACT=$n" "$2"' _ "$ST" skills/ship/bin/ship-lib.sh
check "start: a failed reader is never a pass" grep -q 'never treat it as a pass' "$ST"
check "start: fixed-section completion handoff, remaining-work lists banned" sh -c 'grep -q "The completion handoff has fixed sections" "$1" && grep -q "\"remaining items\" and \"next steps for later\" lists are banned" "$1"' _ "$ST"
check "start: a clean checker run is positive-controlled before 'already fixed'" grep -q 'a clean checker run can also mean a BROKEN checker' "$ST"
check "start: ambiguity is asked before discovery, in one batch" grep -q '^## Step 2.5: Ambiguity gate (ask NOW, before discovery' "$ST"
check "start: no wake-up timer for its own agents" grep -q 'Do not arm a wake-up timer to wait for the Step 3 agents' "$ST"
check "start: Decisions needed come before the plan summary" sh -c 'a=$(grep -n "^### Decisions needed" "$1" | cut -d: -f1); b=$(grep -n "^### Plan summary" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$ST"
t_done
