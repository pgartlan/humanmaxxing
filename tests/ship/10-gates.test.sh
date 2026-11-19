#!/usr/bin/env bash
# The gates that route on an exit code: the test-update guard (fail closed on an unreadable input; untracked tests count),
# the review chain (any call passes on top of an anchor, unreviewed links reported, a remote integration breaks it),
# ship-gate.sh (branch, ci-skip-label, flip, enqueue: no push between green and ready, the no-merge pause, never re-stamp),
# and the fix-round counter (a missing branch line keeps counting).
. "$(dirname "$0")/../lib.sh"
sen() { run bash "$B/ship-sentinel.sh" --contract=2 "$@"; }
gate() { run bash "$B/ship-gate.sh" --contract=2 "$@"; }
push() { run bash "$B/ship-push.sh" --contract=2 "$@"; }

# ---- test-update guard -------------------------------------------------------------------------------------------
t_fixture tug "DEFAULT_MODE=offload" "CRITICAL_GLOBS_FILE=.claude/critical-paths.txt"
t_branch feat/7-x
t_init ""; expect 0 'ship-init PASS' "init"
sen test-guard -- 'tests/**' '**/*.test.ts'
expect 1 'FAIL critical-without-tests' "a critical change with no test touched halts"
expect_out '^NONEXEMPT app/api/r.ts$' "and names the critical file"
mkdir -p tests/api && echo t > tests/api/r.test.ts
sen test-guard -- 'tests/**' '**/*.test.ts'
expect 0 'PASS test-guard ' "an UNTRACKED new test file satisfies it (nothing is committed at Step 1c)"
rm -rf tests
mv .claude/critical-paths.txt "$FIX/cp.bak"
sen test-guard -- 'tests/**'
expect 3 'FAIL test-guard-unreadable' "an unreadable globs file is exit 3, never 'nothing critical changed'"
# The qualifier the old pipe lost: as a 1c task it must not record green.
run bash "$B/ship-run.sh" --contract=2 start test-update-guard -- bash "$B/ship-sentinel.sh" --contract=2 test-guard -- 'tests/**'
check "the task did not record green" test "$RC" -ne 0
run bash "$B/ship-run.sh" --contract=2 collect test-update-guard
expect 1 'FAIL' "and collect reports it red"
mv "$FIX/cp.bak" .claude/critical-paths.txt
git update-ref -d refs/remotes/origin/main
sen test-guard -- 'tests/**'
expect 3 'FAIL' "an unresolvable merge-base is exit 3"
git fetch -q origin
sen test-guard
expect 2 'FAIL usage' "no test pathspec is a usage error"
printf '# off\n' > .claude/critical-paths.txt
sen test-guard -- 'tests/**'
expect 0 'PASS test-guard-no-critical' "no critical path changed: pass"
printf 'app/api/**\nlib/**\n' > .claude/critical-paths.txt

# ---- the review chain --------------------------------------------------------------------------------------------
t_fixture chain "DEFAULT_MODE=offload" "CRITICAL_GLOBS_FILE=.claude/critical-paths.txt"
t_branch 8-chain
t_init ""; expect 0 'ship-init PASS' "init (chain)"
run bash "$B/ship-sync.sh" --contract=2; expect 0 'PASS synced' "sync"
push; expect 0 'ship-push PASS' "initial push"
echo f1 >> lib/u.ts; git commit -qam "fix: Refs #8 (fix-round 1)"
push --kind fix --round 1 --review none; expect 0 'ship-push PASS' "an unreviewed fix push"
sen verify review
expect 1 'FAIL review-invalid' "with no anchor review, the chain does not pass"
expect_out '^REVIEW: CHAIN-UNANCHORED' "as CHAIN-UNANCHORED"
FP=$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint | head -1)
printf '%s\n%s\n%s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$(date +%s)" "x" > "$ST/review-code-ran"
sen verify review
expect 0 'PASS' "on top of an anchor review, an unreviewed fix link passes (unreviewed deltas can merge)"
expect_out '^REVIEW: CHAIN review=none round=1 reviewed=0 unreviewed_delta: files=1 lines=1 links=1' "and the unreviewed delta is reported"
echo f2 >> lib/u.ts; git commit -qam "fix: Refs #8 (fix-round 2)"
push --kind fix --round 2 --review full; expect 0 'ship-push PASS' "a fix push claiming a full review"
expect_out '^WARN --review full but no review covers the pushed tree' "with no review on the pushed tree it WARNs"
check "and is recorded unreviewed" sh -c "tail -1 '$ST/review-chain' | cut -f4 | grep -qx 0"
printf '%s\n%s\n%s\n' "$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint | head -1)" "$(date +%s)" "x" > "$ST/review-code-ran"
echo f3 >> lib/u.ts; git commit -qam "fix: Refs #8 (fix-round 3)"
printf '%s\n%s\n%s\n' "$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint | head -1)" "$(date +%s)" "x" > "$ST/review-code-ran"
push --kind fix --round 3 --review full; expect 0 'ship-push PASS' "a fix push the review covers"
check "is recorded reviewed" sh -c "tail -1 '$ST/review-chain' | cut -f4 | grep -qx 1"
echo f4 >> lib/u.ts; git commit -qam "fix: Refs #8 (fix-round 4)"
push --kind fix --round 4 --review manual; expect 0 'ship-push PASS' "a fix push with the agent's own look"
check "manual is never counted as reviewed" sh -c "tail -1 '$ST/review-chain' | cut -f4 | grep -qx 0"
echo r >> lib/n.ts; git commit -qam "Refs #8 sibling"
push --kind rebase --review full --remote-integrated; expect 0 'ship-push PASS' "a remote-integrated push"
sen verify review
expect 1 'FAIL review-invalid' "breaks the chain"
expect_out '^REVIEW: CHAIN-BROKEN' "as CHAIN-BROKEN"
printf '%s\n%s\n%s\n' "$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint | head -1)" "$(( $(date +%s) + 1 ))" "x" > "$ST/review-code-ran"
sen verify review
expect 0 'PASS' "a review after the break re-anchors it"

# ---- ship-gate.sh: branch and ci-skip-label ----------------------------------------------------------------------
gate branch --protected 'PROTECTED_BRANCHES'
expect 2 'FAIL usage' "an unsubstituted slot is a usage error, never 'not protected'"
gate branch --protected '^(main|8-)'
expect 1 'FAIL protected-branch' "a protected branch halts (exit 1, not just a message)"
gate branch --protected '^main$'
expect 0 'PASS branch' "a feature branch with work passes"
gate ci-skip-label
expect 1 'FAIL offload-never' "OFFLOAD never applies the CI-skip label"

# ---- ship-gate.sh: flip and enqueue against a fake gh ------------------------------------------------------------
mkdir -p "$FIX/fakebin"; PRJSON="$FIX/pr.json"; GHLOG="$FIX/gh.log"
cat > "$FIX/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GHLOG"
case "$1 $2" in
  "pr view") cat "$PRJSON" ;;
  "pr ready") jq '.isDraft=false' "$PRJSON" > "$PRJSON.t" && mv "$PRJSON.t" "$PRJSON" ;;
  "pr edit") jq --arg l "$5" '.labels += [{"name":$l}]' "$PRJSON" > "$PRJSON.t" && mv "$PRJSON.t" "$PRJSON" ;;
  "pr merge") exit 0 ;;
  *) exit 1 ;;
esac
FAKE
chmod 755 "$FIX/fakebin/gh"; export PRJSON GHLOG PATH="$FIX/fakebin:$PATH"
HEADSHA=$(git rev-parse HEAD)
mkpr() { printf '{"state":"OPEN","headRefName":"8-chain","headRefOid":"%s","isDraft":%s,"mergeable":"MERGEABLE","title":"%s","body":"%s","labels":[]}\n' "$HEADSHA" "$1" "$2" "$3" > "$PRJSON"; }
mkpr true "Ship it (Refs #8)" "Closes #8"
echo 5 > "$ST/ship-pr-number"
gate flip --pr 5
expect 1 'FAIL ci-not-green-at-head' "no CI_GREEN recorded for HEAD: no flip"
check "nothing was flipped" sh -c "! grep -q '^pr ready' '$GHLOG' 2>/dev/null"
printf '%s\n' "$HEADSHA" > "$ST/ship-ci-green-sha"
printf 'EXEMPT: test fixture\n%s\n%s\n' "$(date +%s)" "$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint | head -1)" > "$ST/real-e2e-shipgate-passed"
rm -f "$ST/ship-phase1-passed"
gate flip --pr 5
expect 1 'FAIL phase1-absent' "an absent Phase 1 (a sync removed it) blocks the flip"
run bash "$B/ship-run.sh" --contract=2 start lint -- true
sen write phase1; expect 0 'PASS' "phase1 written"
echo moved >> lib/u.ts; git commit -qam "fix: Refs #8 (fix-round 5)"
gate flip --pr 5
expect 1 'FAIL head-moved' "a commit after the green: the PR head is no longer HEAD"
git reset -q --hard "$HEADSHA"
echo again >> lib/n.ts   # a fix round after Phase 1: the sentinel is present but no longer matches; then committed and "pushed"
git commit -qam "fix: Refs #8 (fix-round 6)"; git push -q origin HEAD:8-chain -f; HEADSHA=$(git rev-parse HEAD)
printf '%s\n' "$HEADSHA" > "$ST/ship-ci-green-sha"; mkpr true "Ship it (Refs #8)" "Closes #8"
printf '%s\n%s\n%s\n' "$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint | head -1)" "$(( $(date +%s) + 2 ))" "x" > "$ST/review-code-ran"
printf 'EXEMPT: test fixture\n%s\n%s\n' "$(date +%s)" "$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint | head -1)" > "$ST/real-e2e-shipgate-passed"
gate flip --pr 5 --check-only
expect 0 'PASS flip-check' "a phase1 that moved with a fix round (not absent) does not block: CI is that round's re-check"
gate flip --pr 5
expect 0 'PASS flipped' "flip on green at HEAD"
check "gh pr ready ran" grep -q '^pr ready 5' "$GHLOG"
touch "$ST/ship-no-merge"
gate enqueue --pr 5 -- --squash
expect 1 'FAIL no-merge' "the user's no-merge pause refuses the enqueue"
rm -f "$ST/ship-no-merge"
mkpr false "Closes #8 now" "Closes #8"
gate enqueue --pr 5 -- --squash
expect 1 'FAIL title-closing-keyword' "a closing keyword in the live title refuses the enqueue"
# A started issue with no closing line WARNS and the enqueue proceeds (user decision: customers may run their issue flow
# differently); a closing keyword in a commit message still refuses (it closes the issue past every gate).
mkpr false "Ship it (Refs #8)" "Refs #8"
gate enqueue --pr 5 -- --squash
expect 0 'PASS merge-requested' "no closing line for the started issue: the enqueue proceeds"
expect_out '^WARN started-issue-not-closed: #8' "with a warning naming the issue"
git commit -q --allow-empty -m "Refs #8 note" -m "this closes #8 for good"
git push -q origin HEAD:8-chain -f; HEADSHA=$(git rev-parse HEAD); printf '%s\n' "$HEADSHA" > "$ST/ship-ci-green-sha"; mkpr false "Ship it (Refs #8)" "Closes #8"
gate enqueue --pr 5 -- --squash
expect 1 'FAIL commit-closing-keyword' "a closing keyword mid-line in a commit message still refuses"
git reset -q --hard HEAD^; git push -q origin HEAD:8-chain -f; HEADSHA=$(git rev-parse HEAD); printf '%s\n' "$HEADSHA" > "$ST/ship-ci-green-sha"
# A line-start ADDITIONAL PR REQUIRED banner owning #8, backed by the reviewed plan's ## PRs row: no warning.
BANNER='⚠️ ADDITIONAL PR REQUIRED (1 total): the migration — owns #8 — blocker: needs the schema change first'
printf 'Refs #8\n\n%s\n' "$BANNER" > "$FIX/body.md"
gate body-check --file "$FIX/body.md"
expect 0 'PASS body-check-warned' "a banner no reviewed plan backs: passes with a warning"
expect_out '^WARN banner-not-in-plan: #8' "named banner-not-in-plan"
mkdir -p docs/plans; echo 'docs/plans/' >> "$(git rev-parse --git-path info/exclude)"   # keep the fixture's E2E binding unchanged
printf '# Plan\n\n## PRs\n\n| Additional PR scope | Owns | Hard blocker | User-approved? |\n|---|---|---|---|\n| the migration | #8 | schema first | yes |\n\n## Close-out\n' > docs/plans/8-chain.md
gate body-check --file "$FIX/body.md"
expect 0 'PASS body-check$' "banner + approved plan row: no warning"
refute_out '^WARN' "nothing warned"
sed -i.bak 's/| yes |/| pending |/' docs/plans/8-chain.md && rm -f docs/plans/8-chain.md.bak
gate body-check --file "$FIX/body.md"
expect_out '^WARN banner-not-in-plan: #8' "a plan row the user has not approved does not back it"
sed -i.bak 's/| pending |/| yes |/' docs/plans/8-chain.md && rm -f docs/plans/8-chain.md.bak
printf 'Refs #8\n\n```\n%s\n```\n' "$BANNER" > "$FIX/body.md"
gate body-check --file "$FIX/body.md"
expect_out '^WARN started-issue-not-closed: #8' "a banner inside a code fence is not rendered: it names nothing"
printf 'Refs #8\n\n⚠️ ADDITIONAL PR REQUIRED (1 total): x — owns none — needs #8 first\n' > "$FIX/body.md"
gate body-check --file "$FIX/body.md"
expect_out '^WARN started-issue-not-closed: #8' "a #N outside the owns segment owns nothing"
printf '<!-- Closes #8 -->\nRefs #8\n' > "$FIX/body.md"
gate body-check --file "$FIX/body.md"
expect_out '^WARN started-issue-not-closed: #8' "a closing keyword hidden in an HTML comment closes nothing"
printf 'Closes #8\n' > "$FIX/body.md"
gate body-check --file "$FIX/body.md"
expect 0 'PASS body-check$' "a closing line: no warning"
mkpr false "Ship it (Refs #8)" "Refs #8\\n\\n$BANNER"
gate enqueue --pr 5 -- --squash
expect 0 'PASS merge-requested' "the enqueue with a backed banner proceeds"
refute_out '^WARN (started-issue-not-closed|banner-not-in-plan)' "with no warning"
rm -rf docs/plans
mkpr false "Ship it (Refs #8)" "Closes #8"
gate enqueue --pr 5 -- --admin
expect 2 'FAIL admin-refused' "--admin is refused"
gate enqueue --pr 5 -- --squash
expect 0 'PASS merge-requested' "direct: the merge runs through the gate"
check "with the merge flags" grep -q '^pr merge 5 --squash' "$GHLOG"
git update-index --skip-worktree .claude/skills/ship/ship.env   # a config change, not a change to the PR's tree
printf 'MERGE_METHOD=queue\nQUEUE_LABEL=ready-to-merge\n' >> .claude/skills/ship/ship.env
gate enqueue --pr 5
expect 0 'PASS enqueued' "queue: the label is applied and read back"
gate enqueue --pr 5
expect 10 'SKIP label-present' "a label already on the PR is never re-stamped"
check "the label was written once" test "$(grep -c '^pr edit 5 --add-label' "$GHLOG")" = 1
# A conflict while queued: re-sync (which deletes Phase 1), push a new head, CI green on it. The re-enqueue must NOT demand
# a local Phase-1 re-run: after the flip OFFLOAD does not read it; CI on the new head is the re-check.
rm -f "$ST/ship-phase1-passed"
echo resolved >> lib/n.ts; git commit -qam "Refs #8 conflict resolution"; git push -q origin HEAD:8-chain -f; HEADSHA=$(git rev-parse HEAD)
mkpr false "Ship it (Refs #8)" "Closes #8"
printf '%s\n%s\n%s\n' "$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint | head -1)" "$(( $(date +%s) + 2 ))" "x" > "$ST/review-code-ran"
printf 'EXEMPT: test fixture\n%s\n%s\n' "$(date +%s)" "$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint | head -1)" > "$ST/real-e2e-shipgate-passed"
gate enqueue --pr 5
expect 1 'FAIL ci-not-green-at-head' "the new head is not enqueued before CI is green on it"
printf '%s\n' "$HEADSHA" > "$ST/ship-ci-green-sha"
gate enqueue --pr 5
expect 0 'PASS enqueued' "green on the new head: re-enqueued with no Phase-1 sentinel"

# ---- the Phase-1 task list is configuration; an empty command never records green ---------------------------------
t_fixture req "DEFAULT_MODE=offload" "CHECK_TASKS=lint:both,unit:local,typecheck" "CHECK_CMD_lint=true" "CHECK_CMD_unit=true" "CHECK_CMD_typecheck=true"
t_branch feat/10-q
t_init ""; expect 0 'ship-init PASS' "init (configured checks)"
run bash "$B/ship-run.sh" --contract=2 required
expect 0 'PASS' "required lists the mode's checks"
expect_out '^typecheck$' "a mode-less entry applies to both modes"
refute_out '^unit$' "a local-only check is not required in OFFLOAD"
run bash "$B/ship-run.sh" --contract=2 start lint
expect 0 'PASS' "a configured check runs its configured command"
sen write phase1
expect 1 'FAIL tasks-not-green' "a required check that was never launched blocks Phase 1 (the model's launch list is not the requirement)"
expect_out 'typecheck WAIT' "and is named as pending"
run bash "$B/ship-run.sh" --contract=2 start typecheck -- true
expect 2 'FAIL configured-task' "a configured check cannot be given a different typed command"
run bash "$B/ship-run.sh" --contract=2 start typecheck
sen write phase1
expect 0 'PASS' "every required check green: Phase 1 written"
run bash "$B/ship-run.sh" --contract=2 start other -- bash -c ''
expect 2 'FAIL empty-command' "bash -c '' (an unset slot) is refused, never a green task"
run bash "$B/ship-run.sh" --contract=2 start other -- bash -c "$(printf ' \n')"
expect 2 'FAIL empty-command' "so is a whitespace-only script"
check "and nothing was recorded for it" test ! -e "$ST/tasks/other.exit"
printf 'CHECK_CMD_unit=\n' >> .claude/skills/ship/ship.env
run bash "$B/ship-run.sh" --contract=2 required
expect 2 'FAIL ship-env-malformed' "a configured check with an empty command is a configuration error before any gate"

# ---- release actions: one script per leg, the harvest must be STAGED ------------------------------------------------
t_fixture rel "DEFAULT_MODE=offload"
git checkout -q -b 11-rel; t_init ""; expect 0 'ship-init PASS' "init (release)"
run bash "$B/ship-release.sh" --contract=2 lint; expect 10 'SKIP not-configured' "RELEASE_ACTIONS unset: skipped"
printf 'RELEASE_ACTIONS=file-ledger\nRELEASE_ACTION_LINT_CMD=true\n' >> .claude/skills/ship/ship.env
run bash "$B/ship-release.sh" --contract=2 lint; expect 2 'FAIL ship-env-malformed' "file-ledger with a command missing is a configuration error"
printf 'RELEASE_ACTION_HARVEST_CMD=mkdir -p ledger && cp "$BODY" ledger/row.md\nRELEASE_LEDGER_DIR=ledger\n' >> .claude/skills/ship/ship.env
run bash "$B/ship-release.sh" --contract=2 harvest; expect 10 'SKIP no-body' "no body file yet: skipped"
echo "body" > "$ST/pr-body-11-rel.md"
run bash "$B/ship-release.sh" --contract=2 harvest; expect 0 'PASS harvested' "harvested"
check "and the ledger row is staged (it ships with the commit)" sh -c "git diff --cached --name-only | grep -qx ledger/row.md"
printf 'RELEASE_ACTION_LINT_CMD=exit 1\n' >> .claude/skills/ship/ship.env
run bash "$B/ship-release.sh" --contract=2 lint; expect 1 'FAIL lint-hit' "a lint hit halts"
printf 'RELEASE_ACTION_LINT_CMD=exit 7\n' >> .claude/skills/ship/ship.env
run bash "$B/ship-release.sh" --contract=2 lint; expect 3 'FAIL lint-failed' "a lint that could not run is never clean"

# ---- the pre-push wait pushes past a running run only when it is past its ceiling ---------------------------------
cp_at() { bash -c ". '$B/ship-lib.sh'; ship_ceiling_passed \"\$1\" \"\$2\"" _ "$1" "$2"; }
OLD=$(date -u -d "@$(( $(date +%s) - 7200 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( $(date +%s) - 7200 ))" +%Y-%m-%dT%H:%M:%SZ)
NEW=$(date -u -d "@$(( $(date +%s) - 1500 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( $(date +%s) - 1500 ))" +%Y-%m-%dT%H:%M:%SZ)
check "a run older than the ceiling: yes (push allowed)" test "$(cp_at "$OLD" 60)" = yes
check "a 25-minute-old run under a 60-minute ceiling: no (re-arm, do not push)" test "$(cp_at "$NEW" 60)" = no
check "an unreadable start: unknown (re-arm, never push)" test "$(cp_at "" 60)" = unknown
check "a garbage start: unknown" test "$(cp_at "yesterday-ish" 60)" = unknown

# ---- the fix-round counter fails toward the cap ------------------------------------------------------------------
t_fixture rounds2 "DEFAULT_MODE=offload" "FIX_ROUND_CAP=2"
t_branch feat/9-r
t_init ""; expect 0 'ship-init PASS' "init (rounds)"
run bash "$B/ship-census.sh" --contract=2 --round-gate; expect 0 'PASS fix-round=1' "round 1"
R=$(ls "$ST"/*round* | head -1)
printf '2\n' > "$R"
run bash "$B/ship-census.sh" --contract=2 --round-gate
expect 1 'FAIL round-cap' "a count-only counter file keeps counting (a missing branch line never resets it)"
printf '1\nfeat/9-r\n99999\n' > "$R"
run bash "$B/ship-census.sh" --contract=2 --round-gate
expect 3 'FAIL counter-corrupt' "a hand-raised allowance is refused"

t_done
