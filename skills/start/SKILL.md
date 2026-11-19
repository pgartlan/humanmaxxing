---
name: start
description: First thing in a new worktree — reads the ticket, verifies its claims against the actual code, finds the definitive root cause using parallel domain-investigation subagents, and proposes a reviewed plan.
user-invocable: true
allowed-tools: Bash(gh issue view *), Bash(git *), Bash(grep *), Bash(find *), Bash(cat *), Bash(ls *), Bash(jq *), Bash(test -f *), Bash(bash .claude/skills/start/bin/check-plan-sections.sh *), Bash(bash */.claude/skills/ship/bin/ship-sentinel.sh *), Read, Glob, Grep, Agent, Skill, ToolSearch, SendMessage, TaskCreate, TaskUpdate, TaskList, TaskGet
---

# /start — the kickoff pattern

The first thing you do in a fresh worktree, before writing any code: read the ticket, verify its diagnosis against the actual code (never trust the ticket's stated cause), find the definitive root cause with parallel investigation, check whether the work is already shipped, and produce a plan ready for review.

---

## Configuration — adapt these to your repo/tracker

```
INTEGRATION_BRANCH    — the branch shipped work lands on before promotion (e.g. develop, main)
ISSUE_CMD             — command that returns full ticket content: title, body, comments, state
                         (examples below assume `gh issue view` — swap for your tracker's CLI/API).
                         Empty when the repository has no tracker: the skill then takes a task
                         described in words (see "No tracker: a task in words")
BRANCH_ISSUE_PATTERN  — how branch names encode the ticket number (default: `{number}-{slug}`;
                         a bundle is `{n1}-{n2}-{slug}`, the worktree skill's naming)
WORKTREE_LAYOUT       — siblings | single. siblings (the default, and what the worktree skill, parallel
                         sessions and parallel ships are built on): every task has its own folder beside
                         the primary working copy. single (a fallback, never offered by onboarding; set it
                         here by hand): one checkout, branches switched in place, one agent session at a time
PLAN_DIR              — where kickoff plans are written (default: docs/plans/<ticket>-<slug>.md)
DOMAIN_AGENTS         — table: domain signal → investigation angle (Step 3b). One row per
                         domain-expert agent: its detection-table globs as the signal, the first
                         clause of its description as the angle
REPORT_CAP            — word cap per subagent report (defaults used below: 400 / 200)
```

**Companion skill (optional but recommended):** this skill hands its finished plan to a plan-review skill that runs a multi-perspective review (domain lenses, a zero-context pass, and ideally an external model) and returns a verdict. If you don't have one, Step 6 tells you to present the plan to the user directly instead.

---

## Design principles

1. **Orchestrate, don't investigate.** The main agent frames the hypothesis and adjudicates; subagents read, grep, and trace. Spend your own context on judgment, not file reads.
2. **The ticket is ground truth for the symptom, not the diagnosis.** Verify the reporter's stated cause against the code before planning on top of it — issues are frequently right about *what* broke and wrong about *why*.
3. **Parallel investigation, cross-talk when it might matter.** Dispatch domain lenses concurrently always; wire them into a real collaborating team (peer-to-peer messaging) when the ticket could span domains, and skip that overhead when it's narrow.
4. **Check whether it's already done before spending anything.** In a shared repo, a teammate or another session can ship the same fix while you're still reading the ticket. Investigation and planning are expensive; the check is cheap.
5. **Fix the class, not the instance.** Once you have a confirmed root cause, the sibling sites of the same bug shape are usually the highest-leverage finding left.
6. **Fail conservative on ambiguity.** If the premise or the root cause can't be confirmed, stop and ask rather than build a plan on an unconfirmed foundation.

---

## Usage

- `/start` — derive the ticket number from the current branch name
- `/start 123` — explicit ticket number
- `/start 123 124` — bundle two tickets into one plan
- `/start "the CSV export drops the last row"` — no tracker (`ISSUE_CMD` empty): a task in words

**No tracker: a task in words.** With `ISSUE_CMD` empty, the task the user describes stands in for
the ticket everywhere below: Step 0 takes it from the argument (no argument → ask the user to
describe the task; that is the Step 0 stop), Step 0.5 has nothing to claim and says so, Step 1
records the text as the ticket body, verbatim, and Step 1.5 searches the integration branch's
history and open branches for the same work by its key words instead of by a number. Plans are
named from a slug of the task (`PLAN_DIR/<slug>.md`), and nothing in the plan says "Closes #N".

---

## Pre-flight: are you in the right folder?

Before anything else, two reads:

```bash
git rev-parse --abbrev-ref HEAD
# Compare resolved paths: from a subdirectory git prints one of these absolute and the other relative.
[ "$(cd "$(git rev-parse --git-dir)" && pwd -P)" = "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)" ] && echo PRIMARY || echo LINKED
```

- `WORKTREE_LAYOUT = siblings` and you are on `INTEGRATION_BRANCH`, or in the primary working copy (`PRIMARY` in a non-bare repository) → **STOP.** Work never starts here. Tell the user to create the task's folder with the worktree skill (`/worktree <ticket>`), or its launcher, and run `/start` there. This skill creates nothing itself.
- `WORKTREE_LAYOUT = single` → print `Pre-flight: single-checkout layout, continuing on <branch>` and go on.
- `WORKTREE_LAYOUT` unset or `UNVERIFIED` → **STOP and ask** which layout this repository uses, then record the answer in Configuration. An unknown layout is never treated as permission to work in the primary copy.

> Anonymized story: an agent asked to begin a task switched the primary working copy to a new branch in place. Every other session and script that assumed that folder sat on the integration branch was then reading the wrong tree, and nothing said so.

---

## Step 0: Resolve ticket number(s)

If no argument, parse the leading number(s) from the branch name per `BRANCH_ISSUE_PATTERN`:

```bash
git rev-parse --abbrev-ref HEAD
```

If there's no leading number and no argument was passed, ask the user for the ticket number — this is one of only three acceptable early stops in this skill (the others are the pre-flight above and Step 1.5).

A bundled branch (`12-13-fix-login`) carries every leading number: take all of them, stopping at the first segment that is not a number.

Multiple numbers (space, `&`, or comma separated) → treat as a bundled multi-ticket plan and carry all of them through.

---

## Step 0.5: Claim the ticket (always)

Every ticket you start is claimed, whether the team is one person or a thousand: assigned to whoever started it, moved to in-progress, and commented with the branch or working path. The board then shows what is actually being worked on, and a second session (yours or anyone's) does not pick up the same ticket. If the worktree skill created this folder from the ticket number, its `ISSUE_CLAIM_CMD` has already done this: confirm it did (the ticket shows the assignee and the in-progress state) and go on. Otherwise do it now with your tracker's commands. A tracker with no status field still gets the assignee and the comment. A claim that fails is reported in your first message, never skipped silently; it does not block the investigation.

---

## Step 1: Fetch the ticket(s) — parallel

Fetch full content for every ticket number, plus recent history for context, in a single parallel batch:

```bash
ISSUE_CMD <number>     # e.g. gh issue view <number> --json number,title,body,labels,comments,assignees,state,stateReason
git log --oneline -20
```

Also read the ticket's history for an earlier close or reopen (the tracker's timeline; on GitHub, `stateReason` reads `REOPENED` on a reopened issue, and the comments usually name the PR that closed it): a ticket that was closed before feeds Gate B and Gate C (Step 2.95). Do not proceed until you have the ticket body — it's the primary input for everything downstream.

---

## Step 1.5: Already-shipped / in-flight guard (MANDATORY — runs before any discovery work)

**In a shared repo, another session or teammate may ship the same ticket while you're reading it.** Discovery, planning, review, and shipping are all expensive; running the full cycle on something already merged wastes hours and produces a duplicate branch with colliding migrations or files. Check this first, before spending anything.

> Anonymized story: a full kickoff → implement → review → ship cycle ran to completion on a ticket before the pre-merge sync revealed an identical fix had already landed via a parallel PR — including a colliding schema migration. The branch was a near-complete duplicate; only a small test-coverage delta was salvageable. The check below would have caught it before the first investigation subagent was dispatched.

**Probe (0) — when the ticket's subject IS a checker, run the checker FIRST.** When the ticket's central claim is the output of a lint, guard, parity check, ratchet or failing test ("N violations", "check X is red"), run that checker on the current tree before the git probes below. A fix can merge under an unrelated PR title, which no search below finds. Clean → re-read the cited file:line to confirm the fix is really there, then go to the Decision.

> **Guard against the inverse error: a clean checker run can also mean a BROKEN checker.** Before concluding "already fixed", run the checker's own fixture or regression suite as a positive control and confirm its FAIL fixtures still fail. A green result you did not positive-control is not evidence.

Fetch fresh refs and probe, for each ticket number:

```bash
git fetch -q origin "$INTEGRATION_BRANCH"
for N in <ticket-numbers>; do
  echo "=== #$N ==="
  # (1) ticket state (already have this from Step 1 — restate it here)
  # (2) merged or open PRs referencing this ticket, by title or body search
  # (3) commits on $INTEGRATION_BRANCH referencing the ticket — a merge to a non-default
  #     branch usually does NOT auto-close the ticket, so closed-state alone is insufficient
done
```

If a merged PR or an integration-branch commit looks like this ticket's fix, confirm by diffing the ticket's suspected touch-paths against the integration branch.

**Decision:**
- **Already merged** → STOP. Do not dispatch discovery or write a plan. Report what merged and where, and ask the user how to proceed — abandon, or scope only a genuine remaining delta (missing tests, a deferred follow-up). A positive-controlled clean run from probe (0) reaches this same decision, even when both searches come back empty and the ticket is still open.
- **Open PR in flight by someone else** → STOP and surface it — coordinate (review/extend their PR) rather than build a competing implementation.
- **No sign of prior work** → proceed to Step 2. State "Step 1.5: no prior/in-flight work found" in one line so the check is visible.

This is read-only verification — run it, don't ask permission. Skipping it to "save time" is what causes the duplicate-cycle failure above.

---

## Step 2: Initial read + keyword extraction

Read the ticket body and comments carefully. Extract:

1. **Stated symptoms** — what the reporter observed.
2. **Hypothesized cause** (if any) — what the reporter thinks is wrong.
3. **Affected paths** — files, modules, routes, jobs, tables, or client methods mentioned.
4. **Domain signals** — which parts of the system this touches.
5. **Ticket type** — classify as **bug** or **feature**. When ambiguous, prefer bug (a missing behavior that should have worked is a bug). Carry this classification through to Step 5.

Distill a 2–3 sentence **working hypothesis** for root cause — a concrete, falsifiable claim about the code, not a restatement of the symptom.

---

## Step 2.5: Ambiguity gate (ask NOW, before discovery — not after)

**If the ticket has a genuine interpretation fork, ask the user here, in one batch, before dispatching any Step 3 discovery.** A clarifying question asked after discovery can invalidate a whole round of subagent work and makes the user context-switch twice; asked here it costs one early interruption while they are still engaged.

**A genuine fork:** two or more plausible readings of the ticket that lead to *different fixes, different components, or different scope* — "retry the sync" could mean the whole job or the per-item call; an expected-vs-actual that could each be defended as intended behavior. Batch every fork into one question set.

**Not a fork (do not ask):** anything resolvable by reading the code or the ticket's comments, a choice where one reading is clearly strained, or implementation decisions the plan will surface for review. Most tickets have no fork: state "Step 2.5: no interpretation fork" in one line and go on.

---

## Step 2.9: Premise-validation gate (MANDATORY for enhancement/hardening tickets)

**This skill validates the root cause of a STATED defect; it does not, by itself, question whether the ticket's premise holds.** A ticket that adds capability on top of an existing feature — auto-retry, a new alarm, a backfill, a reconciler, "harden X" — assumes X already works end-to-end. Running the full discovery → plan → review cycle to automate a feature that has never completed wastes it and ships an enhancement that reliably automates a broken outcome.

**Trigger:** the ticket enhances/hardens/automates an existing feature rather than fixing that feature's own reported misbehavior. ("X returns the wrong value" is a normal bug — skip this gate. "X has no retry" is an enhancement — run it.)

**Two probes, before any discovery:**
1. **Empirical** — query the actual data, state, or logs (not just the code) for whether the underlying happy path has ever completed end-to-end, including its downstream side effect landing.
2. **Trace the full happy path once**, end to end, not just the step the ticket touches — confirm every hop reaches its downstream effect.

**Decision:**
- **Works end-to-end** → state the evidence in one line, proceed to Step 3.
- **Never worked, or a hop never reaches its downstream effect** → **STOP.** Surface the break (file:line + evidence) to the user and ask how to proceed. This is an acceptable early stop, same class as Step 1.5.

> Anonymized story: a full team kickoff planned auto-retry for a background execution feature. A downstream break was surfaced mid-review and initially mis-filed as "adjacent, out of scope." A later empirical probe showed the executions completed their own step but never reached the downstream system meant to consume them — dozens of them, zero ever landed. Auto-retry would have automated a broken outcome. The probe belonged here, before discovery — not bolted on after a reviewer happened to notice.

A "the core thing never reaches its downstream effect" finding is a **premise-breaker**, not an out-of-scope adjacency, no matter where it surfaces later — even mid-review. Treat it as a stop-and-question and return to this gate, don't file it as a footnote and keep planning the enhancement.

---

## Step 2.95: Anti-masking gate (MANDATORY for alarm / flagged-row / "noisy signal" tickets)

**An alarm ticket hands you a consumer-side artifact — a metric, a threshold, a routing rule — as the entry point. Fixes there are small, verifiable in seconds, and answer the ticket's literal question. Fixing the *producer* means tracing an unfamiliar upstream path. That asymmetry is why an agent reliably optimizes the alarm instead of the thing the alarm is true about.** This gate breaks it.

**Trigger:** the ticket's subject is a firing alarm, a metric threshold, a count of flagged or bad rows, or any "this signal is noisy" framing — or one of Gate B's and Gate D's own triggers below.

Run every gate whose trigger holds. At the step that fires one, Read [`references/anti-masking-gates.md`](references/anti-masking-gates.md) for the procedure and the stories.

- **Gate A** — the subject is a firing alarm, a metric threshold or a count of flagged rows: trend the underlying POPULATION (bucket by creation time) before any plan; a GROWING population means an alarm-config fix is MASKING. For an alarm, also find WHICH process wrote the datapoint before trusting the emitter the alarm text names.
- **Gate B** — the root cause cites a prior fix commit, OR the ticket was closed before (Step 1's history): reproduce the prior fix through the least-scaffolded invocation, and say why the prior closure didn't hold before proposing anything.
- **Gate C** — one reviewer gets the TICKET, not the plan, and answers whether the number goes UP, FLAT or DOWN (dispatched in Step 6).
- **Gate D** — the signal is a deliberate fail-loud guard (a refusal, a stale-version error, "refusing to…", a drift check): investigate the upstream convergence mechanism that should have kept the invariant true, not the guard, its alarm or its message.

State each fired gate's result in one line before Step 3 ("Gate A: flat at ~N/month since <date> — config fix licensed"); "Step 2.95: not a signal ticket" when none fires.

---

## Step 3: Root-cause discovery — team (default) or isolated-parallel (opt-out)

- **Option A — collaborating team (DEFAULT).** Domain agents run concurrently AND message each other during investigation, so a cross-domain root cause surfaces that no isolated agent would catch.
- **Option B — isolated-parallel (OPT-OUT).** Same agents, no cross-talk — cheaper and just as thorough when there's nothing to correlate across domains.

State which you chose and why in one line before dispatching. **Opt out to B when ANY hold:** single file/domain; disposition is unambiguous (duplicate, config gap, threshold tweak); the ticket already pinpoints file:line and cause (this step becomes verification, not discovery); a simple mechanical fix. Default to the team otherwise — it's a deliberate call, not a quiet shortcut. Either way you still orchestrate and synthesize; the choice only changes how the subagents are wired.

### Option A — collaborating team

Constraints for a real collaborating agent team (generalize to your harness's team-orchestration primitives): investigation is **read-only** (read/grep/trace in the current worktree, no separate checkout); every member must **load its own coordination tools first** — put that as literally the first instruction in every member prompt, or cross-talk is structurally impossible; peer-to-peer messages are usually **invisible in your own transcript** — read them from wherever your harness persists them (e.g. per-member inbox files) during synthesis (Step 4); **retire investigation members** before spawning reviewers into the same team — a graceful shutdown captures their cost.

**Spawn members concurrently in ONE parallel batch**, unique name each, background: one **codebase-navigator** ([3a](#3a--codebase-navigator-agent)); one **domain-investigator** per matching signal from your domain table ([3b](#3b--domain-investigator-agents)) — wrap a general-purpose agent with the domain lens injected in the prompt, not a narrow named agent that lacks coordination tools (it would silently degrade to no-cross-talk and defeat the point of Option A); one **zero-context "fresh eyes"** agent ([3c](#3c--zero-context-fresh-eyes-agent)), spawned **outside** the team since its prompt forbids all tools — fold its read in during Step 4.

Prepend to every team-member prompt except fresh-eyes:

```
You are the <ROLE> member of team `<ticket-slug>`. Other members: <list>.

STEP 0 — load your coordination tools (messaging + shared task) before any other work.

When you find a candidate root cause, message it to the domain member(s) whose area it touches
and ask them to confirm or refute it against their layer. If a peer's hypothesis contradicts
yours, say so explicitly rather than deferring — convergence by agreement-without-evidence is a
failure mode. Post your final verdict (file:line + mechanism + minimal fix) to the shared task,
then idle.
```

Then append the domain/navigator task body unchanged.

### Option B — isolated-parallel

Fire **all** of 3a + 3b + 3c in a single parallel batch. No team, no cross-talk — each agent reports back to you alone and you synthesize.

---

**All three of the following agents are read-only / propose-don't-apply, regardless of what tools their agent type happens to carry.** "Minimal correct fix" in a prompt means *state* it, not apply it — no fixes during investigation, even by an agent that technically has edit access.

### 3a — Codebase-navigator agent

Dispatch a fast read-only search agent, background.

Prompt template:
```
Ticket #<N>: "<title>"
Working hypothesis: <your Step 2 hypothesis>
Affected paths mentioned: <list>

Tasks:
1. For each mentioned path, confirm it exists and find the exact file:line.
2. Grep for the key symbols, identifiers, or names from the ticket.
3. Find sibling code (a route's handler, a deployed job's config, a query's migration).
4. Check recent git history per relevant file.
5. Report exact file:line for every relevant symbol, sibling paths, and any recent related change.

Report in <REPORT_CAP words>. Write detail to a scratch file. Read-only — do not edit anything.
```

### 3b — Domain-investigator agent(s)

Dispatch one per matching domain signal from a routing table you define — for example:

| Domain signal | Investigation angle |
|---|---|
| billing / pricing / invoicing | rate resolution, calculation correctness, invoice generation |
| data pipeline / streaming / ingestion | schema propagation, event processing, sink correctness |
| API surface | auth middleware, request/response contract, error handling |
| frontend / UI | component state coverage, data fetching, rendering |
| infrastructure / deploy | provisioned resources, alarms, deployment config |
| security / auth | authorization gaps, injection, access control |
| SDK / client library | provider parity, instrumentation |
| schema / migrations | migration correctness, cross-branch collisions |

Use general-purpose agents wrapped with the domain lens, not narrow single-purpose named agents (see the Option A note on coordination tools).

Prompt template (adapt per domain):
```
Ticket #<N>: "<title>"
Full body: <text>
Working hypothesis: <hypothesis>
Suspected files: <list — grep for identifiers yourself; the navigator agent's results aren't
available to you yet>

Your job: find the DEFINITIVE root cause. Not the symptom — the actual broken line or missing call.

1. Read the suspected files; grep for key identifiers if not yet located.
2. Trace the path: entry point → processing → output/side-effect. Where does the invariant break?
3. Check adjacent code — callers, siblings, related paths that could mask or compound the bug.
4. State: "The bug is at <file>:<line> because <why>."
5. If the hypothesis is WRONG, explain why and state the correct root cause.
6. What is the minimal correct fix — describe it, do not apply it.

Report in <REPORT_CAP words>. Write detail to a scratch file. Read-only — do not edit anything.
```

### 3c — Zero-context "fresh eyes" agent

Always dispatch one general-purpose agent with **only** the raw ticket text and no hypothesis, no tools:

```
Read this ticket and state what you believe the root cause is, based only on the text below.

IMPORTANT: Do NOT use any tools — no search, no file reads. Work only from the text below.

Ticket #<N>: "<title>"
<body + comments>

State: (1) the most likely root cause in one sentence, (2) what you'd grep for first,
(3) what would confirm vs. refute the hypothesis.

Report in <200 words.
```

This catches cases where the initial read (Step 2) is biased by the reporter's framing.

---

## Step 4: Synthesize root cause

**Do not arm a wake-up timer to wait for the Step 3 agents (or the Step 6 reviewers).** Background subagents notify on completion, so a timer adds nothing, and a timer whose prompt is this skill re-fires the whole skill from scratch. End the turn with a one-line status ("waiting for N agents; they notify on completion"). A timer is for state the harness cannot track (a CI run, a deploy), never for agents this skill dispatched.

Wait for all Step 3 agents/members to return, then: **(team only)** read the peer-to-peer dialogue — final verdicts land on the shared task, but the cross-talk that produced them is invisible in your transcript, so read it from wherever your harness persists inter-member messages; **cross-check** the navigator's findings against the domain agent's diagnosis (do file:line locations match? does recent history align?); **adjudicate** any disagreement between the domain and fresh-eyes agents yourself (re-read the file inline, no new agent); **confirm the intended behavior, then state the definitive root cause** (below); **classify every other defect the agents found** as PRIMARY (this ticket's cause), LATENT (a real bug, not this ticket's: it goes to Step 7 as a proposed ticket, never dropped) or DISMISSED (with the evidence); **(team only) retire the investigation members now** — a graceful shutdown request captures their cost; if one hangs past a few minutes, leave it, session-end cleanup handles it.

**Confirm the intended behavior FIRST, with a citation.** Before writing the diagnosis, name what the affected surface is *supposed* to do and cite an authoritative in-repo source for it: a docstring or contract, a requirements or architecture doc, a sibling that does it correctly, or an explicit design invariant. A defect only exists relative to a verified intended behavior, so this is a lookup, not an inference. It is the bug-path twin of the Step 2.9 premise gate: it applies to a plain bug too, and it is **mandatory whenever the fix flips or restores a behavior** (turns a control on or off, changes a status code, re-scopes access) — the case where "is that actually a bug?" must be answered before the fix is proposed, not left for the user to ask. No source found → the plan's Root Cause says `UNCONFIRMED: <what you looked for>` and you ask the user before planning that fix. Then state it in 2–4 sentences: "The bug is at `<file>:<line>` because `<mechanism>` — but the surface is supposed to `<intended behavior>`, per `<source>`. The symptom occurs because `<causal chain>`."

**Precondition enumeration.** For any "X should have happened and didn't" cause (a sync, drain, deploy, retry, schedule), list EVERY path by which X can fail to run or finish — a job or step condition, a path filter, an upstream step that aborts the run, a missing retry or schedule, a stale pin — and give each a disposition: fixed here / safe, with evidence / out of scope, with a ticket. The list becomes the plan's `### Convergence preconditions` table. Fixing only the path that fired is the instance, not the class.

If you cannot definitively identify root cause, say so explicitly, note what would resolve it, then proceed with the best available hypothesis, clearly marked unconfirmed.

---

## Step 4.5: Class analysis (BUG only — fix the class, not the instance)

**Skip for FEATURE. Skip for a genuine one-line mechanical fix** (typo/config/single-line). **Skip when the root cause has no code mechanism** (pure operational/config). Otherwise mandatory — a single-domain, already-pinpointed bug is exactly the kind most likely to have siblings.

Dispatch a standalone read-only agent (the investigation team is already torn down) with the confirmed root cause — it does not re-derive it:

1. **Characterize the class.** State the invariant being violated in general terms, not the one site — "cost aggregations over gauge metrics use a summing function where the metric is point-in-time," not "this line divides by a possibly-zero X."
2. **Sweep for siblings, bounded.** Grep the anti-pattern across the tree; take the top ~30 candidates by match quality and read each to confirm it's genuinely the same class, not a superficial text match. If matches exceed the bound, report that loudly ("N+ sites, class is widespread — enumeration truncated"), never a silent partial list that reads as complete.
3. **Propose a guard**, ranked by strength: a type that won't compile if the class is written > a chokepoint assertion every path funnels through > a CI lint rule > a schema/boundary constraint > a runtime assertion as last resort. "Reviewers should watch for it" is not a guard — it's the absence of one.
4. **Or argue isolation** explicitly — why this file:line is the only representable site of the mechanism.

Record the result in the plan's bug-class section (Step 5). This is identification only; the fix stage applies the guard.

---

## Step 4.6: Foundation-reachability gate (MANDATORY when the fix builds on an existing module)

**Step 2.9 validates the premise of the TICKET. This validates the premise of the FIX.** They are different assumptions and fail at different times: at 2.9 you do not yet know what the fix will build on; here you do.

**Trigger:** the fix reuses, extends or "hardens in place" an existing module, helper or client instead of writing new code — *"build on the existing X"*, *"reuse X"*, *"X already does Y"*.

**The check, about a minute per module: is it actually REACHED BY LIVE CODE?** Grep for its importers (or callers, in a language without imports), then check that each importer has importers of its own up to an entry point: a caller nothing calls is not a caller.

**Decision:**
- **Reachable** → state "Step 4.6: `<module>` is reached via `<caller>` (`<its caller>`)" in one line, proceed.
- **Zero reachable callers → the module has NEVER RUN. Treat it as UNWRITTEN, not as proven.** Say so in the plan's Fix section and budget for its interface, behavior and tests all being unverified. Never describe it as "already does X": that is an assumption dressed as a finding.
- **It talks to an EXTERNAL service** (an HTTP API, a cloud SDK) → also probe the real contract, read-only, before the plan commits to it, and shape every test fixture from the OBSERVED response, never from your own interface type.

Why it is a gate: a fix built on a module nothing had ever called, with tests whose fakes were shaped from that module's own interface, passes every test while the real contract differs. The fakes confirm your assumptions back to you; only the observed response does not.

---

## Step 5: Write the plan

Write the implementation plan to `PLAN_DIR` (default `docs/plans/<ticket>-<slug>.md`; slug = lowercase hyphenated title words, ~40 chars max).

At this step, Read [`templates/plan.md`](templates/plan.md) and fill EVERY section: it is the plan's required structure — the confirmed intended behavior, Convergence preconditions, Data prerequisites, `## PRs`, the BUG or FEATURE sections, Simplest version considered (with its suppression check), Recurrence verdict with Falsifiable verification, and Close-out. Do not write the plan from memory: Step 7 runs `check-plan-sections.sh`, and a missing section blocks the summary. What later steps read: `## PRs` states the count on a `PRs: <N>` line; `## Close-out` has one bare `- Closes #<N>` line per ticket (the review-plan skill's work-unit audit and the review-code skill's close-out check read it); the `Recurrence-Verdict:` line is bare (both review skills read it).

For bundled tickets (multiple numbers), include a section per ticket, then a combined implementation-steps section that sequences them correctly. A bundle is ONE plan and ONE PR closing all of them.

---

## Step 6: Run plan review

Invoke your plan-review companion skill if you have one — it should own its own single-vs-multi-domain routing; don't replicate that logic here. After it returns, incorporate blocking findings into the plan and present the updated plan to the user.

**No companion skill?** Present the plan to the user directly and get explicit sign-off before implementation — that's the standalone fallback.

End with a line stating that plan review ran (or that you used the standalone fallback), so the user can see which path was taken.

**Gate C — one reviewer gets the TICKET, not the plan (MANDATORY when Step 2.95 fired, the ticket was closed before, or the signal is a fail-loud guard).** Domain reviewers review the artifact they are handed; none is asked whether the plan addresses the cause. Dispatch ONE extra reviewer, alongside the plan review, whose input is the ticket and the plan and whose single question is: a month after this ships, does the Gate A number (for a prior closure or a guard: the signal's occurrence rate) go UP, stay FLAT or go DOWN, and by what mechanism? Non-DOWN is a BLOCK. At this step, Read [`references/anti-masking-gates.md`](references/anti-masking-gates.md) (Gate C) for the reviewer prompt; do not improvise it.

Record the answer as a bare line `Recurrence-Verdict: #<N> <DOWN|FLAT|UP> — <mechanism>` (no backticks, bullet or indent) in the plan's `## Recurrence verdict`. Non-DOWN: revise the plan (change the rate, not the visibility) until Gate C answers DOWN with a mechanism; `Refs #N` and "retitle the ticket to the remaining class" are not remedies; still non-DOWN after one revision: ask the user, inline, what changes the rate (state the measured rate and the two mechanisms you tried), and never ship a non-DOWN verdict. DOWN: `- Closes #N`.

---

## Step 7: Present summary

Resolve the plan's **full filesystem path** before printing it — don't print the bare repo-relative form.

Then check that the plan has every section later steps read. Pass `--bug` and/or `--feature` for the Step 2 classification, and `--no-tracker` when `ISSUE_CMD` is empty:

```bash
bash .claude/skills/start/bin/check-plan-sections.sh <plan path> [--bug] [--feature] [--no-tracker]
```

Exit 0: every required section is present. 3: sections are missing or unfilled (each is printed): add them from [`templates/plan.md`](templates/plan.md), re-run, and do not print the summary until it exits 0. 4: the plan file is missing or unreadable. Anything else: HALT and report.

Output:

```
## Ready to implement — #<N> <title>

**Root cause:** <one sentence>
**Fix location:** <file>:<line>
**Plan (full path):** <absolute path>
**Review:** <verdict counts, or "standalone fallback used">
**PRs:** <1 | N — see banner>

### Data prerequisites
<The plan's section, one bullet per prerequisite, or `None`.>

### Decisions needed
<When the plan has more than one PR, the FIRST item is each additional PR's banner
`⚠️ ADDITIONAL PR REQUIRED (N total): <scope> — owns #<N> — blocker: <blocker>`, for the user's
approval here. Next, every Close-out step marked `(shared write)`, one bullet each, for approval
now. Then the 1–3 judgment calls sign-off actually hinges on, so the user can approve in minutes
without re-deriving them: each one bullet — the decision, the option the plan takes, the
alternative it rejects and why. Draw them from contestable product or contract calls, scope
inclusions and exclusions, guard and design trade-offs, and anything plan review flagged but did
not block. Mechanical content (file lists, test items, phase order) does not belong here. No
contestable call → "None — plan is mechanical; sign-off is a correctness skim.">

### Plan summary
<Structured, not one paragraph: **Fix:** 1–2 sentences. **Implementation phases:** one bullet
per phase, by name. **Testing:** one bullet per item. If BUG: **Bug class & guard:** bullets.
If FEATURE: **E2E test plan:** bullets. A reader who hasn't seen the plan file should understand
its shape from this summary alone.>

### Close-out
<From the plan's `## Close-out`: the tickets that close at merge, the post-merge in-session
steps, the release obligations to register (or `none`). Step 4's LATENT bugs, each as a proposed
ticket for the user's approval (or `none`).>

Next: implement Phase 1 — <first step description>
After the last phase: the review-code skill (Step 8 — the gate before any "done", compact handoff or ship).
```

Do NOT ask "should I start implementing?" — just stop here. The user says "go" or redirects.

Keep the review-code line in the printed summary, but do not mistake it for the enforcement: a compaction summarizes the transcript and may drop it. The durable copies of the rule are the ones re-read every session or every use: the project rules file's code-review rule, and the trim and ship skills' own review checks. Step 8 binds this session while its context is live.

---

## Step 8: Code-review gate before any completion handoff (MANDATORY — terminal)

**This skill does not end at Step 7 for the session that runs it.** The same session implements the plan, so this skill owns the terminal gate on that work: **the review-code skill runs, and passes, before this session emits any completion signal.**

**Blocked until the gate is satisfied — every one of these:**

- "all done", "implementation complete", "that's everything", or any wrap-up summary.
- "ready to ship", "ready to commit", "your call on shipping".
- **A prepared compact or `/trim` handoff, in ANY wording** (the trigger is handing over a compact-then-ship block, not a literal prefix). A compact handed over first destroys the context the review needs. Review, then compact.

**Satisfied only by the ship skill's own predicate**, not by "I ran a review at some point this session": the review sentinel's fingerprint must match the current tree. Resolve the repository root (`git rev-parse --show-toplevel`; substitute it for `<root>`), then:

```bash
test -f <root>/.claude/skills/ship/bin/ship-sentinel.sh && bash <root>/.claude/skills/ship/bin/ship-sentinel.sh --contract=2 verify review
```

- **Exit 0** → satisfied. Emit the completion handoff below.
- **Exit 1** (no valid review for this tree) → invoke the review-code skill now, with no announcement and no "should I?": invoking it IS the next step. Fix what it finds, re-run the check, then emit the handoff. A printed line starting `REVIEW: MANUAL-` means ship's review gate is in manual mode: after the review, record the attestation while the context still exists (`ship-sentinel.sh --contract=2 attest review --note "<what was reviewed, how, against which commit>"`), and never write one for a review that did not happen.
- **Exit 3 or any other** (the reader failed, ship is misconfigured, or exit 9: this `--contract` no longer matches the installed ship) → report the printed line; never treat it as a pass.
- **Ship not installed** (`test -f` fails) → nothing can check a sentinel: the gate is "the review-code skill ran to its last step on the current tree in this session, and no source file changed after it". Review-code not installed either → the handoff opens with `Code review: NOT RUN (no review skill installed)`, never with a ready-to-ship line.

**What un-satisfies the gate is a CONTENT change, not a commit.** The fingerprint covers the working tree against the merge-base, so committing, amending or rebasing after the review keeps it satisfied while the bytes are unchanged; editing a file after the review un-satisfies it, committed or not.

**Only exception:** a genuinely trivial change (a single-line typo fix, a comment correction, a rename with no logic change) — state the specific reason and ask. Any other reason for skipping is banned. **The exception exempts you from running the review; it does NOT produce a sentinel.** Ship's review gate has no exception and halts regardless: if the user approves skipping, say in the same message that ship will halt and that running the review is the only way past it.

**The completion handoff has fixed sections, and no free-form remaining-work list.** Nothing has merged yet, so it says what WILL happen, never that tickets are closed. In order: (1) `⚠️ ADDITIONAL PR REQUIRED (N total): …` or `Additional PRs: none`; (2) `Tickets that close at merge: #A, #B` (every ticket this plan was started on); (3) `Release obligations to register: <list>` or `none`; (4) `Post-merge, in-session steps: <list from ## Close-out>` or `none`; (5) `Follow-up tickets (user-approved): #N` or `none`; (6) `Proposed tickets awaiting your approval: <title — exact fix — blocker — duplicate-search result>` or `none`. Anything else still undone is done now or proposed as a ticket: "still todo", "remaining items" and "next steps for later" lists are banned.

---

## Notes

- **The navigator agent is often faster than expected** — fire it in parallel with domain agents, don't wait for it first.
- **Single-issue vs. bundled.** For a bundled ticket set, produce one plan file covering all of them, with per-ticket root-cause sections and one unified implementation sequence.
- **An already-diagnosed ticket** (file:line + exact cause already in the body) triggers the Step 3 opt-out — treat discovery as verification, and don't pay the team premium to confirm a cause the ticket already pinpoints.
