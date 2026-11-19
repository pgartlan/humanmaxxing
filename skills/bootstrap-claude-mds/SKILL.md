---
name: bootstrap-claude-mds
description: Survey a codebase and generate folder-level CLAUDE.md files for the directories that actually need local conventions documented — matches high-traffic, high-footgun folders against evidence found in the repo, proposes the folder list for human approval, generates evidence-only per-folder files, and runs a consistency check against the root CLAUDE.md. Re-running on an existing set of folder files runs a drift audit instead of regenerating.
user-invocable: true
allowed-tools: Read, Glob, Grep, Write, Edit, Bash(git *, find *, cat *, ls *, grep *, wc *)
---

# /bootstrap-claude-mds — generate the folder-level CLAUDE.md files your codebase actually needs

**Give this to your agent to generate and maintain the per-folder conventions files your codebase needs.**

Two ways to use this: (1) as an installed skill — drop this file at `.claude/skills/bootstrap-claude-mds/SKILL.md` and invoke `/bootstrap-claude-mds`; (2) as a plain prompt — paste the whole file into any fresh Claude Code session with access to your repo and say "run this." Every phase below is self-contained: no skill infrastructure required beyond normal file/shell tools and a working directory.

This skill runs **in the reader's repo, on the reader's folders** — every command below assumes `cwd` is the repo root being surveyed, not the repo this file shipped from.

Sibling of `bootstrap-agents` (same five-phase family, same pitch — read that skill's Configuration and Design Principles sections if you're deciding which to run first). Either order works once the root `CLAUDE.md` exists; the getting-started onboarding runs the roster first and this skill second. When this skill's survey shows that an existing agent states something a folder contradicts (a convention, a command), propose the edit to that agent file as its own item in Phase 2, shown as a diff — never edit it silently.

---

## Configuration — adapt these to your repo

```
CLAUDE_MD_PATH          — root project instructions file (default: CLAUDE.md). Phase 1 requires
                          this to exist before proposing anything — see "What this skill will
                          not do."
FOLDER_MD_DIRS          — the canonical directory list this run evaluates. Empty by default;
                          Phase 1 populates it from what the survey finds in THIS repo. Never
                          hardcode a directory list carried over from a different repo's run.
LINE_TARGET             — 15-40 lines per generated folder file (worked default). These files
                          auto-load into context on every turn spent working in that folder —
                          recalibrate down, not up, if you're unsure.
CHURN_WINDOW_DAYS       — lookback window for the churn signal (default: 60).
INTEGRATION_BRANCH      — the branch shipped work lands on (e.g. main); churn counts its history only.
                          Read the remote-tracking ref (`origin/main`) when the repository has a remote
                          (a local branch can lag behind it), the local branch otherwise.
CHURN_COMMIT_FLOOR      — commits touching a folder within CHURN_WINDOW_DAYS before it's
                          churn-eligible (default: 5).
FILE_COUNT_FLOOR        — files in a folder before it's file-count-eligible (default: 10).
SIBLING_EVIDENCE_FLOOR  — sibling files that must independently exhibit a pattern before it can
                          be stated as a convention (default: 3). A pattern seen in fewer files
                          is not a convention — it's a coincidence or a WIP; propose it to the
                          user as a question, never state it as a rule.
STALENESS_COMMIT_FLOOR  — commits to a folder since its CLAUDE.md was last touched before
                          Phase 5 flags it as potentially stale (default: 20).
EXCLUDE_DIRS            — directories never proposed regardless of file count or churn (default:
                          node_modules, dist, build, .next, vendor, any vendored or generated-
                          output directory — extend per repo).
```

**Companion:** the root `CLAUDE_MD_PATH` file. This skill has no independent function without one — see Phase 1 and the fail-safe rules.

---

## Design principles

1. **Most folders should NOT have a CLAUDE.md.** A file that auto-loads on every turn spent in that folder is a standing tax on every future session, not a one-time cost. The default output of a survey should be a short list, not a folder-by-folder inventory. If Phase 2 proposes more than roughly a third of a repo's top-level-plus-notable-second-level directories, that is itself a signal the bar was set too low — trim, don't rationalize.
2. **Evidence-only, never aspirational.** A convention stated in a generated file must be something the survey actually found repeated across `SIBLING_EVIDENCE_FLOOR`+ files, or something the user explicitly confirmed when asked. "What I couldn't determine" is a question in Phase 2, never a guess in Phase 3. A wrong convention is worse than a missing one — see Design Principle 4.
3. **One fact, one layer.** Root `CLAUDE.md` carries behavior that's true everywhere in the repo. A folder `CLAUDE.md` carries only what's true of *that folder and not elsewhere*. If a candidate convention turns out to be repo-wide once you check other folders, it belongs in the root file, not duplicated into every folder that happens to exhibit it. Every generated folder file gets diffed against the root file in Phase 4 specifically to catch this.
4. **A wrong CLAUDE.md is worse than none.** The agent that loads a folder's CLAUDE.md follows it with full confidence — it has no way to know the convention drifted since the file was written. This is why Phase 5 exists as a standing obligation, not an optional extra, and why every convention this skill writes should be phrased as something checkable (a grep, a file glob, a count) rather than a vibe.
5. **No wiring step — verification instead.** Unlike a generated subagent or a review-skill detection table, a folder `CLAUDE.md` needs nothing pointed at it; the harness auto-loads any `CLAUDE.md` found in the folder it's working in. So the phase that would otherwise be "wire it in" is instead a **consistency check**: does this file contradict the root file, and is every claim in it independently checkable by someone who isn't this skill.
6. **Human gate before every write, generation or maintenance.** Phase 2 gates initial generation. Phase 5 gates every subsequent change. Nothing in this skill regenerates a folder file wholesale on a re-run — maintenance mode proposes edits to specific lines and applies them with `Edit`, preserving anything a human hand-tuned since the last run.

---

## Phase 1 — Survey the codebase (read-only)

Cheap reads and greps only. Nothing is written in this phase.

**1a — Confirm the root file exists.** `[ -f "{CLAUDE_MD_PATH}" ]`. If it doesn't, stop here — see "What this skill will not do." Read it in full; Phase 2 and Phase 4 both need to know what it already covers so folder files never duplicate it.

**1b — Enumerate candidate directories.** Two independent passes, then union the results — a folder that clears either bar is a candidate, not both:

*File-count pass* (tracked files only, at any depth, so vendored and build output never count and a deep folder is not cut off):
```bash
git ls-files | awk -F/ 'NF>1{NF--; print}' OFS=/ | sort | uniq -c | sort -rn \
  | awk '$1 >= {FILE_COUNT_FLOOR}'
```

*Churn pass* (history of the integration branch only, so commits of an unmerged branch, such as an onboarding that is installing this skill, are not counted; agent-setup files are not churn):
```bash
git log {INTEGRATION_BRANCH} --no-merges --since="{CHURN_WINDOW_DAYS} days ago" --name-only --pretty=format: -- . \
    ':(exclude).claude' ':(exclude,glob)**/CLAUDE.md' ':(exclude,glob)**/AGENTS.md' \
  | grep -v '^$' | xargs -n1 dirname 2>/dev/null | sort | uniq -c | sort -rn \
  | awk '$1 >= {CHURN_COMMIT_FLOOR}'
```

On a large repo (thousands of tracked files) the default floors pass most folders: raise `FILE_COUNT_FLOOR` and `CHURN_COMMIT_FLOOR` to the 75th percentile of the two passes' counts, and say so in the Phase 2 proposal.

Both passes are cheap and mechanical — they tell you *where to look*, not *whether to propose*. The real filter is 1c and 1d.

**1c — Detect sibling patterns per candidate directory.** For each candidate, sample its files and look for a repeatable shape: a shared wrapper/decorator used across route handlers, a consistent file-naming scheme (`{slug}-{NNN}.ext`), a consistent header/import block, a consistent test-file convention. Quantify it — "N of M files in this folder do X" — because that count is exactly what Phase 2 must cite as evidence and what Phase 4 turns into a drift-check grep. A directory with real file count but no detectable repeated shape (e.g. a grab-bag `utils/`) is a weak candidate regardless of how many files it has.

**1d — Detect footgun density.** Grep the folder's git history for signs the same mistake recurred: repeated "fix" commits touching the same file or narrow area, revert commits, or commit messages referencing the same symbol/bug repeatedly.

```bash
git log --since="180 days ago" --oneline -- <dir> | grep -icE '^\w+ (fix|revert|hotfix|:bug:|:ambulance:|🐛|🚑)'
```

The pattern covers conventional (`fix:`), plain (`Fix …`) and emoji-prefixed (`:bug:` or 🐛) messages; if the repo marks fixes another way (a ticket prefix, a word in the middle), adapt it before trusting a zero.

A high count here is strong evidence for a "local footguns" section even in a folder that's borderline on file count or churn alone — a small, rarely-touched directory that keeps producing the same mistake still deserves a short file warning about it.

**1d-ter — Deliberate decisions and agent-safety rules.** Sibling patterns and fix commits show what keeps going wrong; they do not show what *looks* wrong but is on purpose, or what an agent must never do here. For each candidate folder, read the plans, design records (ADRs) and guard code that name it (`git grep -l -e '<folder path>' -- docs '*.md'`, plus the scripts and hooks that check files in it) for two shapes: **"looks like a bug, is on purpose"** (a deliberate limit, a bounded change, a kept inconsistency with the decision that chose it: "do not mass-convert X; the scope is bounded on purpose, see `<plan path>`") and **"never bypass X"** (a guard with a human-only override, a flag or variable an agent must never pass or spoof to get past it). Each one found is a convention candidate with its source path as evidence; a guard's override rule is stated with who may use it (the user, per instance). These are the lines that stop an agent from "fixing" designed behavior or routing around a guard, which no sibling count reveals.

**1d-bis — Existing folder files against the root.** Find every folder-level `CLAUDE.md` (and `AGENTS.md`, if your harness reads it per folder) already in the repo. For each, sort its rules against the root file read in 1a: **duplicate** (the root already says it: propose deleting the copy, since two copies drift), **conflict** (the folder says the opposite of the root, or of another folder file on a path both cover: a question for the user, never resolved silently) and **folder-specific** (stays). Phase 2 shows these verdicts before any new folder proposal; an existing folder file is changed only through Phase 3's diff-and-approve path.

**1e — Explicit warning, read before Phase 2:** the signals in 1b-1d are a shortlist generator, not an approval. A directory clearing every numeric floor with zero detectable sibling pattern and zero footgun history is still a weak candidate — a folder file with nothing evidence-backed to say is a folder file that will drift into staleness immediately, because there was never a real convention to check in the first place. Most folders in most repos — a components dir with no shared wrapper, a scripts dir where every script is a one-off, a docs dir — should NOT get a CLAUDE.md. Say so explicitly in the Phase 2 proposal for any directory you're recommending against, not just the ones you're recommending for.

**Output of Phase 1:** a written survey table — directory, file count, churn count, footgun count, and the specific sibling pattern(s) detected with their file:line or sibling-count evidence. This is what Phase 2 quotes from; don't propose anything not traceable to a line in this table.

---

## Phase 2 — Propose the folder list (HUMAN GATE — BLOCKING)

**No file is written in this phase or before it. This gate cannot be skipped, including on a re-run.** With zero qualifying folders there is nothing to approve and no question: report "considered, nothing proposed", with the survey table's top candidates and why each fell short, and end the run.

**2a — Present each qualifying folder** with:
- Why it qualifies (cite the specific 1b/1c/1d numbers — "14 files, 9 commits in 60 days, 14 of 14 route files wrap the handler in the same auth helper").
- 2-4 candidate conventions, each with its evidence: a sibling-count ("11 of 12 test files import the shared fixture from `./helpers`") or a `file:line` pointer, never a description with no backing count.
- An estimated line count for the generated file (should land near `LINE_TARGET`; if your estimate is pushing well past 40, say so and ask whether to split the folder into two files or trim scope).
- Anything the survey couldn't determine that would improve the file — asked as a direct question, not silently omitted or guessed.

**2b — Present folders considered and rejected**, one line each, with the reason (file count/churn cleared the floor but no repeatable sibling pattern found; footgun count was noise from an unrelated bulk rename; the folder's real convention is already stated in the root file). This list matters as much as the accepted list — it's the evidence that the skill isn't defaulting to "generate for everything."

**2c — Wait for explicit approval.** Accept: approve as-is, approve with named changes (add/remove a folder, add/remove a specific convention within a folder), or reject entirely. A question is not approval; do not proceed to Phase 3 on an ambiguous response. Log the approved folder list and, per folder, the approved convention set — this is what Phase 3 generates from and what Phase 5 diffs against on the next run.

---

## Phase 3 — Generate the files

For each approved folder, write `<folder>/CLAUDE.md` using only the conventions approved in Phase 2.

**Before writing, check for collision.** If `<folder>/CLAUDE.md` already exists — a re-run, or a hand-authored file with the same name — **do not overwrite it silently.** Show the diff between the existing content and the proposed content, and get explicit approval before applying it. An existing file at this path is itself evidence someone may have hand-tuned it since any prior run of this skill.

**Content rules — every generated file follows these, no exceptions:**

- **Evidence-only.** Every stated convention traces to a Phase 2 evidence line (a sibling-count or `file:line`) or an explicit user confirmation captured during the gate. Nothing is stated because it "seems like it should be true" of a folder like this one.
- **One-layer discipline.** Before writing a line, check it against the root `CLAUDE_MD_PATH` content read in 1a. If the convention is actually repo-wide (it showed up as a real pattern in more than one unrelated folder during survey), do not write it into this folder's file — flag it as a candidate root-file addition instead and say so in the Phase 4 report. A folder file that repeats "fail loudly" or "never commit without asking" has failed this rule.
- **Small.** Target `LINE_TARGET` (15-40 lines). This is a hard per-turn cost, not a style preference — trim the least-actionable convention before padding out to a round number, and never both. **A safety rule is never what gets trimmed** (a "never bypass X" line, a deliberate decision from 1d-ter, an irreversible-operation warning): when the file is over its target, shorten it to one line that links to its full source instead of dropping it. Length pressure falls on conventions whose violation a check or review would catch anyway.
- **Checkable.** Every convention should be phrased as something a reader (human or the next agent) could verify without asking anyone — a command, a grep, a file glob, a count. "Follow good testing practices" is not checkable; "test files import fixtures from `./helpers`, never redefine them inline (11/12 files)" is.
- **No AI-attribution header, footer, or comment.**

**Shape per file** (adapt section names to the folder's shape, but keep this order):

1. **What this folder is** — one to two sentences. Not an architecture essay; the code already says what it does structurally. This line orients a reader who just landed here, nothing more.
2. **Conventions** — each one a checkable rule, cited with its evidence count inline or in a short parenthetical (mirrors what the root README's genericization discipline demands of *this skill's own* worked examples — real numbers, not vibes).
3. **Local footguns** — only if 1d found something. State the pattern anonymously ("a change here that doesn't also update the sibling config in `../other-dir/` silently breaks X") without a citation that identifies an internal tracker, date, or person — the lesson survives without the incident report attached.
4. **Verification** — the folder's real test/lint/build commands, taken from what Phase 1 actually found runnable for this folder specifically (not the repo-wide command if this folder has its own).
5. **Cross-references** — paths only, not inlined content, to related folders or root-level docs the reader might need next.

Two optional sections, each only when the survey found something to put in it:

- **Placement** (placed first, before Conventions, as "Before creating a file here: decide where it goes") — for a folder where *where* a new file goes changes whether it is checked, collected or conflicts with other PRs (a test folder whose subfolders are typechecked differently, a migrations folder with a generator). The rule and a link to its full source.
- **Enforced by** (after Local footguns) — the hooks, CI checks or scripts that already enforce this folder's rules, as paths, so a reader knows which rules fail loudly and which rest on the reader. A rule with no enforcer is not listed here.

---

## Phase 4 — Verify (consistency check, not wiring)

Folder `CLAUDE.md` files need no wiring — the harness auto-loads whatever `CLAUDE.md` it finds in the folder it's working in. This phase instead checks that what got generated is internally consistent and independently checkable.

**4a — Root-duplication check.** Read `CLAUDE_MD_PATH` again and diff every generated line against it. Any generated convention that restates or contradicts a root rule is a defect — remove the duplicate (root already covers it) or resolve the contradiction (one of the two is wrong; ask the user which). Report every hit, even ones you fix, so the user can see the check actually ran.

**4b — Checkability emission.** For every convention that has a mechanical form, emit the exact one-line grep or glob a reader could run to verify it still holds right now. This is not extra work — it's the same evidence-gathering command from Phase 1c/1d, saved rather than thrown away. This becomes Phase 5's drift-check command for that convention; write it down now rather than re-deriving it later.

**4c — Report, per folder:**

```
| Folder | Action | Lines | Root-dup hits | Convention count | Drift-check commands emitted |
```

`generated` / `skipped — <reason>` for every folder considered in Phase 1, not just the ones written — the same completeness discipline as Phase 2's rejected-folder list.

---

## Phase 5 — Maintenance mode (drift audit, not regeneration)

Triggered by running this skill again against a repo that already has one or more folder `CLAUDE.md` files (find them with `git ls-files '**/CLAUDE.md'`, excluding the root). **This phase proposes; it never applies without approval, and it never rewrites a whole file.**

**5a — Re-run Phase 1's survey**, fresh, on the current repo state.

**5b — For every existing folder CLAUDE.md, re-run its drift-check commands** (emitted in 4b, or re-derive them if this file predates that step — treat a missing drift-check command as itself a finding: "no checkable form on record, re-deriving").

- **A convention whose command now returns evidence below `SIBLING_EVIDENCE_FLOOR`, or contradicts current code** → propose an edit or removal. State it exactly as Design Principle 4 requires: *a wrong CLAUDE.md is worse than none — the agent will follow it confidently.* Don't soften this into "consider updating."
- **A referenced path, function, or command that no longer exists** → definitely stale, propose removal or correction, don't leave a dangling pointer.
- **A folder whose CLAUDE.md has had zero commits to the folder itself in `CHURN_WINDOW_DAYS`, or whose staleness exceeds `STALENESS_COMMIT_FLOOR` commits since the file was last touched** → flag for review; either the folder went quiet (file may just be stable and correct — say so) or it kept changing without the file keeping up (more likely stale — say so).
- **A file that looks hand-edited since generation** (content doesn't match what the prior run would have produced, and there's no record of this skill having made that edit) → do not touch it. Note the divergence and exclude it from auto-proposed changes, even if a command inside it looks stale — a human may have deliberately kept it that way.

**5c — Diff against the current folder-qualification signals** for newly-qualifying folders (same 1b-1d thresholds) not yet covered → propose additions, same evidence bar as Phase 2.

**5d — Present the diff, wait for approval, apply via `Edit` only.** Same gate discipline as Phase 2. No silent regeneration, no silent removal.

---

## Worked example — what Phase 3 actually writes

A survey of a fictional repo `northwind-api` finds a `routes/orders/` directory: 16 files, 11 commits in the last 60 days, and — via 1c — 14 of 16 route handlers wrapping their body in `withOrgScope(...)` before touching the database; the other 2 are read-only health-check routes that don't touch tenant data. Footgun pass (1d) turns up three historical "fix" commits, all involving a route that queried the DB before the `withOrgScope` wrapper ran.

Phase 2 proposes this folder with those two conventions and their evidence, the user approves as-is, and Phase 3 writes `routes/orders/CLAUDE.md`:

```markdown
# routes/orders/

Order-resource HTTP handlers. Sibling handlers under `routes/orders/**` share the
patterns below — check both before adding a new one.

## Conventions

- Every handler that touches the database wraps its body in `withOrgScope(...)`
  BEFORE the first query (14/16 handlers; the 2 exceptions are `GET /health` and
  `GET /ping`, which are intentionally org-agnostic).
- Verify: `grep -L withOrgScope routes/orders/*.ts | grep -v -E 'health|ping'`
  should return nothing.

## Local footguns

A handler that runs its first DB query before calling `withOrgScope(...)` returns
cross-tenant rows instead of erroring — the scoping wrapper narrows the query, it
doesn't gate access. This has recurred three times historically on new handlers
copy-pasted from an older file that predates the wrapper convention.

## Verification

`npm run test -- routes/orders` — route-level integration tests live alongside
the handlers as `*.test.ts`.

## Cross-references

- Org-scoping helper: `lib/auth/with-org-scope.ts`
- Root conventions: `../../CLAUDE.md`
```

23 lines, every claim traceable to a Phase 1 count, the grep in "Verify" is exactly what Phase 5 re-runs next time, and nothing here repeats a root-level rule (multi-tenancy is already a root concern in the fictional repo's `CLAUDE.md` — only the *specific handler-level mechanism* for enforcing it in this folder is folder-local, so only that part is written here).

---

## What this skill will not do

- **It will not run the repo's build, deploy, test, or migration-apply commands.** Phase 1 reads manifests, directory listings, and git history; it greps for evidence, it does not execute the project. A command string found in a `package.json`/`Makefile`/CI config is recorded for the "Verification" section, never run, during survey.
- **It will not generate a folder CLAUDE.md if the root `CLAUDE_MD_PATH` doesn't exist.** The folder layer exists to keep the root contract small by pushing local detail out of it — generating folder files with no root file to diff against produces orphan conventions with nothing anchoring what's repo-wide versus folder-local. If there's no root file yet, say so and point at a root-CLAUDE.md-template artifact instead of proceeding.
- **It will not propose a CLAUDE.md for every directory that clears a numeric floor.** File count and churn are shortlist signals, not approval criteria — see Phase 1e. A folder with real traffic but no detectable convention and no footgun history gets an explicit "considered, not proposed" line, not a file.
- **It will not state a convention observed in fewer than `SIBLING_EVIDENCE_FLOOR` files without asking the user first.** A guess dressed as a rule is the exact failure mode Design Principle 4 warns about.
- **It will not overwrite an existing folder CLAUDE.md without showing a diff and getting approval** — identically in Phase 3 (generation-time collision) and Phase 5 (maintenance-time drift).
- **It will not touch any file outside the approved folders' `CLAUDE.md` files.** Application code, tests, and CI config are read for survey purposes only; the root `CLAUDE_MD_PATH` file is read, never edited, by this skill (a repo-wide convention discovered mid-survey is *reported* as a root-file candidate, never silently written there).

---

## Fail-safe rules (apply across every phase)

- **Human gate before any write, both generation (Phase 2) and maintenance (Phase 5).** No fast path skips it, including on a re-run that "looks obviously fine."
- **Never overwrite an existing folder file without showing a diff and getting explicit approval** — same rule at the Phase 3 collision check and the Phase 5 drift-apply step.
- **Absence fails toward asking, not guessing.** No root file → stop and point elsewhere (see "What this skill will not do"). A convention below the evidence floor → ask, don't state. An undetectable test command for a folder → mark `UNVERIFIED` and ask, never invent one.
- **`Edit`, never `Write`, on anything that already exists.** A `Write` call on a stale cached read of an existing folder file silently restores deleted content with no error — the same failure class the root README's own policy-file discipline exists to prevent.
- **A wrong file is worse than a missing one.** Phase 5 treats a convention that no longer holds as an active defect requiring a proposed fix, not a low-priority cleanup item — the agent reading a stale folder file has no way to know it's stale.
- **A rejected folder stays rejected until the survey changes, not until someone asks again.** Re-running Phase 1 and finding the same folder still below every floor is not grounds to re-propose it "just to check" — only a genuinely new signal (crossed a floor, a footgun that wasn't there before) reopens the question.

---

## Notes

- **Critical path:** survey (read-only) → propose (human gate, blocking) → generate (per-file collision check) → verify (consistency check, not wiring) → done. Maintenance mode replaces "generate" with "diff + propose + `Edit` on approval," same as its sibling skill, and nothing else changes.
- **Calibrate the numbers.** `FILE_COUNT_FLOOR` (10), `CHURN_COMMIT_FLOOR` (5), `SIBLING_EVIDENCE_FLOOR` (3), and `LINE_TARGET` (15-40) are worked defaults tuned for a mid-sized service repo — a large monorepo may need higher floors so the folder list doesn't balloon; a small single-purpose repo may only ever clear the bar for one or two folders, and that's a correct outcome, not under-generation.
- **This skill's own output should pass the same bar it enforces.** A generated folder file with an unverifiable claim, a repo-fact leak, or a convention nobody can check is the same defect class this skill exists to prevent everyone else from shipping.
