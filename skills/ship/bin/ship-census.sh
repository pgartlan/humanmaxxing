#!/usr/bin/env bash
# ship-census.sh — the failure census (Step 4.5 3a) and the fix-round gate (3c).
#
#   ship-census.sh --contract=N [--sha <sha>]
#       EVERY workflow run at the watched SHA (default: ship-watched-sha), EVERY job concluded failure / timed_out /
#       action_required / cancelled / startup_failure (the same set ship-watch.sh reads as CI_FAILED), BEFORE a single file is touched. Each failed job's FULL log is fetched through the jobs API
#       (never `gh run view --log-failed`, which silently drops everything after one over-long line) into
#       $SHIP_STATE/logs/job-<id>.log, and one block is written to $SHIP_STATE/ship-census.txt:
#         === FAILED JOB: <job name>  (run <id>, job <id>) → <log path>
#         required=yes|no|unknown   work=1|0   signature=<first failing line, normalized>
#         <up to 20 excerpt lines: the failing lines if recognizable, else the tail>
#       `required=yes` when the job or its workflow name is in REQUIRED_CHECKS; `no` when REQUIRED_CHECKS is set and it is
#       not; `unknown` (counted as WORK, fail closed) when REQUIRED_CHECKS is unset. Only WORK blocks (work=1) trigger a
#       fix round; work=0 blocks are REPORTED in the PR body, never ignored. The previous census is kept as
#       ship-census-prev.txt so a later run can tell NEW signatures from known ones (`--pre-push`).
#       Prints `FAILED_JOBS=N work=W reported=R`. Exit 0 census built · 1 `census-empty` (the watch said failed but no red
#       job was found: SHA mismatch; push nothing, re-run the watch) · 3 a gh read failed (INCOMPLETE: never push on it).
#   ship-census.sh --contract=N --pre-push [--wait]
#       Immediately before a fix push: re-census silently and compare signatures with the baseline. Exit 0 nothing new ·
#       5 NEW-REQUIRED-RED (a WORK signature not in the baseline appeared: re-run the census, fix it too, do not push yet) ·
#       4 WAIT: a required job is still running at the SHA (a push cancels it and its finding arrives a round late) · 3.
#       --wait polls every 120 s up to 20 minutes (run it in the background and keep fixing); on expiry exit 6
#       `pre-push-wait-expired`: push anyway and record `pushed-before-<run>` in the ledger and the PR body.
#       The watcher's CI_FAILED context names (ship-watched-failed) are the required-red ground truth: a red context no failed
#       job explains (a status posted by a reporter job) makes EVERY failed job WORK (`UNMAPPED_REQUIRED=`), and `census-empty`
#       is only valid when no such context is recorded.
#   ship-census.sh --contract=N --round-gate [--extend]
#       The OFFLOAD fix-round cap (FIX_ROUND_CAP, worked default 10). Exit 0 push now (`fix-round N`; the counter is written;
#       at the last allowed round a TELL_USER: line is printed) · 1 HALT: this would exceed the allowance — STOP AND ASK THE
#       USER (continue another 10 rounds, switch to --local, or stop); never decide it yourself · 2 `--extend` while still
#       within the allowance · 3 counter unreadable or corrupt (never guess: a bad count would bypass the cap).
#       `--extend` records an explicit "continue" answer: allowance += 10, then runs this round.
#   ship-census.sh --contract=N --rerun --run <id>
#       `gh run rerun --failed <id>`, at most ONCE per run id per ship (recorded in ship-ci-reruns). Only when every WORK
#       block is a FLAKE (your judgment, recorded in the PR body). Exit 0 fired · 1 already-rerun · 3 gh failed.
# EXIT-CODES: 0 1 2 3 4 5 6
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-census
command -v jq >/dev/null 2>&1 || ship_die 2 jq-missing "jq is required"
CENSUS="${SHIP_STATE:?}/ship-census.txt"; PREV="$SHIP_STATE/ship-census-prev.txt"; ROUNDS="$SHIP_STATE/ship-fix-rounds"; RERUNS="$SHIP_STATE/ship-ci-reruns"
REQ=$(ship_cfg REQUIRED_CHECKS "") || REQ=""
RCMD=$(ship_cfg REQUIRED_CHECKS_CMD "") || RCMD=""
if [ -n "$RCMD" ]; then
  _rf=$(ship_mktemp); PR="$(sed -n 1p "$SHIP_STATE/ship-pr-number" 2>/dev/null)" bash -c "$RCMD" > "$_rf" 2>>"$SHIP_LOG" || { rm -f "${_rf:?}"; ship_die 3 required-set-unreadable "REQUIRED_CHECKS_CMD failed; the required set is unknown (never 'any red')"; }
  REQ=$(grep -v '^[[:space:]]*$' "$_rf" | paste -sd, -); rm -f "${_rf:?}"
fi
in_list() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }   # exact csv membership; names with spaces are fine
FAILED_CONCLUSIONS='failure|timed_out|action_required|cancelled|startup_failure'   # the same set ship-watch.sh reads as CI_FAILED

MODE_V=census; SHA=""; EXTEND=0; RUN_ID=""; WAIT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sha) SHA="${2:-}"; shift 2 ;; --pre-push) MODE_V=prepush; shift ;; --wait) WAIT=1; shift ;; --round-gate) MODE_V=gate; shift ;; --extend) EXTEND=1; shift ;;
    --rerun) MODE_V=rerun; shift ;; --run) RUN_ID="${2:-}"; shift 2 ;;
    *) ship_die 2 usage "unknown argument $1" ;;
  esac
done

# GH_REPO (exported from ship.env by ship_lib_init) wins: `gh repo view` with no argument ignores it and reads the remotes.
repo_slug() { if [ -n "${GH_REPO:-}" ]; then printf '%s\n' "$GH_REPO"; else gh repo view --json nameWithOwner --jq .nameWithOwner 2>>"$SHIP_LOG"; fi; }

build_census() {  # $1 = sha, $2 = output file; prints FAILED_JOBS line; returns 0 built, 1 empty, 3 unreadable. Also sets RUNNING_REQUIRED.
  local sha="$1" out="$2" runs n rid rname rjobs jid jname jconc slug log req work sig excerpt tmp
  slug=$(repo_slug) || return 3
  runs=$(gh run list --commit "$sha" --json databaseId,name,status,conclusion,event --limit 100 2>>"$SHIP_LOG") || return 3
  : > "$out"; rm -f "${out:?}.count" "${out:?}.rc"; n=0; RUNNING_REQUIRED=""
  local jtmp; tmp=$(ship_mktemp); jtmp=$(ship_mktemp)
  printf '%s' "$runs" | jq -r '.[] | [.databaseId, .status, (.conclusion // ""), .name] | @tsv' > "$tmp" || { rm -f "${tmp:?}" "${jtmp:?}"; return 3; }
  FAILED_CTX=$(sed -n 1p "$SHIP_STATE/ship-watched-failed" 2>/dev/null)
  EXPLAINED=""
  while IFS="$(printf '\t')" read -r rid rstatus rconc rname; do
    [ -n "$rid" ] || continue
    rjobs=$(gh run view "$rid" --json jobs 2>>"$SHIP_LOG") || { rm -f "${tmp:?}" "${jtmp:?}"; return 3; }
    if [ "$rstatus" = completed ] && printf '%s' "$rconc" | grep -qE "^($FAILED_CONCLUSIONS)\$" && [ "$(printf '%s' "$rjobs" | jq -r --arg re "^($FAILED_CONCLUSIONS)\$" '[.jobs[] | select((.conclusion // "") | test($re))] | length')" = 0 ]; then
      # the RUN failed with no failed job (startup_failure, cancelled before jobs ran): a run-level block, so CI_FAILED never meets an empty census
      if [ -z "$REQ" ]; then req=unknown; elif in_list "$rname" "$REQ"; then req=yes; else req=no; fi
      [ "$req" = no ] && work=0 || work=1
      { echo "=== FAILED RUN: $rname  (run $rid, no jobs, $rconc)"; echo "required=$req   work=$work   workflow=$rname   signature=run-level $rconc"; echo "no job ran: a startup failure or a cancellation before any job started; read the run page, re-run once if infra, else fix the workflow"; echo; } >> "$out"
      echo "run-$rid" >> "$out.count"; EXPLAINED="$EXPLAINED,$rname"
      continue
    fi
    if [ "$rstatus" != completed ]; then
      # an in-progress run blocks the pre-push when REQUIRED_CHECKS is unset, or when its workflow OR any of its jobs is required
      if [ -z "$REQ" ] || in_list "$rname" "$REQ"; then RUNNING_REQUIRED="$RUNNING_REQUIRED,$rname"
      else
        printf '%s' "$rjobs" | jq -r '.jobs[].name' > "$jtmp" || { rm -f "${tmp:?}" "${jtmp:?}"; return 3; }
        while IFS= read -r jn; do [ -n "$jn" ] && in_list "$jn" "$REQ" && { RUNNING_REQUIRED="$RUNNING_REQUIRED,$rname/$jn"; break; }; done < "$jtmp"
      fi
      continue
    fi
    printf '%s' "$rjobs" | jq -r --arg re "^($FAILED_CONCLUSIONS)\$" '.jobs[] | select((.conclusion // "") | test($re)) | [.databaseId, .conclusion, .name] | @tsv' > "$jtmp" || { rm -f "${tmp:?}" "${jtmp:?}"; return 3; }
    while IFS="$(printf '\t')" read -r jid jconc jname; do
      [ -n "$jid" ] || continue
      log="$SHIP_STATE/logs/job-$jid.log"
      gh api "repos/$slug/actions/jobs/$jid/logs" > "$log" 2>>"$SHIP_LOG" || { echo "job $jid ($jname) log fetch failed: the census is INCOMPLETE"; echo 3 > "$out.rc"; break; }
      if [ -z "$REQ" ]; then req=unknown; elif in_list "$jname" "$REQ" || in_list "$rname" "$REQ"; then req=yes; else req=no; fi
      [ "$req" = no ] && work=0 || work=1
      # excerpt: strip the ISO timestamp prefix; prefer lines that look like failures; cap the width (a dot-reporter line can be 500 KB)
      excerpt=$(sed -E 's/^[0-9T:.Z-]{20,32} ?//' "$log" | cut -c1-400 | grep -nE '(^|[^a-zA-Z])(FAIL|FAILED|Error|error:|ERR!|✗|✖|AssertionError|Exception|exit code [1-9]|Process completed with exit code)' | head -20)
      [ -n "$excerpt" ] || excerpt=$(sed -E 's/^[0-9T:.Z-]{20,32} ?//' "$log" | cut -c1-400 | tail -20)
      sig=$(printf '%s\n' "$excerpt" | head -1 | sed -E 's/^[0-9]+://; s/[0-9]+/N/g; s/[[:space:]]+/ /g' | cut -c1-160)
      EXPLAINED="$EXPLAINED,$jname,$rname"
      {
        echo "=== FAILED JOB: $jname  (run $rid, job $jid, $jconc) → $log"
        echo "required=$req   work=$work   workflow=$rname   signature=$sig"
        printf '%s\n' "$excerpt"
        echo
      } >> "$out"
      echo "$jid" >> "$out.count"
    done < "$jtmp"
    [ -f "$out.rc" ] && { rm -f "${tmp:?}" "${jtmp:?}" "${out:?}.rc" "${out:?}.count"; return 3; }
  done < "$tmp"
  rm -f "${tmp:?}" "${jtmp:?}"
  n=0; [ -f "$out.count" ] && n=$(wc -l < "$out.count" | tr -d ' '); rm -f "${out:?}.count"
  UNMAPPED=""
  if [ -n "$FAILED_CTX" ]; then
    while IFS= read -r c; do [ -n "$c" ] || continue; in_list "$c" "$EXPLAINED" || UNMAPPED="$UNMAPPED,$c"; done <<EOF_CTX
$(printf '%s' "$FAILED_CTX" | tr ',' '\n')
EOF_CTX
  fi
  if [ -n "$UNMAPPED" ]; then
    echo "UNMAPPED_REQUIRED=${UNMAPPED#,}  (a red required context no failed job carries: every block below is WORK until it is explained)"
    sed -i.bak 's/^required=no   work=0/required=unmapped   work=1/' "$out" 2>/dev/null && rm -f "${out:?}.bak"
  fi
  W=$(grep -c '^required=.*work=1' "$out" 2>/dev/null); [ -n "$W" ] || W=0; R=$(grep -c '^required=.*work=0' "$out" 2>/dev/null); [ -n "$R" ] || R=0
  echo "FAILED_JOBS=$n work=$W reported=$R running_required=${RUNNING_REQUIRED#,}"
  [ "$n" -gt 0 ] || return 1
  return 0
}
signatures() { grep -E '^required=.*work=1' "$1" 2>/dev/null | sed 's/.*signature=//' | LC_ALL=C sort -u; }

case "$MODE_V" in
  census)
    [ -n "$SHA" ] || SHA=$(sed -n 1p "$SHIP_STATE/ship-watched-sha" 2>/dev/null | tr -d '[:space:]')
    _ship_hex40 "$SHA" || ship_die 1 no-watched-sha "no full 40-hex SHA: run the CI watch first (or pass --sha)"
    NEWC=$(ship_mktemp)
    build_census "$SHA" "$NEWC"; RC=$?
    case "$RC" in
      3) rm -f "${NEWC:?}"; ship_result ship-census FAIL incomplete; exit 3 ;;
    esac
    [ -f "$CENSUS" ] && cp -f "$CENSUS" "$PREV"   # the baseline moves only when a census actually built
    mv -f "$NEWC" "$CENSUS"
    case "$RC" in
      1) if [ -s "$SHIP_STATE/ship-watched-failed" ]; then echo "the watch recorded red required context(s) $(cat "$SHIP_STATE/ship-watched-failed") but no failed run or job exists at $SHA: the context is a status posted by something outside Actions. Read it on the PR's checks page; never push on it."; ship_result ship-census FAIL incomplete; exit 3; fi
         echo "the watch reported a failure but no red job exists at $SHA: watcher/SHA mismatch. Push nothing; re-run the CI watch."; ship_result ship-census FAIL census-empty; exit 1 ;;
    esac
    [ -f "$PREV" ] || cp -f "$CENSUS" "$PREV"
    cat "$CENSUS"
    ship_fixloop_log census "sha=$(printf '%.12s' "$SHA")" "failed_jobs=$(grep -c '^=== FAILED JOB' "$CENSUS")"
    echo "CENSUS: $CENSUS is the work list. Label every WORK block (PR-CAUSED | FLAKE | BASE-SIDE | UNATTRIBUTED), fix the union, push ONCE."
    ship_result ship-census PASS built; exit 0 ;;
  prepush)
    SHA=$(sed -n 1p "$SHIP_STATE/ship-watched-sha" 2>/dev/null | tr -d '[:space:]'); _ship_hex40 "$SHA" || ship_die 1 no-watched-sha "run the CI watch first"
    [ -f "$CENSUS" ] || ship_die 3 no-census "no census to compare against: run the census first"
    DEADLINE=$(( $(date +%s) + 1200 ))
    while :; do
      NOW=$(ship_mktemp)
      build_census "$SHA" "$NOW" > "$NOW.head"; RC=$?
      [ "$RC" -ne 3 ] || { rm -f "${NOW:?}" "${NOW:?}.head"; ship_result ship-census FAIL incomplete; exit 3; }
      RUNNING=$(sed -n 's/.*running_required=//p' "$NOW.head")
      NEW=$(LC_ALL=C comm -13 <(signatures "$CENSUS") <(signatures "$NOW"))
      rm -f "${NOW:?}" "${NOW:?}.head"
      if [ -n "$NEW" ]; then echo "NEW-REQUIRED-RED signatures not in the census baseline:"; echo "$NEW"; ship_result ship-census FAIL new-required-red; exit 5; fi
      [ -n "$RUNNING" ] || break
      if [ "$WAIT" -eq 0 ]; then echo "WAIT: required run(s) still in progress at $SHA: $RUNNING (a push now cancels them; their findings would arrive a round late). Fire --pre-push --wait in the background and keep fixing."; ship_result ship-census WAIT running; exit 4; fi
      if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        # Push early only when the in-progress run is past its ceiling (stuck, not slow): a push cancels a healthy required
        # run and its findings arrive a round late. Under the ceiling, or unreadable: re-arm (exit 4), never push.
        CEIL=$(ship_cfg PRE_PUSH_CEILING_MINUTES 60)
        OLDEST=$(gh run list --commit "$SHA" --json status,createdAt --jq '[.[] | select(.status != "completed") | .createdAt] | min // empty' 2>>"$SHIP_LOG") || OLDEST=""
        CP=$(ship_ceiling_passed "$OLDEST" "$CEIL")
        echo "CEILING_PASSED=$CP (oldest in-progress run started ${OLDEST:-unknown}; ceiling ${CEIL} min)"
        if [ "$CP" = yes ]; then echo "PRE-PUSH-WAIT-EXPIRED still running past the ${CEIL}-minute ceiling: $RUNNING. Push, and record pushed-before-$RUNNING in the ledger and the PR body."; ship_fixloop_log pre-push-wait-expired "running=$RUNNING"; ship_result ship-census FAIL pre-push-wait-expired "running=$RUNNING" ceiling_passed=yes; exit 6; fi
        echo "WAIT: $RUNNING still running and not past the ceiling (or its start is unreadable): re-arm --pre-push --wait; do not push."; ship_result ship-census WAIT running ceiling_passed="$CP"; exit 4
      fi
      sleep 120
    done
    echo "PRE-PUSH: nothing new, nothing running"; ship_result ship-census PASS pre-push-clear; exit 0 ;;
  gate)
    CAP=$(ship_cfg FIX_ROUND_CAP 10); BR=$(ship_branch)
    COUNT=0; ALLOW=$CAP
    if [ -f "$ROUNDS" ]; then
      COUNT=$(sed -n 1p "$ROUNDS" | tr -d '[:space:]'); RBR=$(sed -n 2p "$ROUNDS"); A3=$(sed -n 3p "$ROUNDS" | tr -d '[:space:]')
      case "$COUNT" in ''|*[!0-9]*) ship_die 3 counter-corrupt "line 1 of $ROUNDS is not a number; repair it by hand (count, branch, allowance), never guess" ;; esac
      [ "${#COUNT}" -le 6 ] || ship_die 3 counter-corrupt "count too large"
      [ -z "$A3" ] || { case "$A3" in *[!0-9]*|'') ship_die 3 counter-corrupt "line 3 (allowance) is not a number" ;; esac; ALLOW=$((10#$A3)); }
      # An allowance only ever grows by the user's +10 extensions from the cap: anything else is a hand edit, never trusted.
      { [ "$ALLOW" -ge "$CAP" ] && [ $(( (ALLOW - CAP) % 10 )) -eq 0 ] && [ "$ALLOW" -le $((CAP + 1000)) ]; } \
        || ship_die 3 counter-corrupt "line 3 (allowance $ALLOW) is not the cap $CAP plus whole +10 extensions"
      # Reset only when BOTH branch names are known and differ (a new ship on another branch). A count-only file, or a
      # detached HEAD, keeps counting: a missing line must fail toward the cap, never away from it.
      if [ -n "$RBR" ] && [ -n "$BR" ] && [ "$RBR" != "$BR" ]; then COUNT=0; ALLOW=$CAP; fi
    fi
    COUNT=$((10#$COUNT))
    if [ "$EXTEND" -eq 1 ]; then
      [ "$COUNT" -ge "$ALLOW" ] || ship_die 2 extend-not-needed "round $((COUNT+1)) is still within the allowance of $ALLOW; --extend is only for the user's explicit 'continue' after the cap"
      ALLOW=$((ALLOW + 10)); ship_fixloop_log fix-round-extend "allowance=$ALLOW"
    fi
    NEXT=$((COUNT + 1))
    if [ "$NEXT" -gt "$ALLOW" ]; then
      echo "TELL_USER: $ALLOW fix rounds failed to converge on branch $BR. Ask what to do next: continue OFFLOAD for another 10 rounds (then re-run this gate with --extend), switch to --local, or stop. Do not pick one yourself."
      ship_result ship-census FAIL round-cap "rounds=$COUNT" "allowance=$ALLOW"; exit 1
    fi
    ship_write_atomic "$ROUNDS" "$NEXT" "$BR" "$ALLOW" || ship_die 3 counter-unwritable "could not write $ROUNDS"
    ship_fixloop_log fix-round "n=$NEXT" "allowance=$ALLOW"
    echo "fix-round $NEXT of $ALLOW"
    [ "$NEXT" -eq "$ALLOW" ] && echo "TELL_USER: this is fix round $NEXT of $ALLOW; name every remaining WORK block in the same message as the push."
    ship_result ship-census PASS "fix-round=$NEXT"; exit 0 ;;
  rerun)
    case "$RUN_ID" in ''|*[!0-9]*) ship_die 2 usage "--rerun needs --run <id>" ;; esac
    grep -qx "$RUN_ID" "$RERUNS" 2>/dev/null && { echo "run $RUN_ID was already re-run once in this ship; relabel and fix instead"; ship_result ship-census FAIL already-rerun; exit 1; }
    gh run rerun "$RUN_ID" --failed >>"$SHIP_LOG" 2>&1 || ship_die 3 gh-failed "gh run rerun $RUN_ID --failed failed"
    echo "$RUN_ID" >> "$RERUNS"; ship_fixloop_log rerun "run=$RUN_ID"
    echo "RERUN: fired for run $RUN_ID (same SHA); re-arm the CI watch"; ship_result ship-census PASS rerun; exit 0 ;;
esac
