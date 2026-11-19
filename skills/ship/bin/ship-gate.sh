#!/usr/bin/env bash
# ship-gate.sh — the gates that route on an exit code instead of a checklist: the branch check, the flip to ready, and
# the enqueue / merge. Each re-checks every precondition itself, from live state, and reads no stored verdict.
#
#   body-check --file <body>
#       Step 2c, before `gh pr create` and after every body edit: every started issue (ship-status.sh issues) should have a
#       closing line, or be owned (`owns #N`) by a line-start `⚠️ ADDITIONAL PR REQUIRED` banner that the reviewed plan's
#       `## PRs` Owns column declares (User-approved? yes; PLANS_DIR/<N>-*.md). A miss is a WARNING, never a refusal
#       (`WARN started-issue-not-closed`, `WARN banner-not-in-plan`): customers may run their issue flow differently.
#       Exit 0 (`body-check` or `body-check-warned`) · 3 an input unreadable. The enqueue runs the same check on the live body.
#   branch --protected '<PROTECTED_BRANCHES ERE>'
#       Step 0-flight. Exit 0 this worktree's branch is shippable · 1 detached HEAD, a protected branch, or nothing of its
#       own to ship (an empty diff against the merge-base and a clean tree: a wrong-worktree signal) · 2 usage (an empty
#       or unsubstituted ERE) · 3 the merge-base or the status is unreadable.
#   ci-skip-label
#       Step 4 item 1. Exit 0 the CI_SKIP_LABEL may be applied: `--local` and `verify phase1 --committed` passes (the full local
#       tier ran green on exactly this committed tree) · 1 OFFLOAD (never) or Phase 1 invalid · 3 unreadable.
#   flip --pr N [--check-only]
#       Step 4.5 item 4 (OFFLOAD). In order, the first that fails ends the run and nothing is flipped:
#         the PR is OPEN, on this branch, and its head is HEAD · the tracked tree is committed (untracked-only differences
#         WARN) · HEAD is the branch tip on origin · the CI watch recorded CI_GREEN for exactly HEAD (ship-ci-green-sha:
#         a push after the green strips it, so "no push between green and ready" holds by construction) · `verify e2e`
#         passes · the PR is not CONFLICTING · (flip only, not the enqueue's --check-only re-run) the Phase-1 sentinel
#         exists (a base sync deletes it: re-run 1c; a fix round leaves it, because the draft PR's CI round is that
#         round's re-check; after the flip OFFLOAD does not read it).
#       Then `gh pr ready` (not with --check-only, and not in --local, whose PR opens ready).
#       Exit 0 flipped (or, with --check-only, every precondition holds) · 1 HALT (the line says which) · 2 usage ·
#       3 a gh / git read failed (never read as a pass).
#   enqueue --pr N [-- <MERGE_FLAGS>]
#       Step 5 G6.5, the ONLY path that applies QUEUE_LABEL or runs `gh pr merge`. In order:
#         the no-merge pause (SHIP_STATE/ship-no-merge) · not a draft · no closing keyword in a branch commit message or
#         the live title · (a WARNING only: every issue this branch targets has a closing line in the live body, body-check) ·
#         the flip preconditions again (--check-only: a push since the flip leaves the proofs on other bytes) · the
#         review and E2E gates (`verify gates`). Then MERGE_METHOD=queue: the label, unless it is already on the PR (exit
#         10: never re-stamp it, a re-stamp defeats the queue's per-SHA failure memory), read back; direct: `gh pr merge N
#         <MERGE_FLAGS>` (`--admin` refused: a bypass is only ever the user's instruction for one instance, run by hand).
#       Exit 0 enqueued / merge requested · 1 HALT · 2 usage · 3 a read or the write failed · 10 the label is already on.
# EXIT-CODES: 0 1 2 3 10
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-gate

VERB="${1:-}"; [ -n "$VERB" ] && shift
PR=""; CHECK_ONLY=0; PROT=""; HAS_PROT=0; FLAGS=""; BODYFILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr) PR="${2:-}"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --protected) PROT="${2:-}"; HAS_PROT=1; shift 2 ;;
    --file) BODYFILE="${2:-}"; shift 2 ;;
    --) shift; FLAGS="$*"; break ;;
    *) ship_die 2 usage "unknown argument $1" ;;
  esac
done
halt() { echo "GATE: HALT $2"; ship_result ship-gate FAIL "$1"; exit 1; }
CLOSE_RE='(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]*#[0-9]+'

pr_json() { gh pr view "$PR" --json "$1" 2>>"$SHIP_LOG"; }
need_pr() { case "$PR" in ''|*[!0-9]*) PR=$(sed -n 1p "$SHIP_STATE/ship-pr-number" 2>/dev/null | tr -d '[:space:]') ;; esac
  case "$PR" in ''|*[!0-9]*) ship_die 2 usage "$VERB needs --pr N (no recorded PR number)" ;; esac; }

# flip_checks — every flip precondition; returns only when all hold (halts / dies otherwise).
flip_checks() {
  local J BR HEAD ST HN HO LIVE GREEN OUT RC MG D
  command -v jq >/dev/null 2>&1 || ship_die 2 jq-missing "jq is required"
  BR=$(ship_branch); [ -n "$BR" ] || halt detached-head "HEAD is detached"
  HEAD=$(git rev-parse HEAD) || ship_die 3 git-unreadable "git rev-parse HEAD failed"
  J=$(pr_json state,headRefName,headRefOid,isDraft,mergeable) || ship_die 3 gh-unreadable "gh pr view $PR failed (gh auth status?)"
  ST=$(printf '%s' "$J" | jq -r .state); HN=$(printf '%s' "$J" | jq -r .headRefName); HO=$(printf '%s' "$J" | jq -r .headRefOid)
  MG=$(printf '%s' "$J" | jq -r '.mergeable // "UNKNOWN"'); PR_DRAFT=$(printf '%s' "$J" | jq -r .isDraft)
  [ "$ST" = OPEN ] || halt pr-not-open "PR $PR is $ST"
  [ "$HN" = "$BR" ] || halt pr-not-this-branch "PR $PR is for branch '$HN', this worktree is on '$BR'"
  [ "$HO" = "$HEAD" ] || halt head-moved "PR head $(printf '%.12s' "$HO") is not HEAD $(printf '%.12s' "$HEAD"): re-watch the PR's head, push through ship-push.sh"
  D=$(git status --porcelain --untracked-files=no) || ship_die 3 git-unreadable "git status failed"
  [ -z "$D" ] || { echo "$D" | head -10; halt tree-not-committed "tracked changes are not in the commit the CI round tested"; }
  [ -z "$(git ls-files --others --exclude-standard 2>/dev/null | head -1)" ] || echo "WARN untracked files are present; they are not in the PR"
  LIVE=$(git ls-remote origin "refs/heads/$BR" 2>>"$SHIP_LOG") || ship_die 3 remote-unreadable "git ls-remote origin failed"
  LIVE=$(printf '%s' "$LIVE" | cut -f1)
  [ "$LIVE" = "$HEAD" ] || halt head-not-on-remote "origin/$BR is $(printf '%.12s' "${LIVE:-absent}"), HEAD is $(printf '%.12s' "$HEAD")"
  GREEN=$(sed -n 1p "$SHIP_STATE/ship-ci-green-sha" 2>/dev/null | tr -d '[:space:]')
  [ "$GREEN" = "$HEAD" ] || halt ci-not-green-at-head "no CI_GREEN recorded for HEAD $(printf '%.12s' "$HEAD") (recorded: ${GREEN:-none}): run the Step 4.5 watch on this head"
  OUT=$(bash "$SHIP_BIN/ship-sentinel.sh" verify e2e 2>&1); RC=$?
  printf '%s\n' "$OUT" | grep '^E2E:'
  case "$RC" in 0) ;; 3) ship_die 3 e2e-unreadable "the E2E reader could not compute" ;; *) halt e2e-invalid "the E2E gate does not pass for this tree (4.0b)" ;; esac
  [ "$MG" != CONFLICTING ] || halt conflicting "PR $PR is CONFLICTING: resolve (G5b)"
}

# closeout_check <body-file> — every started issue should be closed by the body. A WARNING, never a refusal (a deliberate
# deviation from the reference, where it blocks: customers may run their issue flow differently). An issue a line-start
# `⚠️ ADDITIONAL PR REQUIRED` banner names after `owns`, backed by the reviewed plan's `## PRs` Owns column, is silent; a
# banner no plan backs warns `banner-not-in-plan`. An unreadable input is still exit 3 (never "nothing to warn about").
closeout_check() {
  local sc kind n
  sc=$(ship_started_unclosed "$1") || ship_die 3 issues-unreadable "the started-issue check could not read its inputs (the issue list, the body, or a plan's ## PRs)"
  CLOSEOUT_WARN=0
  while read -r kind n; do
    [ -n "$n" ] || continue
    case "$kind" in
      WARN) : ;;   # declared additional PR (banner + reviewed plan): it closes #n
      UNDECLARED) CLOSEOUT_WARN=1; echo "WARN banner-not-in-plan: #$n is owned by an ADDITIONAL PR REQUIRED banner, but no reviewed plan's ## PRs row (User-approved? yes) declares that PR" ;;
      *) CLOSEOUT_WARN=1; echo "WARN started-issue-not-closed: #$n, which this branch targets, has no closing line in the body: add '<ISSUE_CLOSE_KEYWORD> #$n', or name it after 'owns' in a line-start '⚠️ ADDITIONAL PR REQUIRED' banner if another PR closes it" ;;
    esac
  done <<EOF_SC
$sc
EOF_SC
  return 0
}

case "$VERB" in
  body-check)
    # Draft time: the same close-out check on the body file before `gh pr create` (and after every body edit).
    [ -n "${BODYFILE:-}" ] || ship_die 2 usage "body-check --file <body>"
    [ -r "$BODYFILE" ] || ship_die 3 body-unreadable "cannot read $BODYFILE"
    closeout_check "$BODYFILE"
    if [ "$CLOSEOUT_WARN" -eq 1 ]; then echo "GATE: body close-out check passed with warnings (name them in your report)"; ship_result ship-gate PASS body-check-warned; exit 0; fi
    echo "GATE: body close-out check passed"; ship_result ship-gate PASS body-check; exit 0 ;;
  branch)
    [ "$HAS_PROT" -eq 1 ] && [ -n "$PROT" ] || ship_die 2 usage "branch --protected '<ERE>' (the PROTECTED_BRANCHES slot; worked default ^(main|master|develop|release/))"
    [ "$PROT" != PROTECTED_BRANCHES ] || ship_die 2 usage "--protected was given the slot NAME, not its value: substitute PROTECTED_BRANCHES"
    BR=$(ship_branch); [ -n "$BR" ] || halt detached-head "HEAD is detached: ship from a branch"
    printf '%s\n' "$BR" | grep -E -q -- "$PROT"; RC=$?
    [ "$RC" -le 1 ] || ship_die 2 usage "--protected is not a valid ERE (grep rc=$RC)"
    [ "$RC" -eq 1 ] || { git worktree list; halt protected-branch "'$BR' matches PROTECTED_BRANCHES: this skill never ships from it"; }
    MB=$(ship_merge_base) || ship_die 3 merge-base-unresolved "git merge-base HEAD $(ship_base_ref) failed: fetch the base branch"
    DS=$(git diff --stat "$MB") || ship_die 3 git-unreadable "git diff failed"
    SS=$(git status --porcelain) || ship_die 3 git-unreadable "git status failed"
    if [ -z "$DS" ] && [ -z "$SS" ]; then git worktree list; halt nothing-to-ship "nothing of this branch's own to ship from this worktree (a wrong-worktree signal)"; fi
    echo "GATE: branch '$BR' ok"; ship_result ship-gate PASS branch; exit 0 ;;
  ci-skip-label)
    # The CI_SKIP_LABEL gate: the label tells CI the local tier already ran, so it may only follow a full local tier that
    # passed on exactly the committed tree; a stale or narrower gate can never authorize the skip. Never in OFFLOAD.
    ship_require_mode
    [ "$SHIP_MODE" = local ] || halt offload-never "OFFLOAD never applies the CI-skip label: its absence is what makes the draft PR's CI run for real"
    OUT=$(bash "$SHIP_BIN/ship-sentinel.sh" verify phase1 --committed 2>&1); RC=$?
    printf '%s\n' "$OUT" | grep '^PHASE1:'
    case "$RC" in 0) ;; 3) ship_die 3 phase1-unreadable "the Phase-1 reader could not compute" ;; *) halt phase1-invalid "the local tier did not pass on this committed tree" ;; esac
    echo "GATE: the CI-skip label may be applied to this head"; ship_result ship-gate PASS ci-skip-label-ok; exit 0 ;;
  flip)
    need_pr; ship_require_mode
    flip_checks
    # The flip only (never the enqueue's re-check: after the flip OFFLOAD does not read Phase 1, so a conflict push while
    # queued is re-watched by CI, not re-run locally).
    [ -f "$SHIP_STATE/ship-phase1-passed" ] || halt phase1-absent "no Phase-1 sentinel (a base sync removes it): re-run the 1c tasks and write phase1 (Step 2e-c)"
    if [ "$CHECK_ONLY" -eq 1 ]; then echo "GATE: flip preconditions hold for PR $PR"; ship_result ship-gate PASS flip-check; exit 0; fi
    [ "$SHIP_MODE" = offload ] || ship_die 2 usage "flip is OFFLOAD only: a --local PR is created ready"
    if [ "$PR_DRAFT" = true ]; then
      gh pr ready "$PR" >>"$SHIP_LOG" 2>&1 || ship_die 3 ready-failed "gh pr ready $PR failed"
    fi
    ship_step_mark flipped >/dev/null 2>&1 || true
    ship_fixloop_log flipped "pr=$PR" "head=$(git rev-parse --short=12 HEAD)"
    echo "GATE: PR $PR is ready"; ship_result ship-gate PASS flipped; exit 0 ;;
  enqueue)
    need_pr; ship_require_mode
    command -v jq >/dev/null 2>&1 || ship_die 2 jq-missing "jq is required"
    [ ! -e "$SHIP_STATE/ship-no-merge" ] || halt no-merge "the user asked for no merge (ship-no-merge): the pause holds until they say to merge now; then remove the file and re-run"
    J=$(pr_json isDraft,title,body,labels) || ship_die 3 gh-unreadable "gh pr view $PR failed"
    [ "$(printf '%s' "$J" | jq -r .isDraft)" != true ] || halt draft "PR $PR is a draft: only the flip makes it ready"
    T=$(printf '%s' "$J" | jq -r .title)
    ! printf '%s\n' "$T" | grep -iEq -- "$CLOSE_RE" || halt title-closing-keyword "the PR title carries a closing keyword (the title becomes the merge commit's body): retitle with Refs #N"
    MB=$(ship_merge_base) || ship_die 3 merge-base-unresolved "git merge-base HEAD $(ship_base_ref) failed"
    MSGS=$(git log "$MB..HEAD" --format=%B) || ship_die 3 git-unreadable "git log failed"
    ! printf '%s\n' "$MSGS" | grep -iEq -- "$CLOSE_RE" || halt commit-closing-keyword "a branch commit message carries a closing keyword: reword to Refs #N and push with ship-push.sh --rewritten"
    BF=$(ship_mktemp); printf '%s\n' "$(printf '%s' "$J" | jq -r '.body // ""')" > "$BF" || ship_die 3 gh-unreadable "cannot buffer the live body"
    closeout_check "$BF"; rm -f "${BF:?}"
    flip_checks   # the flip preconditions minus Phase 1 (develop's enqueue re-check has none either)
    OUT=$(bash "$SHIP_BIN/ship-sentinel.sh" verify gates 2>&1); RC=$?
    printf '%s\n' "$OUT" | grep -E '^(REVIEW|E2E):'
    case "$RC" in 0) ;; 3) ship_die 3 gates-unreadable "the gate readers could not compute" ;; *) halt gate-invalid "the review or E2E gate does not pass for this tree (G6)" ;; esac
    MM=$(ship_cfg MERGE_METHOD direct)
    if [ "$MM" = queue ]; then
      QL=$(ship_cfg QUEUE_LABEL "") || QL=""; [ -n "$QL" ] || ship_die 2 usage "MERGE_METHOD=queue needs QUEUE_LABEL"
      if [ "$(printf '%s' "$J" | jq -r --arg l "$QL" '[.labels[]?.name] | index($l) != null')" = true ]; then
        echo "GATE: $QL is already on PR $PR: not re-stamped"; ship_result ship-gate SKIP label-present; exit 10
      fi
      gh pr edit "$PR" --add-label "$QL" >>"$SHIP_LOG" 2>&1 || ship_die 3 label-write-failed "gh pr edit --add-label failed"
      L=$(pr_json labels) || ship_die 3 gh-unreadable "label read-back failed"
      [ "$(printf '%s' "$L" | jq -r --arg l "$QL" '[.labels[]?.name] | index($l) != null')" = true ] || ship_die 3 label-not-applied "the write returned success but $QL is not on PR $PR"
      ship_step_mark enqueued >/dev/null 2>&1 || true; ship_fixloop_log enqueued "pr=$PR"
      echo "GATE: PR $PR enqueued ($QL read back)"; ship_result ship-gate PASS enqueued; exit 0
    fi
    case " $FLAGS " in *" --admin "*) ship_die 2 admin-refused "--admin bypasses branch protection: only on the user's instruction for this instance, run by hand" ;; esac
    # shellcheck disable=SC2086  # MERGE_FLAGS is a word list by design
    gh pr merge "$PR" $FLAGS >>"$SHIP_LOG" 2>&1 || { tail -5 "$SHIP_LOG"; ship_die 3 merge-failed "gh pr merge $PR failed"; }
    ship_step_mark enqueued >/dev/null 2>&1 || true; ship_fixloop_log merge-requested "pr=$PR"
    echo "GATE: merge requested for PR $PR"; ship_result ship-gate PASS merge-requested; exit 0 ;;
  *) ship_die 2 usage "usage: ship-gate.sh branch --protected '<ERE>' | ci-skip-label | flip --pr N [--check-only] | enqueue --pr N [-- <MERGE_FLAGS>]" ;;
esac
