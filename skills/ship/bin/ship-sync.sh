#!/usr/bin/env bash
# ship-sync.sh — Step 0.7: rebase onto origin/<BASE_BRANCH> FIRST, with --autostash, before any check fires; plus the
# merge-resolution audit and the conflict-marker scan.
#
#   ship-sync.sh --contract=N                 fetch, record the remote branch tip (the push lease), rebase --autostash.
#   ship-sync.sh --contract=N --continue      after you resolved a conflict (exit 4) or an autostash re-apply conflict (exit 5).
#   ship-sync.sh --contract=N audit           merge-commit audit over merge-base..HEAD (BOTH_SIDES / IDENTICAL_TO_PARENT lines);
#                                             exit 0 `no-merges` only · 4 any merge commit: `merges-present-audit-required`
#                                             (audit every BOTH_SIDES file) or `audited-suspicious` (one is identical to a
#                                             parent: another side's change was dropped) · 3 a read failed.
#   ship-sync.sh --contract=N scan-conflicts  git's real conflict markers in tracked files and the uncommitted diff.
#   ship-sync.sh --contract=N --integrate-remote   after exit 1 remote-branch-unseen: fetch origin/<branch>, rebase --autostash onto it
#                                             (exits 4/5 as above on conflict), record the lease. The next push passes --remote-integrated.
#   ship-sync.sh --contract=N --merge         the exit-8 route with uncommitted work: ONE scripted stash (SHA captured in the same
#                                             process), `git merge origin/<base>`, re-apply by SHA, drop only on a clean re-apply.
#                                             Exit 0 merged · 4 merge conflict (resolve, `git commit`, re-run the plain sync) · 5 the
#                                             re-apply conflicted (AUTOSTASH: <sha>; resolve, then drop via the printed hint).
#
# Why --autostash and never a hand-rolled stash: the stash stack is shared by every worktree of a bare clone and every
# session on the box; `git stash pop` can restore ANOTHER session's work into your tree and delete it from theirs.
# --autostash records its own entry's SHA and re-applies THAT. Three outcomes, three exits:
#   0  clean rebase, clean re-apply (or already up to date).            `rebased=1|0 onto=<sha>` recorded.
#   4  a rebase conflict; the rebase is left in progress (CONFLICT_FILES: listed). Resolve hunk by hunk, `git add`, --continue.
#   5  `autostash-conflict`: the rebase FINISHED (git exit 0) but the re-apply conflicted (UU: files; AUTOSTASH: <sha>). Your
#      work is safe in that stash entry. Resolve, `git add`, --continue; drop the entry ONLY via the DROP-HINT --continue prints.
#      Also `unmerged-paths`: the index already held UU files before any rebase; resolve, then re-run WITHOUT --continue.
#   6  HEAD is not on the fetched tip after the rebase: investigate, do not re-rebase by hand.
#   8  `merge-only-content`: the branch carries merge commits. A rebase would flatten them and can silently drop merge-only
#      content. Nothing was rebased. Take the merge route: `git merge origin/<base>`, then re-run (already in sync → audit).
#   1  `sync-pending` (a conflicted sync from an earlier run is unresolved: --continue it) · `remote-branch-unseen` (origin/<branch>
#      has commits this clone never saw: another session pushed the same branch; integrate them, re-run, and the first push is
#      --remote-integrated) · `rebase-aborted` (--continue after you aborted: record cleared, run plain again).
#   3  fetch or a git read failed (never "nothing to sync").
# After exit 0 the COEDITED: lines name files changed on BOTH sides: verify each hunk by hand (a clean auto-merge can drop a
# change when both sides edit the same function; never "fix" an apparent revert by copying content back from the base).
# EXIT-CODES: 0 1 2 3 4 5 6 8
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-sync
BASE=$(ship_base_branch) || ship_die 2 base-branch-unset "BASE_BRANCH unset"; BASE_REF="origin/$BASE"
CONTINUE_PTR="bash \"$SHIP_BIN/ship-sync.sh\" --contract=$SKILL_CONTRACT --continue"
PENDING="$SHIP_STATE/ship-sync-pending"
MARKER_RE='^(<{7}|={7}|>{7}|\|{7})([[:space:]]|$)'

finish_sync() {  # $1 = old merge-base, $2 = fetched tip, $3 = old HEAD (pre-rebase), $4 = rebased (0|1)
  local mb; mb=$(git merge-base HEAD "$2" 2>/dev/null) || ship_die 3 merge-base-unresolved "merge-base HEAD $2 unreadable"
  [ "$mb" = "$2" ] || { echo "HEAD is not on the fetched tip $2 (merge-base $mb)"; ship_result ship-sync FAIL head-not-on-tip; exit 6; }
  ship_write_atomic "$SHIP_STATE/ship-rebased-onto" "$2" || ship_die 2 write-failed "ship-rebased-onto"
  # was-rebased is sticky for the ship: a second, no-op sync must not downgrade it (ship-push.sh decides the lease from history anyway)
  if [ "$4" -eq 1 ] || [ "$(sed -n 1p "$SHIP_STATE/ship-was-rebased" 2>/dev/null)" = 1 ]; then ship_write_atomic "$SHIP_STATE/ship-was-rebased" 1 || ship_die 2 write-failed "ship-was-rebased"
  else ship_write_atomic "$SHIP_STATE/ship-was-rebased" 0 || ship_die 2 write-failed "ship-was-rebased"; fi
  rm -f "$PENDING"
  if [ "$4" -eq 1 ] && [ -n "$1" ] && [ -n "$3" ]; then
    local a b co
    a=$(ship_mktemp); b=$(ship_mktemp)
    git diff --name-only "$1" "$2" 2>/dev/null | LC_ALL=C sort -u > "$a"
    git diff --name-only "$1" "$3" 2>/dev/null | LC_ALL=C sort -u > "$b"
    co=$(LC_ALL=C comm -12 "$a" "$b"); rm -f "${a:?}" "${b:?}"
    [ -z "$co" ] || printf '%s\n' "$co" | sed 's/^/COEDITED: /'
  fi
  # A sync onto a moved base forces the full 1c re-run (every task result is stale). The OFFLOAD flip reads an ABSENT
  # Phase 1 as "re-earn it"; a fix round leaves it present (CI is that round's re-check), a sync never does.
  if [ "$4" -eq 1 ]; then bash "$SHIP_BIN/ship-sentinel.sh" invalidate phase1 >/dev/null 2>&1 || ship_die 2 write-failed "could not invalidate the Phase-1 sentinel after the sync"; fi
  ship_step_mark sync >/dev/null 2>&1 || true
  ship_fixloop_log sync "rebased=$4" "onto=$(printf '%.12s' "$2")"
  echo "SYNC: ok rebased=$4 onto=$2"
}

case "${1:-}" in
  scan-conflicts)
    # Two passes: all four marker forms outside prose files; only the unambiguous <<<<<<< / >>>>>>> forms everywhere (a run of
    # equals signs is a legitimate setext underline in markdown). Tracked files, the uncommitted diff, AND untracked files.
    OUT=$(git grep -nE "$MARKER_RE" -- . ':(exclude)*.md' ':(exclude)*.txt' ':(exclude)docs/**' 2>"$SHIP_STATE/logs/scan.err"); RC=$?
    [ "$RC" -le 1 ] || { cat "$SHIP_STATE/logs/scan.err"; ship_result ship-sync FAIL scan-failed; exit 3; }
    OUT2=$(git grep -nE '^(<{7}|>{7})([[:space:]]|$)' -- '*.md' '*.txt' 'docs/**' 2>>"$SHIP_STATE/logs/scan.err"); RC=$?
    [ "$RC" -le 1 ] || { cat "$SHIP_STATE/logs/scan.err"; ship_result ship-sync FAIL scan-failed; exit 3; }
    # The uncommitted diff, same two-pass rule: every marker form in code paths, only <<<<<<< / >>>>>>> in prose paths.
    D=$(git -c core.quotePath=false diff HEAD -- . ':(exclude)*.md' ':(exclude)*.txt' ':(exclude)docs/**' 2>"$SHIP_STATE/logs/scan.err") || { cat "$SHIP_STATE/logs/scan.err"; ship_result ship-sync FAIL scan-failed; exit 3; }
    D2=$(git -c core.quotePath=false diff HEAD -- '*.md' '*.txt' 'docs/**' 2>"$SHIP_STATE/logs/scan.err") || { cat "$SHIP_STATE/logs/scan.err"; ship_result ship-sync FAIL scan-failed; exit 3; }
    DOUT=$(printf '%s\n' "$D" | grep -nE "^\+(<{7}|>{7}|={7}|\|{7})([[:space:]]|$)"); RC=$?
    [ "$RC" -le 1 ] || { echo "grep failed on the uncommitted diff (rc=$RC)"; ship_result ship-sync FAIL scan-failed; exit 3; }
    DOUT2=$(printf '%s\n' "$D2" | grep -nE "^\+(<{7}|>{7})([[:space:]]|$)"); RC=$?
    [ "$RC" -le 1 ] || { echo "grep failed on the uncommitted prose diff (rc=$RC)"; ship_result ship-sync FAIL scan-failed; exit 3; }
    [ -z "$DOUT2" ] || DOUT=$(printf '%s\n%s\n' "$DOUT" "$DOUT2" | grep .)
    # Untracked files, one grep per file so the name is always printed (-H) and a read error is never "clean".
    UOUT=""
    UFILES=$(git -c core.quotePath=false ls-files --others --exclude-standard 2>"$SHIP_STATE/logs/scan.err") || { cat "$SHIP_STATE/logs/scan.err"; ship_result ship-sync FAIL scan-failed; exit 3; }
    while IFS= read -r uf; do
      [ -n "$uf" ] || continue
      [ -f "$uf" ] || continue   # a nested repository is listed as "dir/", a dangling symlink has no content: nothing to scan
      case "$uf" in *.md|*.txt|docs/*) URE='^(<{7}|>{7})([[:space:]]|$)' ;; *) URE="$MARKER_RE" ;; esac
      UHIT=$(grep -HnE "$URE" -- "$uf" 2>"$SHIP_STATE/logs/scan.err"); RC=$?
      [ "$RC" -le 1 ] || { cat "$SHIP_STATE/logs/scan.err"; echo "unreadable untracked file: $uf"; ship_result ship-sync FAIL scan-failed; exit 3; }
      [ -z "$UHIT" ] || UOUT=$(printf '%s\n%s\n' "$UOUT" "$UHIT" | grep .)
    done <<UFILES_EOF
$UFILES
UFILES_EOF
    if [ -n "$OUT" ] || [ -n "$OUT2" ] || [ -n "$DOUT" ] || [ -n "$UOUT" ]; then
      [ -z "$OUT$OUT2" ] || { echo "MARKERS in committed files:"; printf '%s\n%s\n' "$OUT" "$OUT2" | grep . | head -30; }
      [ -z "$DOUT" ] || { echo "MARKERS in the uncommitted diff:"; echo "$DOUT" | head -30; }
      [ -z "$UOUT" ] || { echo "MARKERS in untracked files:"; echo "$UOUT" | head -30; }
      ship_result ship-sync FAIL conflict-markers; exit 1
    fi
    echo "SCAN: clean"; ship_result ship-sync PASS no-markers; exit 0 ;;
  audit)
    MB=$(ship_merge_base) || ship_die 3 merge-base-unresolved "merge-base with $BASE_REF unresolved: fetch first"
    MERGES=$(git rev-list --merges "$MB..HEAD" 2>/dev/null) || ship_die 3 rev-list-failed "git rev-list failed"
    [ -n "$MERGES" ] || { echo "AUDIT: no merge commits"; ship_result ship-sync PASS no-merges; exit 0; }
    # Any merge commit means the model audits it: a hand resolution that kept HALF of one side's hunk matches no parent,
    # so "no file identical to a parent" is not "clean". The script only produces the evidence; every parent is audited
    # (an octopus merge like a two-parent one), against the merge-base of ALL parents, and every read fails closed.
    SUSPICIOUS=0; NFILES=0; D=$(mktemp -d "${TMPDIR:-/tmp}/ship-audit.XXXXXX") || ship_die 3 mktemp-failed "mktemp failed"
    for m in $MERGES; do
      PARENTS=$(git rev-list --parents -n 1 "$m" 2>/dev/null) || { rm -rf "${D:?}"; ship_die 3 rev-list-failed "cannot read the parents of $m"; }
      PARENTS=${PARENTS#* }
      # shellcheck disable=SC2086  # parent SHAs, one word each
      PB=$(git merge-base --octopus $PARENTS 2>/dev/null) || { rm -rf "${D:?}"; ship_die 3 merge-base-unresolved "no merge-base for the parents of $m"; }
      echo "MERGE: $(printf '%.12s' "$m") $(git log -1 --format=%s "$m")"
      : > "$D/all"; n=0
      for p in $PARENTS; do
        n=$((n+1))
        git -c core.quotePath=false diff --name-only --no-renames "$PB" "$p" > "$D/p$n" || { rm -rf "${D:?}"; ship_die 3 diff-unreadable "git diff $PB $p failed"; }
        LC_ALL=C sort -u "$D/p$n" >> "$D/all" || { rm -rf "${D:?}"; ship_die 3 diff-unreadable "sort failed"; }
      done
      # files changed on at least two parents
      LC_ALL=C sort "$D/all" | uniq -d > "$D/both" || { rm -rf "${D:?}"; ship_die 3 diff-unreadable "uniq failed"; }
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        NFILES=$((NFILES+1))
        bm=$(git rev-parse -q --verify "$m:$f" 2>/dev/null || echo deleted)
        tag=""; i=0
        for p in $PARENTS; do
          i=$((i+1)); bp=$(git rev-parse -q --verify "$p:$f" 2>/dev/null || echo deleted)
          if [ "$bm" = "$bp" ]; then
            # identical to parent i while another parent's version differs: that side's change was dropped entirely
            for q in $PARENTS; do bq=$(git rev-parse -q --verify "$q:$f" 2>/dev/null || echo deleted); [ "$bq" = "$bp" ] || { tag="$tag IDENTICAL_TO_PARENT$i"; break; }; done
          fi
        done
        echo "  BOTH_SIDES: $f$tag"; [ -z "$tag" ] || SUSPICIOUS=$((SUSPICIOUS+1))
      done < "$D/both"
    done
    rm -rf "${D:?}"
    echo "AUDIT: merges=$(echo "$MERGES" | wc -l | tr -d ' ') files=$NFILES suspicious=$SUSPICIOUS — audit every BOTH_SIDES file (did the merge keep every side's change?), report under 'Merge Resolution Audit' in the PR body; flag IDENTICAL_TO_PARENT files 'Needs Manual Review'"
    if [ "$SUSPICIOUS" -eq 0 ]; then ship_result ship-sync WAIT merges-present-audit-required "files=$NFILES" "suspicious=0"; exit 4; fi
    ship_result ship-sync FAIL audited-suspicious "files=$NFILES" "suspicious=$SUSPICIOUS"; exit 4 ;;
  --integrate-remote)
    BR=$(ship_branch); [ -n "$BR" ] || ship_die 2 detached-head "HEAD is detached"
    git fetch origin "$BR" > "$SHIP_STATE/logs/fetch.log" 2>&1 || { cat "$SHIP_STATE/logs/fetch.log"; ship_result ship-sync FAIL fetch-failed; exit 3; }
    RTIP=$(git rev-parse "origin/$BR" 2>/dev/null) || ship_die 3 base-unreadable "origin/$BR unreadable after fetch"
    git merge-base --is-ancestor "$RTIP" HEAD 2>/dev/null && { echo "INTEGRATE: origin/$BR is already in HEAD"; ship_result ship-sync SKIP already-integrated; exit 10; }
    echo "INTEGRATE: commits on origin/$BR not in HEAD:"; git log --oneline "HEAD..origin/$BR" | head -20
    OLD_HEAD=$(git rev-parse HEAD)
    ship_write_atomic "$PENDING" "$(git merge-base HEAD "$RTIP")" "$RTIP" "$OLD_HEAD" "" || ship_die 2 write-failed "ship-sync-pending"
    GIT_EDITOR=true git rebase --autostash "$RTIP" > "$SHIP_STATE/logs/rebase.log" 2>&1; RC=$?
    STASH=$(grep -oE 'Created autostash: [0-9a-f]{7,40}' "$SHIP_STATE/logs/rebase.log" | head -1 | awk '{print $3}')
    [ -z "$STASH" ] || STASH=$(git rev-parse --verify -q "$STASH" 2>/dev/null || echo "$STASH")
    ship_write_atomic "$PENDING" "$(git merge-base "$OLD_HEAD" "$RTIP")" "$RTIP" "$OLD_HEAD" "$STASH" || true
    if [ "$RC" -ne 0 ]; then echo "CONFLICT_FILES:"; git diff --name-only --diff-filter=U | head -40; echo "Resolve, git add, then: $CONTINUE_PTR"; ship_result ship-sync FAIL rebase-conflict; exit 4; fi
    UU=$(git diff --name-only --diff-filter=U); [ -z "$UU" ] || { echo "UU:"; echo "$UU"; echo "AUTOSTASH: ${STASH:-unknown}"; ship_result ship-sync FAIL autostash-conflict; exit 5; }
    rm -f "${PENDING:?}"
    ship_write_atomic "$SHIP_STATE/ship-remote-branch-sha" "$RTIP" || ship_die 2 write-failed "ship-remote-branch-sha"
    ship_fixloop_log auto-decision class=remote-integrated "tip=$(printf '%.12s' "$RTIP")"
    echo "INTEGRATE: done; now re-run the plain sync, and pass --remote-integrated on the next push"
    ship_result ship-sync PASS integrated; exit 0 ;;
  --merge)
    UU=$(git diff --name-only --diff-filter=U); [ -z "$UU" ] || { echo "UU:"; echo "$UU"; ship_result ship-sync FAIL unmerged-paths; exit 5; }
    git fetch origin "$BASE" > "$SHIP_STATE/logs/fetch.log" 2>&1 || { cat "$SHIP_STATE/logs/fetch.log"; ship_result ship-sync FAIL fetch-failed; exit 3; }
    STASH=""
    if [ -n "$(git status --porcelain)" ]; then
      git stash push -u -m "ship-merge-$$" > "$SHIP_STATE/logs/stash.log" 2>&1 || ship_die 3 stash-failed "git stash push failed; nothing merged"
      STASH=$(git stash list --format='%H %gs' | awk -v t="ship-merge-$$" 'index($0, t){print $1; exit}')
      _ship_hex40 "$STASH" || ship_die 3 stash-unlocated "stash entry not found by tag; your work is in the stash list (ship-merge-$$); nothing merged"
      echo "STASHED: $STASH (ship-merge-$$)"
    fi
    GIT_EDITOR=true git merge --no-edit "$BASE_REF" > "$SHIP_STATE/logs/merge.log" 2>&1; RC=$?
    if [ "$RC" -ne 0 ]; then
      echo "CONFLICT_FILES:"; git diff --name-only --diff-filter=U | head -40
      echo "Resolve every hunk (a shared append-list is the UNION of both sides), git add, git commit, then re-run the plain sync."
      [ -z "$STASH" ] || echo "Your uncommitted work is in stash $STASH: after the merge commit, git stash apply $STASH (apply, never pop), then drop THAT entry by SHA."
      ship_result ship-sync FAIL merge-conflict; exit 4
    fi
    if [ -n "$STASH" ]; then
      if git stash apply "$STASH" > "$SHIP_STATE/logs/stash-apply.log" 2>&1 && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
        e=$(git stash list --format='%H %gd' | awk -v s="$STASH" '$1==s{print $2}'); [ -n "$e" ] && git stash drop "$e" >/dev/null 2>&1
        echo "RESTORED: uncommitted work re-applied; stash entry dropped"
      else
        echo "UU:"; git diff --name-only --diff-filter=U; echo "AUTOSTASH: $STASH (your work is safe there; resolve the markers, git add, then drop ONLY that entry:"
        echo "  e=\$(git stash list --format='%H %gd' | awk -v s=$STASH '\$1==s{print \$2}'); [ -n \"\$e\" ] && git stash drop \"\$e\" || echo 'nothing dropped')"
        ship_result ship-sync FAIL autostash-conflict; exit 5
      fi
    fi
    ship_fixloop_log auto-decision class=flatten-avoided
    echo "MERGED: $BASE_REF merged into $(ship_branch); re-run the plain sync (it will report in sync and you then run audit)"
    ship_result ship-sync PASS merged; exit 0 ;;
  --continue)
    [ -f "$PENDING" ] || ship_die 2 nothing-to-continue "no sync is pending; run without --continue"
    OLD_MB=$(sed -n 1p "$PENDING"); TIP=$(sed -n 2p "$PENDING"); OLD_HEAD=$(sed -n 3p "$PENDING"); STASH=$(sed -n 4p "$PENDING")
    if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
      UU=$(git diff --name-only --diff-filter=U); [ -z "$UU" ] || { echo "CONFLICT_FILES:"; echo "$UU"; echo "still unresolved: resolve, git add, then: $CONTINUE_PTR"; ship_result ship-sync FAIL still-conflicted; exit 4; }
      GIT_EDITOR=true git rebase --continue > "$SHIP_STATE/logs/rebase-continue.log" 2>&1; RC=$?
      if [ "$RC" -ne 0 ]; then
        UU=$(git diff --name-only --diff-filter=U)
        if [ -n "$UU" ]; then echo "CONFLICT_FILES:"; echo "$UU"; echo "resolve, git add, then: $CONTINUE_PTR"
        else echo "git rebase --continue failed without a conflict:"; tail -5 "$SHIP_STATE/logs/rebase-continue.log"; echo "an empty commit after resolution is usual: git rebase --skip, then: $CONTINUE_PTR"; fi
        ship_result ship-sync FAIL rebase-conflict; exit 4
      fi
    fi
    if ! git merge-base --is-ancestor "$TIP" HEAD 2>/dev/null; then
      rm -f "$PENDING"; echo "the rebase was aborted (HEAD is not on $TIP): record cleared, run the plain sync again"
      ship_result ship-sync FAIL rebase-aborted; exit 1
    fi
    UU=$(git diff --name-only --diff-filter=U)
    [ -z "$UU" ] || { echo "UU:"; echo "$UU"; echo "AUTOSTASH: ${STASH:-unknown}"; ship_result ship-sync FAIL autostash-conflict; exit 5; }
    finish_sync "$OLD_MB" "$TIP" "$OLD_HEAD" 1
    if [ -n "$STASH" ] && _ship_hex40 "$STASH"; then
      echo "DROP-HINT (only after you have verified the resolved tree; drops ONLY your entry, never stash@{0} blind):"
      echo "  e=\$(git stash list --format='%H %gd' | awk -v s=$STASH '\$1==s{print \$2}'); [ -n \"\$e\" ] && git stash drop \"\$e\" || echo 'nothing dropped'"
    fi
    ship_result ship-sync PASS synced "rebased=1"; exit 0 ;;
  '')
    [ ! -f "$PENDING" ] || ship_die 1 sync-pending "a conflicted sync is pending: resolve it, git add, then re-run with --continue (or git rebase --abort, then --continue once to clear)"
    BR=$(ship_branch); [ -n "$BR" ] || ship_die 2 detached-head "HEAD is detached"
    [ "$BR" != "$BASE" ] || ship_die 1 on-base-branch "you are on $BASE itself; ship runs on a feature branch"
    UU=$(git diff --name-only --diff-filter=U); [ -z "$UU" ] || { echo "UU:"; echo "$UU"; ship_result ship-sync FAIL unmerged-paths; exit 5; }
    git fetch origin "$BASE" "$BR" > "$SHIP_STATE/logs/fetch.log" 2>&1 || git fetch origin "$BASE" > "$SHIP_STATE/logs/fetch.log" 2>&1 || { cat "$SHIP_STATE/logs/fetch.log"; ship_result ship-sync FAIL fetch-failed; exit 3; }
    TIP=$(git rev-parse "$BASE_REF" 2>/dev/null) || ship_die 3 base-unreadable "$BASE_REF does not exist after fetch"
    # Push lease: the REMOTE tip of this branch as it is right now, before any history rewrite. ship-push.sh leases on it.
    LSOUT=$(git ls-remote origin "refs/heads/$BR" 2>"$SHIP_STATE/logs/ls-remote.err") || { cat "$SHIP_STATE/logs/ls-remote.err"; ship_result ship-sync FAIL ls-remote-failed; exit 3; }
    REMOTE="${LSOUT%%[[:space:]]*}"; [ -n "$REMOTE" ] || REMOTE=absent
    # "Seen" = an ancestor of HEAD, OR in this branch's own reflog (our pre-rebase history), OR the tip this ship last
    # pushed. Anything else is a commit this clone never had: another session pushed the same branch.
    SEEN=0
    if [ "$REMOTE" = absent ] || git merge-base --is-ancestor "$REMOTE" HEAD 2>/dev/null; then SEEN=1
    else
      REFLOG=$(git rev-list -g "refs/heads/$BR" 2>/dev/null); case "$REFLOG" in *"$REMOTE"*) SEEN=1 ;; esac
    fi
    if [ "$SEEN" -eq 0 ]; then
      [ "$(sed -n 1p "$SHIP_STATE/ship-remote-branch-sha" 2>/dev/null | tr -d '[:space:]')" = "$REMOTE" ] && SEEN=1
    fi
    if [ "$SEEN" -eq 0 ]; then
      echo "origin/$BR is at $REMOTE, which is not in your history: another session pushed this branch."
      echo "Integrate without asking: git fetch origin $BR; git log --oneline HEAD..origin/$BR; git rebase origin/$BR (resolve per the merge protocol); re-run this pointer."
      echo "The first push after that passes --remote-integrated (it breaks the review chain on purpose: a review must cover those commits)."
      ship_result ship-sync FAIL remote-branch-unseen; exit 1
    fi
    ship_write_atomic "$SHIP_STATE/ship-remote-branch-sha" "$REMOTE" || ship_die 2 write-failed "ship-remote-branch-sha"
    OLD_MB=$(git merge-base HEAD "$TIP" 2>/dev/null) || ship_die 3 merge-base-unresolved "merge-base unresolved"
    OLD_HEAD=$(git rev-parse HEAD)
    MERGES=$(git rev-list --merges "$OLD_MB..HEAD")
    if [ "$OLD_MB" = "$TIP" ]; then finish_sync "" "$TIP" "" 0; ship_result ship-sync PASS synced "rebased=0"; exit 0; fi
    if [ -n "$MERGES" ]; then
      echo "$MERGES" | while read -r m; do echo "MERGE-ONLY: $(printf '%.12s' "$m") $(git log -1 --format=%s "$m")"; done
      echo "This branch carries merge commits; a rebase would flatten them and can silently drop merge-only content."
      echo "Take the merge route: git merge $BASE_REF (resolve per the merge protocol), then re-run this pointer. Log auto-decision class=flatten-avoided."
      ship_result ship-sync FAIL merge-only-content; exit 8
    fi
    ship_write_atomic "$PENDING" "$OLD_MB" "$TIP" "$OLD_HEAD" "" || ship_die 2 write-failed "ship-sync-pending"
    GIT_EDITOR=true git rebase --autostash "$TIP" > "$SHIP_STATE/logs/rebase.log" 2>&1; RC=$?
    STASH=$(grep -oE 'Created autostash: [0-9a-f]{7,40}' "$SHIP_STATE/logs/rebase.log" | head -1 | awk '{print $3}')
    [ -z "$STASH" ] || STASH=$(git rev-parse --verify -q "$STASH" 2>/dev/null || echo "$STASH")
    ship_write_atomic "$PENDING" "$OLD_MB" "$TIP" "$OLD_HEAD" "$STASH" || true
    if [ "$RC" -ne 0 ]; then
      UU=$(git diff --name-only --diff-filter=U)
      echo "CONFLICT_FILES:"; echo "$UU" | head -40
      echo "Resolve every hunk (never --ours/--theirs on whole files), git add, then: $CONTINUE_PTR   Abandon: git rebase --abort (restores autostashed work)."
      ship_result ship-sync FAIL rebase-conflict; exit 4
    fi
    UU=$(git diff --name-only --diff-filter=U)
    if [ -n "$UU" ]; then
      echo "UU:"; echo "$UU"; echo "AUTOSTASH: ${STASH:-unknown} (your uncommitted work is safe in that entry)"
      echo "Resolve the markers, git add, then: $CONTINUE_PTR   Drop the entry only via the DROP-HINT --continue prints."
      ship_result ship-sync FAIL autostash-conflict; exit 5
    fi
    finish_sync "$OLD_MB" "$TIP" "$OLD_HEAD" 1
    ship_result ship-sync PASS synced "rebased=1"; exit 0 ;;
  *) ship_die 2 usage "usage: ship-sync.sh [--continue] | --integrate-remote | --merge | audit | scan-conflicts" ;;
esac
