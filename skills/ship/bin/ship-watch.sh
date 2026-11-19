#!/usr/bin/env bash
# ship-watch.sh — every bounded wait of the ship. Run each verb as a `run_in_background: true` Bash call whose harness
# timeout exceeds the bound; RE-ARM on TIMEOUT. A watch killed by the harness prints no VERDICT line: read that as
# UNVERIFIED, never as green. One sanctioned watcher, because hand-rolled polling loops shipped with three distinct defects
# in one afternoon on our side (no SHA gate, a jq default that read an empty rollup as green, dequeue blindness).
#
#   ci --pr N [--max-minutes 30] [--poll 120]
#       Watches the PR's checks at the head SHA it had when the watch started (SHA-gated). The REQUIRED set is read from
#       REQUIRED_CHECKS_CMD when set (one context per line; a failing command is WATCH_ERROR exit 3, never "any green"),
#       else REQUIRED_CHECKS (csv); when both are unset EVERY context in the rollup except IGNORED_CHECKS is required (fail
#       closed). Final `VERDICT:` line, one of:
#         CI_GREEN skipped=[...]      every required context present and SUCCESS/NEUTRAL/SKIPPED (named skips: confirm each is legitimately N/A)
#         CI_FAILED <names>           a required context FAILURE/ERROR/TIMED_OUT/ACTION_REQUIRED/CANCELLED/STARTUP_FAILURE on two consecutive reads
#                                     (the names are also written to ship-watched-failed for the census)
#         NO_CHECKS                   the rollup stayed empty (or held only ignored contexts) for 10 minutes
#         REQUIRED_MISSING <names>    a required context never appeared for 10 minutes AND no run from a PR event is active at the SHA
#                                     (a context that is merely late because its run is still active is TIMEOUT instead)
#         CONFLICTING                 mergeable flipped to CONFLICTING (two reads)
#         HEAD_MISMATCH <sha>         the remote head moved away from the watched SHA
#         CLOSED_UNMERGED | MERGED    terminal
#         TIMEOUT                     the bound expired with nothing decisive (exit 4 WAIT: re-arm)
#       Exit 0 the watch concluded (read the verdict; PASS means "concluded", not "green") · 4 TIMEOUT · 2 usage · 3 gh unreadable.
#   queue --pr N [--max-minutes 25] [--poll 180]
#       After the enqueue (or the direct merge call): MERGED · CONFLICTING · CLOSED_UNMERGED · HEAD_MISMATCH · LABEL_MISSING
#       (MERGE_METHOD=queue and QUEUE_LABEL vanished without a merge) · DEQUEUED / NEVER_QUEUED (QUEUE_STATE_CMD printed
#       `dequeued`, or never printed `queued` within 12 minutes of the start) · TIMEOUT. Same exits.
#   postmerge --sha <merge-sha> [--max-minutes 45] [--poll 120]
#       Watches the base branch's PUSH-event runs for the merge commit; GREEN needs at least one such run, a run count
#       stable across two polls, and every run concluded success/skipped/neutral. `POST_MERGE_RESULT=GREEN|FAILED|RUNNING|ERROR`;
#       exit 0 · 1 · 124 (re-arm) · 3. POSTMERGE_CI=none → exit 10 SKIP (say so in the report: no post-merge CI exists).
#   monitor [--pr N] [--max-minutes 55] [--poll 180] [--until-advance]
#       The live base-advance / conflict monitor beside the long waits. Exit 0 bound elapsed, no conflict (re-arm while the
#       guarded wait runs) · 13 the base branch advanced (`--local`, or any mode with --until-advance; prints `MONITOR_BASELINE=`;
#       OFFLOAD otherwise logs a `BASE_ADVANCED` line and keeps watching) · 11 CONFLICTING · 12 gh blind 3 polls in a row (auth?)
#       · 1 already-running · 3 fetch failed. `monitor --stop` stops a running one (0, or 10 if none).
# EXIT-CODES: 0 1 2 3 4 10 11 12 13 124
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-watch
command -v jq >/dev/null 2>&1 || ship_die 2 jq-missing "jq is required by ship-watch.sh"
command -v gh >/dev/null 2>&1 || ship_die 2 gh-missing "gh is required by ship-watch.sh"

VERB="${1:-}"; [ -n "$VERB" ] && shift
PR=""; SHA=""; MAXM=""; POLL=""; STOP=0; UNTIL_ADV=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) PR="${2:-}"; shift 2 ;; --sha) SHA="${2:-}"; shift 2 ;; --max-minutes) MAXM="${2:-}"; shift 2 ;; --poll) POLL="${2:-}"; shift 2 ;;
    --stop) STOP=1; shift ;; --until-advance) UNTIL_ADV=1; shift ;;
    *) ship_die 2 usage "unknown argument $1" ;;
  esac
done
num_ok() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }
[ -z "$MAXM" ] || num_ok "$MAXM" || ship_die 2 usage "--max-minutes needs a number"
[ -z "$POLL" ] || num_ok "$POLL" || ship_die 2 usage "--poll needs a number"

IGN=$(ship_cfg IGNORED_CHECKS "") || IGN=""
in_list() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }   # in_list <name> <csv> (exact, spaces allowed, no splitting)
csv_each() { local IFS=','; set -f; set -- $1; set +f; printf '%s\n' "$@"; }   # csv_each <csv> → one entry per line, spaces preserved, no globbing
verdict() { echo "VERDICT: $*"; ship_log "VERDICT: $*"; }

# required_set → REQ (csv). REQUIRED_CHECKS_CMD wins (live branch protection + queue conditions); a failing command is exit 3.
required_set() {
  local cmd f
  cmd=$(ship_cfg REQUIRED_CHECKS_CMD "") || cmd=""
  if [ -n "$cmd" ]; then
    f=$(ship_mktemp); PR="${PR:-}" bash -c "$cmd" > "$f" 2>>"$SHIP_LOG" || { rm -f "${f:?}"; verdict "WATCH_ERROR REQUIRED_CHECKS_CMD failed"; ship_result ship-watch FAIL required-set-unreadable; exit 3; }
    REQ=$(grep -v '^[[:space:]]*$' "$f" | paste -sd, -); rm -f "${f:?}"
    [ -n "$REQ" ] || { verdict "WATCH_ERROR REQUIRED_CHECKS_CMD printed nothing"; ship_result ship-watch FAIL required-set-unreadable; exit 3; }
  else REQ=$(ship_cfg REQUIRED_CHECKS "") || REQ=""; fi
}
pr_json() { gh pr view "$1" --json state,mergeable,headRefOid,isDraft,mergedAt,labels,statusCheckRollup 2>>"$SHIP_LOG"; }
rollup_rows() {  # "<name>\t<STATE>" per row; CheckRun and StatusContext normalized
  printf '%s' "$1" | jq -r '.statusCheckRollup[]? | if .__typename=="CheckRun" then ((.name // "UNNAMED") + "\t" + (if .status!="COMPLETED" then "PENDING" else (.conclusion // "PENDING") end)) else ((.context // "UNNAMED") + "\t" + (.state // "PENDING")) end'
}
active_pr_runs() {  # 0 when a non-completed run from a PR-side event exists at the SHA; 1 none; 2 unreadable
  local r
  r=$(gh run list --commit "$1" --json status,event --limit 50 2>>"$SHIP_LOG") || return 2
  [ "$(printf '%s' "$r" | jq -r '[.[] | select(.event=="pull_request" or .event=="pull_request_target" or .event=="merge_group" or .event=="push") | select(.status!="completed")] | length')" -gt 0 ]
}

case "$VERB" in
  ci|queue)
    num_ok "$PR" || PR=$(ship_pr_num) || ship_die 2 usage "$VERB needs --pr N (no open PR found for this branch)"
    [ -n "$MAXM" ] || { [ "$VERB" = ci ] && MAXM=30 || MAXM=25; }
    [ -n "$POLL" ] || { [ "$VERB" = ci ] && POLL=120 || POLL=180; }
    required_set
    J=$(pr_json "$PR") || ship_die 3 gh-unreadable "gh pr view $PR failed (gh auth status?)"
    WATCH_SHA=$(printf '%s' "$J" | jq -r .headRefOid); _ship_hex40 "$WATCH_SHA" || ship_die 3 gh-unreadable "no head SHA for PR $PR"
    # The census and --pre-push read these: a write that failed would leave them reading an older round's SHA.
    ship_write_atomic "$SHIP_STATE/ship-watched-sha" "$WATCH_SHA" || ship_die 3 state-unwritable "could not record ship-watched-sha"
    ship_write_atomic "$SHIP_STATE/ship-pr-number" "$PR" || ship_die 3 state-unwritable "could not record ship-pr-number"
    [ "$VERB" = ci ] && rm -f "${SHIP_STATE:?}/ship-ci-green-sha"   # a new watch: no green is recorded until this one sees it
    QLABEL=$(ship_cfg QUEUE_LABEL "") || QLABEL=""; MM=$(ship_cfg MERGE_METHOD direct); QSTATE=$(ship_cfg QUEUE_STATE_CMD "") || QSTATE=""
    START=$(date +%s); END=$(( START + MAXM*60 )); EMPTY_SINCE=""; MISSING_SINCE=""; FAIL_PREV=""; GREEN_PREV=""; CONF_PREV=0; BLIND=0; EVER_QUEUED=0
    echo "WATCH: $VERB pr=$PR sha=$WATCH_SHA bound=${MAXM}m poll=${POLL}s required=${REQ:-<all>}"
    while :; do
      J=$(pr_json "$PR")
      if [ $? -ne 0 ] || [ -z "$J" ]; then BLIND=$((BLIND+1)); [ "$BLIND" -ge 3 ] && { verdict "WATCH_ERROR gh unreadable 3 polls in a row"; ship_result ship-watch FAIL gh-unreadable; exit 3; }; sleep "$POLL"; continue; fi
      BLIND=0
      STATE=$(printf '%s' "$J" | jq -r .state); HEAD=$(printf '%s' "$J" | jq -r .headRefOid); MERG=$(printf '%s' "$J" | jq -r '.mergeable // "UNKNOWN"')
      [ "$STATE" = MERGED ] && { verdict "MERGED"; ship_step_mark merged >/dev/null 2>&1; ship_result ship-watch PASS verdict=MERGED; exit 0; }
      [ "$STATE" = CLOSED ] && { verdict "CLOSED_UNMERGED"; ship_result ship-watch PASS verdict=CLOSED_UNMERGED; exit 0; }
      [ "$HEAD" = "$WATCH_SHA" ] || { verdict "HEAD_MISMATCH $HEAD"; ship_result ship-watch PASS verdict=HEAD_MISMATCH; exit 0; }
      if [ "$MERG" = CONFLICTING ]; then CONF_PREV=$((CONF_PREV+1)); [ "$CONF_PREV" -ge 2 ] && { verdict "CONFLICTING"; ship_result ship-watch PASS verdict=CONFLICTING; exit 0; }; else CONF_PREV=0; fi
      NOW=$(date +%s)
      if [ "$VERB" = queue ]; then
        if [ "$MM" = queue ] && [ -n "$QLABEL" ]; then
          HAS=$(printf '%s' "$J" | jq -r --arg l "$QLABEL" '[.labels[]?.name] | index($l) != null')
          [ "$HAS" = true ] || { verdict "LABEL_MISSING $QLABEL"; ship_result ship-watch PASS verdict=LABEL_MISSING; exit 0; }
        fi
        if [ -n "$QSTATE" ]; then
          QSF=$(ship_mktemp); PR="$PR" bash -c "$QSTATE" > "$QSF" 2>>"$SHIP_LOG"; QRC=$?
          QS=$(tr -d '[:space:]' < "$QSF"); rm -f "${QSF:?}"
          [ "$QRC" -eq 0 ] || { verdict "WATCH_ERROR QUEUE_STATE_CMD exited $QRC"; ship_result ship-watch FAIL queue-state-unreadable; exit 3; }
          case "$QS" in
            queued) EVER_QUEUED=1 ;;
            dequeued) verdict "DEQUEUED"; ship_result ship-watch PASS verdict=DEQUEUED; exit 0 ;;
          esac
          if [ "$EVER_QUEUED" -eq 0 ] && [ $((NOW - START)) -ge 720 ]; then verdict "NEVER_QUEUED (no queued state in 12 min: nudge the queue to re-evaluate ONCE, then re-arm; never force-queue)"; ship_result ship-watch PASS verdict=NEVER_QUEUED; exit 0; fi
        fi
      else
        ROWS=$(rollup_rows "$J")
        if [ -z "$ROWS" ]; then
          [ -n "$EMPTY_SINCE" ] || EMPTY_SINCE=$NOW
          [ $((NOW - EMPTY_SINCE)) -ge 600 ] && { verdict "NO_CHECKS"; ship_result ship-watch PASS verdict=NO_CHECKS; exit 0; }
        else
          FAILED=""; PENDING=""; SKIPPED=""; SEEN=""; CONSIDERED=0
          while IFS="$(printf '\t')" read -r name st; do
            [ -n "$name" ] || continue
            in_list "$name" "$IGN" && continue
            if [ -n "$REQ" ] && ! in_list "$name" "$REQ"; then continue; fi
            SEEN="$SEEN,$name"; CONSIDERED=$((CONSIDERED+1))
            case "$st" in
              SUCCESS|NEUTRAL) ;;
              SKIPPED) SKIPPED="$SKIPPED,$name" ;;
              FAILURE|ERROR|TIMED_OUT|ACTION_REQUIRED|CANCELLED|STARTUP_FAILURE|STALE) FAILED="$FAILED,$name" ;;
              *) PENDING="$PENDING,$name" ;;
            esac
          done <<EOF_ROWS
$ROWS
EOF_ROWS
          MISSING=""
          if [ -n "$REQ" ]; then while IFS= read -r r; do [ -n "$r" ] || continue; in_list "$r" "$SEEN" || MISSING="$MISSING,$r"; done <<EOF_REQ
$(csv_each "$REQ")
EOF_REQ
          fi
          if [ "$CONSIDERED" -eq 0 ] && [ -z "$MISSING" ]; then
            [ -n "$EMPTY_SINCE" ] || EMPTY_SINCE=$NOW   # only ignored contexts registered: the empty-rollup bug in another spelling
            [ $((NOW - EMPTY_SINCE)) -ge 600 ] && { verdict "NO_CHECKS (only ignored contexts registered)"; ship_result ship-watch PASS verdict=NO_CHECKS; exit 0; }
          elif [ -n "$FAILED" ]; then
            EMPTY_SINCE=""
            if [ "$FAIL_PREV" = "$FAILED" ]; then
              ship_write_atomic "$SHIP_STATE/ship-watched-failed" "${FAILED#,}" || ship_die 3 state-unwritable "could not record ship-watched-failed"
              verdict "CI_FAILED ${FAILED#,}"; ship_result ship-watch PASS verdict=CI_FAILED; exit 0
            fi
            FAIL_PREV="$FAILED"
          else FAIL_PREV=""; EMPTY_SINCE=""
            if [ -n "$MISSING" ]; then
              [ -n "$MISSING_SINCE" ] || MISSING_SINCE=$NOW
              if [ $((NOW - MISSING_SINCE)) -ge 600 ]; then
                active_pr_runs "$WATCH_SHA"; ARC=$?
                case "$ARC" in
                  1) verdict "REQUIRED_MISSING ${MISSING#,}"; ship_result ship-watch PASS verdict=REQUIRED_MISSING; exit 0 ;;
                  0) echo "WATCH: required context(s) ${MISSING#,} absent but a PR-event run is still active: late, not dropped" ;;
                  *) echo "WATCH: run list unreadable; cannot tell late from dropped (re-arm once before investigating)" ;;
                esac
              fi
            elif [ -z "$PENDING" ]; then
              # green needs the SAME non-empty set on two consecutive polls: a context that registers late (external CI, a chained
              # workflow) must not be missed by a first-poll green
              if [ "$GREEN_PREV" = "$SEEN" ]; then
                rm -f "${SHIP_STATE:?}/ship-watched-failed"
                # The flip (ship-flip.sh) reads this: the green belongs to exactly this head SHA, never to a later push.
                ship_write_atomic "$SHIP_STATE/ship-ci-green-sha" "$WATCH_SHA" || ship_die 3 state-unwritable "could not record ship-ci-green-sha"
                verdict "CI_GREEN skipped=[${SKIPPED#,}]"; ship_step_mark ci-green >/dev/null 2>&1; ship_result ship-watch PASS verdict=CI_GREEN; exit 0
              fi
              GREEN_PREV="$SEEN"
            else GREEN_PREV=""
            fi
          fi
        fi
      fi
      [ "$(date +%s)" -lt "$END" ] || { verdict "TIMEOUT"; ship_result ship-watch WAIT timeout; exit 4; }
      sleep "$POLL"
    done ;;
  postmerge)
    [ "$(ship_cfg POSTMERGE_CI required)" = none ] && { echo "POST_MERGE_RESULT=NOT-CONFIGURED (POSTMERGE_CI=none: no CI runs on the base branch; say so in the report)"; ship_result ship-watch SKIP postmerge-ci-none; exit 10; }
    _ship_hex40 "$SHA" || ship_die 2 usage "postmerge needs --sha <40-hex merge commit>"
    [ -n "$MAXM" ] || MAXM=45; [ -n "$POLL" ] || POLL=120
    BASE=$(ship_base_branch); END=$(( $(date +%s) + MAXM*60 )); NONE_SINCE=""; PREV_N=-1
    while :; do
      R=$(gh run list --commit "$SHA" --branch "$BASE" --json databaseId,status,conclusion,name,event --limit 50 2>>"$SHIP_LOG") || { echo "POST_MERGE_RESULT=ERROR"; ship_result ship-watch FAIL gh-unreadable; exit 3; }
      NOW=$(date +%s)
      PUSH_N=$(printf '%s' "$R" | jq -r '[.[] | select(.event=="push")] | length')
      RUNNING=$(printf '%s' "$R" | jq -r '[.[] | select(.event=="push") | select(.status!="completed")] | length')
      RED=$(printf '%s' "$R" | jq -r '[.[] | select(.event=="push") | select(.status=="completed") | select(.conclusion!="success" and .conclusion!="skipped" and .conclusion!="neutral")] | map(.name + "(" + .conclusion + ")") | join(", ")')
      if [ "$PUSH_N" -eq 0 ]; then
        [ -n "$NONE_SINCE" ] || NONE_SINCE=$NOW
        [ $((NOW - NONE_SINCE)) -ge 900 ] && { echo "POST_MERGE_RESULT=ERROR no push-event runs for $SHA on $BASE in 15 min (set POSTMERGE_CI=none only if the base truly has no CI)"; ship_result ship-watch FAIL no-runs; exit 3; }
      else
        NONE_SINCE=""
        if [ -n "$RED" ]; then echo "POST_MERGE_RESULT=FAILED $RED"; ship_result ship-watch FAIL post-merge-red; exit 1; fi
        if [ "$RUNNING" -eq 0 ] && [ "$PREV_N" -eq "$PUSH_N" ]; then echo "POST_MERGE_RESULT=GREEN runs=$PUSH_N"; ship_step_mark postmerge-green >/dev/null 2>&1; ship_result ship-watch PASS post-merge-green; exit 0; fi
        PREV_N=$PUSH_N   # GREEN needs the same run count on two consecutive polls: a slow-registering workflow must not be missed
      fi
      [ "$NOW" -lt "$END" ] || { echo "POST_MERGE_RESULT=RUNNING"; ship_result ship-watch WAIT timeout; exit 124; }
      sleep "$POLL"
    done ;;
  monitor)
    PIDF="${SHIP_STATE:?}/ship-monitor.pid"
    if [ "$STOP" -eq 1 ]; then
      if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then kill "$(cat "$PIDF")" 2>/dev/null; rm -f "${PIDF:?}"; echo "MONITOR: stopped"; ship_result ship-watch PASS stopped; exit 0; fi
      rm -f "${PIDF:?}"; echo "MONITOR: nothing running"; ship_result ship-watch SKIP not-running; exit 10
    fi
    [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null && { echo "MONITOR: already running pid=$(cat "$PIDF")"; ship_result ship-watch FAIL already-running; exit 1; }
    echo $$ > "$PIDF"; trap 'rm -f "${PIDF:?}"' EXIT
    num_ok "$PR" || PR=$(ship_pr_num) || PR=""
    [ -n "$MAXM" ] || MAXM=55; [ -n "$POLL" ] || POLL=180
    ship_require_mode; MODE=$SHIP_MODE; BASE=$(ship_base_branch)
    git fetch origin "$BASE" >>"$SHIP_LOG" 2>&1 || ship_die 3 fetch-failed "git fetch origin $BASE failed"
    BASELINE=$(git rev-parse "origin/$BASE"); END=$(( $(date +%s) + MAXM*60 )); BLIND=0; CONF=0
    echo "MONITOR: pr=${PR:-none} base=$BASE baseline=$(printf '%.12s' "$BASELINE") bound=${MAXM}m"
    while [ "$(date +%s)" -lt "$END" ]; do
      sleep "$POLL"
      git fetch origin "$BASE" >>"$SHIP_LOG" 2>&1 || ship_die 3 fetch-failed "git fetch origin $BASE failed"
      TIP=$(git rev-parse "origin/$BASE")
      if [ "$TIP" != "$BASELINE" ]; then
        ship_fixloop_log base-advanced "from=$(printf '%.12s' "$BASELINE")" "to=$(printf '%.12s' "$TIP")"
        echo "BASE_ADVANCED $TIP (MONITOR_BASELINE=$TIP)"
        if [ "$MODE" = local ] || [ "$UNTIL_ADV" -eq 1 ]; then ship_result ship-watch FAIL base-advanced; exit 13; fi
        echo "MONITOR: OFFLOAD: the queue's speculative merge handles a clean advance; watching for CONFLICTING only"; BASELINE=$TIP
      fi
      if [ -n "$PR" ]; then
        M=$(gh pr view "$PR" --json mergeable --jq .mergeable 2>>"$SHIP_LOG")
        if [ $? -ne 0 ] || [ -z "$M" ]; then BLIND=$((BLIND+1)); [ "$BLIND" -ge 3 ] && { echo "MONITOR: gh blind 3 polls in a row"; ship_result ship-watch FAIL gh-blind; exit 12; }; continue; fi
        BLIND=0
        if [ "$M" = CONFLICTING ]; then CONF=$((CONF+1)); [ "$CONF" -ge 2 ] && { echo "MONITOR: PR $PR is CONFLICTING"; ship_result ship-watch FAIL conflicting; exit 11; }; else CONF=0; fi
      fi
    done
    if [ -z "$PR" ]; then echo "MONITOR: bound elapsed; conflict detection was OFF (no PR): this is not a 'no conflict' reading"; ship_result ship-watch PASS bound-elapsed-no-pr; exit 0; fi
    echo "MONITOR: bound elapsed, no conflict"; ship_result ship-watch PASS bound-elapsed; exit 0 ;;
  *) ship_die 2 usage "usage: ship-watch.sh ci|queue --pr N | postmerge --sha S | monitor [--pr N] [--until-advance] [--stop]  [--max-minutes M] [--poll S]" ;;
esac
