# Contributing

Thanks for helping. Bug reports, onboarding feedback and pull requests are all welcome.

## Reporting a bug

Open a GitHub issue in this repository. Include:

- the release you are on (the `VERSION` file of the copy you installed from);
- your agent harness and version, your OS, and `bash --version`;
- what you ran or asked the agent to do, what you expected, and what happened, with the exact error text;
- the smallest steps that reproduce it, if you have them.

Never paste secrets, tokens, private code, or your own repository's names and paths. Reduce the example to
something generic first.

## Onboarding feedback

When the onboarding (`getting-started.claude.md`) finds an instruction unclear, it can collect notes and send them
with `tools/hm-feedback.sh`. Sending is opt-in: `preview` shows you the exact text, and `send` sends only those
bytes, after you approve them. It refuses text that contains your paths, git remote, git identity or common secret
formats. The header of `tools/hm-feedback.sh` documents its commands.

## Pull requests

This repository is an export of a private development repository. Each release is one squashed commit, so a
pull request here is not merged directly. Pull requests are welcome as proposals:

1. Open a pull request (or an issue first, for anything large) describing the problem and the change.
2. If the change is accepted, the maintainers port it into the private repository, and it lands in the next
   release commit. The author is credited in `CHANGELOG.md`.
3. The pull request is then closed with a link to the release that carries it.

`docs/genericize.md` describes the rules every file here follows: keep the process patterns, strip
organization-specific facts, and turn a load-bearing fact into a configuration slot or an extension point. Changes
to skills, templates and the onboarding should follow it.

## Running the tests

```bash
bash tests/run.sh
```

This runs `bash -n` and `shellcheck` (configured by `.shellcheckrc`, severity warning and above) on every shell
script, then every `tests/**/*.test.sh`. `shellcheck` must be installed: a missing linter is a failure, not a skip.
So must `jq` (on Windows: `winget install jqlang.jq koalaman.shellcheck`). A case the platform cannot build (an
unreadable file as root or on Windows, a symbolic link, a name Windows forbids, a tracked executable bit) prints
`SKIP` with the reason, never a pass.
`bash tests/run.sh <word>` runs only the test files whose path contains `<word>`. CI runs the same suite on Linux,
on macOS's system bash 3.2 and on Windows under Git for Windows' bash, so scripts must stay bash 3.2 compatible,
read a CRLF line end in any file a user edits as a line end, and treat git's `C:/…` paths as absolute.

## Security issues

Do not open a public issue for a security problem. Email feedback@humanmaxxing.ai with "security" in the subject
line, and include enough detail to reproduce it.
