# Changelog

Each release names what changed and what an installed copy has to merge. Installed skills are copies:
run `tools/hm-lock.sh status --from <new download>` from your project to see which installed items are
behind, then merge each one (keep your filled values, `.env` files and generated tables; take the
product's changes) and record it again with `tools/hm-lock.sh record`. `getting-started.claude.md`
("An installed skill is a copy") has the full procedure.

## 0.1.0

First public release. Everything is new; there is nothing to merge.

- New skill `trim`: writes a `/compact` command tailored to the conversation, for you to paste. Before a compact
  headed for a ship or a commit of unreviewed code, it checks ship's review sentinel
  (`ship-sentinel.sh --contract=2 verify review`) and runs review-code first; without ship it skips the check and
  says so. The onboarding installs it at step 7, with no question. Its file goes to a folder in your home
  directory (`COMPACT_DIR`, worked default `$HOME/.cache/trim`), never a shared temp folder: it holds a summary of
  the conversation.
- `skills/peer-review` (new): a three-axis verdict (Code, Test coverage, Merge-readiness) on someone else's pull
  request, from targeted reads of the diff and the code at the PR's head commit, with `file:line` evidence. Its
  grants are `gh` and `git` reads only (the one `git fetch` per PR asks); it comments, approves or merges only when
  you ask. The onboarding installs it at step 7, with no question, filling its Configuration block from answers
  it already has. `review-code` stays the review for your own changes.

- Onboarding step 8 wires the protected-file guard and the commit check in warn mode (`hooks-install.sh --mode warn`:
  they print what they would have asked about or refused and never block); switching them on (`--mode enforce`) is
  the last proposed follow-up. A GitHub copy of the repository is recorded as `GH_REPO=owner/repo` in `ship.env`,
  `retro.env` and `worktree.env`, which the `ship`, `retro` and `worktree` scripts honour, and step 12's merge can take
  a mirror route (push to the GitHub copy, open the pull request there). The templates and skills default to no
  particular language stack. `LICENSE` (MIT) and `CONTRIBUTING.md` are new.
- Windows (Claude Code runs commands in Git for Windows' bash): a `.gitattributes` checks every text file out with LF
  line ends, whatever `core.autocrlf` says. Every configuration file and list a script reads (`ship.env`,
  `worktree.env`, `retro.env`, `hooks.env`, the protected-files and critical-paths lists, `.claude/humanmaxxing.lock`)
  reads a CRLF line end as a line end, so a copy checked out with CRLF in your own repository works; a carriage return
  anywhere else in a line is still malformed. The hooks treat a `python3` that does not run (the Microsoft Store
  alias) as no parser, never as unreadable input, and read a native `jq.exe`'s CRLF output; the worktree scripts print
  and compare worktree paths in the shell's own form, not git's `C:/…`. CI runs the suite on Windows too.

- Onboarding: step 8 verifies the hooks offline (`hooks-check.sh` now also runs the wired guard handler),
  with the live check a follow-up after the merge, so no step needs a new session; the install's own commits and
  push run with the repository's git hooks off, and Step 0's dependency install can be skipped and runs with hooks
  managers off; skipping the merge decision merges (through a pull request where the branch is protected); "a copy
  of a GitHub repository" is defined and needs the user's own GitHub evidence; drafts and agent allowlists are
  checked against the repository's docs first; audit install-fixes default to "fix now"; about a third fewer
  decisions, every one with a default; concrete follow-ups (critical paths by fix density, reviewers per busy
  area, rules mined from CI and docs, more guards, no AI attribution).
- `skills/worktree`: `worktree-create.sh --no-install` and `--no-hook-setup`; a clear line when no install runs.
- `hooks/`: the installer warns when `.claude/settings.json` is git-ignored and names the un-ignore lines.
- `skills/review-code`, `skills/review-plan`: `MAX_REVIEWERS`, a hard total of reviewer agents per review
  (`bin/reviewer-fold.sh`), with lenses scored by weighted complexity (`bin/lens-score.sh`, `LENS_WEIGHTS`,
  `SMALL_DIFF_SCORE`, `REVIEWER_STEP_SCORE`, `LENS_MIN_SCORE`, `LENS_CHECK_<agent>`) and hybrid agents that load each
  folded agent's full profile. The onboarding asks the cap last.
- `skills/checkpoint`: `COMMIT` and `AUTOSTASH` modes; the repository's own secret scan is preferred.
- `skills/bootstrap-agents`: `ToolSearch` for builders that review; no catch-all code-reviewer row; the test row
  covers every critical path; a `## Lens` index in every agent; `vendor/` and `third_party/` left out of counts.

- `skills/retro`: a weekly, read-only retrospective (`/retro`), with `bin/retro-data.sh` gathering the numbers and
  `retro.env` as its configuration. The onboarding installs it as step 9 and its first-week calendar runs it weekly.
- Onboarding: the first install never blocks itself. Checks, critical-path end-to-end gates, the second opinion and
  extra guards are tried once and proposed as follow-ups, never switched on during the install. New close-out steps:
  a read-only final audit by a fresh agent (step 10), the follow-ups, filed only with approval or written to a docs
  file (step 11), and a merge decision (step 12), then `maxx-start`. The progress ledger now lives in the report
  folder inside the git directory and is never committed.
- `skills/checkpoint`: a `PUSH` slot (`ask`, the default, `always` or `never`) decides whether a checkpoint pushes;
  a one-line secret-scan default that needs no script in the repository.
- `skills/review-code`, `skills/review-plan`: `TRACKER=none`; a call contract for `SECOND_OPINION_CMD`; a reviewer
  agent without a Write tool returns its findings in its reply (`references/reviewer-prompt.md`).
- `skills/start`: takes a task described in words when the repository has no tracker.
- `templates/CLAUDE.template.md`: never bypass required checks or branch protection unless the user says so for that
  instance; a protected-file guard asks for approval instead of hard-blocking.
- `hooks/`: the first hooks pack (Claude Code). `protected-file-guard.sh` asks for your approval
  before the agent changes a file in `.claude/protected-files.txt`, the hooks folder, or a
  `.claude/settings.json` / `.claude/settings.local.json` that could switch the hooks off (it refuses only in the
  bypass-permissions and don't-ask modes, where nobody can be asked); `commit-check.sh` refuses
  a commit while `COMMIT_CHECK_CMD` fails (and can run from a git `pre-commit` hook too);
  `pending-question-reprint.sh` shows the question the agent is waiting on again at the end of a
  turn. `bin/hooks-install.sh` installs them (plan, then apply only the approved plan);
  `hooks-check.sh` is the session-start check. Onboarding step 8 wires all three, the guard and the commit check
  in warn mode (see the first bullet); question (j) asks where the wiring lives.
- One protected list: `.claude/protected-files.txt`, read by the guard, `ship` and `review-code`. With
  `PROTECTED_FILES` set to `see .claude/protected-files.txt`, the `ship` and `review-code` gates check the
  list plus the guard's always-protected files, and stop when the list file is missing; they are the
  pre-merge check for what the guard's shell check cannot see.
