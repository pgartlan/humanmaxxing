#!/usr/bin/env bash
# ship-init.sh — Mode selection: run exactly once per ship, first (after the model check).
#
# Usage (the SKILL.md pointer):
#   bash <skill-dir>/bin/ship-init.sh --contract=N --skill-dir "<Base directory for this skill>" <<'EOF_ARGS'; exit $?
#   $ARGUMENTS
#   EOF_ARGS
#
# Arguments text on stdin: nothing (DEFAULT_MODE from ship.env), `--local`, `--offload`, `--fresh`, `--no-merge`, and free
# text (an issue number, a note, a no-merge phrase such as "no merge" / "do not merge" / "pause before merge"). Any other word
# starting with `-` is rejected (a typo must never silently pick the default mode). The text is data: it is stored byte-exact
# in ship-args.txt and a NEUTRALIZED copy (code fences, `#N` references and closing keywords made inert) in
# ship-args.body.md for the PR body, appended by file, never pasted into a prompt. The pointer's `; exit $?` after the heredoc
# stops a terminator inside the text from executing what follows it: never remove it.
#
#   ship-init.sh --contract=N --cleanup [--delete-remote-branch]   AFTER the PR reads MERGED (checked live via gh): removes the
#       per-worktree state directory (path asserted: absolute, ends in /ship-state, inside this git dir) and optionally the remote
#       branch. Exit 0 · 1 not merged (state kept) · 3 gh unreadable · 2.
#
# `--skill-dir` is REQUIRED: the directory the harness loaded SKILL.md from. If it is not THIS bin/'s skill
# directory (a session launched in another worktree, so the text in context is not this worktree's) → exit 9
# `skill-dir-mismatch`, nothing written. Otherwise `git hash-object SKILL.md` is recorded to ship-skill-blob on
# EVERY run (fresh or resume) so ship-lib's freshness check compares against the text that was just loaded.
#
# Fresh vs resume: resume when ship-mode exists with the SAME mode and no-merge request AND either a step
# marker still matches the current tree or a `skill-changed` exit 9 asked for a reload within 2 h. Otherwise
# fresh: per-ship state is reset. `--fresh` always resets. The fix-round counter survives a fresh start on the
# SAME branch (only --fresh or another branch resets it): a cap that forgets is no cap.
#
# Prints START: fresh (reason=…) | resume (…), MODE=, NO-MERGE: requested (when asked), FIX-ROUNDS: kept N of M.
# Exit: 0 · 2 usage/environment · 9 skill-dir-mismatch.
# EXIT-CODES: 0 2 9
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-init

if [ "${1:-}" = --cleanup ]; then
  DELREM=0; [ "${2:-}" = --delete-remote-branch ] && DELREM=1
  BR=$(ship_branch); [ -n "$BR" ] || ship_die 2 detached-head "HEAD is detached"
  ST=$(gh pr view --json state --jq .state 2>>"$SHIP_LOG") || ship_die 3 gh-unreadable "gh pr view failed: cannot confirm the PR is MERGED; nothing deleted"
  [ "$ST" = MERGED ] || { echo "PR state is $ST, not MERGED: ship-state kept (expected on a pause or while queued)"; ship_result ship-init FAIL not-merged; exit 1; }
  case "$SHIP_STATE" in /*/ship-state) ;; *) ship_die 1 unsafe-path "refusing to remove '$SHIP_STATE': not an absolute path ending in /ship-state" ;; esac
  GD=$(cd "$(git rev-parse --git-dir)" && pwd -P); case "$SHIP_STATE" in "$GD"/*) ;; *) ship_die 1 unsafe-path "refusing: $SHIP_STATE is outside this worktree's git dir $GD" ;; esac
  rm -rf "${SHIP_STATE:?}"
  echo "CLEANUP: removed $SHIP_STATE"
  if [ "$DELREM" -eq 1 ]; then git push origin --delete "$BR" >/dev/null 2>&1 && echo "CLEANUP: remote branch $BR deleted" || { echo "CLEANUP: remote branch delete failed (delete by hand if still wanted)"; echo "SHIP-RESULT ship-init FAIL remote-delete-failed"; exit 5; }; fi
  echo "SHIP-RESULT ship-init PASS cleanup"; exit 0
fi
SKILL_DIR_ARG=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skill-dir=*) SKILL_DIR_ARG="${1#--skill-dir=}"; shift ;;
    --skill-dir) [ "$#" -ge 2 ] || ship_die 2 skill-dir-missing "--skill-dir needs a value"; SKILL_DIR_ARG="$2"; shift 2 ;;
    *) ship_die 2 unknown-argument "unrecognized argument '$(printf '%.60s' "$1")'. Only --skill-dir <dir>; the ship arguments go on stdin." ;;
  esac
done
[ -n "$SKILL_DIR_ARG" ] || ship_die 2 skill-dir-missing "--skill-dir <dir> is required: pass the harness's \"Base directory for this skill\"."
GIVEN=$(cd "$SKILL_DIR_ARG" 2>/dev/null && pwd -P) || ship_die 2 skill-dir-missing "--skill-dir '$SKILL_DIR_ARG' is not a directory"
if [ "$GIVEN" != "$SHIP_SKILL_DIR" ]; then
  echo "STOP: the skill text you are following was loaded from $GIVEN, but this worktree's ship skill is $SHIP_SKILL_DIR."
  echo "   Read $SHIP_SKILL_DIR/SKILL.md in full from disk, follow THAT text, and re-run this pointer with --skill-dir $SHIP_SKILL_DIR."
  ship_result ship-init FAIL skill-dir-mismatch
  exit 9
fi
SKILL_BLOB=$(git hash-object "$SHIP_SKILL_DIR/SKILL.md" 2>/dev/null) || ship_die 2 skill-md-missing "cannot hash $SHIP_SKILL_DIR/SKILL.md"

# ---- arguments on stdin ------------------------------------------------------------------------------------
ARGS=""
if [ ! -t 0 ]; then ARGS=$(cat 2>/dev/null | tr -d '\r'); fi
WANT_MODE=""; FRESH=0; NO_MERGE=0
set -f   # the text is split into words below; a glob must not expand into file names
for w in $ARGS; do
  case "$w" in
    --local) WANT_MODE=local ;;
    --offload) WANT_MODE=offload ;;
    --fresh) FRESH=1 ;;
    --no-merge) NO_MERGE=1 ;;
    --) ;;
    --*) ship_die 2 bad-argument "unknown ship flag '$w' (a typo must never silently pick the default mode). Allowed: --local, --offload, --fresh, --no-merge, free text." ;;
    *) ;;
  esac
done
set +f
# A no-merge PHRASE pauses the ship (a false positive pauses, which is the safe direction); "no merge conflicts" is not a request.
if printf '%s' "$ARGS" | tr 'A-Z' 'a-z' | grep -qE "(^|[^a-z])(no[ -]merge|do not merge|don'?t merge|dont merge|pause before (the )?merge|without merging)([^a-z]|$)" \
   && ! printf '%s' "$ARGS" | tr 'A-Z' 'a-z' | grep -qE "no[ -]merge conflict"; then NO_MERGE=1; fi
if [ -z "$WANT_MODE" ]; then
  WANT_MODE=$(ship_cfg DEFAULT_MODE offload)
  case "$WANT_MODE" in local|offload) ;; *) ship_die 2 ship-env-malformed "DEFAULT_MODE in ship.env must be local or offload (got '$WANT_MODE')" ;; esac
fi
ship_base_branch >/dev/null   # exits 2 when BASE_BRANCH is unset: ship.env is required before anything else

if [ -f "$SHIP_STATE/ship-sync-pending" ] || [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
  echo "a sync is pending (a rebase is in progress or was left conflicted): nothing reset. Resolve, git add, then: bash \"$SHIP_BIN/ship-sync.sh\" --contract=$SKILL_CONTRACT --continue (or git rebase --abort, then --continue once to clear)."
  ship_result ship-init FAIL sync-pending; exit 1
fi
BR=$(ship_branch); [ -n "$BR" ] || ship_die 2 detached-head "HEAD is detached; ship runs on a branch"

# ---- fresh or resume ----------------------------------------------------------------------------------------
START_REASON=""; RESUME=0
PREV_MODE=$(ship_mode 2>/dev/null) || PREV_MODE=""
PREV_NM=0; [ -f "$SHIP_STATE/ship-no-merge" ] && PREV_NM=1
PREV_BR=$(sed -n 1p "$SHIP_STATE/ship-branch" 2>/dev/null)
if [ "$FRESH" -eq 1 ]; then START_REASON="--fresh"
elif [ -z "$PREV_MODE" ]; then START_REASON="no-prior-ship"
elif [ "$PREV_MODE" != "$WANT_MODE" ]; then START_REASON="mode-changed($PREV_MODE->$WANT_MODE)"
elif [ "$PREV_NM" != "$NO_MERGE" ]; then START_REASON="no-merge-changed"
elif [ "$PREV_BR" != "$BR" ]; then START_REASON="branch-changed"
else
  N_OK=0; N_STALE=0
  for f in "$SHIP_STATE"/step-*; do
    [ -f "$f" ] || continue
    if ship_step_ok "$(basename "$f" | sed 's/^step-//')"; then N_OK=$((N_OK+1)); else N_STALE=$((N_STALE+1)); fi
  done
  RELOAD=0
  if [ -f "$SHIP_STATE/ship-skill-reload-pending" ]; then
    t=$(sed -n 1p "$SHIP_STATE/ship-skill-reload-pending" | tr -d '[:space:]')
    _ship_epoch_ok "$t" && [ $(( $(date +%s) - t )) -le 7200 ] && RELOAD=1
    rm -f "$SHIP_STATE/ship-skill-reload-pending"
  fi
  PR_OPEN=0; [ -f "$SHIP_STATE/ship-pr-number" ] && PR_OPEN=1   # a PR exists: mid-fix-round trees are legitimately "stale"; never wipe the census, lease or counter
  SYNCING=0; { [ -f "$SHIP_STATE/ship-sync-pending" ] || [ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]; } && SYNCING=1   # a conflicted sync mid-flight: its autostash record must survive
  if [ "$N_OK" -gt 0 ] || [ "$RELOAD" -eq 1 ] || [ "$PR_OPEN" -eq 1 ] || [ "$SYNCING" -eq 1 ]; then
    RESUME=1; START_REASON="ok_markers=$N_OK stale_markers=$N_STALE"
    [ "$RELOAD" -eq 1 ] && START_REASON="$START_REASON reason=skill-changed"
    [ "$PR_OPEN" -eq 1 ] && [ "$N_OK" -eq 0 ] && START_REASON="$START_REASON reason=pr-exists"
    [ "$SYNCING" -eq 1 ] && START_REASON="$START_REASON reason=sync-pending"
  else START_REASON="markers-stale"; fi
fi

if [ "$RESUME" -eq 0 ]; then
  [ "$FRESH" -eq 1 ] && [ -f "$SHIP_STATE/ship-sync-pending" ] && echo "WARN --fresh while a sync was pending: resolve or abort the rebase yourself; the autostash record is dropped"
  # A live task from the previous ship would write its exit file AFTER the reset and vouch for a tree it never saw: stop it first.
  for pf in "$SHIP_STATE"/tasks/*.pid; do
    [ -f "$pf" ] || continue
    lp=$(cat "$pf" 2>/dev/null); if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; then kill "$lp" 2>/dev/null; echo "STOPPED: live task $(basename "$pf" .pid) pid=$lp from the previous ship"; fi
  done
  # Keep: fix-rounds (same branch only), fixloop ledger (archive reads it), logs. Reset everything else.
  KEEP_ROUNDS=0
  if [ "$FRESH" -eq 0 ] && [ -f "$SHIP_STATE/ship-fix-rounds" ] && [ "$(sed -n 2p "$SHIP_STATE/ship-fix-rounds")" = "$BR" ]; then KEEP_ROUNDS=1; fi
  for f in "$SHIP_STATE"/step-* "$SHIP_STATE"/tasks/* "$SHIP_STATE"/ship-phase1-passed "$SHIP_STATE"/ship-rebased-onto "$SHIP_STATE"/ship-was-rebased \
           "$SHIP_STATE"/ship-remote-branch-sha "$SHIP_STATE"/ship-sync-pending "$SHIP_STATE"/ship-watched-sha "$SHIP_STATE"/ship-census.txt \
           "$SHIP_STATE"/ship-census-prev.txt "$SHIP_STATE"/ship-ci-reruns "$SHIP_STATE"/ship-no-merge "$SHIP_STATE"/ship-args.txt \
           "$SHIP_STATE"/ship-skill-reload-pending "$SHIP_STATE"/ship-monitor.pid "$SHIP_STATE"/ship-pr-number "$SHIP_STATE"/tasks.list \
           "$SHIP_STATE"/review-chain "$SHIP_STATE"/manual-review "$SHIP_STATE"/manual-e2e "$SHIP_STATE"/ship-watched-failed "$SHIP_STATE"/ship-args.body.md \
           "$SHIP_STATE"/pr-body-*.md; do
    [ -e "$f" ] && rm -f "$f"
  done
  [ "$KEEP_ROUNDS" -eq 1 ] || rm -f "$SHIP_STATE/ship-fix-rounds"
  [ "$FRESH" -eq 1 ] && rm -f "$SHIP_STATE/fixloop.tsv"
fi

ship_write_atomic "$SHIP_STATE/ship-mode" "$WANT_MODE" || ship_die 2 write-failed "could not write ship-mode"
ship_write_atomic "$SHIP_STATE/ship-branch" "$BR" || ship_die 2 write-failed "could not write ship-branch"
ship_write_atomic "$SHIP_STATE/ship-skill-blob" "$SKILL_BLOB" || ship_die 2 write-failed "could not write ship-skill-blob"
if [ "$NO_MERGE" -eq 1 ]; then ship_write_atomic "$SHIP_STATE/ship-no-merge" "$(date +%s)" || ship_die 2 write-failed "could not write ship-no-merge"; fi
if [ -n "$ARGS" ]; then
  # Byte-exact record, plus the body-safe copy: indented as a code block, fences broken, `#N` and closing keywords made inert
  # (a live `Closes #N` in pasted argument text would close an issue; a fence would end the body's own code block).
  printf '%s\n' "$ARGS" > "$SHIP_STATE/ship-args.txt"
  # `#N` → `# N` (no issue link), closing keywords wrapped in backticks (the host's recognizer drops inline code), fences broken.
  { echo '## Ship arguments'; echo; printf '%s\n' "$ARGS" | sed -e 's/```/`‵`/g' -e 's/#\([0-9]\)/# \1/g' -e 's/\b\([Cc]lose[sd]\{0,1\}\|[Ff]ix\(e[sd]\)\{0,1\}\|[Rr]esolve[sd]\{0,1\}\)\b/`\1`/g' -e 's/^/    /'; } > "$SHIP_STATE/ship-args.body.md"
fi
ship_step_mark init >/dev/null 2>&1 || true
ship_fixloop_log init "mode=$WANT_MODE" "resume=$RESUME" "no_merge=$NO_MERGE"

echo "MODE=$WANT_MODE"
if [ "$RESUME" -eq 1 ]; then
  echo "START: resume ($START_REASON) - state kept, nothing reset; pass --fresh to start over"
  echo "RESUME-HINT: bash \"$SHIP_BIN/ship-status.sh\" --contract=$SKILL_CONTRACT"
else
  echo "START: fresh (reason=$START_REASON)"
fi
if [ -f "$SHIP_STATE/ship-fix-rounds" ]; then
  echo "FIX-ROUNDS: kept $(sed -n 1p "$SHIP_STATE/ship-fix-rounds") of $(sed -n 3p "$SHIP_STATE/ship-fix-rounds" | grep -E '^[0-9]+$' || ship_cfg FIX_ROUND_CAP 10)"
fi
[ "$NO_MERGE" -eq 1 ] && echo "NO-MERGE: requested (Step 5 pauses before any merge; delete $SHIP_STATE/ship-no-merge to lift it)"
[ -n "$ARGS" ] && echo "ANNOTATION: recorded ($SHIP_STATE/ship-args.body.md is the body-safe copy: append it by file)"
ship_result ship-init PASS "mode=$WANT_MODE" "resume=$RESUME"
exit 0
