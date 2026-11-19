# Claude Detailed Procedures — Template

> **Template — companion to `CLAUDE.template.md`; rename to `claude-details.md` (or your preferred path) and adapt. Your `CLAUDE.md` should reference sections here by anchor.**

This file holds the lengthy procedures your short-rules `CLAUDE.md` links out to. Keep `CLAUDE.md` terse (rules, triggers, one-line pointers); put the "how exactly" here so the top file stays skimmable.

---

## Configuration — fill in once, reference everywhere

Every section below assumes these slots exist. Collect the real values for your repo here instead of re-deriving them per section — drift between copies is exactly the bug this discipline exists to avoid.

```
BASE_BRANCH         — integration branch (e.g. develop, main)
REPO_LAYOUT         — bare-repo-plus-worktrees, single-checkout, or monorepo-with-packages
WORKTREE_ROOT        — parent directory siblings live under, if using worktrees
TRACKER              — issue tracker (GitHub Issues, Jira, Linear, …)
PROJECT_BOARD        — board/project identifier + status-field mapping, if you track status there
ERROR_TRACKER        — Sentry / Rollbar / Bugsnag / none — where caught errors get reported
LOG_SINK             — where console/stdout logging lands per runtime (e.g. platform logs, CloudWatch)
CLOUD_PROFILES       — one named credential profile per environment (dev/preview/prod or equivalent)
STATE_BACKENDS       — one IaC state backend identifier per environment, if using Terraform/Pulumi/etc.
IAC_TOOL             — Terraform / OpenTofu / Pulumi / CDK / CloudFormation / none (decides what
                       "When Deploy or CI Fails" keeps)
IAC_PLAN_CMD         — the local, read-only preview command for one module/stack (e.g. `terraform plan`,
                       `pulumi preview`, `cdk diff`); empty when IAC_TOOL is none
CI_PROVIDER          — GitHub Actions / GitLab CI / CircleCI / Buildkite / none (decides which CI
                       gotchas "When Deploy or CI Fails" keeps)
TEST_CMD / TYPECHECK_CMD / LINT_CMD / BUILD_CMD  — your quality-gate commands (see ship template)
DEV_SERVER_CMD        — how you start a local dev server; default port
E2E_PORT / QA_PORT     — dedicated ports for isolated test runners, distinct from the dev-server port
DOCS_ROOT             — top-level docs directory and its subfolder convention
HOOKS_DIR             — where your Claude Code hooks live: `.claude/hooks/` in the repository for the hooks pack (its
                        per-repository values in `.claude/hooks/hooks.env`); your own user-level hooks, if any, under
                        your user-level Claude config directory
TOKEN_BUDGET_MODES    — your named orchestration modes (defaults below: Frugal / Parallel / Max Parallel)
```

---

## No Silent Errors

**Never write a `catch` block that swallows an error without logging it.**

### Rules

- Every `catch` MUST log via your `ERROR_TRACKER` (or structured `console.error`/equivalent where no tracker is wired up).
- A catch block that intentionally ignores an error must still log *why* it's non-critical — silence and "this is fine" look identical from the outside.
- Code review flags any silent catch as a bug, not a style nit.

### Why this matters

We once spent hours chasing a UI bug where a cost-summary panel silently showed zero. Root cause: a downstream query was failing because a migration hadn't been applied yet — but the surrounding `catch {}` returned a zero fallback with no logging. The failure was real, active, and completely invisible. A crash would have been debugged in five minutes; the silent catch cost hours.

### Where errors go, by context (adapt the rows to your runtimes)

| Context | What to call | Where it lands |
|---|---|---|
| Server-side API routes / handlers | `console.error` (or equivalent) + `ERROR_TRACKER.captureException(err)` | Platform logs + tracker |
| Client-side components | Same, browser-side | Browser console + tracker |
| Background jobs / serverless handlers | `console.error` + tracker via your serverless error-reporting layer | `LOG_SINK` + tracker |
| Infra-only scripts with no tracker wired up | `console.error` with full context | `LOG_SINK` only — say so explicitly in a comment, don't let it look like an oversight |

If you have shared error-context helpers (something like `captureError(err, { tenantId, component })`, `trackAPIError(...)`), reference them here instead of ad hoc `console.error` calls — consistency makes the logs greppable.

### What to write

```
// WRONG — silent
} catch {}
} catch (_err) { fallbackValue = 0; }

// RIGHT
} catch (err) {
  console.error('[component-name] operation failed:', err);
  ERROR_TRACKER.captureException(err);
  fallbackValue = 0;  // still a fallback, but now a LOGGED one
}
```

Track known violations in a todo/backlog entry rather than leaving them silently unfixed — "we know about these and they're queued" is very different from "nobody knows."

---

## Starting Work on a Ticket

When you begin work on a tracked issue, immediately mark it in-progress and leave a tracking comment. This prevents duplicate work when multiple agents or sessions are active on the same tracker.

### 1. Move to "In progress"

Use your tracker's CLI/API to move the item to whatever status means "someone is on this" — get the item/field IDs once and keep them in your `PROJECT_BOARD` config slot rather than hardcoding them per call site.

### 2. Comment with session tracking info

```
🔧 Work started
- Path: <working directory / worktree path>
- Session: <session identifier>
- Date: <UTC timestamp>
```

- **Path** matters most when multiple worktrees can be active on the same repo.
- **Session** lets you correlate a comment with agent logs later.
- **Date** orders concurrent claims.

If your tracker supports it, treat "the first tracking comment posted wins the claim" as the tie-break rule for multiple agents watching the same backlog — lowest comment ID / earliest timestamp claims the work, everyone else skips it.

---

## Bulk Tracker Operations (3+ issues)

When moving 3+ items at once (status change, priority, labels), use a single batched mutation via your tracker's API where your environment allows it — a loop burns rate limit linearly with issue count; a batched call is one round trip regardless of N. **Where the batch API is unavailable** (for example, GraphQL is blocked in some hosted agent sessions, such as Claude Code cloud sessions, and returns 403), loop the REST call instead and stop at the first error; never let one failed batch read as "all updated".

**Pattern (GraphQL-style trackers, e.g. GitHub Projects):**

1. Resolve all target item IDs in one list call, filtered to the issue numbers you care about.
2. Build one mutation string with N aliased sub-mutations (`u0: updateItem(...) { ... } u1: updateItem(...) { ... }`), substituting each item's resolved ID and the target field value.
3. Send it as a single API call.

For trackers with no native batch-comment endpoint, fire the individual comment calls in parallel (backgrounded / concurrent), not serially — you still save wall time even without a single-call batch.

Keep your board's field/option IDs in the `PROJECT_BOARD` config slot — resolving them fresh from the API every time you need them is slower and they don't change often.

---

## Checkpoint Procedure

**Trigger phrase:** "checkpoint" or your equivalent slash command.

### 0. Scope verification (first, always)

- Run a status check; categorize every modified/untracked file into "in scope for this checkpoint" vs. "not sure."
- Ask the user explicitly about anything you can't confidently place. Guessing here is how unrelated files ride along into a commit.

### 1. Documentation

- Update your changelog (fragment-per-change if you use one — see the append-hotspot note under Git Workflow below).
- Update any spec/PRD docs affected by schema or conceptual changes.
- Run the propagation check below if any data schema changed.
- Write or update a session summary capturing what was done, what's pending, and key decisions — this is what a compacted context or the next session reads to resume.
- Archive any working plan file before it gets overwritten by the next task.

**When a doc change needs planning mode:** a minor field-level fix is an inline edit; a new concept, new entity type, or anything that changes how the system is *described* (not just implemented) warrants planning mode — search every section that references the affected concept before editing, not just the one you started from.

### 2. Quality checks

Run your full local gate: typecheck, lint, tests for anything new. Fix everything before proceeding — this stage exists precisely so nothing red reaches the commit.

### 3. Git commit

- Status check (never blanket-stage everything).
- Diff review — staged and unstaged.
- Check recent commit message style and match it.
- Link the tracker issue in the commit body (`Refs #N` or `Closes #N` if it fully resolves it).
- Commit via heredoc so multi-line messages format correctly.

### 3.5 Create PR / close issues

**Before opening the PR, run everything your CI will run, locally, first.** This is the single highest-leverage habit in the whole workflow — a CI failure discovered locally costs seconds; the same failure discovered on the 6th CI run costs the wait time of five prior red runs. See your `ship`/`pre-pr` skill for the exact command set (typecheck + lint + test + build + secret-scan + SAST, run in parallel).

Then:
- Sync with the base branch; merge/rebase and resolve conflicts per the Git Merge Protocol below if you're more than a few commits behind.
- Link the issue in the PR body (`Closes #N` to auto-close on merge, where your tracker supports it).
- Ask the user whether the tracked issue should close now or stay open for remaining work — don't assume.
- Move the board status if applicable.

### 4. Confirm and verify

- Status check again — MANDATORY. If anything uncommitted/untracked remains, list it explicitly and ask what to do. Never report "everything committed" while the status check disagrees.
- Report what was documented, what was committed, and what (if anything) is still pending.

### 5. Post-PR conflict check

Mergeability checks on some trackers are computed asynchronously — a PR can look clean at creation time and show conflicts seconds later once the diff finishes computing against the target branch. Launch a short bounded background check (poll once after ~30s) rather than assuming clean-at-creation means clean now. If it comes back conflicting, fetch, merge locally, resolve, push — immediately, not on the next round-trip with the user.

### Common mistakes to avoid

- Skipping documentation because the change felt "small."
- Deferring a decision that came up in conversation instead of recording it now.
- Forgetting to update a spec doc after a schema change lands.

### Session summary template

```markdown
# Session Summary: <topic>
**Date:** <date>
**Branch:** `<branch>`

## Overview
Brief description of what was accomplished.

## Completed
- Item with detail

## Pending
- [ ] Task

## Key decisions
1. Decision + rationale

## Files changed
- `path/to/file` (new/updated)

## To resume
1. Next concrete step
```

### When to checkpoint

On explicit request, before any commit destined for the remote, at natural stopping points in long sessions, and before context limits are reached.

---

## New Branch and Worktree Setup

**Trigger phrase:** "new branch," "new worktree," or equivalent.

With the worktree skill installed, this is one command; it also copies your local env files,
runs the install and, for an issue number, names the branch from the issue:

```bash
bash .claude/skills/worktree/bin/worktree-create.sh <name>
```

By hand (the fallback):

```bash
# 1. Fetch, then create worktree + branch from the REMOTE tip of the base branch.
#    --no-track: otherwise the new branch's upstream is the base branch itself.
#    Folder name: the branch name with any "/" replaced by "-".
git -C <bare-repo-root> fetch origin <YOUR-INTEGRATION-BRANCH>
git -C <bare-repo-root> worktree add --no-track -b <name> <YOUR-WORKTREE-ROOT>/<folder> origin/<YOUR-INTEGRATION-BRANCH>

# 2. Run the setup step, when the repository has one (the worktree skill's POST_CREATE_CMD)
cd <YOUR-WORKTREE-ROOT>/<folder> && <YOUR-POST-CREATE-CMD>
```

When the repository has a setup step (dependency install, code generation), never skip it in a new worktree: stale or missing dependencies produce confusing failures that look like code bugs. When it has none (`POST_CREATE_CMD` empty, for example vendored dependencies), drop step 2.

---

## Branch Cleanup (Worktree Setup)

**Trigger phrase:** "clean up this branch" or equivalent.

If your repo uses a bare-clone-plus-worktrees layout, cleaning up a branch means removing the worktree directory AND deleting the branch both locally and remotely — three separate operations, easy to do only one of. (The worktree skill does the first two; the remote branch is deleted by your ship step at merge, or by hand as below.)

### 1. Check branch state before touching anything

- Any uncommitted changes?
- Any commits not yet in the base branch (`git log <YOUR-INTEGRATION-BRANCH>..HEAD --oneline`)?
- Is the remote branch already gone?

Safe to delete only if the working tree is clean AND everything is merged, or the user explicitly says they don't care about unmerged work.

### 2. Confirm with the user before executing

State exactly what you found and what you're about to do (remove worktree dir, delete local branch, delete remote branch). Wait for explicit confirmation — this is a destructive operation on work history.

### 3. Execute

With the worktree skill installed, steps 1–3 are its `check` then `remove`: `check` reports the
findings, you show them to the user, and `remove` runs only with their answer. It judges
"merged" by whether the branch is contained in the base branch, and never deletes a branch
that is the only copy of its commits.

```bash
bash .claude/skills/worktree/bin/worktree-remove.sh check  <branch>
bash .claude/skills/worktree/bin/worktree-remove.sh remove <branch> --delete-branch
```

By hand (the fallback), from the bare repo root:

```bash
git -C <bare-repo-root> fetch origin
git -C <bare-repo-root> worktree remove <YOUR-WORKTREE-ROOT>/<folder>
git -C <bare-repo-root> merge-base --is-ancestor <branch> origin/<YOUR-INTEGRATION-BRANCH> \
  && git -C <bare-repo-root> branch -D <branch> \
  && git -C <bare-repo-root> push origin --delete <branch>
```

Both deletes hang on the same test: a branch that is not contained in the base keeps its local and its
remote copy until the user says otherwise.

Plain `worktree remove` refuses a folder with uncommitted files; add `--force` only when the
user has said those files can go. Do not use `git branch -d` as the merged test: its answer
depends on which folder it runs in.

### Subagent worktree cleanup

Agent-isolated worktrees are **not** automatically cleaned up if the agent made any changes, even uncommitted ones. Clean them up at the end of any session that used them, once their results are taken (merged, cherry-picked, or explicitly discarded), without waiting for the user to notice the clutter. **Never by name pattern and never with force:** in a repository shared by several sessions, a pattern such as `worktree-agent*` also matches other sessions' running agents, and a forced remove deletes their uncommitted work. Every candidate goes through the same check, one worktree at a time, and is skipped (its branch too) when any of these holds:

- a process has its working directory inside it (a live session or agent sits there);
- a file in it changed within the last 3 days (someone may be mid-task);
- it has uncommitted changes;
- its HEAD is not contained in the base branch on the remote.

```bash
# For one agent worktree from `git -C <bare-repo-root> worktree list`; repeat per worktree.
WT=<agent-worktree-path>; BASE=origin/<YOUR-INTEGRATION-BRANCH>
git -C <bare-repo-root> fetch -q origin
# Live process inside: /proc on Linux (fast), lsof where there is no /proc (it walks the tree, slower)
if [ -d /proc/self ]; then LIVE=$(for p in /proc/[0-9]*; do readlink "$p/cwd" 2>/dev/null; done | awk -v w="$WT" '$0 == w || index($0, w "/") == 1' | wc -l)
elif command -v lsof >/dev/null; then LIVE=$(lsof +D "$WT" 2>/dev/null | wc -l)
else LIVE=unknown; fi
if   [ "$LIVE" = unknown ];                                     then echo "SKIP $WT: cannot check for live processes"
elif [ "$LIVE" -gt 0 ];                                         then echo "SKIP $WT: a process is inside"
elif [ -n "$(find "$WT" -name .git -prune -o -type f -mtime -3 -print | head -1)" ]; then echo "SKIP $WT: edited in the last 3 days"
elif [ -n "$(git -C "$WT" status --porcelain)" ];              then echo "SKIP $WT: uncommitted changes"
elif ! git -C "$WT" merge-base --is-ancestor HEAD "$BASE";     then echo "SKIP $WT: commits not in $BASE"
else B=$(git -C "$WT" branch --show-current)
     git -C <bare-repo-root> worktree remove "$WT" && { [ -z "$B" ] || git -C <bare-repo-root> branch -D "$B"; }
fi
```

A skip is the answer, not an obstacle: never add `--force` to get past one. Because of the 3-day gate, an agent worktree that just finished stays until a later session's cleanup finds it idle, clean and merged. A squash-merged agent branch is never an ancestor of the base branch, so it always stays; it goes, like any branch, through the worktree skill's check-then-remove with the user's answer. None of this applies to a worktree that holds a task's work.

---

## Cross-System Schema Propagation

**Trigger:** any field, column, or type added, renamed, removed, or retyped in a pipeline that stores the same logical event/record in more than one system (validation layer, message queue, stream processor, analytical store, SDK, external-facing schema).

The failure mode is always the same shape: a change lands in one system and the others silently diverge — data loss, deserialization failure, or a query that returns NULL forever. The fix is a checklist, but the checklist is repo-specific (name every system your pipeline actually touches — validation, transport, processor, store, catalog, SDK, gateway — and what "update" means for each). What transfers is the discipline:

- **Additive first.** New fields get defaults; never rename or drop without an explicit migration plan.
- **Order: consumers before producers.** Update the systems that *read* the schema before the systems that *write* it — otherwise you write data nothing can parse yet.
- **Test the full path, not just the changed hop.** After any schema change, verify producer → transport → processor → store → query returns the new field, end to end, not just that the one file you edited compiles.
- **Removing/renaming a field is a staged operation**, not a single commit: stop writing the old field, keep reading it during a transition window, add the new field in parallel, backfill/migrate historical data if needed, only then remove the old field. Treat each removal as case-by-case — don't automate it away.

---

## Documentation Structure

> **Filled at setup.** If your repo already has a docs layout, this section describes YOUR folders and naming (the onboarding writes it from the survey and shows you the diff); the shape below is only the suggestion for a repo that has none. Either way it states one convention, so a new doc has exactly one right place.

Keep project docs under one root (`DOCS_ROOT`) with a small, stable set of subfolders. Suggested shape — adapt names/depth to your repo:

```
DOCS_ROOT/
├── setup/          — environment & config instructions
├── architecture/    — system design, cross-cutting decisions
├── requirements/     — specs/PRDs, organized by domain + an archive/ for superseded ones
├── testing/          — test guides, QA notes
├── procedures/        — this file and its siblings
├── session-notes/       — session summaries capturing "why," not just "what"
└── archive/            — anything superseded, kept for history
```

**Naming conventions** (adapt, but pick something and stick to it): spec files as `{feature}-spec.md`, changelogs as `{feature}-changelog.md` (or per-PR fragments — see the append-hotspot note under Git Workflow), session summaries as `{topic}-{date}.md`.

**Where new specs go:** a genuinely new domain concept gets its own file; a field/table addition to an existing concept updates the existing spec in place. When unsure which it is, that uncertainty is itself the signal to search all sections referencing the affected concept before writing anything new.

---

## Dev Server Management

### Same-directory policy (read before touching your dev server's port)

The gate for "may I kill / restart / launch a dev server?" is **working-directory match** — not "did I start it," not "is anyone using it."

- **OK, no prompting needed:** kill/restart/launch a server whose working directory equals your current working directory.
- **Never touch** a server running from a different directory — different worktree, different repo, someone else's session. Don't kill it, and don't point tests at it either, even if it happens to occupy the port you want.
- **If you need a server and none is running from your CWD:** just launch one in the background. No permission needed.

```bash
# PID of the process LISTENING on the dev port (empty if nothing is), with an ss fallback
P=$(lsof -iTCP:<DEV_PORT> -sTCP:LISTEN -t 2>/dev/null | head -1)
[ -n "$P" ] || P=$(ss -lntp 2>/dev/null | sed -n 's/.*:<DEV_PORT> .*pid=\([0-9]*\).*/\1/p' | head -1)
# Its working directory: /proc on Linux, lsof where there is no /proc (macOS)
SERVER_CWD=""
[ -n "$P" ] && SERVER_CWD=$(readlink "/proc/$P/cwd" 2>/dev/null || lsof -a -p "$P" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')

if [ -z "$P" ]; then
  echo "nothing listening — launch your own"
elif [ -z "$SERVER_CWD" ]; then
  echo "listening, but its directory is unreadable (another user?) — treat as foreign"
elif [ "$SERVER_CWD" = "$(pwd)" ]; then
  echo "ours — OK to kill/restart"
else
  echo "foreign ($SERVER_CWD) — leave it alone, pick another port"
fi
```

**A bare `lsof -i :<port> -t` must not be used alone.** On some systems (WSL2 among them) it returns nothing while the server is up, which reads as "launch your own" and then fails on an address in use; and without `-sTCP:LISTEN` it can return a *client* connected to the port, so a foreign server passes the gate as yours and you kill it or test against it.

### PID file, scoped per directory

A single global PID file collides across worktrees/checkouts. Scope it:

```bash
PID_FILE="/tmp/devserver-$(pwd | sha1sum | cut -c1-8).pid"
```

### Nuke-and-restart (for a server that IS yours)

```bash
PID_FILE="/tmp/devserver-$(pwd | sha1sum | cut -c1-8).pid"
[ -f "$PID_FILE" ] && kill -9 "$(cat "$PID_FILE")" 2>/dev/null && rm "$PID_FILE"
rm -rf <build-cache-dir>          # corrupted cache is the #1 cause of slow/hung restarts
<DEV_SERVER_CMD> &
echo $! > "$PID_FILE"
```

### Before running tests: target the right server

**The most common local-test failure:** an agent in one worktree runs tests that hit the default port, which is actually a *different* worktree's server — so the tests validate the wrong code and pass or fail for the wrong reason. This is easy to trigger silently because most runners default to the same port, while a couple of test runners quietly default elsewhere.

**Rule: never trust the default port. Before any local test that calls the app:**

1. Decide which server the test targets, and confirm it was launched from your CWD (same check as above).
2. If no server from your CWD exists, launch one — wired to *your* worktree's env/config, not a borrowed one.
3. Point every base-URL env var the test framework reads at that exact port, explicitly — don't rely on the default:

   | Runner type | Env var to set | Notes |
   |---|---|---|
   | In-process / fast test harness | `<HARNESS>_BASE_URL` | Often defaults to a *different* port than your main dev server — check, don't assume. |
   | Full E2E runner (raw) | `<E2E>_BASE_URL` **+ a "runner-managed" flag** | Many E2E configs hardcode their own server-launch/reuse block independent of the base-URL var — setting the URL alone can leave the framework checking/launching a stale hardcoded port. Verify both are wired. |
   | Dedicated E2E runner script | `E2E_PORT` | Cleanest path if you have one — it manages its own server and wires the base-URL var for you. **Use a distinct port per worktree** if the runner reuses purely by port number with no CWD check — two worktrees on the same port hit the exact bug you're avoiding. |
   | Generic API tests | `API_BASE_URL` | |

**Reuse vs. relaunch, and parallel runs in the same folder:** "may I kill/launch" (the CWD gate) and "should I reuse" are different questions.
- A server launched from **your** CWD → reuse it, don't launch a duplicate. A second same-folder server doubles memory for zero isolation — both would point at the same dev database/config anyway.
- **Running tests in parallel in the same folder is fine by design**, and a second server does not make it safer — most test runners already hammer one shared server concurrently. What actually needs to be isolated is *data*, not the HTTP server: unique per-scenario tenant/org IDs, not a second process. Where parallel runs genuinely collide, the fix is unique test entities (or a fresh database branch), never a second server on a different port.

**The silent-reuse trap:** some E2E configs have two independent notions of "where the server is" — one derived from an env var, one hardcoded in the framework's own server-launch block with `reuseExistingServer: true`. If only the env var is set, the framework can silently reuse *whatever's on the hardcoded port*, including a foreign worktree's server, without checking CWD at all. Check both halves of your E2E config before trusting a base-URL override alone.

**Known infra gaps to flag, not silently patch:** if your test runner's server-reuse logic has no CWD check, that's a real gap worth fixing deliberately (with sign-off) rather than working around quietly every time.

### General rules

- Run the dev server backgrounded so the agent isn't blocked.
- If your app is memory-hungry under seed/load, raise the heap/memory limit explicitly at launch rather than discovering the crash later.
- Always record the PID to a per-directory file — only kill what you started for THIS directory.
- Don't debug a stuck dev server — kill and restart, it's faster.
- Clear the build cache after any crash before restarting.
- If the default port is taken by a foreign-directory server and you need your own, launch on a different port rather than killing the foreign one.

---

## PRD Implementation Workflow

**Always follow this for any spec-driven feature. Don't skip steps or combine them.**

### Step 1: Planning

Enter planning mode before writing code or mockups. Break the spec into 3–5 independently testable, independently committable phases. Flag which phases have UI work (they need mockups) and which touch schema (usually early phases). Wait for explicit plan approval before proceeding.

### Step 2: Implementation, per phase

**2a. Mockups first, for any phase with UI work.** Before writing framework code:
1. Ask about mockup structure once, up front: self-contained single-file mockups for one-offs, or shared CSS/JS across a mockup set of 3+ related pages to avoid drift.
2. Build static mockups with realistic sample data (not lorem ipsum), covering empty/loading/populated/error states, and every interactive element at least clickable.
3. Get explicit mockup approval before writing any implementation code — iterating on a mockup is far cheaper than iterating on real UI code.
4. For 3+ related mockups, write a short patterns doc capturing layout/navigation/interaction decisions that aren't obvious from the HTML alone.

**2b. Implementation.** One phase at a time — stop before the next. After each phase report: files changed, what was implemented, known limitations, and a manual testing checklist for the user. Run your full quality gate before calling the phase done.

**2c. Review and commit.** Wait for user review of each phase. Don't proceed to the next phase until the current one is confirmed. Fix issues before committing, not after.

### Testing after implementation

Write real integration tests, not just mocked unit tests, wherever the boundary matters (a real HTTP call, a real browser, a real datastore — not an in-process handler call). Cover three categories, not just the happy path:

**Attacks** — injection via user-controlled input, auth bypass, cross-tenant data access (IDOR), malformed/oversized input, and — for anything billing-adjacent — negative quantities, zero prices, duplicate submissions.

**Edge cases** — zero/empty/null values, boundary conditions (first/last page, min/max limits, exactly-at-threshold), concurrent/racing requests, currency and rounding edge cases, missing optional fields downstream code assumes exist.

**Failure modes** — slow/timing-out dependencies, partial failure mid-transaction (what rolled back, what didn't), retries that could double-write or double-charge, resource limits (cold starts, memory caps, dead-letter scenarios) for async paths.

### Self-review checklist before marking any phase complete

Missing error handling; injection/XSS/auth-bypass surface; unjustified loose typing; edge cases (empty/null/loading states); responsive layout if UI; basic accessibility if UI.

---

## When Deploy or CI Fails

**Don't push fixes blind.** A CI run typically surfaces one infra/permissions error at a time — fixing them one-by-one against a live pipeline wastes hours you'd save by reproducing locally in minutes. **Diagnose locally first, always.**

> **Filled at setup, from `IAC_TOOL` and `CI_PROVIDER`.** Keep the generic steps, rewrite the commands for your tool, keep only the gotcha blocks that match your stack, and delete the infrastructure subsection when `IAC_TOOL` is none. A block for a tool you do not use is noise an agent will act on.

### Infrastructure-as-code failures (`IAC_TOOL`)

1. **Get the right credentials before starting.** Ask the user which profile/role they have for the target environment (`CLOUD_PROFILES`) — don't start debugging without it. Verify it works and refresh it per Tool Discipline → Cloud CLI auth before cloud commands.
2. **Run a local preview against the failing module or stack.** This surfaces every error in one pass instead of one per CI run: `IAC_PLAN_CMD`, against the same state backend (`STATE_BACKENDS`) and the same environment inputs CI uses. Example for Terraform:
   ```bash
   cd <iac-module-dir>
   <YOUR-CLOUD-PROFILE-ENV> terraform init -backend-config="bucket=<YOUR-STATE-BACKEND>" -reconfigure
   <YOUR-CLOUD-PROFILE-ENV> terraform plan -var-file=environments/<env>.tfvars
   ```
3. **If access is denied**, add the missing permission where your deploy identity's permissions are defined (a bootstrap module or stack), deploy that first with admin credentials, then re-run the failing preview.
4. **Check the permission fix before re-triggering CI** — use your provider's policy simulator or access analyzer if it has one, so a guess does not cost another CI cycle. Watch for conditions scoped by resource tags or attributes that the simulator does not load by itself.
5. **Permission gotchas — keep the block for your cloud, delete the rest.**
   - *AWS IAM:* near-duplicate action names cover different resources (an "accelerate config" action is not a "lifecycle config" action) — use the exact action your provider needs; classic event-target integrations need an explicit pass-role grant separate from scheduler-style ones; the simulator's own actions must be granted to the calling role; managed policies have a size cap, so check the serialized size before it silently exceeds the limit.
   - *Other clouds:* add the equivalents you hit (role-binding scope on GCP, data-plane versus control-plane roles on Azure) as you learn them.

### Deploy-time validation failures (handler/artifact mismatches)

If your CI has a job that cross-checks a list of expected handlers/artifacts against what's actually compiled/packaged: diff the expected list (usually declared in a workflow/deploy config file) against what's actually on disk. Anything in the expected list with no matching build artifact gets removed from the list; anything built but missing from the list gets added (or it silently won't deploy).

### Jobs silently skipped when they should run (`CI_PROVIDER`: GitHub Actions; keep the equivalent for yours)

**Cause (GitHub Actions and similar):** skip propagation. When an upstream job is conditionally skipped (e.g., environment-gated), that skip can silently propagate through the dependency graph to jobs that don't have their own explicit "run regardless" guard — even past an intermediate job that protected itself.

**Fix:** any job downstream of a conditionally-skipped job needs its own explicit condition, not an inherited one:
```yaml
if: always() && <your-real-condition> && needs.<upstream-job>.result == 'success'
```

### Deployment ordering for infra bootstrap changes

If the module or stack that defines your deploy identity's permissions changed, apply it before triggering any other infra deploy that depends on the roles/permissions it grants — deploying dependents first just reproduces the same permission error you're trying to fix.

### Reusable-workflow gotchas (`CI_PROVIDER`: GitHub Actions only; delete for another provider)

- Dynamic environment names (`environment: ${{ inputs.environment }}`) inside a reusable workflow job commonly cause a hard startup failure — use inline steps instead of a reusable workflow when the environment name needs to be dynamic.
- Hyphenated job names work fine in `needs.<job>.result` expressions — don't avoid hyphens for that reason.

---

## Git Merge Protocol

> If your integration branch uses a merge queue, note its config and troubleshooting path here (or link to a dedicated doc) — queue behavior (speculative merges, batching windows, force-push ejection) changes what "stuck in queue" means.

**A dirty working tree first.** If there are modified files, commit them first (a WIP commit you can squash later) — merging with a dirty working tree fails with "local changes would be overwritten" and leaves the tree in a half-merged state. Never set them aside with a hand-rolled `git stash`: the stash stack is shared by every worktree and session of the repository, and a bare `pop` can restore someone else's work.

**Clean merges** (no conflicts, no file touched by both sides) — just merge, no planning mode needed.

**Enter planning mode before merging** whenever there's a conflict OR both branches touched the same file — you need to understand intent on both sides to make an informed call, not a coin flip.

### Conflict resolution rules (critical)

**Never blindly accept "ours" or "theirs."** Evaluate every conflicted hunk individually. A single wrong resolution can silently revert a real bug fix — we've had a fix land, then get reverted by a bad merge resolution weeks later, causing a production error rate that took a while to connect back to the original (already-fixed, now-un-fixed) bug.

**For each conflicted file:**
1. Read both versions of every hunk — understand what each side changed and why.
2. **Check what the current branch deliberately did first:** `git log --oneline MERGE_HEAD..HEAD -- <file>`. If there's a recent `fix:`/`revert:` commit touching this file, that side's values are intentional and must survive the merge. We've lost an intentional fix minutes after it was committed because a merge picked the incoming side without checking this.
3. **Then check what the incoming side did:** `git log --oneline HEAD..MERGE_HEAD -- <file>`. If the incoming change is older than a fix already on the current branch, the current branch wins.
4. If a hunk touches a column name, query, or API contract, verify against the *current* schema/API before picking a side.
5. If genuinely unsure — stop and ask. A delayed merge beats a silent regression.

**Never use, for application code:** whole-file `--theirs`/`--ours`, a merge tool's "accept all" on a multi-hunk file, or resolving by deleting one side without understanding both.

**After resolution, audit the result:** for every file that had conflicts, diff the merge result against the merge-base and confirm changes from *both* branches are present — not just the one that "won" the auto-resolution.

### Rebase conflict inside your ship/checkpoint flow

When the rebase step of your ship or checkpoint flow stops on a conflict, finish the rebase rather than restarting:

1. Resolve each conflicted hunk with the rules above — never a whole-file `--ours`/`--theirs`. (During a rebase the sides are swapped: "ours" is the base you are rebasing onto, "theirs" is your commit.)
2. Stage each resolved file (`git add <file>`) and continue through the flow's own continue command, not a raw one: a scripted ship flow has its own (for example a `--continue` on its sync script, which also prints how to drop an autostash entry and clears its in-progress state); a by-hand flow such as checkpoint uses `git rebase --continue`. Repeat for every commit that stops.
3. Resume the flow where its own status says it stopped (a scripted flow usually has a status command that prints the next step; a fresh start can discard work already in progress). A by-hand flow re-runs its sync step. It records its own lease and pushes with it; never push the rebased branch with a hand-run force push, which skips that pinned lease and can overwrite someone else's commits.

Abort (`git rebase --abort`) only when resolution is genuinely impossible — you cannot tell which side is right and the user is not there to ask — and say so; an abort while a resolution was possible just moves the same conflict to the next run.

### The wrong-merge-base trap (a real, repeatable gotcha)

**Symptom:** a merge reports suspiciously few conflicts despite a stat diff showing hundreds of files differ. The merge silently "preserves" code the incoming branch actually deleted.

**Root cause:** if a prior bad merge and its revert both sit in your branch's history, Git's merge-base computation can pick the bad-merge commit as the most recent common ancestor — which pulls the effective ancestor *forward*, past the incoming branch's real deletions. From that wrong vantage point your branch looks like it *added* code the other side actually removed, so the merge keeps it.

**Diagnose:** compare the actual merge-base against the point you know the branches genuinely diverged. If they differ, and there's a bad-merge-then-revert pair in the log between them, you've hit this.

**Fix (destructive — requires explicit sign-off):** reset past the bad-merge commit to before it happened, then re-merge cleanly. We've burned real hours writing an elaborate manual-deletion plan before realizing the merge itself just had the wrong ancestor — the fix was one reset, not a 35-site hand edit.

### Pre-merge planning for conflicted merges

- List files touched on both sides (`comm -12` of two sorted name-only diffs) and read both diffs for each, looking for semantic conflicts a text-level merge can't see (e.g., one side renames a column, the other adds a new query using the old name).
- Check for numbering conflicts in anything sequentially numbered (migrations, ordered configs).
- Note any structural/architectural changes on either side (route reshuffles, module moves) — these are exactly what makes "clean, no conflicts" misleading (see below).

### Post-merge verification

Always check: no duplicate sequence numbers, full quality gate green, and — for every file touched on both sides — a spot check that both sides' changes actually survived.

**Red flags:** "no conflicts" on a large structural merge (often means two sides put equivalent logic at *different paths*, so Git sees no textual overlap even though the app can only route to one); files that show as wholesale "deleted" or "new" instead of "modified" when you know they were actively worked on; anything sequentially numbered colliding.

### Filesystem case-collision in a repo template file (platform-specific gotcha)

**Symptom:** every merge aborts with "local changes would be overwritten," even after checkout/stash, on a file you never touched.

**Root cause:** on case-insensitive filesystems (common on macOS), a repo can accumulate two index entries that only differ by case — a canonical uppercase name and a legacy lowercase duplicate. Only one file exists on disk; Git thinks it's tracking two, and the on-disk content can't match both blob SHAs simultaneously — so it looks permanently "modified."

**Detect:** `git ls-files -s <path> | grep -i <filename>` — two entries with different blob SHAs is the signature.

**Fix:** drop the duplicate from the index, force the disk content to match the canonical entry, re-add, commit. `stash`/`checkout` will not clear this — it's an index-level duplicate, not a working-tree change.

### Rogue local branch shadowing a remote-tracking ref (gotcha)

**Symptom:** `git merge origin/<branch>` reports "already up to date" or completes silently, but a stat diff against the actual remote shows hundreds of files differ. The resulting push opens a PR flagged as conflicting.

**Root cause:** a local branch literally named `origin/<branch>` exists (usually created by an old typo like checking out `-b origin/<branch>` instead of tracking it). Git's ref disambiguation prefers the local branch of that name over the real remote-tracking ref — so `git merge origin/<branch>` silently merges against a stale local snapshot instead of current upstream.

**Detect:** `git for-each-ref --format='%(refname) %(objectname)' | grep <branch>` — if you see both `refs/heads/origin/<branch>` and `refs/remotes/origin/<branch>` at *different* SHAs, you've hit this.

**Workaround (non-destructive):** always merge via the explicit remote-tracking path: `git merge refs/remotes/origin/<branch>`.

**Fix (destructive, needs sign-off):** delete the rogue local branch; subsequent `git merge origin/<branch>` then resolves correctly.

---

## Git Workflow Details

**Standard flow:** branch off the base branch → commit → push → open a PR targeting the base branch (not straight to production) → review → merge → delete the branch. Direct commits to the base branch are fine for trivial fixes/docs; feature branches are preferred for anything reviewable.

**Multiple PRs from one branch:** a merged PR does not block opening a new PR from the same branch. New commits on an already-merged-once branch just need a push and a new PR — don't create a fresh branch and cherry-pick, that's wasted motion.

**Uncommitted files rule:** status-check before every commit and ask which files belong; status-check again after every commit; never claim "everything committed" while the status check disagrees; list anything left over explicitly.

**Branch merge rules:** never merge your production branch into your integration branch without explicit sign-off — the flow is one-directional (feature → integration → staging → production). If production has a hotfix the integration branch needs, ask first and prefer cherry-picking the specific commit over a full branch merge.

**Changelog append-hotspot (if you use one flat CHANGELOG.md):** every concurrent PR that appends to the same anchor line in one file conflicts with every other PR doing the same thing — and a merge queue typically won't honor a custom union merge driver, so it ejects them even when a local merge would succeed. Use per-PR changelog fragment files instead, compiled at release time.

---

## Test Thoroughness Gate

Self-attestation ("the tests I ran are enough") is the failure mode that ships critical-path code
with zero tests. The gate is mechanical:

- **Trigger:** any diff that touches your critical-path globs (API routes, core business logic,
  auth, database handlers, migrations; define the list for your repo, and keep it in one place
  your ship and review skills both read).
- **Required action:** dispatch a dedicated test-engineer subagent with no scoping prompt beyond
  the diff. It audits coverage and decides scope itself. The orchestrator never decides what is
  "small enough to skip".
- **Override:** only the user, typing an explicit override phrase with a reason. Log the bypass
  somewhere durable (the PR body, a findings log).
- **Sentinel:** the test pass writes a sentinel file that your ship/checkpoint flow checks. Hash it
  against the diff's own changed paths, not the whole tree, so an unrelated advance of the base
  branch does not force a re-run while any edit to the branch's own critical files invalidates it.
  If the hash cannot be computed, HALT; never pass silently.

---

## Subagent Orchestration

### When to delegate vs. stay inline

Delegate when tasks are genuinely independent (different files/systems), well-scoped enough to hand off with a clear contract, or when protecting the parent's context from a large output matters. Stay inline when the task is quick, needs iterative judgment, or the handoff overhead exceeds the benefit.

**Structuring a handoff:** give the subagent the relevant plan excerpt (don't make it rediscover context), the specific file paths and existing patterns to follow, explicit constraints on what NOT to touch, and a clear definition of done.

**Dependent tasks are sequential, not parallel.** Map dependencies before dispatch; only the genuinely independent branches parallelize.

**Validate before integrating.** Never trust subagent output blindly — run your quality gate on the result and review the diff before treating it as done. You run the gate **once, after all the agents land**; the workers do not each run it (see Local-execution briefing below). A subagent that silently produces wrong output is worse than one that fails loudly.

### Local-execution briefing

Every prompt for an agent that can run commands carries this block, filled in for the task: implementers, fixers, test writers, reviewers, investigators, forks and follow-up messages to a live agent alike. "The rules file already says so" does not count; the block goes in the prompt, and a prompt without it is a dispatch defect.

```
LOCAL EXECUTION. Other agents and sessions share this machine.
ALLOWED locally (exact commands, nothing else):
- the linter on the files you touched: <exact command>
- read-only git and grep
- <task-specific, one exact command per line, e.g. one test file named by path, or "nothing else">
FORBIDDEN locally, even once, even "just to check":
- any whole-project typecheck
- any multi-file test run (a directory, a "related tests" mode, the whole suite, end-to-end, integration tiers)
- builds, dependency installs, whole-tree lint or format runs (they rewrite every file)
- the quality-gate steps of a review skill, if you run one on your own work
- any run you would have to wait on for more than ~5 minutes: write the exact command in your result instead
VERIFICATION: <who runs what, and when, e.g. "I run the full gate once, after every agent lands">
Anything not on ALLOWED is FORBIDDEN. If you believe you need a forbidden command, do not run it:
put the exact command and the reason in your result.
```

- **Default-deny.** ALLOWED holds exact commands, never categories: "run the tests for your change" reads as a whole suite. Name each file.
- **Widen ALLOWED for one agent only, and only when no sibling is running the same thing** (a lone agent may get a scoped typecheck). N siblings never each get a typecheck: you run one after they land.
- **Named and generated agents get the block too;** their own protocol does not replace it, and the block wins where the two conflict. An agent that receives no block runs nothing heavier than its own files' lint and one named test file at a time, says the block was missing, and lists the commands it would have run.
- **Why:** with no count cap on workers, every implementer runs the obvious whole-project typecheck and test suite at the same moment. Several heavy typechecks at once can push a shared machine into swap for every session on it, and "run the related tests" has executed thousands of test files per agent.

### Checking a worker's result

Before treating a worker's "Done" as completion:

- **Did it finish, or was it stopped?** A worker cut off at its tool-use cap reports "Done" exactly like one that finished. Check that it ended on its own (its transcript's last message is a final answer, not a tool call or tool result, where your harness keeps transcripts), that its completion marker is the last line of its result file, and that the assigned work is actually all there. A missing closing line means the result is partial: re-dispatch the remainder.
- **Grep the identifiers it claims to have created** (functions, files, tests, config keys). An invented one is a fabricated result.
- **"Should pass" is not a run.** Anything reported as "should pass" or "will work" is re-run (by you, in the one gate after the agents land) before it counts.
- **Challenge red-flag phrases:** "mostly done", "the rest is similar", "left as a follow-up", "couldn't verify", "pre-existing". Each is a question back to the worker or a check you run, never a pass.
- **Pick the right fix for a failed worker.** Capped mid-work (stopped at a phase boundary, work incomplete) → split its scope, same tier; a bigger model hits the same cap. Incoherent (contradicts itself, trails off mid-sentence, lost the thread after compaction) → a stronger tier or a split, never a same-tier resume, which inherits the damage. Budget roughly 3 tool uses per file edited and keep one dispatch to about 25 file-edit cycles; bundling several phases into one worker reliably hits the cap before the tests.
- **Merge several workers' results smallest first,** checking between merges, never all at once.

### Foreground vs. background dispatch

- **Foreground** (wait for the return): use when the result changes what you dispatch next — validation, classification, plan review.
- **Background** (continue while it runs): use when completion unblocks the next phase but doesn't inform it — parallel implementation streams, independent reviewers on one diff, isolated worktree work.

If dispatching a subagent while you also have 2+ independent things to do, background it — a foreground subagent plus an idle parent wastes wall time for zero savings. Exception: if you already fired several agents in parallel in the same turn, waiting on that batch is fine.

For long subagent deliverables, ask for a short summary in the response with detail written to a scratch file — lets the parent grep instead of swallowing a large dump.

Tool-use caps tend to run lower for background dispatch than foreground (observed roughly half, in our environment — calibrate for yours). For scope beyond that ceiling, prefer foreground or split into multiple background agents at phase boundaries rather than one oversized background agent that silently truncates mid-task.

### Subagent scope boundary — subagents stop at the artifact, not the integration

A subagent's job ends at producing the file/diff/review the parent asked for. **Commits, pushes, PR creation, and CI watching belong to the parent — never the subagent.** This is a hard rule.

We've had a subagent hang for real wall-clock time after correctly finishing its actual task, because it then tried to push its own commit and stalled on a permission prompt for a command that wasn't in its tool allowlist — the parent had to notice and kill it manually. Multiple near-misses share this exact shape: the agent's instinct after finishing is to "take it to completion," and that instinct is the hang.

**Forbidden for every subagent, regardless of type or how permissive its tool access is:**

| Forbidden | Why |
|---|---|
| Committing | Parent decides message and timing |
| Pushing | Parent owns the push |
| Creating/editing the PR | Parent's job |
| Watching CI (`--watch` or equivalent) | Polling CI can hang the agent indefinitely |
| Re-triggering CI | Subagent doesn't own remediation |
| Running the full pre-merge validation skill/pipeline | Long-running, belongs to the parent |
| Any foreground long build/apply | Multi-minute hangs unrelated to the subagent's actual artifact |
| Anything with `--watch`/`tail -f`/an interactive prompt | Blocks the turn forever |
| Any command that needs a permission prompt the agent can't auto-approve | Waits on a human who isn't coming |
| Starting a run it would have to wait on for more than ~5 minutes (a long test tier, a remote dispatch, a deploy) | It burns its cap waiting, and a run started by a worker that then ends keeps going unobserved; it returns the exact command and the orchestrator runs it in the background, where its exit is the wake |

**Clean termination protocol:** write the result file **early** and update it as you go, so a turn cap loses nothing; end it with a completion marker as its last non-empty line, written last (`DONE: <artifact> | <status>`; if you edit the file after, re-append the marker). The parent can then tell done from in-progress without reading the transcript. Return a one-line summary plus any task-specific output, and end the turn. Don't offer to push or ask "should I open the PR?" — that's the parent's decision by design.

**Parent-side complement — verify before takeover.** If a subagent goes quiet with no completion message, check for its effects before assuming it's dead: the completion marker, the expected branch state (`git fetch` + `git log <branch> -1`), whether the file/diff actually landed. If the work is done, mark it complete — don't spin up a replacement to redo work that already shipped; that's the second most common waste pattern after the hang itself.

**Parent-side CI watching must be bounded too.** The same "unbounded watch hangs forever" hazard applies one level up — see the bounded-wait pattern under Tool Discipline below.

---

## Token-Efficient Orchestration

For any plan with 2+ independent work streams or 3+ phases, include an explicit orchestration note: chosen budget mode, what's offloaded to a cheap model, when context gets compacted, and the dispatch plan.

### Budget modes

Don't ask. Use the default, **Parallel** (or the default your onboarding configured), and state it in the plan ("token budget: Parallel — default"). Max Parallel, the loosest and most expensive mode, is opt-in only, when the user asks for it. Only the user moves the mode, either way, and it holds until they move it again.

For a genuinely single-phase, no-parallel-streams plan, don't silently default to "no subagents" either — default to Parallel unless the work is truly sequential (each step depends on the prior step's output). "This task feels small" is not the same as "this task has zero parallelizable work."

#### Named disjoint work unit

A **named disjoint work unit** is a specific, file-scoped task you can state in one sentence *before dispatching anything*. All three properties must hold:

1. **Named** — you can say what it's doing ("update the schema in `X`," "add logging to handler `Y`"), not "the next chunk" or "whatever comes back."
2. **Disjoint** — its file/infra footprint doesn't overlap any other concurrently-running unit. Two units editing the same file are not disjoint; two units only reading the same file are fine.
3. **Pre-dispatch** — enumerated before the parallel fan-out, not discovered mid-run. If you need a recon pass to *find* the units, run that first — you don't have named units yet.

This definition anchors the uncapped default below, cheap-model offload, and the idle-audit / concurrency-saturation rules further down — treat "named disjoint work units" the same way everywhere it's used, don't reinterpret it loosely per section.

| Mode | Default action | Stay inline only when... |
|---|---|---|
| **Frugal** | Inline by default; serialize any subagent dispatch. Aggressive, unbounded offload to a cheap/fast model (spawn cost there is low). For the rare heavier-model spawn: 0–1 concurrent, reuse a live agent over respawning, hard output caps. | (every heavier-model spawn needs its own justification) |
| **Parallel** (default) | **No count cap, but budget-conscious.** Every named disjoint work unit gets dispatched: a ceiling of 3 on 7 units only serializes the same spend, it saves nothing. But each worker has a fixed cost (its start-up context plus everything it must read), so **split only while a worker saves more than it costs**: units that read the same context go to **one** worker (three edits in one module = one worker, not three); a unit smaller than a worker's start-up cost (one or two quick edits or reads) stays inline; mechanical units with the code in the prompt go to the cheap model; reuse a live agent whose task overlaps before spawning fresh. Soft hints for how many workers run at once, not caps: about 4 mechanical and 3 standard (critical work is not a hint: see below the table), and judgment work (architecture, plan synthesis, integrating several streams, hard debugging) stays in the main session. Opt into a hard ceiling (`parallel --cap=N`) when integration overhead matters more than wall time, or when units aren't fully nameable up front. | Single file, single item, a unit smaller than a worker's start-up cost, or work where step N's output feeds step N+1. |
| **Max Parallel** | Always dispatch in parallel when work is independent. Same uncapped-by-named-units default as Parallel, without its merge and stay-inline rules: per-spawn token cost, speculative spawns and redundant verification are accepted costs for wall time. | Work is genuinely sequential. |

A rule-of-thumb amortization threshold ("fewer than ~15 turns of work → just do it inline") applies to Frugal mode. Parallel weighs each worker's fixed cost against what it saves, unit by unit, as above, but per batch through the pre-flight below, never per edit; only Max Parallel treats that cost as accepted and does not re-litigate it.

**Critical work runs one at a time, in every mode.** Work on the code your domain invariant names, on security or authentication, on an architectural change, on a halting gate or on a protected file gets one worker at a time, a fresh one, with nothing else critical in flight. Ordinary work in a critical-path folder (a route, a handler) is not critical by location alone. No mode's "no count cap" lifts this: critical streams integrate badly in parallel, and a wrong merge there is the expensive failure.

**Frugal: what justifies a mid-tier worker.** Spend tokens for wall time when someone is waiting for the result or the step is on the critical path (everything else waits for it); save them when the work runs unattended, the session's context is already large, or four or more workers would be involved. A Frugal parallel dispatch also needs non-overlapping files, no step feeding another, enough work per worker to cover its start-up cost, and a return-size cap in every prompt.

### Implementation pre-flight

Before the first edit of an approved plan or any substantial change (Parallel and Max Parallel; in Frugal the same count decides what is worth one serialized worker):

1. **Count first.** A quick `git grep` / file listing: how many files, how many call sites. It takes seconds and is the step that stops drift.
2. **Partition per batch, never per edit.**

   | Scope | Partition |
   |---|---|
   | up to ~5 files, mechanical | inline |
   | ~6–25 files, mechanical | one worker, the exact change in its prompt |
   | 25+ files, or fewer with cross-file reasoning | 2+ workers at logical boundaries |
   | mixed | mechanical batches to workers; the files that need your judgment stay inline |

3. **Dispatch before doing your inline share,** then work on it while the workers run. Inline first and dispatch after gives serial wall time and defeats the partition.
4. **Inline is for files that need your judgment.** "I might as well do it" is not a reason.

Why: "this edit is small" is true of every edit, so a per-edit check approves each one and a hundred small edits become hours of inline work that two or three workers would have finished in minutes. The opposite failure is one worker per tiny unit; the partition prevents both.

### Dispatch prompt and result discipline

These cost nothing in wall time and save tokens in every mode:

- **One agent per shared context.** Calls that read the same context (the same PR, issue or files) are one agent, not three. Agents score their own findings against a rubric in their prompt instead of a second wave of scoring agents. Don't re-check what a passed check already established unless state changed in between.
- **Fill a worker's batch** before dispatching: about 5 mechanical items, 3 standard, 1–2 critical per worker (items per worker, not the at-once hints in the table). Dispatch a partial batch at once only when the next item is on the critical path.
- **Every prompt carries a token-discipline block:** grep before read and read with offset/limit, Edit (never Write) for existing files, filter long command output before it returns.
- **Every prompt sets an output contract:** structured, no restating the task, a few hundred tokens at most, detail written to a file. In a parallel wave this is the return-size cap: N returns land in your context at once.
- **Compress after a wave:** keep one line per file changed, decision and issue in context, and the full record on disk.
- **Review waves get the diff in the prompt.** You already have it; N reviewers each re-reading the same files is the largest per-wave multiplier. A small changed file goes in whole; a larger one gets its hunks plus an instruction to read only the lines around each hunk.
- **The plan's orchestration note ends with a budget check:** when a small plan (fewer than 2 independent streams and fewer than 3 phases) is set to Max Parallel, say in one line that a cheaper mode would be about as fast. The user still decides.

### Sizing a dispatch

- **Omnibus scope truncates.** "Wire 30 routes" or "fix 9 tests" as one agent task stops
  mid-work. Split before dispatch: 5–10 files per agent, with explicit line ranges where agents
  share a file. A large codemod (50+ sites) is an omnibus even though it reads as one transform:
  run the transform script directly, or cap each apply agent at a bounded file count, and never
  combine dry-run and apply in one agent's budget.
- **Multi-bug workstreams.** With 3+ distinct fixable bugs, one agent per bug with the fix recipe
  in the prompt (file:line and what to change). One agent for everything is cheapest at two bugs
  or fewer and the most expensive failure at four or more: it spends its budget on per-bug
  investigate-verify-decide loops, runs out of tool calls, and produces nothing.
- **Failing tests: parallel from the start.** With 2+ failures in a suite, one focused debugger
  per failing test, each with a bounded fix-or-skip budget.
- **Permissions.** An agent told to implement something and run the tests needs full
  permissions: without them it stops at the first command not on the allowlist, and a stalled
  background agent sends no output and no completion until it dies. A mode that only
  auto-approves file edits does not cover the shell. Full permissions never lift the rules (no
  commits, PRs, infrastructure changes or protected files); read-only agents stay at the default.

### Baseline optimizations

These apply regardless of mode — effectively free, just discipline.

- Grep before Read — find line numbers first, then Read with `offset`/`limit`.
- Batch every independent read/grep/lookup into one turn — sequential single-purpose lookups are the largest avoidable wall-time cost in analysis-heavy sessions.
- Don't re-read a file already read this session unless it changed.
- Search for the specific pattern first; don't scan broadly and filter after.
- Truncate verbose command output automatically (see Context Optimization Hooks below) rather than reading it all into context.

### Cheap-model offload

Applies in every mode. Before dispatching a heavier-model agent, pull out anything within its scope that needs no semantic judgment and route it to your cheapest capable model instead.

**Cheap-model-appropriate (pure lookup, no interpretation):**
File/symbol existence checks; glob/grep searches (finding, not evaluating); reading config or history for pure factual data ("list the variables in this file," not "is this config wrong?"); line counts, line-number lookups.

**Needs a stronger model:**
Judging whether a bug is real; code review (pattern/correctness/edge-case judgment); root-causing a test failure; classifying a finding as real vs. false-positive; architectural or design decisions.

**When in doubt, use the stronger model.** Correctness beats token savings every time this is close.

**Spawn threshold:** every agent launch pays a fixed cost (its own system prompt + tool init, roughly 5–10K tokens, independent of how long the parent session has run). For truly trivial work — one grep, a ten-line single-file edit — just do it inline; the spawn overhead isn't worth it. Only offload once the task justifies that fixed cost (reading/validating several files, a batch of searches, parallel lookups across modules). This threshold is about avoiding overhead on genuinely trivial work — it is **not** license to inline a batch that already meets the Parallel-mode dispatch trigger (2+ independent files, 3+ items, or a mechanical batch of 2+ similar edits) just because each individual edit is short: size is judged per batch, by the Implementation pre-flight above.

**Mechanical edits go to the cheapest tier only with the exact change in the prompt** (file, location, the code to write). A mechanical edit the agent must explore to find goes to the mid tier. A cheapest-tier agent that has to explore at all carries this clause in its prompt: "If anything is more complex than described (the file doesn't match, the logic is non-obvious, the change touches more than specified), stop and report back; do not proceed." A cheapest-tier reviewer flags instead of stopping. Never the strongest tier for routine or mechanical workers.

### Reuse-first dispatch

Applies in every mode, and only to heavier-model workers (cheap-model dispatch is unbounded — see above). The cheapest heavier-model worker is the one you don't spawn. A long-lived worker handling a run of follow-ups is meaningfully cheaper than repeated fresh spawns, because a live worker's context is cache-read (cheap) while a fresh spawn's cold-start (system prompt + tool init) is a full write every time.

**Before spawning a new heavier-model worker, check live agents:**
1. If a live one's task family overlaps the new work → send it the follow-up instead of spawning.
2. Spawn fresh only when: no live worker exists, OR the live one's accumulated context is dead weight for this genuinely unrelated task, OR the new task must run *concurrently* with the live worker's current task, OR the live worker's context is already large enough that piling on more risks truncation.

**Reuse is for follow-ups, not for sequencing batches.** Separate batches of substantive work (say, 3 batches of 10 files) go to parallel fresh workers, not one after another to the same live worker: reuse saves one start-up cost per batch but serializes the wall time and piles up cap and compaction risk by the second or third batch. Spawning is cheap; recovering from a truncated worker is not.

**Routing and lifecycle:** group related follow-ups onto the same worker that already has the relevant context loaded. Batch 3+ related tasks into one handoff rather than drip-feeding one at a time. Retire a worker once its task family is exhausted — don't keep it alive idling. Restart fresh once a worker's accumulated context is mostly dead weight for what's next (rough guide: tens of thousands of tokens of unrelated history) — the cache-read tax on a stale, irrelevant prefix is its own cost.

**Reserve the strongest model for judgment work that stays in the main session** — architectural decisions, plan synthesis, multi-stream integration, complex debugging. Delegate what's parallelizable, well-scoped, or context-bloating; keep what needs continuous judgment.

### Idle audit

Applies in every mode. Whenever you're about to wait ≥30s (a long build/test/typecheck, an IaC plan, a subagent dispatch, a pending user question), run **one** pass: is there planned, already-known forward-progress work that's independent of this wait?

**Trigger threshold:** treat any long build/test/lint/install, IaC plan/apply, large network-bound call, or subagent dispatch as ≥30s by default — no need to estimate. Skip the audit for anything clearly <10s. The 10–30s range is judgment — only audit if a candidate is *already* on your backlog, don't go fishing for one.

**Audit cap:** one pass, effectively free, no nesting, no scope generation, no repo scan for "something to do." The question is "is there a candidate I already know about," never "let me go look for one."

**Quality boundary — all three must hold for a candidate to be safe:**
1. **Inputs fixed** — the candidate's required inputs are already known; the in-flight work's return won't change them.
2. **Outputs not consumed** — the in-flight work won't read the candidate's outputs.
3. **Footprint disjoint** — no file/infra overlap with the in-flight work. If you can't verify the in-flight scope, treat it as overlapping.

For a pending user-question wait specifically: the candidate's premise must not depend on the answer.

**Always-safe:** reading files for the next phase, grep/scope enumeration for downstream work, drafting (never committing) messages/docs for already-shipped work, writing tests for already-specified code, dispatching on a verifiably non-overlapping file set within the mode's concurrency bound.

**Never-safe:** editing files the in-flight work might touch; work whose design the in-flight output gates; work whose premise depends on a pending answer; polling the in-flight task itself; speculative work outside the plan.

**Resource contention:** if the in-flight work is CPU/IO-heavy on the same host, prefer non-CPU candidates (reads, drafts) over kicking off another build/test that competes for the same resources.

**Per-mode intensity** (counting only heavier-model spawns triggered by the audit — cheap-model spawns are unbounded in every mode): Frugal spawns zero new heavier-model workers from the audit alone (bias to reads/drafts/reuse). Parallel and Max Parallel are bounded by named disjoint work units still unstarted in the plan — never invent new units during the audit, only pull forward what's already planned.

### Concurrency saturation

Applies only in the uncapped/parallel-style modes (not the serialize-by-default mode). The active companion to Idle Audit. Idle Audit is defensive and fires once per wait; Concurrency Saturation is active and fires at **every** completion notification while parallel work is still in flight — it re-checks and dispatches more if there's headroom, rather than waiting for the whole batch to finish before considering more.

**Why it matters:** "bounded by named disjoint work units, not a number" means sitting at, say, 6 of 10 possible slots in flight when 4 more named units exist is a violation of that definition, not a conservative default. The failure this rule targets: dispatching a batch of N and then waiting for all N before considering more, even when cap headroom exists and more named units remain.

**On every completion notification, with ≥1 unit still in flight, walk three gates before doing anything else:**
1. Named disjoint work units still unstarted? (from the plan, never invented on the spot)
2. Cap headroom? (in-flight count below your ceiling, if one is set)
3. Net token usage doesn't grow? (dispatching now vs. later is the same total work, just compressed in wall time — spawning something that wasn't already planned fails this gate, because that's invention, not saturation)

If all three pass, dispatch immediately in the same response — don't defer to "next turn" or wait for a prompt. If any gate fails, do nothing. Two brakes still apply to a refill: **reuse first** (send the unit to a finished or idle worker whose task family matches before spawning a new one), and **resource contention** (don't add CPU-heavy work while CPU-heavy work is running on the same machine; refill with reads and drafts instead). Asking the user "should I dispatch more?" is the anti-pattern this rule exists to remove.

**Frugal mode is exempt** — it serializes by design.

---

## Post-Compact Agent Dispatch

Compacting reduces *your own* context, not a subagent's — a freshly spawned subagent never inherits parent context regardless of when it's spawned, so spawn timing relative to a compact doesn't change subagent cost. What compacting *does* help: your own per-turn cost afterward, so run it at a natural phase boundary when your own context is heavy, not as a subagent-cost trick.

---

## Post-Compaction Recovery

After any compaction (manual or automatic), **read the summary and act on it** — that's what it's for.

1. **Summary describes active work + clear next step** → resume immediately. Don't re-read old transcripts, don't ask "should I continue," don't re-verify what the summary already told you.
2. **Summary describes completed work, nothing pending** → report completion, ask what's next.
3. **Summary is genuinely ambiguous** (unresolved discussion, conflicting signals) → ask one focused question to unblock.

The failure mode this prevents: stopping to "verify context" after every compaction even when the summary clearly states the next step — that kills momentum and forces the user to repeat themselves.

**Still never, regardless of what the summary says:** commit or push autonomously, take any destructive action based on the summary alone, or discard the summary and start over as if it's a new conversation.

**What to preserve when compacting:** architectural decisions and their rationale, key open decisions from any spec docs in flight, file paths created/modified, completed vs. pending work, current blockers.

---

## Context Optimization Hooks

A small set of hooks reduces context waste mechanically rather than relying on the agent to self-regulate. Describe these as patterns and reproduce them for your own harness — the exact filenames don't matter, the shapes do.

**1. Output truncator.** A small utility that, given verbose stdin, keeps a head slice + tail slice with a summarized gap in between once output exceeds a configurable line threshold. Used by the next hook, and directly by anything else that wants to cap its own output.

**2. Bash-output truncation (PreToolUse hook on the shell tool).** Intercepts commands matching known-verbose patterns (package installs, framework builds, IaC plan/apply, container builds) and rewrites them to pipe through the truncator before the output reaches context. Skips backgrounded commands. Preserves the command's own exit code (captured from the pipeline's status array, see Capture the real exit code) so truncation never masks a failure.

**Measuring token use is not a hook's job.** Your harness already writes a transcript of every session with each tool result exactly as it entered the conversation; measure from that, or from a usage-telemetry tool that reads it. A per-call hook only sees the raw tool response, which can be far larger than what reached the context (an edit tool's response may carry the whole original file), so its totals mislead.

**3. Read-once enforcement (PreToolUse hook on the read tool).** Blocks or warns on re-reading a file within a TTL window if its mtime hasn't changed since the last read in this session. Forces "reference your prior read" instead of "re-fetch and re-pay the token cost."

**The installed pack.** The HumanMaxxing hooks pack (the download's `hooks/` folder) holds three
hooks, installed into `.claude/hooks/` by `hooks/bin/hooks-install.sh`: the protected-file guard
(for any change to a file in `.claude/protected-files.txt`, the hook settings files or the hooks
folder), the commit check (for a commit while `COMMIT_CHECK_CMD` in `.claude/hooks/hooks.env`
fails) and the pending-question reprint (a hook that shows the question still waiting for an
answer again; see Pending Questions). The guard and the commit check are installed in warn-only
mode (`--mode warn`): they print what they found and let the action through. Switching them to
blocking (the guard asks for the user's approval, the commit check refuses the commit) is
`hooks-install.sh --mode enforce`, a separate decision the team takes later. When the hooks were
declined at install, none of them is installed: install them later the same way as "Recreation"
below. The scripts hold no values of this repository; `hooks.env`, the protected list and the
settings file's `hooks` block do. `hooks-check.sh` beside them is the session-start
check, for the pack's scripts only. The output truncator and read-once enforcement above are
patterns, not part of the pack.

**Registration:** wire these into your harness's PreToolUse/PostToolUse hook config, matched on the relevant tool names. Keep the matcher scoped (e.g., only the shell tool for output truncation, only the read tool for read-once) so the hooks don't fire on unrelated tool calls.

**Recreation:** if `hooks-check.sh` fails or a pack script goes missing, reinstall from the download (`hooks/bin/hooks-install.sh plan`, then `apply` once the user approves that plan) rather than reconstructing it from memory. For a hook of your own, treat the script as self-documenting (comments should explain every config var) and recreate it from a known-good copy.

**Progressive skill/command loading:** if your harness supports it, default new internal-only commands to hidden-from-the-top-level-list (still callable, just not advertised) unless they're meant to be user-invoked directly — keeps the visible surface small without losing functionality.

---

## Schema and Batching Discipline

**Why this matters:** we once burned a 77-minute session where roughly two-thirds of the wall time was "answer from training-data memory → get corrected → re-read the schema → re-answer," with the same baseline schema file read or grepped over a dozen times across sequential turns and zero parallel tool calls used in over 80 turns. A single concept alone triggered seven sequential single-pattern greps before the relevant function was found. The fix is boring: read once, up front, in parallel.

### Front-load reads by session type

At the start of any analysis or design session, fire one parallel batch of the files relevant to the topic — don't wait for a question to force each read one at a time. Examples (adapt to your repo): a data-model session front-loads the baseline schema file(s); an API session front-loads the API spec plus the touched route and its siblings; an SDK session front-loads the core client file per language. Add one or two domain-specific files based on the actual topic — don't read everything, read what the session is about, once.

### Batching examples

**Bad — sequential, N round trips:**
```
Grep("concept") → wait → Grep("concept_alt_name") → wait → Grep("relatedFunction") → wait
```

**Good — one parallel turn:**
```
Grep("concept|concept_alt_name|related_field|relatedFunction", path="lib/")
```

Independent lookups go in one turn; only serialize when pattern N genuinely depends on pattern N-1's result.

### Correction handling protocol

When the user corrects a factual claim ("isn't that what X does?" / "we actually have Y" / "double check that"):

1. Check whether you actually read the file that would confirm/refute this, in *this* session.
2. If not read yet — read it, then answer. Don't just re-answer from corrected memory; that's still a memory answer, only nudged in a new direction.
3. If already read — your prior read missed something or you misread it. Re-examine what's already in context; don't blindly re-fetch.
4. Acknowledge the gap explicitly ("you're right, I was answering from memory — let me check"), then verify, then answer.

The failure mode this prevents: a correction loop where each round trip costs a full turn and produces a slightly-different-but-still-wrong answer.

---

## Browser Tooling and UI Validation

### The cost asymmetry

| Approach | Per-action cost | Use for |
|---|---|---|
| Interactive browser tool (screenshot + click loop) | High — tens of thousands of tokens per screenshot | Live-state debugging, genuine interactive exploration |
| DOM-based read/find | Low — roughly a thousand tokens | Inspecting page state without pixels |
| Headless test framework, screenshot to disk | Near zero agent tokens | Generating images for a human to review |
| Headless framework + one targeted image read-back | High per read, but only 1–2 reads | Final visual judgment, not a loop |
| Assertion on the underlying chart data/API | Low | "Are the right values plotted" — quantitative checks |

We once burned a large multi-million-token session on a few hundred interactive screenshots exploring how charts looked. The same exploration via a headless framework dumping images to disk would have cost close to nothing.

### When the interactive tool is the right one

Live-state debugging that needs real auth/real backend data and you specifically need console/network inspection alongside visuals; drag-drop or canvas/image-based UI where the DOM doesn't tell the story; genuine first exploration of an unfamiliar UI — but switch to DOM-based inspection once the layout is understood, don't keep looping screenshots for hundreds of actions.

**Hard rule:** more than ~20 interactive screenshots in one flow means stop and switch to a headless framework. The screenshot-every-action loop is the failure mode.

### When a headless framework is the right one

Validating a flow end-to-end with selectors and assertions; walking a known flow repeatedly; visual regression via screenshot + pixel diff against a checked-in baseline; "show me how this looks across N scenarios" — loop it, dump images, let a human review; agent token cost stays near zero.

### Pattern: fuzzy visual goals ("make this look right")

Don't put the agent in a screenshot-and-eyeball loop for a fuzzy aesthetic goal — translate it into measurable criteria checkable from the underlying data/API response instead.

**Example "populated" criteria:** a minimum number of distinct data points/categories/buckets; no segment invisibly small relative to the total; time-series data spanning most of the displayed period.

**Example "meaningful" criteria:** enough spread between max and min values that nothing renders as a flat line; a distinguishable shape (trend, peaks, distinct top/bottom items); comparable items actually differing from each other; magnitudes realistic for the domain.

**Workflow:** read the component to know what it displays and where its data comes from; derive numeric criteria from the defaults above; validate against the API/data response (a few hundred tokens) instead of a screenshot (tens of thousands); iterate seed data using data responses, not screenshots; only dump screenshots via the headless framework once criteria pass, for human review — don't read them back into context unless a visual judgment is specifically needed.

**What this catches:** empty/sparse data (the most common seed-data failure), flat/uniform data (second most common), unrealistic magnitudes. **What it doesn't catch:** pure visual design issues (palette, legend overlap, axis scale) — those need eyes, but they're rarely a data problem, they're a component-code fix.

### Reading screenshots back into context, when genuinely needed

If the agent itself must render a visual judgment with no human reviewer available: take one round of screenshots, read them once, identify issues, then switch back to data-mode for iteration (cheap), and return to a screenshot read only once, at the end, to confirm. Pay the expensive multimodal cost once per phase, not per iteration.

---

## Pending Questions

A question that scrolls off screen is a question that does not get answered. The rule in your
short-rules file (Tool Discipline) is kept with one file per session, plus a hook once you have
it (the pending-question reprint in the HumanMaxxing hooks pack).

**When you ask.** Write the full question text, in the words you showed the user, with a quoted
heredoc so nothing expands. Use your harness's session id; the variable below is Claude Code's.
On a harness without one, choose a per-session file name at session start (for example a
timestamp plus a random suffix) and use it for the whole session. The `:?` makes the command fail
loudly when the variable is unset, rather than write one shared file every session overwrites:

```bash
mkdir -p "$HOME/.claude/pending-questions" && cat > "$HOME/.claude/pending-questions/${CLAUDE_CODE_SESSION_ID:?}" <<'PQ_EOF'
1. <question one, complete>
2. <question two, complete>
PQ_EOF
```

This applies when you ask through a question tool too: the tool does not write the file, you do.
Several open questions share one file; rewrite the whole file, never append.

**When they answer.** Delete it in the same turn:
`rm -f "$HOME/.claude/pending-questions/${CLAUDE_CODE_SESSION_ID:?}"`. A partial answer rewrites
the file with only the questions still open.

**What the hook adds.** The hooks pack's pending-question reprint (a stop hook) shows the file
again at the end of a turn when its text changed or enough conversation has scrolled past since it
last did, and deletes files older than a day. A status line that shows the first open question is
optional and not part of the pack. Without the hook the file is still written; it is simply not
shown again.

---

## Tool Discipline

Cheatsheet lives in your short-rules file; operational detail lives here.

### Read before Edit/Write, always

Never call an edit/write operation on an existing file without a read in the current session — a read-once hook should enforce this mechanically, but don't rely on the error as your only defense against working from stale memory.

### Edit matches must be unique and generous

Include several lines of surrounding context, not just the changed line. If a match fails as "not found," re-read the file — an auto-formatter may have touched it since your last read. If it fails as "multiple matches," widen the context or explicitly opt into replace-all only when every occurrence should change identically.

### Read large files with a limit, after grepping for the target line

Grep first to find the line number, then read with an offset/limit window. Reading a large file blind risks a timeout and wastes the tokens you didn't need.

### Tee + grep, never re-run

Long validation commands (test suite, typecheck, lint, full build) should tee to a log file on the first run; every follow-up filters the log file. Never re-run the whole suite to slice the same output a different way.

**A re-run is earned by a changed input, never by wanting reassurance.** Scope it to the checks whose inputs changed since their last green: a lint-only fix re-runs lint only (lint cannot change runtime behavior); a doc-only edit re-runs only the tests that actually read that file, found by grep first; when nothing relevant changed, the tee'd green stands and you cite it. Re-running an identical test command "to be safe" is one of the largest avoidable token and wall-time sinks in a shipping session.

**Scope every test run to what changed.** A whole-suite run needs a named reason: a change to test configuration, a shared test helper or a dependency, a release, or the user asking. A flaky-test re-run is that one file, never the suite. Re-verifying with the whole suite after every fix round costs runner time, CI minutes and wall time for no new signal.

### Background by default for anything long

Any command expected to run more than ~30s should run backgrounded — builds, full test suites, typechecks, lints, package installs, IaC plans/applies. Foreground is the exception, justified only when the command finishes in under ~30s or the very next step has nothing else to do until the result lands. Backgrounding keeps the user able to interject; pair every backgrounded command with a log file so its output stays greppable once it completes.

**Never poll a still-running background task** — wait for the completion notification; calling back in to check status is polling theater and burns tokens for nothing. Independent checks (e.g. typecheck + lint + test) should all fire in the same turn, each backgrounded.

**Every background wait must be bounded, or it can hang the session forever.** The harness only re-wakes you when a background process *exits* — there's no separate watchdog. An unbounded wait on something that might never conclude (watching a CI run that's stuck queued, a bare infinite loop, following a log file forever, watching an empty/unset target) never exits, so it never notifies, and the session just sits there. The fix keeps backgrounding as the default while guaranteeing an exit:

- **Wrap the wait in a timeout, gated on the condition, inside ONE process:** `timeout <bound> bash -c 'until <condition>; do sleep <poll>; done'`. The process exits when the condition holds or at the bound, so it wakes you exactly once. Make the bound generous (minutes: about 10 by default, never under 2); a short bound just re-wakes you to re-arm. A guaranteed exit is a guaranteed re-wake.
- **`sleep N && <check>` in the background is the banned shape,** and so is re-arming one every few seconds: each wake is a full model turn, so a 30-second loop over a 40-minute wait is eighty turns of nothing. Poll inside the one bounded process instead.
- **A running background task or agent that the harness tracks is already an armed wait.** Its exit notification is your wake; never arm a timer watching the same completion on top of it. (A bounded watch for a different condition beside it, such as the base branch moving while CI runs, is fine.)
- Adopt a status contract: success = done, a timeout-specific code = "still running, re-arm the same bounded wait," anything else = a real error to diagnose. Re-arming after a timeout is recovery, not polling — the no-poll rule forbids checking a *still-running* task, not re-launching a wait that already returned.
- **Guard against an empty target.** Watching an unset/empty identifier can silently report success trivially — always check the target is actually populated before watching it, and use whatever "fail on non-success" flag your watch command offers (many default to exit-0-regardless without it).
- **Never end a turn narrating a wait with no bounded background task actually armed in that turn** — otherwise no notification is ever coming and the session just sits until the user notices and pokes it.

### Background subagents when parallel main-thread work exists

See Subagent Orchestration → Foreground vs. background dispatch.

### Plan-mode propagates to subagents

If you're in a plan-approval-gated mode and dispatch a subagent that will write files, give it write-approval explicitly for that dispatch — otherwise its first write hits the same gate and hangs an unattended dispatch with nobody there to approve it.

### Don't wait for the slowest reviewer

When multiple reviewers run in parallel (backgrounded), don't block on all of them before acting. As each returns: apply obvious factual fixes (typos, wrong references, broken paths) immediately; hold judgment-call findings (architecture, scope, naming) for a synthesis pass; start synthesis once roughly half have returned with substantive findings, or sooner if two-plus converge on the same critical issue, and keep absorbing stragglers as they land. This applies to review/audit waves specifically — multi-stream implementation still needs all streams before integrating.

### User correction is not an automatic re-read trigger

When corrected, first check whether you actually read the relevant file this session. If not, read before re-answering. If you did, re-examine what's already in context — you likely misread, not under-read.

### Status-check before merge

See Git Merge Protocol (a dirty working tree before a merge).

### Capture the real exit code

`$?` after a pipeline is the exit of the LAST command: `cmd 2>&1 | tail -20; echo $?` reports `tail`'s exit, always 0, never `cmd`'s. Capture the first command's status **on the same line as the pipeline, into a variable**, because the very next command (including the `echo` you would inspect it with) resets the array:

```bash
some_command 2>&1 | tee "$LOG"; PS=("${PIPESTATUS[@]}"); echo "Exit: ${PS[0]}"   # bash: uppercase, 0-indexed
some_command 2>&1 | tee "$LOG"; PS=("${pipestatus[@]}"); echo "Exit: ${PS[1]}"   # zsh: lowercase, 1-indexed
```

Check which shell your tool runs (`echo "$BASH_VERSION$ZSH_VERSION"`): the wrong spelling expands to nothing, with no error, and an empty exit value is not success, it means you read the wrong variable. This exact mistake has masked a real failure that then only surfaced in CI, after the local gate that was supposed to catch it.

**Don't use a blanket `set -o pipefail`.** With it, `producer | grep -q pattern` or `producer | head` fails whenever the reader exits early and the producer dies of SIGPIPE, which happens on large inputs: a match reads as a failure. Capture the one status you need instead.

### Pre-existing failures: find them, then fix them

When a test count looks alarming after a multi-file change, run the suite at the base commit to see which failures pre-date your work — in a throwaway scratch worktree, never by stashing your changes. Create it outside your worktree layout and remove it when the baseline run is done, because it registers in the shared repository (a leftover one shows up in every session's `git worktree list` and can block branch deletion):

```bash
SCRATCH="$(mktemp -d)" && git worktree add --detach "$SCRATCH" origin/<base>
# ...install dependencies and run the suite in "$SCRATCH"...
git worktree remove --force "$SCRATCH"
```

The worktree skill's create and remove are for task worktrees with a branch; this detached baseline is the one case you make by hand. The baseline tells you where to look; it is not a license to skip anything. A red suite blocks shipping, and pre-existing failures get fixed too. We once let a pile of "not mine" failures accumulate on the integration branch because each shipper deferred them; fixing them found no product bugs but several stale mocks that had quietly stopped testing a live critical path.

### Policy files: Edit, never Write

Your rules file, this details file, and skill and hook definitions encode rules no compiler or test checks. A whole-file write from a stale read silently restores content that was deliberately deleted, with no error. If the file exists, make a targeted edit. A pre-tool-use hook can enforce this mechanically.

### Diff-scope gate before every commit

Check that the changed-file set matches what the task required: a file outside the task's scope needs an explanation, and a file whose line count exceeds what the task accounts for gets its hunks read. We have seen a routine rename produce far more insertions than deletions because it restored a section that had been deliberately removed.

### Dev servers

Only ever kill, restart or reuse a dev server launched from your own working directory, and check that a test will hit your server on the port it targets (set the base-URL variable explicitly). Detail: Dev Server Management above.

### Cloud CLI auth before cloud commands

Check credentials are live before any cloud CLI work (`<cloud CLI> get-caller-identity`-equivalent per `CLOUD_PROFILES`). If the token's expired, refresh it yourself — don't ask first, just run the refresh (most SSO flows open a browser device-code prompt the user clicks through). Re-verify after refreshing. Only if refresh itself fails, tell the user exactly what to run and that you already tried. Never retry a failed cloud command without fixing auth first — a second failure on expired credentials tells you nothing new.

**Background and non-interactive monitors are the exception.** Never attempt an interactive or device-flow refresh from one: nobody is there to click through the prompt, so the monitor hangs. Fail loud instead. A background monitor that polls a cloud API wraps each call so an expired token surfaces as an explicit error (a non-zero exit and a message naming the auth failure), never as a silently empty result that reads as "nothing changed".

### Skill/command invocation enforcement

When one skill's instructions say "run skill X," actually invoke skill X through your harness's mechanism — don't reimplement its steps inline from memory. A skill typically does more than its underlying raw command: sentinel/cache handling, base-branch sync, atomic label attachment, stale-run cancellation. Reimplementing "the gist of it" loses all of that silently.
