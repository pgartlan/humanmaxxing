#!/usr/bin/env bash
# start's bin/check-plan-sections.sh (the Step 7 gate) and the plan template it checks.
# Mutations this file must catch: drop a required section · accept a section that only appears inside a code fence ·
# accept a backtick-wrapped or bulleted Recurrence-Verdict line · accept an inline (not line-start) Closes · accept an
# empty Data prerequisites · accept a template placeholder · ignore --bug · refuse a plan with no tracker.
. "$(dirname "$0")/../lib.sh"
cd "$T_ROOT" || exit 2
C="${CHECK_UNDER_TEST:-$T_ROOT/skills/start/bin/check-plan-sections.sh}"
TPL="$T_ROOT/skills/start/templates/plan.md"
P="$T_TMP/plan.md"

good_plan() {
  cat <<'EOF'
# #42 — Export drops the last row

## Root Cause

**Confirmed intended behavior:** every row is exported, per docs/export.md "Rows".

The loop stops one short at src/export.js:10.

## Fix

Iterate to the end.

## Implementation Steps

### Phase 1: loop bound
- [ ] src/export.js:10

### Data prerequisites

None

## PRs

PRs: 1 — this PR covers #42.

## Testing

- [ ] Unit: last row exported

### Why wasn't this caught?

No test had an odd row count.

### Prevention

A test with one and three rows.

### Bug class & guard

Off-by-one in loop bounds; none found beyond this site.

### Simplest version considered

Layer: the loop. Alternative: the caller pads the input — rejected, it hides the bug.

## Recurrence verdict

Recurrence-Verdict: #42 DOWN — the loop now reaches the last row

### Falsifiable verification

Invariant: rows out = rows in; next export run; the shipping session checks it.

## Risks & Adjacencies

- none

## Out of Scope

- none

## Close-out

- Closes #42
EOF
}

good_plan > "$P"
run bash "$C" "$P" --bug
expect 0 '^check-plan-sections: PASS' "a complete bug plan passes"
run bash "$C" "$P"
expect 0 'PASS' "no type flag: the full bug set is enough"
run bash "$C" "$P" --feature
expect 3 'FAIL' "--feature demands the E2E Test Plan"
expect_out 'MISSING section: ### E2E Test Plan' "--feature names the missing E2E Test Plan"

for h in '## PRs' '### Simplest version considered' '### Data prerequisites' '## Close-out' '### Prevention'; do
  good_plan | grep -vxF -- "$h" > "$P"
  run bash "$C" "$P" --bug
  expect 3 'FAIL' "missing '$h' fails"
  expect_out "MISSING section: $h" "missing '$h' is named"
done

good_plan | awk '/^## PRs$/ { print "```"; print; print "```"; next } { print }' > "$P"
run bash "$C" "$P" --bug
expect_out 'MISSING section: ## PRs' "a heading inside a code fence is not a section"

good_plan | sed 's/^Recurrence-Verdict: \(.*\)$/`Recurrence-Verdict: \1`/' > "$P"
run bash "$C" "$P" --bug
expect_out '^check-plan-sections: VERDICT' "a backtick-wrapped verdict line is refused"
good_plan | sed 's/^Recurrence-Verdict:/- Recurrence-Verdict:/' > "$P"
run bash "$C" "$P" --bug
expect_out '^check-plan-sections: VERDICT' "a bulleted verdict line is refused"
good_plan | sed 's/ DOWN — / SIDEWAYS — /' > "$P"
run bash "$C" "$P" --bug
expect_out '^check-plan-sections: VERDICT' "a verdict other than DOWN|FLAT|UP is refused"
good_plan | sed 's/ DOWN — / FLAT — /' > "$P"
run bash "$C" "$P" --bug
expect 0 'PASS' "a well-formed FLAT line passes the section check (review-plan blocks it, not this script)"

good_plan | sed 's/^- Closes #42$/This PR closes #42./' > "$P"
run bash "$C" "$P" --bug
expect_out '^check-plan-sections: CLOSE-OUT' "a closing keyword mid-sentence is not a close-out line"
good_plan | sed 's/^PRs: 1 — this PR covers #42\.$/One PR./' > "$P"
run bash "$C" "$P" --bug
expect_out '^check-plan-sections: PRS-COUNT' "a PRs section without 'PRs: <N>' is refused"
good_plan | awk 'p && /^None$/ { p = 0; next } /^### Data prerequisites$/ { p = 1 } { print }' > "$P"
run bash "$C" "$P" --bug
expect_out '^check-plan-sections: DATA-PREREQ' "an empty Data prerequisites section is refused (write None)"
good_plan | sed 's/^### Phase 1: loop bound$/### Phase 1: <name>/' > "$P"
run bash "$C" "$P" --bug
expect_out '^check-plan-sections: UNFILLED' "a template placeholder is refused"

# No tracker: a task in words, no ticket number anywhere.
good_plan | sed -e 's/^# #42 — /# /' -e 's/^- Closes #42$/- Done at merge: the export keeps the last row/' \
  -e '/^## Recurrence verdict$/,/^## Risks/{/^## Risks/!d}' > "$P"
run bash "$C" "$P" --bug --no-tracker
expect 0 'PASS' "--no-tracker: a task-in-words plan passes"
run bash "$C" "$P" --bug
expect 3 'FAIL' "without --no-tracker the same plan is refused"

run bash "$C" "$T_TMP/nope.md"
expect_rc 4 "a missing plan file exits 4"
run bash "$C"
expect_rc 2 "no argument is a usage error"

# The template itself carries every section the checker requires, and its placeholders are caught.
run bash "$C" "$TPL" --bug --feature
expect 3 'FAIL' "the unfilled template is refused"
refute_out 'MISSING section' "the template has every required section"
expect_out '^check-plan-sections: UNFILLED' "the template's placeholders are reported"

check "template: the suppression check names SEEN vs PRODUCED" sh -c 'grep -q "change how the bad state is SEEN" "$1" && grep -q "rate at which it is PRODUCED" "$1"' _ "$TPL"
check "template: 'the plan IS the simplest' is not an answer when it adds surface" grep -q '"The plan IS the simplest version" is not an answer when the plan adds' "$TPL"
check "template: machinery that makes an operation safe says why it cannot be prevented" grep -q 'why the operation cannot simply be prevented' "$TPL"
check "template: intended behavior is confirmed with a citation, or UNCONFIRMED" sh -c 'grep -q "^\*\*Confirmed intended behavior:\*\*" "$1" && grep -q "UNCONFIRMED: <what you looked for>" "$1"' _ "$TPL"
check "template: falsifiable verification names the invariant, the next event and who checks" sh -c 'grep -q "\*\*invariant\*\*" "$1" && grep -q "\*\*next concrete event\*\*" "$1" && grep -q "\*\*who checks it\*\*" "$1"' _ "$TPL"
check "template: Convergence preconditions table" grep -q '^### Convergence preconditions$' "$TPL"
check "template: FLAT or UP means the plan is not finished; Refs is no remedy" sh -c 'grep -q "FLAT or UP means the plan is not finished" "$1" && grep -q "are not remedies" "$1"' _ "$TPL"
t_done
