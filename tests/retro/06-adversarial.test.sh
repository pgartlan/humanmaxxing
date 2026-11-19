#!/usr/bin/env bash
# retro-data.sh, hostile and boundary inputs: the configuration refusals the other files leave out, a repository whose
# path has a space, a run from a subfolder, an empty window, a remote that has no tracking branch yet, file names git
# quotes, and guard patterns that are only blanks.
. "$(dirname "$0")/../lib.sh"

# --- refusals not reached elsewhere ---------------------------------------------------------------------------------
t_retro_fixture adv
run bash "$R" --days 3661; expect 2 'FAIL usage$' "--days above 3660 is a usage error"
run bash "$R" --days 3660; expect 0 'PASS complete$' "--days 3660, the upper bound, is accepted"
run bash "$R" --days -1; expect 2 'FAIL usage$' "--days -1 is a usage error"
run bash "$R" --config ""; expect 2 'FAIL usage$' "--config with an empty value is a usage error"
run bash "$R" --download ""; expect 2 'FAIL usage$' "--download with an empty value is a usage error"
run bash "$R" --help; expect 2 'FAIL usage$' "--help prints the usage, routed as usage"
t_retro_cfg "BASE_BRANCH="; run bash "$R"; expect 2 'FAIL config-base-branch$' "an empty BASE_BRANCH is refused"
t_retro_cfg "BASE_BRANCH=--output=x"; run bash "$R"; expect 2 'FAIL config-base-branch$' "a BASE_BRANCH that reads as an option is refused"
t_retro_cfg "BASE_BRANCH=main;id"; run bash "$R"; expect 2 'FAIL config-base-branch$' "a BASE_BRANCH with shell characters is refused"
t_retro_cfg "BASE_REMOTE=-x"; run bash "$R"; expect 2 'FAIL config-malformed$' "a BASE_REMOTE that reads as an option is refused"
t_retro_cfg "BASE_REMOTE=up stream"; run bash "$R"; expect 2 'FAIL config-malformed$' "a BASE_REMOTE with a space is refused"
t_retro_cfg "CLAUDE_MD=/etc/passwd"; run bash "$R"; expect 2 'FAIL config-malformed$' "an absolute rules file is refused"
t_retro_cfg "FINDINGS_DIR=docs/../../x"; run bash "$R"; expect 2 'FAIL config-malformed$' "a folder that climbs out through .. is refused"
t_retro_cfg "REPORT_DIR=.."; run bash "$R"; expect 2 'FAIL config-malformed$' "a report folder of .. is refused"
t_retro_cfg "RELEASE_REPO_URL=-oProxyCommand=x"; run bash "$R"; expect 2 'FAIL config-malformed$' "a release URL that starts with - is refused"
t_retro_cfg; printf 'just words\n' >> "$CFG"; run bash "$R"; expect 2 'FAIL config-malformed$' "a line that is not KEY=value is malformed"
t_retro_cfg; printf 'BAD-KEY=1\n' >> "$CFG"; run bash "$R"; expect 2 'FAIL config-malformed$' "a key with a dash is malformed"
t_retro_cfg; printf 'TRACKER=none\rx\n' >> "$CFG"; run bash "$R"; expect 2 'FAIL config-malformed$' "a CR inside a line (not its end) is malformed, not read with a stray CR"
# CRLF line ends (Git for Windows checks text out that way by default) read as LF: the rules-file path still opens.
t_retro_cfg "CLAUDE_MD=CLAUDE.md"; run bash "$R"; LF_OUT="$(printf '%s\n' "$OUT" | grep -v '^WINDOW ')"
cp "$CFG" "$FIX/lf.env"; t_crlf "$FIX/lf.env" "$CFG"
run bash "$R"; expect 0 'PASS complete$' "a retro.env with CRLF line ends runs"
expect_out '^THRESHOLD value=3 CLAUDE\.md$' "…and its CLAUDE_MD path, read without a CR, opens"
[ "$(printf '%s\n' "$OUT" | grep -v '^WINDOW ')" = "$LF_OUT" ] && t_pass "…and reports exactly what the LF file does" \
  || t_fail "…and reports exactly what the LF file does" "LF: $LF_OUT"
t_crlf "$T_ROOT/skills/retro/retro.env.example" "$CFG"
run bash "$R"; refute_out 'config-malformed' "a CRLF copy of retro.env.example is not malformed"
t_retro_cfg; chmod 000 "$CFG"
if [ -r "$CFG" ]; then t_skip "an unreadable configuration: chmod cannot take read access away here (root, or Windows)"
else run bash "$R"; expect 2 'FAIL config-malformed$' "an unreadable configuration is refused, never read as empty"; fi
chmod 644 "$CFG"
t_retro_cfg "TRACKER=none" "TRACKER=github" "TRACKER=none"; run bash "$R"
expect 0 'PASS complete$' "a key given twice: the last line wins"
expect_out '^NOT-CONFIGURED issues reason=tracker-none$' "and the last value is the one used"
t_retro_cfg

# --- an empty window: real zeros, a complete run ----------------------------------------------------------------------
run bash "$R"
expect 0 'PASS complete$' "no commit in the window: complete"
expect_out '^COMMITS total=0 feat=0 fix=0 chore=0 docs=0 other=0 style=conventional$' "and every count is a real zero"
refute_out '^(COMMIT|FIXCHAIN) ' "with no commit or chain line"

# --- the remote is configured but its tracking branch does not exist yet: the local branch is read -----------------
git update-ref -d refs/remotes/origin/main || exit 2
t_retro_commit 1 "fix: local only" a.txt
run bash "$R"
expect 0 'PASS complete$' "no origin/main: complete"
expect_out '^REF refs/heads/main ' "the local branch is read when origin/main is absent"
expect_out '^COMMITS total=1 ' "and its commit counts"
git fetch -q origin || exit 2

# --- a run from a subfolder reads the whole repository and names the report from the root --------------------------
t_retro_commit 1 "fix: deep" src/deep/x.ts; t_retro_push
mkdir -p src/deep && cd src/deep || exit 2
run bash "../../$R"
expect 0 'PASS complete$' "a run from a subfolder: complete"
expect_out '^COMMITS total=2 ' "every commit of the window, not only the subfolder's"
expect_out '^REPORT path=docs/retros/retro-' "the report path stays relative to the repository root"
cd "$FIX/work" || exit 2

# --- a repository whose path has a space; findings and guard files whose names have a space -------------------------
t_retro_fixture "with space" "FINDINGS_DIR=docs/review notes" "GUARD_GLOBS=lint/**"
t_retro_commit 2 "fix: one" "src/my dir/a b.ts"
t_retro_commit 1 "fix: two" "src/my dir/a b.ts"
t_retro_commit 1 "fix: three" "src/my dir/a b.ts"
t_retro_commit 1 "docs: a review" "docs/review notes/branch one.md"
t_retro_commit 1 "chore: a guard" "lint/no tabs.yml"
t_retro_push
run bash "$R"
expect 0 'PASS complete$' "a repository under a path with a space: complete"
expect_out '^FIXCHAIN count=3 kind=file commits=[0-9a-f,]+ src/my dir/a b\.ts$' "a file name with spaces is a chain, its path kept whole and last"
expect_out '^FIXCHAIN count=3 kind=dir commits=[0-9a-f,]+ src/my dir$' "and its folder with a space too"
expect_out '^FINDINGS files=1$' "a findings folder with a space is read"
expect_out '^FINDINGS-FILE docs/review notes/branch one\.md$' "and its file listed whole"
expect_out '^GUARDS added=1 ' "a guard file with a space is counted"
expect_out '^GUARD-FILE lint/no tabs\.yml$' "and listed whole"

# --- names git quotes (non-ASCII): a findings file is never dropped in silence ----------------------------------------
t_retro_fixture quoted "FINDINGS_DIR=docs/findings"
t_retro_commit 1 "docs: a plain review" docs/findings/plain.md
t_retro_commit 1 "docs: a review with an accent" "docs/findings/caf$(printf '\303\251').md"
E="$(printf '\303\251')"
t_retro_commit 3 "fix: one" "src/caf$E.ts"; t_retro_commit 2 "fix: two" src/plain.ts; t_retro_commit 1 "fix: three" src/plain.ts
t_retro_push
run bash "$R"
expect_out '^FINDINGS files=2$' "a findings file with a non-ASCII name is counted, not dropped"
expect_out '^FIXCHAIN count=3 kind=dir commits=[0-9a-f,]+ src$' "a fix of a non-ASCII file counts toward its folder's chain"
refute_out '^[A-Z-]+ .*"' "no path is printed in git's quoted form"

# --- guard patterns that are only blanks: never a count of every file added ----------------------------------------
t_retro_fixture blank
t_retro_commit 1 "chore: an ordinary file" src/app.ts
t_retro_commit 1 "chore: another" docs/readme.md
t_retro_push
t_retro_cfg "GUARD_GLOBS=   "
run bash "$R"
refute_out '^GUARD-FILE ' "blank guard patterns list no guard file"
refute_out '^GUARDS added=[1-9]' "and never count every file added in the window as a guard"
# --- --days with a leading zero is decimal, never octal --------------------------------------------------------------
t_retro_fixture oct
run bash "$R" --days 010
expect 0 'PASS complete$' "--days 010: complete"
expect_out '^WINDOW days=10 ' "--days 010 is ten days, not eight"
run bash "$R" --days 08
expect 0 'PASS complete$' "--days 08 is eight days, never a failed date"
expect_out '^WINDOW days=8 ' "and the window says 8"
run bash "$R" --days 0000; expect 2 'FAIL usage$' "--days 0000 is zero days: a usage error"

# --- paths git quotes even with core.quotePath=false: read raw, or the section says it could not be read ---------------
if ! t_can_name 'q"x' || ! t_can_name 'b\s' || ! t_can_name "t$(printf '\t')x"; then
  t_skip "names with a double quote, a backslash or a tab: this filesystem cannot make them (Windows)"
else
t_retro_fixture qchars "FINDINGS_DIR=docs/findings"
t_retro_commit 1 "docs: a" 'docs/findings/q"uote.md'
t_retro_commit 1 "docs: b" 'docs/findings/back\slash.md'
t_retro_commit 3 'fix: one' 'src/q"x/a.ts'; t_retro_commit 2 'fix: two' 'src/q"x/b.ts'; t_retro_commit 1 'fix: three' 'src/q"x/a.ts'
t_retro_push
run bash "$R"
expect 0 'PASS complete$' "names with a double quote and a backslash: complete"
expect_out '^FINDINGS files=2$' "both findings files are counted"
expect_out '^FINDINGS-FILE docs/findings/q"uote\.md$' "a double quote stays raw"
expect_out '^FINDINGS-FILE docs/findings/back\\slash\.md$' "a backslash stays raw"
expect_out '^FIXCHAIN count=3 kind=dir commits=[0-9a-f,]+ src/q"x$' "a folder with a double quote is one chain"
t_retro_commit 1 "docs: c" "docs/findings/tab$(printf '\t')x.md"
t_retro_commit 1 "fix: four" "src/tab$(printf '\t')y.ts"
t_retro_push
run bash "$R"
expect 3 'PARTIAL unavailable=fixchains,findings$' "a tab in a name: those sections are partial"
expect_out '^UNAVAILABLE findings reason=unparseable-path' "findings: unparseable-path, never a count"
expect_out '^UNAVAILABLE fixchains reason=unparseable-path' "fix chains: unparseable-path"
refute_out '^FINDINGS files=' "no findings count"
refute_out '^FIXCHAIN ' "no fix chain"
expect_out '^COMMITS total=' "the commit mix still stands"
fi

# --- a word list with glob characters is matched literally, never against file names ----------------------------------
t_retro_fixture wglob "COMMIT_STYLE=keywords" "FIX_WORDS=*"
t_retro_commit 1 "Update docs" docs/x.md
t_retro_commit 1 "README cleanup" docs/y.md
t_retro_push
run bash "$R"
refute_out '^COMMIT [0-9a-f]+ fix ' "FIX_WORDS=* does not expand to the root's file names"
expect_out '^COMMIT [0-9a-f]+ docs README cleanup$' "the other lists still sort the commit"

# --- a relative --download from a subfolder is the folder the user named ---------------------------------------------
t_retro_fixture reldl
mkdir -p dl/tools sub && cp "$T_ROOT/tools/hm-lock.sh" dl/tools/ && echo 0.2.0 > dl/VERSION
OUT="$(cd sub && bash "../$R" --download ../dl 2>&1)"
refute_out 'reason=download-without-hm-lock' "a relative --download resolves from where the user ran it"
expect_out '^UNAVAILABLE currency reason=hm-lock-failed .*no install record' "and reaches the download's hm-lock"

# --- the download's hm-lock.sh: empty output, a crash after the SOURCE line, an exit that disagrees with its items ----
t_retro_fixture hmodd
mkdir -p "$FIX/dl0/tools"; printf '#!/bin/sh\nexit 0\n' > "$FIX/dl0/tools/hm-lock.sh"
run bash "$R" --download "$FIX/dl0"
expect_out '^UNAVAILABLE currency reason=hm-lock-unexpected-output' "a status with no SOURCE line is unavailable"
mkdir -p "$FIX/dl1/tools"
printf '#!/usr/bin/env bash\necho "SOURCE version=0.5.0"\nset -u; echo "$nope"\n' > "$FIX/dl1/tools/hm-lock.sh"
run bash "$R" --download "$FIX/dl1"
expect 3 'PARTIAL unavailable=currency$' "a status that crashed after SOURCE: partial"
refute_out '^CURRENCY ' "and prints no currency numbers"
expect_out '^UNAVAILABLE currency reason=hm-lock-failed' "it is hm-lock-failed"
mkdir -p "$FIX/dl2/tools"
printf '#!/bin/sh\necho "SOURCE version=0.5.0"\necho "ITEM skills/a current recorded=0.5.0 source=0.5.0"\nexit 1\n' > "$FIX/dl2/tools/hm-lock.sh"
run bash "$R" --download "$FIX/dl2"
expect_out '^UNAVAILABLE currency reason=hm-lock-failed exit 1 does not match' "exit 1 with nothing behind or gone is not a status"
t_done
