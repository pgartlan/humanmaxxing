---
name: checkpoint
description: Checkpoint a unit of work — docs, quality checks, git commit. It never opens or merges a PR; for commit→PR→merge, use /ship.
user-invocable: true
allowed-tools: Bash(git *), Bash(gh pr view *), Bash(gh pr list *), Bash(gh project field-list *), Bash(gh project item-edit *), Bash(date *), Bash(mkdir *), Read, Edit, Write, Glob, Grep, Agent
---

# /checkpoint — docs, quality gate, commit

Run the full procedure in order; don't skip steps or say "done" while a file is uncommitted or a
session summary is missing — the code working is not the same thing as the checkpoint being done.

`/checkpoint` is a save point: docs, quality checks, a commit, and (per `PUSH`) a push. **It never
creates a PR and never merges.** When the commit is done and a PR is wanted, tell the user to run
`/ship` (if installed), the single PR path: two skills that each drive a PR to merge drift apart, and
the one that drifts loses the PR gates (protected files, the bounded CI watch, "never merge without
green CI", the merge queue).

---

## Configuration — adapt these to your repo

**Any command you put in a slot must also be added to `allowed-tools` above** (the list ships with
`git`, `date`, `mkdir` and the exact read-only and board `gh` commands Steps 3 and 3.7 use, no stack's
commands; `gh pr merge` is not in it, and checkpoint never merges); otherwise the first checkpoint stops
on a permission prompt. Add each slot's command in its exact form (`Bash(go vet ./...)`,
`Bash(npm run lint)`), never a whole tool (`Bash(npx *)`).

This skill reads the block below the same way an `.env` file is read: one `KEY=value` per line,
everything after the first `=` is the value, a line starting with `#` is a comment, and each
comment sits on its own line above the key it describes.

```
# Integration branch you rebase onto and commit toward (e.g. develop, main).
BASE_BRANCH=
# Type check, every sub-project CI checks (e.g. npm run typecheck, go vet ./..., mypy src).
TYPECHECK_CMD=
# Lint, the form CI runs.
LINT_CMD=
# Unit test runner.
TEST_CMD=
# Production build.
BUILD_CMD=
# A pattern pgrep -f matches against a dev server running from this folder (e.g. next dev). When one
# runs, the build is skipped (it would fight the server for its output folder) and reported as
# skipped, never as passed. Empty: the build always runs.
DEV_SERVER_PATTERN=
# Secret scan over exactly what git would commit (tracked files plus untracked files git does not
# ignore), never git-ignored files: a local, ignored key file must not turn every scan red. NOT
# `gitleaks detect --source . --no-git`, which reads ignored files. When the
# repository has its own scan (a gitleaks config, a secret-scan pre-commit hook or script), use
# that command with its config instead: it is faster and knows the repository's allowlist.
# Otherwise the command shown below. Worked default, one line, no file to add to the repo: it copies the files
# `git ls-files --cached --others --exclude-standard -z` lists AND that exist on disk (a tracked
# file deleted in the working tree is listed but absent) into a temporary folder, runs gitleaks
# there, and exits 0 clean, 1 leaks, 2 when gitleaks is missing or the list could not be built
# (never "clean"). It runs from the repository's top folder, wherever it is started. Approve this
# exact command at its first prompt, never a blanket `Bash(bash -c *)` in allowed-tools, which
# would approve any command wrapped in `bash -c`.
# A scan tried clean is not proof it catches this repository's secrets: when a known secrets
# finding (a hard-coded key, a fallback signing secret) is not flagged by the scan, the note above
# this key says "tried: clean, but does not catch the finding at <file:line>", never a bare
# "ready" or "clean", and that finding stays open on its own.
# Worked default (copy it after `=` as one line):
# bash -c 'command -v gitleaks >/dev/null || { echo "gitleaks is not installed" >&2; exit 2; }; d=$(mktemp -d) || exit 2; trap "rm -rf \"$d\"" EXIT; cd "$(git rev-parse --show-toplevel)" || exit 2; git ls-files -z --cached --others --exclude-standard | while IFS= read -r -d "" f; do [ -f "$f" ] || continue; mkdir -p "$d/$(dirname "$f")" && cp -p "$f" "$d/$f" || exit 2; done; [ "${PIPESTATUS[0]}${PIPESTATUS[1]}" = 00 ] || exit 2; gitleaks detect --no-git --redact --source "$d"'
SECRET_SCAN_CMD=
# Optional static analysis, e.g. semgrep scan --baseline-commit <merge-base>.
SAST_CMD=
# Optional cheap deterministic checks CI runs as separate jobs, separated by ";". Each runs as its
# own check with its own exit code.
INVARIANT_CMDS=
# The critical-path list: a file, one glob per line (`#` lines are comments), paths from the
# repository's top in git's glob spelling (`**` crosses folders). Product code matching it that
# changed with no test touched blocks the commit. The SAME file ship (CRITICAL_GLOBS_FILE),
# review-code and peer-review read; never keep a second copy. Empty: the test-update guard prints
# "not configured". Named but missing or unreadable: the guard halts, never "no critical paths".
CRITICAL_GLOBS_FILE=
# Globs that identify a test file, space-separated, same spelling (e.g. **/*.test.ts tests/**
# **/*_test.go). The same value as ship's TEST_GLOBS. Required when CRITICAL_GLOBS_FILE is set:
# without it the guard cannot tell a test from product code, so it halts.
TEST_GLOBS=
# One path-gated conditional check per domain your repo has (migrations, IaC, generated-code
# drift, workflow lint, SDK parity, a toolchain your deploy CI skips tests for, …), as
# <glob> -> <command>, separated by ";". Define the detection once; share it with /ship if installed.
# A domain check validates and never applies: syntax checks, dry runs, a plan and never an apply.
# A migration changes the database when it runs, so it is validated without being executed.
# Anything that writes to a shared environment is not a checkpoint check: ask the user first.
DOMAIN_CHECKS=

# Per-session summaries (e.g. docs/chat-summaries/).
SESSION_SUMMARY_DIR=
# Where an active plan is archived once a checkpoint lands (e.g. docs/plans/).
PLAN_ARCHIVE_DIR=
# Per-PR changelog fragments, if used (e.g. docs/changelog.d/).
CHANGELOG_DIR=
# Bug-fix / incident lessons (e.g. docs/notes/review-findings/).
REVIEW_FINDINGS_DIR=
# Globs never committed even if modified (agent-memory caches, scratch).
ALWAYS_EXCLUDE=

# State folder for the docs marker and the check logs. Not a setting: every step computes it as
# SHIP_STATE="$(git rev-parse --git-path ship-state)"; mkdir -p "$SHIP_STATE"

# PUSH: ask | always | never (default: ask). Whether Step 3 pushes after the commit. ask: say
# what would be pushed and wait for the user's yes, unless their request for this checkpoint
# already said to push. always: push without asking. never: commit only (a repository with no
# remote, or a team that pushes by hand). Match the project's instructions file: a rule there
# that forbids pushing unless the user asks means ask.
PUSH=ask
# COMMIT: auto | ask (default: auto). ask: before Step 3's commit, show the staged files and the
# message and wait for the user's yes, unless their request already said to commit. Match the
# project's instructions file: a rule there that says to ask before every commit means ask.
COMMIT=auto
# AUTOSTASH: yes | no (default: yes). no: never stash, not even through git. With uncommitted
# work, Step 0a fetches but does not rebase; Step 3 commits first, then rebases onto the base
# branch (no --autostash) before the push, and re-runs Step 2's checks when the rebase brought
# in commits. Match the project's instructions file: a rule there that forbids stashing in any
# form, including --autostash, means no.
AUTOSTASH=yes
```

**A command slot you do not use is left empty** (`TEST_CMD=`), never filled with prose: `none` or
`covered by CI` would be executed as a command. Note the reason in a
comment on its own line, above the slot, never beside the value (a comment beside a value is read as part of the value, and a
command that is only a comment exits 0 and reads green). The steps below skip an
empty slot and print `<SLOT>: not configured`, never a pass.
`SECRET_SCAN_CMD` empty means no secret scan runs at all: say so in every report.

**Companions (optional):** `/ship` for anything headed to a PR; a project-tracker board (Step 3.7).

---

## Design principles

1. **Docs aren't optional, even for a small change** — a session summary is how the next session
   recovers the WHY, not just the WHAT, and it must land WITH the code, never after: a summary
   committed post-merge gets stranded on a branch that's already gone.
2. **Delegate docs to a background subagent** — prose-writing isn't on the commit's critical path.
3. **A red check blocks the commit, always** — "pre-existing" or "just lint" are reasons to tell the
   user, never reasons to self-clear a red result. A check that could not run (a HALT, a skip) is
   not a pass either: it is reported as what it is.
4. **Scope verification is a gate, not a courtesy** — every file riding along must be explainable;
   an unexplained file gets a question, not a guess.
5. **A pass belongs to the tree it ran on** — an edit made after a check started (a fix, a
   formatter's rewrite) is not covered by that check's green: re-run it. This skill writes no
   pass sentinels: nothing reads them, and a pass recorded with only a time and no tree would
   later be trusted for code it never checked.
6. **Issues close at merge, never at a commit** — a commit carries `Refs #N`; the PR body closes;
   the board moves when the PR has merged (Step 3.7).

---

## Pre-flight: Context assessment

Every tool call here carries the full conversation, so compacting first is cheap insurance. Check
for an active plan (`ls ~/.claude/plans/*.md`) and the current branch, then suggest a `/compact`:
if a plan is mid-flight, warn that compacting loses its position unless the compact message states
it explicitly; otherwise a generic `/compact Run /checkpoint after. Branch: [branch]. In progress:
[...]`. Wait for a pasted compact command or "proceed" before continuing.

---

## Step 0: Scope verification (first)

**0a — Sync with the base branch.** On a detached HEAD (`git branch --show-current` prints
nothing) STOP: there is no branch to sync or push. With no remote (`git remote` prints nothing; `PUSH`
is then `never`): skip every fetch and the lease below, rebase onto the local `$BASE_BRANCH`, and
read every `origin/$BASE_BRANCH` in this skill as `$BASE_BRANCH`. Otherwise, first establish the push lease for
Step 3 from the **live** remote branch, and make sure everything on it is already in your history:

```bash
B=$(git branch --show-current)
git fetch origin "$B" 2>/dev/null                    # fails harmlessly when the branch was never pushed
LEASE=$(git rev-parse --verify -q "refs/remotes/origin/$B") || LEASE=none
[ "$LEASE" = none ] || git merge-base --is-ancestor "$LEASE" HEAD || echo "REMOTE-UNSEEN $LEASE"
echo "LEASE=$LEASE"
```

`REMOTE-UNSEEN` means the remote branch has commits that are not in your history. Read
`git cherry -v HEAD "origin/$B"` (oldest first):
- **Only `-` lines:** every remote commit has an equivalent in yours. It is your own earlier push
  from before a rebase (a previous checkpoint rebased but stopped before pushing). The lease value
  is safe to use as it is.
- **`+` lines:** read each one (`git show <sha>`). A `+` is either another session's commit or
  your own commit whose patch changed when you resolved a rebase conflict. Bring in exactly the
  commits that are not yours (`git cherry-pick <sha>…`, oldest first; on a conflict resolve per
  hunk and `git cherry-pick --continue`), never `git rebase "origin/$B"`, which would replay
  base-branch commits you rebased past. A merge commit among them, or one you cannot attribute:
  STOP and ask the user. Then run the block again.

A lease pinned to commits you never integrated would let your force push delete them.

Keep the final `LEASE=` value as text: shell variables do not survive between tool calls, so it
goes into the Step 3 command; `none` means the branch was never pushed.

**Then** (with `AUTOSTASH=no` and uncommitted work: fetch only, and rebase after Step 3's commit):

```bash
git fetch origin "$BASE_BRANCH" || { echo "HALT: fetch of $BASE_BRANCH failed; not rebasing onto a stale base"; exit 1; }
git rebase --autostash "origin/$BASE_BRANCH"
```

(with no remote: `git rebase --autostash "$BASE_BRANCH"`, no fetch). A failed fetch is a HALT: fix
the cause and re-run, never rebase onto whatever the last fetch left. Rebasing keeps
history linear and surfaces conflicts per-commit, and `--autostash` carries uncommitted work across
it. **Never a hand-rolled `git stash` / `git stash pop`:** the stash stack is shared by every
worktree and session of the repository, and a bare `pop` can restore someone else's work. Resolve
hunk-by-hunk (never blind "ours"/"theirs" whole-file), `git rebase --continue`.

**An autostash conflict still exits 0.** Git prints `Applying autostash resulted in conflicts`
and "Successfully rebased", so after a rebase that **exited 0 and printed a `Created autostash:
<sha>` line**, run `git status --short`: any `UU` line means your uncommitted work did not re-apply
cleanly. It is safe in the stash entry whose SHA git printed on that line; take the SHA from that
line, not from the top of `git stash list` (another session's autostash entry looks the same).
Resolve, then drop that entry only, finding its current `stash@{n}` by that (short) SHA:
`git stash list --format='%H %gd' | awk -v s=<sha> 'index($1, s) == 1 {print $2}'`.
This check applies only there. A rebase that stopped on a conflict (non-zero exit) shows the same
`UU` lines for its own commit: resolve them and `git rebase --continue`; there is no entry of yours
to drop. No `Created autostash:` line means no entry of yours exists: never drop an entry by its
position, and never run the lookup above with an empty SHA (it would match another session's entry).

**0b — Categorize every modified/untracked file** (`git status`): in-scope (commit it), out-of-scope
(leave it), or `ALWAYS_EXCLUDE` (never commit). Don't ask for confirmation on the obvious in-scope
list — commit what you edited. Only ask about files you genuinely can't explain.

---

## Step 1: Documentation (required — delegate to a background subagent)

**Dispatch in the background and don't wait for it** before launching 1c's quality gate — the docs
subagent's completion marker gates Step 3 (commit), not Step 2. Note the time you dispatch it
(`date +%s`): a marker an earlier checkpoint in this folder left holds an older time, and Step 3
counts the marker only when its time is not older than this one.

```
You are the documentation step of a checkpoint. Derive context yourself: branch, `git status
--short`, `git log --oneline -5`, and THIS session's transcript, found by this session's id and
nothing else. With Claude Code:
  find "$HOME/.claude/projects" -maxdepth 2 -name "${CLAUDE_CODE_SESSION_ID:?}.jsonl" | head -1
(another harness: its transcript file for this session's id). If that prints nothing, STOP and
report "session transcript not found" — never fall back to the newest transcript in the folder:
with sessions running in parallel that is another session's, and its content would be written
into this repository. Use that one path for everything below; no second search.
Read the transcript for what was done and key decisions ("decided to", "chose", "rejected X
because"); if this was a design/architecture session, emphasize rationale over implementation detail.

Do ALL of:
1. Changelog — write this PR's entry to a fragment at $CHANGELOG_DIR/<branch-slug>.md, not a shared
   flat CHANGELOG.md (concurrent PRs appending at the same anchor collide, and most merge queues
   don't honor a union merge driver — per-PR fragments compiled at release time avoid it).
2. Update any design docs a schema/conceptual change affects; flag schema changes explicitly.
3. Archive any active plan to $PLAN_ARCHIVE_DIR.
4. Create $SESSION_SUMMARY_DIR/{feature}-{YYYY-MM-DD}.md with: Session Overview, Completed Work,
   Pending Tasks, Key Decisions (what/why/alternatives-rejected/how-validated), Files Changed,
   Docs Updated, Session Stats (wall time, working time, turn counts, response latency — from
   transcript timestamps), Token Usage (input/output/cache-create/cache-read/total — from each
   assistant message's usage block), To Resume.
5. Write the marker: SHIP_STATE="$(git rev-parse --git-path ship-state)" && mkdir -p "$SHIP_STATE" &&
   date +%s > "$SHIP_STATE/checkpoint-docs-done"
   If that fails, report the failure; never write the marker anywhere else (no /tmp fallback).

Report the files created/updated so they can be staged.
```

If the subagent reports "session transcript not found" or a failed marker, tell the user: the
commit waits for the summary. Never write the marker yourself and never hand it another session's
transcript.

**1c — Launch the quality gate at the same time**, not after docs finish — the docs subagent
typically outlasts the whole suite below.

**Test-update guard (blocking, first).** Product code that changes behavior while its covering
tests stay untouched is the most common way red tests reach the base branch, and `$TEST_CMD`
passing doesn't prove the *changed* code's tests were updated, only that whatever already existed
still passes. Run this with the three slot values filled in (one line):

```bash
BASE_BRANCH='<BASE_BRANCH>' CRITICAL_GLOBS_FILE='<CRITICAL_GLOBS_FILE>' TEST_GLOBS='<TEST_GLOBS>' bash -c 'set -f; [ -n "$CRITICAL_GLOBS_FILE" ] || { echo "test-update guard: not configured (CRITICAL_GLOBS_FILE empty)"; exit 0; }; [ -n "$TEST_GLOBS" ] || { echo "HALT: TEST_GLOBS not configured; cannot tell a test from product code"; exit 20; }; cd "$(git rev-parse --show-toplevel)" || { echo "HALT: not inside a repository"; exit 20; }; [ -f "$CRITICAL_GLOBS_FILE" ] && [ -r "$CRITICAL_GLOBS_FILE" ] || { echo "HALT: cannot read $CRITICAL_GLOBS_FILE"; exit 20; }; REF="origin/$BASE_BRANCH"; [ -n "$(git remote)" ] || REF="$BASE_BRANCH"; MB=$(git merge-base HEAD "$REF") && [ -n "$MB" ] || { echo "HALT: no merge-base with $REF"; exit 20; }; C=(); X=(); T=(); while IFS= read -r g || [ -n "$g" ]; do case "$g" in ""|"#"*) continue;; esac; C+=(":(glob)$g"); done < "$CRITICAL_GLOBS_FILE" || { echo "HALT: cannot read $CRITICAL_GLOBS_FILE"; exit 20; }; for g in $TEST_GLOBS; do T+=(":(glob)$g"); X+=(":(exclude,glob)$g"); done; ch() { git diff --name-only "$MB" -- "$@" && git ls-files --others --exclude-standard -- "$@"; }; ALL=$(ch .) || { echo "HALT: the diff could not be read"; exit 20; }; [ -n "$ALL" ] || { echo "HALT: nothing changed against the merge-base; the guard would pass vacuously"; exit 20; }; [ "${#C[@]}" -gt 0 ] || { echo "PASS: the critical-path list holds only comments; nothing is critical"; exit 0; }; P=$(ch "${C[@]}" "${X[@]}") && N=$(ch "${T[@]}") || { echo "HALT: the diff could not be read"; exit 20; }; [ -n "$P" ] || { echo "PASS: no critical product file changed"; exit 0; }; [ -n "$N" ] && { echo "PASS: a test file changed too"; exit 0; }; while IFS= read -r f; do echo "COUPLING_PROD: $f"; done <<< "$P"; echo "STOP: critical product code changed and no test file changed"; exit 10'
```

Exit 0 = pass (or `not configured`, which is said in the report, never as a pass). Exit 20 = HALT:
the merge-base, the diff or the slots could not be read, or nothing changed; fix the cause, never
read it as clean. Exit 10 = STOP: for each `COUPLING_PROD:` file, either (a) add or update the
covering tests now, or (b) write a justification **in the commit body** that the change is
provably behavior-neutral: a pure rename, a comment, log text, or a type-only edit with no runtime
effect. This is a judgment gate, and (b) exists for genuine no-behavior changes; it is a stated
reason, never a silent skip. "I'll add tests later" is not a justification and is refused. Untracked
files count (a new test file you have not staged yet is a test change).

**Merge-base (once, for SAST and the domain checks):**

```bash
MERGE_BASE=$(git merge-base HEAD "origin/$BASE_BRANCH") && [ -n "$MERGE_BASE" ] && echo "MERGE_BASE=$MERGE_BASE" || { echo "HALT: no merge-base with origin/$BASE_BRANCH"; exit 1; }
```

A HALT here stops the gate: an empty merge-base would silently skip every domain check and widen
the SAST baseline. Keep the printed value as text for the commands below.

**Each check is its own call** (in the background, all launched together), never one block judged
by its last exit status: in `$LINT_CMD; $TEST_CMD`, a red lint followed by green tests exits 0. Run
each set slot (`TYPECHECK_CMD` — every sub-project, since CI gates on the union; `LINT_CMD`;
`TEST_CMD`; each `INVARIANT_CMDS` entry; `SECRET_SCAN_CMD`, always, including docs-only diffs;
`SAST_CMD` with the merge-base as its baseline; and each `DOMAIN_CHECKS` entry whose glob matches a
file changed since the merge-base, especially anything your CI defers off the PR, where this is the
only pre-push gate) as:

```bash
L="$(git rev-parse --git-path ship-state)/logs" && mkdir -p "$L" || { echo "HALT: no log folder"; exit 1; }
<command> > "$L/<name>.log" 2>&1; rc=$?; echo "<name> rc=$rc"; [ "$rc" -eq 0 ] || tail -n 40 "$L/<name>.log"
```

The full log stays in the file; only a failing check's last 40 lines reach the screen. An empty slot
is not run: print `<SLOT>: not configured`.

**The build** runs the same way, unless a dev server from this folder would fight it:

```bash
P='<DEV_SERVER_PATTERN>'; if [ -z "$P" ]; then rc=1; else pgrep -f "$P.*$(pwd)" >/dev/null; rc=$?; fi
case $rc in 0) echo "build: skipped (dev server running)";; 1) echo "build: run it";; *) echo "HALT: pgrep failed (rc $rc); cannot tell whether a dev server runs here";; esac
```

`run it` → the per-check wrapper above with `$BUILD_CMD`. `skipped (dev server running)` is reported
as skipped, never as passed: the build did not run. A pgrep failure is a HALT, never "no server".

**Capture real exit codes.** `cmd 2>&1 | tee log; echo $?` reports `tee`'s exit (always 0), not
`cmd`'s. Read `${PIPESTATUS[0]}` in bash (`${pipestatus[1]}` in zsh) right after the
pipeline, or write the output to a file first and check `cmd`'s own exit; an empty value is not a
success.

---

## Step 2: Quality checks — collect and gate

Collect every 1c result (run any not yet launched) and list each check as passed, failed, skipped
(with the reason) or not configured. Fix red before committing. **Never "fix" a red by changing a
test's expected values to match the new output, or by suppressing a type, SAST or secret-scan
finding** (an ignore comment, a baseline or allowlist entry) unless the user agrees that the finding
is wrong: those reds are the signal. After any fix, re-run every check the fix could affect, and
report a check as passed only from a run that started after your last edit.

---

## Step 2.5: Self code review

Before committing, ask honestly: did I read every file I'm about to commit, not just the changed
lines? Any silent catches, stubs, or unimplemented paths? Does the logic match the plan, or did it
drift? Any obvious bugs, edge cases, missing error handling, or security issues visible right now?
Any "no" or "not sure" → review now, before proceeding.

**Findings log (bug-fix / incident checkpoints only).** Write to `$REVIEW_FINDINGS_DIR/<branch-
slug>.md` (deterministic name — append if a prior review pass this session already created it):

```markdown
## YYYY-MM-DD — [Brief title]
- **Root cause**: what was actually wrong
- **How discovered** / **How missed** / **Pattern** (general category) / **Prevention**
```

Skip for pure feature work. Commit the file — this is how a lesson survives the session that learned it.

---

## Step 3: Git commit

**Wait for `$SHIP_STATE/checkpoint-docs-done`** with a time not older than Step 1's dispatch before
staging — the session summary must be *in* this commit, never a follow-up.

1. `git status` / `git diff` — review the change; `git log --oneline -5` — match commit style
2. Stage the files from Step 0 **and** the session summary from Step 1
3. Reference a tracked issue as `Refs #123` only — **never a closing keyword anywhere in a commit
   message, mid-line included** (`Closes`, `Fixes`, `Resolves` and their forms, before any `#N`).
   The host closes an issue named after a closing keyword anywhere in a commit message the moment
   that commit reaches the default branch, past every gate (on a flow whose base is not the default
   branch, that is a release-time close nobody asked for). Closing keywords go only in the PR body.
   Then, with `COMMIT=ask`, show the staged files and the message and wait for the user's yes first; commit via heredoc:

```bash
git commit -m "$(cat <<'EOF'
type: description

Refs #123
EOF
)"
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`. **Never add an AI-attribution footer** —
write the message as if a human engineer authored the change. A behavior-neutral justification from
the test-update guard goes in this body.

With `AUTOSTASH=no` and a rebase skipped in 0a: rebase now (`git rebase "origin/$BASE_BRANCH"`, no `--autostash`), and re-run Step 2's checks if it brought in commits.

4. Push, per `PUSH`: `never` → skip this item and say "committed, not pushed (PUSH=never)";
   `ask` → show the branch and the commits that would go out and wait for the user's yes (a
   request that already said "push" is that yes); no yes → stop here, committed and not pushed,
   and say so. Before pushing, check that this branch's PR has not already merged
   (`gh pr list --state merged --head <branch> --json number,mergedAt`): if one has, STOP and tell the
   user; new commits go on a fresh branch from the base, never onto a merged PR's branch. Then push, with the lease pinned to the `LEASE=` value Step 0a printed:
   `git push --force-with-lease="refs/heads/<branch>:<value>" -u origin HEAD`, with an empty
   value (`refs/heads/<branch>:`) when 0a printed `none`, which means "the remote branch must not
   exist yet". Force, because Step 0 rebased. A bare `--force-with-lease` compares against your
   remote-tracking ref, which any fetch since (yours, another session's, an editor's background
   fetch) can have moved to someone else's push, so it can overwrite their commits; 0a's ancestry
   check is what makes the pinned value safe. If the push is rejected, another session pushed
   since 0a: re-run 0a (it integrates their commits), re-run the checks, and push with the new
   value. Never retry with `--force`.

**Diff-scope check before pushing:** `git diff --cached --stat` against what the task required — a
file outside scope, or a hunk with far more changed lines than the task accounts for, is worth
inspecting before it goes out (the shape to catch: a rename that should be a handful of lines
produces a huge diff because it silently reintroduced content that should have stayed deleted).

The checkpoint's commit is complete here. **No PR is created and nothing is merged.** If a PR is
wanted, tell the user to run `/ship`.

---

## Step 3.7: Close resolved issues and move them to Done (merged work only)

**Only for work that has ALREADY merged into `$BASE_BRANCH`.** A checkpoint commit on a feature
branch closes nothing: its issues close when its PR merges (ship's close-out does it). Run this step
only when the commit itself is on `$BASE_BRANCH`, or the PR it belongs to reads merged into it
(`gh pr view <N> --json state,baseRefName`: `MERGED` and `$BASE_BRANCH`). Anything else, or a read
that fails → skip, and report `issues close at merge`. A failed read is never taken as merged.

**The issue list is the merged PR body's closing-keyword issues, never the commit messages.**
Commits carry `Refs #N` only, and a `Refs #N` in the body is an issue that was mentioned, not
resolved. A keyword counts only at the start of a line, outside code fences, HTML comments and
inline code. A commit made directly on the base with no PR has no closing list: ask the user which
issues it resolves. Empty list, or no board → skip.

Per issue, in this order. Moving a card to Done can close the issue by board automation, so the
sub-issue guard runs before either write, and an issue it holds gets no board move either:
1. Already closed and on Done → `already closed + Done`. Closed but not on Done → only the move.
2. **Sub-issue guard.** Read the issue's open sub-issues (on GitHub, its `subIssues` through
   `gh api graphql`, which asks for permission). Open children → skip it now and retry it after
   the rest of the list. Still open on that second pass → `HELD (open children)`: a defect in the
   PR body, which claims a parent whose child it does not close. Report it; never close the parent,
   and never close the children to clear it. Children that cannot be read → `FAILED (sub-issue
   read)`, never "no children".
3. **Close.** The host closed it at merge when the base is the default branch; on any other base,
   close it yourself with a comment naming the PR (`gh issue close <N> --comment "Closed by #<PR>"`,
   which asks).
4. **Move to Done**, e.g. for GitHub Projects (v2): `gh project item-edit --project-id "<PROJECT_ID>"
   --id "<ITEM_ID>" --field-id "<STATUS_FIELD_ID>" --single-select-option-id "<DONE_OPTION_ID>"`.
   Look up the IDs once (`gh project field-list <num> --owner <owner>`) and keep them in
   Configuration.

Every write is checked: a failure is reported for that issue and the loop goes on. Each issue ends
in exactly one outcome: `closed + Done`, `already closed + Done`, `HELD (<reason>)` or
`FAILED (<error>)`. Any HELD or FAILED → `INCOMPLETE: #a #b`: re-run this step for those (it is
idempotent), and never report them as moved to Done. This is the same loop as ship's close-out after
a merge; keep the two in step.

---

## Step 4: Confirm and verify

`git status` again, mandatory. Any uncommitted/untracked files → list them explicitly and ask what
to do (commit separately, gitignore, intentional leftover) — never say "everything is committed"
while files remain uncertain. Report: what was documented, what was committed (files + message),
each check's result (passed / failed / skipped with its reason / not configured), remaining files
and their status, and Step 3.7's outcome per issue (or `issues close at merge`).
