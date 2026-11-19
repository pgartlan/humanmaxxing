# Failure triage — no self-classified reds, the census, labels, fold-in

Narrative behind SKILL.md Step 2b and Step 4.5 items 3a, 3c, 3d, 3e.

## No self-classified reds

The most expensive failure class in a ship is not a bug, it is a *classification*: the agent reads a red result, decides it "doesn't count", and ships past it. Every one of these has happened and each was a true description of where the red came from:

- "it's pre-existing" — the base branch was red before this branch existed
- "it's not in my diff" — the failing test imports a file this PR never touched
- "the base branch's CI doesn't gate this check" — true, and the check still found a bug
- "it's just lint / cosmetic"
- "it's repo-wide debt, not mine"
- "fixing it would sprawl scope"

None of them is a reason to leave the red. The rule has exactly two exits and no third:

1. **You make it green.** For a suspected flake, re-run that one test in isolation (bounded, or through `REMOTE_TEST_DISPATCH`); an isolated green is proof of flake and goes in the PR body.
2. **It is also red on the base branch, and you fix it by the written rule.** Attribution is a *diagnostic*, not a carve-out: it decides where the fix lands.

Proceeding past a red without one of those two outcomes is a process bug, identical in class to an autonomous commit.

We once let thirty-seven "not mine" test failures accumulate across a month of ships; the day the base branch had to go green for a release, two engineers lost a weekend to findings every one of those ships had seen and classified away.

## Fold-in rules

Fold, never split: as few PRs as possible. A small unrelated fix (any number of them) is folded into THIS PR with a body note `folded base-side fix (authored here, <files>)`. Only a genuinely large fix goes elsewhere, and then as a user-approved ticket, never as a surprise PR.

Base-side reds have a bound: **≤ 2 files AND ≤ 30 changed lines** → fold (the 3rd file or the 31st line takes the larger path). Already fixed in an open PR → copy ONLY that PR's hunks byte for byte at a recorded source SHA, within the same bound, note `folded base-side fix from #N @<sha> (byte-for-byte)`. Larger → a separate fix PR AND the identical fold here: the base is red for every branch, so the fix PR exists to green the base independently. This ship owns it: after MERGED, if its diff against the base is empty, close it "landed via #N"; otherwise it stays open under the `⚠️ ADDITIONAL PR REQUIRED` banner, never buried in a list.

Deferral is the rare exception and the user's call. Only a failure whose *fix itself* is externally blocked can be deferred: propose the ticket (title, exact fix, the specific blocker, the duplicate-search result) and wait for approval before any `gh issue create`. Even then the red still blocks THIS ship. Never file a "test-debt" ticket unilaterally and ship on top of red.

## The census (Step 4.5 3a)

Why a census and not "read the failed job's log": a PR's CI is several workflow runs at one SHA, and a single-run drill structurally cannot show the whole red set. The canonical failure: an orchestrator read one pooled lint job's log on rounds two and three, fixed what it saw, pushed, and re-discovered the same three findings from a sibling job on rounds two, three AND four: two whole CI rounds spent on findings that were already on screen. The census is the mechanical fix: every run at the SHA, every job concluded `failure`, `timed_out` or `action_required`, the FULL log through the jobs API (never the `--log-failed` reader, which silently truncates after one over-long line, and a dot-reporter test shard prints all its dots as one 500 KB line with the FAIL block after it), one block per job.

Block grammar (`SHIP_STATE/ship-census.txt`):

```
=== FAILED JOB: <job name>  (run <id>, job <id>, <conclusion>) → <log path>
required=yes|no|unknown   work=1|0   workflow=<name>   signature=<first failing line, numbers normalized>
<up to 20 excerpt lines>
```

`required=yes` when the job or workflow is in `REQUIRED_CHECKS`; `no` when the list is set and it is not; `unknown` when the list is unset, which counts as WORK (fail closed). `cancelled` is deliberately absent: at the watched SHA it means a newer push superseded the run, which the flip's SHA check handles. Only WORK blocks trigger a fix round; `work=0` blocks are REPORTED in the PR body under "Non-required reds" at every round and listed in the final report. A reported red is never "ignored".

## Labels (your judgment, recorded)

Precedence matters: label in this order, first match wins.
- **PR-CAUSED**: a finding whose file is in this PR's diff, full stop (the diff veto comes before any base check). Fix the root cause locally, in this push.
- **FLAKE**: infrastructure noise around the failure (runner death, network, timeout waiting for a resource), not an assertion, type error or lint violation. A timeout is FLAKE the first time and PR-CAUSED when it recurs. When the log is ambiguous, it is genuine. When EVERY WORK block is FLAKE, one re-run of that run's failed jobs at the same SHA (`--rerun --run <id>`, once per run id per ship); already re-run → relabel and fix. If a `PR_LABELS` entry makes CI skip jobs, a same-SHA re-run posts skip-passes for them: remove the label first or treat them as unverified.
- **BASE-SIDE**: the same finding reproduced at the base branch's tip, or its red job log read in full. "Also red on the base" in the PR body is a claim that needs that evidence, never a job-name match. The fold-in rules above, no ask. Before authoring the fix, look for an existing one (a base commit or an open PR touching the file): copy or rebase onto it, never re-author.
- **UNATTRIBUTED**: no signature can be derived. It gets the one re-run; if it reds again with no derivable signature the round is not converging, and that is the only path in the fix loop that reaches the user (class `cap`, with the run URL).

Fix the union of every WORK block, verify each fix with the narrowest bounded local run that exists (never the whole gate; a full local lint run was measured at 22 minutes on our repo and contended with the CI shards being waited on: calibrate yours), then push ONCE. A fix that could not be verified is listed in the PR body as `unverified: <what>`: zero tests selected is unverified, never green; a non-zero runner exit with zero tests executed is RED. Read a job's own result line, not the scariest string: CI echoes a step's source before running it (an `::error::` in the echoed source is not an error), and baseline-mode lints print grandfathered notes that are not failures.

## Pre-push and the round gate (3c)

A push cancels every in-flight run at the old SHA and restarts them on the new one. Pushing while a required job is still running makes its findings arrive a whole round late (about a third of the rounds in one measured ship). `--pre-push` asks two questions right before the push: did a required red appear that the census did not see (exit 5: re-census, fix it too), and is a required run still in progress (exit 4: keep fixing, re-run).

The round gate is mechanical because a prose rule ("third round-trip, switch to local") was ignored four rounds in a row. Ten fix pushes are allowed (`FIX_ROUND_CAP`); the eleventh is the user's decision, asked neutrally (continue another ten, switch to `--local`, stop), never the agent's. The counter records its branch; a restart on the same branch keeps it (a cap that forgets is no cap), `--fresh` or another branch resets it, and the user hears the count in the SAME message as the push or the halt, never inside a wall of shell output. A census whose WORK blocks are all FLAKE (re-run) or whose WORK count is zero is not a round; only a fix push is.

## Blocking questions (3d)

A permission question once sat unanswered for an hour while three already-visible findings sat unread. A question never blocks the census: ask only for a class on the question list, write it to `PENDING_QUESTIONS_FILE` if configured, keep working every other block, keep a bounded wait armed.

## Review of a fix push (3e)

A fix push does not re-open the full review gate. The review call is yours and it is recorded on the push and in the PR body: the review-code skill's fix-delta mode for a focused fix (where available), the full review for a PR-level change or a complex area. Edit first, review, push last. Never push a blind patch; never re-run hoping for a different answer.
