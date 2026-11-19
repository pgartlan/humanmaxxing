> **How to use this file.** Get a copy of this repository (clone it, or download and unpack it) and
> put it **outside** your project, for example `~/humanmaxxing` beside your repos; if it must sit
> inside, use a folder git ignores (add it to `.git/info/exclude`) so it is never committed. Keep
> the copy unmodified (for a clone, a clean `git status`): the install record hashes its files as
> they are on disk. The onboarding reads the copy by absolute path and installs each artifact where
> it belongs, one step at a time. Open Claude Code in your project and say:
> **"Read `<copy>/getting-started.claude.md` and follow it."** That's the whole invocation.
>
> **Run it on your strongest model.** The onboarding is judgment work, and a weaker model guesses
> where it should ask. In Claude Code: start it with `claude --model opus --effort high` (or
> `fable`, if your account has it), or type `/model opus` before the line above. The agent checks
> this first.
>
> **It commits after every step.** The install runs on its own branch (Step 0 creates it), and each
> step is committed there once you approve it, so each can be read and undone on its own. Nothing is
> pushed, opened as a pull request or merged without asking you: the last decision of the install is
> whether to merge, and skipping it merges (through a pull request where the branch is protected or
> the host needs one; never a bypass). On a mirror where that pull request cannot be opened from
> here, a skip keeps the branch and prints the commands. Approving the plan permits these per-step commits on the onboarding branch; if
> your own instruction files forbid commits, that is raised as a conflict before the plan. The
> `CLAUDE.md` it installs keeps its own commit rule for everything after.
>
> **It never blocks its own merge.** Checks the survey finds (lint, tests, a secret scan,
> critical-path end-to-end gates, a second-opinion review, extra guards) are tried once and proposed
> as follow-up tickets with their evidence; none is switched on as a gate during the install, and
> the guards it installs only warn until you switch them on (see "The first install never blocks
> itself").
>
> **Feedback, if you want to give it.** The first dialog asks whether the agent may keep notes on
> where these instructions were unclear. They stay on your machine. At the end you see the exact
> text, can add your email and any other feedback, and choose whether to send it to the HumanMaxxing
> maintainers. Nothing is sent without that approval.
>
> **If your project *is* a copy of this repository** (a fork for your own skill set), the files
> under `skills/` and `templates/` are the source, installed into `.claude/` and the repo root as in
> any other project. The source folders are never edited by the install, and an existing root
> `CLAUDE.md` is never overwritten without a diff and your approval.
>
> This file is deliberately **not named `CLAUDE.md`** and is **not a skill**: a plain prompt your
> agent reads top to bottom in this conversation, executing the phases directly. Nothing here
> auto-loads; nothing runs until you say so.

# Getting started with HumanMaxxing

This file turns a bare repo into one with a behavioral contract (`CLAUDE.md`), a subagent roster,
folder-level conventions where they're earned, and a working commit → review → ship pipeline,
installed in the order that works for *your* repo.

It runs five phases (0–4): show you every question and, with your approval, answer what it can from
the repo itself (0–1), then ask only what is left; propose an ordered plan and stop for your approval
(2); execute one artifact at a time with a resumable ledger, then audit the install, list the
follow-ups and ask whether to merge (3); and leave a first-week maintenance calendar (4). Nothing
destructive happens before Phase 2's approval, and nothing here bypasses a gate that a downstream
artifact defines for itself.

---

## Before you begin: fresh install or resume?

Agent — run these cheap checks first, in this order, and stop at the first that applies. Every check
looks only at **this project**: the repository you were opened in (`git rev-parse --show-toplevel`)
and the folders its own `git worktree list` names. Never look for a ledger or a lock anywhere else,
on the rest of the machine or in the downloaded copy: one from another repository is not this
project's, however similar. The download is read only for what it ships (its skill names,
templates, tools and `VERSION`).

**The model.** If this session is not on the harness's strongest tier (Claude Code: opus, or fable),
the verdict line ends with "running on <model>; this onboarding works best on the strongest model:
type `/model opus` and say 'continue', or carry on as is". That is a suggestion, not a stop: do not
wait for a reply to it or ask it again. On the strongest tier, say nothing about it.

**The download.** It is its own git checkout only when
`git -C <download> rev-parse --show-toplevel` succeeds AND prints the download's own path (another
path means it sits inside some other repository, whose status says nothing about the download).
Compare the two in one form: on Windows git prints `C:/…` while the shell (Git Bash) says
`/c/…`, so normalize both first (`cd <path> && pwd -P`, or `cygpath -u <path>` where `cygpath`
exists) and never compare the raw strings.
Only then run `git -C <download> status --porcelain`: empty = unmodified; anything listed is a local
edit the install record would hash as the release, so report it and ask whether to continue before
any step that installs from it. Not its own checkout (an unpacked archive) → not checked.

1. **Ledger.** Look for `getting-started-progress.md` in this repository's report folder (see "Every
   message that waits for the user"), and, for an install by an older release, at the top of each of
   those folders. A `pending` row → **resume**: report its status and continue at the first
   `pending` step; do not re-ask the questions or re-propose the plan. A ledger
   whose only open rows are the merge (`not yet` or `branch kept`) and `maxx-start` (`waits for
   the merge`) is not a resume: the install is done; say "installed on <branch>, not merged yet" in
   the verdict line and offer the merge decision again (Phase 3, "Merge"). First, for `branch kept`,
   check whether the branch has merged since (its pull request merged, read with
   `--repo owner/repo` on a copy of a GitHub repository, or the branch is in the remote
   integration branch): if it has, mark the merge row `done` and offer `maxx-start` instead. A
   ledger with every row closed is ignored.
2. **Lock.** Look for `.claude/humanmaxxing.lock` (the release each installed item came from) at the
   top of those folders. A lock with no ledger, or no `pending` row → **update**: say what changed
   per the download's `CHANGELOG.md` between the recorded versions and its `VERSION`, then run
   `bash <download>/tools/hm-lock.sh status --from <download>` from inside the project. Each `behind`
   item is merged per "An installed skill is a copy" (Fail-safes) and recorded again; each `gone`
   item is reported (the release dropped or renamed it); each `NEW` skill is offered as a gap to
   fill, through Phases 1–3 for that skill only.
3. **Partial install** (started by hand, no ledger): a root `CLAUDE.md` containing either template
   marker line, exactly (check with `grep -F`):
   `## Configuration — fill these in for your repo` or
   `# CLAUDE.md — a behavioral contract for your coding agent, not a style guide`;
   or a `.claude/skills/<name>/` that is evidently this download's skill: its `SKILL.md` has the
   same `name:` **and** the same first line of `description:` as the download's, or
   `.claude/humanmaxxing.lock` records it. A folder that only shares the name is the user's own
   skill (Phase 1, "A skill or command with the same name"). The user's **own** instruction
   files, agents or skills (a `CLAUDE.md` without those markers, `AGENTS.md`, their own agents,
   a same-name skill of their own) are not a partial install: they do not change the mode; Phase 1's "Existing instructions and
   agents" handles them. A partial install → **gap-filling mode**: treat its Configuration block as
   answered (confirm the values, don't re-ask) and scope Phase 1 to what is *missing*. If Step 0 and
   steps 1–9 are all done, say there's nothing to install; only the close-out (audit, follow-ups,
   merge, `maxx-start`) and Phase 4's calendar can still be open.
4. **None of the above** → a fresh install.

**Report the verdict in one line** at the top of your next message ("Fresh install: no ledger, lock
or partial install found in this repository; download: unmodified git checkout"), with what you found
if it is not a fresh install. The download part is exactly one of
"download: unmodified git checkout",
"download: git checkout with local edits (listed in the report)" or
"download: not a git checkout, not checked". If the repository has instruction files, agents or
skills of its own (check 3; a `.claude/skills/` or `.agents/skills/` folder whose names are not the
download's counts too; user-level skills and agent-memory folders are named too), or the harness's
user-level instruction file exists and is not empty, end the line with "; your own `CLAUDE.md`
[and …, the skills `<names>`, your user-level `CLAUDE.md`] found" and, on a fresh install only,
", Phase 1 compares them with the template". On a fresh install the verdict line is Phase 0's **Where we
are**. Do not send the verdict on its own or wait for a reply to it.

**Feedback notes, whatever the mode.** Look for `feedback.md` in the report folder.
Present = decision 2 of Phase 0 is A (answered, or taken as the
default on a skip): keep adding to it. Absent = no notes are kept. If it holds notes not yet sent or
declined (see "Feedback to the maintainers"), end the verdict line with "; feedback notes from an
earlier session are not sent yet", and offer them when this session ends (once: when the
onboarding also ends in this session, that is Phase 4's offer).

---

## The one thing this file will not guess

If the user says "just set it up," "skip the questions," or otherwise routes around Phase 0, comply
for everything except **your domain's non-negotiable invariant** (question (b)). It is asked at the
end of Phase 1, with candidates from the code; if the user skips it, ask again, and
do not start Step 1 without it. Every other answer can proceed on a finding or a stated default.
This one can't: no code signal tells an agent what a false success looks like in your domain, and a
wrong guess makes every downstream artifact enforce the wrong thing with full confidence.

---

## The first install never blocks itself

The first goal of the install is to get the framework committed and merged. Nothing the first
install sets up may block or delay committing and merging the install itself.

- **Checks become follow-ups, not gates.** Quality-check commands (type check, lint, tests, build, a
  secret scan, static analysis, the repository's own invariant and domain checks), critical-path
  end-to-end gates, a second-opinion review and extra guards found by the survey are recorded as
  **proposed follow-ups**, each with its evidence, and are not switched on during the install
  ("turn on the lint check `npm run lint`: currently 23 errors"). A check that passed when it was
  tried is listed as "ready to switch on", and is still a follow-up, not on by default. A secret
  scan is never a bare "ready": when Phase 1 found a secret the scan did not flag, its follow-up
  says "tried: clean, but does not catch the finding at `<file:line>`", and that secret's own
  follow-up says no scan covers it. The user switches each one on later by approving its follow-up.
- **A follow-up** has a title in plain words, the exact change (the slot and its value, the file
  and its lines), the evidence (what was tried and what happened, or the file that shows the
  need), and what it needs first, if anything ("needs Docker running", "23 lint errors to fix").
  Keep every one in `<report folder>/follow-ups.md` as it comes up, in any phase; step 11 lists
  them all.
- **Where every gate sits on the first install:**

| Gate | Set during the install to | Turned on by |
|---|---|---|
| The check commands of `checkpoint` (`TYPECHECK_CMD`, `LINT_CMD`, `TEST_CMD`, `BUILD_CMD`, `SECRET_SCAN_CMD`, `SAST_CMD`, `INVARIANT_CMDS`, `DOMAIN_CHECKS`) and of `ship` (`TYPECHECK_CMD`, `LINT_CI_CMD`, `LINT_FIX_CMD`, `BUILD_CMD`, `SECRET_SCAN_CMD`, `SAST_CMD`, `TEST_CMD`, `CONDITIONAL_CHECKS`) | empty, each with a comment line above it naming its follow-up (`# follow-up: lint, npm run lint, 23 errors when tried`) | its follow-up: the command goes into the slot and into the skill's `allowed-tools` |
| `ship`'s review gate | `REVIEW_GATE=sentinel` whenever step 7 installs `review-code`: a pull request passes the review and end-to-end gates only on the sentinels a review-code run writes, never on the agent's word. It cannot hold the install, whose commits and merge do not go through `ship` (below). Only when `review-code` is skipped or the user kept a review skill of their own: `REVIEW_GATE=manual`, where an attestation's note quotes the user's own in-session confirmation and the agent never attests its own review or tests | already on |
| The critical-path end-to-end gate (`ship`, `review-code`) | the confirmed critical paths are written into `.claude/critical-paths.txt` as `# off: <glob>` lines under a line saying why; comment lines are not read, so every diff is exempt | a follow-up: "turn on the end-to-end gate for <paths>", one command that removes every `# off: ` prefix (step 11) |
| `SECOND_OPINION_CMD` (`review-plan`, `review-code`) | empty | a follow-up that names the vendor and says your diffs and plans are sent there |
| Guards found by the survey (a file the repository guards, a wrapper a command must go through) | recorded, not installed | a follow-up each |
| Protected files | listed in the skills' `PROTECTED_FILES` (this only makes a review or ship stop and ask; it never blocks a commit) | already on |
| The hooks pack (step 8) | the protected-file guard and the commit check are wired in **warn mode** (`hooks-install.sh … --mode warn`): each prints what it would have asked about or refused, and never blocks; the review nudge only prints its reminder; the pending-question reprint is wired as is. None can refuse a commit or the merge you approve | a follow-up: "switch the guards on", the same install run with `--mode enforce` (plan, then apply) |

- **The install's own commits and merge never run through `checkpoint`, `ship` or `review-code`.**
  Those skills are installed by this onboarding, not used on it: their protected-file stops would
  halt on the install's own diff, and a review of the install's own files is the audit's job
  (step 10). Each step is committed directly (Phase 3, item 3); the merge is its own decision
  (step 12). For the same reason, the installed `CLAUDE.md`'s rule to run the code review as soon
  as work is done applies to the first change after the merge, not to the install: step 10 is the
  install's review, and reporting a step as done is not a completion claim it holds back.
- **Install commits follow the repository's commit style** (Phase 1's commit-message finding:
  `chore: onboarding step 2, agent roster` where messages are conventional, `Onboarding step 2:
  agent roster` with keywords, the emoji first where the history puts one there).
- **The repository's own git hooks do not run on the install's commits or its push.** Every one
  runs as `git -c core.hooksPath=<report folder>/no-hooks commit …` (an empty folder; the same for
  the step-12 push), so a slow or failing pre-commit, or a hooks manager Step 0's dependency
  install switches on, cannot hold the install: it changes only agent configuration, never code.
  The plan says so in one line. This covers the install's own commits and push only: every later
  commit runs the hooks as before, `--no-verify` is never used, and server-side protection and
  required checks are never bypassed (step 12).

---

## Every message that waits for the user

Any message after which you need something from the user (Phase 0's questions, the end of Phase
1, the plan in Phase 2, a step in Phase 3 that needs a decision) has the same shape, and nothing
else in it. Phase 0 is no exception: its section says what fills each slot, and its decisions go
through the dialog like every other phase's.

```
**Where we are:** <one line: what just finished, what it found in a sentence>

**Decisions** (reply like `1B, 2A`):
1. <title> — <one line on what differs>
   A) <option> — <its exact effect>
   B) <option> — <its exact effect>
   C) <option> — <its exact effect>
   Default if you skip it: <letter, or "none: needed before <step>">

**Questions** (a short answer each; skip any to take its default):
3. <question> — default: <value, or UNVERIFIED>

**Full report:** <path> (opened in your editor)

**Next:** <exactly what happens after the reply, and what is written, if anything>
```

- **Choices, not open questions.** Anything with a known set of answers is a decision with
  lettered options, each stating its effect. Number decisions and questions in one sequence, so
  a reply like `1B, 3: Vercel` is unambiguous.
- **A conflict between the user's existing instructions and the template** is always offered as:
  **A) keep yours** (their rule replaces the template's, and "Project Rules" records it as a
  deliberate override of that rule); **B) use the template's** (their line is dropped);
  **C) combine**, with the combined rule written out in full (for "commit after each logical change"
  against "never commit unless asked", for example: "commit after each logical change when the user
  has asked for commits in this session"); **D) something else**, in the user's words.
  Default if you skip it: C when a combined rule can be written, otherwise A. Two or more
  conflicts are one decision: "A) take the resolution proposed for each (listed in the report);
  B) change some: name them (`1B: 3A`)", default A.
  Choosing A also edits every other line of the template that refers to the replaced rule (a
  heading, a "same class as …" cross-reference), so the filled file never contradicts itself;
  the Step 1 report lists each line edited.
- **Every decision has a "Default if you skip it" line, and the dialog is for what a user would
  not always take.** A choice with a safe default the user would almost always take (where an
  agent's overlap goes, an `AGENTS.md` import, startable issue states, a docs path, a branch name)
  is not asked: it is listed in the report under **Defaults taken**, each with its evidence and
  how to change it ("say 'replace my ship skill'"), and named in one line of **Where we are**.
  Related decisions are one decision. "none: needed before …" is allowed only for the invariant
  (b), the read-only first pass, and approving Step 1's drafts and step 2's roster; and, on the
  same footing, approving step 3's folder list when it proposes at least one folder (its own gate
  cannot be skipped). With
  nothing proposed, step 3 has no decision: it is a done line ("considered, nothing proposed").
- **Recommendations** follow (h): with `always`, each decision ends with "Recommended: X, because
  …"; with `on-request`, or before (h) is answered, the options are listed neutrally. **A
  decision with no default still gets guidance, whatever (h) says** (the invariant, a draft):
  the user must pick before the onboarding can go on, so it ends with "Recommended: X, because …
  (this decision has no default)", with the reason drawn from the repository's evidence. A fixed
  option wording that says "(recommended)" says "(the default)" instead under `on-request`. For a
  conflict under `always`, recommend C) combine when a combined rule can be written.
- **Ask through the harness's question dialog** when it has one (Claude Code: the
  `AskUserQuestion` tool), right after the message, so every decision is a click, not a reply to
  parse. One dialog question per numbered item, its header the item's number and a short title
  ("1 Commits"), its options the item's lettered options, **each label starting with its letter**
  ("A) Keep yours"), so a letter named anywhere (in a recommendation, in the report file) points at
  the option that carries it; the recommended option is marked by its letter (in a multi-select,
  every recommended option is). The first option is always A. The dialog adds its own free-text
  "Other", which stands in for "something else" and "in your own words".
- **A finding is never folded into an option.** Something the first pass found that needs
  attention (a hardcoded secret, a failing check, a missing guard) is reported as a finding in the
  report file and, when it needs a decision, as its own numbered decision; an option's description
  says only what choosing that option does. A finding about secrets or sign-in (a hardcoded key,
  a fallback secret, an auth check that fails open) is always named in **Where we are** and becomes
  a proposed follow-up by default (say "note it only" to drop that). It is cited by file and line
  only, never with the secret's value, in a report, a draft, a follow-up or an issue. A free-text question gets options in plain words: the
  likeliest answers the agent can name (each with its effect), and "Not sure yet — decide later";
  the user's own answer comes through "Other".
- **Plain words everywhere the user reads: the question, its short header and its options.** A
  setting name (`CRITICAL_GLOBS`, `TYPECHECK_CMD`, `UNVERIFIED`), a file pattern or a term of art
  is what the agent writes, not what the user reads. Ask what the setting decides, in the user's
  terms: not "Critical globs for the test-engineer?" but "Which parts of the code are critical
  enough that every change there needs a dedicated test review and real end-to-end tests before
  it merges?", with options naming the parts ("Sign-in and accounts (`src/app/routes/auth/`)",
  "The database schema and migrations (`src/prisma/`)"), the paths only in brackets. If a term
  has no plain substitute, explain it in one clause in the question itself. This holds for every
  question asked during the onboarding, including the ones an installed skill asks while it runs
  in Phase 3 (a roster, a review setting, a command).
- **A check command is tried once, read-only, before it is listed.** This covers the commands the
  repository defines and any the agent proposes. For a check that only reads (a type check, a
  lint without `--fix`, a test run), run it **once**, and only **inside the onboarding worktree**,
  after Step 0 and after its dependency install has finished (never in the primary copy); with the
  toolchains' automatic downloads switched off (`GOTOOLCHAIN=local`, `UV_PYTHON_DOWNLOADS=never`,
  `npx --no-install`, and the same for any other tool that fetches a runtime or a package on
  first use). **When:** each check is tried exactly once, right after Step 0 (after its dependency
  install, if any); the step that installs its skill (step 4, step 6) reuses that result and never
  tries it again. Before Step 0 a check is "not tried yet: tried after Step 0", and Step 1's drafts
  name a check with that status. With the dependency install skipped (plan answer B), a check
  that needs no install (a secret scan, `shellcheck`, `semgrep`, `go vet` on vendored code) is
  still tried once after Step 0; only the ones that need it stay "not tried: install skipped". Say what happened in
  the follow-up ("tried: 0 errors, ready to switch on", "tried: 12 type errors"), and report a
  failure caused by something missing on this machine apart from a real failure ("fails only
  because Docker is not running", "needs a database: `DATABASE_URL` is not set", "needs Python
  3.12, not installed"). A command that writes (a fix, a format, an install, a migration, a code
  generator) is never tried just to list it. Whatever the result, the command becomes a proposed
  follow-up, never a gate (see "The first install never blocks itself"). A command that runs the
  whole test suite, or the end-to-end suite, is not tried when the repository sends suites to run
  elsewhere (a remote test dispatcher, or docs that warn against full local runs): say why.
- **Never ask what the agent can find out.** A question whose answer is in the repository or this
  session (the harness command, the model running now, a file's contents) is a [repo] finding to
  confirm, not a dialog question: it is listed in the report with its answer and evidence, and the
  user corrects it only if it is wrong. The dialog
  takes at most four questions at a time and two to four options each: put items that block the
  next step first, and run a second dialog for the rest. The message numbers every item once; a
  second dialog keeps those numbers (an item numbered 5 in the message is "5 …" in whichever
  dialog asks it). Without a dialog
  tool, the reply format in the message is the way to answer.
- **Detail goes in a file, not the chat,** and the file stands on its own. It opens with the same
  **Decisions** and **Questions**, numbered and worded exactly as in the message, with their
  options and defaults, and a line on how to answer ("answer in the dialog, or reply in the
  session like `1B, 3: Vercel`; you can also write your answer after an item here and say
  'answered in the file'"). Then the findings tables, evidence, the existing-instructions table
  and drafts. Someone who reads only the file misses nothing. It lives inside the repository's git
  directory, where it is never committed:
  `<report folder>/<name>.md`, where the report folder is
  `$(cd "$(git rev-parse --git-common-dir)" && pwd)/humanmaxxing` (an absolute path:
  `--git-common-dir` alone may print just `.git`) and the names are fixed: `questions-report.md`
  (Phase 0), `first-pass-report.md` (Phase 1), `plan.md` (Phase 2), `step<N>-report.md` (a
  Phase 3 step that needs a decision, the audit, follow-ups and merge steps included),
  `follow-ups.md` (every proposed follow-up, kept as they come up), `getting-started-progress.md`
  (the ledger, Phase 3), `feedback.md` (see "Feedback to the maintainers"), and `drafts/` for
  drafts. Open the first report for the user without waiting on it: `code <path>` when the `code`
  command exists, otherwise the system opener (`open` on macOS, `xdg-open` or `wslview` on
  Linux), started in the background; if none works, give the path.
  Never open one in a session with no display (over SSH, Linux or WSL with no display set) or a
  non-interactive run (no terminal on standard input, or a session started by a script or by
  another agent). When a
  report did open, the first message's line reads "opened in your editor; say 'no editor' to get
  paths only" (asked once); when nothing opened, it reads only "**Full report:** <path>", with no
  "no editor" clause. The chat message stays short enough to answer at a glance.
- **Use the wait.** Before sending, do the read-only work that does not depend on the answers (at
  the end of Phase 1, draft the Phase 2 plan with the defaults into the report), so the reply is
  folded in rather than started from scratch. Say so under **Next**.
- **An answer can arrive at any time,** in the dialog, in the chat or in the report file,
  including in the middle of a phase. Take it, confirm it in the next message's **Where we are**
  line, and never re-ask it. "Not sure yet — decide later" is an answer too: it becomes an open
  item in the plan and is not asked again in this onboarding.

---

## Phase 0 — The questions, and approval for a first pass

Send **one message** in the layout of "Every message that waits for the user", its slots filled like
this:

- **Where we are:** the verdict line (see "Before you begin").
- **What the onboarding needs** (an extra section between Where we are and Decisions): each
  question below as **one line**: letter, title, tag, and when a [you] part is asked ("(c) Stack and
  frameworks [repo]"; "(h) Recommendations [you]: a stated default below"; "(b) The one thing that must
  always be true [repo, you]: candidates after the first pass"). Letters here; numbers belong to
  the decisions. A [repo] question is listed, not asked (its full wording would read as a question).
  Nothing is asked twice: no question appears both here and as a decision. **[repo]** = the first
  pass answers it (from the repository, its history and host, or this session's environment) and
  the user only confirms; **[you]** = only the user can answer; `[repo, you]` (the order means
  nothing) tags each part, and each part says when it is asked. A [repo] question the first pass
  cannot settle comes back as a follow-up.
- **Decisions:**
  1. **First pass** — in these words or close: "Approve doing a first pass to answer as many of
     these as I can from the repository? It is read-only: files, git history[, and read-only `gh`
     queries]. Then I'll come back to you with what I found and any follow-up questions."
     The bracketed part is said only when `gh` will be used (below). A) approve the read-only first
     pass; B) no: ask me the [repo] questions directly. Default if you skip it: none: needed before
     the first pass. Under it, one line on `gh`. **Check the remote's URL
     first** (`git remote get-url <remote>`), before any `gh` command:
     - A GitHub host (`github.com`, or a GitHub Enterprise host `gh` is configured for) → run
       `gh auth status`. Missing or not signed in, or not usable in this session (no network, or
       a policy against it: "`gh` not used in this session (no network)") → say so, and which
       questions that makes follow-ups. Fine → "gh is signed in; whether it can read this repository's protection,
       issues and boards is reported after the first pass."
     - Not on GitHub (a local path, another host) or no remote → no `gh` command runs at all. Look
       for GitHub evidence of **this user's own** instead: a GitHub URL among this repository's
       remotes (`git remote -v`), or pull-request merges (`Merge pull request #12 from …`, a
       `(#12)` suffix on a squash merge) whose author is this git user (`git config user.email`
       or `user.name`; GitHub itself is the committer of a web merge). An upstream's pull-request
       numbers, `.github/` folder or merge-queue config in inherited history are not evidence.
       Found → "the remote is not on GitHub, but your history shows GitHub pull requests: this
       may be a copy of a GitHub repository; Phase 1 asks". None →
       "gh is not used: the remote is not on GitHub", and which questions that makes follow-ups.
     Never install `gh` or sign in on the user's behalf.
  2. **Feedback notes** — "May I keep notes on where these instructions are unclear or make me
     guess? They stay on this machine; at the end you see the exact text and decide whether to
     send it to the HumanMaxxing maintainers." A) yes, keep notes; B) no.
     Default if you skip it: A (keeping notes sends nothing: sending is a separate approval of the exact text). See "Feedback to the maintainers".
- **Defaults taken** (one line each, under Decisions): (h) "Recommendations: only when you ask
  (say 'always recommend' to change it)"; (i) "No mechanical guard (lint rule, check script, hook)
  before the 7th fix of the same bug; every fix still gets its class-level test (say 5 or 3 to
  change it)"; "Agent budget: Parallel: independent work goes to parallel
  agents, with no count cap but no worker that costs more than it saves (say 'frugal' to keep
  spend low, or 'max parallel' for speed; you can also switch in any session)".
- **Questions:** none in this message. The other [you] parts (the invariant (b), which issue states
  may be started (e2), the hook wiring (j)) need the first pass's findings and are asked at the end of Phase 1.
- **Full report:** `questions-report.md`: the whole message, every question below in full, and how
  to answer (in the dialog, in the session, or by writing the answer under a question in the file
  and saying "answered in the file"); then anything else the user asked for in their opening
  message.
- **Next:** "Answer the two decisions (the dialog is open); I'll start the read-only first pass as
  soon as you approve it." With no dialog tool in this session, the bracket reads "(answer by
  reply; no dialog in this session)", and no dialog follows the message.

**Then ask through the dialog**, right after the message, never instead of it.
One dialog, two questions: decisions 1 and 2, same numbers and letters, headers "1 First pass"
and "2 Feedback". The invariant (b) is not asked here, and no
[repo] question is (see the tags above).

The questions:

- **(a) What is the project?** [repo] Domain + one paragraph of what it does, drafted from the
  README and the code; the user corrects it in the Phase 1 report.
- **(b) What is the domain's non-negotiable invariant?** [repo, you] — the one property that can
  never silently drift (a billing system's: "every cent exact, always"). Asked in these words or
  close to them: "What is the one thing that must always be true in this app, whatever else
  changes? Every review, test and agent will check each change against it, so pick the failure
  that would hurt most and that a passing test run would not catch."
  - [repo] the first pass drafts two or three candidates from what the code handles (user accounts
    and tokens → "user data never leaks"; money → "every amount exact"; concurrent writes →
    "correct under concurrency"), each with its evidence, and checks each against the code before
    offering it: an exception found (sign-up and login need no sign-in, an admin path) is written
    into the candidate. **Every name in a candidate (an env var, a column, a script, a path, an
    exception) cites the `file:line` you read it at**; a name you cannot cite is left out, never
    guessed.
  - **A later finding against the chosen invariant** (the step 10 audit, or any step): a wrong
    *name* in a candidate the user picked (the code reads `APP_ENV`, the invariant says `ENV`) is
    corrected like any plain error, without a question, and the step's message says so: "invariant
    corrected: `ENV` → `APP_ENV` (`config/settings.py:12`)". A finding that changes what the rule
    *means* (a wrong exception, a wrong scope), or any change to the user's own words, is one
    decision: **A) use the corrected wording `<text>`** (default) **/ B) keep it as is** (the
    finding becomes a follow-up).
  - [you] the choice, or the user's own words: asked at the end of Phase 1 as a decision, not in
    Phase 0. **It cannot be defaulted** (see "The one thing this file will not guess"). The user's
    own words are recorded verbatim and changed only through the decision above.
- **(c) Stack and frameworks** [repo] — language(s), web framework, database, package manager.
- **(d) Where is it hosted / deployed?** [repo] No deploy configuration that names a host (none at
  all, only a `Dockerfile`, or a chart or manifests with no named cluster) → a Default taken in
  Phase 1, "not deployed yet" (say the host to change it), and a follow-up naming the hosts the
  stack points to (from the survey), "a container host, not named in the repository" among them
  when the repository builds an image. It is not a Phase 1 decision.
- **(e) GitHub and tracking** [repo] — the remote, PRs, branch protection, a merge queue, the branch
  naming convention (a prefix such as `feature/`, read from existing branch names), and where
  issues/tickets live (a board, a tracker, nowhere yet). A tracker outside the repository host that
  the history does not reveal becomes a follow-up.
- **(e2) Working folders and issues** [repo, you] — every task gets its own folder (a sibling
  worktree) beside the primary working copy, which stays on the integration branch. Not asked: the
  worktree skill, `maxx-start`, `start`'s guard, parallel ships and parallel sessions depend on it.
  (A single-checkout setting exists for repositories that cannot use worktrees; it
  is never offered, and is set later by hand if ever.) Starting work on an issue always does four
  things: refuse an issue not in a startable state (unless forced), assign it to whoever starts it,
  move it to in-progress with a comment naming the branch, and push the branch. So:
  - [repo] the tracker's states (a board's status options, labels).
  - [you] which states may be started and which one means in progress: a stated default from the
    states found (Backlog and Ready; In progress), changed by naming others. No tracker → none.
  - [repo] whether there is a remote; the command that installs dependencies in a fresh folder; the
    local files git does not carry that a fresh folder needs (an env file in the primary copy now).
- **(e3) Your agent command and its models** [repo] — the command a new session starts with (this
  harness's, for example `claude`) and its model names for the three tiers, cheapest / mid /
  strongest (Claude Code: haiku / sonnet / opus; fable replaces opus only when this session runs on
  fable or the user names it, never by guessing what the account can use). They fill the worktree
  skill's launcher and `CLAUDE.md`'s tier map. No other model is asked: the template's "Subagent
  Model Selection" table picks one per task (no "worker model"), and each generated agent's model
  comes from its archetype's tier.
- **(f) Environments** [repo, you] — dev/staging/prod, or just one?
  - [repo] the environments and their branches, from deploy configuration and branch names. A setup
    that only runs on a developer's machine (a local cluster, a compose file) is not an environment
    and is not asked about.
  - [you] only when environments exist without a branch of their own: does each deploy from the
    integration branch, or will it get a branch (and its name)? A stated default: it deploys from
    the integration branch, and no branch is named that does not exist.
- **(g) Test infrastructure and CI provider** [repo], if any.
- **(h) Do you want the agents to always recommend an option?** [you] A stated default (no),
  changed whenever the user says so. Yes: every choice an agent
  lays out ends with a recommendation and its reasoning. No: options are laid out neutrally, with a
  recommendation only when you ask.
- **(i) Repeat bugs: how many fixes before a mechanical guard?** [you] Asked in these words or
  close to them: "Some bugs come back after they're fixed, often in a different place. Every fix
  already sweeps the other places with the same bug and adds a test over all of them, and routing
  the code through one shared helper is always allowed. A mechanical guard is more: a lint rule, a
  check script, a hook or a CI step that scans every later change. It costs time and false alarms
  on every change after it, so it is earned by repeats: below the number you pick, a fix adds no
  mechanical guard, only its test. How many fixes of the same kind of bug, this one included,
  before a fix may suggest one?" A stated default the user can change at any time, among **7**
  (the default: guards stay rare, which is what holds up when many agents ship many fixes),
  **5**, or **3** (guards come sooner, and there will be many more of them). Another whole
  number is fine if the user names one.
- **(j) Automatic guards** [repo, you] — where step 8's hook wiring lives, asked at the end of
  Phase 1 when step 8 is in the plan: **A) shared with the team** (`.claude/settings.json`,
  committed: everyone who opens this repository in Claude Code gets the same guards); **B) this
  machine only** (`.claude/settings.local.json`, not committed). Default if you skip it: A. Which
  check the commit check runs is not asked here: step 8 shows its candidate (from the checks the
  first pass tried, a secret scan among them) in its one decision, and the first install wires it
  in warn mode only, so it reports and never refuses a commit.

**Wait for the approval before the first pass.** The [you] answers may come in the same reply, later,
or partly; never hold the first pass for them.

- **Approved** → Phase 1.
- **Neither** (the reply answers some questions but neither approves nor declines) → keep the
  answers and ask in one line only: "Approve the read-only first pass, or should I ask the remaining
  questions directly instead?" Do not start the pass, and do not re-ask what was answered.
- **Declined** → ask the [repo] questions as plain questions in one message, take the answers as
  given (marked "from the user, not checked" in the plan), and go to Phase 2 once they and the [you]
  answers are in. The bootstrap skills still survey for themselves when they run.

**Phase 0 ends** at that approval or refusal. Say which in one line and go straight on.

**Slot map — where each answer (and everything it doesn't cover) actually lands:**

| Template slot | Source |
|---|---|
| Where the filled files land | Not asked. `CLAUDE.md` is created at the **repository root** of the folder the onboarding works in (the Step 0 worktree), in Step 1 of Phase 3; its long-form companion goes at the details-file path below. Nothing is written into the downloaded copy |
| Domain invariant | (b), verbatim, refused if skipped; changed later only as (b) says (a wrong name corrected, a change of meaning one decision) |
| Integration / staging / prod branch names, feature-branch prefix | (e) + (f). An environment with no branch of its own gets no branch name: the template's branch list drops it and its "Promotion" line states the real flow ("feature → main; production deploys from main"). The branch-name pattern is the one most recent branches follow, whatever its shape (`feature/<slug>`, `<issue>-<slug>`, `<name>/<slug>`); the template's example is only the fallback when no pattern dominates (`feature/`). The onboarding's own branch (Step 0) is `<prefix>agent-onboarding` with that finding's prefix (`feature/agent-onboarding` on the fallback; `agent-onboarding` where the shape starts with an issue number or has no prefix) |
| `WORKTREE_LAYOUT` (the `start` skill) and every key in the worktree skill's `worktree.env` except the launcher keys | (e2). `WORKTREE_LAYOUT=siblings`, always: not asked; `single` only when the user asks for it unprompted, with a reason the plan records. (`start` itself still stops and asks when `WORKTREE_LAYOUT` is unset or `UNVERIFIED`, for installs made without this file.) The integration branch name fills five places from the one answer: `BASE_BRANCH` in `worktree.env`, `BASE_BRANCH` in `ship.env`, `BASE_BRANCH` in `retro.env`, `INTEGRATION_BRANCH` in `start`, `INTEGRATION_BRANCH` in `bootstrap-claude-mds`. The issue guard, claim and push are always on when the repository has a tracker the agent can drive. On GitHub the example file's lines stay (`bin/worktree-issue.sh` in `ISSUE_TITLE_CMD`, `ISSUE_GUARD_CMD`, `ISSUE_CLAIM_CMD`; `PUSH_ON_ISSUE=1`), and the confirmed states fill `ISSUE_PROJECT` (the board as `<owner>/<number>`), `ISSUE_STARTABLE` and `ISSUE_IN_PROGRESS`; another tracker gets its own commands in the three slots. With no tracker or no remote the whole issue group is emptied, not left at the example's values: `ISSUE_TITLE_CMD`, `ISSUE_GUARD_CMD`, `ISSUE_CLAIM_CMD`, `ISSUE_PROJECT`, `ISSUE_STATUS_FIELD`, `ISSUE_STARTABLE` and `ISSUE_IN_PROGRESS` empty, `PUSH_ON_ISSUE=0`, one comment line above the group saying why, and the plan says so; `UNVERIFIED` where they did not answer. `COPY_FILES` lists only files that exist in the primary copy now; a file the team will add later goes in a comment line above it, so the first create does not warn about a missing file. `POST_CREATE_MODE` keeps the example's value (`wait`) and is not asked; Step 0's own create passes `--background`. A copy of a GitHub repository (Phase 1, "A remote that is not on GitHub", A) adds `GH_REPO=<owner/repo>`, the named GitHub copy, so every `gh` call targets it and not the local remote (`gh` reads `GH_REPO` itself too); otherwise `GH_REPO` stays empty |
| Docs root, details-file path, todo-file path | Not asked. Phase 1 checks for an existing `docs/`; if none, propose a default and confirm it at Step 1, never a silent guess. No todo file → none, and the template's todo line is removed |
| The details file's "Documentation Structure" section | Not asked: the survey's docs layout, written in as it is (its folders, its naming) and shown as a diff at Step 1; the template's tree is offered only when the repo has none, and the user may change it |
| `IAC_TOOL`, `IAC_PLAN_CMD`, `CI_PROVIDER` (details file) and the "When Deploy or CI Fails" section | (d) + (g), checked by the survey. At Step 1 the section keeps the generic steps, gets commands for the detected tool, keeps only the gotcha blocks for this cloud and CI provider, and loses its infrastructure subsection when there is no IaC. Never left as the template's Terraform/AWS example for a repo that uses something else |
| `<YOUR-MODEL-TIERS>` (`CLAUDE.md`), `START_CMD` / `START_MODELS` / `START_DEFAULT_MODEL` (`worktree.env`) | (e3), from the first pass: the tier map from the harness's model names; `START_MODELS` lists them all, `START_DEFAULT_MODEL` is the strongest tier as (e3) defines it (a different model is a word on the command line: `maxx-start sonnet 123`). Confirmed in the Phase 1 report, never asked as a separate question |
| `<YOUR-HOOK-LIST>` | Step 8: the installed hook scripts' paths and the settings file that wires them. Step 1 deletes the template's hook paragraph in "SESSION START" and its hook line in "Reference", as the template's own notes there say, and keeps the deleted text in `drafts/`; step 8 writes them back from there, filled, when it installs at least one hook (shown as a diff): the value written without backticks of its own where the template already wraps the placeholder in a code span, the paragraph's conditional clauses ("with none of your own, drop this clause", "(No hooks installed yet: delete this paragraph …)") pruned, and the Configuration block's `HOOK-LIST` line updated to the same value. Every hook declined → they stay deleted and the ledger records `skipped (declined at step 8)` |
| `COMMIT_CHECK_CMD` (`.claude/hooks/hooks.env`) | Step 8: the candidate shown in its one decision (a check the first pass tried that needs no install and ran clean, a secret scan first), with a `#` line above it saying it runs in warn mode; no such candidate → empty, with a `#` line above it saying why, and the commit check reports that it has nothing to run. In warn mode it only prints what it would have refused; the follow-up "switch the guards on" (step 11) makes it refuse |
| Hook wiring: `.claude/settings.json` or `.claude/settings.local.json` | (j), default A (`.claude/settings.json`); not asked again at step 8 |
| Template sections that do not apply | Not asked. A section of either template written for something this repo does not have (a tracker, a browser UI, a merge queue, an infrastructure tool, an SDK) is removed at Step 1, not kept as the template wrote it (the details file's "Context Optimization Hooks" section is never removed here: the hooks pack arrives at step 8, after Step 1, and that section says how to install or reinstall it); a pointer to a file the onboarding does not create (a dev-reference doc, a todo file) is pointed at a file that exists (the README) or removed. Removing a section of `CLAUDE.md` also removes the details-file section it points to, and every other line that names either (grep both files for the heading and its anchor), so nothing points at a section that is gone. The Step 1 report lists every removed section and pointer with its reason, so any of them can be added back from the template. "Out-of-Scope Subsystems" is not removed silently: when the first pass found a candidate (a component the code treats as external or best-effort), it is a question at Step 1 ("<component> in `<path>`: is it out of scope for the core system?"); with none, the section goes |
| The template's opinionated defaults | Not filled silently. Each of these is checked against the repository's own evidence (its instruction files, CI config and comments, check scripts, procedure docs): small unrelated fixes folded into the current PR or split into their own; when a fix adds a class guard and of what kind (a lint rule, a test, a CI check), and whether new CI checks are welcome at all; `set -o pipefail` as the way to capture exit codes; what "protected" means for a file. Evidence of a different team practice → a conflict, offered like one from an existing instruction file (A–D); no evidence → the template's rule, listed in the Step 1 report as "template default, nothing in the repository says otherwise" |
| Protected files | Not asked directly. Phase 1 proposes candidates: anything that looks like a schema or state-version marker, a pricing table, a kill-switch config, and every file the repository itself guards (a CI workflow or check script that fails when the file changes, a label a change to it needs, a "never edit" note in its docs or at the top of the file, a generated file, a sole-owner CODEOWNERS entry, a file only bots commit to, a CI baseline: the commands are in Phase 1's "Guards, checks and decisions"). A candidate is a single file or a small fixed set, never a whole folder of routine work (a migrations folder agents add to every week is not protected; a marker file whose change forces a rebuild is). The user confirms or names their own at Step 1; steps 2 and 3 can add candidates (Phase 3, "Later steps can reopen earlier lists"). `.claude/settings.json` and `.claude/settings.local.json` are not offered: the guard always protects them, listed or not (they can switch the hooks off with `disableAllHooks`), as it does the hooks folder and the list itself; the report says so. Step 1 writes the confirmed list to `.claude/protected-files.txt`, one glob per line with each file's reason on a `#` line above it. Each glob is spelled the way the guard reads it: a path from the repository's top, `*` and `?` staying inside one folder, `**/` spanning folders (a whole folder is `config/**`); no leading `./` or `/`, no trailing `/`, no `{a,b}`, no `[..]`, no `!negation`, no `#` after the glob on its line, and not all wildcards. The guard treats a list with any of those as broken (it then asks about every call), so step 8's installer plan refuses such a list and names the lines to fix. That file is the one list: `<YOUR-PROTECTED-FILES>` in `CLAUDE.md` and the `PROTECTED_FILES` values of `ship` and `review-code` point at it instead of repeating it, and step 8's guard reads it |
| Tenant key | Not asked. Phase 1 greps for it (as `bootstrap-agents`' own survey does); "not detected" is a legitimate answer, not a gap to guess at. Not detected → Step 1 removes the "Multi-tenancy" line of Key Guardrails (a single-tenant app has no tenant key), and the Step 1 report says so. A key spelled differently in different stores is recorded with each spelling and where it applies |
| `checkpoint`'s folders: `SESSION_SUMMARY_DIR`, `PLAN_ARCHIVE_DIR`, `REVIEW_FINDINGS_DIR`, `CHANGELOG_DIR` | Not asked. The repository's own folders when the docs layout has them; otherwise `<docs root>/sessions/`, `<docs root>/plans/`, review-code's `FINDINGS_LOG_DIR`, and empty (no changelog fragments) for `CHANGELOG_DIR` unless the repository keeps them. Nothing is created until the skill first writes there |
| `TRACKER` (`review-plan`, `review-code`, `retro`) and `ISSUE_CMD` (`start`) | (e): `github` when issues live in this repository's GitHub issues, otherwise `none`. With `none`, `start` takes a task described in words instead of an issue number (its `ISSUE_CMD` empty, with a comment line above it), and the review skills list proposed tickets in the conversation instead of filing them |
| `CRITICAL_GLOBS` (`review-code`, `ship`, `checkpoint`, the test engineer) | The paths the user confirms as critical, asked once, at step 2 (bootstrap-agents' roster). Written into `.claude/critical-paths.txt` as `# off: <glob>` lines (see "The first install never blocks itself") by `ship` at step 6, or by `review-code` at step 7 when `ship` is skipped. `checkpoint` reads the same file (its `CRITICAL_GLOBS_FILE` = `.claude/critical-paths.txt`, the file step 6 or 7 writes; never a second copy; checkpoint is not run on the install, so the file exists before its first use) only when its `TEST_GLOBS` is filled: a named list with no test globs halts every checkpoint, so with no test globs `CRITICAL_GLOBS_FILE` stays empty, with a comment line above it naming the follow-up that fills both, and its test-update guard prints "not configured". With the install's all-`# off:` list the guard passes ("nothing is critical"), so it never halts the first checkpoint |
| `TEST_GLOBS` (`checkpoint`, `ship`) | Not asked: the test-file globs Phase 1's test-signal check found (`**/*.test.ts tests/** **/*_test.go`, in git's glob spelling, space-separated), the same value in both skills; empty when the repository has no tests, and then `checkpoint`'s `CRITICAL_GLOBS_FILE` stays empty too (above) |
| `REVIEW_GATE` (`ship`) | Not asked: `sentinel` whenever step 7 installs `review-code` (the review's own sentinel is the proof, never the agent's word); `manual` only when step 7 is skipped or the user kept their own review skill, with the two manual-mode lines of step 6 |
| `DEV_SERVER_PATTERN` (`checkpoint`) | Not asked: a `pgrep -f` pattern for the dev server Phase 1's "Ports and dev servers" found (its command, for example `next dev` or `vite`); with one running from the folder, checkpoint skips the build and reports it skipped, never passed. Empty when the repository has no dev server: the build always runs |
| `MAX_REVIEWERS` (`review-code`, `review-plan`) | The onboarding's last question (step 12), once the roster exists: 5, 3 or 7, a hard total of reviewer agents per review; default 5, and not asked when the roster has no more reviewer agents than that |
| `LENS_WEIGHTS`, `SMALL_DIFF_SCORE`, `REVIEWER_STEP_SCORE`, `LENS_MIN_SCORE`, `LENS_CHECK_<agent>` (`review-code`) | Not asked: the skill's defaults (weights `critical=3 code=1 config=1 test=0.5 docs=0.1`, bonuses `new_exec=25 permission=25 gate=40 deleted=10`; 60; 150; 40), and a lens's mechanical check only where the repository has one for that lens (its leak or lint script) |
| `TOKEN_BUDGET_MODES` (details file) | Not asked: the template's three modes kept as they are (Frugal / Parallel / Max Parallel, Parallel the default), listed under Defaults taken; a user who named their own modes in an instruction file keeps theirs (Step 1's merge) |
| `peer-review` (step 7) | Not asked. `GH_REPO` as in `worktree.env` (step 0 writes it, or the (e2) answer when the user kept their own `worktree`; `ship.env` is missing when `ship` is skipped); `PR_REMOTE` = `origin`, or the GitHub copy's URL when `GH_REPO` names a repository origin is not; `BASE_BRANCH` from (e); `CRITICAL_GLOBS_FILE` = the same `.claude/critical-paths.txt` review-code uses; `TRACKER` from (e), as for `review-code` (`retro.env` is written later, at step 9); `KNOWN_DEFERRALS` and `COMPONENT_ALIASES` = `see .claude/skills/review-code/SKILL.md`; `PROTECTED_FILES` = `see .claude/protected-files.txt`; `TENANT_KEY` from the invariant when it names one, else empty; `REAL_TEST_KINDS` from Phase 1's test-signal check, else empty; `HUNK_RATIO` and `VERDICT_MAX_CHARS` keep their worked defaults; `MERGE_METHOD`, `QUEUE_LABEL` and `MERGE_FLAGS` = `see ship.env` when `ship` is installed (one copy, never two), else the merge method, queue label and merge flags Phase 1 read from the repository (empty `MERGE_METHOD` when it settled none: a requested merge then stops and asks) |
| `TIMEBOX` (`review-code`), `DOMAIN_AGENTS` (`start`) | Not asked: review-code's worked default; `DOMAIN_AGENTS` has one row per domain-expert agent step 2 generated: its detection globs as the signal, the first clause of its description as the investigation angle; never written by hand |
| `COMMIT`, `AUTOSTASH`, `PUSH` (`checkpoint`) | Not asked: step 4 maps them from the installed `CLAUDE.md`'s rules, found by their text, not by line: the Commits and PRs rule that commits wait for the user's ask → `COMMIT=ask`; Tool Discipline's "No hand-rolled `git stash` or `pop`: use a WIP commit" → `AUTOSTASH=no`; Commits and PRs' "Never push unless the user asks" → `PUSH=ask` (`never` with no remote). A rule Step 1 replaced with the user's own (a conflict answered A or C) maps from that rule instead |
| `<YOUR-FAIL-LOUDLY-EXAMPLES>` (`CLAUDE.md` #1 RULE) | Not asked: the stack's own silent-failure forms, from (c) (Go: an error assigned to `_`; Python: a bare `except: pass`; JavaScript or TypeScript: an empty `catch`, `?? {}` or `\|\| []` hiding a missing value), each a short code span; a repository with several stacks lists each stack's |
| `checkpoint`'s `allowed-tools` | Not asked. The skill ships with git, `date`, `mkdir` and the exact `gh` commands its steps use, only (`gh pr view`, `gh pr list`, `gh project field-list`, `gh project item-edit`: it is commit-only, so no command that opens, watches or merges a pull request; that is `ship`'s); step 4 adds exactly the commands its filled slots use (none during the install: the check slots stay empty), and a follow-up that fills a slot adds its command in the same edit. Never a whole-suite or stack-wide pattern (`npm test*`, `npx *`, `go test *`) where Phase 1 found suites run elsewhere |
| `REMOTE_TEST_DISPATCH`, `UNIT_TESTS_IN_REVIEW` (`review-code`) | Phase 1's test-signal check. A remote test dispatcher found → `REMOTE_TEST_DISPATCH` is that command and `UNIT_TESTS_IN_REVIEW=ci`. None → `REMOTE_TEST_DISPATCH` empty and `UNIT_TESTS_IN_REVIEW=local` |
| `<YOUR-RECOMMENDATION-MODE>` | (h): yes → `always`, no → `on-request`. In Step 1, keep only the matching closing paragraph of the template's "#3 RULE" (between the `RECOMMENDATION-MODE` markers) and delete the other paragraph and the markers. Not answered → `on-request`, and the plan says so |
| `<YOUR-CLASS-GUARD-THRESHOLD>` | (i): 7, 5 or 3 (or another whole number the user names). Not answered → `7`, and the plan says so. It is a floor, not a trigger: below it a fix adds a class-level test and no mechanical guard. Filled in place, with the line left as it is: the `retro` skill reads the number from the rule's sentence ("this fix included, reaches `7`"), so a reworded or rewrapped sentence leaves its repeat-bug check without a threshold |
| `retro.env` (the `retro` skill, step 9) | Not asked. `GH_REPO` as in `worktree.env` (the named GitHub copy, or empty), and the same in `ship.env`; `BASE_BRANCH` from (e); `BASE_REMOTE` = `worktree.env`'s `BASE_REMOTE` value (empty with no remote); `TRACKER` from (e)'s answer to where issues live: `github` when they are this repository's GitHub issues, `none` for anything else (another tracker, nowhere yet), because GitHub issues that exist but go unused would read as a confident zero; `COMMIT_STYLE` from Phase 1's commit-message check, reported as a [repo] finding; `REPORT_DIR` = `<docs root>/retros`; `FINDINGS_DIR` = review-code's `FINDINGS_LOG_DIR` (step 7); `RELEASE_REPO_URL` = `git -C <download> remote get-url origin` when the download is its own git checkout ("Before you begin"), empty otherwise and always empty for a URL holding a token or password; the guard-growth keys filled, so the over-guarding direction of the repeat-bug rule is watched as well as the under-guarding one: `GUARD_GLOBS` = where mechanical guards live in this repository (the lint-rule folders, check scripts and CI check folders Phase 1's "Guards, checks and decisions" found, plus `.claude/hooks/**`), and `GUARD_BUDGET_PER_MONTH=10`, a tripwire the weekly report compares against, never a cap: a month over it means repeat counts are being inflated or the threshold needs raising, a question for the user, never a number an agent re-tunes (the first report's count includes the install's own hook files, and step 9's ledger note says so); `FIX_CHAIN_MIN`, `CLAUDE_MD` and the word lists keep the example's values. The threshold is not a key: the skill reads it from `CLAUDE.md` |
| Everything else in (a), (c), (d), (g) | Context that shapes Phase 2's ordering, not a literal template slot |

---

## Phase 1 — First pass: answer from the repository

Answer every [repo] question, and every [repo] part of a mixed one, from the repository: a lighter
version of the survey `bootstrap-agents` and `bootstrap-claude-mds` run in their own Phase 1
(`skills/<name>/SKILL.md`) before proposing anything; each re-runs its deeper version at its own
step in Phase 3. Read-only throughout: files, `git` history, and read-only `gh` queries
only when Phase 0 found the remote on GitHub. Nothing is written, installed or configured, and no
check command runs yet (see "A check command is tried once"). Each check feeds the question in
brackets:

- **Manifests and lockfiles** (c, e2) — the stack as declared and locked, the package manager and
  its install command for a fresh folder. At any depth (a nested frontend has its own):
  `git ls-files '*package.json' '*go.mod' '*pyproject.toml' '*Cargo.toml' '*Gemfile' '*pom.xml' '*build.gradle*' '*composer.json'`.
- **README and code layout** (a) — a one-paragraph draft of what the project is and does.
- **Deploy configuration** (d, f) — a Dockerfile, platform files (`vercel.json`, `fly.toml`,
  `netlify.toml`, a serverless config, Kubernetes manifests), environment-named branches, env-file
  examples (`.env.example`) and which `.env*` files git ignores (e2's local files).
- **Directory topology** — folders of tracked files at any depth with their file counts, so build
  and vendor output never counts: `git ls-files | awk -F/ 'NF>1{NF--; print}' OFS=/ | sort | uniq -c`.
  Is there a frontend, API/routes, service/domain-logic, migrations or tests dir? This decides
  whether folder `CLAUDE.md` files (step 3) or a bigger roster (step 2) can justify themselves.
- **CI config** (g) — `.github/workflows/` or another provider's: what it runs, and what it
  **guards** (below).
- **Guards, checks and decisions the repository already has** (feeds protected files, Project
  Rules, Out-of-Scope Subsystems and the follow-ups) — team rules often live outside any agent
  instruction file. Read guard workflows and CI jobs that fail on a change to one file, need a label
  before a change can merge, or freeze something (their header comments say why); check scripts
  (`scripts/check-*`, `*guard*`, `*lint*` scripts, a pre-commit config) and what each refuses;
  procedure and decision docs (runbooks, contributing guides, decision records) and their "never"
  and "always" lines; and, with `git grep -n` in the domain-logic folders,
  decision comments at the top of code files ("user decision", "do not change", "intentional:").
  Files the repository guards indirectly, each hit a protected-file candidate:
  generated files (`git grep -l -I -E 'DO NOT EDIT|@generated|auto-generated|Code generated'`,
  plus files a generator config names as outputs); sole-owner `CODEOWNERS` entries (a single file
  or small set with one owner); files only bots commit to (`git log --format='%an' -- <file> |
  sort -u` shows only a bot); and files a CI job compares against a baseline (a snapshot, a lock,
  a recorded output the job diffs).
  Route each finding: a guarded file → a protected-file candidate; a documented rule → a Project
  Rules candidate (quoted, with its file); a component the code treats as external → an
  Out-of-Scope candidate; a documented intended behaviour (a value that looks like a bug) → a note
  the invariant candidates and the generated agents must not contradict; an existing check → a
  follow-up candidate.
- **Tools on this machine** (feeds the follow-ups) — for each check slot, whether a tool that can
  fill it is installed (`command -v gitleaks trufflehog semgrep shellcheck`, the stack's own linters
  and runners), so a follow-up names a tool that exists or says what to install.
- **Infrastructure-as-code** — `*.tf`, `Pulumi.yaml`, `cdk.json`, CloudFormation/SAM templates, or
  none; the cloud they target and where the modules live.
- **Docs layout** — the folders and file naming under the docs root, if any (slot map,
  "Documentation Structure").
- **Remote, branch protection, merge queue, issues, boards** (e, e2) — `git remote -v`; with `gh`
  and access, the default branch's protection or rulesets, a merge queue, whether issues are enabled
  and in use, any project board. Name what `gh` could not read (missing, not signed in, no access to
  this repository); each becomes a follow-up, never a guess.
- **A remote that is not on GitHub** (a local path, another host) — skip the `gh` queries and ask
  one Phase 1 decision. **A copy of a GitHub repository** means: the team's pull requests, reviews
  and merges happen on GitHub, in a repository the user names (`owner/repo`), and this remote is a
  mirror or a local copy of it. Offered only with this user's own GitHub evidence (Phase 0), as:
  **A) a copy of a GitHub repository** — the user names it (a Question, "which GitHub repository:
  `owner/repo`?"), and the install is planned as on GitHub: `ship` installed (the plan says it
  needs `gh` signed in for that repository), protection, merge queue and boards read from it with
  read-only `gh … --repo owner/repo` once named (or left follow-ups), its protection counts at step
  12, and where issues live defaults to GitHub issues when its board, its issues or issue-numbered
  branches are found. The named copy is written as `GH_REPO=owner/repo` into `ship.env`,
  `retro.env` and `worktree.env` (slot map), so every `gh` call the skills make targets it, never
  the local remote; step 12 merges through it (its "mirror route"). **B) moving to GitHub**;
  **C) staying where it is**; **D) not sure yet**. Default: A with that evidence, otherwise D.
  Without the evidence only B–D are offered, relettered A–C, and written out in full: **A) moving to GitHub**; **B) staying
  where it is**; **C) not sure yet**; Default if you skip it: C. Moving: the PR steps are installed
  but unused until the move, and the GitHub settings stay open items; staying or not sure: the "No
  GitHub / no PRs" scoping rule (Phase 2), and the plan's skipped `ship` row names what moving to
  GitHub would add (the pull-request flow, merge-queue support) and how to add it later (re-run
  step 6 alone). CI configuration whose runner is tied to a host this remote is not on (GitHub
  Actions, CircleCI, …) counts as "no CI", and the report says so, except under the GitHub-copy
  answer, where it runs on the GitHub copy. Where issues live, when not settled by A's evidence, is a stated
  default ("nowhere yet": `TRACKER=none` and the worktree skill's issue group emptied, slot map),
  changed by naming the tracker. Any git remote works for Step 0, including a local bare one.
- **Branch names** (e, f) — existing local and remote branches, for the branch-name pattern and any
  staging/release branches. Count the shapes of the recent ones
  (`git for-each-ref --sort=-committerdate --count=150 refs/heads refs/remotes`): the shape most
  follow is the finding, whatever it is (`feature/<slug>`, `<issue>-<slug>`, `<initials>/<slug>`),
  with its count ("41 of 60 start with the issue number"). It is a stated default, not a question.
  No shape dominates → the template's example (`feature/`), decided now. The onboarding's own
  branch is `<prefix>agent-onboarding` with the finding's prefix (`feature/agent-onboarding` on
  the fallback); a shape that starts with an issue number names the onboarding branch without
  one, and so does a shape with no prefix (`agent-onboarding`). This is the one rule for that name (slot map, Step 0). A mirror with one
  branch: read the shapes from pull-request merge messages (`Merge pull request #12 from o/<branch>`).
- **Tenant-scoping convention** — grep for a `tenant_id`/`team_id`/`org_id`/row-level-security
  convention the way `bootstrap-agents` does (its Phase 1e); what a hit or a miss means: slot map,
  "Tenant key". With a database, also note, each with its `file:line`: whether isolation is
  enforced in the database itself (row-level security policies), whether connections go through a
  transaction-mode pooler (a pooler host or port in the connection settings), and whether a
  read-only role that sees every tenant exists for audits. These feed one follow-up (step 11),
  not a question.
- **Test signal** (g) — a test directory plus a runnable test command in the manifest/CI, or
  genuinely nothing; this feeds Phase 2's test-engineer reordering rule. Also look for a
  **remote test dispatcher**: a script or workflow that sends test suites to other machines, or docs
  that warn against running the whole (or the end-to-end) suite on a developer's machine. Found → it
  fills `REMOTE_TEST_DISPATCH` (slot map), and no whole-suite or
  end-to-end command goes into any agent's allowed commands or any check slot: agents get the
  scoped form (one test file, the tests related to a change).
- **Inherited history** — a fork or clone of someone else's project carries their history. Work it
  out, do not ask: count commits by the current git user (`git config user.name` / `user.email`,
  matched with `git log --author`) against the rest. Mixed in with other authors' (a team) →
  **ours**: the history is this team's evidence. None or almost none by this user → **inherited**:
  anything read from it (the branch prefix, which folders keep breaking) is a suggestion to confirm,
  never a fact, and step 3's churn counts are told the same. A recent commit under a name that is
  neither this git user nor the original authors (an alias, a second machine) counts as "not this
  user", and the finding names it so the user can claim it. A finding with its counts ("History:
  inherited: 64 of 66 commits by other authors, none by your git user"), not a decision.
- **Ports and dev servers** (f, details file) — the ports the repository sets: the end-to-end
  runner's config (`playwright.config.*`, `cypress.config.*`), compose files' `ports:`, the dev
  server's script or config, `.env.example`. They fill `E2E_PORT` / `QA_PORT` and the dev-server
  lines; `UNVERIFIED` only when none of these names one and the repository does not settle it.
  Where the repository settles that there is none (tests start their server in-process, no
  type-check script exists), the value is "none in this repository (`<evidence>`)", a filled
  value, not `UNVERIFIED`.
- **This session's model** (e3) — the main-session model, for the user to confirm.
- **Commit messages** (feeds step 9 and the install's own commit messages) — do most recent
  messages start with a type (`feat:`, `fix:`, `docs:`, `chore:`)? Sample about 200 without merges
  (`git log --no-merges -200 --format=%s`). Most do → `conventional`; otherwise → `keywords`
  (messages sorted by their words; `retro`'s `COMMIT_STYLE` takes exactly these
  two values). An emoji-first history is `keywords`: a picture emoji is not a word, so it is sorted
  by the words after it, and a written-out code such as `:bug:` reads as the word `bug`; the finding
  says so. A finding with its evidence ("141 of the last 200 start with a type"), not a question.
- **Existing instructions and agents** (feeds Step 1 and step 2) — every file that tells an agent
  how to work here: a root or folder `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `GEMINI.md`,
  `.cursorrules` or `.cursor/rules/`, `.github/copilot-instructions.md`, the user-level file your
  harness loads in every project (Claude Code: `~/.claude/CLAUDE.md`), and agent definitions in
  `.claude/agents/` and the user-level agents directory. Read-only; the
  user-level files are never edited. A file that is empty or holds only whitespace counts as absent
  (listed as "empty (counts as absent)"). Sort every rule in them against the `CLAUDE.md` template:
  - **duplicate** — the template says the same: it merges into the template's rule (keeping the
    user's wording where it is more specific to this repo);
  - **conflict** — it says the opposite ("commit after each change" against "never commit without
    asking"): asked as "your file says X, the template says Y — which wins?", never resolved
    silently. A conflict in a user-level file is reported with the change to make by hand, since
    that file affects every project on the machine;
  - **unique** — build commands, code style, domain facts, anything the template does not cover:
    carried into "Project Rules" or the details file, so nothing is lost.
  List each existing agent with the role it covers, so `bootstrap-agents` (step 2) never generates a
  second agent for a covered role. List each existing skill too (`.claude/skills/*/`, the
  tool-neutral `.agents/skills/*/`, the user-level skills folder), broken links included, with what
  it does: a review skill whose lenses cover a reviewer role, a commit or ship skill that overlaps a
  step. Enabled plugins' skills count too (`claude plugin list --json`, only rows with
  `"scope": "user"` or a `"scope": "project"` whose `projectPath` is this repository; never other
  projects'); a skill that overlaps no step is listed as "kept as is". Each overlap is a stated
  default, "install beside it" (say "keep mine and skip step N" or "replace it" to change).
  **A skill or command with the same name as one this onboarding installs** (a `ship` or `trim`
  folder in any of those skills folders, or a `.claude/commands/<name>.md` or user-level
  `commands/<name>.md`, which answers to the same `/<name>`) cannot sit beside it. **It is
  kept, never overwritten, and nothing of ours is written into its folder.** The step that
  installs ours is recorded `skipped (kept your <name>)`, and so is every step that relies on
  ours; the Phase 1 report names each kept skill with that cost, in one line, as a Default taken:
  - `review-code`: step 7 is skipped, and so are `review-plan` and `start` (step 5), which read
    its detection table;
  - `ship`: step 6 takes its existing "ship skipped" path;
  - `checkpoint`: step 4 is skipped; review-code's gate commands stay empty, with a follow-up;
  - `bootstrap-agents` or `bootstrap-claude-mds`: step 2 or 3 is skipped; with step 2 skipped,
    review-code's detection table keeps only its template rows, with a follow-up;
  - `worktree`: Step 0 makes the onboarding folder with plain `git worktree add` (the same path
    and branch), writes no `worktree.env` (the slot map's values read from it, `GH_REPO` and
    `BASE_REMOTE`, come from the (e2) answers instead), and `maxx-start` is not offered;
  - `start`, `review-plan`, `retro`, `trim`, `peer-review`: only that skill is skipped.
  To get ours instead, rename or remove yours and say so; that step is then run as on a fresh
  install. Two
  cases are always settled in Phase 1: the commits rule (a decision) and the `AGENTS.md` choice (a
  Default taken):
  - **Any instruction file in the repository, or loaded in this session, that forbids commits** ("never commit unless
    asked") conflicts with the per-step commits. Ask it as a conflict: "Your instructions say never
    commit without asking; the onboarding commits each step you approve on its own branch. For this
    onboarding:" A) allow the per-step commits on the onboarding branch only (your rule stays as it
    is for everything else); B) commit nothing: each step stays as uncommitted changes in the
    onboarding folder until you commit it yourself; C) ask me before each commit. Default if you
    skip it: A (the commits stay on the onboarding branch; nothing reaches your main branch without
    the merge decision). This is separate from the template conflict about the same rule, which
    decides what the installed `CLAUDE.md` says.
  - **An `AGENTS.md` that other harnesses read:** listed under **Defaults taken** next to the
    conflicts, because their answers depend on it (say "copy it" or "import it" to change): A) keep `AGENTS.md` as the shared source, imported by `CLAUDE.md` (where
    the harness supports imports); B) copy its rules into `CLAUDE.md` and leave `AGENTS.md` as it
    is. A stated default: A when another harness's files are in the repository, otherwise B. With A, every
    conflict resolved against one of its lines also
    edits that line in `AGENTS.md` to the resolved rule (shown as a diff at Step 1), so the imported
    file never says the opposite of `CLAUDE.md`.
- **Where the download sits** — only if it is inside this repository: `git check-ignore` on it; not
  ignored → report it and propose adding it to `.git/info/exclude`. Outside → nothing to report.
- **Hooks already in place** (j, step 8) — the `hooks` blocks in `.claude/settings.json`,
  `.claude/settings.local.json` and the user-level settings (`~/.claude/settings.json`): event,
  matcher and command of each handler, and whether any of them sets `disableAllHooks`; files
  already in `.claude/hooks/`; git's own hooks (`git config core.hooksPath`, a hooks manager's
  folder or config such as `.husky/` or `.pre-commit-config.yaml`, files other than the `.sample`
  ones in the folder `git rev-parse --git-path hooks` prints), so a check that already runs before
  commits is not proposed twice; whether `jq`, `python3` and `claude --version` answer, by running
  them (`jq -n 1`, `python3 -c 1`), never by looking the name up: on Windows a `python3` that is
  only the Microsoft Store's stub is found on the path but does not run (the installer needs `jq`;
  the guards' "block when the hook itself fails" setting needs Claude Code 2.1.295 or later; on
  Windows, Claude Code runs commands in Git Bash, and the missing tools install with `winget
  install jqlang.jq GitHub.cli`); a hooks manager the dependency install would switch on (husky, lefthook,
  simple-git-hooks in the manifest's scripts; Step 0 runs the install with it off and the install's
  commits with git's hooks off, see "The first install never blocks itself"); and where sessions are started (Claude Code reads `.claude/settings.json`
  only from the folder a session starts in, while `.claude/settings.local.json` is read from the
  repository's root, in a worktree the main checkout's root, so the answer to (j) decides whether
  a session started in a subfolder gets the hooks). Reported, not acted on.
- **Install paths git would ignore** — `git check-ignore -v` on every path the install writes:
  `CLAUDE.md`, the details file, `.claude/skills/x/SKILL.md`, `.claude/skills/x/ship.env` (and
  `worktree.env`, `retro.env`), `.claude/agents/x.md`, `.claude/critical-paths.txt`,
  `.claude/protected-files.txt`, `.claude/humanmaxxing.lock`, `.claude/hooks/hooks.env`,
  `.claude/settings.json` (under (j) A), a folder `CLAUDE.md`, the follow-ups file. A hit means
  every step commit would silently leave that file out: a Phase 1 decision quoting the rule and
  its file: A) un-ignore the install paths (the exact lines shown: `!` lines for each; where a
  whole folder is ignored, its line becomes `<folder>/*` first, since a `!` line cannot reach into
  an ignored folder; `.claude/settings.local.json` and other personal files stay ignored), written
  to `.gitignore` in Step 0 and committed with it; B) keep them ignored: the install stays on this
  machine, and the plan says nothing it installs is shared. Default if you skip it: A.

**Never fill a gap with a guess.** A finding states its evidence (the file or command); a question
the repository cannot settle is a follow-up, not an assumption. Where a finding contradicts what the
user said, or the docs contradict the history, say both: "you said X (or: the docs say X), the
repo shows Y — which one do we plan around?" (verify before
you plan, as `start` does with a ticket). That question is a Phase 1 decision (below).
**Keep `follow-ups.md` from the first finding:** create `<report folder>/follow-ups.md` with the
first follow-up Phase 1 finds, and add to it as they come up.

**Phase 1 ends** with the report file and one message, both laid out per "Every message that
waits for the user".

- **The report file** (`first-pass-report.md`): the Decisions and Questions first; then every [repo]
  question with its answer and evidence ("Express + Prisma, from `package.json` and
  `prisma/schema.prisma`") or "not found"; what no question asked about (protected-file candidates,
  a tenant key, IaC, a docs layout, a proposed docs and details-file path: proposals confirmed at
  Step 1 per the slot map, which are not Phase 1 decisions); the existing-instructions table (each
  file, its rules sorted duplicate / conflict / unique) and each existing agent with its role; then
  the draft Phase 2 plan with the current answers and defaults.
- **The message:** **Decisions** = only what a default cannot settle: the invariant (b) with the
  first pass's candidates as A, B, C (the user's own words through "Other"; no default: needed
  before Step 1), the conflicts (one decision when two or more), the commits rule, a GitHub copy,
  ignored install paths, the wiring (j), and a contradiction between the docs (or the user) and the
  code ("which one do we plan around?", one decision when two or more; default: the code);
  everything else is under **Defaults taken** (e2's states, (d)'s hosting with no named host,
  (f), skill overlaps, `AGENTS.md`, the branch name, the docs path). **Next:** "Reply with your choices; anything you skip takes the default
  shown. Then I'll show you the plan for approval. Nothing is written to the repository before that
  approval."

**Partial answers.** Whatever is still missing after that reply gets the slot map's default where it
gives one, and `UNVERIFIED` everywhere else, never a guess, and shows in the plan as an open item.
Only (b) stops the onboarding when missing. Then go on to Phase 2.

---

## Phase 2 — Personalized adoption plan (HUMAN GATE — BLOCKING)

**Nothing is installed in this phase or before it.**

Present an ordered plan on this canonical path (Step 0 prepares the working copy; steps
1–9 install the artifacts; steps 10–12 audit, list the follow-ups and decide the merge), the order
the artifact set's own dependencies require:

0. **A working copy for the onboarding itself** (`skills/worktree`). Runs first, so no later step
   writes into the primary working copy. The plan names the branch (`<prefix>agent-onboarding`,
   the prefix from Phase 1's branch-name finding: `feature/agent-onboarding` when no shape
   dominates, `agent-onboarding` where the shape starts with an issue number or has no prefix), the
   folder, and the dependency install (`POST_CREATE_CMD`, named): what it reaches (the network,
   caches in the user's home folder such as `~/.npm` or `~/.cache`), that it runs with git hooks
   managers off, and that it can be skipped (plan decision 1, B, which names what it costs).
   Approving the plan approves all three. In Phase 3:
   - Fill a copy of `skills/worktree/worktree.env.example` from the (e2) answers in a temporary
     folder **outside the repository** (`mktemp -d`), so the primary copy gains no file.
   - Note `git config --get core.hooksPath` and the primary copy's branch and `git status --short`.
     From inside the primary copy run the create script from the download by absolute path:
     `bash <download>/skills/worktree/bin/worktree-create.sh --config <filled file> --no-base-update --background --no-hook-setup [--no-install] <branch>`
     (`--background`: the install does not hold the onboarding; `--no-hook-setup`: it runs with
     `HUSKY=0` and `LEFTHOOK=0`, and a change it makes to the shared `core.hooksPath` is put back
     and reported; `--no-install` on plan answer B, leaving every check that needs the install
     "not tried: install skipped"; the checks that need no install are still tried once). It
     creates the folder from the remote tip of the integration branch in the repository's
     worktree folder (`<repo>-worktrees` beside the main checkout, for example
     `~/app-worktrees/feature-agent-onboarding` for `~/app`) and leaves the primary copy as
     it was. The plan names that full path.
   - Change into the new folder; install the skill there (`.claude/skills/worktree/`, the filled
     file as its `worktree.env`), apply an approved Phase 1 `.gitignore` change, and write the
     ledger with the approved order. Every later step runs in the new folder, by absolute path in
     every command; the download stays where it is, read by absolute path.
   - Verify, and record in the ledger's Step 0 note: `git worktree list` shows the new folder; the
     primary copy's branch, `git status --short` and `core.hooksPath` match what you noted; your
     working directory is the new folder.
   - **The dependency install's result**, before Step 0 is done: `setup=none` (no command) or
     `setup=skipped` on the result line → nothing ran and there is no exit-status file to wait for.
     `setup=background` → wait (bounded) for the exit-status file it printed: 0 → noted in the
     ledger; anything else → the end of its log, in plain words in the ledger ("Python 3.12 is not
     installed"); the folder stays, and the checks that need it stay "not tried: <reason>". Never
     a stop.
   - Then try each check once (see "A check command is tried once"), the install-free ones even
     on plan answer B, and record each result in `follow-ups.md`.
   - `maxx-start` (the per-machine launcher) waits for the merge (see "Closing the install").
   - The harness "resets the working directory" when a `cd` does not carry to the next command
     (some keep a `cd` only inside folders registered for the session): register the new folder,
     or tell the user to restart the session there; the ledger carries the resume point. A
     subagent needs no restart: give it the folder's absolute path.
   - **Gap-filling mode with uncommitted work in the primary copy** (a hand-installed `CLAUDE.md`,
     agents, skills): a new worktree starts from the remote tip and will not contain it. Offer:
     **A)** commit and push that work first, then run this step; **B)** keep working in that
     folder for this onboarding only, record `single` for now, and move to worktrees once pushed.
   - **The user asks for a single checkout** (never offered): record the request and its reason in
     the ledger row, set `WORKTREE_LAYOUT=single` when `start` is installed (step 5), and create an
     ordinary branch instead. Say once, in the plan, what this turns off (see (e2)).
1. **`CLAUDE.md` from the template** (`templates/CLAUDE.template.md`, plus its companion
   `templates/claude-details.template.md` for the long-form procedures it points into), written as
   `CLAUDE.md` at the repository root of the folder you are working in, every Configuration slot
   filled from Phases 0 and 1, `UNVERIFIED` exactly where the survey came up empty, never guessed. The protected files confirmed
   here go to `.claude/protected-files.txt` in the same step (slot map), and `<YOUR-PROTECTED-FILES>`
   names that file.
   Among the nine artifact steps (1–9) this step is never reordered (Step 0 only prepares its
   folder): both bootstrap skills refuse to run without a root `CLAUDE.md`.
   **When the repo already has instruction files, this step is a merge, not a write.** Build the new
   `CLAUDE.md` from the template plus the Phase 1 table: duplicates folded into the template's rules,
   each conflict resolved as the user answered, every unique rule carried into "Project Rules" (or
   the details file, for a long procedure). Show the table and the merged file and get approval
   before writing; the existing root `CLAUDE.md` is replaced only by that approved merge. An
   `AGENTS.md` follows the Phase 1 answer: kept as the shared source and imported (its conflicting
   lines edited to the resolved rule, shown as a diff), or copied from. Other instruction files
   (`.cursorrules`, Copilot's, `GEMINI.md`) are left as they are; their conflicts are reported, not
   edited.
   **How the template is filled.** The template's Configuration block is replaced as a whole by a
   `## Configuration — this repo` block with one `NAME — value` line per slot (the definitions stay
   in the template); then every `<YOUR-…>` placeholder elsewhere in the file is replaced by its
   value. Never one search-and-replace over the whole file: the block's definitions name the same
   placeholders, and replacing them in place corrupts the block. The same rule fills the details
   file's block. The filled file carries no onboarding text: no "Template —" note, no "fill these
   in" line, no reference to the ledger or to a step number.
   **Before drafting, check the evidence (restated here because it is needed here):**
   - `UNVERIFIED` exactly where the survey came up empty (the ports included: Phase 1). The details file's settleable slots,
     each from its Phase 1 source: `E2E_PORT` and `QA_PORT` and the dev-server lines ("Ports and
     dev servers"), the type-check and test commands ("Test signal", the manifests), the tenant
     key ("Tenant-scoping convention"), the board states (e2, a fixture or config that lists
     them counts). "none in this repository (`<evidence>`)" is a filled value, not `UNVERIFIED`.
   - Every opinionated template default (slot map) is searched for in the repository's docs,
     CI comments and check-script headers (`git grep -n -i -e pipefail -e 'separate PR' -e
     'guard' -- '*.md' .github scripts`, adapted): evidence of another practice → a conflict;
     none → kept, and the Step 1 report names what was searched. Never write "nothing in the
     repository says otherwise" without that search.
   - A command named as a check or a test in the drafts carries its result from the one try after
     Step 0 (or "not tried: <reason>"), and is not one the docs warn against (a whole-suite run where tests are dispatched elsewhere, a
     script that resets a database).
   **Step 1's one message:** 1. **Write these drafts?** (the merged `CLAUDE.md`, the details file,
   the protected list, each shown per the Fail-safes) A) write them as shown; B) with changes:
   name them. Default if you skip it: none: needed before Step 1 writes. Then, only when they
   apply: the template defaults the evidence contradicts (one decision: A) take the repository's
   practice for each; B) name the ones to keep; default A), and "Out-of-Scope" with a candidate
   (A) yes, as named; B) no, the section goes; default B). The docs and details-file paths are
   Defaults taken.
2. **`bootstrap-agents`** (`.claude/skills/bootstrap-agents/SKILL.md` once installed) — surveys the
   repo again on its own and proposes your subagent roster from its archetype catalog, counting the
   agents you already have by the role they cover (keep / extend / replace), never adding a second
   agent for a covered role. Its own human gate applies. Its review wiring (the reviewer rows for
   `review-code`'s detection table) cannot land before `review-code` arrives at step 7:
   Save the rows it emits, as a ready-to-paste block, in `step2-report.md`, and name that file in
   the ledger's step 2 note; step 7 pastes them. The critical paths are asked here, once (slot map,
   `CRITICAL_GLOBS`), with the folders the survey found most fix-prone and most changed, and the
   files the repository itself guards, as the options (a multi-select; default: the code the
   invariant names). With inherited history (Phase 1), the options are the invariant's code and
   the current folders by size and kind; history counts appear only as notes, never as an option
   for a folder that no longer exists. **Restated for this step:** every generated agent's allowed
   commands are checked against the repository's docs, CI comments, check-script headers and
   test-dispatch scripts before the roster is shown, and the roster shows one line per agent
   ("test-engineer: scoped runs only, no whole-suite command: the docs dispatch suites remotely");
   no whole-suite or end-to-end command in any allowlist where suites run elsewhere. There the
   agents' test commands take a path-anchored form (`Bash(go test ./business/*)`,
   `Bash(npx vitest run src/*)`), never `{TEST_CMD} *`. Where no pattern can express the limit
   (the runner takes the whole suite from any argument), the roster line says "scoping is prose
   only", and a guard hook that refuses whole-suite runs becomes a follow-up.
3. **`bootstrap-claude-mds`** — proposes folder-level `CLAUDE.md` files for directories that earn
   one (churn + repeated pattern + footgun history, not just file count). Its survey reads deeper
   than step 2's: when it shows that an agent approved at step 2 is wrong (a convention the agent
   states that the folder contradicts), propose the edit to that agent file as its own decision in
   this step's report, shown as a diff (default: apply it). With no folder proposed, the step has
   no decision: it reports "considered, nothing proposed" as a done line and goes on.
4. **`checkpoint`** — the baseline commit flow: docs, quality checks, git commit. It is
   commit-only: pull requests go through `ship` (step 6), and it writes no pass sentinel.
   Its `CRITICAL_GLOBS_FILE`, `TEST_GLOBS` and `DEV_SERVER_PATTERN` follow the slot map, so its
   test-update guard never halts its first use.
   Its check slots are left empty during the install, each with its follow-up named in a comment
   line above it (see "The first install never blocks itself"); every command is tried once (once:
   never again for evidence), right after Step 0, and that result goes into the follow-ups. Its `allowed-tools`
   ships with git, `date`, `mkdir` and the exact `gh` commands its steps use, only (slot map; never
   `gh pr merge`); it gains exactly the commands its filled slots use
   (slot map). Its commit, stash and push behaviour is mapped from the installed `CLAUDE.md`'s
   rules, found by their text, not by line (slot map, `COMMIT`, `AUTOSTASH`, `PUSH`):
   `COMMIT=ask` when it says to ask before every commit; `AUTOSTASH=no` when it forbids stashing
   (Tool Discipline's "No hand-rolled `git stash` or `pop`: use a WIP commit");
   `PUSH=ask` from Commits and PRs' "Never push unless the user asks" (`never` with no remote).
   These three values are the same on every install unless Step 1 replaced one of those rules
   with the user's own; any other clash is a decision in this step's report (default: the skill
   follows the rule). Its folders come from the slot map.
5. **`review-plan`, then `start`** — the plan-approval gate: before you build something nontrivial,
   a multi-domain agent team reviews the plan. `start` is its front door: it takes an issue, finds
   the root cause with domain subagents, and hands its plan to `review-plan`; its `WORKTREE_LAYOUT`
   and `INTEGRATION_BRANCH` come from (e2) and (e). **Install-only until step 7:** `review-plan`
   requires its companion `review-code` to run its review steps, and `start` hands every plan to
   `review-plan`. Step 5 copies and configures both; their first real run comes after step 7.
   In review-plan's `references/plan-audits.md` (and, at step 7, review-code's
   `references/audits.md`): delete the worked examples that do not apply, add repository blocks
   only from Phase 1's documented rules, and remove the ONBOARDING comment.
   Record the step as `done (inert until step 7)`. With no tracker
   (`TRACKER=none`), `start` takes a task described in words (`/start "the export drops the last
   row"`) instead of an issue number, and the plan says so.
6. **`ship`** — the optimized commit → PR → merge flow. Its script-read configuration is a
   `ship.env` next to its `SKILL.md` (`ship.env.example` lists every key; the answers fill base
   branch, default mode, merge method, required checks, critical globs). `REVIEW_GATE=sentinel`
   when step 7 will install `review-code` (the plan has it and no review skill of the user's own
   was kept): the review and end-to-end gates read the sentinels `review-code` writes. It lands
   one step ahead of step 7 safely, because nothing runs `ship` during the install. **Fallback
   only** (step 7 skipped, or the user kept their own review skill): `REVIEW_GATE=manual`, with
   the rule written where the agent reads it at ship time: a `#` line above `REVIEW_GATE=manual`
   in `ship.env`, and one line under the Test Thoroughness Gate in `CLAUDE.md`, both saying
   "manual mode: an attestation's note quotes the user's own confirmation, given in this session;
   the agent never attests its own review or tests". Its check slots
   stay empty and its critical-paths file holds the confirmed paths as comment lines (see "The first
   install never blocks itself"). For a copy of a GitHub repository, `ship.env` carries
   `GH_REPO=<owner/repo>` (slot map). **Skipped** when the scoping rule "No GitHub / no PRs"
   applies (the remote is staying where it is, or "not sure yet"): the ledger row says `skipped`
   with that reason, and nothing of `ship` is copied.
7. **`review-code`** — installs the code-review companion, whose sentinels `ship`'s review gate
   reads from the first pull request after the merge (`REVIEW_GATE=sentinel`, set at step 6).
   The install itself is never reviewed through it (step 10 is its review). With `ship` skipped
   there is no gate to read them: review sentinels are advisory, and `checkpoint` does not read
   them. This step also:
   - pastes the rows saved at step 2 (`step2-report.md`) into
     `.claude/skills/review-code/references/detection-table.md`, then checks that every agent the
     table names exists (`.claude/agents/<name>.md`, or the user-level agents folder) and can
     write its findings file (step 2's keep / extend check); a name with no agent is fixed now
     (the row removed or the name corrected), never left to fail at the first review; the test
     row covers every confirmed critical path, and no row is a catch-all;
   - writes `.claude/critical-paths.txt` when `ship` was skipped (slot map, `CRITICAL_GLOBS`),
     and checks the file parses: every line is a comment, blank, or a glob in the protected
     list's grammar (slot map, "Protected files": a path from the repository's top, `*` and `?`
     inside one folder, `**/` across folders; no leading `./` or `/`, no trailing `/`, no
     `{a,b}`, no `[..]`, no `!`), so the check needs no installed `ship`; and adds one line under the Test Thoroughness Gate in `CLAUDE.md`: "not switched on
     yet: the critical paths are off until their follow-up", so the rule never claims a live gate;
   - leaves `SECOND_OPINION_CMD` empty in `review-code` and `review-plan`, with a comment line
     above it naming its follow-up (the vendor, and that diffs and plans are sent there);
   - installs the two small companions, with no question (a Default taken, each named in the
     step's message): **`peer-review`** (a verdict on someone else's pull request; its
     Configuration filled per the slot map) and **`trim`** (writes a `/compact` command for the
     conversation; `COMPACT_DIR` keeps its worked default). Each is copied from the download into
     `.claude/skills/<name>/` and recorded with `hm-lock.sh record`, like every installed skill.
     A same-name skill or command of the user's own (Phase 1) is kept: that companion is skipped
     and named in the message; it is never copied over.
   No sentinel is expected until the first real review after the merge.
8. **hooks** — automatic guards for the rules in your `CLAUDE.md` that a prose reminder does not
   hold, from the download's `hooks/` folder. They are written for Claude Code (its hook events
   and settings files). **The first install wires everything in warn mode, so nothing can block or
   delay merging the install:** `hooks-install.sh … --mode warn` wires the protected-file guard
   and the commit check so that each prints what it would have asked about or refused (the file
   and the list entry it matched; the check that failed) and never blocks, asks or refuses; the
   pending-question reprint has no mode; the review nudge only prints its reminder until switched on.
   The same plan sets `env.CLAUDE_CODE_SUBAGENT_MODEL = "sonnet"` (the mid tier) when no settings
   file sets it, and never overwrites a value; `--no-subagent-model` leaves it off. Switching the guards on is a proposed follow-up (step
   11): the same install run with `--mode enforce`, plan then apply. The table below describes
   each hook once switched on; its known gaps and the limits go into `plan.md`, not the plan
   message; the message keeps one line per ticked hook, each saying "warn only". **Until "switch
   the guards on", every ask, refuse or block described in this step (the table, the Limits, the
   Fail-safes) means "prints a warning and lets the call through"**, a hook that crashes or times
   out included:

   | Hook | The `CLAUDE.md` rule it enforces | When it runs | What it does | What it needs from this repo | If the hook itself fails | Ticked by default |
   |---|---|---|---|---|---|---|
   | protected-file guard | Protected Files | before every file edit and shell command | asks you to approve any change to a protected file, naming the file and the list entry it matched; refuses it only in a permission mode that cannot ask you (bypass permissions, don't ask) | the protected list from Step 1; always protected besides, listed or not: the hooks folder, the list itself, and `.claude/settings.json` and `.claude/settings.local.json` (they can switch the hooks off) wherever they are, see "Limits" | a crash or a timeout blocks the call (Claude Code 2.1.295 or later; older versions let the call through); a broken configuration asks you about every edit until it is fixed | yes, when the protected list is not empty (warn mode: it prints the match and lets the call through) |
   | commit check | Domain Accuracy: a change passes the check before it is committed | before every shell command that makes a commit | refuses the commit while the check fails, and shows why | a check command (the candidate step 8 shows, from the checks the first pass tried) | a check that fails, runs out of time or cannot start refuses the commit | yes, in warn mode: it prints what it would have refused and lets the commit through |
   | pending-question reprint | Tool Discipline, "Pending question" | at the end of each turn | shows the question still waiting for your answer again, so it does not scroll away | nothing | does nothing; it never holds up a turn | yes |
   | review nudge (`review-nudge`) | the code review runs before any completion claim | at the end of each turn | once per session, when this session wrote reviewable (non-docs) files and no review covers the tree, holds the stop once and tells the agent to run the review-code skill | the review-code and ship skills (silent until both are installed) | does nothing; any error lets the stop through | yes, in warn mode: it prints the reminder only |

   Under the table: each ticked hook's known gaps in one line (the guard: see "What the shell
   guard can and cannot see" below; the commit check: merges and other commits that never say
   `commit`, a commit made inside a script, commits you make in your own terminal); any hook the
   first pass found already running on the same event.

   **The follow-up, recorded now and offered at the end:** "Switch the guards on: the
   protected-file guard asks and the commit check refuses a commit while `<the check>` fails"
   (from warn to enforce), optionally with **the same check for every commit** (a git
   `pre-commit` hook; not offered when another tool manages git's hooks, `core.hooksPath` is set,
   or a `pre-commit` hook already exists: the one line to add to it is given instead). Switching
   on later is the same install run in enforce mode:
   `bash <download>/hooks/bin/hooks-install.sh plan --hooks protected-file-guard,commit-check,pending-question-reprint,review-nudge --settings <the same file> --mode enforce`
   (plus `--git-pre-commit`), show it, and the same command with `apply … --approved <hash>` on a
   yes. Changing the check first: edit `COMMIT_CHECK_CMD` in `.claude/hooks/hooks.env` (a
   protected file).

   **No hook here can stop the install's own commits or its merge, and nothing in this step needs
   a new session.** Every hook is in warn mode. The session running the onboarding is never
   guarded (it started before the wiring existed, and settings are read when a session starts),
   so no approval prompt appears during the install, `apply` included, and no warning either: the
   user's answer at sub-step 2 is the approval. The first session that shows warnings is the first one
   after the merge. A plan this step cannot get past (below) is never a stop: the step is
   recorded `skipped (<reason>)`, the reason becomes a follow-up, and the install goes on.

   **At step 8, one sub-step at a time, in one message with one decision:**
   1. **Configuration.** Copy `<download>/hooks/hooks.env.example` to `.claude/hooks/hooks.env`.
      `COMMIT_CHECK_CMD` gets the candidate (slot map), with a `#` line above it: "warn mode:
      reports, never refuses; switched on by the follow-up 'switch the guards on'"; no candidate →
      empty, with a `#` line above it saying why. The protected list already exists (Step 1).
   2. **Plan and decide.** From the repository's top level:
      `bash <download>/hooks/bin/hooks-install.sh plan --hooks protected-file-guard,commit-check,pending-question-reprint,review-nudge --settings <the file from (j)> --mode warn`
      (only the hooks still ticked; always `--mode warn`, never `--mode enforce` or
      `--git-pre-commit` on the first install). It writes nothing and prints the files it would copy, the handlers it would add,
      the settings file's diff, and two checked promises: nothing outside the settings file's
      `hooks` block changes, and every hook that was there before stays, in order. Put the whole
      output and the `CLAUDE.md` hook lines of sub-step 4 below (as a diff) in `step8-report.md`. The
      message says in plain words what changes ("adds 4 automatic handlers to `.claude/settings.json`: the protected-file guard and the commit check, both warn only (they print what they would have stopped and never block), the pending-question reprint, and the review nudge (warn only: it prints a reminder to run the code review); the commit check runs `<the candidate>`; nothing else in that file changes")
      with one decision: **A) install exactly this, with the `CLAUDE.md` lines shown**; **B) not
      now** (the `hooks.env` of sub-step 1 is deleted again, so nothing of the pack is left; the
      ledger records `skipped (declined at step 8)`, and the report keeps the handlers for wiring
      by hand later). Default if you skip it: A. A `WARNING` that `.claude/settings.json` is
      ignored by git: the decision gets C) un-ignore it with the lines the plan names, then A
      (default C). The plan saying `.claude/settings.local.json` is not ignored (B at (j)): add the
      line it prints to the file `git rev-parse --git-path info/exclude` names, before `apply`, so
      no `git add -A` ever commits it. Exit 1 → the plan names what blocks it (a missing protected
      list, a list line the guard cannot honour, a malformed `hooks.env`): fix that, plan again
      (a fix that needs the user beyond this step's decision → `skipped`, above).
      Exit 2 with `settings-unparseable` → the settings file is not valid JSON: the user fixes it
      by hand, then plan again (or wire by hand, as for `no-jq`). Exit 2 with `no-jq` → ask whether
      to install `jq` (Windows: `winget install jqlang.jq`), or wire the handlers by hand from `<download>/hooks/settings.fragment.json`
      as a diff approved the same way.
   3. **Apply**, on A: the same command (`--mode warn` included) with `apply` and
      `--approved <the hash on the plan's last line>`. It applies only the plan that was shown (the hash covers the plan's text and the
      download's files); exit 4 means something changed since: plan again and show it again.
   4. **`CLAUDE.md`**: write the hook paragraph in "SESSION START" and the hook line in
      "Reference" back, filled (`<YOUR-HOOK-LIST>`), by a targeted edit, from the text Step 1 kept
      in `drafts/` when it deleted them: the conditional clauses dropped ("with none of your own,
      drop this clause", "(No hooks installed yet: delete this paragraph …)"), no second pair of
      backticks where the template already wraps the placeholder, the hooks named as warn-only
      for now, and the Configuration block's `HOOK-LIST` line updated to the same value.
   5. **Verify offline, in this session:** `bash .claude/hooks/hooks-check.sh` exits 0. It checks
      every installed hook is present, wired under its event and answering its probes, and runs
      the guard's registered handler itself, as the harness would, on a synthetic edit of a
      protected file (in warn mode it must print the warning and let the edit through; once
      enforced, it must ask). Exit 0 → the step is `done (verified offline)`. Exit 1 → fix
      what it names and run it again; the step is never `failed` for want of a new session, and
      never holds the merge. The live check (a session started in the repository's top folder
      after the merge: `/hooks` lists the handlers, and one edit of a protected file is warned
      about, asked about once enforced) is a follow-up for that first session.
   6. **Record**: `bash <download>/tools/hm-lock.sh record --from <download> hooks`, and the
      ledger row, for example: "warn mode: protected-file guard (5 globs), commit check (secret
      scan), review nudge; pending-question reprint; wired in .claude/settings.json (+4 handlers, diff
      approved); verified offline; follow-ups: live check, switch the guards on".

   **What the shell guard can and cannot see — say this to the user plainly, in `plan.md`.** It is
   exact for the file tools (edit, write, notebook edit): it sees the path, follows symlinks, and
   asks. For shell commands it reads the command text for the protected names, the folders that
   hold them, and commands that rewrite the whole tree (`git clean`, `git reset --hard`,
   `git stash`, `git apply`, `rm -rf .`): best-effort, not a guarantee. It cannot see a path the
   shell builds while the command runs, a file written by a one-line program (`python3 -c …`),
   **a script the agent writes and then runs**, a branch switch, merge, rebase or pull that changes
   a protected file, or a write tool it is not wired to. The protected-files gates before merge
   catch those: `ship` (Step 0-pre) and `review-code` (0b) check every changed file against the
   list and the guard's always-protected files (`**/.claude/settings.json`,
   `**/.claude/settings.local.json`, `.claude/hooks/**`, the list itself) and stop for approval.
   It asks more than needed, by design: a commit message or PR body that names a protected file is
   asked about (documented noise: approve it, or reword it), and so is copying a folder that holds
   one (`cp -r .github /tmp/x`).

   **Limits to state in `plan.md`, in plain words:**
   - In the bypass-permissions mode a hook's request for approval is not documented to reach you,
     so the guard refuses there instead. A hook that crashes lets the call through on Claude Code
     older than 2.1.295 (the plan says which version you have).
   - Where the wiring is read from: `.claude/settings.json` (A) only from the folder a session
     starts in (a worktree's top folder counts); `.claude/settings.local.json` (B) from the main
     checkout's root for any session in the repository, so one file covers every worktree. The
     handler finds the scripts in the top folder of the worktree the session started in: where it
     has no pack (a branch from before the install) the hook says it is off there; where the guard
     script is gone but its configuration remains, every call it matches needs your approval.
     Under B, a session started in the primary copy is not guarded until the merge is pulled there.
   - The settings files are protected wherever they are, but only from a guarded session: a file
     edit of any `.claude/settings.json` or `.claude/settings.local.json` is asked about (this
     repository's, another checkout's or worktree's, a subfolder's, your own `~/.claude/`), and a
     shell command is asked about when it names them.
   - The commit check's time limit is written into the settings file at install: after raising
     `COMMIT_CHECK_TIMEOUT_SECS`, run the plan with `--update` again (`hooks-check.sh` says so).
   - **If every call is suddenly blocked with a hook error**: in your own terminal run
     `git checkout -- .claude/hooks` (or reinstall from the download), or start one session with
     `claude --settings '{"disableAllHooks": true}'` to repair it; then run
     `bash .claude/hooks/hooks-check.sh`.
9. **`retro`** — the weekly look back that Phase 4's calendar runs: what shipped, what broke, which
   fixes needed another attempt, whether fixes closed the whole class of bug or only one instance,
   recurring review findings, and whether a newer HumanMaxxing release is out. It only reads (git
   history, `git ls-remote`, and read-only `gh` queries when `TRACKER=github`) and writes one
   report file when it runs.
   **Nothing new is asked:** its `retro.env` is filled from answers already in hand, per the slot
   map. The repeat-bug threshold is not copied into it: the skill reads it from the rule (i) filled
   into `CLAUDE.md`. **Network notice, not a question:** before the data script runs, the step's
   message says, in one line, "This step reads from the network, read only: issue counts and merged
   pull request titles from GitHub (`<GH_REPO or the repository gh resolves>`), and the release tags
   of the HumanMaxxing download's repository. Nothing about your project is sent." (only the parts
   that apply: no GitHub line when `TRACKER=none`, no release line when `RELEASE_REPO_URL` is
   empty), then runs it without waiting. If the user later says to skip it, the step is recorded
   `skipped (network declined)` and the install goes on. **Verified by its data script, not a full run** (a full run would write a
   report into the onboarding branch): `bash .claude/skills/retro/bin/retro-data.sh` must end with
   a `RETRO-RESULT` line and exit 0, or exit 3 with a `PARTIAL` line whose sections are each
   explained in the ledger note (`gh` not signed in, the release repository not reachable).
   On a fresh install `threshold` and `findings` are expected in that `PARTIAL` list: the script
   reads the rules file and the findings folder from the base branch, which has neither until the
   onboarding branch merges and a reviewed branch has merged after it. They are not defects to
   fix; say so in the ledger note, and that the first week's guard count includes the install's
   own hook files (`GUARD_GLOBS` covers `.claude/hooks/**`). Check the threshold fill in the working tree instead:
   ``grep -c 'this fix included, reaches `[0-9][0-9]*`' CLAUDE.md`` must print `1`.
   Exit 2, or a `FAIL` line, follows retro's own routing table in its `SKILL.md`: exit 2 means
   fix `retro.env` or the call and run it again; exit 3 with `FAIL` means report it and stop. The
   first real `/retro` is Phase 4's. The script reads history from the remote-tracking branch when
   there is one: after a merge that was not pushed, it still sees the remote's older tip until a
   push (the report shows the tip's date).
10. **Final audit** — a fresh read-only check of the whole install against the repository's own
    evidence, by an agent that has seen none of this onboarding, just before the merge decision.
11. **Follow-ups** — every proposed follow-up with its evidence: filed in the tracker with your
    approval, or written to a follow-ups file in the docs.
12. **Merge** — whether the onboarding branch is merged now, kept for a pull request, or not yet;
    then `maxx-start`, once the branch has merged. Steps 10–12: see "Closing the install" (Phase 3).

**Also in the plan, not a numbered step: plugins worth installing.** A short list from the survey,
one line each on what it adds and where it meets these skills, ticked in one multi-select question
(Claude Code: `multiSelect`; at most four per question; "None" the default when skipped). A
plugin is third-party code running with the agent's permissions: name its marketplace and
publisher, and have the user look at `claude plugin details <name>` first. Commands below are
Claude Code's; on another harness, name the capability.

| Suggest when | Plugin (marketplace) | What it adds, and where it meets these skills |
|---|---|---|
| Any repo (baseline offer) | `superpowers` (`claude-plugins-official`) | Working habits for the agent: brainstorming before building, red/green TDD, systematic debugging. Complements `start`; where its workflow and your `CLAUDE.md` disagree, `CLAUDE.md` wins |
| Any repo (baseline offer) | `second-opinion` (`trailofbits`) | Review by a different vendor's model through its CLI, which sends your diffs and plans to that vendor. This is the simplest way to fill `SECOND_OPINION_CMD` in `review-plan` and `review-code`, which is a follow-up, never filled during the install |
| Any repo with code review | `differential-review` (`trailofbits`) | A security-focused read of a diff with history and blast radius. A candidate extra lens for `review-code`'s detection table on your critical paths |
| Code that handles secrets, auth or user input | `security-guidance` (`claude-plugins-official`), `insecure-defaults`, `sharp-edges`, `static-analysis` (`trailofbits`) | Pattern warnings at edit time, fail-open default detection, footgun API review, Semgrep/CodeQL scans. Feed findings into `review-code`; they do not replace its reviewers |
| Third-party dependencies | `supply-chain-risk-auditor` (`trailofbits`) | Flags dependencies at risk of takeover or abandonment before you add them |
| Pull requests on GitHub | `code-review` (`claude-plugins-official`) | A second, independent PR review pass. `review-code` stays the gate `ship` checks; this is an extra read, not a substitute for the sentinel |
| Fast-moving frameworks | `context7` (`claude-plugins-official`) | Current library documentation on demand, so the agent checks instead of remembering |
| Your stack has one | the vendor's own plugin (your host, your cloud, your queue, your tracker) | Found in the survey: propose it by name only if its marketplace lists it; never guess that one exists |

Installing, once approved (or `/plugin`): `claude plugin marketplace add trailofbits/skills` once
per new marketplace, then `claude plugin install --scope project second-opinion@trailofbits`
(`--scope project`: recorded in the committed `.claude/settings.json` for everyone in this
repository; `--scope local` for this user only; user level only when the user asks).
**Already installed** (`claude plugin list --json`, only rows with `"scope": "user"` or a
`"scope": "project"` whose `projectPath` is this repository; never report other projects'):
enabled → not offered again, listed as "already installed", counting for the slots it can fill;
disabled → offered as "enable it for this project" (`claude plugin enable --scope project
<name>`). **Before a follow-up points a slot at a plugin** (`SECOND_OPINION_CMD` at
`second-opinion`), check it answers in this session (its tool, or `<command> --version`) and put
the result in the follow-up's evidence. Record what was installed, offered and declined in the
ledger. Beyond the baseline rows, suggest no more than the survey supports (each plugin adds
instructions to every session), and confirm each name is still listed
(`claude plugin marketplace list`) or mark it `UNVERIFIED`; an installed one is never re-checked.

**Scoping rules — state which ones apply to this repo, and why, before presenting the final order:**

- **No GitHub / no PRs** (also "not sure yet") → step 6 is `skipped` with that reason; `checkpoint`
  (step 4) runs standalone, commit-only (`PUSH=ask` or `never`), as the last step of every work
  unit. Step 7's review still adds value as a discipline before each commit.
- **No tests at all** → move step 7 (`review-code`, which carries the real-boundary test gate) ahead
  of step 6, and prioritize the test-engineer in step 2. If step 2 deferred it (nothing to test),
  the end-to-end gate stays exempt (its critical paths are off): once the first tests exist,
  re-run step 2 in maintenance mode to add the agent and its row, and only then propose switching
  on the critical-path gate.
- **No commits or no CI yet** → Step 0 needs a first commit: with the user's approval, an empty one
  (`git commit --allow-empty -m "Initial commit"`), pushed when a remote exists. With no CI, `ship`'s
  required-checks list stays empty and the plan says so; the local gates' follow-ups come first,
  and setting up CI is offered as a follow-up.
- **Another harness** (not Claude Code) → step 8 wires nothing: the plan describes the three
  scripts and what they read on stdin (the tool name, its input, the working folder, the
  permission mode); the ledger records `skipped (harness)`.
- **Small or young repo** → step 3 still runs, and "considered, not proposed" is the expected,
  correct outcome below `bootstrap-claude-mds`'s floors.

**How the plan is shown:** the full plan goes into `plan.md` (opened the same way);
**the steps themselves are in the message**, never only in the file. One table row per step: the number,
**what the user gets, in plain words** ("a rules file merged with yours", "your agent team: keep
backend-reviewer, add a test engineer"; a skill only with what it does, "the commit flow
(`checkpoint`)"), and **what it writes** (files and folders, or "nothing"); a skipped step says
why. No setting names, no time estimates. Under it, one line each: "no check or gate is switched on
during the install; each becomes a follow-up you approve later", what Step 0's dependency install
reaches, and that the install's commits run with git's hooks off. Then the rest of the layout per
"Every message that waits for the user": **Where we are**;
**Decisions**, the first always "1. Approve the plan? A) approve as shown — Step 0 creates
<branch> in <folder>, and each step is committed there once you approve it; B) approve, without the
dependency install — N of M checks won't be tried (named: lint, tests, …); the checks that need no
install are still tried once; C) approve with changes — name them;
D) not yet — nothing happens". Default if you skip it: D) not yet. Then the plugins (one
multi-select) and any open item as a decision or question with its default; **Next**.

**Wait for explicit approval of the whole ordered plan before Phase 3 starts anything.** It covers
*the order*; each artifact's own gate still covers *its own output* (the bootstrap skills' Phase 2).
**Phase 2 ends** at that approval; the approved order goes into the ledger at Step 0.

---

## Phase 3 — Execute in order

One step at a time. After each approved step:

1. **Install it, then fill it** — at this step, never earlier, drafting first any file the user must
   approve (see Fail-safes). Every skill, the two bootstrap skills included, is first copied whole
   from the download into `.claude/skills/<name>/` (`SKILL.md`, `bin/`, `references/`, the
   `.example` config). You then run the **installed** copy, never the one in the download, so what
   you tested is what stays. Templates are the exception: they are filled into new files
   (`CLAUDE.md`, the details file), not copied.

   Fill the installed copy's Configuration block with real values, `UNVERIFIED` where genuinely
   unknown, never a plausible-looking guess. **How:** keep the slot definitions and add a
   `Values for this repo` block directly under them: one fenced block of `KEY=value` lines, one
   per slot, every slot listed even when all keep their defaults, each comment on its own line
   above its key (`# …`). The skill reads that block the same way an `.env` file is read: the
   same format as the script-read files below. A slot another skill owns gets its value as a
   comment above an empty key (`# see <skill>'s values`), never a second copy (with `ship` skipped, review-code's gate commands point at
   `checkpoint`'s). A script-read file (`ship.env`, `worktree.env`, `retro.env`) is its `.example`
   copied beside it and filled; `ship` has both that file and a values block. Every command put in
   a slot (by a later follow-up too) goes into that skill's `allowed-tools` in the same edit, and
   that edit also fills every key in another skill that says `# see <this skill>'s values`.

   **A command slot you do not use is left empty, never filled with prose:** `none`, `covered by
   CI` or `UNVERIFIED` would be executed as a command. The reason goes in a comment
   **on its own line, above** the empty value (`# no CI yet`), never after it: everything after `=` is the
   value, a value that begins with `#` is refused as malformed, and a comment run as a command
   exits 0 and reads green. During the install that comment is the slot's follow-up
   (`# follow-up: secret scan, ready to switch on (tried: clean)`). List every empty quality-gate
   slot in the plan: a secret scan that is not configured is a check that does not run.
2. **Run it** — what "run" means differs per step:
   - **The bootstrap skills (steps 2 and 3)** run in full, each with its own human gate.
   - **`checkpoint` (step 4) and `review-code` (step 7) are not run** on the install: no gate
     runs, nothing is committed, rebased or pushed by them, and no review of the install's own diff
     is made (the audit, step 10, is that check). Each check command is only tried once, per "A
     check command is tried once"; the results become follow-ups.
   - **Step 5** is install-only until step 7; **step 9** runs only its data script (see each
     entry); **steps 6 and 8** are configured, not run.
3. **Verify** the output did what it claimed before marking the step done: the file exists, the
   values block is filled, the roster is reachable; for step 4, every check slot is either filled
   or empty with its comment line above it, and its `allowed-tools` covers every filled slot; for
   step 7, every agent the detection table names exists and the critical-paths file parses (no
   sentinel is expected: none is written until the first real review). Then **record it**: from
   inside the project, `bash <download>/tools/hm-lock.sh record --from <download> <path>` with the
   item's path in the download (`skills/ship`; `templates/CLAUDE.template.md` and
   `templates/claude-details.template.md` for step 1; `skills/worktree` for Step 0). This writes
   `.claude/humanmaxxing.lock`, committed with the rest of the install; a later update reads it to
   tell which installed items a newer release changed.
   Then **commit the step** on the onboarding branch, the lock change in the same commit (commit
   style: see "The first install never blocks itself"; when your instructions forbid commits,
   as the Phase 1 answer about commits says). The ledger is not committed. Never push, open a pull
   request or merge without asking. A step that wrote nothing has nothing to commit.
4. **Report** what happened, then update the ledger. A step with no decision of its own (Step 0,
   `checkpoint`, step 5's install, `retro`) was approved with the plan: it is committed straight
   away, with no second approval, reports in two lines (**Where we are**, **Next**) and goes on.
   When the next step needs a decision, the done line is not sent on its own:
   it becomes the first half of the next message's **Where we are** ("Step 4 done: commit flow
   installed, 3 checks proposed as follow-ups. Step 5 needs …"). A step that needs a decision (a
   roster to approve, a merge to confirm) uses the full layout of "Every message that waits for the
   user", with the step's own output in the report file.
5. **Stop and wait**, or continue, at the user's discretion. When the user stops, send one line:
   the ledger's path and "say 'continue' in a new session in this repository to resume here".
   When feedback notes are due at that stop ("Offering to send"), that line is the **Next** of the
   feedback offer's message: one message, not two.

**Later steps can reopen earlier lists.** Steps 2 and 3 survey deeper than Phase 1. When either finds
something an earlier answer should have included (a file the repository guards, a folder with a long
run of fix commits, a documented rule, a guard), it offers the additions as one decision in that
step's report (default: add them): to the protected files (in `CLAUDE.md` and in every installed skill's
`PROTECTED_FILES`), the critical paths, Project Rules, or the follow-ups. An approved addition to a
file an earlier step wrote is committed with the current step. Every list is settled before the
audit (step 10), which checks them again with fresh eyes.

**`getting-started-progress.md`** — the ledger. Write it in the report folder (see "Every message
that waits for the user") at Step 0 and update it after every step. Because it is never committed,
no `pending` row can reach the main branch with the merge:

```markdown
# HumanMaxxing adoption — progress

Answers: <report folder>/first-pass-report.md and plan.md (the reports of Phases 1 and 2); after
step 1, CLAUDE.md's Configuration block is the durable copy.
Onboarding folder: ~/app-worktrees/feature-agent-onboarding (branch feature/agent-onboarding).
Release installed from: 0.1.0 (the download's `VERSION`; per item in `.claude/humanmaxxing.lock`).

| # | Step | Status | Notes |
|---|------|--------|-------|
| 0 | working copy (worktree) | done | branch feature/agent-onboarding, sibling folder; primary copy untouched; dependency install exit 0 |
| 1 | CLAUDE.md from template | done | filled 2026-xx-xx; UNVERIFIED: tenant key |
| 2 | bootstrap-agents | done | 5-agent roster approved; review rows saved in step2-report.md |
| 3 | bootstrap-claude-mds | skipped | repo below churn/file-count floors — revisit later |
| 4 | checkpoint | done | check slots empty, 4 follow-ups |
| 5 | review-plan + start | pending | |
| 6 | ship | pending | |
| 7 | review-code | pending | |
| 8 | hooks | pending | |
| 9 | retro | pending | |
| 10 | audit | pending | |
| 11 | follow-ups | pending | |
| 12 | merge | pending | |
| — | maxx-start | pending | installed only after the merge |
```

A resuming session reads this file first (see "Before you begin"), reports in its verdict line the
done and pending counts and the next step (not the table), repeats the "your own files found"
clause only while Phase 1 is still ahead, and starts at the first `pending` row. **Phase 3 ends** when no row is `pending`: every install step is `done`,
`skipped` (with the reason) or `failed` (with what is needed; step 8 is `done (verified offline)`
when `hooks-check.sh` passes, never `failed` for want of a new session); the audit and the
follow-ups are `done`; the merge is `done` (the default), `branch kept` or `not
yet`; and `maxx-start` is `done`, `declined` or `waits for the merge`.

### Closing the install


**10. Final audit.** A check of the install against the repository's own evidence, by an agent that
has seen none of this onboarding, so it does not inherit the onboarding's blind spots. It runs just
before the merge decision: nothing is installed or changed between it and the merge, except the
fixes and follow-ups it proposes.

- **Who runs it:** a fresh subagent (Claude Code: the `Agent` tool), with read-only tools only:
  reading, searching, and `git` commands that read (`log`, `show`, `diff`, `ls-files`, `grep`). It
  writes nothing and runs no check command. Its prompt holds only the onboarding folder's absolute
  path, the integration branch, the files the install added or changed
  (`git diff --name-only <integration branch>...HEAD` in that folder), the checklist below, the
  output format, and one fact: the follow-ups file is written at step 11, after this audit. Never the conversation, the reports, the user's answers or any conclusion of the
  onboarding. On a harness without subagents: save the same prompt as
  `<report folder>/audit-prompt.md` and ask the user to run it in a fresh session in the onboarding
  folder and paste the answer back.
- **The checklist** (item 0 is the first pass):
  0. Repo facts and template defaults. (a) Every identifier in the domain invariant and in
     `CLAUDE.md`'s Configuration block (an env var, a column or table, a script, a path), searched
     for in the code (a column in the schema or migrations of the store it names): cite
     `file:line`, or flag it "not found in code" (fix: the name the code uses, or drop it). (b) Template defaults in the installed
     `CLAUDE.md` and details file that the repository's own rules, CI or docs, or the installed
     skills' values (`WORK_UNIT_RULE`), contradict (a template rule its CI forbids), and leftover
     template text or sections that do not apply here. (c) No installed skill touched one of the
     user's own: every `.claude/skills/<name>/` folder and `.claude/commands/` file that existed
     at the base commit is unchanged (`git diff <base> -- <path>` is empty). Each is an install-fix (a plain error), unless its fix would switch on a check or a gate.
  1. Files the repository itself guards (a guard workflow or check script that fails on a change to
     the file, a label a change needs, a "never edit" note in the docs or at the top of the file)
     that are missing from the protected files or the critical paths.
  2. Allowed commands or check commands the repository's own scripts or docs warn against (a
     whole-suite test run where a remote test dispatcher exists, a raw infrastructure command where
     a wrapper is required).
  3. Rules in `CLAUDE.md` (and the folder `CLAUDE.md` files, the agent files) that contradict the
     code or a documented team decision (a code comment, a procedure doc, a decision record).
  4. `UNVERIFIED` settings the repository could settle (the answer is in a file).
  5. Installed files that conflict with each other (a skill that pushes while `CLAUDE.md` says never
     push without asking; an agent allowed a command a rule forbids; two different base branches).
- **Output format:** one finding per item, each with its evidence (`file:line` and the quoted line,
  or the command and its output), the change it proposes, and a class: **install-fix** only for a
  plain error in the install itself (a wrong value, two installed files that contradict each other,
  a rule or allowlist the repository's docs contradict) that a small edit fixes; **follow-up** for
  gaps and for anything that would add enforcement (the default). A secret is cited by file and
  line only, never its value.
- **Then:** re-read each finding's evidence yourself (the cited line exists and says that); drop one
  that does not hold, and say so. **A finding whose fix would switch on a check or a gate** (fill a
  check slot, uncomment a critical path, fill `SECOND_OPINION_CMD`)
  **is a follow-up, whatever class the audit gave it**: the auditor does not know those are off on
  purpose during the install. A finding that matches a choice the user made earlier becomes a
  "confirm with the team" follow-up; one already in `follow-ups.md` is not added twice. Write
  `step10-report.md`. All install-fixes are one decision: **Fix these N now?** A) apply them all
  (the diffs are shown); B) apply only the ones I name; C) make them follow-ups instead. Default
  if you skip it: A (they are errors in the install, small, and never hold the merge). Follow-up
  findings go into `follow-ups.md` with no decision of their own. Approved fixes are applied and committed together (`chore: onboarding audit fixes`), with
  nothing else in that commit. No finding → one line, "Audit: nothing found", and go on.

**11. Follow-ups.** Every proposed follow-up from `<report folder>/follow-ups.md`, deduplicated,
each with its title, the exact change, its evidence (a secret by file and line only) and what it
needs first: the check commands with what happened when they were tried, the gates to switch on,
the second opinion (naming the vendor, and that diffs and plans are sent there), the guards the
survey found, switching step 8's warn-only guards on ("Switch the guards on", step 8's
`--mode enforce` run, with its git `pre-commit` option; it is the last follow-up in the list, see
below), step 8's live check in the
first session after the merge, the open items, the audit's follow-ups, and these, each proposed
only with its evidence from this repository:
- **Switch on the critical-path gate:** one command, `sed -i.bak 's/^# off: //'
  .claude/critical-paths.txt && rm .claude/critical-paths.txt.bak` (a protected file: the guard
  asks), then remove the "not switched on yet" line under the Test Thoroughness Gate.
- **Widen the critical paths** to the folders with the most fix commits
  (`git log --no-merges --format= --name-only` over fix-shaped messages, counted per folder) and
  the highest-risk areas the survey found (request handlers, background and stream processing,
  the data store, published client libraries) that the confirmed list leaves out.
- **A reviewer for each high-churn area with no detection-table row** (`bootstrap-agents` in
  maintenance mode), named with its churn and fix counts.
- **Rules the repository already enforces elsewhere**, as `CLAUDE.md` Project Rules or
  Out-of-Scope lines: label-gated workflows, freeze comments, version-bump or publish checks,
  components the docs exclude; each quoted with its file.
- **More guards**, each with the file or doc that shows the need: destructive database statements,
  writes to production data, a raw infrastructure apply where a wrapper is required, opening a pull
  request without the test pass.
- **A read-only database role for audits**, when Phase 1 found row-level tenant isolation and no
  read-only role that sees every tenant: "An audit run as the app's own role sees one tenant's rows
  and reports zeros that look real; give agents a read-only role that sees every tenant, and never
  the admin credential." With a transaction-mode pooler found, the follow-up adds that a read is
  made read-only per transaction, never with a session setting, which the pooler hands on to the
  next client.
- **Default subagent model: the mid tier** (Claude Code; ready to apply; proposed only when step 8
  did not set it (the hooks pack skipped, or `--no-subagent-model` used) and no settings file sets the key: `grep -l CLAUDE_CODE_SUBAGENT_MODEL .claude/settings*.json ~/.claude/settings.json`
  prints nothing, and that check plus (e3)'s tier map are its evidence): a
  subagent started with no model of its own and no agent file runs on the session's model, which
  is the strongest tier, so every ad-hoc worker pays top price. The change: `"env":
  {"CLAUDE_CODE_SUBAGENT_MODEL": "<(e3)'s mid tier>"}` in the settings file (j) named
  (`.claude/settings.json` when (j) was not asked). A model
  named in the dispatch or in an agent's own file still wins, so judgment work keeps its tier.
- **No AI attribution in commits and pull requests**, when the rules or the history say so: the
  harness's setting in the shared settings file (Claude Code: `"attribution": false`, 2.1.281 or
  later; older: empty `attribution.commit` and `attribution.pr`).
- **Switch the guards on** (always last, whenever step 8 installed hooks): "The protected-file
  guard, the commit check and the review nudge have only warned since the install. Switch them on:
  the guard asks before a change to a protected file, the commit check refuses a commit while
  `<the check>` fails, and the review nudge holds a stop once when a change has no review." The
  change: `bash <download>/hooks/bin/hooks-install.sh plan --hooks <the installed hooks, review-nudge among them>
  --settings <the file from (j)> --mode enforce`, shown, then the same command with
  `apply … --approved <hash>` on a yes. The evidence: the warnings the guards printed since the
  install (none yet on a fresh install: the first guarded session is after the merge). Needs
  first: the live check, and the commit check's command passing on the integration branch.
The template's rule holds: no ticket is filed without the user's approval.

- **Issues in this repository's GitHub** (`TRACKER=github`, `gh` signed in): one message with the
  titles (in full in `step11-report.md`). Decision: 1. **File the follow-ups?** A) file all N as
  issues; B) file only the ones I name (for example "1B: 2, 5"); C) file none: write them to the
  follow-ups file instead. Default if you skip it: C. Before filing, search the open issues for each
  title (`gh issue list --search`); a match is named, not filed again. Each approved item is one
  `gh issue create` (its title, and a body with the change, the evidence and what it needs first);
  items not filed go to the follow-ups file, so nothing is lost.
- **No tracker, or one the agent cannot drive:** the titles are listed in the message, and the list
  is written to `<docs root>/humanmaxxing-follow-ups.md` (a section per item, and a line saying they
  are proposals, not filed) and committed (`chore: onboarding follow-ups`): a Default taken ("say
  which to leave out"). For another tracker, the line says to move them there by hand.

**12. Merge.** One message, per "Every message that waits for the user". The decision, in plain
words: 1. **Merge the onboarding branch?** First, in the onboarding folder, bring the branch up to
date (`git fetch`, then `git rebase <remote>/<integration branch>` when it moved; a conflict is
resolved hunk by hunk, never by taking one side whole). Every push below runs with the repository's
git hooks off, like the install's commits (`git -c core.hooksPath=<report folder>/no-hooks push …`).
**On a copy of a GitHub repository (`GH_REPO` set), A and B always take the mirror route
(below), whatever Phase 1 read about protection; A's other routes are for every other remote.**
- A) **merge it** — where nothing protects the integration branch and the host needs no pull
  request: push it as a fast-forward (`git push <remote> HEAD:<integration branch>`, never
  `--force`), then fast-forward the primary copy (`git -C <primary copy> merge --ff-only
  <remote>/<integration branch>`) only when it has no uncommitted changes. Where branch protection,
  required checks or a merge queue guard it (found in Phase 1, or a refused push), or the host works through pull requests: push the branch, open a pull request
  (`gh pr create --base <integration branch>`, its body the install summary and the follow-ups;
  another host: the link its push printed) and merge it the normal way once it may merge
  (`gh pr merge`, or the merge queue), with a bounded wait on its checks. Never an admin merge, a
  force push or a skipped required check, unless the user says so for this one merge. A required
  review or a red check the agent cannot clear → the pull request stays open, the ledger says
  `branch kept (PR open: <reason>)`, and the next session checks whether it has merged.
  **The mirror route** (the remote is a copy of a GitHub repository, `GH_REPO=owner/repo`): the
  pull request lives on the GitHub copy. Push the branch to the GitHub copy (a remote whose URL is
  that repository; `git remote -v` names it, or the user's answer does), then
  `gh pr create --repo owner/repo --base <integration branch> --head <branch>` and merge it there
  as above (`gh pr merge <number> --repo owner/repo`: with `--repo`, every `gh pr` command names the
  PR number, or gh refuses it; or its merge queue); the mirror picks the merge up
  the way it always does. Never a direct push to the mirror's integration branch. Where that
  cannot run (no remote for the GitHub copy, `gh` missing, not signed in or with no network in
  this session), the default becomes B (`branch kept`), and the message and `step12-report.md`
  give the exact commands to run where it can: the `git push <github remote> <branch>`, the
  `gh pr create --repo owner/repo …` line, and the merge.
- B) **keep the branch** — push it and open the pull request as in A (a host with no pull requests:
  push only; a mirror: the mirror route above, or its printed commands); merging it is yours.
- C) **not yet** — nothing is pushed or merged; the next session offers this decision again.

Default if you skip it: A: **a skip merges** (the message says so), except on a mirror whose
route cannot run here, where it is B. When the install's steps were
left uncommitted (the Phase 1 answer "commit nothing"), A and B first commit the install as one
commit. With no remote, A merges locally (the primary copy fast-forwarded only when clean) and B
keeps the branch unpushed. The merge changes protected files (the list, the hooks): no session is
guarded yet, so no prompt appears; say so in one line. The ledger records `done`, `branch kept` or
`not yet`. Once merged, the onboarding folder can be removed with the worktree skill's `check` then
`remove`.

**The last question: how many reviewers** (`MAX_REVIEWERS` in `review-code` and `review-plan`),
asked in the merge message after decision 1, once the roster exists: "Your setup has N reviewer agents. How many may review one change at the same time? A) 5 (recommended); B) 3; C) 7" (under `on-request`: "A) 5 (the default)") — N
counting every agent with a detection-table row (builders with a row included), plus the general
code-reviewer, plus the zero-context reader; "at the same time" is a hard total
of agents per review (more lenses share an agent). Default if you skip it: A.
Skipped when the roster has no more reviewer agents than 5 (the default stays). Written into both skills' values
and committed before the merge.

**`maxx-start`** — the per-machine command (`maxx-start 123` from any directory: guard, worktree,
claim, push, then a session running `start`), written by `bin/worktree-install-launcher.sh`. It runs
the primary copy's launcher, so it comes only after the branch has merged, and it writes outside the
repository (`~/bin/maxx-start` by default): a Default taken, "not installed: say 'install
maxx-start'". On that request: `bash .claude/skills/worktree/bin/worktree-install-launcher.sh` from
the primary copy, then one real run on a startable issue, or, with none or no tracker, a run with
no arguments, which must end with the launcher's usage line. The ledger records `done`, `declined`
or `waits for the merge`.

---

## Phase 4 — First-week calendar

This system is maintained, not installed once. The calendar is **shown only**: nothing is
written, scheduled or installed for it. Drop the rows (and parts of rows) for skipped steps (with
`ship` skipped, "Per commit/PR" names `checkpoint`; checks still waiting: "none switched on yet, see
the follow-ups"), and the weekly row's release clause when `RELEASE_REPO_URL` is empty. The message:
**Where we are** (merged, a pull request open, or not merged, then the follow-ups' count and
place), the table, and **Next** (the feedback offer when notes were kept, else "nothing: the
onboarding is done"), then one closing line, every time: "**Optional: see your numbers.** A free
hosted dashboard shows where your hours go against the agents' run time, cost per pull request, which reviewers
find real issues, and a retro after every pull request. Sign up at https://humanmaxxing.ai/signup;
its install prompt adds a telemetry plugin to this repository and stops so you can read the diff
before you commit. It sends your agents' usage data to the hosted service; nothing is set up unless
you do it." No decision of its own: the line is never asked as a question, never run, and never a
follow-up.

| Cadence | What runs |
|---|---|
| Every session | Read back your `CLAUDE.md` rules at session start |
| Per commit/PR | Quality checks, the review gate (a `review-code` run, whose sentinels `ship` checks before a pull request can merge), the ship sentinel checks |
| Weekly | `/retro` — a read-only look back over the week against your own rules: fix chains, fixes that patched one instance instead of the class, recurring review findings, and whether a newer HumanMaxxing release is out. Its suggestions become issues or rule changes only when you approve each one. The first week's guard count includes the install's own hook files: not a reason to change the repeat-bug number |
| Monthly | `bootstrap-agents` and `bootstrap-claude-mds` re-run in maintenance mode — drift audits, not regeneration |
| As needed | A stale rule or a repeat mistake gets written into `CLAUDE.md` or a guard, not just fixed once |

Every maintenance pass outputs a **verdict-sized report** (a proposed diff, a short drift list, a
sampled finding), never raw data; one that regularly costs more than fifteen minutes is a tooling gap.

---

## Feedback to the maintainers

Only when decision 2 of Phase 0 is A, answered or taken as the default on a skip; only an explicit B
is a no. Nothing here is ever sent without the user's approval of the exact text.

**Keeping notes.** On A (answered or by default), create `feedback.md` in the report folder right away,
holding one header line (`# Where the onboarding instructions were unclear`) and no note yet: a later session reads its
presence as decision 2 being A (see "Before you begin"). Whenever this file (or a file it sends you
to) is unclear, contradicts itself or another product file, makes you guess, or makes you ask
something you could have found out, append one numbered line to `feedback.md`: the file and section,
what was unclear, and what you did. Write it silently:
never mention a note in the chat. The notes are about **these instructions, never the user's code**: no file contents, no code,
no command output. Write the user's names generically ("the API folder", "the main branch", "their
tracker"), never their paths, repository name, remote, people's names or email addresses. The send
script refuses the common forms of those, but it is a backstop, not proof: your own care comes
first, and a passing preview does not make a note generic. A note that needs them is a note about
the user's project, not about these instructions.

**Offering to send.** Only when `feedback.md` has at least one numbered note (the script refuses a
file without one, so a comment alone is never offered), and only at these points: when the
onboarding ends (after Phase 4's calendar); when the user says they are stopping; and at the end of
a resumed session whose "Before you begin" check found notes not yet sent or declined. Notes are not
yet sent or declined when neither `feedback.json.sent` nor `feedback.declined` sits beside
`feedback.md`, or when `feedback.md` is newer than the one that does
(`[ feedback.md -nt <that file> ]`): notes added after a send or a decline are a new offer, and the
new preview removes the old `feedback.json.sent`. **A note found after the user declined (or sent)
is still kept:** append it as usual. It does not reopen the offer there and then; it is offered at
the next of the points above, never in the middle of a step.

Run every command below as ONE command that starts in the project's root (the folder
`git rev-parse --show-toplevel` printed in "Before you begin"), because the shell's folder may reset
between calls: `cd <project root> && bash <download>/tools/hm-feedback.sh …`. Outside the project
the script refuses (exit 3). Each message numbers its own items from 1, like every other
message: Reply (1) and Anything else (2) in the first message, Send (1) in the preview's. The four
parts below are named, not numbered, so they are never read as decisions.

- **The first message**, per "Every message that waits for the user":
   - **Where we are:** "the onboarding kept N notes on where its instructions were unclear".
   - **Decisions**, also through the dialog (header "1 Reply"):
     1. **Reply** — "Would you like a reply? Your email goes with the feedback, only so a
        maintainer can answer you." A) no reply needed; B) reply to the address git has for the
        user, written out in the option (no address in git: "I'll type one", through "Other");
        C) not now: the notes are kept and offered again at the next stop (the next point below,
        or the next session's end), with nothing built or sent now. Default if you skip it: A.
   - **Questions:** 2. **Anything else** — "Anything else you'd like to tell the maintainers: what
     worked, what didn't, what you'd want next? Reply with it, or write it in
     `<report folder>/feedback-comment.md` and say done." Default: nothing to add.
   - **Full report:** `<report folder>/feedback.md` (the notes).
   - **Next:** "I'll build the exact text that would be sent and show it to you here in full;
     nothing is sent until you approve it."
- **Building the preview.** Reply C → stop here (nothing is written; the offer comes back at the next
   stop). When the user said they would write in `feedback-comment.md`, wait until they say done (a
   missing or empty file then means nothing to add); a reply with the text is written there. Then build the payload (the address as one quoted argument, on one line):
   `cd <project root> && bash <download>/tools/hm-feedback.sh preview --notes <report folder>/feedback.md [--comment <report folder>/feedback-comment.md] [--contact "<email>"] --out <report folder>/feedback.json`
- **The preview message.** **The preview is the one thing in the onboarding shown in full in the chat:**
   the user approves the exact text, so it is never summarized or left to a file. One message:
   - **Where we are:** "this is exactly what would be sent", then the preview's text exactly as
     the script printed it.
   - **Decisions:** 1. **Send** — "Send this to the HumanMaxxing maintainers?" A) send exactly
     this; B) let me edit it first (edit `feedback.md` or `feedback-comment.md`, say done, and the
     preview runs and is shown again); C) don't send. Default if you skip it: C; nothing is sent on
     a skip.
   - **Full report:** `<report folder>/feedback.json` (what would be sent).
   - **Next:** on A, it is sent and you get a reference; on C, the notes stay on this machine.
- **The answer.** Send A → `cd <project root> && bash <download>/tools/hm-feedback.sh send --approved <the preview's FINGERPRINT> <report folder>/feedback.json`.
   Send C or a skip → create an empty `feedback.declined` in the report folder and give the notes'
   path; they are not offered again unless notes are added after it.

**What the script's exit codes mean.** Never retry in a loop, and never send it any other way.
- preview 0: written; show it (the preview message).
- preview 2: the address is not one plain email address → ask the Reply decision once more; a second
  bad address → no reply (preview again without `--contact`).
- 3 (preview or send): a missing tool, not inside the project, or an unreadable file → tell the
  user what is missing, give the notes' path, and stop offering in this session.
- 4 (preview or send): refused by a check, which lists categories, not the text → rewrite YOUR
  notes in generic words for each category it lists, then preview again; never delete a note to
  pass. If the hit is in the user's own comment, show the user your proposed rewording and ask;
  never reword their words silently. After a send 4, the new preview is shown and approved again.
- send 0: sent (give the user the reference it prints), or already sent (it says so; never send
  again).
- send 2: the payload changed since it was approved → preview again and show it again (the preview message).
- send 5: not sent (the service refused it or could not be reached) → say so, give the path, and
  say they can ask for it again later.

---

## Fail-safes (apply throughout, not just where mentioned above)

- **Never overwrite an existing `CLAUDE.md`, agent file, or folder `CLAUDE.md` without showing a
  diff and getting explicit approval, and never overwrite the user's own skill or command of the
  same name at all.** Before any copy into `.claude/skills/<name>/`, check that the folder does
  not exist yet (or is this download's own, per "Partial install"); if it exists and is not ours,
  do not copy: the step is `skipped (kept your <name>)`, with the costs Phase 1 lists. Every downstream artifact enforces this itself; this file
  does too. It touches directly only: the ledger and the reports in the report folder, the install
  record `.claude/humanmaxxing.lock`, the filled `worktree.env`, `ship.env` and `retro.env`,
  `.claude/critical-paths.txt`, the protected list, `.claude/hooks/hooks.env`, the settings file step 8 wires the
  hooks into (`hooks-install.sh plan` is that diff), the agent files in `.claude/agents/` that step 2 approves, the
  follow-ups file `<docs root>/humanmaxxing-follow-ups.md`, the lines of an `AGENTS.md` or
  `.gitignore` the user approved changing in Phase 1, and the one branch and sibling folder Step 0
  creates. `checkpoint`'s folders (session summaries, plans, findings) are not created by the
  install: the skill creates them the first time it writes.
- **A draft never goes to its target path before approval.** A merged `CLAUDE.md`, a details file,
  an agent file or any other file the user approves is drafted in the report folder
  (`$(git rev-parse --git-common-dir)/humanmaxxing/drafts/`, never committed), shown as a diff
  against the file it would replace, and written to its target once, after approval. When the draft
  is mostly new content (a short file merged into a long template), a diff says nothing: show
  instead where each of the user's existing lines went (the existing-instructions table: kept,
  merged, overridden), a one-line summary per section, the sections removed as not applying, and the
  draft's path. "Write it, then revert" is still a write over the user's file: it does not happen.
- **Each artifact is installed only at its own step.** Nothing is copied early "to prepare", not even
  into the onboarding worktree: a skill present before its step reads as installed to everything
  that checks, the resume check included.
- **Nothing leaves the machine without the user's approval of the exact bytes:** see "Feedback to
  the maintainers" (`hm-feedback.sh send` with the approved preview's fingerprint).
- **Partial install detected → gap-filling mode**, not a fresh run from zero (see "Before you
  begin").
- **An installed skill is a copy.** A newer download updates nothing by itself. Update each changed
  skill by **merging**, never by copying the folder over: take the product's changes and keep what
  the onboarding filled for this repo, which is exactly the `Values for this repo` block and any
  `allowed-tools` additions; the script-read config files (`ship.env`, `worktree.env`, `retro.env`);
  review-code's `references/detection-table.md` and the repo-specific audit blocks in review-code's
  `references/audits.md` and review-plan's `references/plan-audits.md`. Outside the skill folders,
  `.claude/critical-paths.txt` and the agent files in `.claude/agents/` belong to the repository
  once written: an update never replaces them. `bash <download>/tools/hm-lock.sh status --from
  <download>` (from inside the project) says WHICH items a newer release changed (`behind` needs a
  merge; exit 3 "no install record": compare every item by hand once, then record each);
  `diff -r -x '*.env' "<download>/skills/<name>" ".claude/skills/<name>"` shows WHAT changed. After
  the merge, record the item again (`hm-lock.sh record`). A filled template is updated by hand:
  `status` says it changed, the download's `CHANGELOG.md` says which rules.
- **An installed hook is a copy too**, holding no values of this repository (those are in
  `.claude/hooks/hooks.env`, the protected list and the settings file's `hooks` block, which an
  update keeps). `diff -r -x hooks.env <download>/hooks .claude/hooks` shows what a newer release
  changed; `bash <download>/hooks/bin/hooks-install.sh plan --update …` (same hooks, `--mode` and
  settings file) shows the update and `apply --update --approved <hash>` installs it once the user approves
  that plan. The installed scripts are protected files: in a guarded session the guard asks before
  any `hooks-install.sh … apply`, and that prompt is the second half of the approval; in the
  bypass-permissions or don't-ask mode it refuses, and the user runs the printed `apply` line in
  their own terminal. `hooks-check.sh` names any `hooks.env` key the new example adds. Record it
  again with `hm-lock.sh record … hooks`.
- **Every downstream artifact keeps its own gate**: the plan's approval never stands in for one
  (see the end of Phase 2).
- **The domain invariant cannot be skipped or defaulted** (see "The one thing this file will not
  guess"): the user picks it or writes it. A later finding against the chosen invariant follows
  Phase 1 (b): a wrong name is corrected, a change of meaning is one decision whose default is the
  corrected wording.
