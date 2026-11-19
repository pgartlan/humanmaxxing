#!/usr/bin/env bash
# ship-run (the task runner) and the Phase-1 sentinel: green/red/pending, the stale-tree refusal, docs exclusion.
. "$(dirname "$0")/../lib.sh"

t_fixture run "DEFAULT_MODE=offload" "CRITICAL_GLOBS_FILE=.claude/critical-paths.txt" \
  'DOCS_ALLOWLIST=(\.md$|\.txt$|^docs/|(^|/)CHANGELOG)'
t_branch feat/7-x
t_init ""; expect 0 'ship-init PASS' "init"

run bash "$B/ship-sentinel.sh" --contract=2 write phase1
expect 1 'FAIL no-tasks' "phase1 cannot be written before any task ran"

run bash "$B/ship-run.sh" --contract=2 start lint -- bash -c 'echo linting; exit 0'
expect 0 'SHIP-RESULT ship-run PASS' "a green task"
run bash "$B/ship-run.sh" --contract=2 start unit -- bash -c 'echo boom >&2; exit 3'
expect 1 'SHIP-RESULT ship-run FAIL .*rc=3' "a red task reports the command's own exit code"
expect_out 'boom' "and prints the log tail"

run bash "$B/ship-run.sh" --contract=2 collect lint
expect 0 'ship-run PASS' "collect of a green task"
run bash "$B/ship-run.sh" --contract=2 collect lint,unit
expect 1 'FAIL red.*unit' "collect names the red task"
run bash "$B/ship-run.sh" --contract=2 collect lint,build
expect 4 'WAIT pending.*build' "a task that never ran is pending, never green"

run bash "$B/ship-sentinel.sh" --contract=2 write phase1
expect 1 'FAIL tasks-not-green' "phase1 is refused while a recorded task is red"

run bash "$B/ship-run.sh" --contract=2 start unit -- true
expect 0 'ship-run PASS' "the task re-run green"
run bash "$B/ship-sentinel.sh" --contract=2 write phase1
expect 0 'ship-sentinel PASS' "phase1 written once every recorded task is green"
run bash "$B/ship-sentinel.sh" --contract=2 verify phase1
expect 0 'ship-sentinel PASS' "phase1 verifies on the same tree"

echo more >> docs/x.md
run bash "$B/ship-sentinel.sh" --contract=2 verify phase1
expect 0 'ship-sentinel PASS' "a docs-allowlisted edit keeps phase1 valid"
git checkout -q docs/x.md
echo more >> lib/u.ts
run bash "$B/ship-sentinel.sh" --contract=2 verify phase1
expect 1 'FAIL phase1-tree-moved' "a code edit invalidates phase1"
run bash "$B/ship-sentinel.sh" --contract=2 verify phase1 --committed
expect 1 'FAIL (tree-not-committed|phase1-tree-moved)' "--committed refuses a dirty tracked file"

# A task that ran on another tree cannot back a new sentinel.
run bash "$B/ship-sentinel.sh" --contract=2 write phase1
expect 1 'FAIL tasks-not-green' "tasks that ran before the edit do not count for the edited tree"
run bash "$B/ship-run.sh" --contract=2 collect lint,unit --same-tree
expect 1 'FAIL stale-tree' "collect --same-tree names the tasks that ran on another tree"
git checkout -q lib/u.ts

run bash "$B/ship-sentinel.sh" --contract=2 invalidate phase1
expect 0 'ship-sentinel PASS' "invalidate"
run bash "$B/ship-sentinel.sh" --contract=2 verify phase1
expect 1 'FAIL phase1-absent' "an invalidated phase1 is absent"

# A fresh init stops a live task and discards its result.
bash "$B/ship-run.sh" --contract=2 start slow -- sleep 30 >"$FIX/slow.out" 2>&1 &
SLOW=$!
# Wait until the task has started (its log has the command line, written after its pid file), not a fixed second.
i=0; while ! grep -q '^+ ' "$ST/tasks/slow.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
t_init "--fresh"
expect 0 'ship-init PASS' "fresh init while a task is live"
expect_out 'STOPPED' "names the stopped task"
wait "$SLOW" 2>/dev/null
check "the stopped task did not report green" sh -c "! grep -q 'SHIP-RESULT ship-run PASS' '$FIX/slow.out'"

# --- the base moving while a task runs; a fixer task -------------------------------------------------------------
t_fixture race "DEFAULT_MODE=local" 'DOCS_ALLOWLIST=(\.md$|\.txt$|^docs/|(^|/)CHANGELOG)'
t_branch feat/9-r
t_init ""; expect 0 'ship-init PASS' "init (race)"
run bash "$B/ship-sync.sh" --contract=2; expect 0 'PASS synced' "sync (race)"
GATE="$FIX/go"; rm -f "$GATE"
bash "$B/ship-run.sh" --contract=2 start held -- sh -c "while [ ! -f '$GATE' ]; do sleep 0.1; done" > "$FIX/held.out" 2>&1 &
HP=$!
i=0; while ! grep -q '^+ ' "$ST/tasks/held.log" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
t_base_commit lib/base.ts b1; git rebase -q origin/main
touch "$GATE"; wait "$HP"
run bash "$B/ship-run.sh" --contract=2 collect held --same-tree
expect 1 'FAIL stale-tree' "a task during which the base moved is stale"
expect_out 'the base moved while it ran' "and says why"
run bash "$B/ship-run.sh" --contract=2 start fmt -- sh -c 'echo fixed >> lib/u.ts'
run bash "$B/ship-run.sh" --contract=2 collect fmt --same-tree
expect 0 'ship-run PASS' "a fixer task vouches for the tree it leaves behind, on its first run"
git checkout -q lib/u.ts
printf 'rc=0\nepoch=%s\nhead=x\nfp=unknown\nmb_start=unknown\nmb=unknown\n' "$(date +%s)" > "$ST/tasks/fmt.exit"
run bash "$B/ship-run.sh" --contract=2 collect fmt --same-tree
expect 1 'FAIL stale-tree' "an exit file with an unrecorded tree or base is stale, never green"
# The base-not-recorded guard on its own: a real exit file whose tree is current.
run bash "$B/ship-run.sh" --contract=2 start ctl -- true
run bash "$B/ship-run.sh" --contract=2 collect ctl --same-tree
expect 0 'ship-run PASS' "control: an unmodified exit file on this tree is green"
sed -e 's/^mb_start=.*/mb_start=unknown/' -e 's/^mb=.*/mb=unknown/' "$ST/tasks/ctl.exit" > "$FIX/ctl.exit" && mv -f "$FIX/ctl.exit" "$ST/tasks/ctl.exit"
check "the exit file now records an unknown base" grep -qx 'mb_start=unknown' "$ST/tasks/ctl.exit"
run bash "$B/ship-run.sh" --contract=2 collect ctl --same-tree
expect 1 'FAIL stale-tree' "a current tree with an unknown base is stale, never green"
expect_out 'its base was not recorded' "and says why"
grep -v '^mb' "$ST/tasks/ctl.exit" > "$FIX/ctl.exit"; mv -f "$FIX/ctl.exit" "$ST/tasks/ctl.exit"
check "the exit file now has no base lines" sh -c "! grep -q '^mb' '$ST/tasks/ctl.exit'"
run bash "$B/ship-run.sh" --contract=2 collect ctl --same-tree
expect 1 'FAIL stale-tree' "a current tree with no base lines (an older ship) is stale too"

t_done
