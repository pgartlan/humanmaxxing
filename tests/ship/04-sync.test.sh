#!/usr/bin/env bash
# ship-sync: every documented outcome of syncing with the base branch, on real rebases, merges and stashes.
. "$(dirname "$0")/../lib.sh"
sync() { run bash "$B/ship-sync.sh" --contract=2 "$@"; }

# --- clean paths -------------------------------------------------------------------------------------------
t_fixture sync1 "DEFAULT_MODE=offload"
run bash "$B/ship-sync.sh" --contract=2
expect 1 'FAIL on-base-branch' "sync on the base branch is refused"
t_branch feat/7-x
t_init ""; expect 0 'ship-init PASS' "init"

sync; expect 0 'PASS synced rebased=0' "already in sync"
sync --continue; expect 2 'FAIL nothing-to-continue' "--continue with nothing pending is a usage error"

t_base_commit CHANGELOG.md base1
echo wip > lib/wip.ts; echo dirty >> lib/n.ts
sync; expect 0 'PASS synced rebased=1' "base advanced: clean rebase with uncommitted work"
check "untracked work survived the rebase" test -f lib/wip.ts
check "tracked uncommitted work survived the rebase" grep -q dirty lib/n.ts
check "no stash entry is left behind" test "$(git stash list | wc -l | tr -d ' ')" = 0
check "the branch now contains the base commit" git merge-base --is-ancestor origin/main HEAD
git checkout -q lib/n.ts; rm -f lib/wip.ts

# --- rebase conflict ---------------------------------------------------------------------------------------
t_base_commit lib/u.ts conflict-base
echo conflict-feat > lib/u.ts; git commit -qam "feat u"
sync; expect 4 'rebase-conflict' "a conflicting commit stops the rebase"
expect_out '^CONFLICT_FILES:' "and lists the conflicted files"
expect_out '^lib/u.ts$' "by path"
sync; expect 1 'FAIL sync-pending' "a second sync while one is pending is refused"
t_init ""; expect 1 'FAIL sync-pending' "init while a sync is pending resets nothing"
sync --continue; expect 4 'still-conflicted' "--continue before resolving waits"
echo resolved > lib/u.ts; git add lib/u.ts
sync --continue; expect 0 'PASS synced' "--continue after resolving completes the sync"

# --- conflict markers --------------------------------------------------------------------------------------
sync scan-conflicts; expect 0 'PASS' "scan-conflicts on a clean tree"
printf '<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> b\n' > lib/bad.c
sync scan-conflicts; expect 1 'FAIL conflict-markers' "an untracked file with real markers is found"
expect_out '^lib/bad.c:1:' "with file:line"
rm -f lib/bad.c
printf 'Title\n=======\n' > docs/y.md
sync scan-conflicts; expect 0 'PASS' "markdown is excluded (setext headings)"
rm -f docs/y.md
printf 'Title\n=======\n' >> docs/x.md
sync scan-conflicts; expect 0 'PASS' "an uncommitted setext heading in a tracked markdown file is not a marker"
printf '<<<<<<< HEAD\n' >> docs/x.md
sync scan-conflicts; expect 1 'FAIL conflict-markers' "an unambiguous marker in markdown is still found"
git checkout -q docs/x.md
echo '=======' >> lib/n.ts
sync scan-conflicts; expect 1 'FAIL conflict-markers' "a separator line added to a code file is found in the diff"
git checkout -q lib/n.ts
printf '# ============ banner ============\nx=1\n' > lib/banner.sh
sync scan-conflicts; expect 0 'PASS' "a banner of equals signs is not a marker"
rm -f lib/banner.sh
printf '<<<<<<< HEAD\nx\n>>>>>>> b\n' > "lib/sp ace.c"
sync scan-conflicts; expect 1 'FAIL conflict-markers' "an untracked file with a space in its name and real markers is found"
expect_out '^lib/sp ace.c:1:' "and is named with its space intact"
rm -f "lib/sp ace.c"
printf 'Title\n=======\n' > notes-setext.md
sync scan-conflicts; expect 0 'PASS' "an untracked markdown setext heading is not a marker"
rm -f notes-setext.md
printf '<<<<<<< HEAD\n' > notes-marker.md
sync scan-conflicts; expect 1 'FAIL conflict-markers' "an untracked markdown file with an unambiguous marker is found"
rm -f notes-marker.md
printf '<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> b\n' > lib/committed.c; git add lib/committed.c; git commit -qm "oops markers"
sync scan-conflicts; expect 1 'FAIL conflict-markers' "markers in a committed code file are found"
git reset -q --hard HEAD~1
# Fail closed: an untracked file that cannot be read is scan-failed (exit 3), never a clean PASS. Root ignores modes, so skip then.
if ! t_can_unreadable; then t_skip "an unreadable untracked file: chmod cannot take read access away here (root, or Windows)"
else
  printf 'x\n' > lib/unreadable.c; chmod 000 lib/unreadable.c
  sync scan-conflicts; expect 3 'FAIL scan-failed' "an unreadable untracked file fails closed"
  expect_out 'unreadable untracked file: lib/unreadable.c' "and names the file"
  rm -f lib/unreadable.c
fi

# --- merge-only content (exit 8), the merge route, the audit -----------------------------------------------
t_fixture sync2 "DEFAULT_MODE=offload"
t_branch feat/8-y
t_init ""
t_base_commit CHANGELOG.md m1
git merge -q --no-edit origin/main
t_base_commit CHANGELOG.md m2
sync; expect 8 'FAIL merge-only-content' "a branch carrying a merge commit is never rebased"
check "nothing was rebased" test -z "$(git status --porcelain)"
echo dirty >> lib/n.ts
sync --merge; expect 0 'PASS' "--merge takes the merge route with a dirty tree"
check "uncommitted work survived the merge" grep -q dirty lib/n.ts
check "no stash entry is left behind" test "$(git stash list | wc -l | tr -d ' ')" = 0
git checkout -q lib/n.ts
sync; expect 0 'PASS synced rebased=0' "after the merge the branch is in sync"
sync audit; expect 4 'WAIT merges-present-audit-required' "any merge commit requires the audit, even with nothing identical to a parent"
# A hand resolution that keeps neither side whole matches no parent: the old audit read that as clean (exit 0).
git checkout -q -b audit2 origin/main
echo "base side" > lib/u.ts; git commit -qam "base side"; BASESIDE=$(git rev-parse HEAD)
git checkout -q feat/8-y
echo "branch side" > lib/u.ts; git commit -qam "Refs #8 branch side"
git merge -q --no-edit "$BASESIDE" >/dev/null 2>&1; echo "half of each" > lib/u.ts; git add lib/u.ts; git commit -qm "Refs #8 merge" --no-edit
git update-ref refs/remotes/origin/main "$(git merge-base HEAD origin/main)"   # keep the merge-base before both merges
sync audit; expect 4 'merges-present-audit-required|audited-suspicious' "a partial hand resolution is never 'clean'"
expect_out '^  BOTH_SIDES: lib/u.ts$' "and lists the both-sides file for the audit"
git reset -q --hard HEAD^
git merge -q --no-edit -s ours "$BASESIDE"
sync audit; expect 4 'FAIL audited-suspicious' "a resolution that dropped one side entirely is suspicious"
expect_out 'BOTH_SIDES: lib/u.ts IDENTICAL_TO_PARENT1' "named as identical to parent 1"
git fetch -q origin

# --- autostash re-apply conflict (exit 5) on a merge-free branch -------------------------------------------
t_fixture sync3 "DEFAULT_MODE=offload"
t_branch feat/9-z
t_init ""
t_base_commit lib/n.ts base-n
echo local-n > lib/n.ts
sync; expect 5 'autostash-conflict' "uncommitted work that conflicts with the new base is exit 5, not success"
expect_out '^AUTOSTASH:' "and prints the stash entry that holds the work"
check "the stash entry was preserved" test "$(git stash list | wc -l | tr -d ' ')" = 1
echo resolved-n > lib/n.ts; git add lib/n.ts
sync --continue; expect 0 'PASS synced' "--continue after resolving"
expect_out 'DROP-HINT' "and prints the drop hint for the preserved entry"
git reset -q; git checkout -q lib/n.ts; git stash drop -q

# --- another session pushed this branch --------------------------------------------------------------------
git push -q -u origin feat/9-z
sync; expect 0 'PASS synced' "in sync after the first push"
git clone -q "$FIX/origin.git" "$FIX/other"
( cd "$FIX/other" && git checkout -q feat/9-z && echo o > lib/o.ts && git add -A && git commit -qm "Refs #9 other" && git push -q origin feat/9-z ) || exit 2
sync; expect 1 'FAIL remote-branch-unseen' "commits this clone never saw are not overwritten"
sync --integrate-remote; expect 0 'PASS' "--integrate-remote brings them in"
check "the other session's commit is now local" test -f lib/o.ts
sync; expect 0 'PASS synced' "and the plain sync then passes"
sync --integrate-remote; expect 10 'SKIP already-integrated' "a second integrate is a skip"

git checkout -q --detach
sync; expect 2 'FAIL detached-head' "sync on a detached HEAD is refused"

# --- Phase 1 across syncs: old task results never count for the new base ---------------------------------------
t_fixture p1sync "DEFAULT_MODE=local"
t_branch feat/9-s
t_init ""; expect 0 'ship-init PASS' "init (phase1 sync)"
sync; expect 0 'PASS synced' "sync"
phase1() { run bash "$B/ship-sentinel.sh" --contract=2 write phase1; }
lint() { run bash "$B/ship-run.sh" --contract=2 start lint -- true; }
lint; phase1; expect 0 'PASS phase1-written' "phase1 written"
t_base_commit lib/base.ts b1
sync; expect 0 'PASS synced rebased=1' "a clean sync onto a moved base"
phase1; expect 1 'FAIL tasks-not-green' "the task results from the old base do not count"
lint; phase1; expect 0 'PASS phase1-written' "re-running the tasks re-earns it"

t_base_commit lib/u.ts conflict-base
echo conflict-feat > lib/u.ts; git commit -qam "Refs #9 u"
sync; expect 4 'rebase-conflict' "a conflicting sync"
run bash "$B/ship-sentinel.sh" --contract=2 fingerprint --phase1
expect 3 'FAIL fingerprint-error' "the check binding refuses a tree with unmerged paths"
expect_out 'unmerged paths' "and says so"
phase1; expect 3 'FAIL reader-error' "phase1 cannot be written mid-conflict"
echo resolved > lib/u.ts; git add lib/u.ts
sync --continue; expect 0 'PASS synced' "the conflict resolved"
check "the Phase-1 sentinel is gone" test ! -f "$ST/ship-phase1-passed"
phase1; expect 1 'FAIL tasks-not-green' "the old results still do not count"
lint; phase1; expect 0 'PASS phase1-written' "re-running re-earns it"
run bash "$B/ship-push.sh" --contract=2; expect 0 'ship-push PASS' "and the local push goes through"

git clone -q "$FIX/origin.git" "$FIX/other9"
( cd "$FIX/other9" && git checkout -q feat/9-s && echo other >> lib/n.ts && git commit -qam "Refs #9 other" && git push -q origin feat/9-s ) || exit 2
sync; expect 1 'remote-branch-unseen' "another session pushed this branch"
sync --integrate-remote; expect 0 'ship-sync PASS' "its commit is integrated"
phase1; expect 1 'FAIL tasks-not-green' "integrated commits make the old task results stale too"

t_done
