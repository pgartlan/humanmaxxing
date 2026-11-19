---
name: review-plan
description: Multi-perspective review of an implementation plan before any code is written — context prep and assumption validation, the lead's structural audits, domain-expert reviewers (collaborating when two or more apply) plus a zero-context reader, a plan-edit pass, and an external second-opinion gate on the updated plan. Shares its reviewer detection table and collaboration mechanics with review-code.
user-invocable: true
allowed-tools: Agent, Bash(gh issue view *), Bash(gh issue list *), Bash(git *), Bash(cat *), Bash(mktemp *), Bash(mkdir *), Bash(chmod *), Bash(cp *), Bash(rm *), Bash(rmdir *), Bash(grep *), Bash(stat *), Bash(touch *), Bash(date *), Bash(echo *), Bash(printf *), Read, Glob, Grep, Write, Edit, ToolSearch, Bash(bash .claude/skills/review-code/bin/reviewer-fold.sh *), Bash(bash .claude/skills/review-code/bin/lens-score.sh *), Bash(bash .claude/skills/review-code/bin/wait-for-findings.sh *)
---

# /review-plan — multi-perspective plan review

Review the most recently presented implementation plan before a line of code is written: **context prep** (docs, git history, every assumption the plan makes about existing code, verified), the lead's **structural audits** (deferred work, scope, test plan, requirement traceability), **domain-expert reviewers** chosen from the plan's content plus a **zero-context reader**, a **plan-edit pass**, and an **external second-opinion gate** on the updated plan — closing with a final plan the implementer can start from in a fresh context.

The product is the **orchestration pattern**: what gets verified before reviewers spend tokens, which audits the lead runs itself, how reviewers cross-examine, and the rule that a plan's necessity findings are surfaced as options the user decides, never as verdicts.

**One skill, one decision made for you.** Two or more domain reviewers match → they run as a collaborating group (Step 5 picks the mechanism your harness supports). One matches → it runs alone. The zero-context reader runs in every mode.

**No mid-run pause for a context-compaction suggestion.** This skill runs long; don't interrupt it to offer one.

---

## Configuration — adapt these to your repo

**Any command you put in a slot must also be added to `allowed-tools` above.**

```
DETECTION_TABLE        — review-code's references/detection-table.md (rows match topics a plan
                         names as well as paths in a diff). One table, two readers
DOCS_ROOT              — where requirements, architecture notes, and prior decisions live
                         (Step 1 searches it)
PLAN_DIR               — where finished plans are saved, as <id>-<slug>.md; <id> is the
                         originating issue number, or the branch slug when there is no issue
WORK_UNIT_RULE         — how many PRs one plan may produce without a declared blocker (worked
                         default: one; phases are commits, not PRs) and which blockers justify
                         more (another repo; an ordering that needs an intervening deploy; a
                         protected-file change the user makes by hand; the user asked)
PROTECTED_PATTERNS     — phrases in plan text that mean an irreversible or high-blast-radius
                         operation (state-incompatible schema change, destructive migration,
                         kill switch) — Step 2's soft callout. Empty is valid; Step 2 says so
REQUIRED_AUDITS        — references/plan-audits.md: the lead's Step 4 audits. Four are built in;
                         add yours under the extension point
CRITICAL_GLOBS         — same slot as review-code / ship: paths whose change needs real E2E
                         coverage; here it decides whether the plan must carry an E2E close-out step
SECOND_OPINION_CMD     — a model/provider DIFFERENT from the one running this session (Step 8).
                         It sends the plan and its context to that provider: fill it only with
                         the user's consent to that. Same call contract as review-code's (prompt
                         on stdin, review as text on stdout, exit 0; anything else is NOT_RUN).
                         Key from the CLI's own login or a 0600 file, never argv. Unset: NOT_RUN,
                         visibly
COLLAB_MODE            — auto | peer | mediated | isolated (default: auto; Step 5a). Explicit
                         peer/mediated override the 2+ row; isolated forces single-pass review
REVIEWER_BUDGET        — tool calls per reviewer (worked default 30)
MAX_REVIEWERS          — the HARD TOTAL of reviewer agents for one plan review, the zero-context
                         reader included (default 5); folding as in review-code Step 2
TRACKER                — github | none. github: the adapter Steps 4 and 9 use. none: no tracker
                         (the plan starts from a task described in words): Step 4's close-out
                         audit checks that the plan's work is done or named in it instead of an
                         issue being closed, and Step 9 lists proposed tickets in the
                         conversation, filing nothing
ISSUE_CLOSE_KEYWORD    — the closing keyword plans and PR bodies use (default: Closes)
TEST_PRESCAFFOLD       — on | off (default: off). After the final plan, dispatch the test reviewer
                         in the background to pre-write specs the code review will later extend
OPEN_FILE_CMD          — optional: how to open the finished plan for the user (an editor CLI).
                         Unset: print the path
TIMEBOX                — wall-time bound for the reviewer stage, total across rounds
```

**Companion (REQUIRED): review-code.** This skill reads review-code's `references/detection-table.md` and `references/harness-notes.md` by relative path (`../review-code/references/`), and the plan it approves must end with a step that runs review-code after implementation. Install both; without review-code, Step 3 and Step 5a cannot run and Step 9's mandatory plan steps cannot be satisfied. **Companion (recommended): bootstrap-agents**, which generates the roster and the detection table.

---

## Design principles (why the skill is shaped this way)

1. **Verify the plan's assumptions before anyone reviews its logic.** Silently-wrong assumptions about existing code are the single largest source of plan defects we've seen. One pass of Grep/Read against every "X currently does Y" claim, before reviewers launch, saves the whole group from rediscovering it.
2. **The lead owns the structural audits.** Deferred work, PR count, test plan, requirement traceability — these are properties of the document, not of a domain, and a domain reviewer reading against code reality misses them. They run on the main thread, every plan, no exceptions.
3. **Collaboration beats isolation when domains overlap.** A reviewer who hears another's finding checks its own domain against it; cross-domain blockers live in that gap. On our own calibration a collaborating group found roughly 2× the blocking findings of isolated-parallel review at better cost per finding — recalibrate on your repo.
4. **One reviewer reads the whole plan as a document.** Every domain reviewer is scoped; the zero-context reader is the only one who sees cross-phase excess, steps that don't follow from the stated problem, and inconsistent terminology. It has no codebase access on purpose, and no peer messaging.
5. **Trust but verify, from every source.** Every blocking finding needs a citation — a quoted plan section, file:line from a Read/Grep, a docs URL with section, or script output. No citation → downgrade, never pass-through.
6. **The second opinion runs on the edited plan, after the group.** Run in parallel, an external model re-derives what the group is converging on (roughly half its findings were duplicates on our calibration); run on the updated plan it is a genuine second look. When configured, it runs even if the group found nothing — a clean round 1 is exactly when an independent model earns its keep.
7. **Necessity findings are options, not verdicts, and never CRITICAL.** A phase that serves no stated requirement is a scope question for the user. Cap it at WARNING, collect every such finding in one visible block, state the cut and its size as facts, and let the user decide. A scope opinion that outranks a correctness finding hands any reviewer a veto over a correct change. The exception that still caps at WARNING but must never be buried: **ALTERNATIVE-MECHANISM** — a different chokepoint that replaces the whole approach (a plan once collapsed by an order of magnitude after such a finding had been filed as a mere suggestion).
8. **Fail-safe at every gate.** Zero matching reviewers → one general reviewer plus the zero-context reader. A reviewer that returns nothing → report and get an explicit decision, never drop it. No second-opinion provider, or a failed call → NOT_RUN with the reason. An audit with nothing to report still prints its block — a silent absence is indistinguishable from an audit that never ran.

Severity vocabulary: reviewers write **BLOCK / REQUEST_CHANGES / SUGGEST / NOTE**; the synthesis presents the same tiers as **CRITICAL / WARNING / SUGGESTION / NOTE**.

---

## Sequencing rules

- Step 1's four prep lanes run **in one parallel batch**.
- Step 4 (the lead's audits) runs **in the same turn** as Step 5's reviewer dispatch — write your own findings while they work; never finish the self-review first and launch after.
- Step 8 (second-opinion gate) runs **after** Step 7's plan edits, never alongside Step 5.
- Step 11 (teardown) is last.

---

## Step 0: Extract the plan, create the scratch dir and run id

Identify the complete plan text from the most recent plan presentation in this conversation.

```bash
SCRATCH_DIR=$(mktemp -d /tmp/plan-review-XXXXXX); chmod 700 "$SCRATCH_DIR"; mkdir -p "$SCRATCH_DIR/findings"
RUN_ID="rp-$(date +%s)-$$"
echo "SCRATCH_DIR=$SCRATCH_DIR RUN_ID=$RUN_ID"
```

Every Bash call is a fresh shell and agent prompts don't expand variables: substitute the **printed literal values** everywhere below. Write the plan to `SCRATCH_DIR/plan.md`. (`run.env` with the expected-reviewer list is written in Step 3, once the roster is known.)

---

## Step 1: Context prep — one parallel batch

Four lanes, fired together, each writing its file even when empty (a reviewer prompt names the file; a missing file is a failed read, an empty one is information):

- **`historical.md` — docs search.** Extract 5–10 keywords (feature, component, table, service, route names). Grep `DOCS_ROOT` and `PLAN_DIR`; read the 3–6 most relevant files. Extract prior decisions and their rationale, known issues and TODOs, scope constraints from requirements, what's already done, what was deferred. Print a HISTORICAL CONTEXT summary; write it.
- **`decisions.md` — git history.** For each path the plan touches, `git log` the last ~3 months. Extract architectural decisions, prior fixes, recently-merged changes on the same logic, conventions in active use (grep for the idiom in 5+ places). Print a PRIOR DECISIONS summary; write it.
- **`assumptions.md` — assumption validation (MANDATORY).** List every claim the plan makes about existing code ("the handler already validates X", "the column is nullable", "nothing else calls this"). Verify each with Grep/Read. Table: assumption → verified / wrong / unverifiable, with file:line. Correct the plan text where an assumption is wrong, and record the correction. Reviewers start from the verified plan.
- **`code-context.md` — snippet pre-fetch.** The 3–5 files whose behavior the plan claims to change: the relevant function bodies, queries, type definitions, with file:line ranges. Reviewers read this first instead of each re-fetching the same files, and the second-opinion call gets real code instead of guessing. Too high-level to name 3 files → write `(no code context — plan is too high-level for code-grounded review)` and say so in the report.

**Three traces when their trigger matches, run now and attached to `assumptions.md`:**
- **Adjacent columns** (the plan changes an aggregation): enumerate every column sharing the same filter or grouping as the one named, and whether a test asserts each. (We once fixed one aggregated column cleanly while two siblings built from the identical expression carried the same bug.) Missing assertion for any sibling → a BLOCK the lead carries into Step 7.
- **Generated-artifact propagation** (the plan changes a generator, compiler, or config builder): is the output persisted or cached, and does the plan regenerate the stored copies? (A full review plus an external gate both passed a generator fix that was dormant in production because stored, previously-compiled copies were what ran.) Persisted output + no regeneration step → BLOCK.
- **Precondition coverage** (the plan relies on "X will happen / X self-heals / X is retried"): enumerate what else can stop X and what re-runs it. A plan whose fix only changes visibility (an alarm, a threshold, a label) does not reduce recurrence; "we'd have observed it" is not verification. Compare against the plan's `### Convergence preconditions` table: a path the table omits that you can name from the code → REQUEST_CHANGES; **BLOCK when it is the path that produced the incident.**

**Recurrence rule (the lead runs it now and reports it in Step 7; the verdict is decided at plan stage, never at ship).** For every ticket the plan closes, read its `## Recurrence verdict` line (`Recurrence-Verdict: #<N> <DOWN|FLAT|UP> — <mechanism>`, bare). **BLOCK** when the plan carries FLAT or UP for #N, or when #N was closed before (its history shows a close or reopen) or its signal is an alarm, a flagged-row count or a fail-loud guard, and the plan has no DOWN line with a mechanism. A line starting `Recurrence-Verdict:` in any other shape is malformed → BLOCK. Remedy: revise the plan until the start skill's Gate C reviewer answers DOWN with a mechanism; the plan then says `- Closes #N`. `Refs #N` and "retitle the ticket to the remaining class" are not remedies.

---

## Step 2: Protected-operation callout (SOFT)

Scan the plan text for `PROTECTED_PATTERNS`. **This is a reading of prose, not a machine gate** — at plan time there is no diff, so it can miss an operation not described in words; the enforceable gate is the `PROTECTED_FILES` check in review-code and ship, which read the actual diff. Detected → emit prominently in Step 7's synthesis:

```
⚠️ HIGH-BLAST-RADIUS OPERATION — EXPLICIT APPROVAL NEEDED
This plan proposes <operation class>. An unnoticed slip here is an incident, not a review
comment. SOFT callout (plan text only); the diff-based gates in review-code/ship are the
enforceable backstop. REQUIRED before implementation: explicit user approval stating the
reason and the blast radius / downtime accepted.
```

Not detected → print one line, `Protected-operation scan: none detected (N patterns)`, and continue. Empty `PROTECTED_PATTERNS` → `Protected-operation scan: no patterns configured`. Don't manufacture a callout for ordinary changes.

---

## Step 3: Detect reviewers, persist the roster

Match the plan's content — the topics, components, and paths it names — against `DETECTION_TABLE`. Print which reviewers matched and why; overlapping rows are intended (each is a lens). Decide who reviews exactly as review-code Step 2 does, with this skill's `MAX_REVIEWERS` (a hard total: the zero-context reader counts) and review-code's `SMALL_DIFF_SCORE`, `REVIEWER_STEP_SCORE`, `LENS_MIN_SCORE` and `LENS_CHECK_<agent>` values and `bash .claude/skills/review-code/bin/reviewer-fold.sh`. A plan has no diff yet, so `lens-score.sh` runs only when the plan's branch already has one; otherwise score each lens by the plan lines that name its topics or paths (×3 for a critical path), and `--total-score` is their sum. The test reviewer, and the security reviewer when a critical path is named, are never dropped but count; print the decision table and give each hybrid agent its `HYBRID` file. The **zero-context reader** runs in every mode; it counts toward `MAX_REVIEWERS` but not in the domain-agent count below. The count of *domain* agents that run decides Step 5's shape: **0 → one general reviewer, isolated; 1 → that reviewer, isolated; 2+ → collaborating group.**

```bash
printf 'RUN_ID=%s\nEXPECT=%s\n' "<RUN_ID>" "<name1>,<name2>,…,zero-context" > <SCRATCH_DIR>/run.env   # mediated mode: <name>:R1,<name>:R2 per domain/test reviewer and zero-context:R1; matching rule in review-code's references/sentinels.md "Expected markers"
```

`run.env` is the durable copy of the expected-reviewer list; after a compaction, read it back rather than remembering it. Each reviewer `<NAME>` writes `SCRATCH_DIR/findings/<NAME>.md`.

---

## Step 4: The lead's structural audits (same turn as Step 5's dispatch)

Run every audit in `references/plan-audits.md` yourself, on the main thread, while reviewers work. Print each audit's block even when it finds nothing. Four are built in:

- **Deferred-items audit** — every phrase that pushes work out of this plan. Deferred tests, error handling, validation, migrations, or any part of the originating issue → CRITICAL unless `WORK_UNIT_RULE` names a blocker; docs or polish → WARNING; an explicit out-of-scope with a reason → OK.
- **Work-unit and close-out audit** — the plan produces the number of PRs `WORK_UNIT_RULE` allows, each additional one declares a blocker and has user approval, every originating issue is closed by the plan's close-out (`ISSUE_CLOSE_KEYWORD #N`), and every post-merge obligation has a home your process actually tracks. The synthesis opens with `PRs: <N>` and any `⚠️ ADDITIONAL PR REQUIRED` banner. A plan template with PR and close-out sections makes this mechanical; without one, read for the same facts and say the template is missing.
- **Requirement traceability** — the one audit that can shrink a plan: map each phase to the requirement or root-cause element it serves. UNMAPPED → WARNING at most (Design Principle 7). Phases that exist for class guards, tests, error handling, observability, tenancy, a settled prior decision, or a *declared* fold-in are excluded, not reported.
- **Test-plan audit** — unit/integration tests for new logic; a baseline step; real E2E through real boundaries for anything touching `CRITICAL_GLOBS`, with named adversarial cases developed in three rounds; and an explicit **close-out criterion** that the E2E tests are built AND executed in-session with green output captured — "will run in CI" does not satisfy it. Missing on a non-exempt plan → CRITICAL.

Then the **parallel execution map** for the implementer. Every CRITICAL you raise needs a `VERIFIED:` line. Repo-specific audits go under the reference file's extension point.

---

## Step 5: Launch reviewers

Launch ALL reviewers in a single message with multiple `Agent` calls, prompts from `references/plan-reviewer-prompt.md` with every slot filled (literal scratch paths, run id, roster, budget). The test reviewer gets its specialized prompt; the zero-context reader gets its variant and **never the peer block**. Every prompt names what the reviewer may run locally; reviewers are read-only on plan and code and write only their own findings file.

### 5a — Pick the collaboration mechanism

`COLLAB_MODE = auto` resolves by the procedure in review-code's `references/harness-notes.md` — harness identity first (anything but Claude Code → mediated), then the one-time two-agent probe, then roster delivery (pre-filled if your `Agent` tool takes a name, otherwise sent as the lead's first message after the batch):

| Domain reviewers | Spawned agents can message each other | Mode |
|---|---|---|
| 0 or 1 | any | **isolated** |
| 2+ | yes (Claude Code, after the probe) | **peer** |
| 2+ | no (Codex, Copilot CLI, Cursor, Gemini CLI as of this writing) | **mediated** |

Record the mode in the report header. Explicit `peer`/`mediated` override the 2+ row; `isolated` forces single-pass review (say so). With 0–1 domain reviewers every setting is isolated.

### 5b — Peer mode
One batch; domain reviewers and the test reviewer carry the peer block; the zero-context reader spawns in the same batch outside the roster. Each findings file ends with `<!-- REVIEW-COMPLETE <name> <RUN_ID> -->`. Arm the watcher right after the spawn batch as a background command, never a timer that re-invokes the skill: `bash .claude/skills/review-code/bin/wait-for-findings.sh --run-env <SCRATCH_DIR>/run.env --dir <SCRATCH_DIR>/findings --timeout <seconds>` (exit codes and the one matching rule: review-code Step 5b), and run it once with `--check` to confirm its `MISSING:` list is the full expected list. A "done" message is a hint; the markers are proof, and Step 6 starts only after the same command with `--check` exits 0. Timeout → nudge once, re-arm once.

### 5c — Mediated mode
Round 1 isolated in one batch; copy `findings/` to `findings/round1/`; round 2 re-dispatches (or resumes) each domain reviewer with the others' BLOCK and REQUEST_CHANGES attached by domain and the round-2 block; markers carry `R1`/`R2` as the last token before `-->` (matching rule: review-code's `references/sentinels.md`, "Expected markers"). The zero-context reader does not take part in round 2. Budgets, resume rules, and what this mode loses relative to peer are in harness-notes.

### 5d — Isolated mode
The matched reviewer (or a general reviewer when none matched) plus the zero-context reader, base prompts, no peer block. Markers still required.

**Completion is verified in every mode, never assumed.** A reviewer whose findings don't open with the `E2E GATE:` line skipped it: treat as failed. A reviewer that exhausted its budget without writing findings, or is still missing after the one re-arm, is a FAILURE: **report it to the user and get an explicit decision** — re-run with a tighter prompt ("write findings from the plan text first, then verify") or a larger budget, or continue without it; continuing is recorded in the report header as a named gap. Do not arm a wake-up timer to wait for reviewers; a timer that re-fires this skill restarts the review.

---

## Step 6: Convergence pass

After every expected marker is present (or the Step 5 failure path was resolved with the user):

1. Peer mode: **snapshot every inbox first.** Mediated mode: your inbox is the `findings/round1/` vs `findings/` diff.
2. **Read all findings** (round 2 in mediated mode).
3. **Convergence-failure signals:** unclassified findings; two reviewers BLOCKing the same thing with no shared resolution; a classification flipped after one exchange with no cited evidence (peer: in a DM; mediated: a round-1 finding changed without a self-DISPUTE); zero DISPUTEs group-wide; a CONFIRM whose citation restates the original's; a BLOCK with no plan §-ref or file:line.
4. **Re-verify every BLOCK yourself** — re-read the cited plan passage, run the Grep, fetch the doc, run the script. Checks out → `MAIN-CONFIRMED`. Doesn't → `MAIN-UNVERIFIED`, downgrade with the reason. None supplied → `UNVERIFIED`, downgrade. Mediated: adjudicate every DISPUTE and ESCALATE yourself with both citations.
5. **Adversarial re-read:** a cross-domain concern no one owns? **Two or more findings on one component — is the component the right mechanism at all?** (Defect density is a design signal; ask before patching.) Something Step 1 or 4 surfaced that no reviewer raised?
6. **APPROVE-CONVERGENCE or DISSENT.** DISSENT when one expert's concrete evidence contradicts a general-knowledge consensus, the downside is severe (data corruption, security exposure, unrecoverable state), and more reading won't settle it (mediated: one targeted re-dispatch to the two parties first). State the finding, the counter-evidence, your reasoning, and a concrete resolution test. Never over style.

---

## Step 7: Present findings, edit the plan (HUMAN GATE)

Present, in this order:

1. `PRs: <N>` and any `⚠️ ADDITIONAL PR REQUIRED (N total): <scope> — owns #<N> — blocker: <blocker>` banner.
2. The Step 2 callout, if it fired, and the recurrence rule's result (Step 1): one line per closed ticket — its `Recurrence-Verdict`, or the BLOCK.
3. **Simplification options** — every necessity finding from every source, all tiers, as a table: shape (UNMAPPED, DUPLICATE, SPECULATIVE-GENERALITY, ALTERNATIVE-MECHANISM, TASTE), what could be cut or replaced, size, tier, source. State them as options, not recommendations; the user decides what to build. None → write "None — N reviewers emitted a necessity trace with no finding."
4. Findings by source: your Step 4 audits, each domain reviewer, the zero-context reader. Header: mode, verdict (APPROVE-CONVERGENCE or DISSENT), reviewers completed N/N; peer mode adds the cross-talk summary (DMs exchanged, documented mind-changes, findings that emerged from dialogue).
5. The parallel execution map.

**Then edit the plan to address the valid findings** — rewrite the affected sections, don't append notes — and record what changed and why. Write the updated plan back to `SCRATCH_DIR/plan.md`. **Wait for the user** before Step 8 if any CRITICAL remains that you could not resolve by editing; otherwise continue.

---

## Step 8: Round 2 on the updated plan + second-opinion gate

Two independent decisions:

- **Reviewer re-run** — skip if round 1 produced 0 CRITICAL, 0 WARNING, and 0 WARNING-tier necessity findings across every source (say so). Otherwise re-run only reviewers that had CRITICAL or WARNING findings, or whose domain the edits touched, plus the zero-context reader (cheap, whole-document). Print `ROUND2:` and `SKIPPED:` lists with reasons.
- **Second-opinion gate** — runs whenever `SECOND_OPINION_CMD` is set, clean round 1 or not (Design Principle 6). Two parallel calls to a model/provider different from this session's, both given the updated plan, `code-context.md`, `historical.md`, and the round-1 CRITICAL summary so they don't re-derive it, and both told explicitly **this is a pre-implementation plan, not merged code** — "the code still does X" is a false positive. Call A: integration edges and external-system semantics (datastore corner cases, runtime edges, wire-format asymmetries, deploy ordering of code vs migration). Call B: cross-layer asymmetries, round-trip fidelity, error contracts, tenant scoping, async/retry semantics, plus necessity over the whole plan. Unset → `second-opinion-gate: NOT_RUN (reason: not configured)`; **set but errored, timed out, or empty → `NOT_RUN (reason: <error>)`**, never "no findings".

Dispatch both decisions' work in one batch. **Fact-check every second-opinion claim about the codebase** with Grep/Read before including it: an external model reasoning from snippets confidently invents file names, signatures, and column types. Present Verified and Unverified/Hallucinated separately, attributed, never silently dropped. Edit the plan again for what survives.

---

## Step 9: Final presentation + mandatory plan steps + close the loop

Show: `PRs:` line first; what changed since round 1; round-2 findings per source; the second-opinion verdict (or NOT_RUN with reason); remaining concerns; the final parallel execution map.

**Mandatory final plan steps** — confirm the plan carries each, add it if missing, or get explicit approval to defer:
1. A step to run **review-code** after implementation (it picks single vs collaborative itself).
2. The E2E close-out criterion from the test-plan audit: *build real E2E tests for <scope> AND execute them in-session against the implemented code; the plan is not closed until green output is captured.* Exempt categories (docs-only, type-only, infra-topology-only, internal scripts) must state the exemption.
3. Named adversarial test cases with the three-round structure visible.
4. A test baseline step where existing tests cover the area.

**Close the loop.** For every CRITICAL or WARNING the user proceeds past without resolving: re-read the final plan to confirm it is genuinely unaddressed, then **propose** a tracking issue — search for a duplicate first; show title, body (finding, why it is a risk, what the implementation must do), and the duplicate-search result; file **only after the user approves that issue in this session**. Necessity findings are never filed: they stay in the Simplification options block, surfaced not tracked. More than 3 unresolved CRITICALs → say so before proposing anything; that count says the plan needs more work, not more tickets. (`TRACKER` other than github: propose in the conversation; filing needs an adapter.)

**Save the plan** to `PLAN_DIR/<id>-<slug>.md` if it only exists in conversation (`<id>` per Configuration). Then always end with the handoff the implementer needs to start in a fresh context (adapt the command to your harness's context-reset mechanism):

```
Ready to implement? Clear context and preserve this plan:
/compact Approved plan: <plan-file-path> — begin implementation starting from Phase 1.
```

---

## Step 10: Pre-scaffold tests (optional, background)

If `TEST_PRESCAFFOLD = on` and the plan touches `CRITICAL_GLOBS`: dispatch the test reviewer in the background with the **prescaffold prompt** from `references/plan-reviewer-prompt.md`, pointed at the **saved plan in `PLAN_DIR`** (not the scratch copy — Step 11 deletes that) and the plan's file list. It pre-writes specs to their proper locations and must not run anything; its summary goes to `/tmp/test-prescaffold-<RUN_ID>.md`, outside the scratch dir. Don't wait for it. When review-code runs after implementation, its test reviewer extends and executes the pre-written specs instead of starting cold.

---

## Step 11: Teardown

Peer mode: graceful shutdown to each reviewer individually, acks overlap with your final writing (inbox snapshots happened in Step 6). Then `rm -rf <SCRATCH_DIR>` (literal path; an unsubstituted placeholder is a shell error and deletes nothing). If `OPEN_FILE_CMD` is set, open the saved plan for the user; a failure there is one line and not a review failure.

**Calibration (worked defaults — measure your own):** 1 reviewer under ~5 min; 3–5 under ~10; 6–10 reviewers 10–25; heavy cross-talk or two mediated rounds 25–40. Past 40, check progress directly. Cost per significant finding on a 10-reviewer collaborating run was roughly half the isolated-parallel figure on our repo.

---

## Anti-patterns

1. **Skipping assumption validation.** Reviewers then spend their budget rediscovering what one Grep would have settled.
2. **Writing the self-review first, dispatching reviewers after.**
3. **Seeding one reviewer's round-1 prompt with another's findings.** Compliance, not discovery. Mediated round 2 is deliberate, labeled, and governed by the CONFIRM-needs-new-evidence rule.
4. **Spawning peers serially.**
5. **Skipping the convergence pass.**
6. **Letting reviewers edit the plan.** Read-only except their own findings file; plan authoring is the author's job.
7. **Running the second opinion alongside the reviewers, on the un-edited plan, or with one lens only — or skipping it because round 1 was clean.**
8. **Trusting a second-opinion claim about code it has not read.** Fact-check every one.
9. **Raising a necessity finding to CRITICAL**, or writing "recommend dropping Phase 3." Options, sizes, facts; the user decides.
10. **Appending review notes to the plan instead of rewriting the affected sections.**
11. **Letting a reviewer's "done" message stand in for its completion marker**, in any mode.

---

## Reference

- `references/plan-reviewer-prompt.md` — base plan-reviewer prompt, peer and round-2 blocks, zero-context reader, test-reviewer plan prompt, prescaffold prompt
- `references/plan-audits.md` — the four built-in audits, the parallel map, and the extension point
- review-code `references/detection-table.md` — the shared table (required companion)
- review-code `references/harness-notes.md` — the Step 5a capability procedure and per-harness mechanics (required companion)
- Companion (required): review-code. Companion (recommended): bootstrap-agents.
