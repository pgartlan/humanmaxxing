# Step 0.7 — sync with the base branch: rationale, outcomes, recovery

Mechanics: `bin/ship-sync.sh`. SKILL.md holds the exit-code reactions; this file holds the why.

## Rebase first

Rebase onto the base branch's tip **before** any check fires, so every Step 1–3 check runs against the already-rebased tree and there is no "did the sync invalidate the gate?" question left to answer. An earlier design synced *after* the checks and then re-ran a calculus over which checks the sync had invalidated (with full local test re-runs when it could not tell). That whole apparatus is deleted, not relocated. What remains, the base advancing *after* checks start, is handled by the conflict-only rule in OFFLOAD (the queue's speculative merge handles a clean advance) and by the check binding in both modes: Phase 1 and every task result bind to the whole working tree, so any later sync makes them stale and they are re-earned before the next `--local` push or the OFFLOAD flip.

## `--autostash`, never a hand-rolled stash

The stash stack is **shared** across every worktree of a bare clone and every agent session on the machine. A bare `git stash pop` can restore *another session's* work into your tree and delete it from theirs. `--autostash` is immune by construction: it records its entry's SHA and re-applies **that**, never whatever is on top of the stack. Verified on all three paths:

- **Clean rebase**: work restored (tracked and untracked), a competing session's entry untouched, no leftover entry.
- **Rebase conflict**: `git rebase --abort` re-applies the autostash and restores the tree; nothing stranded.
- **Re-apply conflict**: git prints "Your changes are safe in the stash" and **preserves** the entry; recover with `git stash apply <that sha>`.

Do not "improve" this into a manual `stash push` / restore pair. It was tried and is strictly worse: the capture and the restore land in two separate shell invocations, so the variable holding the SHA is empty when the restore reads it, the restore silently no-ops, and your work stays stashed. If git's own hint suggests `git stash pop` after a conflicted re-apply, use `git stash apply <sha>` instead.

## The three outcomes (why exit 4 and exit 5 differ)

1. A clean rebase plus a clean re-apply: git exit 0, genuinely done. Script exit **0**.
2. A rebase-commit conflict: git exits non-zero, the rebase is in progress. Resolve, `git add`, `--continue`; `--abort` bails out and restores any autostash. Script exit **4**.
3. A **clean rebase whose autostash re-apply conflicts**: git prints "Applying autostash resulted in conflicts" but still reports "Successfully rebased" with **exit 0**, leaving `UU` files and literal markers. Script exit **5**.

The `UU` check is gated on a zero rebase exit on purpose. A plain rebase conflict produces the identical `UU` signature with a non-zero code and an EMPTY autostash SHA; an ungated check prints the wrong message, and a remediation that greps the stash list for an empty SHA matches every entry, so `head -1` targets whatever is on top of the shared stack, quite possibly another session's work. The `DROP-HINT` is printed only with a non-empty SHA, only on `--continue`'s success (the exit-5 output is long gone by then, and a hint run earlier would delete the only copy of your work), and it looks the entry up by SHA and prints "nothing dropped" when absent rather than falling through to a bare `git stash drop`.

## Merge-only content (exit 8)

A branch that carries merge commits is never rebased by this skill. A rebase replays each commit's own diff; content that exists only in a merge resolution (the union of two appended entries, a hand-fixed import) has no commit of its own and is silently dropped. The safe direction is always the merge route: `git merge origin/<base>`, resolve, re-run the sync (now in sync), and let the audit report `BOTH_SIDES` files. Logged as `auto-decision class=flatten-avoided`.

## Remote branch unseen (exit 1)

`origin/<branch>` holds commits this clone never had: another session pushed the same branch. The lease the push uses is recorded here, before any rewrite, and it must be a tip you have seen (an ancestor of HEAD, in this branch's own reflog, or the tip this ship last pushed). Anything else is integrated first (`fetch`, inspect, `rebase origin/<branch>`), and the first push afterwards passes `--remote-integrated`, which deliberately breaks the review chain: those commits have not been reviewed by this ship.

## Co-edited files

After a rebase the script prints `COEDITED: <file>` for every path changed on both sides. Verify each hunk by hand: a clean auto-merge drops a change when both sides edited the same function and git picked one side without conflict. Never "fix" an apparent silent revert by copying content back from the base; find out which side is right. `COEDITED` compares paths only, so a file renamed upstream is checked by hand.

## Post-rebase lint

A hand-resolved conflict can orphan imports or leave misplaced symbols that lint catches immediately and CI surfaces twenty minutes later. Run `LINT_CI_CMD` right after any resolution, before pushing.

## Re-arming after a base advance

The monitor's exit 13 (the base advanced) ends the monitor. If you let the current gate finish rather than re-entering Step 0.7, re-arm the monitor with the printed `MONITOR_BASELINE` at once; otherwise conflict detection is blind for the rest of the wait.

## wip squash (optional)

If your agents commit `wip(<issue>): snapshot …` commits so a remote test runner can see the tree, fold them before the branch is first pushed as a PR, or every snapshot lands in the base branch. Safe recipe, ONLY when no open PR exists for the branch and the branch carries no merge commits: `git reset --soft "$(git merge-base HEAD origin/<base>)"`, then recommit as the real commit(s) with the real message(s) (`Refs #N` only). The tree is unchanged (`git diff` against the old HEAD is empty: check it). The remote branch, if present, is then not a fast-forward: push with `ship-push.sh --rewritten`, which leases on the recorded remote tip. With an open PR, skip the fold and say so in the PR body. A verifying script (tree identity, message identity, compare-and-swap ref update, backup ref) is a roadmap item.
