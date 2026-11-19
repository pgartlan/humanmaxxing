#!/usr/bin/env bash
# ship-sentinel.sh — the sentinel contract's reader (review-code writes), the Phase-1 sentinel (this skill's own),
# and the fingerprint CLI other skills may call.
#
#   fingerprint [--critical|--raw]        print the 64-hex REVIEW fingerprint (all changed paths minus DOCS_ALLOWLIST, plus
#                                         DOCS_KEEP_BOUND: the contract's line-1 value; review-code may call this instead of
#                                         re-implementing); --critical only CRITICAL_GLOBS matches; --raw every path, no exclusion.
#                                         Exit 0 · 3 on SENTINEL-ERROR.
#   fingerprint --phase1                  ship-internal: print the CHECK binding (ship_fp_phase1: the tree id of the working
#                                         tree's content, 40 or 64 hex). Other skills never need it. Exit 0 · 3.
#   attest review|e2e --note "<text>" --user "<the user's words>"
#                                         REVIEW_GATE=manual only: record the USER's in-session attestation ($SHIP_STATE/manual-<kind>),
#                                         review bound to the tree fingerprint, e2e to the critical-path one. The agent never
#                                         attests its own work: --user is mandatory. Exit 0 · 2 (not manual, no note, no --user) · 3.
#   test-guard -- <TEST_GLOBS pathspecs>  the Step 1c test-update guard: exit 0 no critical change or a test file touched (tracked
#                                         or untracked) · 1 critical change, no test touched · 3 categorize could not compute.
#   categorize                            `NONEXEMPT <path>` per changed path matching CRITICAL_GLOBS, `EXEMPT-COUNT <n>`.
#                                         Exit 0 at least one non-exempt path · 10 none (E2E-exempt diff) · 3 unreadable.
#   verify review                         review-code-ran is valid for THIS tree (hash AND TTL). Exit 0 · 1 invalid · 3 reader error.
#   verify e2e                            real-e2e-shipgate-passed is valid for this tree's critical paths (or a bound EXEMPT). Same codes.
#   verify gates                          both, in one call (the pre-merge re-gate). Exit 0 both valid · 1 · 3.
#   write phase1                          record "the Phase-1 checks passed on this tree": refuses (exit 1) unless EVERY task
#                                         ship-run.sh recorded in $SHIP_STATE/tasks.list says rc=0 (the list is written at
#                                         launch, never typed at verification: a forgotten name cannot unrequire a task);
#                                         writes $SHIP_STATE/ship-phase1-passed (<check binding> / <HEAD> / <epoch>). Exit 0 · 1 · 3.
#   verify phase1 [--committed]           the Phase-1 sentinel matches the current check binding; with --committed also requires
#                                         no tracked uncommitted change and no RELEVANT untracked file (the push precondition).
#                                         Exit 0 · 1 moved/absent/untracked-relevant · 3.
#   untracked                             `RELEVANT<TAB><path>` / `IGNORED<TAB><path>` for every untracked, not-ignored file
#                                         (ship_untracked_relevant: RELEVANT = near a change of this branch). Exit 0 · 3
#                                         (`merge-base-unresolved`: fetch the base branch; `untracked-unreadable`).
#   invalidate phase1                     delete it (after a conflict resolution; the tree is new).
# EXIT-CODES: 0 1 2 3 10
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-sentinel

VERB="${1:-}"; [ -n "$VERB" ] && shift
BASE_REF=$(ship_base_ref)
P1="${SHIP_STATE:?}/ship-phase1-passed"

fp_phase1() { ship_fp_phase1; }
fp_critical() { local inc fp rc; inc=$(ship_critical_ere_file) || return 1; fp=$(ship_fingerprint "$BASE_REF" "$inc"); rc=$?; rm -f "${inc:?}"; printf '%s\n' "$fp"; return $rc; }

case "$VERB" in
  fingerprint)
    case "${1:-}" in
      --critical) FP=$(fp_critical); RC=$? ;;
      --raw) FP=$(ship_fingerprint "$BASE_REF"); RC=$? ;;
      --phase1) FP=$(fp_phase1); RC=$? ;;
      '') FP=$(ship_fp_tree); RC=$? ;;
      *) ship_die 2 usage "fingerprint [--critical|--raw|--phase1]" ;;
    esac
    [ "$RC" -eq 0 ] || { echo "$FP"; ship_result ship-sentinel FAIL fingerprint-error; exit 3; }
    echo "$FP"; ship_result ship-sentinel PASS fingerprint; exit 0 ;;
  untracked)
    ship_merge_base >/dev/null || ship_die 3 merge-base-unresolved "git merge-base HEAD $BASE_REF failed: fetch the base branch, then re-run"
    OUT=$(ship_untracked_relevant); RC=$?
    [ "$RC" -eq 0 ] || { echo "$OUT"; ship_result ship-sentinel FAIL untracked-unreadable; exit 3; }
    [ -z "$OUT" ] || printf '%s\n' "$OUT"
    NR=$(printf '%s\n' "$OUT" | grep -c '^RELEVANT')
    NI=$(printf '%s\n' "$OUT" | grep -c '^IGNORED')
    ship_result ship-sentinel PASS untracked "relevant=$NR" "ignored=$NI"; exit 0 ;;
  categorize)
    MB=$(ship_merge_base) || ship_die 3 merge-base-unresolved "git merge-base HEAD $BASE_REF failed: fetch the base branch"
    INC=$(ship_critical_ere_file) || ship_die 3 filter-unbuildable "cannot build the critical-path filter (CRITICAL_GLOBS_FILE is unreadable, or holds a glob spelling named above)"
    LIST=$(ship_mktemp)
    git -c core.quotePath=false diff --name-status --no-renames "$MB" > "$LIST.raw" || { rm -f "${LIST:?}" "${LIST:?}.raw" "${INC:?}"; ship_die 3 diff-unreadable "git diff failed"; }
    git -c core.quotePath=false ls-files --others --exclude-standard > "$LIST.u" || { rm -f "${LIST:?}" "${LIST:?}.raw" "${LIST:?}.u" "${INC:?}"; ship_die 3 diff-unreadable "git ls-files failed"; }
    # Same record shape as ship_fingerprint: an untracked file is an add; a literal tab (BSD sed has no \t).
    sed "s/^/A$(printf '\t')/" "$LIST.u" >> "$LIST.raw" || { rm -f "${LIST:?}" "${LIST:?}.raw" "${LIST:?}.u" "${INC:?}"; ship_die 3 diff-unreadable "could not append the untracked list"; }
    rm -f "${LIST:?}.u"
    LC_ALL=C sort -u "$LIST.raw" > "$LIST"; rm -f "${LIST:?}.raw"
    TOTAL=$(wc -l < "$LIST" | tr -d ' ')
    if [ -s "$INC" ]; then grep -E -f "$INC" "$LIST" > "$LIST.f"; RC=$?; [ "$RC" -le 1 ] || { rm -f "${LIST:?}" "${LIST:?}.f" "${INC:?}"; ship_die 3 filter-invalid "the critical-path regex is invalid (grep rc=$RC)"; }; else : > "$LIST.f"; fi
    N=$(wc -l < "$LIST.f" | tr -d ' ')
    cut -f2 "$LIST.f" | sed 's/^/NONEXEMPT /'
    echo "EXEMPT-COUNT $((TOTAL - N))"
    [ -s "$INC" ] || echo "NOTE: CRITICAL_GLOBS_FILE is unset or empty: every diff is E2E-exempt. Say so in the PR body."
    rm -f "${LIST:?}" "${LIST:?}.f" "${INC:?}"
    if [ "$N" -gt 0 ]; then ship_result ship-sentinel PASS nonexempt "n=$N"; exit 0; fi
    ship_result ship-sentinel SKIP all-exempt "changed=$TOTAL"; exit 10 ;;
  verify)
    case "${1:-}" in
      review) OUT=$(ship_verify_review); RC=$?; echo "$OUT"
        case "$RC" in 0) ship_result ship-sentinel PASS review-fresh; exit 0 ;; 3) ship_result ship-sentinel FAIL reader-error; exit 3 ;; *) ship_result ship-sentinel FAIL review-invalid; exit 1 ;; esac ;;
      e2e) OUT=$(ship_verify_e2e); RC=$?; echo "$OUT"
        case "$RC" in 0) ship_result ship-sentinel PASS e2e-valid; exit 0 ;; 3) ship_result ship-sentinel FAIL reader-error; exit 3 ;; *) ship_result ship-sentinel FAIL e2e-invalid; exit 1 ;; esac ;;
      gates) O1=$(ship_verify_review); R1=$?; O2=$(ship_verify_e2e); R2=$?; echo "$O1"; echo "$O2"
        if [ "$R1" -eq 3 ] || [ "$R2" -eq 3 ]; then ship_result ship-sentinel FAIL reader-error; exit 3; fi
        if [ "$R1" -eq 0 ] && [ "$R2" -eq 0 ]; then ship_result ship-sentinel PASS gates-valid; exit 0; fi
        ship_result ship-sentinel FAIL gate-invalid "review=$R1" "e2e=$R2"; exit 1 ;;
      phase1)
        COMMITTED=0; [ "${2:-}" = "--committed" ] && COMMITTED=1
        [ -f "$P1" ] || { echo "PHASE1: ABSENT"; ship_result ship-sentinel FAIL phase1-absent; exit 1; }
        L1=$(sed -n 1p "$P1" | tr -d '[:space:]'); _ship_hex_tree "$L1" || _ship_hex64 "$L1" || { echo "PHASE1: MALFORMED"; ship_result ship-sentinel FAIL phase1-malformed; exit 1; }
        FP=$(fp_phase1) || { echo "$FP"; ship_result ship-sentinel FAIL reader-error; exit 3; }
        if [ "$FP" != "$L1" ]; then
          if [ "${#FP}" -ne "${#L1}" ]; then echo "PHASE1: TREE-MOVED binding format changed (written by an older ship): re-run the 1c tasks, then write phase1 again"
          else echo "PHASE1: TREE-MOVED the checked tree is not this tree (an edit, or the base moved: re-run the 1c tasks, then write phase1 again)"; fi
          ship_result ship-sentinel FAIL phase1-tree-moved; exit 1
        fi
        if [ "$COMMITTED" -eq 1 ]; then
          D=$(git status --porcelain --untracked-files=no 2>/dev/null) || { ship_result ship-sentinel FAIL reader-error; exit 3; }
          [ -z "$D" ] || { echo "PHASE1: TREE-NOT-COMMITTED tracked changes are not in the commit:"; echo "$D" | head -20; ship_result ship-sentinel FAIL tree-not-committed; exit 1; }
          ship_merge_base >/dev/null || ship_die 3 merge-base-unresolved "git merge-base HEAD $BASE_REF failed: fetch the base branch, then re-run"
          U=$(ship_untracked_relevant) || { echo "$U"; ship_result ship-sentinel FAIL untracked-unreadable; exit 3; }
          R=$(printf '%s\n' "$U" | sed -n "s/^RELEVANT$(printf '\t')//p")
          [ -z "$R" ] || { echo "PHASE1: UNTRACKED-RELEVANT untracked files near this branch's changes (commit the ones that belong; delete the rest or move them out of the checkout, which moves the binding: re-run 1c):"; printf '%s\n' "$R" | head -20; ship_result ship-sentinel FAIL untracked-relevant; exit 1; }
          I=$(printf '%s\n' "$U" | sed -n "s/^IGNORED$(printf '\t')//p")
          [ -z "$I" ] || { echo "NOTE untracked, not near this branch's changes (not in the PR; any untracked change still moves the binding):"; printf '%s\n' "$I" | head -20; }
        fi
        echo "PHASE1: OK"; ship_result ship-sentinel PASS phase1-ok; exit 0 ;;
      *) ship_die 2 usage "verify review|e2e|gates|phase1 [--committed]" ;;
    esac ;;
  attest)
    KIND="${1:-}"; case "$KIND" in review|e2e) ;; *) ship_die 2 usage "attest review|e2e --note \"<what was verified, when, against which commit>\" --user \"<the user's words, verbatim>\"" ;; esac
    shift
    [ "$(ship_cfg REVIEW_GATE sentinel)" = manual ] || ship_die 2 not-manual "REVIEW_GATE is sentinel: the review-code skill writes the sentinels; an attestation is not accepted"
    NOTE=""; USERW=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --note) NOTE="${2:-}"; shift 2 ;;
        --user) USERW="${2:-}"; shift 2 ;;
        *) ship_die 2 usage "attest $KIND: unknown argument $1" ;;
      esac
    done
    [ -n "$NOTE" ] || ship_die 2 usage "attest $KIND --note \"<text>\" (the note is mandatory and goes in the PR body)"
    # The user's confirmation, typed in this session, is what makes it an attestation: the shipping agent never attests
    # its own review or its own E2E run (that is the self-override both gates exist to prevent; only the user waives them).
    [ -n "$(printf '%s' "$USERW" | tr -d '[:space:]')" ] || ship_die 2 no-user-confirmation "attest $KIND needs --user \"<the user's words, verbatim>\": ask the user (class waiver); the agent's own claim is not an attestation"
    FP=$(_ship_manual_fp "$KIND") || { echo "$FP"; ship_result ship-sentinel FAIL reader-error; exit 3; }
    ship_write_atomic "$SHIP_STATE/manual-$KIND" "$FP" "$(date +%s)" "$(printf '%s' "$NOTE" | tr '\n' ' ')" "$(printf '%s' "$USERW" | tr '\n' ' ')" || ship_die 2 write-failed "could not write manual-$KIND"
    ship_fixloop_log auto-decision "class=${KIND}-manual" "note=$(printf '%.80s' "$NOTE")" "user=$(printf '%.80s' "$USERW")"
    echo "ATTESTED: $KIND for $(printf '%.12s' "$FP") — the PR body must say 'manual attestation' and quote the user's words, never FRESH"
    ship_result ship-sentinel PASS attested "kind=$KIND"; exit 0 ;;
  test-guard)
    # The test-update guard (BLOCKING, Step 1c): a critical-path product change with no test file touched HALTs. It keeps
    # categorize's exit code: an unreadable diff, merge-base or globs file is exit 3, never "nothing critical changed".
    [ "${1:-}" = -- ] && shift
    [ "$#" -gt 0 ] || ship_die 2 usage "test-guard -- <TEST_GLOBS as git pathspecs, at least one>"
    COUT=$(bash "$SHIP_BIN/ship-sentinel.sh" categorize 2>&1); CRC=$?
    case "$CRC" in
      10) echo "TEST-GUARD: PASS no critical path changed"; ship_result ship-sentinel PASS test-guard-no-critical; exit 0 ;;
      0) ;;
      *) printf '%s\n' "$COUT" | grep -v '^SHIP-RESULT' | tail -5; echo "TEST-GUARD: HALT the critical-path set could not be computed (categorize exit $CRC): never read as clean"; ship_result ship-sentinel FAIL test-guard-unreadable "categorize=$CRC"; exit 3 ;;
    esac
    MB=$(ship_merge_base) || ship_die 3 merge-base-unresolved "git merge-base HEAD $BASE_REF failed: fetch the base branch"
    # Tracked (committed, staged, unstaged; a deleted test counts as touched) plus untracked-not-ignored: at Step 1c nothing
    # is committed yet, so a new test file is untracked.
    TT=$(git -c core.quotePath=false diff --name-only --no-renames "$MB" -- "$@") || ship_die 3 diff-unreadable "git diff over the test globs failed"
    TU=$(git -c core.quotePath=false ls-files --others --exclude-standard -- "$@") || ship_die 3 diff-unreadable "git ls-files over the test globs failed"
    NT=$(printf '%s\n%s\n' "$TT" "$TU" | grep -c .)
    NC=$(printf '%s\n' "$COUT" | grep -c '^NONEXEMPT ')
    if [ "$NT" -eq 0 ]; then
      printf '%s\n' "$COUT" | grep '^NONEXEMPT ' | head -20
      echo "TEST-GUARD: HALT critical-path product code changed ($NC file(s)) and no test file was touched: add or update the covering tests"
      ship_result ship-sentinel FAIL critical-without-tests "critical=$NC" tests=0; exit 1
    fi
    echo "TEST-GUARD: PASS critical=$NC tests-touched=$NT"; ship_result ship-sentinel PASS test-guard "critical=$NC" "tests=$NT"; exit 0 ;;
  write)
    [ "${1:-}" = phase1 ] || ship_die 2 usage "write phase1"
    [ "$#" -eq 1 ] || ship_die 2 usage "write phase1 takes no task list: every task recorded in tasks.list at launch is required"
    TL="$SHIP_STATE/tasks.list"
    # The required list is CONFIGURATION (CHECK_TASKS for this mode), never only what happened to be launched: a required
    # task that never ran joins the list here, so collect reports it pending and nothing is written.
    ship_require_mode
    REQ=$(ship_required_tasks "$SHIP_MODE")
    if [ -n "$REQ" ]; then
      for r in $REQ; do grep -qx "$r" "$TL" 2>/dev/null || echo "$r" >> "$TL" || ship_die 2 write-failed "could not record required task $r"; done
    else
      echo "NOTE required-tasks=launched (CHECK_TASKS is unset: the required list is what was launched; say so in the PR body)"
    fi
    [ -s "$TL" ] || { echo "PHASE1: REFUSED no task was ever launched through ship-run.sh (tasks.list empty)"; ship_result ship-sentinel FAIL no-tasks; exit 1; }
    OUT=$(bash "$SHIP_BIN/ship-run.sh" collect --same-tree 2>&1); RC=$?
    # Stamp exactly the binding collect checked every task against, and only while the tree still has it: an edit between
    # the two would otherwise bind the sentinel to a tree no task ran on.
    CB=$(printf '%s\n' "$OUT" | sed -n 's/^collect: binding //p' | tail -1)
    case "$RC" in
      0) ;;
      1|4) echo "$OUT" | grep -E '^collect:'; echo "PHASE1: REFUSED a recorded task is red, has no result, or ran on another tree; nothing written"; ship_result ship-sentinel FAIL tasks-not-green; exit 1 ;;
      *) echo "$OUT" | tail -5; ship_result ship-sentinel FAIL reader-error; exit 3 ;;
    esac
    _ship_hex_tree "$CB" || { echo "$OUT" | tail -5; echo "PHASE1: REFUSED collect reported no binding"; ship_result ship-sentinel FAIL reader-error; exit 3; }
    FP=$(fp_phase1) || { echo "$FP"; ship_result ship-sentinel FAIL reader-error; exit 3; }
    [ "$FP" = "$CB" ] || { echo "PHASE1: REFUSED the tree changed while the tasks were being checked; re-run the 1c tasks"; ship_result ship-sentinel FAIL tasks-not-green; exit 1; }
    ship_write_atomic "$P1" "$FP" "$(git rev-parse HEAD)" "$(date +%s)" || ship_die 2 write-failed "could not write $P1"
    ship_step_mark phase1 >/dev/null 2>&1 || true
    ship_fixloop_log phase1 "fp=$(printf '%.12s' "$FP")"
    echo "PHASE1: WRITTEN $(printf '%.12s' "$FP") (check binding: the whole working tree minus DOCS_ALLOWLIST paths)"; ship_result ship-sentinel PASS phase1-written; exit 0 ;;
  invalidate)
    [ "${1:-}" = phase1 ] || ship_die 2 usage "invalidate phase1"
    rm -f "${P1:?}" "${SHIP_STATE:?}/step-phase1"; echo "PHASE1: INVALIDATED"; ship_result ship-sentinel PASS phase1-invalidated; exit 0 ;;
  *) ship_die 2 usage "usage: ship-sentinel.sh fingerprint [--critical|--raw|--phase1] | untracked | categorize | verify review|e2e|gates|phase1 | attest review|e2e --note … --user … | test-guard -- <pathspecs> | write phase1 | invalidate phase1" ;;
esac
