<h1 align="center">Maximize <em>the human side</em><br>of the equation.</h1>

<p align="center">
  <strong>Spend your time on impactful decisions, not babysitting AI.</strong><br>
  The AI framework that adapts to your codebase, <a href="https://humanmaxxing.ai/receipts">with receipts</a>.
</p>

| **Focus** | **Craft** | **Trust** |
|---|---|---|
| Put human judgment where it earns the most. | Continuously sharpen your craft of working with AI, driven by real-world results. | Maximize your trust in the AI output, so you can own what ships. |

<p align="center"><strong>Scale</strong> · Standardize your team’s AI process, so every gain can be measured and repeated.</p>

<p align="center"><a href="https://humanmaxxing.ai">humanmaxxing.ai</a> · <a href="https://humanmaxxing.ai/framework">The framework</a> · <a href="#start-here">Start here</a></p>

---

## HumanMaxxing: skills, templates, and onboarding for running AI coding agents well

Generic, drop-in versions of the Claude Code skills, agent templates, and onboarding flow we run
internally. Each skill is a self-contained directory (`SKILL.md` plus, where it earns one,
`references/`) that any team can place under `.claude/skills/<name>/` and adapt through its
Configuration block. Other harnesses that read `SKILL.md` (Codex, Copilot CLI, Cursor, Gemini CLI)
can use them too; where a skill depends on a harness capability, it says so and degrades visibly.

## Start here

Clone this repo (or download and unpack it) somewhere outside your project, for example
`~/humanmaxxing`. Then open your agent in your project and tell it:

> Read `~/humanmaxxing/getting-started.claude.md` and follow it.

If the copy has to live inside your project, put it in a folder git ignores (`.git/info/exclude`)
so it is never committed.

It interviews you once, verifies your answers against the repo, proposes an ordered install plan,
stops for your approval, and installs one artifact at a time with a resumable ledger.

**Tools.** The scripts need `bash`, `git` and the usual POSIX tools; `gh` for anything that reads GitHub, and `jq`
for `ship` and for installing the hooks (the hooks themselves use `jq`, else `python3`, else a cautious no-parser mode).
**On Windows**, Claude Code runs commands in Git for Windows' bash, which brings everything except `jq` and `gh`:
`winget install jqlang.jq` and `winget install GitHub.cli`. `python3` is optional; the Microsoft Store alias that
answers to `python3` without installing anything is detected and treated as no python.

## What's here

| Path | What it is |
|---|---|
| `getting-started.claude.md` | Day-zero onboarding: interview → survey → plan (human gate) → install → first-week calendar |
| `templates/` | `CLAUDE.template.md` (the behavioral contract) and `claude-details.template.md` (long-form procedures it points into) |
| `skills/start` | Kick off work on an issue: root-cause discovery with domain subagents, then a reviewed plan |
| `skills/review-plan` | Multi-perspective plan review before any code is written |
| `skills/review-code` | Multi-perspective code review with a fix pass and an external second-opinion gate; writes the sentinels `ship` checks |
| `skills/peer-review` | Reviewer-side verdict on someone else's PR: Code, Test coverage and Merge-readiness, each with `file:line` evidence from the PR's head; read-only unless you ask it to comment |
| `skills/worktree` | One folder per branch: scripted create, list and remove of worktrees (one folder per branch), an issue shorthand, and a launcher from issue number to session |
| `skills/checkpoint` | Commit flow: docs, quality checks, commit (commit-only: pull requests are `ship`'s) |
| `skills/ship` | Commit → PR → merge with blocking quality and E2E gates |
| `skills/retro` | Weekly read-only retrospective: commit mix, fix chains, issues opened vs closed, recurring review findings, an audit of fixes that patched one instance instead of the class, and whether the install is behind the latest release. Writes one report; suggestions become issues or rule changes only when you approve each |
| `skills/trim` | Writes a `/compact` command tailored to the conversation (keeps decisions, reasoning and pending work; drops redundant tool output); before a compact headed for a ship or a commit of unreviewed code it checks ship's review sentinel and runs review-code first |
| `skills/bootstrap-agents` | Surveys your repo and proposes a subagent roster and the reviewer detection table |
| `skills/bootstrap-claude-mds` | Proposes folder-level `CLAUDE.md` files where they are earned |
| `docs/genericize.md` | How an internal skill becomes a public one — the policy every file here followed |
| `VERSION`, `CHANGELOG.md` | The release version, and per release what changed and what an installed copy has to merge |
| `hooks/` | The first hooks pack, for Claude Code: a protected-file guard (asks for your approval before the agent changes a file you listed), a commit check (refuses a commit while your check fails), and a reprint of the question the agent is waiting on. Onboarding step 8 installs all three into `.claude/hooks/`, the guard and the commit check in warn mode (they print what they would have refused and never block; switching them on is a proposed follow-up); `bin/hooks-install.sh` shows the settings change as a diff before it writes anything |
| `tools/hm-lock.sh` | The install record: which release each installed item came from, and which ones a newer download changed |
| `tools/hm-feedback.sh` | Sends the onboarding's notes on unclear instructions to the maintainers, only as you approved them: it shows the exact text first, sends only those bytes, and refuses your paths, remote, git identity and common secret formats |

## Status

0.1.0 is the first public release. It includes the onboarding guide, the two templates, eleven skills (`start`,
`review-plan`, `review-code`, `peer-review`, `worktree`, `checkpoint`, `ship`, `retro`, `trim`, `bootstrap-agents`,
`bootstrap-claude-mds`), the first hooks pack for Claude Code, and the `hm-lock.sh` and `hm-feedback.sh` tools.
The shell scripts have a test suite (`bash tests/run.sh`) that CI runs on Linux, on macOS's bash 3.2 and on Windows (Git for Windows' bash).
[CHANGELOG.md](CHANGELOG.md) lists what each release changed. See each skill's Configuration block for what you
must fill in before first use.

## Updates

To hear about new releases, use **Watch → Custom → Releases** on this repository. Installed skills are copies,
so nothing updates on its own: `/retro` reports when a newer release is out (when you installed from a `git clone`),
and [CHANGELOG.md](CHANGELOG.md) says what each release changed and how to merge it into your copy.

## Contributing

Bug reports, onboarding feedback and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
