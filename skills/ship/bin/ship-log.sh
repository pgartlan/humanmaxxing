#!/usr/bin/env bash
# ship-log.sh <event> [k=v ...] | summary — the fix-loop ledger CLI (v1 placeholder: $SHIP_STATE/fixloop.tsv).
#   <event>   append one line, e.g. `auto-decision class=flatten-avoided`. Never blocks the ship: an unwritable
#             ledger WARNs and still exits 0 (`ledger=gap`).
#   summary   print `FIXLOOP: <N> events — <event>=<count> ...` for the final report.
#   mark <step>   write the step marker (pr-created | flipped | enqueued) bound to the current tree, for ship-status.sh.
# Exit: 0 · 2 usage. Callable by other skills without the contract (listed in SKILL_OPTIONAL_SCRIPTS).
# EXIT-CODES: 0 2
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-log
[ "$#" -ge 1 ] || ship_die 2 usage "usage: ship-log.sh <event> [k=v ...] | summary | mark <step>"
if [ "$1" = mark ]; then
  case "${2:-}" in pr-created|flipped|enqueued) ;; *) ship_die 2 usage "mark pr-created|flipped|enqueued" ;; esac
  ship_step_mark "$2" || ship_die 3 fingerprint-error "could not fingerprint the tree"
  ship_fixloop_log "$2"; echo "MARKED: $2"; ship_result ship-log PASS "mark=$2"; exit 0
fi
if [ "$1" = summary ]; then
  F="$SHIP_STATE/fixloop.tsv"
  if [ -s "$F" ]; then
    echo "FIXLOOP: $(wc -l < "$F" | tr -d ' ') events — $(cut -f2 "$F" | LC_ALL=C sort | uniq -c | awk '{printf "%s%s=%s", (NR>1?" ":""), $2, $1}')"
  else echo "FIXLOOP: 0 events"; fi
  ship_result ship-log PASS summary; exit 0
fi
ship_fixloop_log "$@"
ship_result ship-log PASS "event=$1" "ledger=${SHIP_FIXLOOP_LAST:-gap}"
exit 0
