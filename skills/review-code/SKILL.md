---
name: review-code
description: Code review for a PR or local changes — requirement-fidelity check, external review tooling, domain-expert reviewers (collaborating when two or more apply), a fix pass, an optional second-opinion gate on a different model, and a focused verification pass. Writes the review and E2E sentinels a companion ship skill checks before merge.
user-invocable: true
allowed-tools: Agent, Bash(gh pr view *), Bash(gh pr list *), Bash(gh pr comment *), Bash(gh issue view *), Bash(gh issue list *), Bash(git *), Bash(cat *), Bash(mktemp *), Bash(mkdir *), Bash(chmod *), Bash(cp *), Bash(mv *), Bash(rm *), Bash(grep *), Bash(stat *), Bash(touch *), Bash(date *), Bash(echo *), Bash(printf *), Bash(sha256sum *), Bash(sort *), Bash(cut *), Bash(sed *), Read, Glob, Grep, Skill, Write, Edit, ToolSearch, Bash(bash .claude/skills/review-code/bin/reviewer-fold.sh *), Bash(bash .claude/skills/review-code/bin/lens-score.sh *), Bash(bash .claude/skills/review-code/bin/wait-for-findings.sh *)
---

# /review-code — multi-perspective code review

Review a diff (an open PR, or the branch's committed plus uncommitted changes) in six stages: a **requirement-fidelity** check, **external review tooling**, **domain-expert reviewers** chosen from the changed paths, a **fix pass**, an optional **second-opinion gate** on a different model or provider, and a **focused verification pass** — closing with a findings log and the sentinels a companion ship skill reads before it lets a critical-path diff merge.

The product here is the **orchestration pattern**: the stage order, the gates between stages, and the rule that no finding ships unverified. Swap in your own reviewers, globs, and tooling and it runs on any repo.

**One skill, one decision made for you.** When two or more domain reviewers match the diff, they run as a collaborating group (Step 5 picks the mechanism your harness supports). When one matches, it runs alone. The zero-context reviewer runs in every mode. You never choose between a "single" and a "team" review — the skill does, from the diff.

**No mid-run pause for a context-compaction suggestion.** This skill runs long; don't interrupt it to offer one. **Review does not wait for green CI** — its findings are most valuable before the first deploy, so when a ship flow invokes it, run it alongside the first CI cycle, not after.

---

## Configuration — adapt these to your repo

Every value the skill references more than once lives here. Fill it once at install; the onboarding interview collects most of it. **Any command you put in a slot must also be added to `allowed-tools` above** (the list ships with only the skill's own needs).

```
BASE_BRANCH            — the branch PRs merge into (merge-base for every diff below)
SHIP_STATE             — sentinel directory shared with your ship skill:
                         SHIP_STATE="$(git rev-parse --git-path ship-state)"; mkdir -p "$SHIP_STATE"
QUALITY_GATE_CMDS      — TYPECHECK_CMD / LINT_CI_CMD / BUILD_CMD / SECRET_SCAN_CMD / SAST_CMD /
                         TEST_CMD. If you have a ship skill, these are ITS slots — reference them,
                         never copy them. If you don't, define them here; they are required either way
                         for the checks your repo has (SECRET_SCAN_CMD scans what git would commit, never
                         git-ignored files). A check with no command is NOT launched in 0d (an empty
                         command exits 0 and would read as PASS); the report lists it as not configured
UNIT_TESTS_IN_REVIEW   — local | ci | none (default: local). local: TEST_CMD runs in the Step 4
                         gate. ci: review never runs unit tests, reports "deferred to CI", and
                         ship's PR check gates them. none: no unit tests exist yet (the review
                         says so, in bold, every run)
PROTECTED_FILES        — files whose change needs explicit human approval before ANY review step
                         (a schema/state-version marker, a pricing table, a kill-switch config).
                         Empty is valid; Step 0b then prints "none configured". A repository
                         that keeps them in `.claude/protected-files.txt` (one glob per line,
                         the list the protected-file guard hook reads) sets
                         `see .claude/protected-files.txt`: read that file, never a second copy.
                         With that pointer the gate checks the file's globs PLUS the guard's
                         always-protected files: `**/.claude/settings.json`,
                         `**/.claude/settings.local.json` (in any folder), `.claude/hooks/**`
                         and the list file itself. The globs follow the guard's spelling: paths from the
                         repository's top, `**/` spans folders, `*` and `?` do not cross `/`.
                         The list file missing or unreadable → STOP, never "none configured"
DOCS_ALLOWLIST         — ERE over paths that cannot change runtime behavior (worked default
                         (\.md$|\.txt$|^docs/|(^|/)CHANGELOG)); excluded from the tree fingerprint the
                         sentinels bind to, so a docs subagent writing after the review cannot invalidate
                         them. DOCS_KEEP_BOUND — ERE re-including docs a check or test reads as input.
                         Both shared with the ship skill's ship.env
CRITICAL_GLOBS         — paths whose change requires real E2E coverage before the E2E sentinel can
                         be written: one glob per line in a file (worked default
                         .claude/critical-paths.txt), the same file the ship skill reads as
                         CRITICAL_GLOBS_FILE. Empty is valid and means every diff is E2E-exempt;
                         Step 10 says so, in bold
DETECTION_TABLE        — references/detection-table.md: changed-path globs → reviewer agents.
                         bootstrap-agents writes it; review-plan reads the same file
REQUIRED_AUDITS        — references/audits.md: the main-thread audits Step 6 runs. Two are built
                         in and always on; the rest are yours (trigger glob + procedure)
PLAN_DIR               — where implementation plans are saved (Step 1a's second requirement
                         source); plans named <issue-or-slug>-<slug>.md. Empty if you keep none
EXTERNAL_REVIEW_TOOLS  — zero or more review plugins/scanners Step 1d dispatches, each with its
                         invocation and whether it needs a PR. Empty is valid: Step 1d is skipped
                         and the coverage line says so
SECOND_OPINION_CMD     — how to call a model/provider DIFFERENT from the one running this
                         session (Steps 1c and 9). It sends the requirements and the diff to that
                         provider: fill it only with the user's consent to that. Call contract: the
                         prompt (instructions, requirements, diff) on stdin; the review as plain
                         text on stdout; exit 0. Any other exit, a timeout or empty output →
                         NOT_RUN with the reason. The key comes from the provider CLI's own login
                         or a 0600 file the command reads, never on argv. Unset: both steps record
                         NOT_RUN (reason: not configured)
REMOTE_TEST_DISPATCH   — optional command that runs a test suite somewhere other than this box.
                         Set: the test reviewer records a `## Pending remote run` instead of
                         running suite-sized tests locally. Unset: bounded local runs
COLLAB_MODE            — auto | peer | mediated | isolated (default: auto; Step 5a)
REVIEWER_BUDGET        — tool calls per reviewer (worked default 30; raise for large diffs)
MAX_REVIEWERS          — the HARD TOTAL of reviewer agents for one review (default 5; the onboarding
                         offers 3, 5 or 7): lens reviewers, the general reviewer, the zero-context
                         reviewer and any intent-fidelity agent all count; mechanical checks do not,
                         and the second pass reuses the same agents. Step 2: bin/reviewer-fold.sh
LENS_WEIGHTS           — how bin/lens-score.sh weighs a change (default: critical=3 code=1 config=1
                         test=0.5 docs=0.1 per changed line; new_exec=25 permission=25 gate=40
                         deleted=10 per file). Any subset, as `key=value` words
SMALL_DIFF_SCORE       — a change scoring below this earns ONE reviewer for every lens, and Step 11
                         runs only after a BLOCK (default 60)
REVIEWER_STEP_SCORE    — at SMALL_DIFF_SCORE the change earns two reviewers, then one more per this
                         many further points, never above MAX_REVIEWERS (default 150)
LENS_MIN_SCORE         — a lens scoring below this never runs solo; it folds into another reviewer
                         (default 40)
LENS_CHECK_<agent>     — optional mechanical check for one lens (a lint, a leak scan), run first in
                         Step 2: exit 0 clean, non-zero found. Clean and below LENS_MIN_SCORE → that
                         lens gets no agent; found → it may run solo. Default: none
TRACKER                — github | none. github: the adapter Steps 1a and 13 use. none: no tracker
                         (work starts from a task described in words): Step 1a skips the linked
                         issue (rung 1) and the close-out keyword check, and says so; Step 13
                         lists proposed tickets in the conversation and the findings log, and
                         files nothing
ISSUE_CLOSE_KEYWORD    — the closing keyword your PR bodies use (default: Closes). Commit
                         messages use Refs only — see Step 1a for why
FINDINGS_LOG_DIR       — one file per branch, e.g. docs/notes/review-findings/
KNOWN_DEFERRALS        — features intentionally unbuilt (a provider not yet wired, a flagged-off
                         path) so fidelity review doesn't flag deliberate incompleteness
COMPONENT_ALIASES      — pairs of similarly-named integration points that are easy to conflate
                         (two sync pipelines, two meanings of "events")
TIMEBOX                — wall-time bound for the reviewer stage, total across rounds (worked
                         defaults in Step 14)
```

**Companion (recommended): a ship skill with a review gate and an E2E gate.** Step 14 WRITES the two sentinels its gates READ; the exact contract is `references/sentinels.md`. No ship skill? Step 10 still runs and prints pass/fail; Step 14 still writes the sentinels, nothing reads them, and the summary says so.

**Companion (recommended): bootstrap-agents**, which generates the reviewer roster and `DETECTION_TABLE`. Without it, write the table by hand from the worked example in the reference.

---

## Design principles (why the skill is shaped this way)

1. **Intent before quality.** A technically clean diff that solves the wrong problem is wasted review. Requirement-fidelity runs first and a Misaligned verdict stops everything else.
2. **Never review a red tree.** Reviewer tokens spent on a tree that doesn't typecheck, lint, or build are wasted on problems a two-minute check catches first.
3. **Pre-digest what's already known.** External tools and the fidelity check complete before reviewers launch, and hand them an "already flagged" list. Launch early and reviewers re-derive it.
4. **Collaboration beats isolation when domains overlap.** An isolated reviewer sees its slice; a reviewer who hears another's finding checks its own domain against it. Cross-domain blockers live in that gap. On our own calibration, a collaborating group found roughly 2× the blocking findings of isolated-parallel review at better cost per finding — recalibrate on your repo.
5. **Trust but verify, from every source, at every stage.** Every blocking finding — a reviewer's, the lead's, an external model's — needs a citation: file:line with a snippet from a Read/Grep, a docs URL with section, or reproducible script output. No citation → downgrade, never pass-through.
6. **The second opinion runs after the fix pass, not alongside the reviewers.** Run in parallel, an external model re-derives what the group is converging on (roughly half its findings were duplicates on our calibration). After fixes it is a genuine second look at the resolved diff.
7. **Sentinels make expensive greens reusable, and the writer/reader contract is exact.** Content-addressed and fail-closed: an uncomputable hash writes an obvious error token, never a value that could compare equal by accident.
8. **Fail-safe at every gate.** No requirement source → proceed but say so. A reviewer that returns nothing → report and get sign-off, never drop it. Zero matching reviewers → one general reviewer plus zero-context, never a silent skip. An unset or failed optional tool → NOT_RUN with a reason, never a bare zero. An unreadable diff or merge-base → HALT, never "unchanged".
9. **One file per branch for durable records.** An append-only shared log is a merge hotspot; every concurrent review conflicts on the same anchor line. (Note: a `merge=union` attribute does not save you — hosted merge queues ignore `.gitattributes` server-side.)

Severity vocabulary: reviewers write **BLOCK / REQUEST_CHANGES / SUGGEST / NOTE** in their files; the synthesis presents the same tiers as **CRITICAL / WARNING / SUGGESTION / NOTE**. One mapping, stated here once.

---

## Sequencing rules (read before executing any step)

- Step 0 is sequential: scope, protected gate, baseline, THEN fire the quality checks (0d) in the background. Nothing runs before the protected-files gate passes.
- Step 1's three lanes (fidelity subagent, external second opinion, external tools) run **in parallel with each other**; all must resolve before Step 5.
- Steps 2 and 3 (detection, scratch dir, git-log half) may run **during** the Step 1 wait.
- Step 4 (collect the quality gate, blocking) and Step 5 (reviewer launch) must NOT start before Step 1 resolves.
- Step 6 (main-thread audits) runs in the **same turn** as Step 5's dispatch.
- Steps 9 → 10 → 11 → 12 → 13 → 14 are strictly sequential; Step 14 writes both sentinels and is always last.

---

## Step 0: Scope, protected files, baseline, fire the gate

**0a — Scope.** A PR number given as an argument → PR mode: store number, URL, HEAD SHA. No argument → check for an open PR on the current branch. None → local mode. In every mode the changed set is merge-base → **working tree**:

```bash
BASE=$(git merge-base HEAD "BASE_BRANCH") || { echo "HALT: merge-base unresolved — fetch BASE_BRANCH and re-run; refusing to review an unknown file set"; exit 1; }
{ git -c core.quotePath=false diff --name-only "$BASE"; git -c core.quotePath=false ls-files --others --exclude-standard; } | LC_ALL=C sort -u
```

An empty substitution would silently degrade `git diff` to index-vs-worktree and hand reviewers a partial file set that reports clean; the guard is not optional. Record the mode; local mode skips any external tool that requires a PR (Step 1d) and says so.

**0b — Protected-files gate (BLOCKING).** Intersect the 0a set with `PROTECTED_FILES`. One changed → **STOP**, print exactly what changed and why it's gated, and require explicit in-session approval before any further step; log the approval verbatim. `PROTECTED_FILES` empty → print `Protected files: none configured` and continue. If 0a HALTed, this gate has not run; never treat an unreadable diff as "nothing protected changed". (A second, out-of-band factor — a CI status or a PR label that a human set — is a sound addition where you have one; chat approval alone is forgeable by a misread transcript.)

**0c — Baseline guard.** Every diff in this skill is merge-base → working tree, never `..HEAD`: review runs before ship commits, and a committed-only diff is empty on an uncommitted branch — every real finding would be mislabeled out-of-scope and dropped. If any external tool was handed a wider base (the default branch instead of `BASE_BRANCH`), filter its findings to the 0a set and label the rest `[OUT-OF-SCOPE-BASELINE]`.

**0d — Fire the quality gate (background).** A check whose command slot is empty is never fired (an empty command exits 0 and Step 4 would read PASS); Step 4 lists it as `not configured`. Classify the diff: **docs-only** (markdown, text, docs dirs — NOT hook scripts or settings, which are behavior-bearing) → skip, note the skip. **Infra-topology-only or type-only** → `TYPECHECK_CMD` + `LINT_CI_CMD`. **Anything executable** → the full `QUALITY_GATE_CMDS` set, plus `TEST_CMD` when `UNIT_TESTS_IN_REVIEW=local`. **On the branch as-is — do not rebase first; review the exact tree that will be PR'd.** Each check runs as its own backgrounded command under this exit-file contract:

```bash
mkdir -p "$SHIP_STATE"; rm -f "$SHIP_STATE/review-<name>.exit"            # 1. purge the stale exit file FIRST: an old green would satisfy Step 4 instantly
( <command> > "$SHIP_STATE/review-<name>.log" 2>&1; echo $? > "$SHIP_STATE/review-<name>.exit.tmp" && mv -f "$SHIP_STATE/review-<name>.exit.tmp" "$SHIP_STATE/review-<name>.exit" )   # 2. write the exit file LAST, atomically
```

Step 4 collects. An exit file that is missing after the bound is a TIMEOUT; one that is unreadable or non-numeric is a FAIL. Never anything else.

---

## Step 1: Requirement-fidelity + external lanes (parallel)

### 1a — Get the requirements (source-of-truth ladder)

Try in order; stop at the first hit:

1. **Linked issue** (PR mode, strongest) — read the PR body, extract the issue the PR closes, fetch its title and body.
2. **A plan file** in `PLAN_DIR` whose name carries the branch's leading issue number or slug (both modes).
3. **Synthetic intent from branch name + commit messages** (fallback) — findings from this source soften one severity tier; the narrative may itself be wrong.
4. **Nothing found** — print a visible notice and continue. Never silently skip; domain review still runs without requirement coverage.

**Close-out check (both modes; the orchestrator runs it, not the subagent).** The PR exists to close the issue(s) the work started from. Check that the PR body (or the plan's close-out section in local mode) carries `ISSUE_CLOSE_KEYWORD #N` for each of them; a missing one is CRITICAL (remedy: add the line). Separately scan every branch commit message and the PR title for closing keywords and flag any hit CRITICAL (remedy: reword to `Refs #N`). Why both directions: GitHub closes an issue named after a closing keyword *anywhere* in a commit message the moment that commit reaches the default branch — past every gate, at release time, on any flow where `BASE_BRANCH` is not the default branch. The PR body is the one place a close belongs; commits and titles carry `Refs` only. Deferred work with no home — "follow-up PR", a to-do list in the PR body, "validate later" — is CRITICAL: do it now, or register it where your process tracks post-merge obligations. `TRACKER=none`: the check is skipped; say so. Any other `TRACKER` than github needs an adapter for this check (not yet written); until then, run it by hand and say so.

**Recurrence verification (both modes; the orchestrator runs it).** The recurrence decision is made at plan stage — the start skill's Gate C writes `Recurrence-Verdict: #N DOWN — <mechanism>` and review-plan blocks a FLAT, UP or missing one — so this check verifies, it does not decide. Read every line of the plan (and, in PR mode, the PR body) that starts with `Recurrence-Verdict:`. For each closing-keyword target #N that has one, or that was closed before (the ticket's history shows a close or reopen):
- The diff delivers the DOWN mechanism → state it in one line with the file:line that delivers it.
- The diff does not deliver it → **CRITICAL** (remedy: make the code match the plan, or go back to plan review).
- The plan carries FLAT or UP for #N, or a previously closed #N has no DOWN line → **CRITICAL**: plan review missed it; back to the start skill's Gate C and review-plan, never a downgrade to `Refs`.
- A line that starts `Recurrence-Verdict:` but is not exactly `Recurrence-Verdict: #<N> <DOWN|FLAT|UP> — <mechanism>` → **CRITICAL** (malformed: nothing downstream can read it).

No plan and no verdict line on a never-closed ticket → skip, and say so in one line.

### 1b — Fidelity subagent (background, deep-reasoning model)

Prompt from `references/fidelity-prompt.md` with every slot filled: source, requirements verbatim, changed-file list, `KNOWN_DEFERRALS`, `COMPONENT_ALIASES`, and the close-out results from 1a. It returns Coverage / Scope / Intent / Breaking changes / Verdict (Fully, Mostly, Partially addressed, or Misaligned).

### 1c — External second opinion on the same question (background)

If `SECOND_OPINION_CMD` is set: same requirements + diff to a model/provider **different from the one running this session**, backgrounded. Unset → `second-opinion-intent: NOT_RUN (reason: not configured)`. **Set but errored, timed out, or returned no text → `NOT_RUN (reason: <the error>)`**, never "no findings".

### 1d — External review tooling (parallel wrapper agents)

For each entry in `EXTERNAL_REVIEW_TOOLS` that applies to this mode: dispatch a cheap wrapper agent whose only job is to invoke the tool, write its full output to `SHIP_STATE/review-<tool>.log`, and return a first line that classifies the result: `RAN (N findings)`; `NOT_RUN (reason: plugin-missing)`; or `NOT_RUN (reason: non-review-output)` when the output is methodology or setup text rather than findings. Never invoke a synchronous review tool directly — that serializes what should be parallel. Dispatch all wrappers in ONE message.

Before dispatch, if `git status --porcelain` is non-empty, print a **dirty-tree warning**: diff-based tools see the committed diff only; uncommitted work is invisible to them. Continue, and repeat the warning in the Step 8 synthesis. If the committed diff is empty, don't dispatch committed-diff tools at all — record `NOT_RUN (reason: empty committed diff; N uncommitted files invisible)`.

### 1e — Hard barrier + act on the verdict

Wait for 1b, 1c, and every 1d wrapper. Reconcile 1b and 1c: agree → consensus; differ on severity → stricter; conflict → present both, flagged.

- **Misaligned** → blocker. Report, stop. Do not spend reviewer tokens on quality review of the wrong requirement.
- **Fully / Mostly / Partially** → proceed.
- **3+ combined CRITICAL** (fidelity + tools; worked default) → offer a checkpoint: fix now and re-run, or continue and catalogue for the fix pass. Wait for the answer.

---

## Step 2: Detect reviewers (path-matching only — may run during the Step 1 wait)

Match the 0a set against `DETECTION_TABLE`. Print which reviewers matched and why. A file matching several rows matches several lenses — that is intended; the fold below decides how many agents carry them.

**Who reviews (classify → score → cap → launch).** Matched lenses are folded, never dropped (the one exception: a lens whose mechanical check ran clean and that scores below `LENS_MIN_SCORE` gets no agent, and the table says so), and `MAX_REVIEWERS` is a hard total of agents. (1) Run each matched lens's `LENS_CHECK_<agent>` first, if set. (2) Score: feed every (lens, matched file) pair to `bash .claude/skills/review-code/bin/lens-score.sh --base <merge-base> --weights "<LENS_WEIGHTS>"` (one tab-separated `<agent> <path>` line each); it weighs each file's changed lines by kind (a critical path ×3, code and config ×1, tests ×0.5, docs ×0.1) and adds the bonuses (a new executable, a changed permission or allowlist, a changed gate, hook or CI step, a deleted file). (3) Feed its `SCORE` lines to `bash .claude/skills/review-code/bin/reviewer-fold.sh --max <MAX_REVIEWERS> --fixed <1, plus 1 when Step 1a's fidelity check runs as an agent> --total-score <TOTAL> --small <SMALL_DIFF_SCORE> --step <REVIEWER_STEP_SCORE> --min-score <LENS_MIN_SCORE> --budget <REVIEWER_BUDGET> --agents-dir .claude/agents --agents-dir ~/.claude/agents --out-dir <SCRATCH_DIR>/hybrid` (Step 3 makes the scratch dir; run this right after it), one tab-separated line per lens: agent, score, critical (1/0), a one-word domain, `test`, `security` or `other`, and the check's result (`none`, `clean`, `found`). The total score earns the reviewer count (one below `SMALL_DIFF_SCORE`, then one per `REVIEWER_STEP_SCORE`, never past the cap); lenses are ranked by score, the protected ones first — the test reviewer (it writes the E2E sentinel) and the security reviewer when a critical path changed are never dropped, but they COUNT toward the cap and other lenses fold into them; the top lenses run solo and every other lens joins the agent of its domain, else the one with the lowest load, as a hybrid. **Print the decision table** (its `LENS` lines: each lens, its score, solo or folded into which agent and why, then `AGENTS`); `FOLD-RESULT FAIL`, or no `FOLD-RESULT` line at all → STOP and fix the input. A `RUN` line's `budget=` replaces `REVIEWER_BUDGET` for that agent (it grows by half per extra profile); a `HYBRID` line's file is that agent's prompt head (each profile's full agent file); only the `RUN` agents (`general` = the general reviewer) and the fixed ones go into `run.env`. The second pass (Step 11) reuses the same agents and never adds one.

The **zero-context reviewer** (no codebase access, reads the diff as a document) runs in **every** mode; it counts toward `MAX_REVIEWERS` (Step 2's `--fixed`) but not in the domain-reviewer count below. The count of *domain* reviewers that run (after folding) decides Step 5's shape: **0 → one general reviewer, isolated; 1 → that reviewer, isolated; 2+ → collaborating group.**

---

## Step 3: Scratch dir, run id, shared context

```bash
SCRATCH_DIR=$(mktemp -d /tmp/review-XXXXXX); chmod 700 "$SCRATCH_DIR"; mkdir -p "$SCRATCH_DIR/findings"
RUN_ID="rv-$(date +%s)-$$"
printf 'RUN_ID=%s\nEXPECT=%s\n' "$RUN_ID" "<name1>,<name2>,…,zero-context" > "$SCRATCH_DIR/run.env"   # every reviewer you will spawn, zero-context included. Mediated mode: <name>:R1,<name>:R2 per domain/test reviewer and zero-context:R1 — see sentinels.md "Expected markers"
touch "$SCRATCH_DIR/decisions.md" "$SCRATCH_DIR/flagged.md"   # placeholders so no reviewer ever reads a missing file
echo "SCRATCH_DIR=$SCRATCH_DIR RUN_ID=$RUN_ID"
```

Every Bash call is a fresh shell and agent prompts don't expand variables: substitute the **printed literal values** everywhere below. `run.env` is the durable copy of the expected-reviewer list — after a context compaction, read it back rather than remembering it; Step 14 re-reads it and refuses a shortened list. Reviewer `<NAME>`s are the roster names; each writes `SCRATCH_DIR/findings/<NAME>.md`.

- **`decisions.md`** (no tool dependency, run early): `git log` on every touched path for the last ~3 months → a PRIOR DECISIONS summary. Reviewers respect these by default; a genuine re-open is marked `RE-OPEN PRIOR DECISION: <ref> — reason: <new evidence>`.
- **`flagged.md`** (waits for Step 1e): CRITICAL + WARNING from 1b/1c/1d, tagged by source, under 500 words. **The `touch`ed placeholder does not satisfy Step 5's precondition** — the file must carry Step 1e's content, or the explicit line `(nothing flagged by earlier lanes)`.
- **`diff.patch`**: the merge-base → working-tree diff.

---

## Step 4: Collect the quality gate (BLOCKING — before any reviewer launches)

Collect every check fired in 0d with a **bounded** wait (worked default 20 minutes per check): the exit file exists and reads `0` → PASS; non-zero → FAIL; missing after the bound → TIMEOUT; unreadable → FAIL. **Any FAIL → STOP**, report every red, not the first. **TIMEOUT → report and stop**; never kill by command-string match on a shared box. Unit tests: `local` → `TEST_CMD` is one of the checks; `ci` → print `unit tests: deferred to CI` (never "green"); `none` → print **`unit tests: NONE EXIST`**. (We once let review rounds re-fire a full suite on shared runners after every fix: over a hundred full runs in a day and a half. Decide where unit tests run once, at install, and let review honor it.) All green → print one summary line for the synthesis preamble and proceed.

---

## Step 5: Launch reviewers

**Preconditions:** Step 4 green (or docs-exempt); Step 1e resolved; `flagged.md` populated (not the placeholder) and `decisions.md` written; `run.env` lists every reviewer about to spawn. Launch ALL reviewers in a single message with multiple `Agent` calls. Prompts come from `references/reviewer-prompt.md` with every slot filled; the test reviewer gets its specialized prompt from the same file; the zero-context reviewer gets its variant and **never the peer block**.

### 5a — Pick the collaboration mechanism

`COLLAB_MODE = auto` resolves by the procedure in `references/harness-notes.md` (harness identity first, then the one-time probe):

| Domain reviewers | Spawned agents can message each other (per harness-notes) | Mode |
|---|---|---|
| 0 or 1 | any | **isolated** |
| 2+ | yes (Claude Code, after the probe) | **peer** |
| 2+ | no (Codex, Copilot CLI, Cursor, Gemini CLI as of this writing) | **mediated** |

Record the mode in the report header. `peer` or `mediated` set explicitly override the row for 2+ reviewers; `isolated` forces single-pass review even on a multi-domain diff (say so in the report). With 0–1 domain reviewers every setting means isolated.

### 5b — Peer mode

- Spawn every reviewer in ONE batch; sequential spawning breaks cross-talk (a late reviewer misses DMs already sent).
- Domain reviewers and the test reviewer carry the peer block. The roster is pre-filled if your `Agent` tool takes a name, otherwise sent to every reviewer as the lead's first message right after the batch (harness-notes). The zero-context reviewer spawns in the same batch, outside the roster.
- Right after the spawn batch, arm the watcher as a background command (never a timer that re-invokes the skill): `bash .claude/skills/review-code/bin/wait-for-findings.sh --run-env <SCRATCH_DIR>/run.env --dir <SCRATCH_DIR>/findings --timeout <seconds>` (give the background call a harness timeout longer than `--timeout`), and run the same command once with `--check` to confirm its `MISSING:` list is the FULL expected list (that proves the names parse). Then end the turn with a one-line status; the watcher exiting is the guaranteed wake. A "done" message is a hint: confirm it with `--check`. Exit 0 → Step 7. Exit 124 (`MISSING: …`) → nudge each missing reviewer once and re-arm once; still missing → the Step 5 failure path below. Exit 2 or 3 → a bug on your side (a bad name, a wrong path): fix it and re-arm. The same script, same `run.env`, is the Step 14 hold. Mediated and isolated modes use it too.

### 5c — Mediated mode

Round 1 isolated, one batch. Then copy `findings/` to `findings/round1/`. Round 2 re-dispatches (or resumes) each domain reviewer with the others' BLOCK and REQUEST_CHANGES attached by domain and the round-2 block from the prompt file; the zero-context reviewer does not take part in round 2. Markers carry `R1` / `R2` (`<!-- REVIEW-COMPLETE <name> <RUN_ID> R2 -->`); `EXPECT` lists `<name>:R1,<name>:R2` for each domain and test reviewer and `zero-context:R1`, per the matching rule in `references/sentinels.md`. The round-1/round-2 diff is your inbox. Budgets and resume rules per harness are in harness-notes. **This reproduces peer mode's adversarial structure one round later and through you; it does not reproduce mid-review redirection or SUGGEST-tier hints** (harness-notes says exactly what is lost).

### 5d — Isolated mode

The matched reviewer (or a general reviewer when none matched) plus the zero-context reviewer, both with the base prompts, no peer block. Markers still required.

**A reviewer that cannot write files never stalls the review.** An agent with no `Write` tool (a hand-written agent the roster kept as it is) returns its findings in its reply instead. Take that reply and write it to the reviewer's findings file verbatim, with the line `(written by the lead from <name>'s reply: the agent cannot write files)` above its marker. It counts as complete only when the reply itself ends with the reviewer's exact marker; the lead never adds a marker the reply did not carry, and a reply without one is a missing reviewer (the failure path below). Say so in the report header, and name the agent as one to extend with `Write` and the findings-file clause (bootstrap-agents' keep / extend check).

**Completion is verified in every mode, never assumed.** A reviewer is complete when its file ends with its marker. A reviewer that exhausted its budget without writing findings, or is still missing after the one re-arm, is a FAILURE: **report it to the user and get an explicit decision** — re-run it with a tighter prompt or a larger `REVIEWER_BUDGET`, or continue without it. Continuing without it is recorded in the report header and **no sentinel is written in Step 14** (its hold reads the markers, and a missing one refuses): the findings still get reported and fixed, and the sentinel comes only from re-running that reviewer to its marker.

---

## Step 6: Main-thread audits (same turn as Step 5's dispatch)

These are file reads with no dependency on reviewer output; run them synchronously in the dispatch turn so they are done when reviewers return. `references/audits.md` holds the procedures. Two are built in and always on:

- **Test quality** — inline stubs, silent-ignore (a schema field accepted but never read by runtime code), and the three-round adversarial-coverage audit of changed tests.
- **Real E2E coverage** for every file matching `CRITICAL_GLOBS` — real boundary, executed in-session, more than the happy path. This feeds Step 10.

The rest of `REQUIRED_AUDITS` are yours: a trigger glob and a procedure each. The worked examples in the reference each exist because a review converged cleanly while the bug sat one file away. Every CRITICAL you raise here needs a `VERIFIED:` line.

---

## Step 7: Convergence pass (the lead's assurance layer)

After every expected marker is present (or the Step 5 failure path was resolved with the user):

1. **Peer mode: snapshot every inbox first.** Peer messages live in reviewers' inboxes, not your chat, and vanish at session end. **Mediated mode: your inbox is the `findings/round1/` vs `findings/` diff.**
2. **Read all findings files** (round 2 in mediated mode).
3. **Convergence-failure signals:** an unclassified finding; two reviewers BLOCKing the same thing with no shared resolution; a classification flipped after one exchange with no cited evidence (peer: in a DM thread; mediated: a round-1 finding changed without a self-DISPUTE entry); zero DISPUTEs group-wide; a CONFIRM whose citation restates the original's; a BLOCK with no file:line.
4. **Re-verify every BLOCK yourself** — run the Grep, Read the line, fetch the doc, run the script. Checks out → keep, mark `MAIN-CONFIRMED`. Doesn't → `MAIN-UNVERIFIED`, downgrade to REQUEST_CHANGES with the reason. None supplied → `UNVERIFIED`, downgrade. **Mediated: adjudicate every DISPUTE and ESCALATE yourself with both citations.** External-tool findings whose file:line can't be confirmed in-session → `[UNVERIFIED:external-tool]`, hold for a human spot-check, never auto-dismiss; they must be resolved with the user before Step 14. Any finding on a file over ~30KB from an external model → `[LARGE-FILE]` (worked default; external calls commonly truncate past ~800 lines).
5. **Adversarial re-read:** a cross-domain concern no one owns? Two or more findings on one component — is the component the right mechanism at all, or are we patching the wrong thing? Something your Step 1 or 6 work surfaced that no reviewer raised?
6. **Decide APPROVE-CONVERGENCE or DISSENT.** DISSENT when one domain expert cites concrete evidence against a general-knowledge consensus, the downside of being wrong is severe (data corruption, security exposure, unrecoverable state), and more reading won't settle it (mediated: one targeted re-dispatch to the two parties first). State the finding, the counter-evidence, your reasoning, and a specific resolution test. Never DISSENT over style or an unsupported claim.

---

## Step 8: Present findings + fix pass

Synthesize Step 1 (fidelity, second opinion, tools), Step 6 (audits), Step 7 (reviewers) — deduplicated, attributed to every source that flagged it, ordered CRITICAL / WARNING / SUGGESTION / NOTE. Fidelity findings of Partially or Misaligned go first. Open with the header (mode, verdict, reviewers that completed) and the **external-tool coverage** block: one `RAN (N)` / `NOT_RUN (reason)` line per lane. PR mode: post as a PR comment. Local mode: present in the conversation.

### 8a — Triage before fixing anything

| Fixable findings | Strategy |
|---|---|
| 1–5 | Solo, sequential |
| 6–15 | One subagent + you, two non-overlapping file groups |
| 16–30 | 2–3 subagents in parallel, grouped by path or domain |
| 31+ | 3–5 subagents in parallel, grouped by domain; you coordinate and verify only |

Worked defaults; print the decision first. Starting solo on a long list is the failure mode this table prevents. **Do not idle while fixers run** — write the findings log (Step 12's content), prepare Step 11's prompt, or take the next independent step. If nothing is runnable while they work, you under-decomposed.

### 8b — Fix policy

Default: **fix now**. Deferral needs one of exactly four cited reasons: **(a)** access-blocked — a named credential or permission you lack; **(b)** a behavior or API contract change beyond this diff's stated scope, with who depends on it named; **(c)** 5+ additional *named* files outside the diff that can't be folded in without changing its scope (worked default); **(d)** needs a deploy step, no in-session edit possible. "Pre-existing", "I'd need to think about it", "separate scope" with no named reason → fix it. Every fixer prompt names what the fixer may run locally: fixers lint their own files only; one typecheck for all groups runs in 8c.

### 8c — Verify and gather

One `TYPECHECK_CMD` + `LINT_CI_CMD` at the top level after fixers return. Consolidate fixed/deferred. **Do not commit** — report what changed; the user decides when to commit or ship.

**No re-run of the suites after the fix pass.** Once fixes land, do not re-run suite-sized checks (the full test suite, a remote dispatch, a whole-project scan) because "the tree changed since the last run". That is the stale-validation reflex: the next step is the ship, whose PR checks run the same suites on the exact pushed commit, so a pre-PR copy is duplicate runner time. (We once let it run after every fix round: over a hundred full suite runs in a day and a half.) What still runs: the typecheck and lint above, and a scoped run of one specific check that a fix in THIS pass targeted. Real E2E is not a suite under this rule: a fix that touches a `CRITICAL_GLOBS` file still re-runs Step 10b for that file. Say in the summary which fix edits have no run on the final tree; the PR's checks cover them. The handoff is the ship, not another verification round. The same holds after Steps 9 and 11.

---

## Step 9: Second-opinion final gate (after fixes land)

`SECOND_OPINION_CMD` unset → `NOT_RUN (reason: not configured)`; set but failed → `NOT_RUN (reason: <error>)`; either way continue and say so. Otherwise, **sequentially after Step 8** (Design Principle 6), two parallel calls on the updated diff, each given the Step 8 CRITICAL/WARNING summary so it doesn't re-derive them:

- **Call A — integration edges + external semantics:** datastore corner cases (NULL, coercion, version quirks), runtime edges, wire-format asymmetries, third-party behavior the diff doesn't fully specify.
- **Call B — cross-layer asymmetries + round-trips:** divergence between two languages or runtimes in your stack, save → reopen fidelity, error-envelope consistency, multi-tenant scoping, async/retry semantics across boundaries. Plus *necessity*: new surface that maps to no requirement, or re-implements an existing helper — WARNING at most, never on tests, error handling, observability, or tenancy guards.

Verify every finding in-session (Step 7 rule 4) before including it. Dismissed false positives go in their own section, attributed, never silently dropped. Fix what survives (Step 8b policy).

---

## Step 10: Real E2E ship gate (verdict only — the sentinel is written in Step 14)

**10a — Categorize.** Files matching `CRITICAL_GLOBS` are non-exempt. Exempt, with the reason stated: docs-only; type-only refactors; infra-topology changes with no runtime behavior; internal scripts with no production reach. `CRITICAL_GLOBS` empty → **every diff is exempt; print that in bold every run.**

**10b — Verify coverage for every non-exempt file** — a spec that exercises it at a real boundary, EXECUTED in-session with green output captured (a spec file existing is not enough), covering auth rejection, validation failure, and error responses, not just the happy path. A file under your E2E directory that mocks the datastore or imports the handler in-process is an integration test mislabeled, not E2E. Missing or unexecuted → **CRITICAL**: the test reviewer writes and runs them before this step can pass. If `REMOTE_TEST_DISPATCH` is set and the reviewer recorded a `## Pending remote run`, run that command now (background, bounded), read its verdict, and only then continue.

**10c — Record the verdict** (`E2E: green | exempt: <reason> | RED`) for Step 14. No ship skill → the verdict is still printed, and the summary says nothing downstream enforces it.

---

## Step 11: Focused 2nd-pass review

After Step 9's fixes land (on a change scoring below `SMALL_DIFF_SCORE`: only when Step 5 found a BLOCK; with the same agents), one re-review by the single reviewer that found the most issues in Step 5: same prompt, prepended with the fixed-findings list, asking for new or unresolved findings only. New CRITICAL/WARNING → fix and repeat, capped at 3 passes, then surface to the user. Nothing new and Step 8c was clean → continue; a fourth round is diminishing returns. **Any edit here invalidates the Step 10 verdict for the files it touched — re-run 10b for those files.**

---

## Step 12: Findings log

Write `FINDINGS_LOG_DIR/<slug>.md`, `<slug>` = the sanitized branch name (stable before a PR exists), **one file per branch, never an append to a shared file** (Design Principle 9). Draft it while Step 8's fixers run; finalize it here, in place:

```markdown
## YYYY-MM-DD — <branch> — <brief description>
- Mode: peer | mediated | isolated — Verdict: APPROVE-CONVERGENCE | DISSENT — Reviewers completed: N/N
- CRITICAL: N | WARNING: N | SUGGESTION: N | NOTE: N — Fixed: N | Deferred: N
- Per reviewer: <domain>: N, …
- Per source (actionable/total): fidelity, second-opinion-intent, each external tool, each reviewer, second-opinion-gate — a NOT_RUN lane renders as NOT_RUN (reason), never 0/0
- Top patterns: <e.g. "silent catches in handlers", "missing tenant scoping">
- Root cause + prevention (bug-fix diffs only)
```

---

## Step 13: Close the loop

For every item still deferred: **fix it now** if no (a)–(d) reason was cited; **propose a tracking issue** only for items with a verified reason — search for a duplicate first, show the user title, body (severity, reason, suggested fix, link to the findings log), and the search result, and file it **only after the user approves that issue in this session**; **discard** only informational notes. About to propose more than 3 from one review? Stop — that count says the fix pass was inadequate. No finding exits unresolved and untracked. A proposed ticket never keeps the originating issue open: it still closes at merge. (`TRACKER` other than github: propose in the conversation; filing needs an adapter.)

**Do not commit.** Continue to Step 14 — the review is not finished until the sentinels are written.

---

## Step 14: Sentinels + teardown (always last)

**Ordering.** Nothing that edits source may run after this step. Steps 11 and 13 can edit; that is why both sentinels are written here and not earlier.

**Hold — nothing is written if any of these holds:** a marker in `run.env`'s `EXPECT` is missing from `SCRATCH_DIR/findings/` (including after the Step 5 failure path ended in "continue without reviewer X"); an `[UNVERIFIED:external-tool]` finding has no user decision. On a hold, report exactly what is missing and stop — never write a sentinel by hand.

**The marker hold is mechanical: run it as the first command of the sentinel write, in the same Bash call, and write nothing unless it exits 0:**

```bash
bash .claude/skills/review-code/bin/wait-for-findings.sh --check --run-env <SCRATCH_DIR>/run.env --dir <SCRATCH_DIR>/findings \
  || { echo "HOLD: reviewer completion markers missing — no sentinel written. Report the MISSING reviewers; keep <SCRATCH_DIR>; never write the sentinel by hand." >&2; exit 1; }
# only now: compute the fingerprints and write the sentinels (below)
```

It reads `RUN_ID` and `EXPECT` back from `run.env` (written at spawn, so the list cannot be shortened or misremembered after a compaction). Never edit `run.env`, and never re-run the hold with a shorter list. **This is the ONLY place the marker hold is enforced:** the ship skill's reader checks the sentinel's fingerprint, not the markers, so a sentinel written by hand, or by a step that skipped this command, bypasses the hold entirely. A review that continued without reviewer X (the Step 5 failure path) still prints `MISSING: X` here and gets no sentinel: the way to a sentinel is re-running X until its marker is written.

**Write**, per `references/sentinels.md`, by its exact fingerprint procedure: `SHIP_STATE/review-code-ran` (always, once the hold clears), and `SHIP_STATE/real-e2e-shipgate-passed` (hash form when the Step 10 verdict is green, EXEMPT form when exempt, **withheld when RED** — ship then halts with "run review-code", which is correct). A `SENTINEL-ERROR` from the fingerprint → nothing written, HALT, report.

**Teardown.** Peer mode: send each reviewer a graceful shutdown and wait for acks (60–120 s); inbox snapshots already happened in Step 7. Then `rm -rf <SCRATCH_DIR>` (literal path). Keep it if the hold refused — the re-check after the missing reviewer finishes reads `findings/` and `run.env`.

**Calibration (worked defaults — measure your own):** 1 reviewer under ~5 min; 3–5 reviewers under ~10; 6–10 reviewers 10–25; heavy peer dialog or two mediated rounds 25–40. Past 40, check progress directly — if nothing has moved in 10 minutes, nudge or tear down. A 9–10 reviewer run with the second-opinion gate cost roughly 2–3× a single-reviewer review on our repo for roughly 2× the significant findings.

---

## Anti-patterns

1. **Skipping requirement-fidelity.** Clean code against the wrong requirement is wasted review.
2. **Launching reviewers before Step 1 and Step 4 resolve.** They re-derive tool findings and review a red tree.
3. **Seeding one reviewer's round-1 prompt with another reviewer's findings.** That produces compliance, not discovery. `flagged.md` is earlier-lane output tagged as unverified and open to dispute; mediated round 2 is deliberate, labeled, and governed by the CONFIRM-needs-new-evidence rule.
4. **Spawning peers serially.**
5. **Skipping the convergence pass.** It is the only check against sycophantic false convergence.
6. **Watching the chat thread for progress in peer mode.** Peer DMs are invisible there by design.
7. **Running the second opinion in parallel with reviewers, or with one lens only.**
8. **Treating sentinel existence as validity.** Hash AND TTL, independently.
9. **Letting a reviewer's "done" message stand in for its completion marker**, in any mode.
10. **Fixing solo on a long list, idling while fixers run, or letting fixers each run project-wide checks.**
11. **Writing a sentinel before the last source edit, or by hand when the hold refuses.**

---

## Reference

- `references/sentinels.md` — the exact fingerprint procedure and both sentinel formats (the ship-skill contract)
- `references/detection-table.md` — the changed-path → reviewer table (worked example; bootstrap-agents fills yours)
- `references/reviewer-prompt.md` — base reviewer prompt, peer block, round-2 block, zero-context variant, test-reviewer prompt
- `references/fidelity-prompt.md` — the requirement-fidelity subagent prompt
- `references/audits.md` — the Step 6 audits: two built in, extension point for yours
- `references/harness-notes.md` — the Step 5a capability procedure and per-harness mechanics (shared with review-plan)
- Companion: a ship skill with a review gate and an E2E gate — reads the sentinels
- Companion: bootstrap-agents — generates the roster and `DETECTION_TABLE`
- Sibling: review-plan — same stage structure for a plan instead of a diff; reads this skill's detection table and harness notes
