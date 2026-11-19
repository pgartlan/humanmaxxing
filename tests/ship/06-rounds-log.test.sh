#!/usr/bin/env bash
# The fix-round gate (a cap that survives a restart and is extended only on request) and the event ledger.
. "$(dirname "$0")/../lib.sh"
gate() { run bash "$B/ship-census.sh" --contract=2 --round-gate "$@"; }

t_fixture rounds "DEFAULT_MODE=offload" "FIX_ROUND_CAP=2"
t_branch feat/7-x
t_init ""; expect 0 'ship-init PASS' "init"

gate --extend; expect 2 'FAIL extend-not-needed' "--extend before the cap is a usage error"
gate; expect 0 'PASS fix-round=1' "round 1"
refute_out '^TELL_USER' "no user notice before the last allowed round"
gate; expect 0 'PASS fix-round=2' "round 2 (the cap)"
expect_out '^TELL_USER' "the last allowed round tells the user"
gate; expect 1 'FAIL round-cap' "round 3 stops and asks"

t_init ""
expect_out '^START: resume' "a restart on the same branch resumes"
gate; expect 1 'FAIL round-cap' "and the cap is remembered across the restart"
gate --extend; expect 0 'PASS fix-round=3' "--extend grants another allowance"

t_init "--fresh"
gate; expect 0 'PASS fix-round=1' "--fresh resets the counter"

echo "not-a-number" > "$(ls "$ST"/*round* 2>/dev/null | head -1)"
gate; expect 3 'FAIL counter-corrupt' "a corrupt counter is an error, never round 1"

run bash "$B/ship-log.sh" auto-decision class=flatten-avoided
expect 0 'ledger=(written|gap)' "an event is logged"
run bash "$B/ship-log.sh" summary
expect_rc 0 "summary"
expect_out '^FIXLOOP: .*auto-decision=1' "the summary counts the logged decision"
run bash "$B/ship-log.sh"
expect_rc 2 "ship-log with no arguments is a usage error"

t_done
