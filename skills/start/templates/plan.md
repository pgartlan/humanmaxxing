# #<N> — <Ticket Title>

## Root Cause

**Confirmed intended behavior:** <what the affected surface is SUPPOSED to do, cited to an authoritative in-repo source: a docstring or contract, a requirements or architecture doc, a sibling that does it correctly, or an explicit design invariant. State this FIRST, before the diagnosis: a bug is only a bug relative to a verified intended behavior. Never infer it silently. When the fix flips or restores a behavior (turns a control on or off, changes a status code, re-scopes access), naming the intended behavior WITH a citation is what proves it is a defect and not the design. No citation found → write `UNCONFIRMED: <what you looked for>` here and ask the user before planning the fix.>

<Definitive 2–4 sentence diagnosis with file:line citations>

## Fix

<What changes, where, and why — concrete, not abstract. When the fix builds on an existing module that Step 4.6 found unreachable from live code, say here that the module has never run and is treated as unwritten.>

### Convergence preconditions

**(Include whenever the cause is "X should have happened and didn't" — a sync, a drain, a deploy, a retry, a schedule (Step 4 item 3). Omit otherwise.)**

| Path by which X fails to run or finish | Evidence | Disposition (fixed here / safe + evidence / out of scope + ticket) |
|---|---|---|
| <a job or step condition, a path filter, an upstream step that aborts the run, a missing retry or schedule, a stale pin, …> | <run, log line or file:line> | <…> |

## Implementation Steps

### Phase 1: <name>
- [ ] Step with file:line specificity

### Phase 2: <name>
- [ ] ...

### Data prerequisites

**(Mandatory: the literal `None` when the change needs no data written or made true in a shared environment before it merges.)** A merged change whose correctness depends on data being written first (a backfill, a regeneration of stored output, a seed row) goes red on its first deploy when that step lives only in plan prose. Per prerequisite:

- <prerequisite>: write `<command>`; verify (read-only) `<command>` → expect `<result>`. The command already exists on the integration branch, or runs only after the review of the script that does it. Evidence (output + timestamp) goes in the PR body, never back into this plan after review (a post-review plan edit changes the reviewed content).

## PRs

**(Mandatory. State the total PR count.)** Default:

PRs: 1 — this PR covers #<N>[, #<M>…]. Phases are commits in this PR, not separate PRs.

Every ticket this plan was started on, and every open child folded in, is closed by that one PR, through the bare `- Closes #<N>` lines in `## Close-out` below (this `PRs:` line is prose; it closes nothing). An additional PR is allowed ONLY for a hard blocker the code or the process forces; declare each one:

| Additional PR scope | Owns | Hard blocker | User-approved? |
|---|---|---|---|
| <scope> | #<N> | <blocker> | <yes / pending — surfaced in the Step 7 "Decisions needed"> |

- **A ticket in a row's Owns column is NOT closed by THIS PR.** This PR's `## Close-out` and PR body write `- Refs #<N>` for it, and that additional PR carries the closing line. The PR body also carries the banner naming it: `⚠️ ADDITIONAL PR REQUIRED (N total): <scope> — owns #<N> — blocker: <blocker>`.
- **Allowed blockers:** a different repository; an ordering constraint that needs a deploy or promotion in between (B can only merge after A is deployed); a protected-file change the user must make by hand; the user explicitly asked for a separate PR.
- **NOT reasons:** "easier to review", "keeps the diff small", "different theme", "phase 2", "follow-up".

## Testing

- [ ] Unit: <what and where>
- [ ] Integration: <scenario>
- [ ] Manual verification: <what to observe>

**If this is a BUG** — add all three of the following immediately after Testing:

### Why wasn't this caught?

<Which test, alarm, or review layer should have caught this and didn't — be specific. If no layer could have caught it, say why.

**First check whether it WAS caught and dismissed.** Search the tracker for earlier reports of the same symptom. If a detector fired and the reports were closed as noise, the honest answer is not "we lacked a detector", it is "the detector worked and the response failed", which is a different and more important defect. Say which.>

### Prevention

<Concrete changes so this class does not recur: a new test, alarm, lint rule, assertion, review-checklist item. At least one item must be a test or alarm that would have caught this specific bug had it existed. "Be more careful" is not acceptable.>

### Bug class & guard

<From Step 4.5: the class and the invariant violated; sibling sites found (or "none found beyond this site" / "widespread, enumeration truncated"); the guard and its scope. The fix fixes every sibling site AND lands the guard, or states the isolation argument. "Reviewers should watch for it" is not a guard.>

**If this is a FEATURE** — include:

### E2E Test Plan

<At least one end-to-end scenario through the full user-visible flow: the happy path, one error or edge case, and any sensitive surface (money, auth) touched. "Unit tests only" is not acceptable — name the scenario and what it asserts.>

### Simplest version considered

**(ALL plans — bug fixes and features alike.)**

<**Name the LAYER this fix sits at, then name at least ONE alternative layer you considered and why you rejected it.** The failure mode is anchoring: an author who asks "what is the smallest version of *my* approach?" answers within their own mechanism and never sees that a different chokepoint removes the need for it. Layers to scan: the call site · the shared helper · the config or wiring layer · the harness or lifecycle step that sets up the state · the **upstream point where the bad state is produced**. The last is the most often missed and the most likely to collapse the plan.

**Suppression check — apply it before accepting your own layer.** Read back every alternative you named. **If ALL of them change how the bad state is SEEN (a threshold, a metric, a routing rule, an alarm scope, a marker, a log level) and NONE changes the rate at which it is PRODUCED, you scanned one layer and called it a survey.** Go find the producer.

Then: the smallest change that satisfies the requirement, and why this plan does more. New surface (an abstraction, knob, layer, interface, column) is named WITH its first real caller; "useful later" is not a caller.

**"The plan IS the simplest version" is not an answer when the plan adds a module, a config key, an environment variable or a CI check:** a plan that adds surface has, by construction, an alternative that doesn't. Name it and say why it loses.

**If the plan adds machinery to make an unwanted operation safe (a mock, a stub, a gate, a guard, a suppression, a retry), say in one line why the operation cannot simply be prevented.** Removing the precondition is almost always smaller than simulating the operation.

Never counted as excess: class guards and sibling-site fixes, tests of any kind, error handling and logging, observability, tenancy and auth scoping.>

## Recurrence verdict

**(Include when Gate C ran — Step 2.95 fired, the ticket was closed before, or the signal is a fail-loud guard. Omit otherwise.)**

Recurrence-Verdict: #<N> <DOWN|FLAT|UP> — <mechanism>

One line per ticket, bare: no backticks, bullet or indent, an em dash before the mechanism. A DOWN verdict lets `## Close-out` say `- Closes #<N>`. FLAT or UP means the plan is not finished: revise it until the Gate C reviewer answers DOWN with a mechanism. `Refs #N` and "retitle the ticket to the remaining class" are not remedies.

### Falsifiable verification

**(Mandatory for a plan on a recurring or reopened ticket.)** State: (1) the **invariant** the fix establishes; (2) the **next concrete event** that tests it (a named job run, the next scheduled run, the next deploy of X); (3) **who checks it** — the shipping session observes it in-session with a bounded wait, or, when it can only be observed later, a post-merge obligation registered where your release process tracks them. "Observed naturally" or "we'll see if it recurs" is not acceptable.

## Risks & Adjacencies

- <Other code that calls into the changed path>
- <Any migration or cold-start concern>
- <Any sensitive surface touched>

## Out of Scope

- <Related things intentionally NOT addressed. Not remaining work of the tickets this plan closes: anything required to close one of them is in scope, not here.>

## Close-out

**(Mandatory. Every ticket this plan was started on closes when this PR merges; no keep-open, no ticket checklists.)**

- Closes #<N>

(One bare `- Closes #<N>` line per ticket and per folded-in child, each on its own line, with no backticks or bold: a closing keyword counts only at the start of a line. The exception: a ticket in a `## PRs` Owns column is `- Refs #<N>` here. Commit messages carry `Refs #N` only, never a closing keyword. With no tracker, the title is `# <the task in words>` and this line is `- Done at merge: <the task in words>`.)

- **Post-merge, in-session:** each step the shipping session runs and observes after the merge (a rollout, a flag flip, a smoke check), with the signal that proves it, or `none`. Mark every step that writes to a shared environment `(shared write)`: the user approves those at plan approval (Step 7 "Decisions needed").
- **Release obligations to register:** what must happen at a later promotion, registered where your release process reads them, or `none`.
