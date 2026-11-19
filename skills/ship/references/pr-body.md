# PR body — template, release-action blocks, close-out sections, the docs subagent

`PR_TEMPLATE` points here. Edit the template to your repo; the Step 2c structural check requires every `##` section below and no `<FILL …>` left.

## The rule

**A PR body is documentation. It is never a work queue.** "Follow up later", "validate after deploy", a to-do list, "at release we need to…" are banned: each item is either done now, in this PR or this session, or registered where your process tracks post-merge obligations (a `release-action` block when `RELEASE_ACTIONS=file-ledger`). An issue is never left open "to validate later": it closes at merge.

## Template

```markdown
## What and why
<FILL: one paragraph: the change and the problem it solves. Link the plan if there is one.>

Closes #<FILL: the issue this branch was started on — one bare line per issue>
Refs #<FILL: related issues found by the Step 1c search; or remove>

## Checks run
<FILL: pass/fail table from Step 2 — lint, typecheck, build, unit, scans, each conditional check; mode OFFLOAD|local;
 which checks CI runs on the draft; folded fixes with their notes>

## Review
<FILL: review mode (review-code sentinel fresh at <time> | manual attestation), fix-push reviews recorded per round>

## Real E2E ship gate
<FILL: E2E: FRESH <sentinel time> | EXEMPT <reason> — the critical paths touched, the specs that cover them, or the
 exemption category. 4.0b fills the final verdict; "in progress (CI)" is acceptable on a draft>

## Merge resolution audit
<FILL: "no merge commits" | per BOTH_SIDES file: kept both | Needs Manual Review>

## Non-required reds
<FILL: "none" | per reported red: job, signature, why it is not required; never deleted>

## Close-out
Post-merge, in-session: <FILL: steps this session executes after the merge, each marked (shared-env write) when it is one; or "none">
Release actions: <FILL: ids of the release-action blocks below, or "none">

## Ship arguments
<copied by file from SHIP_STATE/ship-args.txt; never pasted by hand>
```

A fix PR (title starts `fix`) also carries `class=<N sites>, recurrence=<M>`: a fix for one site of a pattern names the other sites it fixed (or why they are not sites).

## Closing keywords

`ISSUE_CLOSE_KEYWORD #N` (default `Closes`) appears **only in the PR body**, as a bare line. Commits and the PR title carry `Refs #N`. The host closes an issue named after a closing keyword *anywhere* in a commit message (mid-line too) the moment that commit reaches the default branch, past every gate; under a squash or queue merge the PR title becomes the merge commit's body. On a flow whose `BASE_BRANCH` is not the default branch that is a release-time auto-close nobody asked for. The Step 2c grep checks both directions.

## Release-action blocks (`RELEASE_ACTIONS=file-ledger`)

Anything the shipped code needs done in a target environment to function (an env var or secret it reads, a key or org that must exist, a migration that must precede the deploy) is `when: pre`: a release skill refuses the promotion while a `pre` action is open. Follow-up the code does not depend on, and verification that can only run after a deploy, is `when: post`. A cron's key refresh once shipped as `post` to production and failed every hour until someone noticed; it should have been `pre`.

````markdown
```release-action
{"id": "<issue>-<slug>", "when": "pre|post", "env": "<target environment or promotion>", "owner": "<team or person>",
 "action": "<exact command or steps>", "verify": "<how to see it is done>"}
```
````

The lint: any sentence in the body shaped like an obligation ("needs to", "must be", "remember to", "before deploying") that is not inside a block fails the ship. Two legitimate fixes: it is an action → make it a block; it is descriptive → annotate the line `<!-- doc-only: <why this needs no action, ≥10 chars> -->`. The doc-only escape is refused when its reason says the work is tracked "elsewhere" (an issue, a checklist, post-deploy verification): that work becomes a block. Never delete or reword a sentence to hide an obligation from the lint; the gap then exists in neither place. Harvest the blocks into the in-repo ledger before the Step 3 commit so the record ships with the code that created the obligation; a malformed block fails loud.

## The docs subagent (Step 1d)

Dispatch one subagent with a small model, `run_in_background: true`. Worked prompt when no checkpoint skill supplies one:

```
You are the documentation step of a ship. Read `git diff origin/<BASE_BRANCH>...HEAD` and `git status`. Write:
1. A changelog fragment at <CHANGELOG_FRAGMENT_DIR>/<branch-slug>.md: one entry, user-facing wording, the issue number.
2. A chat summary at <CHAT_SUMMARY_DIR>/<date>-<branch-slug>.md: what changed, why, decisions taken, what was deferred
   and where it is tracked. No command transcripts.
Do not edit code. Do not run checks. When finished, write the current epoch seconds to <ABS_SHIP_STATE>/ship-docs-done.
```

Substitute `<ABS_SHIP_STATE>` with the absolute path (`cd "$(git rev-parse --git-path ship-state)" && pwd`); a relative or unexpanded path makes the subagent write the sentinel somewhere else or nowhere, and Step 3 waits forever.
