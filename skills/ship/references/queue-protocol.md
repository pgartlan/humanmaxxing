# Merge queue — enqueue, the watcher, the dequeue protocol, conflicts while queued

Applies with `MERGE_METHOD=queue` (a label enqueues; a bot or the host's queue merges). The worked example is a label-driven third-party queue with batch drafts; the host's native merge queue behaves the same way in the parts that matter here. With `MERGE_METHOD=direct` only "Conflicts before merge" and the post-merge section apply.

## Enqueue

Enqueue is the `QUEUE_LABEL`, applied once and read back. Three rules:

1. **Never a plain merge on a queue-governed base.** It direct-merges and bypasses every batch check.
2. **Never re-stamp a label that is already on the PR.** Most queues keep a per-SHA failure memory; re-labeling resets it and the same red re-runs forever. (One PR reached sixty-three CI runs this way.) **Never use the provider's force-queue command**: it admits a PR that failed the admission conditions. A green, labeled PR that the queue never picks up (`NEVER_QUEUED`, 12 minutes) gets ONE re-evaluate nudge; a second is a diagnosis, not another nudge.
3. **The label goes on LAST**: green → `ship-gate.sh flip` → `ship-gate.sh enqueue` (the only path that labels). A push after the label fires a synchronize event that strips it and invalidates the result.

## The watcher

`ship-watch.sh queue` reads the PR's `state`, `mergeable`, head SHA and labels on every poll, and `QUEUE_STATE_CMD` when configured. A red queue outcome is a *successful* watch (exit 0 with a verdict); a non-zero exit always means the watcher itself needs attention. Re-arm on TIMEOUT until a terminal verdict; the watcher never labels and never requeues.

**Polling `state` alone is insufficient.** A queue-ejected PR stays OPEN, so a state-only watch runs silently to its timeout. The watcher reads `mergeable` and surfaces CONFLICTING after two consecutive reads.

## The dequeue protocol (MANDATORY on any dequeue signal)

Diagnose BEFORE acting. The ship stays open until it merges.

1. **Verify it is a real dequeue.** Queue labels drift and race (`queued` and `dequeued` have been on one PR at the same instant). Use the provider's authoritative state: a status comment's payload, a check-run's output (`QUEUE_STATE_CMD` wraps it). Authoritative `queued` plus a `dequeued` label is a stale label: re-arm the watcher.
2. **Read the REASON, not just the fact.** The queue's check-run or comment names what failed: a specific condition, a conflict, a checks timeout. Classify before touching anything:
   - **Your check failed on the batch**: label it (failure-triage.md) and fix through the Step 4.5 route: census of the failed batch run(s), label, one push through `ship-push.sh --kind fix`. `FLAKE` → the one verified requeue below.
   - **The batch was cancelled, bisection blamed a sibling, or your PR was collateral**: at most ONE requeue. If it dequeues again without your checks ever failing, something structural is wrong (a flapping sibling, a config change) and more requeues only cancel more batches: wait for the base to advance (bounded, 60 minutes), re-sync, push `--kind rebase`, diagnose the batch draft. On expiry with the base unchanged there is nothing to push: re-enqueue through the normal path (if the label is already on, keep the bounded wait armed and report; no extra comment, no new ask) and log `auto-decision class=dequeue-wait-expired`.
   - **Conflict**: "Conflicts while queued" below.
3. **When the reason names NO check and your PR looks green, the failure is on the BATCH DRAFT: read the draft's job logs.** Added after a full day of queue babysitting failed to find a one-line config bug. A generic "conditions not satisfied / failing checks" message with no check named is not "nothing is wrong": a condition failed on the batch draft, a different, ephemeral PR the queue opens to test the combined change set and later deletes. Your PR's own check list shows green and is the wrong surface. The mechanism: a job gated on a path filter *skips* on your PR (a skipped required context reports green) but runs for real on the batch draft, which diffs the COMBINED change set of every PR in the batch and is far likelier to trip the filter. Green by skip on the PR, dead on the batch. This is the most expensive trap in this file: an agent polling PR status sees green, sees `dequeued`, requeues, and loops forever. Find the batch draft PR the queue's comment names, list its failed runs, read those job logs, then `bash .claude/skills/ship/bin/ship-census.sh --contract=2 --sha <draft head sha>` builds the census from them.
4. **One diagnosis-backed requeue maximum.** Then fix code or escalate. A new SHA resets the queue's failure memory and, after the strip, re-runs your gates; re-add the label only once they are green again. Log `auto-decision class=dequeue-repush`.
5. **Classify BLOCKING vs ADVISORY against the real union**: the queue's own conditions plus the base branch's protection contexts. Reading only one list produces a false red or a false green.

## Conflicts while queued

A queued PR can flip to CONFLICTING the instant another PR merges ahead of it, and the queue ejects it. The common cause is a sibling PR that touched the same append-heavy shared artifact (a baseline JSON, a registry array, generated API types, an enum table). If this PR's diff touches such an artifact, expect a queue conflict and plan for at least one re-resolve cycle; the first enqueue is not terminal.

1. Keep the `step5` monitor running through the ENTIRE queued wait. Skipping it is how a queued CONFLICTING PR goes unnoticed for tens of minutes.
2. On CONFLICTING: re-sync (Step 0.7's script, never a hand-rolled rebase: it records the lease), resolve each file per the merge protocol (for a shared append-array the resolution is the union of both sides' entries, never `--ours`/`--theirs`), re-run the lint that owns the shared artifact, in `--local` re-earn Phase 1 (the re-sync made it stale), push `--kind conflict` (the PR is already ejected, so a leased force push is correct here; a raw force-push would leave the lease stale), re-check G6, re-enqueue, re-arm the watch. Repeat until merged.

## Conflicts before merge (both methods)

G5a scans tracked files and the uncommitted diff for git's real markers, anchored (exactly seven characters followed by end of line or whitespace), because a banner comment of equals signs once read as a conflict. Markdown, text and `docs/` are excluded (setext headings). G5b reads `mergeable`; a reading older than two minutes is stale before an enqueue.

## Override

Bypassing the queue or branch protection (`--admin`) is only on the user's explicit instruction for that specific instance. Never offer it as a routine step.

## After MERGED

Close-out order matters: issues first (a red post-merge run never holds a close), then the post-merge CI watch on the base to green, then the in-session close-out steps, then fix-PR closure, then the ledger archive, then cleanup. Cleanup deletes the per-worktree state everything before it reads, and refuses unless the PR reads MERGED, so a pause or a queued PR keeps its state.
