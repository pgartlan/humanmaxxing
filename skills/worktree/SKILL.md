---
name: worktree
description: Create, list, remove and sweep (bulk-clean) git worktrees, one folder per branch (by default in one `<repo>-worktrees` folder beside the primary copy), so no work ever happens by switching the primary working copy. Includes an issue shorthand (branch named from the issue) and a launcher that goes from an issue number to a session in the right folder.
user-invocable: true
allowed-tools: Bash(bash *), Bash(git *), Read
---

# /worktree — one folder per branch

Every piece of work gets its own folder beside the primary working copy, on its own branch, created from the current tip of the base branch. The primary working copy stays on the base branch and is never switched. The mechanics live in five scripts; this file says when to run them and what to do with each result.

---

## Configuration — `worktree.env`, next to this file

Copy `worktree.env.example` to `worktree.env` and fill it; the getting-started onboarding does this. The scripts parse the file and never source it. The `*_CMD` values are commands the scripts run with `bash -c`: review a change to them like code. The scripts run the commands themselves, so nothing needs adding to `allowed-tools` above.

```
BASE_BRANCH            — REQUIRED. The branch work starts from. Same value as your ship and start skills
BASE_REMOTE            — default origin; set EMPTY for a repository with no remote
GH_REPO                — owner/repo the issue commands' gh calls target (exported to slot commands); empty = gh's default
WORKTREE_PARENT_DIR    — where worktree folders go; default: one folder per repository, <repo>-worktrees beside
                         the main checkout (made by the first create); a bare-repository layout keeps them
                         beside the bare repository
COPY_FILES             — files git does not carry, copied into each new worktree (a local env file)
POST_CREATE_CMD        — your dependency install; POST_CREATE_MODE = wait | background
ISSUE_TITLE_CMD        — prints an issue's title (names the branch); empty = number-only names
ISSUE_GUARD_CMD        — exit 0 when an issue may be started; empty = no guard, said on every run
ISSUE_CLAIM_CMD        — assign / move the card / comment, once per issue, after the worktree exists
                         (the example file fills all three with bin/worktree-issue.sh, for GitHub: starting an
                         issue always guards, claims and pushes, whether the team is one person or a thousand)
ISSUE_PROJECT, ISSUE_STATUS_FIELD, ISSUE_STARTABLE, ISSUE_IN_PROGRESS — the board worktree-issue.sh reads and moves
PUSH_ON_ISSUE          — 1 (the example's value) pushes the new branch at creation; 0 leaves that to your ship step
BRANCH_MAX_LEN         — cap on a derived branch name (the number prefix is never cut)
START_CMD, START_MODELS, START_DEFAULT_MODEL, START_WAIT_SECONDS — the launcher (references/launcher.md)
```

Every script takes `--config <file>` and runs from wherever it sits, so it also works straight from a download before the skill is installed. Run them from inside the repository.

**Companions (all optional).** A start skill reads `WORKTREE_LAYOUT` in its own Configuration and stops when asked to begin work in the primary working copy. A ship skill pushes and merges the branch; `ISSUE_CLAIM_CMD` fires when work starts, the ship skill's board move when the PR opens. The issue set this skill records lives in the worktree's git directory, where a ship skill that reads an issue-list file from the checkout does not look: for a bundle, such a ship skill sees the numbers in the branch name plus whatever its own file says. A tracker CLI is needed only by the three `ISSUE_*_CMD` slots: with none, leave them empty and name branches yourself. No harness command for `START_CMD`: skip the launcher; create the worktree, change into it and start your session by hand. No bash: the manual commands at the end of this file.

---

## Design principles

1. **A new branch never inherits the base as its upstream.** Created from a remote base, a branch tracks that base unless told otherwise; "unpushed" checks then compare against the wrong branch and a plain push can aim at the base. New branches are created with no upstream; a branch that already exists on the remote tracks itself.
2. **A failed read is not "absent".** Asking the remote whether a branch exists has three answers: yes, no, and could not ask. Only "no" creates a new branch. A network blip must never produce a second branch with the name of one that already exists.
3. **Nothing is created until every refusal has had its chance.** The guard, the name checks and the remote reads all run first. Once the worktree exists, later steps (copy, install, push, claim) each still run, and a failure there is reported with the worktree left in place and named.
4. **"Merged" is judged by ancestry against the base.** `git branch -d` answers relative to whichever checkout it happens to run in, or to the branch's own upstream: it refuses branches that are merged and deletes branches that are not. The remove script asks one question (is this branch's tip contained in the base?) and decides itself.
5. **The only copy of work is never deleted by a script.** A branch that is unmerged and not fully on a remote survives every flag. The folder can go; the commits stay reachable by name.
6. **Findings are the user's to answer.** A worktree with uncommitted files, unpushed commits or unmerged work is removed only after the user has seen exactly that and said yes.
7. **The folder is created by git, never before it.** A folder made ahead of the checkout can be opened by a tool while it is still empty, and a leftover empty folder makes two creates for one path both appear to succeed.
8. **State about a worktree lives in its git directory.** The issue set and the install's log and exit status are files git itself keeps per worktree, so they never show in `git status` and never reach a commit.
9. **A folder in use is never removed.** A process sitting in the folder (a session, a dev server, a test watcher, a shell), or a mount point at or below it, refuses the remove whatever the flags: the user's answer consents to discarding files, never to deleting out from under a running session or into a mounted volume. A process list or mount table that cannot be read is a stop, never a pass. Untracked files are counted even when git is set to hide them (`status.showUntrackedFiles=no`): they are the one thing no ref can bring back.
10. **Bulk cleanup goes through `sweep`, never by hand.** Many worktrees pile up when many agents run; a hand-rolled loop of `git worktree remove` and `git branch -D` is how merged-somewhere-else and still-in-use work gets deleted. The sweep's skip rules are the whole rule, and none of them is relaxed for a big batch.

---

## The self-service rule

An agent may create **one** new branch in **one** new worktree folder, from the base branch, without asking, when the task it was given needs its own branch. It says what it created (branch, folder, starting commit) in its next message. An orchestrated run differs only in count: a lead running several agent teams may create one worktree per team, as its own instructions prescribe, without asking for each; worktrees your harness creates by itself for isolated subagents do not count against either limit. Everything else still needs the user's explicit go-ahead: a second worktree for the same task, switching or checking out a branch in an existing folder, anything in the primary working copy (the fast-forward described under Create is the script's, not a switch), and every removal of a worktree that holds work. A scratch worktree the agent itself made for a throwaway check, with nothing in it to lose, it may remove when the check is done, through `check` then `remove`, and only when `check` comes back clean.

---

## Usage

- `/worktree create <branch>`: a worktree on a new branch (or on the remote branch of that name)
- `/worktree <issue> [<issue>...]`: issue shorthand; the branch is `<numbers>-<slug of the first title>`
- `/worktree list`
- `/worktree remove <branch>`
- `/worktree sweep`: list every finished worktree, and remove the ones the user approves
- `/worktree` with no argument: show these five lines

Route on each script's **exit code and last line** (`WORKTREE-RESULT <script> PASS|FAIL <reason> …`), never on the prose above it.

| Code | Meaning | What you do |
|---|---|---|
| 0 | done | report the last line's fields |
| 1 | refused | tell the user the reason; do not work around it |
| 2 | usage or configuration | fix the call or `worktree.env` |
| 3 | a read failed | retry once when the reason is a network read (`fetch-failed`, `ls-remote-failed`); otherwise report it. Never continue as if the answer were "no" |
| 5 | findings | show them to the user and wait for the answer |
| 6 | the worktree exists, a later step failed | report which step; finish it by hand or remove the worktree |

Reason tokens, by exit code. **0:** `created`, `listed`, `clean`, `removed`, `swept`, `launching`. **2:** `usage`, `config-missing`, `config-malformed`, `config-base-branch`, `config-remote`, `config-copy-files`, `config-parent-dir`, `config-start-cmd`, `not-a-repo`. **1:** `guard-refused`, `path-exists`, `branch-exists`, `add-failed`, `create-in-progress`, `no-commits`, `is-base`, `is-current`, `not-found`, `remove-failed`, `in-use`, `mount-below`, `sweep-incomplete`. **3:** `fetch-failed`, `ls-remote-failed`, `title-failed`, `marker-unreadable`, `status-failed`, `compare-failed`, `not-a-checkout`, `live-unknown`, `mount-unknown`. **5:** `findings`. **6:** `marker-failed`, `copy-failed`, `post-create-failed`, `push-failed`, `claim-failed`. The launcher, when the create it ran refuses, repeats the create's own reason and exit code on its last line (`create-failed` only when the create printed no reason).

---

## Create

```bash
bash .claude/skills/worktree/bin/worktree-create.sh <branch>
bash .claude/skills/worktree/bin/worktree-create.sh <issue> [<issue>...] [<branch>]
```

The folder is `<parent>/<branch with / replaced by ->`. A derived name is the issue numbers, then the first six words of the first issue's title, lowercased, with filler words (the, a, to, of, for…) dropped. In order, the script: checks the guard (issue form), takes a short lock on the folder name, repairs a missing fetch refspec (a bare clone has none), fetches the base, asks the remote whether the branch exists, creates the worktree, records the issue set, copies `COPY_FILES`, runs `POST_CREATE_CMD`, pushes and claims (issue form, as configured), and fast-forwards the local base.

- **Issue form.** Don't ask the user to confirm the derived name; state it in your first status line so they can interrupt. `guard-refused` means the issue is not free to start: report what the guard printed. `--force` skips the guard and is passed only when the user says so.
- **`path-exists` / `branch-exists`.** Something by that name is already there (for `branch-exists`: a local branch that is not on the remote, one checked out elsewhere, or one that has diverged from its remote branch). Look (`worktree-list.sh`), then ask; never delete to make room. `add-failed` is git refusing the checkout for another reason: report what it printed.
- **A branch that exists both locally and on the remote** is used only when one contains the other: it is fast-forwarded to the remote if behind, and tracks its remote branch either way.
- **A bundle** is recorded as a set: `12 13` and `13 12` are the same worktree. The first number you type decides whose title names a new branch.
- **`setup=background`** on the result line: the install is still running. Before the first build or test in that worktree, read the exit-status file the script printed; absent means still running, non-zero means the install failed.
- **`setup=none`** (no `POST_CREATE_CMD`) and **`setup=skipped`** (`--no-install`): nothing ran and no exit-status file is written, so never wait for one. `--no-hook-setup` runs the install with `HUSKY=0` and `LEFTHOOK=0` and puts back any change it makes to `core.hooksPath`, which lives in the repository's shared config and would otherwise switch a hooks manager on in every checkout; the change is reported.
- **The local base** is brought forward by fast-forward only, in whichever folder has it checked out, and only when that folder has no uncommitted changes. That is the one thing this skill does in the primary working copy: it stays on the base branch and moves forward. `--no-base-update` skips it. A base that has diverged is reported and left alone; never merge, rebase or reset it to force the update.

After a create, change into the new folder for every later command and say so. If your harness resets the shell's directory between commands, register the folder for the session or tell the user to restart the session there.

## List

```bash
bash .claude/skills/worktree/bin/worktree-list.sh
```

One tab-separated line per worktree: path, branch, commit, state, recorded issues. The state is `clean`, `dirty`, `unreadable` (git could not read its status: treat it as not clean) or `missing` (registered, folder gone). Present it as a table and flag every row that is not `clean`.

## Remove

```bash
bash .claude/skills/worktree/bin/worktree-remove.sh check  <branch>
bash .claude/skills/worktree/bin/worktree-remove.sh remove <branch> [--delete-branch] [--confirmed] [--discard-uncommitted] [--discard-commits]
```

1. Run `check`. Exit 0 → `remove <branch> --delete-branch` is safe to run after the user asked for the removal.
2. Exit 5 → show the findings (uncommitted paths, commits not on a remote branch, not contained in the base, an install still running, or `setup-died`: an install that stopped without recording a result) and **wait for the user's answer**. Only then pass `--confirmed`, and `--discard-uncommitted` only if they said the uncommitted files can go. You never add either flag on your own initiative.
3. `remove` repeats the checks itself, so a stale `check` cannot wave anything through.
4. `in-use` (a process is running inside the folder) and `mount-below` (a mount point at or below it) are refusals no flag overrides: tell the user which, and run it again once the session ends or the volume is unmounted. `live-unknown` and `mount-unknown` mean the check itself could not be read (for example: another account's processes are invisible to this one); never remove by hand to get past them. Under Git Bash, MSYS or Cygwin on Windows the shell cannot see native programs at all, so instead of either answer the findings carry `in-use-unknown=1`: ask the user whether a session, editor or server still has the folder open, and pass `--confirmed` only on their answer, like any other finding.

"Not contained in the base" is also what a squash-merged branch looks like. Say both readings, and what decides between them: it counts as merged only when a PR from this branch was merged into the base itself, with this branch's tip as the commit that PR merged, and was not reverted afterwards. A PR merged into another branch, or merged and then reverted, is not merged into the base. The user knows which it is. The result line's `branch-deleted=0|1` says what happened to the branch. `kept=only-copy`: the folder is gone and the branch was kept because nothing else holds its commits; tell the user its name. If they then say those commits can go (the usual case: the work was merged by squash), that answer is `--discard-commits`: run `remove <branch> --delete-branch --confirmed --discard-commits` again. It works with the folder already gone (the same checks then run on the branch alone). Like the other two flags, you never add it yourself. `kept=delete-failed`: git refused the delete; report what it printed. Never delete a branch by hand to finish the job. The base branch's folder and the folder you are standing in are refused outright.

The script never deletes a remote branch. That is your ship step's job at merge, or the user's.

## Sweep — bulk cleanup

```bash
bash .claude/skills/worktree/bin/worktree-sweep.sh
bash .claude/skills/worktree/bin/worktree-sweep.sh --confirmed <branch> [<branch>...]
```

When the user asks to clean up worktrees, this is the way; a loop of `remove` or of git commands is not. The first form only lists: one tab-separated line per worktree, `candidate <branch> <path> <issues>` or `skip <branch> <path> <reason>`. A worktree is a candidate only when nothing in it can be lost or interrupted; the skip reasons, in the order they are checked:

| Reason | Why it is kept |
|---|---|
| `in-use` | a process sits in the folder |
| `recent-edits` | a file changed in the last 72 hours: an isolated subagent's worktree is not its process's working directory, so the in-use check cannot see it, but its edits can |
| `uncommitted` | any uncommitted or untracked path |
| `setup-running` | its install has not recorded a result |
| `unmerged` | the branch tip is not contained in the base. A squash-merged branch is skipped too: it goes through `remove` and the user's answer, one at a time |
| `mount-below` | a mount point at or below it |
| `unreadable`, `compare-failed`, `mount-unknown` | a check could not be read, so nothing is assumed |
| `in-use-unknown` | the shell cannot see native programs (Git Bash, MSYS, Cygwin on Windows): every worktree is skipped, so clean up there one at a time with `remove` and the user's answer |

The main working tree, the base branch's folder, the folder you run in and detached checkouts are never listed. Show the candidates as one table (and the skips below it, with their reasons). Mark every candidate whose issues column is not `-`: a worktree made for an issue and still sitting at the base may be work that has not started yet (the sweep does not ask the tracker), so name the issue and let the user leave it out. Then **wait for the user's approval of the batch**. Then run the second form with exactly the approved names. `--confirmed` is that approval: never add it on your own initiative, and an approval covers that batch only, never a later sweep. Each name is judged again right before it is removed, so one that changed since the list (a session started, a file was edited) comes back `not-swept <branch> <path> <reason>` instead of being removed; a name with no worktree comes back `not-found`. Removal is one at a time, never forced; the branch goes with the folder (its tip is in the base), and each removal prints `restore: git branch <branch> <sha>`: pass those lines on. `failed` lines and the `sweep-incomplete` result (exit 1) name what git refused. A process list that cannot be read stops the whole sweep before anything is removed (`live-unknown`, exit 3). The sweep never touches a remote branch.

## The launcher

`bin/worktree-start.sh <issue>...` takes a person from an issue number to a session in the right folder. It is typed by a human in a terminal, usually as `maxx-start <issue>` from any directory: `bin/worktree-install-launcher.sh` writes that per-machine command once (it writes outside the repository, so only with the user's approval). See `references/launcher.md` for its rules, the `START_CMD` line per harness and the installer.

---

## Without the scripts

The same steps by hand, for an environment with no bash. Substitute your base branch and remote.

```bash
git config --get remote.origin.fetch || git config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'   # a bare clone has none
git fetch origin
git ls-remote --exit-code origin refs/heads/<branch>        # 0: exists · 2: does not · anything else: stop
git worktree add --no-track -b <branch> ../<folder> origin/<base>      # new branch
git worktree add --track    -b <branch> ../<folder> origin/<branch>    # branch already on the remote
```

Then copy your local env files and run your install inside the new folder. To remove: `git status --short --untracked-files=all` in the folder (your git config may hide untracked files otherwise), `git merge-base --is-ancestor <branch> origin/<base>` after a fetch, make sure no session or server is running inside the folder, show the user what you found, and only on their answer `git -c status.showUntrackedFiles=all worktree remove ../<folder>`. Leave the branch unless it is contained in the base.

---

## Reference

- `references/launcher.md`: the launcher, `START_CMD` per harness, the per-machine `maxx-start` command
- `worktree.env.example`: every key, with worked values
