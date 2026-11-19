# Anti-masking gates A, B, C, D: procedure and stories

`SKILL.md` Step 2.95 names the four gates with their triggers; Gate C is dispatched in Step 6. At the step that fires a gate, Read the matching section below.

## Gates A, B and D (Step 2.95)

### Gate A — trend the underlying POPULATION before writing any plan

Do not plan against the metric. Query the rows (records, events, jobs) the metric counts, and **bucket them by creation time**:

```sql
SELECT date_trunc('month', created_at) AS bucket, count(*)
  FROM <what the metric counts> WHERE <the flagged condition>
 GROUP BY 1 ORDER BY 1 DESC;
```

(The shape, not the dialect: any store that can group by a creation timestamp answers it; for a log-based signal, count the matching lines per day or week.) Then one classification query: *are these rows structurally incomplete, and since when?* State the result in one line before Step 3.

- **Flat or static backlog** → an alarm-config fix (threshold, scoping, routing) is legitimately on the table.
- **GROWING** → **the alarm is reporting a live defect. An alarm-config fix is MASKING. Do not propose one as the primary fix.** Find what produces the rows.

A flat answer is not a wasted query: it is the evidence that licenses the cheap fix. A read-only query needs no approval; run it, don't ask.

**For an alarm ticket, also identify WHICH process wrote the datapoint before reading the alarm text's named emitter as fact:** read the alarm's series at its finest period and correlate the datapoints with each candidate writer's runs in the same minutes, then read that writer's own logs for the failure line. An alarm description names the emitter its author expected, not the one that wrote this datapoint.

> Anonymized story: a flagged-row count had its creation timestamps in hand and never bucketed them. One group-by would have shown the monthly count roughly doubling over four months, and nearly every flagged row missing the record it should have been created with. Without it, the session wrote three successive plans to suppress the signal (route it to an unalarmed series, disable the alarm, raise the threshold) and needed six user questions to reach the actual defect.

### Gate B — if a prior fix exists for this symptom, verify it works BEFORE designing a new one

Before Step 3, search history for a prior fix (`git log -S'<symptom token>'`, and the tracker for earlier tickets with the same symptom keywords). If one exists, **reproduce it via the least-scaffolded invocation a person would actually type**: the bare script or raw command, not the CI wrapper around it.

- **Prior fix holds** → say so in one line, proceed.
- **Prior fix does NOT hold** → the ticket is *"why didn't the fix work?"*, not *"design a fix"*. That is a different and usually much smaller change. Re-frame before planning.

Fires when the root cause **cites a prior fix commit** OR the ticket was **closed before** (a closed or reopened event in its history, from Step 1). It is not a mandate to re-test everything else. For a prior closure, read who or what closed it, the PR that closed it and that PR's plan `Recurrence-Verdict` line if it has one, and **say why the prior closure didn't hold** (did the closing fix change the production rate, or only the visibility?) before proposing anything. A prior closer with a FLAT, UP or absent verdict means the unfixed class is the ticket.

> Anonymized story: a week-old commit titled as the fix for a test leak was not working. Isolation was enforced by a wrapper script; the documented test command bypassed the wrapper, so any direct or local run still wrote to the shared environment. Running the bare command once would have found it; instead it surfaced at the eighth question.

### Gate D — guard-firing signals: investigate the convergence mechanism

**Trigger:** the signal is a deliberate fail-loud guard (a refusal, a stale-version error, "refusing to…", a drift check), whether or not it is an alarm ticket.

A guard firing proves the invariant it protects is false. The investigation target is therefore **the upstream convergence mechanism** that should have made the invariant true (the sync, drain or deploy job that restores it), not the guard, its alarm or its message. The plan names that mechanism and cites evidence (a run id, a job status, a log line) that it ran and succeeded, or didn't, in the window around onset, plus what retries it when it fails. "It self-heals on the next run" without that evidence is not a finding.

> Anonymized story: a stale-version guard fired a couple of hundred times and the ticket was closed twice as "working as designed, self-healing". The job that should have cleared the stale state had failed on the same commits, and nothing retried it.

## Gate C (dispatched in Step 6)

**Review converges on the artifact it is given.** Every domain reviewer handed "review this plan" reviews the plan: the money reviewer checks money-safety, the infra reviewer checks the infrastructure diff, the observability reviewer checks alarm coverage. None has a mandate to ask whether the plan addresses the *cause*, so none does. This is not a reviewer-quality problem, and more reviewers do not fix it.

So dispatch ONE additional reviewer whose input is the ticket **and** the plan, with exactly this mandate, wired to Gate A's number (or, when Gate C fired for a prior closure or a guard, the signal's occurrence rate per day from the ticket's history or the log query) so it is a measurement, not another open-ended judgment:

```
Ticket: <title + body>. Plan: <path>. Gate A measured the bad population as <N per month, trend>
(or: the signal occurs <N per day, trend>).
ONE question: a month after this plan ships, does that number go UP, stay FLAT, or go DOWN?
Answer with a mechanism, not a hope.
If UP or FLAT, the plan changes the VISIBILITY of the bad state, not its production rate: say so
plainly and name what would change the rate.
You are not reviewing the plan's quality. Do not report bugs, style, or missing tests.
```

A plan that cannot answer "DOWN, because <mechanism>" is a masking plan. That is a BLOCK, however well engineered it is.

**Record the answer.** After the reviewer answers, write `Recurrence-Verdict: #<N> <DOWN|FLAT|UP> — <mechanism>` as a bare line in the plan's `## Recurrence verdict` section. The review-plan skill blocks a FLAT, UP or missing verdict, and the review-code skill checks that the diff delivers the DOWN mechanism; the verdict is decided HERE, at plan stage, never at ship time. **Non-DOWN → the plan is not done: revise it (change the rate, not the visibility) until Gate C answers DOWN with a mechanism. `Refs #N` and "retitle the ticket to the remaining class" are not remedies. Still non-DOWN after one revision → ask the user, inline, what changes the rate (state the measured rate and the two mechanisms you tried); never ship a plan with a non-DOWN verdict. DOWN → `- Closes #N`.**

> Anonymized story: two review rounds, eleven agents and eight verified BLOCKs on a plan, and not one finding questioned the framing; a search of every finding for accumulation or cleanup language returned nothing. The most thorough pass of the session hardened a plan that was later replaced in full.
