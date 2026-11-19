#!/usr/bin/env bash
# ship-release.sh lint|harvest — Step 2d (release actions), one process per leg. RELEASE_ACTIONS=file-ledger only.
#
# The body is always this branch's canonical body file, `$SHIP_STATE/pr-body-<branch, / made ->.md` (Step 2c): there is no
# way to point a leg at another file, so what is linted and harvested is what `gh pr create` / `gh pr edit` sends.
#
#   lint     RELEASE_ACTION_LINT_CMD with BODY=<the body file>: action-required prose in the body that is not inside a
#            ```release-action block. Its exit 1 is a HALT (the violating lines are printed); any other non-zero is exit 3
#            (the lint could not run: never read as clean).
#   harvest  RELEASE_ACTION_HARVEST_CMD with BODY=<the body file>: append every ```release-action block to the in-repo
#            ledger under RELEASE_LEDGER_DIR, then `git add` that directory and READ BACK that nothing under it is left
#            untracked or unstaged: a fragment that is not staged is never committed and the obligation evaporates. A
#            harvest failure is exit 3; a stage failure (or anything left unstaged) is exit 4, never `|| true`.
#
# Exit: 0 pass · 10 SKIP (RELEASE_ACTIONS=none, or no body file yet) · 1 HALT (lint hit) · 2 usage/environment (incl.
# file-ledger with a command or the ledger dir unset: ship_cfg_validate) · 3 the tool could not run · 4 the harvest is
# not staged (the record would be LOST at commit).
# EXIT-CODES: 0 1 2 3 4 10
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-release

LEG="${1:-}"; case "$LEG" in lint|harvest) ;; *) ship_die 2 usage "ship-release.sh lint|harvest" ;; esac
[ "$#" -eq 1 ] || ship_die 2 usage "ship-release.sh $LEG takes no other argument (the body file is the canonical one)"
[ "$(ship_cfg RELEASE_ACTIONS none)" = file-ledger ] || { echo "RELEASE: RELEASE_ACTIONS=none (the PR body is still documentation, never a queue)"; ship_result ship-release SKIP not-configured; exit 10; }
BR=$(git branch --show-current 2>/dev/null) || ship_die 2 branch-unreadable "git could not read the branch"
[ -n "$BR" ] || ship_die 2 detached-head "HEAD is detached"
BODY="$SHIP_STATE/pr-body-$(printf '%s' "$BR" | tr '/' '-').md"
[ -f "$BODY" ] || { echo "RELEASE: no body file yet ($BODY): write it at Step 2c first"; ship_result ship-release SKIP no-body; exit 10; }

case "$LEG" in
  lint)
    OUT=$(BODY="$BODY" bash -c "$(ship_cfg RELEASE_ACTION_LINT_CMD)" 2>&1); RC=$?
    case "$RC" in
      0) echo "RELEASE: lint clean"; ship_result ship-release PASS lint-clean; exit 0 ;;
      1) printf '%s\n' "$OUT" | tail -30; echo "RELEASE: action-shaped prose outside a release-action block: register it as a block (never delete the prose to pass)"; ship_result ship-release FAIL lint-hit; exit 1 ;;
      *) printf '%s\n' "$OUT" | tail -10; ship_result ship-release FAIL lint-failed "rc=$RC"; exit 3 ;;
    esac ;;
  harvest)
    DIR=$(ship_cfg RELEASE_LEDGER_DIR)
    OUT=$(BODY="$BODY" bash -c "$(ship_cfg RELEASE_ACTION_HARVEST_CMD)" 2>&1); RC=$?
    [ "$RC" -eq 0 ] || { printf '%s\n' "$OUT" | tail -10; ship_result ship-release FAIL harvest-failed "rc=$RC"; exit 3; }
    if [ -e "$DIR" ]; then
      git add -- "$DIR" >>"$SHIP_LOG" 2>&1 || { echo "RELEASE: git add $DIR failed: the harvested rows would be lost at commit"; ship_result ship-release FAIL not-staged; exit 4; }
      LEFT=$(git status --porcelain --untracked-files=all -- "$DIR") || { ship_result ship-release FAIL not-staged; exit 4; }
      LEFT=$(printf '%s\n' "$LEFT" | grep -E '^(\?\?|.[MD])')
      [ -z "$LEFT" ] || { printf '%s\n' "$LEFT"; echo "RELEASE: ledger files are not staged: they would not be committed"; ship_result ship-release FAIL not-staged; exit 4; }
    elif [ -n "$OUT" ]; then
      printf '%s\n' "$OUT" | tail -5; echo "RELEASE: the harvest printed rows but $DIR does not exist: they were written somewhere else and would not be committed"; ship_result ship-release FAIL not-staged; exit 4
    fi
    printf '%s\n' "$OUT" | tail -5
    echo "RELEASE: harvested and staged under $DIR"; ship_result ship-release PASS harvested; exit 0 ;;
esac
