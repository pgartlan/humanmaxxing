---
name: retro
description: Weekly read-only retrospective over recent work — commit mix, fix chains, issues opened vs closed, recurring review findings, an audit of fixes that patched the instance instead of the class (and of guards added before repeats earned them), and whether this install is behind the latest HumanMaxxing release. Writes one report file; suggestions become issues or rules-file edits only when the user approves each one.
user-invocable: true
allowed-tools: Bash(bash .claude/skills/retro/bin/retro-data.sh *), Bash(git log *), Bash(git show *), Bash(gh pr view *), Read, Glob, Grep, Write, AskUserQuestion
---

# /retro — look back at the week, against your own rules

A short, regular look at what the last few days of work actually did: what shipped, what broke, which fixes needed a second and third attempt, which review findings keep coming back, and whether the fixes closed the class of bug or only the one instance someone reported. It ends with a few concrete process suggestions, each tied to the evidence behind it.

It is **read-only**. It writes one report file and changes nothing else: no commit, no issue, no edit to your rules, no update of the installed skills. Every suggestion becomes an issue or a `CLAUDE.md` edit only when the user approves that one suggestion. The skill's tool grant covers only its reads and the report; anything else (filing an approved issue, a fetch) goes through the normal permission prompt.

---

## Configuration — `retro.env`, next to this file

Copy `retro.env.example` to `retro.env` and fill it; the getting-started onboarding does this from answers it already has. The script parses the file and never sources it; nothing in it is run as a command.

```
BASE_BRANCH            — REQUIRED. The branch shipped work lands on (same value as ship and worktree)
BASE_REMOTE            — default origin; EMPTY for a repository with no remote
COMMIT_STYLE           — REQUIRED. conventional (feat:/fix:/docs:/chore:) | keywords (plain messages, sorted by
                         whole words; FIX_WORDS, FEAT_WORDS, DOCS_WORDS, CHORE_WORDS override the word lists)
FIX_CHAIN_MIN          — fix commits on one file or folder in the window that make a fix chain (worked default 3)
TRACKER                — REQUIRED. github (read-only gh queries) | none (git history only)
GH_REPO                — owner/repo the gh queries read (exported as GH_REPO; a gh command you type, e.g. 2d's
                         `gh pr view`, adds `--repo <it>`); empty = gh's default (the git remotes)
REPORT_DIR             — REQUIRED. Where the report goes, under your docs root (e.g. docs/retros)
FINDINGS_DIR           — your code-review skill's findings folder (review-code's FINDINGS_LOG_DIR); empty = not configured
SESSION_NOTES_DIR      — OPTIONAL. Where session or chat summaries are committed (ship's CHAT_SUMMARY_DIR); empty = not read
CLAUDE_MD              — your rules file (default CLAUDE.md); the repeat-bug threshold is read from its rule text
GUARD_GLOBS            — OPTIONAL. Patterns for files that are guards (lint rules, check scripts, hooks); empty = off
GUARD_BUDGET_PER_MONTH — OPTIONAL. New guards a month the report compares against (worked value 10): a tripwire on
                         guard growth, not a cap and never a target; empty = no budget
RELEASE_REPO_URL       — where HumanMaxxing releases are published (a git URL); empty = "release source not configured"
```

**The repeat-bug threshold** is not a setting here. It is the number your `CLAUDE.md` names in "Fix the Class, Not the Instance" → "Count the repeats" (the onboarding offers 7, the default, 5 or 3; below it, a fix adds no mechanical guard), read from the rule's own sentence, so the rule and this audit can never disagree.

**Companions (all optional).** A code-review skill that writes one findings file per branch feeds the recurring-findings section. `tools/hm-lock.sh` and `.claude/humanmaxxing.lock`, from the onboarding, feed the framework-currency section. Without either, those sections say they could not be filled, and why.

---

## Design principles

1. **Scripts hold the mechanical, the model holds the judgment.** Counting commits, grouping fix commits by file and folder, counting issues, comparing versions: a script does these the same way every week. Reading a fix PR and deciding whether it closed the class: that is the agent's work, and it cites what it read.
2. **A number that could not be read is not a zero.** A failed query, a missing `gh`, a list cut off at its limit: each is reported as unavailable, with the reason, and the report says so in that section. "0 issues opened" is only ever written when the tracker answered 0.
3. **A choice is not a failure.** No tracker, no findings folder, no release source: the section says it is not configured and the run is still complete. Something configured that could not be read makes the run partial.
4. **Read-only, always.** Reads need no permission; writes do. The retro reads git history, read-only `gh` queries (with `TRACKER=github`) and `git ls-remote`, and writes its own report file. Turning a suggestion into an issue, a rules edit or a skill update is a separate write the user approves, one suggestion at a time.
5. **Every suggestion carries its evidence.** "Add a guard for X" names the fix chain, the PRs or the findings that motivate it. A suggestion without evidence is an opinion; leave it out.
6. **The window is small on purpose.** A week of history is short enough to read the important parts, not just count them.

---

## Usage

- `/retro` — the last 7 days
- `/retro --days 14` — another window
- `/retro --download <dir>` — compare the install against a local HumanMaxxing download instead of the published release tags (any combination of the two flags works)

---

## Step 1: Gather the data (the script)

```bash
bash .claude/skills/retro/bin/retro-data.sh --days 7 [--download <dir>]
```

History, review-findings files and the rules file are read from the base branch the `REF` line names (its remote-tracking branch when there is one), never from the checkout, so a run from any worktree or branch sees the same week. The install record is the one thing read from the checkout, where the onboarding wrote it.

It never fetches. The `REF` line's `tip=` date shows how current that history is; if it is older than the user would expect, say so and ask whether to fetch first (a fetch updates this clone's remote-tracking branches, so it is the user's call). Never fetch on your own.

Route on the **exit code and the last line** (`RETRO-RESULT retro-data PASS|PARTIAL|FAIL ...`):

| Exit | Last line | What you do |
|---|---|---|
| 0 | `PASS complete` | every configured section was read: go on |
| 3 | `PARTIAL unavailable=<sections>` | go on; each listed section is written as "could not be read: <reason>" from its `UNAVAILABLE` line, never as a zero or an empty list |
| 2 | `FAIL <reason>` | configuration or usage: fix `retro.env` or the call, then run it again |
| 3 | `FAIL <reason>` | nothing could be read (not a git repository, the base branch unreadable): report it and stop |

The lines, one fact each, free text last:

```
WINDOW days=7 since=2026-03-02T09:00:00Z until=2026-03-09T09:00:00Z
REF refs/remotes/origin/main 4f2a9c1 tip=2026-03-09T08:12:40+00:00
REPORT path=docs/retros/retro-2026-03-09.md
COMMITS total=23 feat=6 fix=11 chore=4 docs=2 other=0 style=conventional
COMMIT 9b1e2d0 fix fix(auth): refresh the token before it expires
FIXCHAIN count=3 kind=file commits=1a2b3c4,5d6e7f8,9b1e2d0 src/auth/session.ts
FIXCHAIN count=4 kind=dir commits=1a2b3c4,2c3d4e5,5d6e7f8,9b1e2d0 src/auth
ISSUES opened=9 closed=6 net=+3
PRS merged=12 fix=5
PR 214 fix fix(auth): refresh the token before it expires
FINDINGS files=3
FINDINGS-FILE docs/notes/review-findings/214-token-refresh.md
NOT-CONFIGURED sessions reason=no-session-folder
THRESHOLD value=3 CLAUDE.md
NOT-CONFIGURED guards reason=no-guard-globs
CURRENCY source=tag tag=v0.4.0 installed=0.3.1 available=0.4.0 older=7 items=9
CURRENCY-ITEM older recorded=0.3.1 skills/ship
RETRO-RESULT retro-data PASS complete
```

A section that could not be read prints `UNAVAILABLE <section> reason=<token> [detail]` in place of its numbers (`UNAVAILABLE issues reason=gh-missing`, `UNAVAILABLE prs reason=truncated-at-1000`, `UNAVAILABLE currency reason=ls-remote-failed ...`); one that is switched off prints `NOT-CONFIGURED <section> reason=<token>`. Reasons worth knowing:

- `UNAVAILABLE fixchains reason=unparseable-path`: a fix commit touched a path with a tab or a newline in it. The `COMMITS` counts still stand; the fix chains could not be computed. `UNAVAILABLE findings reason=unparseable-path` and `UNAVAILABLE guards reason=unparseable-path` mean the same for those sections.
- `UNAVAILABLE currency reason=download-older-than-install`: the `--download` is older than an item the install recorded. Compare against a newer download; never merge "behind" items from this one.
- `UNAVAILABLE currency reason=hm-lock-failed`: `hm-lock.sh status` failed, including an exit 1 that named no behind or gone item.
- `UNAVAILABLE currency reason=lock-malformed`: the install record could not be read, including a recorded version that is not `x.y.z` (optionally with a `-suffix`).

With `GUARD_GLOBS` set, the `NOT-CONFIGURED guards` line is replaced by `GUARDS added=1 budget-per-month=2 days=7` and one `GUARD-FILE <path>` line per guard added in the window.

`kind=dir` chains count each commit once per folder; a folder chain that repeats a file chain adds nothing, and one that spreads across several files is the more interesting kind. `PR` and `COMMIT` types use the same `COMMIT_STYLE` rule.

---

## Step 2: The judgment

Do these in parallel where they are independent; dispatch the reading to cheaper subagents if your rules say so, and keep the conclusions on the main thread.

**2a — What shipped.** From the `feat` commits and PRs: the user-visible changes, grouped by theme, one line each. Not a commit list.

**2b — What broke, and the fix chains.** For each `FIXCHAIN`, read its commits (`git show --stat <id>` and the message): were the later fixes completing an incomplete first attempt, or new bugs in the same place? Name the root cause when the commits show it. A chain in a file is "the first fix was incomplete" until the commits say otherwise. `UNAVAILABLE fixchains reason=unparseable-path` → say the chains could not be computed (a path with a tab or newline), not that there were none. Also look across the `COMMIT` and `PR` lines for deploy whack-a-mole: several fixes in a row to the same deployment, release or environment configuration, each fixing what the last one broke. It hides from the file chains when each attempt touches a different file; name it as one incident.

**2c — Recurring review findings.** Read each `FINDINGS-FILE` as the base branch has it (`git show <REF>:<path>`; the checkout may be behind or on another branch). Group findings by kind (an unhandled error path, a missing test at a boundary, a query without its scope key), not by file, and list the kinds that appear in two or more files. Each is a candidate for a rule in `CLAUDE.md` or a guard (a guard only once the kind has repeated as often as the threshold says, per check 5 below). Where the files say which reviewer raised a finding and whether it was fixed or dismissed, also say which reviewers' findings were mostly real (fixed) and which were mostly noise (dismissed, disputed): a reviewer that is mostly noise costs every review and is a process suggestion of its own.

Session summaries are a source too: read each `SESSIONS-FILE` the same way (`git show <REF>:<path>`) and use what they record (decisions reversed, time lost, work abandoned) as evidence for 2b and 2f. `NOT-CONFIGURED sessions` → name it under "Sources not read".

`UNAVAILABLE findings reason=folder-missing` usually means no findings file has reached the base branch yet (normal for a new install until the first reviewed branch merges); a mistyped `FINDINGS_DIR` is the other cause. Say which in the report; never write it as zero findings.

**2d — Class-fix audit.** Sample the window's fix PRs (`PR <n> fix ...` lines): **all of them when there are 5 or fewer, otherwise 5**, the ones that touch a `FIXCHAIN` path first, then the most recent. For each, read it with read-only queries (`gh pr view <n> --json title,body,files`) and check it against your `CLAUDE.md`'s "Fix the Class, Not the Instance":

1. **Sibling sweep.** Did it fix the other sites that share the failing shape, or say why not? Check it yourself: grep the codebase for the shape the fix changed. Identical untouched siblings → instance-only.
2. **Repeat count.** Does the PR body state how many times this kind of bug has been fixed ("3rd fix of this shape: #A, #B"), as the rule's "Count the repeats" step asks? No count → instance-only.
3. **Threshold.** With `THRESHOLD value=N`: a fix whose count (stated, or the one you find in the history and tracker) reached N, and whose PR body neither suggested a guard nor said why none exists → flag it. At the threshold the fix **suggests** a guard and the user decides; a PR where the user declined the suggestion is correct, not a violation. `UNAVAILABLE threshold` → skip this check and say why.
4. **Came back.** A repeat that returned in the window after an instance-only fix (a fix chain whose earlier commit belongs to a PR you flagged, or a new issue describing the same shape) matters most in the whole retro: name both.
5. **Over-guarded (the same audit, the other direction).** With `THRESHOLD value=N`: a fix that added a mechanical guard (a lint or static-analysis rule, a check script, a hook, a new CI step or required check: a `GUARD_GLOBS` file when that is set, otherwise judge it from the PR's files) while its count, this fix included, was below N, or stated no count → flag it, **with the same weight as instance-only**. A guard is earned by repeats, never by a first occurrence: it costs every later change (run time, false positives, upkeep), and a rule that only ever adds guards grows them without limit. A below-threshold fix that closed the class with a class-level test and no guard is correct, not instance-only. A chokepoint the product code calls at runtime (one validated function, codec or factory the class routes through) is not a guard and is never flagged here; a standalone script that scans the code is a guard, whatever it is called.

With `TRACKER=none` or the PR lines unavailable, sample fix *commits* instead (their full messages stand in for the PR body) and say the audit was done on commits.

**2e — Framework currency.** From the `CURRENCY` line, one sentence:

- `source=download`: "HumanMaxxing <installed> installed, <available> available: <behind> items behind" (plus `gone` and `new` when non-zero). Behind items need a merge.
- `source=tag`: "HumanMaxxing <installed> installed, <available> available: <older> items recorded at an older release" — the tag cannot say which of them changed; a download and `hm-lock.sh status` can.
- Either way, point at the release's `CHANGELOG.md` entries between the two versions and at the update procedure: getting-started's "An installed skill is a copy" (merge each changed skill, keep your filled values, record it again). **The retro never updates anything itself.**
- A pre-release install (for example `0.4.0-rc.1`) counts as older than the `0.4.0` release.
- `NOT-CONFIGURED currency` → "release source not configured". `UNAVAILABLE currency` → its reason (`no-install-record`: the install predates install records; `download-older-than-install`: compare against a newer download and merge nothing from this one).

**2f — Process suggestions and metrics.** At most four suggestions (one question dialog holds four), each one: the pattern (with its evidence from 2b–2e), the change (a rule, a guard, a test, a skill update), and where it would land. Then the numbers to watch next week: the fix share of commits, the issue backlog's direction, fix chains, guard growth against its budget when configured. The budget is a tripwire the report compares against, not a cap: report the window's count against it, and when guards keep arriving faster than it month after month, say so.

---

## Step 3: Write the report

Write `REPORT path` (create the folder if needed) in this shape. Every section is present every time; a section whose source was not configured or could not be read says so in one line with the reason and gives no number ("Issues: could not be read (gh-missing)", never "Issues opened: 0"). The report is the only file this skill writes; it is not committed (the user decides whether to keep it).

```markdown
# Retrospective — <YYYY-MM-DD> (last <N> days)

Window: <since> to <until>, history from <REF> at <commit>.
Sources not read: <each NOT-CONFIGURED / UNAVAILABLE section with its reason, or "none">

## Summary
- Commits: <total> (feat <n>, fix <n>, chore <n>, docs <n>, other <n>), sorted by <conventional prefixes | keywords>
- Pull requests merged: <n> (<n> fixes)          — or: could not be read (<reason>) / no tracker configured
- Issues opened: <n>, closed: <n> (backlog growing by <n> | shrinking by <n> | flat)   — same rule
- Fix chains: <n> (<the top one, with its count>)
- Framework: <the one-sentence currency line>

## What shipped
- <user-visible change, grouped by theme, with its PR or commit>

## What broke
- <fix chain or incident>: <what kept breaking>, <root cause when the commits show it>, <commits / PRs>

## Recurring patterns
- <kind of finding> — seen in <n> findings files (<which>), and/or in the history (<evidence>)

## Class-fix audit
- Threshold: <N, from CLAUDE.md> — or: not found in CLAUDE.md (<reason>), threshold check skipped
- Sampled: <n> of <m> fix PRs (or: fix commits, no tracker) — <how they were chosen>
- Instance-only (siblings left, or no repeat count stated): <#n: what was missed>, or "none"
- Reached the threshold without suggesting a guard: <#n: its count, the guard that was due>, or "none"
- Came back after an instance-only fix: <earlier #n → later #m or commit, same shape>, or "none"
- Over-guarded (a guard added below the threshold): <#n: its count, the guard it added>, or "none"
- Guard growth: <added> new guards in <N> days against <budget>/month — or: not configured

## Framework currency
- HumanMaxxing <installed> installed, <available> available: <n> items behind (or: <n> items recorded at an older release)
- What changed: the release's CHANGELOG.md entries after <installed>, up to <available>
- How to take it: getting-started's "An installed skill is a copy" (merge each changed skill, keep your filled
  values, record it again). Nothing was updated by this retro.
- (or: release source not configured / could not be read: <reason>)

## Process suggestions
1. <the change> — because <the pattern, with its evidence from the sections above> — lands in <rules file | a guard |
   a test | a skill update>

## Metrics to watch
- <a number trending the wrong way, with this week's value, to compare next week>
```

## Step 4: Present it, and ask about each suggestion

Show the report's Summary and Process suggestions in the conversation and give the report's path. Then ask, through the harness's question dialog when it has one, **one numbered item per suggestion** (four at most, so one dialog holds them all), in plain words — what would change for the user, not a setting name or a file pattern (a path goes in brackets):

```
1. Fixes to sign-in kept needing a second attempt (3 fixes this week in src/auth/session.ts).
   Add a rule that every change to token refresh comes with a test covering each place a
   session token is refreshed?
   A) Open an issue for it — written up with the evidence above, filed after you say yes
   B) Add it to the rules file now — I show you the exact wording first
   C) Not now — it stays in this report only
   Default if you skip it: C (nothing is filed or changed)
```

Option B is offered only when the suggestion lands in the rules file; a guard, a test or a skill update gets A and C only.

Nothing is filed, edited or updated before the user answers that item. An issue is shown in full (title, body with the evidence) before it is filed; a `CLAUDE.md` change is shown as a diff before it is written. An approved rules edit lands on its own branch (made with the worktree skill, when it is installed) and is shipped the usual way; the retro itself never commits, and next week's retro sees the rule once it has merged to the base branch. A framework update is never a suggestion this skill carries out: it points at the update procedure.

---

## Without the script

The same numbers by hand, for an environment with no bash:

```bash
git log --no-merges --since="7 days ago" --format='%h %s' <BASE_REMOTE>/<BASE_BRANCH>          # the commit mix
git log --no-merges --since="7 days ago" --format='@%h %s' --name-only <BASE_REMOTE>/<BASE_BRANCH>   # files per fix commit: group by file and folder
gh issue list --state all --search "created:>=<YYYY-MM-DD>" --limit 1000 --json number --jq length
gh issue list --state closed --search "closed:>=<YYYY-MM-DD>" --limit 1000 --json number --jq length
gh pr list --state merged --search "merged:>=<YYYY-MM-DD>" --limit 1000 --json number,title
git ls-remote --tags --refs <RELEASE_REPO_URL>                                  # newest vX.Y.Z against .claude/humanmaxxing.lock
```

With no remote (`BASE_REMOTE` empty), use `<BASE_BRANCH>` alone. A query that fails, or returns exactly its limit, is "could not be read", never a count.

---

## Reference

- `retro.env.example`: every key, with worked values
