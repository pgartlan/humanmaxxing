#!/usr/bin/env bash
# ship-push: the plain first push, the leased push after a rebase, the review-chain requirement on fix pushes,
# the Phase-1 requirement in local mode, and the refusals (dirty tree, nothing to push, a lease the remote outran).
. "$(dirname "$0")/../lib.sh"
push() { run bash "$B/ship-push.sh" --contract=2 "$@"; }
sync() { run bash "$B/ship-sync.sh" --contract=2; }

t_fixture push1 "DEFAULT_MODE=offload" "CRITICAL_GLOBS_FILE=.claude/critical-paths.txt"
t_branch feat/7-x
t_init ""; expect 0 'ship-init PASS' "init (offload)"
sync; expect 0 'PASS synced' "sync records the remote state before any push"

echo dirty >> lib/n.ts
push; expect 7 'FAIL dirty-tree' "a dirty tree is never pushed"
git checkout -q lib/n.ts

push; expect 0 'ship-push PASS' "the first push of a new branch"
expect_out '^PUSHED:' "prints the PUSHED line"
refute_out '\(leased\)' "and is a plain push, not a leased one"
check "the remote branch is at HEAD" test "$(git rev-parse HEAD)" = "$(git rev-parse origin/feat/7-x)"
push; expect 6 'nothing-to-push' "a second push with nothing new"
check "nothing-to-push still marks the step done" sh -c "ls '$ST'/step-pushed* >/dev/null"

# A fix push names how the fix was reviewed; the chain then satisfies the review gate.
echo fix >> lib/u.ts; git commit -qam "fix: Refs #7"
push --kind fix --round 1; expect 2 'FAIL' "a fix push without --review is a usage error"
push --kind fix --round 1 --review manual; expect 0 'ship-push PASS' "a fix push with a recorded review"
check "the review chain was recorded" test -s "$ST/review-chain"

# Base advances: the rebased branch is pushed with a lease on the tip this clone last saw.
t_base_commit CHANGELOG.md base1
sync; expect 0 'PASS synced rebased=1' "rebase onto the advanced base"
sync; expect 0 'PASS synced' "a second sync does not lose the lease record"
push --kind rebase --review full; expect 0 'ship-push PASS' "the rebased branch pushes"
expect_out 'PUSHED:.*\(leased\)' "with a lease"
check "the remote branch is at HEAD after the leased push" test "$(git rev-parse HEAD)" = "$(git ls-remote origin refs/heads/feat/7-x | cut -f1)"

# The remote moves after the sync recorded its tip: the lease must reject, never overwrite.
t_base_commit CHANGELOG.md base2
sync; expect 0 'PASS synced rebased=1' "rebase again"
git clone -q "$FIX/origin.git" "$FIX/other"
( cd "$FIX/other" && git checkout -q feat/7-x && echo o > lib/o.ts && git add -A && git commit -qm "Refs #7 other" && git push -q origin feat/7-x ) || exit 2
OTHER="$(git ls-remote origin refs/heads/feat/7-x | cut -f1)"
push --kind rebase --review full; expect 5 'FAIL lease-rejected' "a remote that moved under the lease rejects the push"
check "the other session's commit is still the remote tip" test "$OTHER" = "$(git ls-remote origin refs/heads/feat/7-x | cut -f1)"

git checkout -q --detach
push; expect 1 'FAIL detached-head' "push on a detached HEAD is refused"

# --- local mode: Phase 1 is always required ----------------------------------------------------------------
t_fixture push2 "DEFAULT_MODE=local"
t_branch feat/8-y
t_init ""; expect 0 'ship-init PASS mode=local' "init (local)"
sync; expect 0 'PASS synced' "sync"
push; expect 1 'FAIL phase1-invalid' "local mode refuses a push with no Phase-1 sentinel"
run bash "$B/ship-run.sh" --contract=2 start lint -- true
run bash "$B/ship-sentinel.sh" --contract=2 write phase1
expect 0 'ship-sentinel PASS' "phase1 written"
push; expect 0 'ship-push PASS' "and the push goes through"
echo more >> lib/u.ts; git commit -qam "Refs #8 more"
push; expect 1 'FAIL phase1-invalid' "a commit after Phase 1 invalidates it"

# --- the untracked gate in offload mode, and an unreadable merge-base -------------------------------------------
t_fixture push3 "DEFAULT_MODE=offload"
t_branch feat/9-u
t_init ""; expect 0 'ship-init PASS' "init (offload, untracked)"
sync; expect 0 'PASS synced' "sync"
mkdir -p app/api/sub && echo x > app/api/sub/x.ts
TIP0=$(git ls-remote origin refs/heads/feat/9-u | cut -f1)
push; expect 7 'FAIL untracked-relevant' "the first push refuses an untracked file in a changed directory"
expect_out '^app/api/sub/x.ts$' "and names it"
check "nothing was pushed" test "$TIP0" = "$(git ls-remote origin refs/heads/feat/9-u | cut -f1)"
git add app/api/sub/x.ts && git commit -qm "Refs #9 x"
push; expect 0 'ship-push PASS' "committed, it goes through"
echo y > app/api/y.ts
push --kind fix --round 1 --review manual; expect 7 'FAIL untracked-relevant' "a fix push refuses it too"
rm -f app/api/y.ts
git update-ref -d refs/remotes/origin/main
push --kind fix --round 1 --review manual; expect 3 'FAIL merge-base-unresolved' "an unresolvable merge-base is exit 3 with its own reason, never 'nothing untracked'"
run bash "$B/ship-sentinel.sh" --contract=2 untracked; expect 3 'FAIL merge-base-unresolved' "for the untracked verb too"
run bash "$B/ship-sentinel.sh" --contract=2 verify phase1 --committed; expect 1 'FAIL phase1-absent' "verify reports its own state first"
git fetch -q origin

t_done
