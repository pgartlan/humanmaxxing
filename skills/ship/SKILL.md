---
name: ship
description: Commit → PR → merge in one pass, and not "done" until merged with green post-merge CI. Fires every check that only needs the working tree in parallel at the start; syncs with the base branch first; drives the PR through CI, fix rounds and the merge queue with bounded waits and a mechanical census of failures. Reads the review and E2E sentinels a companion review-code skill writes.
user-invocable: true
allowed-tools: Bash(bash *), Bash(git *), Bash(gh auth status *), Bash(gh repo view *), Bash(gh issue create *), Bash(gh issue list *), Bash(gh issue view *), Bash(gh issue close *), Bash(gh pr comment *), Bash(gh pr create *), Bash(gh pr edit *), Bash(gh pr view *), Bash(gh pr checks *), Bash(gh run list *), Bash(gh run view *), Bash(gh run rerun *), Bash(gh run watch *), Bash(cat *), Bash(date *), Bash(mkdir *), Bash(printf *), Bash(rm *), Bash(sed *), Read, Edit, Write, Glob, Grep, Agent, AskUserQuestion
---

# ship — one-pass ship pipeline

Everything that only needs the working tree fires in **one turn**: quality checks, build, scans, documentation, issue search. The base-branch sync runs **before** any of them (Step 0.7), so every check runs against the tree that will merge. Only PR creation waits for the commit. Then the skill drives the PR all the way: CI watch, failure census, bounded fix rounds, flip to ready, enqueue or merge, post-merge CI, close-out, cleanup.

Do not skip steps. Do not say "done" until the PR is **MERGED**, post-merge CI is green and the close-out has run (Step 5, G0).

**Several finished branches? Ship them in parallel**, one ship per worktree, and let their CI waits overlap. Serialize only on a real ordering dependency.

ship-contract: 2

---

## Resume (read this first after a compaction or a restart)

You are in the middle of a ship if `$(git rev-parse --git-path ship-state)/ship-mode` exists. Do not re-invoke the skill to find your place (a changed mode or no-merge request would start over). Run, from the worktree root (the session's working directory; the relative `ship-status.sh` pointers in this file assume it):

```bash
bash .claude/skills/ship/bin/ship-status.sh --contract=2
```

Read-only. It prints the mode, every step marker (`ok` = still bound to the current tree; `tree-moved` = the tree changed after that step; `absent`; the `phase1` marker also moves when the base moves, the others only on a change to the branch's own paths), the two review-code sentinels' verdicts, live background processes, the ledger summary, then `LAST`, `NEXT` and `POINTER`. A marker-backed `NEXT` is exact; an inferred one is a guess from state files: read that step before skipping anything. `LIVE-BG` lines are running processes: never start a second copy; wait for the notification or stop it. `NOTE ship-no-merge` means Step 5 pauses before any merge.

A script printing exit 9 (`contract-mismatch`, `skill-changed`, `skill-dir-mismatch`) means the text you are following is not this worktree's current SKILL.md: Read `.claude/skills/ship/SKILL.md` from disk and resume (state kept). Re-invoking the skill is not enough: a harness may load the copy from the session's launch directory, not this worktree. `--fresh` discards progress; a plain re-run resumes when mode and no-merge request are unchanged and a step marker still matches the tree.

---

## Script exit codes (every `bin/*.sh`)

0 proceed · 10 the script deliberately did not perform its optional action (the pointer says what to do next; never read 10 as "skip this step's work") · 1 HALT · 2 usage/environment · 3 input unreadable or an external read failed (never "nothing to do") · 4 wait or resolve, never proceed (WAIT: a bound expired or a result is not in yet, so re-arm or wait; a conflict or a suspicious finding: resolve it, then re-run) · 9 contract or skill-text mismatch · other codes ≥5 gate-specific, named at the pointer. **Route on the code and the `SHIP-RESULT` last line, never on "it printed PASS" and never on prose. A missing `SHIP-RESULT` line is a HALT (the harness bound killed the task: unverified, never green). Never `Read` a `bin/` file to decide what to do; the pointer and `references/exit-codes.md` say what to do.**

**Contract.** The `ship-contract: 2` line above must equal `SKILL_CONTRACT` in `bin/ship-lib.sh`; every pointer passes `--contract=2` as its FIRST argument. Exit 9 `contract-mismatch` means SKILL.md and `bin/` are out of step (a rebase brought newer scripts): HALT, Read this worktree's SKILL.md from disk, resume. The two sibling exit-9 results, `skill-changed` (SKILL.md on disk differs from the blob `ship-init.sh` recorded) and `skill-dir-mismatch` (the harness loaded another worktree's copy), mean the same thing. Detail: `references/exit-codes.md § Exit 9`.

**Background pointers** say `run_in_background: true` and an explicit `timeout:`. Every script bounds itself; a task killed by the harness bound prints no `SHIP-RESULT` line.

---

## Configuration — adapt these to your repo

Two kinds of slot. **Script-read values** live in `ship.env` next to this file (`KEY=value` lines, `#` comments on their own lines; the `getting-started` onboarding writes it, or fill it by hand from `ship.env.example`, which lists every key with its worked default). **Prose slots** are the commands and lists you substitute into the pointers below. **Any command you put in a slot must also be added to `allowed-tools` above.** The `*_CMD` keys in `ship.env` are executed by the scripts: review changes to that file like code.

Prerequisites: git ≥ 2.34 (the check binding uses `git add --sparse`), an authenticated `gh`, `jq`, `sha256sum` or `shasum`. The skill is installed in-repo at `.claude/skills/ship/` (every pointer assumes it; a user-level install breaks the pointers and the contract check). Background pointers below state a `timeout:`; if your harness caps background timeouts lower, pass `--max-minutes` below the cap and re-arm on TIMEOUT.

```
# ship.env (scripts read these)
BASE_BRANCH          — the branch PRs merge into (every merge-base, fetch and lease is against origin/<this>)
GH_REPO              — owner/repo every gh call targets (scripts export it; typed gh commands add --repo); empty = gh's default
ISSUE_MARKER_FILE    — optional: a file in the checkout listing issue numbers this branch targets (e.g. .issue-numbers);
                       left out of the check binding and never an untracked-file finding
DEFAULT_MODE         — offload | local (Mode selection; offload where a draft PR can run the heavy tier in CI)
MERGE_METHOD         — queue | direct. queue: a label enqueues and a bot merges; direct: `gh pr merge` per MERGE_FLAGS
QUEUE_LABEL          — queue only: the label that enqueues (e.g. ready-to-merge)
QUEUE_STATE_CMD      — queue only, optional: a command printing queued|dequeued|unknown for $PR (your queue provider's
                       authoritative state: a status comment, a check-run). Unset → dequeues surface as LABEL_MISSING/TIMEOUT
REVIEW_GATE          — sentinel | manual. sentinel (the default whenever review-code is installed): review-code writes the
                       sentinels the gates read. manual: only the fallback when review-code is not installed;
                       the gates accept the USER's in-session attestation, recorded by ship-sentinel.sh attest with their
                       words and bound like a sentinel, never spelled FRESH; the agent never attests its own work
POSTMERGE_CI         — required | none. none: the base branch runs no CI on push; the post-merge watch is skipped and reported
REQUIRED_CHECKS_CMD  — preferred: a command printing the LIVE required contexts, one per line (branch protection ∪ queue
                       conditions; $PR is set). A failing command is a watch ERROR, never "any green"
REQUIRED_CHECKS      — fallback: a static csv of required contexts (drifts from branch protection). Both unset → EVERY
                       context is required (fail closed)
IGNORED_CHECKS       — contexts the watch ignores (a queue provider's always-pending check)
CRITICAL_GLOBS_FILE  — one glob per line: paths whose change needs real E2E (the same file review-code's CRITICAL_GLOBS names).
                       Empty value = explicit opt-out; a named file that is missing is an error, never "no globs"
DOCS_ALLOWLIST       — ERE over paths that cannot change runtime behavior; worked default (\.md$|\.txt$|^docs/|(^|/)CHANGELOG).
                       Excluded from both bindings: the review fingerprint (shared with review-code: sentinels.md) and the
                       check binding Phase 1 and the task results bind to (Step 2e-c)
DOCS_KEEP_BOUND      — ERE re-including docs a check or test reads as input (a baseline, a registry); they stay bound
REVIEW_TTL_SECONDS   — review sentinel age limit (worked default 43200; freshness is the fingerprint, the TTL only forces a
E2E_TTL_SECONDS        re-attestation on a very long ship)
FIX_ROUND_CAP        — OFFLOAD fix pushes before the skill stops and asks (worked default 10)
PLANS_DIR            — where reviewed plans live (<dir>/<issue>-*.md; worked default docs/plans): the close-out check reads
                       a plan's `## PRs` Owns column
RELEASE_ACTIONS      — none | file-ledger (ship-release.sh). file-ledger also needs RELEASE_ACTION_LINT_CMD (exit 1 on
                       action-shaped prose outside a block), RELEASE_ACTION_HARVEST_CMD (writes the blocks into your in-repo
                       ledger) and RELEASE_LEDGER_DIR (the script stages it and reads it back); any one empty is exit 2
PRE_PUSH_CEILING_MINUTES — a still-running required CI run older than this is stuck, and a fix push may cancel it after the
                       20-minute pre-push wait; younger, the wait re-arms (worked default 60)
CHECK_TASKS          — the Phase-1 checks bound to their commands: <name>:<local|offload|both>,… with a CHECK_CMD_<name>
                       each (an empty one is exit 2 at init). `write phase1` requires every name for the mode, launched or
                       not. Unset = the launched list is the required list (the first install), named in the PR body

# prose slots (you substitute them into the pointers)
MERGE_FLAGS          — direct merges only: `--squash` | `--merge` | `--rebase` (match the repo's merge setting)
QUALITY_GATE_CMDS    — TYPECHECK_CMD / LINT_CI_CMD (the NON-writing variant CI runs) / LINT_FIX_CMD / BUILD_CMD /
                       SECRET_SCAN_CMD / SAST_CMD / TEST_CMD. One ship-run task each (Step 1c)
                       SECRET_SCAN_CMD scans what git would commit, never git-ignored files (a local
                       ignored key file must not turn it red): checkpoint's slot text has the worked
                       default. A check with no command is not launched as a task (an empty command
                       exits 0 and would read as green); the PR body lists it as not configured
TEST_GLOBS           — globs that identify test files, as git pathspecs (the test-update guard, Step 1c)
INFRA_JUDGMENT_PATTERNS — optional diff-CONTENT regexes for infrastructure-as-code whose content changes runtime behavior
                       (an environment block, a permission widening, a queue attribute): globs cannot see these; a hit
                       prints the files and you decide E2E vs exempt, recording the basis in the PR body
UNIT_TESTS_IN_REVIEW — local | ci | none (shared with review-code): where unit tests run before the PR
CONDITIONAL_CHECKS   — <!-- ONBOARDING --> domain-conditional checks: "if paths matching X changed, also run Y".
                       The principle: anything CI defers off the PR path runs here. Empty is valid
PROTECTED_FILES      — files whose change needs explicit human approval before ANY step (Step 0-pre). Empty is valid.
                       A repository that keeps them in `.claude/protected-files.txt` (one glob per line, the list the
                       protected-file guard hook reads) sets `see .claude/protected-files.txt`: read that file, never
                       a second copy of the list. With that pointer the gate checks the file's globs PLUS the guard's
                       always-protected files: `**/.claude/settings.json`, `**/.claude/settings.local.json` (in any
                       folder), `.claude/hooks/**` and the list file itself. The globs follow the guard's spelling: paths from the repository's top,
                       `**/` spans folders, `*` and `?` do not cross `/`. The list file missing or unreadable → STOP,
                       never "none configured"
PROTECTED_BRANCHES   — ERE of branches this skill must never ship FROM (worked default ^(main|master|develop|release/))
BASE_HEALTH_CMD      — optional: a command that fails when the base branch's deploy/CI is red (Step 0)
REMOTE_TEST_DISPATCH — optional: how a suite-sized run goes somewhere other than this machine (shared with review-code)
DOCS_STEP            — checkpoint | default | none. checkpoint: your checkpoint skill's docs prompt; default: the worked
                       prompt in references/pr-body.md with CHANGELOG_FRAGMENT_DIR and CHAT_SUMMARY_DIR; none: no docs
                       subagent (Step 1d writes the done file itself and logs auto-decision class=docs-none)
CHANGELOG_FRAGMENT_DIR / CHAT_SUMMARY_DIR — where the docs subagent writes (DOCS_STEP=default)
PR_TEMPLATE          — references/pr-body.md (edit it; the structural check reads its required sections)
TRACKER              — github (the only adapter so far). BOARD_MOVE_CMD / BOARD_VERIFY_CMD (optional): commands that move
                       the issues in $ISSUES to "In review" and verify it on the live board; unset = no board steps.
                       $ISSUES = `ship-status.sh --contract=2 issues` (Step 1e)
ISSUE_CLOSE_KEYWORD  — Closes (PR body only; commits and the title carry Refs — Step 2c says why)
REMOTE_TEST_DISPATCH — (shared with review-code) when a validation of UNCOMMITTED work runs remotely on a scratch ref, publish
                       only tracked/staged changes, withhold untracked and secret-looking files (.env*, *.pem, *token*), scan
                       the scratch diff for secrets, delete the ref on every exit
PENDING_QUESTIONS_FILE — optional: where an open question to the user is written while you keep working
SHIP_MODEL           — optional: the model this skill should run on; a different one is asked about once (Step -1)
CONTEXT_RESTORE_LINE — optional: the line that restores a context setting the trim skill's ship-bound handoff tells the user
                       to raise (a long ship runs at a large context per turn); every ship-ending message ends with it.
                       The setting is per model, so the line is for SHIP_MODEL
PR_LABELS            — optional INFORMATIONAL labels the PR carries (a plan-shown label). A label that makes CI skip or
                       defer jobs never goes here: it is CI_SKIP_LABEL
CI_SKIP_LABEL        — optional: a label that makes CI skip or defer jobs because they already ran locally. Applied only in
                       `--local`, only through the Step 4 gate (the Phase-1 sentinel valid for the committed tree), and only
                       when the local tier runs every job it skips: one it does not run (an integration suite CI owns) means
                       the label stays off unless that job's result on this tree is known. Never in OFFLOAD: there the
                       label's absence is what makes CI run for real
```

Reading a `ship.env` value inside a prose command: `$(bash .claude/skills/ship/bin/ship-status.sh --contract=2 cfg BASE_BRANCH)` (the `cfg` verb prints the bare value). The blocks below use it for `BASE_BRANCH`. `GH_REPO` (owner/repo, for a checkout whose origin is not the GitHub repository): the bin/ scripts export it to `gh` themselves; every `gh` command you type adds `--repo <that value>` when `cfg GH_REPO` prints one (exit 1, nothing printed = unset: leave `--repo` out).

**Companion (recommended, `REVIEW_GATE=sentinel`): review-code.** It writes `SHIP_STATE/review-code-ran` and `SHIP_STATE/real-e2e-shipgate-passed`; this skill's `ship-sentinel.sh` is the reader. The exact contract is review-code's `references/sentinels.md`; `bin/ship-lib.sh` is its reference implementation (review-code may call `ship-sentinel.sh fingerprint` instead of re-implementing). No review-code yet? `REVIEW_GATE=manual`: the review gate (Step 1c) and, for a diff that touches a critical path, the E2E gate (4.0b) accept the **user's** attestation: ask them (class `waiver`), then record it with `ship-sentinel.sh attest review|e2e --note "<what was verified, when, against which commit>" --user "<their words, verbatim>"`, bound like the sentinel it stands in for, and the PR body says "manual attestation" and quotes them, never FRESH. The shipping agent never attests its own review or its own E2E run: a gate the agent clears for itself is the self-override both gates exist to prevent, and the script refuses an attestation without the user's words. A diff that touches no critical path is E2E-exempt in manual mode with no attestation (the categorizer decides, on every read). `REVIEW_GATE` changes the writer, not the gate: no flag, label, argument or PR-body note bypasses the HALT.

**Not a companion: a release skill.** `RELEASE_ACTIONS=file-ledger` only requires your lint and harvest commands; whatever consumes the ledger at promotion time is yours.

**Companion (optional): checkpoint**, whose documentation step this skill dispatches as a subagent (Step 1d). Without it, the worked prompt in `references/pr-body.md § Docs subagent` applies.

---

## Design principles (why the skill is shaped this way)

1. **Fire everything in one turn.** Checks that only need the working tree have no ordering dependency; launching them serially adds their runtimes. The one exception is a fixer (`LINT_FIX_CMD`): it rewrites files, so it runs first, alone, and the rest launch after it.
2. **Sync first, then check.** Rebasing before any check fires removes the whole "did the sync invalidate the gate?" question. What is left (the base advancing *after* checks start) is handled by conflict-only re-gating in OFFLOAD, and in both modes by the check binding: Phase 1 and every task result bind to the whole working tree, so a base move makes them stale and they are re-earned before the next `--local` push or the OFFLOAD flip (a sync deletes the Phase-1 sentinel; an OFFLOAD fix round does not, because its CI round is the re-check; after the flip OFFLOAD does not read Phase 1).
3. **Run inline; delegate only leaf work.** We lost three multi-hour sessions to a subagent that fired a test suite, then ended turns polling it and never converged; when a human stepped in, two actors shared one worktree and competing runs thrashed the box so nothing finished. A background task costs the main agent nothing while it runs, so there is no token saving to chase. The one subagent is the documentation step, which runs no pipeline step.
4. **Offload is not skip.** In OFFLOAD every heavy check still runs and still blocks, in CI against a draft PR. If you are about to skip a check in OFFLOAD without a CI job that runs it, that is a bug in this skill: report it and run the check.
5. **Scripts hold the gates; the model holds the judgment.** The things that must not be re-derived under pressure (fingerprints, leases, bounded waits, the census, the round cap) are scripts routed on by exit code. Dispositions (flake or genuine, fold or separate PR, what the PR body says) stay with you.
6. **Sentinels make expensive greens reusable, and the writer/reader contract is exact.** Content-addressed and fail-closed: an uncomputable hash is an error token that can never compare equal; hash and TTL are checked independently; existence is never validity.
7. **A red check blocks the ship. Always.** No self-granted exemptions (Step 2b). Attribution says where the fix lands, never whether to fix.
8. **Every long wait is bounded, and a wait is never narrated.** The harness re-wakes you only when a background process exits; an unbounded watch on a stuck target hangs the session forever. Re-arming after a bound is recovery, not polling. Ending a turn with "waiting for CI" and no bounded task armed in that same turn means no notification is ever coming.
9. **One push per census.** Read every failed job at the SHA before touching a file; fix the union; push once. We once re-discovered the same three lint findings on three consecutive CI rounds because the orchestrator read one job's log at a time.
10. **The ship is not done until the PR is merged**, post-merge CI is green and the close-out has run (G0). An open PR is an unfinished ship.
11. **The skill asks the user only for a short list of question classes** (below). Everything else follows a written rule, is logged as an auto-decision, and keeps going.

---

## The question list (the only things this skill asks the user)

| class | what is asked |
|---|---|
| `protected` | a `PROTECTED_FILES` change (Step 0-pre): explicit in-session approval |
| `admin` | any queue or branch-protection bypass: only on the user's instruction for that instance |
| `waiver` | `REVIEW_GATE=manual` only: the user's own attestation for the review gate, or for the E2E gate on a critical-path diff (their words go into `attest --user` and the PR body); never answered by the agent |
| `cap` | the fix-round cap (Step 4.5 3c), and a CI failure with no derivable signature (non-convergence) |
| `infra-write` | a deploy, an infrastructure apply, or a post-merge shared-environment write the approved plan does not already cover |
| `product` | a genuine product or contract call no written rule decides; and every ticket proposal (the user approves before `gh issue create`) |
| `model` | Step -1: the skill was invoked on a model other than `SHIP_MODEL`; ask once |
| `pause` | user-requested stops and wrong-invocation relays (the no-merge pause, the wrong-worktree relay): reports, not questions |

**Logging an auto-decision.** Every rule-decided outcome named below (`flatten-avoided`, `remote-integrated`, `files-unstaged`, `dequeue-repush`, `dequeue-wait-expired`, `model-confirmed`, …) is written to the fix-loop ledger. Best-effort telemetry: it always exits 0.
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-log.sh" --contract=2 auto-decision class=CLASS
```

**While a question is open, keep working** on everything it does not block, keep every bounded wait armed, and (if `PENDING_QUESTIONS_FILE` is set) write the question there until it is answered. A question is never a reason to tear a watcher down.

---

## Step -1: Model check (before anything touches state)

If `SHIP_MODEL` is set and the model named in your system prompt differs, ask once with plain options: `Continue on <model>` or `Stop — I'll switch and re-invoke`. <!-- ask:class=model --> On Stop, end the turn having touched nothing. On Continue, log `auto-decision class=model-confirmed model=<name>` after `ship-init.sh` exits 0. A resumed ship that already logged it does not ask again.

## Mode selection: OFFLOAD vs `--local`

Two modes, differing only in *where the heavy check tier runs*. **OFFLOAD**: open a **draft** PR early, let CI run the heavy tier, flip to ready only on green. **`--local`**: run everything here, open a ready PR. Both rebase first. Use `--local` when CI is down or a multi-round debug loop makes a CI round-trip per iteration worse than running locally.

**Nothing heavy runs on this machine except what a pointer in this file runs**, fix rounds included: no ad-hoc test runs, no hand-run lint groups, no parallel heavy runs. To re-check a red, re-run its Step 1c task. A separate base-side fix PR (2b), or a post-merge follow-on fix (Step 5), is its own task: create its branch with the worktree skill (one new branch in one new sibling folder from the base; say branch, folder and starting commit in your next message). Switching this worktree's branch is never pre-authorized.

```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-init.sh" --contract=2 --skill-dir "<the harness's Base directory for this skill>" <<'EOF_SHIP_ARGS'; exit $?
$ARGUMENTS
EOF_SHIP_ARGS
```

`--skill-dir` is the directory the harness said it loaded this file from (Claude Code prints "Base directory for this skill"); a harness that does not say uses `"$(git rev-parse --show-toplevel)/.claude/skills/ship"`. Arguments: nothing (`DEFAULT_MODE`), `--local`, `--offload`, `--fresh`, `--no-merge`, or free text (an issue number, a no-merge phrase). Any other `--flag` is rejected: a typo must never silently pick the default mode. The argument text is data: the script keeps a byte-exact copy and a body-safe copy (fences, `#N` and closing keywords made inert) that Step 2c appends by file. The `; exit $?` after the heredoc stops a terminator inside the text from executing what follows: never remove it.
- exit 0 → `MODE=` persisted. `START: fresh (reason=…)` → continue at Step 0-flight. `START: resume (…)` → run the printed `RESUME-HINT` and continue from its `NEXT`/`POINTER`; do not repeat earlier steps. `NO-MERGE: requested` → Step 5 pauses before the merge. `FIX-ROUNDS: kept N of M` → the cap survives a restart on the same branch. `ANNOTATION: recorded` → the argument text was saved for the PR body (Step 2c copies it by file; never paste it into a prompt).
- exit 9 `skill-dir-mismatch` → HALT: Read this worktree's `.claude/skills/ship/SKILL.md`, follow that text, re-run with that directory.
- exit 1 `sync-pending` → a conflicted Step 0.7 sync is still in progress; nothing was reset: resolve it and `ship-sync.sh --continue`, then continue from `ship-status.sh`.
- exit 2 → `ship.env` missing or malformed, detached HEAD, bad flag: fix it. Anything else, or no `SHIP-RESULT` line → HALT; follow the `READ:` line.

---

## Step 0-flight: branch sanity (BLOCKING)

The skill ships **the current worktree's branch**. On a branch matching `PROTECTED_BRANCHES`, detached, or with NOTHING of its own to ship (an empty diff against the merge-base and a clean tree: a wrong-worktree signal as strong as being on the base) → STOP, print `git worktree list`, relay to the user. <!-- ask:class=pause -->
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-gate.sh" --contract=2 branch --protected 'PROTECTED_BRANCHES'
```
- exit 0 → continue. Exit 1 → STOP (the line says which: `detached-head`, `protected-branch`, `nothing-to-ship`) and relay the printed `git worktree list`. Exit 2 → the slot was not substituted or is not a valid ERE: fix it. Exit 3 → fetch the base branch; never read as shippable.

## Step 0-pre: protected files (BLOCKING)

Intersect the changed set (merge-base → working tree, untracked included) with `PROTECTED_FILES`. One hit → **STOP**: print exactly what changed and why it is gated; proceed only on explicit in-session approval, logged verbatim in the PR body. <!-- ask:class=protected --> `PROTECTED_FILES` empty → print `Protected files: none configured`. An unreadable diff is never "nothing protected changed".
```bash
BASE_BRANCH=$(bash .claude/skills/ship/bin/ship-status.sh --contract=2 cfg BASE_BRANCH)
BASE=$(git merge-base HEAD "origin/$BASE_BRANCH") || { echo "HALT: merge-base unresolved"; exit 1; }
{ git -c core.quotePath=false diff --name-only "$BASE"; git -c core.quotePath=false ls-files --others --exclude-standard; } | LC_ALL=C sort -u
```

## Step 0: Base-branch health (BLOCKING when configured)

A pre-existing red on the base branch compounds triage. Run `BASE_HEALTH_CMD` if set; non-zero → STOP, do not argue with the gate in prose. The only bypass is the user's explicit approval for this run, logged as class `admin`. <!-- ask:class=admin --> A bypass is GLOBAL: list every red it waives in the message and the PR body; never assume it was narrow. Unset → say "base health: not configured" and continue.

## Step 0.7: Sync with the base branch — rebase first (BLOCKING, both modes)

Rebase onto `origin/BASE_BRANCH` BEFORE any check fires. Uncommitted work rides along via `--autostash` (never a hand-rolled stash: the stash stack is shared across worktrees and sessions, and a bare `pop` can restore someone else's work). Rationale and the three outcomes: `references/sync.md`.
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sync.sh" --contract=2
```
- exit 0 → synced (`rebased=` recorded; the push lease recorded). For EACH `COEDITED: <file>` line do hunk-level verification: a clean auto-merge can drop a change when both sides edited the same function; never "fix" an apparent silent revert by copying content back from the base.
- exit 4 → rebase conflict, rebase left in progress (`CONFLICT_FILES:`). Resolve every hunk (never `--ours`/`--theirs` on whole files), `git add`, then re-run with `--continue`. Abandon: `git rebase --abort`.
- exit 5 `autostash-conflict` → the rebase finished but your uncommitted work conflicted on re-apply (`UU:`, `AUTOSTASH: <sha>`); it is safe in that entry. Resolve, `git add`, `--continue`; drop the entry ONLY via the `DROP-HINT` that `--continue` prints. Exit 5 `unmerged-paths` → the index already held conflicts from something else: resolve, re-run WITHOUT `--continue`.
- exit 8 `merge-only-content` → the branch carries merge commits; a rebase would flatten them and can silently drop content. Never flatten: `ship-sync.sh --contract=2 --merge` (one scripted stash for uncommitted work, `git merge`, re-apply by SHA; exit 4 = merge conflict: resolve, `git commit`, re-run the plain sync; exit 5 = re-apply conflict, your work is in the printed stash), then re-run the plain sync (already in sync → continue). Logged as `flatten-avoided`.
- exit 1 `remote-branch-unseen` → another session pushed this branch. Integrate without asking: `ship-sync.sh --contract=2 --integrate-remote` (rebase with autostash onto origin/<branch>; exits 4/5 as above), re-run the plain sync; the first push after that is `ship-push.sh --remote-integrated` (it breaks the review chain on purpose: a review must cover those commits). List them in the PR body. Their commits move the check binding: re-earn Phase 1 before the next `--local` push or the OFFLOAD flip. Exit 1 `sync-pending` → a conflicted sync is unresolved: `--continue` it.
- exit 6 / 3 → HALT; investigate, never re-rebase by hand. Anything else, or no `SHIP-RESULT` line → HALT; follow the `READ:` line.

After a rebase that touched hand-resolved files, run `LINT_CI_CMD` now: a resolution can orphan imports that lint catches in seconds and CI surfaces 20 minutes later. Then the merge audit:
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sync.sh" --contract=2 audit
```
- exit 0 → no merge commits. Exit 4 → merge commits are present and the audit is yours, every time: `merges-present-audit-required` lists the `BOTH_SIDES:` files (changed on two or more parents; a hand resolution that kept only part of a side matches no parent, so "nothing identical" is never "clean"), `audited-suspicious` also tags some `IDENTICAL_TO_PARENTn` (another side's change was dropped entirely). Decide per file whether the merge kept every side's change; report under "Merge Resolution Audit" in the PR body and flag the suspicious ones **Needs Manual Review**. Exit 3 → a read failed: never clean. Not persisted: re-run after a compaction.

No push here (Step 3 pushes, leased against the remote tip recorded before the rebase). The sync rebases onto the fetched SHA and records it; later freshness checks compare against that record, never a fresh read of the remote-tracking ref, which another worktree's fetch can move.

---

## Step 1: Fire everything (one turn)

### 1.0 — Prefire
A Phase-1 sentinel valid for this exact tree (written by an earlier Step 2e-c in this worktree) means the heavy tasks need not re-run:
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sentinel.sh" --contract=2 verify phase1
```
- exit 0 → PREFIRE: launch only `LINT_CI_CMD` and the test-update guard in 1c; the E2E gate is still required at 4.0b. Exit 1 → fire Phase 1 normally. Exit 3 → HALT (unreadable tree).

### 1a — Scope
`git status`, then sort the untracked files:
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sentinel.sh" --contract=2 untracked
```
`RELEVANT<TAB><path>` = near a change of this branch (the file's folder, or a folder above it below the top level, directly holds a file the branch changes; a top-level file when the branch changes a top-level file); `IGNORED<TAB><path>` = anywhere else. Decide the expected set per file: tracked changes, plus each untracked file that belongs in the PR. A RELEVANT file is never left untracked in place: it goes into the set, or you delete it or move it out of the checkout before Step 3 (the push refuses it otherwise). An exclude pattern is only for a path no worktree should ever commit, and goes in the file `git rev-parse --git-path info/exclude` names, which every worktree of the repository shares (never a literal `.git/info/exclude`: in a linked worktree `.git` is a file). An IGNORED file goes into the set or stays out. Every file left out is listed in the Step 5 report; log `auto-decision class=files-unstaged`. No ask. (Step 3 stages `git add -A` and unstages anything outside this set.) Exit 3 → HALT: an unreadable list is never "nothing untracked".

Exit 3 `merge-base-unresolved` → fetch the base branch, re-run. Two known gaps: a forgotten file in a new top-level directory the branch touches nowhere else, and a file removed from the index whose directory has no other change, both read IGNORED. Read the IGNORED list for them.

### 1b — Detect domains
Classify the changed set: **docs-only** (every path matches `DOCS_ALLOWLIST`; hook scripts and settings are NOT docs) → 1c skips typecheck/test/build; **critical** (`ship-sentinel.sh categorize` exit 0) → the E2E gate applies; each `CONDITIONAL_CHECKS` trigger that matched → its check joins 1c. Re-derivable: re-run after a compaction.
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sentinel.sh" --contract=2 categorize
```
- exit 0 → `NONEXEMPT <path>` lines: the E2E gate applies to them. Exit 10 → no critical path changed: E2E-exempt; say so in the PR body. Exit 3 → HALT (CRITICAL_GLOBS_FILE unreadable, a bad glob spelling, or an unreadable diff). If `INFRA_JUDGMENT_PATTERNS` is set, grep the diff content for them; a hit prints the files and the E2E decision is yours, recorded in the PR body. **Re-run 1b after any fix that changes the changed set**: a newly matched `CONDITIONAL_CHECKS` trigger launches its task before Phase 1 is (re)written.

### 1c — Launch the tasks (the fixer first in the foreground, then one `run_in_background: true` Bash call per task, all in the same turn)
The FIRST action of this turn is the 1d docs dispatch. Then one call per task through the runner, each with an explicit `timeout:` (600000 for a check; 3600000 for a build or a suite):
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-run.sh" --contract=2 start <name> -- <command>
```
**With `CHECK_TASKS` set** the task list is configuration: `ship-run.sh --contract=2 required` prints the names for this mode; launch each as `ship-run.sh --contract=2 start <name>` (no command: the configured `CHECK_CMD_<name>` runs), and `write phase1` refuses until every one is green on this tree, launched or not. Typed commands below apply only to checks not in `CHECK_TASKS`. An empty command, `bash -c ''` included, is refused (exit 2 `empty-command`): it would record a green that checked nothing.
**`LINT_FIX_CMD` (when set) first, alone, in the FOREGROUND:** `ship-run.sh start lint-fix -- <LINT_FIX_CMD>` as an ordinary (not background) call with `timeout: 600000`, so no other check runs while a fixer rewrites files (a check records the tree as it was when the check ENDED). A red `lint-fix` still finished writing: launch the rest anyway and fix its findings with the others (2b). **This order holds at every re-run** (2a, 2e-c, 3c, G5b): whenever `lint-fix` is among the tasks to re-run, it re-runs first and alone. Then, in parallel: `lint` (`LINT_CI_CMD`), `typecheck`, `build` (OFFLOAD: only when CI does not build the PR), `unit` (in `--local`; in OFFLOAD the draft PR's CI runs it, and when `UNIT_TESTS_IN_REVIEW=local` review-code already ran it on this tree), `secrets`, `sast` (baseline = merge-base; a task whose command slot is empty is never started, since an empty command exits 0 and would record a green: list it in the PR body as not configured), one task per matched `CONDITIONAL_CHECKS` entry, and `test-update-guard` (below). A pipeline goes in `bash -c '…'`. Each task logs to `SHIP_STATE/tasks/<name>.log`, records `<name>.exit` LAST (with the check binding it ended on and the merge-base at its start and end), and is appended to `SHIP_STATE/tasks.list`: **the list of required tasks is recorded at launch, never retyped at verification.**
- exit 0 → PASS. Exit 1 → red: read the printed log tail, fix per Step 2b, re-run ONLY that task. Exit 10 `already-running` → wait for the live copy's notification; never start a second. Exit 3 → the result could not be recorded: not green.

**Test-update guard (BLOCKING; runs even on PREFIRE).** A product file matching `CRITICAL_GLOBS_FILE` changed and no file matching `TEST_GLOBS` changed (tracked or untracked; a deleted test counts as touched) → STOP: demand the covering tests. A passing unit run does not satisfy it. It fails closed: a diff, merge-base or globs file it cannot read is exit 3, never "nothing critical changed". As a task (substitute `TEST_GLOBS` as pathspecs, each quoted):
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-run.sh" --contract=2 start test-update-guard -- bash .claude/skills/ship/bin/ship-sentinel.sh --contract=2 test-guard -- TEST_GLOBS
```
Its exit 1 is a red task (`critical-without-tests`, the critical files listed); exit 3 is a red task too, never green.

**Review gate (BLOCKING; inline).** `REVIEW_GATE=sentinel`:
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sentinel.sh" --contract=2 verify review
```
- exit 0 → `REVIEW: FRESH`: continue. Exit 1 → HALT: the printed line says why (ABSENT, HASH-MISMATCH: the tree changed since the review, STALE). Invoke the review-code skill now, with no ask; fix what it finds; its fixes change the tree, so re-run only the 1c tasks whose input changed; re-run this pointer. Exit 3 → HALT, do not continue blind.
`REVIEW_GATE=manual`: the same pointer reads the user's attestation instead. Ask the user to review the diff and confirm (class `waiver`) <!-- ask:class=waiver -->; then `ship-sentinel.sh --contract=2 attest review --note "<what was reviewed, when, against which commit>" --user "<their words, verbatim>"` (bound to the tree; an edit invalidates it; exit 2 `no-user-confirmation` = you tried to attest without them), then `verify review` prints `REVIEW: MANUAL-ATTESTED`. The PR body says "review: manual attestation" and quotes the user. The HALT itself is unconditional in both modes.

**Issue search** (for the PR body): `gh issue list --state open --search "<branch words>" --limit 5 --json number,title`. Related issues are `Refs`; they never replace the issue the branch was started on.

### 1d — Documentation (dispatch at the TOP of 1c)
`DOCS_STEP=none` → write the done file yourself (`date +%s > "$(git rev-parse --git-path ship-state)/ship-docs-done"`), log `auto-decision class=docs-none`, continue. Otherwise dispatch ONE subagent (`run_in_background: true`, a small model) with the `DOCS_STEP` prompt, appended with: "When finished, write the current epoch seconds to `<ABS>/ship-docs-done`", where `<ABS>` is the absolute ship-state path (`cd "$(git rev-parse --git-path ship-state)" && pwd`; a relative path makes the subagent write it somewhere else). It writes the changelog fragment and the chat summary; Step 3 stages only after that file exists. Skip the dispatch when a same-session docs run already wrote it for this tree; if a companion skill reports a docs run in progress, wait at most 60 s, then dispatch your own. Re-dispatch at most once per ship; a second failure is reported to the user, not retried.

### 1e — Board move (optional, background)
`BOARD_MOVE_CMD` set: run it with `ISSUES="$(bash .claude/skills/ship/bin/ship-status.sh --contract=2 issues)"`: every issue this branch targets (the worktree skill's issue list when the worktree has one, else the branch's leading number when it is followed by `-` and a non-digit or ends the name; plus `ISSUE_MARKER_FILE`), moving them to "In review". Exit 3 → the issue list is unreadable: report it, no board move. Non-gating: a failure is reported, never blocks. Step 4.6 re-verifies with `BOARD_VERIFY_CMD`.

---

## Step 2: Collect + triage

**Collect.** Proceed as soon as tasks start returning; do not wait for the docs subagent (its gate is Step 3). No names = every task recorded in `tasks.list`.
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-run.sh" --contract=2 collect
```
- exit 0 → all green. Exit 1 → `collect: <task> FAIL` lines: fix ALL of them (Step 2b), re-run only those tasks, collect again. Exit 4 → `WAIT` tasks have no result yet: wait for their notifications (a task killed by the bound never writes one: re-run it). Exit 3 → HALT.

A fix changes the tree, and so does a sync onto a moved base. Every task that ran on the old tree must re-run before Phase 1 is written (2e-c refuses `STALE-TREE` tasks; `lint-fix` first and alone, per 1c), and 1b re-runs so a newly matched conditional check joins the set. Never edit a test's expected value to make it green: a changed expectation is a product call (class `product`), named in the PR body. Before authoring a base-side fix, look for an existing one (`git log <red base>..origin/BASE -- <file>`, open PRs touching the file): an existing fix is copied or rebased onto, never re-authored.

### 2b — Failure triage: a red suite blocks the ship
**No self-classified reds.** Every non-green result is a blocker by default, including failures that are pre-existing, outside this diff, or in a check the base branch's CI does not gate. A red clears in exactly two ways, and **no third way exists** (neither is a question to the user):
1. **You make it green.** For a *suspected* flake, re-run that one test in isolation (bounded, or via `REMOTE_TEST_DISPATCH`); an isolated green resolves it; record it in the PR body.
2. **It is also red on the base branch, and you fix it by the written rule.** Fix ≤ 2 files and ≤ 30 lines → fold it into THIS PR with the body note `folded base-side fix (<files>)`; already fixed in an open PR → copy only that PR's hunks byte for byte, note the source; larger → a separate fix PR AND the identical fold here; this ship owns closing it after merge ("landed via #N").

Banned self-classifications: "it's pre-existing", "not in my diff", "CI doesn't gate this", "just lint", "fixing it would sprawl scope". Each may be a *true* description of where the red came from, which is why you REPORT it and fix it by the rule; none is a reason to leave the red. Attribution (where did it come from) decides only WHERE the fix lands. The only ask is a fix that needs a genuine product call no rule decides. <!-- ask:class=product --> Deferral is the user's call, proposed as a ticket with a duplicate search, and even then the red still blocks THIS ship. Fold, never split: as few PRs as possible. Detail and the war stories: `references/failure-triage.md`.

Remove debugging output and commented-out code in scope; report check/build/scan results as a pass/fail table.

### 2c — Draft the PR title and body
Title under 70 chars. Body from `PR_TEMPLATE` (`references/pr-body.md`): what/why, the checks run, the review mode, the E2E gate block, merge audit, folded fixes, the ship-arguments section copied from `SHIP_STATE/ship-args.txt` by file (never pasted). Write the body to `"$(git rev-parse --git-path ship-state)/pr-body-<branch>.md"`, `<branch>` being the branch name with every `/` made `-`: this worktree's own state folder, one file per branch, so two parallel ships never share a body file (never a fixed scratch path such as `/tmp/pr-body.md`). **Issues:** the issue the branch was started on gets a bare `ISSUE_CLOSE_KEYWORD #N` line of its own in the body; related issues are `Refs #N`. **No closing keyword anywhere in a commit message or the title**: the host closes an issue named after a closing keyword *anywhere* in a commit message the moment it reaches the default branch, past every gate, and under a squash or queue merge the PR title becomes the commit body. Check both directions after the Step 3 commit (before the push) AND again immediately before the enqueue or merge (fix-round commits, body edits and retitles happen in between): `BASE_BRANCH=$(bash .claude/skills/ship/bin/ship-status.sh --contract=2 cfg BASE_BRANCH); git log "origin/$BASE_BRANCH..HEAD" --format=%B | grep -iE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b *#[0-9]+'`, plus the live title; reword to `Refs #N` (`--rewritten` push for an already-pushed commit). Every later body edit (the E2E verdict, non-required reds, the merge audit) re-runs the structural check and, with `RELEASE_ACTIONS=file-ledger`, the lint, on the file you are about to pass to `gh pr create` or `gh pr edit`: the lint is only meaningful on the final body. **The PR body is documentation, never a work queue**: "follow-up later", "validate after deploy", a to-do list → either done now or registered where your process tracks post-merge obligations (Step 2d). Structural check: every required section present, no `<FILL…>` placeholder left. **Close-out check** (after writing the body, and after every body edit): `bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-gate.sh" --contract=2 body-check --file "$(git rev-parse --git-path ship-state)/pr-body-<branch>.md"`: exit 0; a `WARN started-issue-not-closed` (an issue this branch targets has no closing line) or `WARN banner-not-in-plan` is a warning to resolve or name in the report, never a refusal (add the `ISSUE_CLOSE_KEYWORD #N` line, or the line-start `⚠️ ADDITIONAL PR REQUIRED … — owns #N — blocker: …` banner the reviewed plan's `## PRs` row backs); exit 3 → an input is unreadable: fix it. **Shared-environment writes in the close-out line are asked about NOW**, before any enqueue (a post-merge ask is too late): a step the approved plan already covers is approved; one it does not is a question listing the write, its command and what declining costs (the check is then not observed in-session and becomes a `when: pre` verification row). <!-- ask:class=infra-write -->

### 2d — Release actions (`RELEASE_ACTIONS=file-ledger`)
Anything this PR defers to a later promotion or to a human (an env var the shipped code reads, a migration that must precede a deploy, a check that can only run after deploy) goes in a fenced `release-action` block in the body (grammar in `references/pr-body.md`), harvested into the in-repo ledger by `RELEASE_ACTION_HARVEST_CMD` **before the Step 3 commit** so the record ships with the code that created the obligation; `RELEASE_ACTION_LINT_CMD` runs on the final body (and again after every later body edit). `when: pre` = the code cannot function in the target environment without it (a release skill refuses the promotion while open); `when: post` = follow-up the code does not depend on. Both legs are one script each, on the canonical body file only (never another file):
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-release.sh" --contract=2 lint      # final body, and after every body edit
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-release.sh" --contract=2 harvest   # before the Step 3 commit
```
- exit 0 → clean / harvested AND staged (read back). Exit 1 (lint) → action-shaped prose outside a block: register it as a block; never delete prose to pass the lint. Exit 4 (harvest) → the ledger rows are not staged and would be lost at commit: HALT, fix, re-run. Exit 3 → the tool could not run: never clean. Exit 10 → `RELEASE_ACTIONS=none` or no body file yet. `RELEASE_ACTIONS=none` → the rule still holds (documentation, never a queue); without a ledger a post-merge obligation is done in-session or is a user-approved ticket.

### 2e — E2E gate pre-check (informational) and Phase-1 sentinel
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sentinel.sh" --contract=2 verify e2e
```
- exit 0 → `E2E: FRESH` or `E2E: EXEMPT <reason>`: the 4.0b gate would pass now. Exit 1 → the line says why (`ABSENT`, `HASH-MISMATCH`, `STALE`, `STALE-EXEMPT`, `MALFORMED`). Exit 3 → fix the git state. A HASH-MISMATCH or STALE here is informational (4.0b enforces it). **One case halts here, before the commit:** a critical-path diff (1b `categorize` exit 0) whose line reads `ABSENT` (or `MANUAL-ABSENT`): no real E2E exists for it yet. Halt; do not proceed to Step 3. Run the review-code skill now (its test reviewer writes and runs the missing tests and the sentinel), or in manual mode ask the user for the waiver (class `waiver`), then re-run this pointer. Finding the gap after a draft PR and a CI round costs that round.

A critical-path diff (1b) with no coverage is the review-code skill's job: its test reviewer writes and runs the real E2E and writes the sentinel. Mocked boundaries and in-process handler imports are not E2E.

**2e-c — Phase-1 complete: write the sentinel** (before the commit; verified after it). The script takes no list: it refuses unless EVERY task in `tasks.list` is green AND ran on exactly this tree:
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sentinel.sh" --contract=2 write phase1
```
- exit 0 → written, bound to the **check binding**: the git tree id of the whole working tree (tracked files plus untracked files that are not ignored) minus `DOCS_ALLOWLIST` paths (except `DOCS_KEEP_BOUND`) and the `ISSUE_MARKER_FILE`. Docs landing afterwards do not invalidate it; a commit of unchanged content does not either; any other edit, any untracked file appearing or disappearing, and a base move do. Exit 1 → a task is red, unrecorded, or `STALE-TREE` (ran before a later edit, on an older base, or the base moved while it ran): re-run those tasks, retry. Exit 3 → HALT (an unreadable tree, unmerged paths, an untracked nested repository: the message says which).

Blind spots of the check binding: a dirty submodule's working tree is not seen (only its recorded commit counts), so checks that read edited submodule files are not bound to them. Computing it runs `git add -A` in a throwaway index: your clean filters (and `core.safecrlf`) run, a failing required filter is an exit 3, and objects are written for changed and untracked files (`git gc` reclaims them).

---

## Step 3: Commit + push

**Wait for docs before staging.** `SHIP_STATE/ship-docs-done` must exist. If no docs subagent is running (its notification arrived, was lost to a compaction, or it was never dispatched), nothing will ever write it: re-dispatch 1d, then wait for ITS notification. There is no bounded wait here; a normal docs run exceeds a minute.

**Stage and commit.** `git add -A`, then compare `git diff --cached --stat` against the 1a expected set: a file outside it is explained or unstaged (this is where a 1a leftover is caught). One commit, message `Refs #N` only. Run the Step 2c closing-keyword grep over the branch's commits now. Then fold `wip(` snapshot commits if your agents make them (`references/sync.md § wip squash`; uncertainty = do not rewrite), then push:
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-push.sh" --contract=2 --kind initial
```
`--local` adds `--require-phase1`. Later pushes pass `--kind fix --round N`, `--kind conflict`, `--kind rebase`, `--rewritten` (history rewritten in place), `--remote-integrated` (Step 0.7).
`--kind fix|conflict|rebase` also REQUIRE `--review none|manual|full`: the review call for that push, recorded in the review chain (3e).
- exit 0 → pushed (leased on the recorded remote tip whenever history was rewritten; the lease is decided from history, not a flag). Exit 7 `dirty-tree` → tracked changes uncommitted: commit. Exit 7 `untracked-relevant` → untracked files near this branch's changes (listed): commit the ones that belong (the check binding already includes them, so Phase 1 stays valid); delete the rest or move them out of the checkout (that moves the binding: re-run 1c; exclude patterns per 1a). Exit 6 → nothing to push (HEAD is the remote tip). Exit 1 → Phase 1 invalid (`--local` always checks it), or git refused for a reason other than the lease (`push-failed git_rc=`: read the log; a protection or hook message is not "another session"). Exit 3 `no-lease-record` → a rebased ship with no lease record: re-run Step 0.7, never a bare lease. Exit 3 `merge-base-unresolved` → fetch the base branch, re-run. Exit 3 `untracked-unreadable` → HALT: fix the git state. **Exit 5 → the remote moved under you: do NOT force past it; fetch, inspect, re-run Step 0.7.** Anything else → HALT.

---

## Step 4: PR creation, E2E gate, live monitor

**Order.** OFFLOAD: create a DRAFT → fire the E2E gate check (4.0b, non-blocking here) → Step 4.5 → 4.6 → Step 5. `--local`: 4.0b (blocking) → create a READY PR → 4.6 → Step 5. **Never proceed to Step 5 from a draft.**

**0. Re-verify Phase 1** (the commit must be what was checked):
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sentinel.sh" --contract=2 verify phase1 --committed
```
- exit 0 → continue (a `NOTE untracked, not near this branch's changes` list: those files are not in the PR; any untracked change still moves the binding). Exit 1 `TREE-MOVED` or `TREE-NOT-COMMITTED` → commit or revert, re-run Phase 1 from 1c. Exit 1 `UNTRACKED-RELEVANT` → as push exit 7 `untracked-relevant`. Exit 3 → HALT. Never push past it.

**1. Create the PR.** `gh pr create --base "$BASE_BRANCH" --title "<title>" --body-file "$(git rev-parse --git-path ship-state)/pr-body-<branch>.md"` (the 2c file; plus `--repo <GH_REPO>` when `ship.env` sets `GH_REPO`, as on every `gh` command you type) (`BASE_BRANCH` read as above) plus `--draft` in OFFLOAD; add `PR_LABELS` (informational only). `CI_SKIP_LABEL`, when set, is applied in `--local` only, in a second call right after the create, and only through its gate: `bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-gate.sh" --contract=2 ci-skip-label && gh pr edit <N> --add-label "<CI_SKIP_LABEL>"` (exit 1 = OFFLOAD, or the local tier did not pass on this committed tree: no label; exit 3 = unreadable: no label). Leave it off when this diff touches a job the label skips that the local tier does not run, unless that job's result on this tree is known. Never same-SHA re-run a run that carried it: the skipped jobs would post skip-passes that tested nothing. A re-entry with an open PR is a no-op. Record it: `printf '%s\n' <number> > "$(git rev-parse --git-path ship-state)/ship-pr-number"` and `ship-log.sh --contract=2 mark pr-created`. Never gate any workflow on `draft == false` (a queue's batch drafts would skip their checks).

**4.0b — E2E gate (BLOCKING: nothing flips to ready or enqueues without it).**
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sentinel.sh" --contract=2 verify e2e
```
- exit 0 → `E2E: FRESH` / `E2E: EXEMPT` (or, under `REVIEW_GATE=manual` on a critical-path diff, `MANUAL-ATTESTED` after the user's waiver: `attest e2e --note "<the real-boundary tests run, when, against which commit>" --user "<their words>"`, class `waiver`, bound to the critical-path fingerprint): pass; put the verdict verbatim in the PR body's "Real E2E ship gate" block (a manual attestation is never written as FRESH). Exit 1 → HALT: the PR stays draft; do NOT flip, do NOT enqueue. The reason names the fix: re-run the review-code skill for a fresh sentinel (a hash mismatch means a critical file changed after E2E ran; a stale EXEMPT means a docs-only exemption is being inherited by a code diff; an empty critical set needs the EXEMPT form). Exit 3 → fix the git state. Never hand-write the sentinel. A gate that is unset or off is written into the PR body as `not run (<reason>)`, never as passed.

**Live base-advance / conflict monitor** (fire beside every long wait; `run_in_background: true`, `timeout: 3600000`):
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-watch.sh" --contract=2 monitor --pr <N>
```
- exit 0 → bound elapsed, no conflict: re-arm while the guarded wait still runs. Exit 11 → CONFLICTING: resolve now (G5b), do not wait for CI. Exit 13 (`--local`, or `--until-advance`) → the base advanced: decide whether to let the gate finish or re-enter Step 0.7 (re-entering makes Phase 1 and every task result stale: a full 1c re-run before the next push; re-arm with the printed baseline either way, or conflict detection goes blind); in OFFLOAD without the flag a `BASE_ADVANCED` line is logged and the watch continues. Exit 12 → gh blind 3 polls (auth): `gh auth status`, re-arm. Exit 1 → already running (one monitor at a time); `monitor --stop` stops it. Stop it before launching the next phase's monitor; a completion from a stale phase is ignored.

---

## Step 4.5: Watch the draft PR's CI → flip to ready (OFFLOAD only)

`--local` skips this step (everything was gated locally; the PR is ready). This step has **no waiver**: a red draft never flips, never gets the queue label, never enqueues.

**1. Watch, bounded** (`run_in_background: true`, `timeout: 2400000`; fire the monitor in the same turn):
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-watch.sh" --contract=2 ci --pr <N> --max-minutes 30 --poll 120
```
Act on the final `VERDICT:` line, never on the exit code alone (`PASS` means "concluded", not "green"):
- `CI_GREEN skipped=[…]` → confirm each named skipped context is legitimately N/A (a skip-pass is not a pass), then item 4.
- `CI_FAILED <names>` → item 3. `NO_CHECKS` / `REQUIRED_MISSING` → never flip; investigate (dropped event, path filter, renamed check; a late context whose run is still active comes back as TIMEOUT instead, and a run queued longer than your runner-pool norm is a capacity problem, not a code problem). `CONFLICTING` → resolve (G5b). `HEAD_MISMATCH` → re-watch the new head. `MERGED` → someone merged it: go to Step 5 after MERGED. `CLOSED_UNMERGED` → do not re-arm; report and stop. `WATCH_ERROR` → exit 3.
- exit 4 `TIMEOUT` → re-arm the same pointer (recovery, not polling). Exit 3 → the watcher is broken or gh is unreadable: fix the cause; no blind re-arm. Exit 2 → usage.

**2. Confirm the checks are real.** `gh run view <id> --json jobs` for the run at the SHA: required jobs are genuine results, not skip-passes or runs on a fallback runner that skipped the heavy tier.

**3. On red: Step 2b applies verbatim.** Then:

**3a. Census FIRST, then label, then fix the WORK blocks — every run at the SHA, every failed job, before touching a file (BLOCKING).**
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-census.sh" --contract=2
```
- exit 0 → `SHIP_STATE/ship-census.txt` IS the work list: one block per failed job (or failed run with no jobs) with `required=`, `work=`, a signature and an excerpt (full logs under `SHIP_STATE/logs/`). `work=1` blocks need a fix this round; `work=0` (not required) are REPORTED in the PR body under "Non-required reds", never ignored. An `UNMAPPED_REQUIRED=` line means a red required context no failed job carries (a status posted by a reporter job): every block is WORK until it is explained. Exit 1 `census-empty` → the watch said failed but no red job exists: SHA mismatch; push nothing, re-run the watch. Exit 3 → INCOMPLETE (a read failed, a log could not be fetched, or a red context exists outside Actions): never push on it; fix the cause, re-run. Diagnose from a job's own result line, not the scariest string: CI echoes a step's source before running it.

**Label every WORK block** (your judgment, recorded in the PR body), in this order: a finding whose file is in this PR's diff is `PR-CAUSED`, full stop; `FLAKE` needs an infrastructure signature (runner death, network, a timeout waiting for a resource) and no assertion, and a timeout is FLAKE the first time and PR-CAUSED when it recurs; `BASE-SIDE` needs evidence (the same finding reproduced at the base tip, or its red job log read in full), never a job-name match; else `UNATTRIBUTED`. When the log is ambiguous, treat it as genuine. Then act, with no ask:
- every WORK block `FLAKE` → one re-run of that run's failed jobs, same SHA, once per run id: `ship-census.sh --contract=2 --rerun --run <id>` (exit 1 `already-rerun` → relabel and fix). Then re-arm the watch.
- `PR-CAUSED` / `UNATTRIBUTED` → fix the root cause locally, in this push. An `UNATTRIBUTED` block that reds again with no derivable signature is the only path to the user in this step, class `cap`, with the run URL. <!-- ask:class=cap -->
- `BASE-SIDE` → Step 2b item 2 (fold ≤ 2 files / ≤ 30 lines, byte-for-byte copy, or separate PR plus the fold). No ask.

Fix the **union** of every WORK block, verify each fix with the narrowest bounded local run that exists (never the whole gate; a full local lint run was measured at 22 minutes on our repo and contended with the CI shards being waited on; calibrate yours). A fix that could not be verified before the push is listed in the PR body as `unverified: <what>`: zero tests selected is unverified, never green, and a non-zero runner exit with zero tests executed is RED. Then push **once**: one push per census, never one push per finding.

**3c. Round gate — mechanical. Order: fixes → `--pre-push` → commit → round gate → `ship-push.sh` → re-arm the watch.**
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-census.sh" --contract=2 --pre-push
```
- exit 0 → nothing new, nothing running: go on. Exit 5 → a NEW required red appeared since the census: re-run 3a, fix it too, do not push yet. Exit 4 → a required run is still in progress (a push cancels it and its findings arrive a round late): fire `--pre-push --wait` as a `run_in_background: true` task (`timeout: 1500000`; it polls for up to 20 minutes) and keep fixing; exit 0 → go on; exit 4 after the 20 minutes (`CEILING_PASSED=no|unknown`) → the run is slow, not stuck: re-arm the same `--wait`, do not push; exit 6 `pre-push-wait-expired` (`CEILING_PASSED=yes`: the run is past `PRE_PUSH_CEILING_MINUTES`, worked default 60, since it started) → push and record `pushed-before-<run>` in the PR body (the ledger line is written for you). Exit 3 → do not push.

Commit the fix (ONE commit per round, `fix(<scope>): <what> (fix-round N)`, `Refs` only), then:
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-census.sh" --contract=2 --round-gate
```
- exit 0 → `fix-round N of M`: push now, through `ship-push.sh --contract=2 --kind fix --round N --review <none|manual|full>` (3e), then re-arm the watch (item 1) for the new SHA. **No full 1c re-run in OFFLOAD**: the draft PR's CI round is the re-verification of everything CI runs, and re-running the whole local tier on every round is the banned "re-run everything" move (it pays the local tier on top of CI, every round). Before the push, run locally only what CI does NOT run and the fix touched: re-run 1b on the fixed tree, then each `CONDITIONAL_CHECKS` entry whose trigger globs the fix delta matches and the test-update guard, through `ship-run.sh start` (`lint-fix` first and alone if it is among them), collected green by name (`ship-run.sh collect <names>`). Phase 1 is not rewritten: the flip needs it present, not re-earned per round (a base sync deletes it, and only then is the full 1c re-run due). At the last allowed round a `TELL_USER:` line is printed: say so in the SAME message as the push and name every remaining WORK block.
- exit 1 → HALT: the cap is reached. Do NOT push. In the same message, tell the user "M fix rounds failed to converge", list the remaining WORK blocks, and ask what to do next, neutrally: continue OFFLOAD for another 10 rounds, switch to `--local`, or stop. Never pick one and never switch to `--local` yourself. <!-- ask:class=cap --> Only after an explicit "continue": `--round-gate --extend` (allowance +10, runs this round).
- exit 3 → the counter is corrupt or unreadable: repair it by hand, never guess.

**3d.** A blocking question never blocks the census: ask only a class on the question list, keep every other block moving, keep a bounded wait armed.

**3e.** A fix push does not re-open the full review gate; the review call for the push is yours and it is RECORDED on the push: `--review full` (the review-code skill ran on the pushed tree, or in manual mode the user attested it; edit first, review, push last: an edit after the review invalidates it), `--review manual` (your own look at the delta: say what and how in the PR body), `--review none`. The chain link counts as **reviewed only when `ship-push.sh` finds a review covering exactly the pushed tree** (`full` with a matching sentinel or attestation); `manual` and `none` are unreviewed, and a `full` with no matching review is recorded unreviewed with a WARN. The pre-merge re-gate accepts the chain's last link for the current tree, whatever the call, on top of the anchor review from Step 1c: unreviewed fix deltas of any size can merge, and every one is reported (the final report's `unreviewed_delta: files= lines= links=`; an unreviewed push over 10 files or 300 lines prints `REVIEW-DELTA: large`, a hint for the report, not a gate). A `--remote-integrated` push breaks the chain: the re-gate then demands a fresh review. Never push a blind patch; never re-run hoping for a different answer.

**4. Flip to ready — only on green, only if HEAD has not moved.** The script re-checks every gate itself, from live state, and reads no stored verdict except the green the watch recorded for one exact SHA:
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-gate.sh" --contract=2 flip --pr <N>
```
It checks, in order: the PR is open, on this branch, its head is HEAD; the tracked tree is committed; HEAD is the remote tip; the CI watch recorded `CI_GREEN` for exactly HEAD (**no push between green and flip**: a push moves HEAD off the recorded green, so the flip refuses); the Phase-1 sentinel exists (a base sync deletes it); `verify e2e` passes; the PR is not CONFLICTING. Then `gh pr ready`, and the step is marked. Exit 0 → flipped. Exit 1 → HALT, the line says which gate (re-watch the head, re-run 1c after a sync, fix the E2E gate, resolve the conflict); the PR stays draft. Exit 3 → a read failed: never a pass, fix and re-run. Never `gh pr ready` by hand.

**5. Then, and only then, Step 4.6 and Step 5.** Order: green → ready → queue label LAST.

## Step 4.6: Verify the linked issues reached "In review" (both modes; only with `BOARD_VERIFY_CMD`)
Re-query the live board for the same `issues` list; retry a move once; never override an issue already Done. Non-gating, but every issue that did not move MUST appear in the Step 5 report.

---

## Step 5: CI → merge → post-merge → cleanup

**G0 — COMPLETION INVARIANT (governs all of Step 5).** The ship is **not complete until the PR is MERGED, post-merge CI is green, and the close-out has run**: every started issue closed (and moved to Done), every post-merge obligation done in-session or registered as a release-action row. **Never report "done", "ready to merge" or "nothing left to watch" while the PR is unmerged**; the next action is to drive it to merge. **A deferred merge is not a walk-away**: Step 5 may end unmerged only on the user's explicit direction (a `SHIP_STATE/ship-no-merge` file IS that direction), and even then the `step5` monitor stays armed and the pause message says mergeability decays as the base moves. <!-- ask:class=pause --> If `CONTEXT_RESTORE_LINE` is set, every message that ends this ship (final report, pause, `CLOSED_UNMERGED`, any HALT awaiting the user) ends with that line, on its own line, last. The setting is per model: the line restores it for `SHIP_MODEL`.

**G5 — Conflict check, the moment the PR exists** (do not wait for CI to find a conflict). A clean rebase can still leave markers that the host's `mergeable` never sees.
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sync.sh" --contract=2 scan-conflicts
```
- exit 0 → clean. Exit 1 → markers (file:line printed): fix, commit, push `--kind conflict`, re-run. Exit 3 → never read as clean.

**G5b** — `gh pr view <N> --json mergeable,mergeStateStatus`. `CONFLICTING` → STOP: re-enter Step 0.7 (`ship-sync.sh`, never a hand-rolled rebase: it records the lease), resolve per the merge protocol, run `LINT_CI_CMD`, invalidate and re-earn Phase 1 (re-run the 1c tasks, 2e-c) before the next push in `--local` and before the flip in OFFLOAD (the sync deletes the sentinel; after the flip OFFLOAD does not read it), push `--kind conflict`, re-check. `UNKNOWN` → continue; G6 re-reads it. A review demand after a conflict push (the hand resolution changed code no review saw): run the review-code skill on the resolved tree before the push and push with `--review full`.

**`--local` only: watch the PR's own CI before merging** (Step 4.5 item 1 pointer; OFFLOAD already watched it).

**G6 — Pre-merge re-gate (immediately before the enqueue or merge; foreground).** With `MERGE_METHOD=queue`, a clean base advance during the wait is trusted to the queue's speculative merge (OFFLOAD: do not re-rebase); only real un-mergeability acts. With `direct` there is no speculative merge: if the base moved since the CI run the watch saw (compare the base tip with the one recorded at Step 0.7), never merge on that stale CI: re-sync (Step 0.7), push `--kind rebase`, re-watch to `CI_GREEN`, then come back here, unless branch protection itself requires the branch to be up to date (then the host refuses a stale merge and re-syncing first only adds a round).
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-sentinel.sh" --contract=2 verify gates
```
- exit 0 → both sentinels valid for this tree. Exit 1 → HALT: a push since the flip left the proof pointing at other bytes; re-earn (review-code) before any merge. Exit 3 → HALT.
Then `gh pr view <N> --json mergeable,isDraft,state`: `MERGEABLE`, not draft, `OPEN`. `UNKNOWN` after a minute's retry is NOT a pass: wait, re-read. `--local`: the base must still be at the recorded Step 0.7 tip, else re-enter 0.7 (and re-earn Phase 1 before the push). A `mergeable` reading older than two minutes is stale: re-read before EVERY enqueue. Re-run the Step 2c closing-keyword check on the live body, every branch commit and the live title now: a miss is a HALT (reword, `--rewritten` push, edit the body), never an enqueue. A pause the user chose because a gate was blocked expires when the blocker clears: re-confirm, then drive to merge.

**Arm the `step5` monitor now, in every case including the pause** (`monitor --pr <N>`, after `monitor --stop` of the previous one), and keep it through the ENTIRE queued wait.

**G6.5 — Enqueue or merge, per `MERGE_METHOD`: only through the script** (foreground, `timeout: 300000`):
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-gate.sh" --contract=2 enqueue --pr <N> -- MERGE_FLAGS
```
It refuses, in order: the no-merge pause (`ship-no-merge`), a draft, a closing keyword in a branch commit message or the live title (those close issues the moment the commit reaches the default branch, past every gate), a flip precondition that no longer holds (a push since the flip), and a review or E2E gate that fails for this tree. Then `queue`: the label, read back; `direct`: `gh pr merge <N> MERGE_FLAGS` (`MERGE_FLAGS` is read only for `direct`). An issue this branch targets with no closing line in the live body is a WARNING, not a refusal (`WARN started-issue-not-closed`, the same check `body-check` runs at draft time): add the `ISSUE_CLOSE_KEYWORD #N` line, or name it after `owns` in a line-start `⚠️ ADDITIONAL PR REQUIRED` banner backed by the reviewed plan's `## PRs` row; otherwise say in the report that it stays open.
- exit 0 → enqueued / merge requested: start the queue watch. Exit 10 → the label is already on the PR: **never re-stamp it** (it defeats the queue's per-SHA failure memory); go straight to the watch.
- exit 1 → HALT, the line says which. The no-merge pause is the sanctioned G0 stop: do NOT enqueue until the user now explicitly says to merge; then remove `ship-no-merge` and re-run. <!-- ask:class=pause --> Every other refusal: fix the named cause, re-run.
- exit 3 → a read or the write failed: `gh auth status`, re-run. Exit 2 → usage, or `admin-refused`: `--admin` bypasses branch protection and runs only by hand, only on the user's instruction for that instance. <!-- ask:class=admin -->
Never a plain `gh pr merge` or a hand-applied queue label: on a queue-governed base a plain merge bypasses the queue.

**Queue / merge watch — to completion** (`run_in_background: true`, `timeout: 1800000`, same turn as the monitor; re-arm on every TIMEOUT):
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-watch.sh" --contract=2 queue --pr <N> --max-minutes 25 --poll 180
```
Act on the `VERDICT:` line: `MERGED` → post-merge (still NOT done); `TIMEOUT` (exit 4) → re-arm, at most 4 consecutive times, then report what is still pending and ask before continuing; `DEQUEUED` → the dequeue protocol, diagnose BEFORE acting; `NEVER_QUEUED` → nudge your provider to re-evaluate ONCE (never its force-queue command, which skips the admission conditions), re-arm; a second `NEVER_QUEUED` is a diagnosis, not another nudge; `LABEL_MISSING` (green, label gone, not merged) → re-apply once through G6 and `ship-gate.sh enqueue` (if a push moved the head, watch it to `CI_GREEN` first); `CONFLICTING` → "Conflicts while queued"; `CLOSED_UNMERGED` → do not re-arm, report, stop; `HEAD_MISMATCH` → re-run Step 4.5 for the new head (watch to `CI_GREEN`), then enqueue through the script. Poll every 2–3 minutes: the host's API quota is shared by every session on the account, and sub-minute polling from several parallel ships has exhausted it.

**Dequeue protocol (MANDATORY on any dequeue signal).** Verify it is a real dequeue from the provider's authoritative state, not a label (labels drift). Read the REASON the provider gives. If the reason names no check and your PR looks green, the failure is on the queue's **batch draft**, a different ephemeral PR: read ITS job logs, not your PR's green rollup. Then fix through the Step 4.5 route (census of the batch run, label, one push), never a bare push. **One diagnosis-backed requeue maximum**; on a second dequeue with your checks never failing, something structural is wrong: wait (bounded, 60 min) for the base to advance, re-sync, push `--kind rebase`, never an empty commit. Log each outcome (`dequeue-repush`, `dequeue-wait-expired`). The full protocol and the war story: `references/queue-protocol.md`.

**Conflicts while queued.** A queued PR can go CONFLICTING the instant another PR merges ahead of it; the monitor must run through the whole wait. On CONFLICTING: re-sync (Step 0.7), resolve, lint, push `--kind conflict`, watch the new head to `CI_GREEN` (Step 4.5 item 1; the enqueue refuses a head with no green recorded), re-check G6, re-enqueue through `ship-gate.sh enqueue`, re-arm. After the flip, OFFLOAD needs no local Phase-1 re-run here: CI on the new head is the re-check. Repeat until merged.

**After `MERGED` — in this order (cleanup is LAST: it deletes the state this work reads).**
1. Stop the `step5` monitor.
2. **Close the issues and move them to Done NOW** (`TRACKER`): every `ISSUE_CLOSE_KEYWORD #N` in the body is closed by the host at merge to the default branch; on another base branch close them yourself with a comment naming the PR. Before closing, check for open sub-issues: a parent with open children is skipped on the first pass and retried after the rest; one still held is a defect in this PR's body (it claims a parent whose child it does not close): fix the body to `Refs`, never a silent skip; a guard that cannot read the children is FAILED, never "no children". The close-out is idempotent: every issue ends in exactly one reported outcome (closed + Done / already / HELD / FAILED). A red post-merge run never holds the close.
3. **Watch post-merge CI on the base to green** (`run_in_background: true`, `timeout: 3600000`):
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-watch.sh" --contract=2 postmerge --sha "$(gh pr view <N> --json mergeCommit --jq .mergeCommit.oid)"
```
   `POST_MERGE_RESULT=GREEN` (exit 0) → go on; `RUNNING` (exit 124) → re-arm, at most 3 consecutive times, then report the still-running runs and ask; `FAILED` (exit 1) → diagnose and fix (the ship is still not complete). If the fix is to REVERT this PR, reopen every issue this ship closed with a comment naming the revert PR, move the cards back, and lead the final report with `reverted: #PR — reopened #N`; the re-landing PR owns the close. `ERROR` (exit 3) → never green: fix, re-arm. `NOT-CONFIGURED` (exit 10, `POSTMERGE_CI=none`) → say so in the report. No verdict line → UNVERIFIED.
4. **Do the post-merge, in-session close-out**: every step the PR body's `## Close-out` line lists (a rollout, a flag flip, a smoke check) is executed now by this session, bounded, not reported as a to-do; a step marked as a shared-environment write runs only if the user approved it before the merge (Step 2c). Every observation loop distinguishes "signal absent" from "probe failed" (auth, network, rate limit): a failed probe is `PROBE_ERROR`, never "not yet". Signal correct → `verified: <evidence>`; signal wrong → reopen the issue, move it back, start the follow-on fix on its own branch through the worktree skill (one new branch in one new sibling folder from the base; say branch, folder and starting commit) and lead the report with it; bound expired → re-arm once, then ask the user: a one-commit PR registering a `when: pre` verification row, or reopening the issue. <!-- ask:class=infra-write --> Post the outcomes as one PR comment.
5. **Close the separate base-side fix PR(s)**: diff against the base now empty → close with "landed via #N"; else leave open and report it under the `⚠️ ADDITIONAL PR REQUIRED` banner.
6. **Archive the fix-loop ledger** as one PR comment (`ship-log.sh --contract=2 summary` plus the auto-decision lines), before cleanup deletes it. Telemetry never blocks the ship. (v1: the summary; the per-ship retro scorecard is a roadmap item.)

**The final report opens with the fixed close-out sections, in this order, and no other remaining-work list is allowed:** (1) `⚠️ ADDITIONAL PR REQUIRED (N total): …` or `Additional PRs: none`; (2) `Issues closed + moved to Done: #A, #B`; (3) `Release-action rows registered: <ids>` or `none`; (4) `Post-merge, in-session steps: <step — verified: evidence>` or `none`; (5) `Follow-up tickets (user-approved): #N` or `none`; (6) `Proposed tickets awaiting your approval: …` or `none`. "Still todo" lists are banned: a leftover is done now or proposed as a ticket. Then the `FIXLOOP:` summary, every `auto-decision class=` outcome, every push with its review call and the total unreviewed delta (`SHIP_STATE/review-chain`: the `unreviewed_delta: files= lines= links=` that `verify review` prints, summed over every push not covered by a review, `manual` included), the non-required reds, files left unstaged. Collect all of it BEFORE cleanup; print it AFTER.

**Cleanup — once, only after `MERGED` and all of the above.**
```bash
bash "$(git rev-parse --show-toplevel)/.claude/skills/ship/bin/ship-init.sh" --contract=2 --cleanup [--delete-remote-branch]
```
- exit 0 → the state directory is gone (the script re-reads the PR state and asserts the path before any removal; never `rm -rf` by hand). Exit 1 → the PR is not `MERGED`: state kept (expected on a pause or while queued). Exit 3 → gh unreadable: nothing deleted. Exit 5 → the remote branch delete failed (state is gone): delete by hand if still wanted. Pass `--delete-remote-branch` for a throwaway feature branch; skip it when another PR is stacked on it.

---

## Anti-patterns

1. **Delegating the pipeline to a subagent.** Three multi-hour stalls; see principle 3.
2. **Treating OFFLOAD as "skips checks."**
3. **Self-classifying a red** ("pre-existing", "not mine", "just lint").
4. **A hand-rolled stash, a hand-rolled rebase, or a raw `git push`.** The scripts record the lease; a raw push leaves it stale and the next push fails with a false "remote moved".
5. **Reading one job's log and pushing.** Census first; one push per census.
6. **Narrating a wait without a bounded task armed in the same turn.**
7. **Pushing between green and flip.**
8. **Treating sentinel existence as validity**, or writing one by hand.
9. **Requeue spam.** One diagnosis-backed requeue; then fix code or escalate.
10. **A plain merge on a queue-governed base**, or a merge from a draft.
11. **Reporting "done" with an open PR, an open started issue, or a to-do list in the body.**
12. **Deciding the fix-round cap yourself.** The eleventh round is the user's call.
13. **Retyping the task list at verification time**, or writing a sentinel over a tree a check never saw.
14. **Spelling an unrun or manual gate as passed.** Manual attestation and "not run (<reason>)" are the only honest words.

---

## Reference

- `references/exit-codes.md` — every script's exit table, the exit 9 mechanism, background-pointer rules
- `references/sync.md` — why rebase first, the three autostash outcomes, merge-only content, remote-unseen, co-edited verification, wip squash
- `references/failure-triage.md` — no self-classified reds in full, labels, the census grammar, fold-in rules, war stories
- `references/queue-protocol.md` — the dequeue protocol, batch-draft diagnosis, conflicts while queued, the one-requeue rule
- `references/pr-body.md` — the PR body template, the release-action block grammar, the close-out sections, the docs subagent prompt
- `ship.env.example` — every script-read key with its worked default
- Companion: review-code — writes the sentinels this skill reads (`references/sentinels.md` there is the contract)
- Companion: checkpoint — the documentation step this skill dispatches
