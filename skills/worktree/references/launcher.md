# The launcher — from an issue number to a working session

`bin/worktree-start.sh` is the one command a person types to begin work on an issue. It is run by a human from a
terminal, not by the agent: the terminal becomes the session.

```
worktree-start.sh [--config F] [--force] [--parent DIR] [<model>] <issue> [<issue>...]
```

1. Words are issue numbers (comma lists work: `12,13`) and at most one model name from `START_MODELS`, in any
   position. Anything else is exit 2 and nothing is created. No model word → `START_DEFAULT_MODEL`, which must
   be set when `START_CMD` uses `$MODEL` (with neither, `MODEL` is empty and the result line says `model=none`).
2. It looks for the worktree recorded for **exactly** that issue set. `12` never matches a worktree made for `12 13`; `13 12` and `12 13` are the same set. The base branch's own working copy is never chosen.
3. None found → it runs `worktree-create.sh` for the issue set (guard, branch from the title, copy files, post-create
   in the background, push and claim as configured). `--force` is passed through to skip the guard. If the create
   fails because another session made the same worktree a moment earlier, it finds that one and uses it. Any other
   refusal ends the launcher with the create's own reason and exit code on its last line.
4. It waits, up to `START_WAIT_SECONDS`, until the folder is a valid checkout. A session is never started in a
   half-written folder.
5. It prints `WORKTREE-RESULT worktree-start PASS launching path=… branch=… model=… issues=…`, changes into the
   worktree and replaces itself with `START_CMD`. From that line on, the exit code is your harness's own.

Several issues form a bundle: one worktree, one branch named `<n1>-<n2>-<slug of the first title>`, one session.

## `START_CMD` per harness

`START_CMD` is the only harness-specific line. It runs with `bash -c` inside the worktree with `MODEL`, `ISSUES`
(space-separated), `BRANCH` and `WORKTREE_PATH` in the environment. Keep the quotes: the values are read by the
shell when the command runs and are never pasted into the string.

| Harness | `START_CMD` | Checked against |
|---|---|---|
| Claude Code | `claude --model "$MODEL" --effort high "/start $ISSUES"` | the CLI's `--help` (a positional prompt, `--model`) |
| Gemini CLI | `gemini -m "$MODEL" -i "Follow the start skill for issue(s) $ISSUES"` | the CLI's `--help` (`-m`, `-i` runs a prompt and stays interactive) |
| Any other | the command that opens an interactive session with a first prompt, and its model flag | your CLI's `--help`; we have not run it |

Set `START_MODELS` to the names your harness accepts for its model flag. The worked default starts no session with
permission prompts disabled; if you add such a flag, that is your decision and it belongs in your own file.

## `maxx-start`: the per-machine command

The launcher must run from inside the repository. `bin/worktree-install-launcher.sh` writes a short command on your
`PATH` that runs it from anywhere, once per machine:

```
bash .claude/skills/worktree/bin/worktree-install-launcher.sh [--name maxx-start] [--dir ~/bin] [--config F]
```

The written file changes into the primary working copy (the worktree of `BASE_BRANCH`) and runs that copy's
launcher (and, when this machine sets `WORKTREE_PARENT_DIR` in its environment, that folder). Then `maxx-start 123`, `maxx-start fable 12,13` or
`maxx-start --force 123` work from any directory. The file names the installer on its second line: a file of the same
name that the installer did not write is never replaced, and one it wrote is updated, so re-run it when the
repository or its parent folder moves. It writes outside the repository: install it only with the user's approval.
If the folder is not on your `PATH`, it says so.

## What it does not do

- It does not decide whether the issue is ready to start: that is `ISSUE_GUARD_CMD` (by default `bin/worktree-issue.sh guard`:
  open, on the board in a startable status). Claiming it (assign, move to in-progress, comment the branch) is
  `ISSUE_CLAIM_CMD`, and pushing the branch is `PUSH_ON_ISSUE`; the example file turns all three on.
- It does not wait for the post-create command. The session starts while the install runs; the start skill's
  first steps are reading, and the worktree skill says how to check the install finished before building.
- It does not clean up. Removing a worktree is `bin/worktree-remove.sh`, after the work has merged.
