#!/usr/bin/env bash
# ship-push.sh — every push of the ship goes through here; never a raw `git push`.
#
#   ship-push.sh --contract=N [--kind initial|fix|conflict|rebase] [--round N] [--review none|manual|full] [--rewritten] [--remote-integrated] [--require-phase1]
#
#   --review   REQUIRED with --kind fix|conflict|rebase: the review call for this push (full = the review-code skill ran on
#              the pushed tree; manual = your own look at the delta; none = unreviewed). Appended to $SHIP_STATE/review-chain
#              as `<fp tree>\t<call>\t<round>\t<reviewed 0|1>\t<files>\t<lines>\t<epoch>`. reviewed=1 only when a review
#              covers exactly the pushed tree (`full` + review-code's sentinel, or in manual mode the user's attestation, on
#              this fingerprint); `manual` never counts. The pre-merge re-gate accepts the chain's last link for the current
#              tree, any call, on top of an anchor review (unreviewed deltas of any size can merge and are REPORTED: an
#              unreviewed link over 10 files / 300 lines prints `REVIEW-DELTA: large`). A --remote-integrated push is a
#              break link: the re-gate then demands a fresh review.
#
# Rebase-aware, leased: when Step 0.7 rebased (`ship-was-rebased`=1) or `--rewritten` is passed, the push is
# `--force-with-lease=refs/heads/<branch>:<sha>` where <sha> is the REMOTE tip recorded BEFORE the rewrite
# (`ship-remote-branch-sha`). A bare --force-with-lease compares against the remote-tracking ref, which every worktree of a
# shared clone updates on fetch, so another session's fetch can satisfy it; the explicit SHA cannot. A record of `absent`
# (branch not on the remote) is a plain `push -u`. After a successful push the record is refreshed to HEAD, so the next
# push in this ship leases on what is really there.
#   --require-phase1   refuse unless the Phase-1 sentinel matches this committed tree (always on in --local mode).
#   --remote-integrated  the first push after integrating a sibling session's commits; logged, never leased past.
# Exit: 0 pushed · 1 refused (detached HEAD, Phase 1 invalid, or git push failed for a reason other than the lease: `push-failed git_rc=`) · 2 usage · 3 a rebased ship with no usable lease record
# (never papered over with a bare lease: re-run the sync), or `untracked-unreadable` · 5 lease rejected: the remote moved
# under you — do NOT force past it; fetch, inspect, re-run the sync · 6 nothing-to-push (HEAD already on the remote) ·
# 7 dirty-tree (tracked changes uncommitted) or untracked-relevant (untracked files near this branch's changes: they may
# belong in the PR; checked in every mode, before the Phase-1 gate). 3 merge-base-unresolved: fetch the base branch.
# EXIT-CODES: 0 1 2 3 5 6 7
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-push
ship_require_mode; MODE=$SHIP_MODE
KIND=initial; ROUND=""; REWRITTEN=0; INTEGRATED=0; REQ_P1=0; REVIEW=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind) case "${2:-}" in initial|fix|conflict|rebase) KIND="$2" ;; *) ship_die 2 usage "--kind initial|fix|conflict|rebase" ;; esac; shift 2 ;;
    --round) case "${2:-}" in ''|*[!0-9]*) ship_die 2 usage "--round needs a number" ;; esac; ROUND="$2"; shift 2 ;;
    --review) case "${2:-}" in none|manual|full) REVIEW="$2" ;; *) ship_die 2 usage "--review none|manual|full" ;; esac; shift 2 ;;
    --rewritten) REWRITTEN=1; shift ;;
    --remote-integrated) INTEGRATED=1; shift ;;
    --require-phase1) REQ_P1=1; shift ;;
    *) ship_die 2 usage "unknown argument $1" ;;
  esac
done
case "$KIND" in fix|conflict|rebase) [ -n "$REVIEW" ] || ship_die 2 usage "--kind $KIND needs --review none|manual|full (the review call for this push is recorded, never implied)" ;; esac
BR=$(ship_branch); [ -n "$BR" ] || ship_die 1 detached-head "HEAD is detached"
D=$(git status --porcelain --untracked-files=no) || ship_die 3 git-unreadable "git status failed"
[ -z "$D" ] || { echo "$D" | head -10; ship_result ship-push FAIL dirty-tree; exit 7; }
ship_merge_base >/dev/null || ship_die 3 merge-base-unresolved "git merge-base HEAD $(ship_base_ref) failed: fetch the base branch, then re-run"
U=$(ship_untracked_relevant) || { echo "$U"; ship_result ship-push FAIL untracked-unreadable; exit 3; }
R=$(printf '%s\n' "$U" | sed -n "s/^RELEVANT$(printf '\t')//p")
[ -z "$R" ] || { echo "untracked files near this branch's changes (commit the ones that belong; delete the rest or move them out of the checkout):"; printf '%s\n' "$R" | head -20; ship_result ship-push FAIL untracked-relevant; exit 7; }
# --local always requires Phase 1 (its PR opens READY, so the local tier IS the gate); OFFLOAD only with --require-phase1.
if [ "$REQ_P1" -eq 1 ] || [ "$MODE" = local ]; then
  bash "$SHIP_BIN/ship-sentinel.sh" verify phase1 --committed > "$SHIP_STATE/logs/push-phase1.log" 2>&1 || { grep -v '^READ:' "$SHIP_STATE/logs/push-phase1.log"; ship_result ship-push FAIL phase1-invalid; exit 1; }
fi
HEAD=$(git rev-parse HEAD)
REC=$(sed -n 1p "$SHIP_STATE/ship-remote-branch-sha" 2>/dev/null | tr -d '[:space:]')
WAS=$(sed -n 1p "$SHIP_STATE/ship-was-rebased" 2>/dev/null | tr -d '[:space:]')
LIVE=$(git ls-remote origin "refs/heads/$BR" 2>/dev/null | cut -f1)
if [ -n "$LIVE" ] && [ "$LIVE" = "$HEAD" ]; then
  ship_write_atomic "$SHIP_STATE/ship-remote-branch-sha" "$HEAD" || true; ship_step_mark pushed >/dev/null 2>&1 || true
  echo "HEAD $HEAD is already the remote tip; nothing to push"; ship_result ship-push SKIP nothing-to-push; exit 6
fi
# The lease is decided from HISTORY, not from a flag: if the recorded remote tip is not an ancestor of HEAD (a rebase or a rewrite
# happened since the sync recorded it), the push must be leased on exactly that tip. `absent` = plain push -u, whatever happened.
LEASE=""
if [ "$REC" = absent ]; then LEASE=""
elif _ship_hex40 "$REC"; then
  git merge-base --is-ancestor "$REC" HEAD 2>/dev/null || LEASE="--force-with-lease=refs/heads/$BR:$REC"
elif [ "$REWRITTEN" -eq 1 ] || [ "$WAS" = 1 ]; then
  echo "this ship rebased or rewrote history but has no usable lease record (${REC:-none}); re-run the Step 0.7 sync, never a bare lease"; ship_result ship-push FAIL no-lease-record; exit 3
fi
if [ -n "$LEASE" ]; then git push "$LEASE" origin "$BR" > "$SHIP_STATE/logs/push.log" 2>&1; RC=$?
else git push -u origin "$BR" > "$SHIP_STATE/logs/push.log" 2>&1; RC=$?; fi
if [ "$RC" -ne 0 ]; then
  if grep -qiE 'stale info|fetch first|non-fast-forward' "$SHIP_STATE/logs/push.log"; then
    tail -5 "$SHIP_STATE/logs/push.log"; echo "the remote branch moved under you (another session pushing the same branch). Do NOT force past it: fetch, inspect, re-run the sync."
    ship_result ship-push FAIL lease-rejected; exit 5
  fi
  tail -10 "$SHIP_STATE/logs/push.log"; ship_result ship-push FAIL push-failed "git_rc=$RC"; exit 1
fi
ship_write_atomic "$SHIP_STATE/ship-remote-branch-sha" "$HEAD" || true
ship_step_mark pushed >/dev/null 2>&1 || true
if [ -n "$REVIEW" ] || [ "$INTEGRATED" -eq 1 ]; then
  # One chain link per recorded push: `<fp tree>\t<call>\t<round>\t<reviewed>\t<files>\t<lines>\t<epoch>` (ship-lib's
  # _ship_verify_chain reads it). reviewed=1 only when a review covers exactly the pushed tree: `full` with review-code's
  # sentinel (or, in manual mode, the user's review attestation) on this fingerprint. `manual` is the agent's own look and
  # is recorded, reported, never counted as reviewed. A --remote-integrated push is a BREAK: commits another session
  # pushed were never reviewed here, so the chain cannot carry the gate past them (a fresh review is required).
  FPT=$(ship_fp_tree) || FPT=""
  if [ -z "$FPT" ]; then echo "WARN review-chain not recorded (fingerprint failed): the pre-merge re-gate will demand a review"
  else
    RV=0; CALL="${REVIEW:-none}"
    if [ "$CALL" = full ]; then
      if [ "$(ship_cfg REVIEW_GATE sentinel)" = manual ]; then SF="$SHIP_STATE/manual-review"; else SF="$SHIP_STATE/review-code-ran"; fi
      if [ "$(sed -n 1p "$SF" 2>/dev/null | tr -d '[:space:]')" = "$FPT" ]; then RV=1
      else echo "WARN --review full but no review covers the pushed tree ($(basename "$SF") is absent or for other bytes): recorded as unreviewed"; fi
    fi
    [ "$INTEGRATED" -eq 1 ] && { CALL=break-remote-integrated; RV=0; }
    DF="?"; DL="?"
    if _ship_hex40 "$REC" && git cat-file -e "$REC^{commit}" 2>/dev/null; then
      # Only paths this branch changes against the base: after a sync, REC..HEAD also carries the base's own commits,
      # which are not this ship's unreviewed delta (counting them would make every rebase push read "large").
      MBP=$(ship_merge_base) && OWN=$(git -c core.quotePath=false diff --name-only --no-renames "$MBP" HEAD 2>/dev/null) \
        && NS=$(git -c core.quotePath=false diff --numstat --no-renames "$REC" HEAD 2>/dev/null) \
        && NS=$(printf '%s\n' "$NS" | SHIP_OWN="$OWN" awk -F'\t' 'BEGIN { n = split(ENVIRON["SHIP_OWN"], a, "\n"); for (i = 1; i <= n; i++) own[a[i]] = 1 } NF >= 3 && ($3 in own)') \
        && { DF=$(printf '%s\n' "$NS" | grep -c .); DL=$(printf '%s\n' "$NS" | awk -F'\t' '{ if ($1 ~ /^[0-9]+$/) s+=$1; if ($2 ~ /^[0-9]+$/) s+=$2 } END { print s+0 }'); }
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$FPT" "$CALL" "${ROUND:-}" "$RV" "$DF" "$DL" "$(date +%s)" >> "$SHIP_STATE/review-chain" || echo "WARN review-chain not recorded (unwritable)"
    if [ "$RV" -eq 0 ]; then
      case "$DF$DL" in *'?'*) ;; *) { [ "$DF" -gt 10 ] || [ "$DL" -gt 300 ]; } && echo "REVIEW-DELTA: large files=$DF lines=$DL (unreviewed; a hint, not a gate: name it in the final report)" ;; esac
    fi
  fi
fi
ship_fixloop_log push "kind=$KIND" "round=${ROUND:-}" "review=${REVIEW:-n/a}" "rewritten=$REWRITTEN" "remote_integrated=$INTEGRATED" "head=$(printf '%.12s' "$HEAD")"
echo "PUSHED: $BR @ $(printf '%.12s' "$HEAD") kind=$KIND${ROUND:+ round=$ROUND}${LEASE:+ (leased)}"
ship_result ship-push PASS pushed "kind=$KIND"; exit 0
