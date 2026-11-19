#!/usr/bin/env bash
# ship-status.sh — read-only: where is this ship? Run it after a context compaction instead of re-invoking the skill.
# Prints MODE, BRANCH, PR, each step marker (ok | tree-moved | absent), the two review-code sentinels' verdicts, live
# background processes this bin/ started, the ledger summary, then LAST / NEXT / POINTER.
#   NEXT (marker-backed) is exact; NEXT (inferred) is a guess from state files: read that step before skipping anything.
# `ship-status.sh --contract=N cfg <KEY>` prints one ship.env value and nothing else (for $(...) substitution); exit 1 when unset.
# `ship-status.sh --contract=N issues` prints every issue this branch targets on one line, numerically sorted (empty when
# none; ship_issues lists the sources) and nothing else; exit 3 when a source exists but is unreadable or malformed.
# Neither prints a SHIP-RESULT line, and neither needs ship-init to have run.
# Exit: 0 · 1 (cfg: unset) · 2 (ship-init never ran, or ship.env missing) · 3 (issues: a source unreadable).
# EXIT-CODES: 0 1 2 3
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-status
if [ "${1:-}" = cfg ]; then   # cfg <KEY>: print ONE configured value (no SHIP-RESULT line: it is meant for $(...) substitution in SKILL.md)
  [ -n "${2:-}" ] || exit 2
  ship_cfg "$2" || exit 1
  exit 0
fi
if [ "${1:-}" = issues ]; then   # issues: one line for $(...) substitution (no SHIP-RESULT line)
  ship_issues || exit 3
  exit 0
fi
ship_require_mode; MODE=$SHIP_MODE
echo "MODE=$MODE"
echo "BRANCH=$(sed -n 1p "$SHIP_STATE/ship-branch" 2>/dev/null) (current: $(ship_branch))"
PR=$(sed -n 1p "$SHIP_STATE/ship-pr-number" 2>/dev/null); [ -n "$PR" ] || PR=$(ship_pr_num 2>/dev/null) || PR=none
echo "PR=$PR"
[ -f "$SHIP_STATE/ship-no-merge" ] && echo "NOTE ship-no-merge: Step 5 pauses before any merge (delete the file to lift it)"
STEPS="init sync phase1 pushed pr-created ci-green flipped enqueued merged postmerge-green"
LAST=""; NEXT=""
for s in $STEPS; do
  if ship_step_ok "$s"; then echo "STEP $s: ok"; LAST=$s; [ -z "$NEXT" ] || NEXT=""
  else case $? in 1) echo "STEP $s: tree-moved (the tree changed after this step; re-run from it, earlier gates re-validate)" ;; *) echo "STEP $s: absent" ;; esac; [ -n "$NEXT" ] || NEXT=$s; fi
done
echo "REVIEW-SENTINEL: $(ship_verify_review 2>/dev/null || true)"
echo "E2E-SENTINEL: $(ship_verify_e2e 2>/dev/null || true)"
for p in "$SHIP_STATE"/tasks/*.pid "$SHIP_STATE"/ship-monitor.pid; do
  [ -f "$p" ] || continue
  if kill -0 "$(cat "$p" 2>/dev/null)" 2>/dev/null; then echo "LIVE-BG: $(basename "$p" .pid) pid=$(cat "$p") (never start a second copy; wait for its notification or stop it)"; fi
done
[ -f "$SHIP_STATE/ship-fix-rounds" ] && echo "FIX-ROUNDS: $(sed -n 1p "$SHIP_STATE/ship-fix-rounds") of $(sed -n 3p "$SHIP_STATE/ship-fix-rounds" | grep -E '^[0-9]+$' || ship_cfg FIX_ROUND_CAP 10)"
bash "$SHIP_BIN/ship-log.sh" summary 2>/dev/null | grep '^FIXLOOP' || true
echo "LAST=${LAST:-none}"
PRSTATE=""; [ "$PR" != none ] && PRSTATE=$(gh pr view "$PR" --json state --jq .state 2>/dev/null)
if [ "$PRSTATE" = MERGED ] && ! ship_step_ok postmerge-green 2>/dev/null; then NEXT=merged-closeout
elif [ "$PR" != none ] && [ "$PRSTATE" = OPEN ]; then case "${NEXT:-done}" in init|sync|phase1|pushed|pr-created) NEXT=fix-round ;; esac; fi
case "${NEXT:-done}" in
  merged-closeout) echo "NEXT (live PR state)=the PR is MERGED and the close-out has not run: Step 5 after MERGED (close issues, post-merge CI, close-out, archive, cleanup). Never re-run earlier steps."; echo "POINTER: SKILL.md § Step 5 after MERGED" ;;
  fix-round) echo "NEXT (inferred)=a PR is open and the tree moved: you are mid fix round. Step 4.5 3a → 3c (census, fix, pre-push, round gate, push, re-arm)."; echo "POINTER: bash \"$SHIP_BIN/ship-census.sh\" --contract=$SKILL_CONTRACT" ;;
  init) echo "NEXT (marker-backed)=Mode selection (ship-init)"; echo "POINTER: SKILL.md § Mode selection" ;;
  sync) echo "NEXT (marker-backed)=Step 0.7 sync"; echo "POINTER: bash \"$SHIP_BIN/ship-sync.sh\" --contract=$SKILL_CONTRACT" ;;
  phase1) echo "NEXT (inferred)=Step 1 (fire the checks) → Step 2 → 2e-c write phase1"; echo "POINTER: SKILL.md § Step 1" ;;
  pushed) echo "NEXT (inferred)=Step 3 commit + push"; echo "POINTER: SKILL.md § Step 3" ;;
  pr-created) echo "NEXT (inferred)=Step 4 item 1 (create the PR)"; echo "POINTER: SKILL.md § Step 4" ;;
  ci-green) echo "NEXT (inferred)=Step 4.5 (watch the draft's CI)"; echo "POINTER: bash \"$SHIP_BIN/ship-watch.sh\" --contract=$SKILL_CONTRACT ci --pr $PR" ;;
  flipped) echo "NEXT (inferred)=Step 4.5 item 4 (flip to ready) — or Step 5 in --local"; echo "POINTER: SKILL.md § Step 4.5 item 4" ;;
  enqueued) echo "NEXT (inferred)=Step 5 G5–G6.5 (re-gate, enqueue or merge)"; echo "POINTER: SKILL.md § Step 5" ;;
  merged) echo "NEXT (inferred)=Step 5 queue watch to MERGED"; echo "POINTER: bash \"$SHIP_BIN/ship-watch.sh\" --contract=$SKILL_CONTRACT queue --pr $PR" ;;
  postmerge-green) echo "NEXT (inferred)=Step 5 post-merge (close issues, watch base CI, close-out, archive, cleanup)"; echo "POINTER: SKILL.md § Step 5 after MERGED" ;;
  done) echo "NEXT=final report + cleanup (all markers ok)"; echo "POINTER: SKILL.md § Step 5 cleanup" ;;
esac
ship_result ship-status PASS status; exit 0
