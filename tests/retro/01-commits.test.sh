#!/usr/bin/env bash
# retro-data.sh: the commit mix (conventional prefixes and plain-message keywords), fix chains by file and folder, the
# window, which branch is read, and the configuration and usage refusals.
. "$(dirname "$0")/../lib.sh"

# --- conventional commits, a fix chain ------------------------------------------------------------------------------
t_retro_fixture conv
t_retro_commit 20 "fix: an old fix, outside the default window" src/api/a.ts
t_retro_commit 5 "feat: add the export button" src/ui/export.ts
t_retro_commit 4 "fix(api): handle an empty body" src/api/a.ts
t_retro_commit 3 "fix: two files in one folder, one commit" src/api/a.ts src/api/b.ts
t_retro_commit 2 "fix!: retry once" src/api/a.ts
t_retro_commit 2 "docs: explain the export" docs/export.md
t_retro_commit 2 "chore: bump a dependency" package.txt
t_retro_commit 1 "refactor: split a helper" src/ui/helper.ts
t_retro_commit 1 "Tidy up the build" build.txt
t_retro_commit 1 "prefix: not a conventional type" other.txt
git checkout -q -b side && t_retro_commit 1 "fix: on a side branch" src/api/side.ts && git checkout -q main
when="@$(( $(date +%s) - 3600 )) +0000"
GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git merge -q --no-ff -m "Merge branch side" side || exit 2
t_retro_push
t_retro_commit 0 "fix: committed but not pushed" src/api/a.ts

run bash "$R"
expect 0 '^RETRO-RESULT retro-data PASS complete$' "a git-only run with every optional source switched off is complete"
expect_out '^WINDOW days=7 since=[0-9T:-]+Z until=[0-9T:-]+Z$' "the window is printed"
expect_out '^REF refs/remotes/origin/main [0-9a-f]+ tip=' "origin/main is read when it exists"
expect_out '^REPORT path=docs/retros/retro-[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$' "the report path is under REPORT_DIR"
expect_out '^COMMITS total=10 feat=1 fix=4 chore=2 docs=1 other=2 style=conventional$' "conventional prefixes: the mix, merges left out, the unpushed commit and the old one not counted"
expect_out '^COMMIT [0-9a-f]+ fix fix\(api\): handle an empty body$' "a scoped fix is a fix, its subject kept whole"
expect_out '^COMMIT [0-9a-f]+ other prefix: not a conventional type$' "an unknown prefix is other"
expect_out '^COMMIT [0-9a-f]+ chore refactor: split a helper$' "refactor counts as chore"
refute_out 'Merge branch side' "the merge commit is not counted"
expect_out '^FIXCHAIN count=3 kind=file commits=[0-9a-f]+,[0-9a-f]+,[0-9a-f]+ src/api/a\.ts$' "three fixes of one file are a chain"
expect_out '^FIXCHAIN count=4 kind=dir commits=[0-9a-f,]+ src/api$' "the folder has four fix commits (the side-branch fix included)"
refute_out 'FIXCHAIN .*src/api/b\.ts' "a file fixed once is not a chain"
# The commits of a chain are listed oldest first.
first="$(git log --format=%h --since='5 days ago' --grep '^fix(api)' origin/main | head -1)"
expect_out "^FIXCHAIN count=3 kind=file commits=$first," "a chain lists its oldest commit first"

run bash "$R" --days 30
expect_out '^FIXCHAIN count=4 kind=file commits=[0-9a-f,]+ src/api/a\.ts$' "--days 30 reaches the old fix"
expect_out '^WINDOW days=30 ' "and says so"

# One commit touching three files of one folder is one hit for that folder.
t_retro_fixture once
t_retro_commit 3 "fix: one" lib/x.ts lib/y.ts lib/z.ts
t_retro_commit 2 "fix: two" lib/x.ts
t_retro_push
run bash "$R"
refute_out 'FIXCHAIN .* lib$' "a commit touching three files in a folder counts once for the folder"
t_retro_cfg "FIX_CHAIN_MIN=2"; t_retro_commit 1 "chore: lower the chain floor" cfg.txt; t_retro_push
run bash "$R"
expect_out '^FIXCHAIN count=2 kind=dir commits=[0-9a-f]+,[0-9a-f]+ lib$' "FIX_CHAIN_MIN lowers the floor, still one hit per commit"
expect_out '^FIXCHAIN count=2 kind=file commits=[0-9a-f]+,[0-9a-f]+ lib/x\.ts$' "and a file fixed twice is a chain at 2"

# Top-level files make file chains, never a chain for the repository itself.
t_retro_fixture top
for d in 3 2 1; do t_retro_commit "$d" "fix: readme $d" README.md; done
t_retro_push
run bash "$R"
expect_out '^FIXCHAIN count=3 kind=file commits=[0-9a-f,]+ README\.md$' "a top-level file can be a chain"
refute_out 'kind=dir .* \.$' "the repository root is not an area"

# With no remote configured, the local branch is read.
t_retro_fixture local "BASE_REMOTE="
t_retro_commit 1 "fix: only local" a.txt
run bash "$R"
expect_out '^REF refs/heads/main ' "BASE_REMOTE empty: the local branch is read"
expect_out '^COMMITS total=1 .*fix=1 ' "and its unpushed commit counts"

# --- plain messages, sorted by whole words ----------------------------------------------------------------------------
t_retro_fixture words "COMMIT_STYLE=keywords"
t_retro_commit 3 "Fix crash when saving" a.txt
t_retro_commit 3 "Add an export button" b.txt
t_retro_commit 2 "Update prefix handling" c.txt
t_retro_commit 2 "Address the review notes" d.txt
t_retro_commit 2 "Update the README" e.txt
t_retro_commit 1 "Bump deps" f.txt
t_retro_commit 1 "Fixed a typo in the docs" g.txt
t_retro_push
run bash "$R"
expect_out '^COMMITS total=7 feat=1 fix=2 chore=1 docs=1 other=2 style=keywords$' "keywords: the mix"
expect_out '^COMMIT [0-9a-f]+ other Update prefix handling$' "'prefix' is not the word 'fix'"
expect_out '^COMMIT [0-9a-f]+ other Address the review notes$' "'address' is not the word 'add'"
expect_out '^COMMIT [0-9a-f]+ fix Fixed a typo in the docs$' "fix words win over docs words"
expect_out '^COMMIT [0-9a-f]+ docs Update the README$' "README is a docs word"
t_retro_cfg "COMMIT_STYLE=keywords" "FIX_WORDS=oops,Repair"
t_retro_commit 1 "Oops, the save button" h.txt; t_retro_commit 1 "repair the cache" i.txt; t_retro_push
run bash "$R"
expect_out '^COMMIT [0-9a-f]+ fix Oops, the save button$' "FIX_WORDS replaces the fix list"
expect_out '^COMMIT [0-9a-f]+ fix repair the cache$' "words match without regard to case"
expect_out '^COMMIT [0-9a-f]+ other Fix crash when saving$' "a word left out of the custom list no longer counts"

# --- refusals -------------------------------------------------------------------------------------------------------
t_retro_fixture cfg
run bash "$R" --days 0; expect 2 'FAIL usage' "--days 0 is a usage error"
run bash "$R" --days abc; expect 2 'FAIL usage' "--days abc is a usage error"
run bash "$R" --days; expect 2 'FAIL usage' "--days with no value is a usage error"
run bash "$R" --frobnicate; expect 2 'FAIL usage' "an unknown option is a usage error"
run bash "$R" --config "$FIX/nope.env"; expect 2 'FAIL config-missing' "a missing configuration file is refused"
t_retro_cfg "COMMIT_STYLE=angular"; run bash "$R"; expect 2 'FAIL config-commit-style' "an unknown commit style is refused"
t_retro_cfg "TRACKER=jira"; run bash "$R"; expect 2 'FAIL config-tracker' "an unknown tracker is refused"
printf 'BASE_BRANCH=main\nCOMMIT_STYLE=conventional\nREPORT_DIR=docs/retros\n' > "$CFG"
run bash "$R"; expect 2 'FAIL config-tracker' "TRACKER is required: never defaulted"
t_retro_cfg "REPORT_DIR="; run bash "$R"; expect 2 'FAIL config-report-dir' "REPORT_DIR is required"
t_retro_cfg "REPORT_DIR=/tmp/elsewhere"; run bash "$R"; expect 2 'FAIL config-malformed' "an absolute report folder is refused"
t_retro_cfg "FINDINGS_DIR=../outside"; run bash "$R"; expect 2 'FAIL config-malformed' "a folder outside the repository is refused"
t_retro_cfg "FIX_CHAIN_MIN=1"; run bash "$R"; expect 2 'FAIL config-malformed' "a chain floor below 2 is refused"
t_retro_cfg "TRACKER= # github"; run bash "$R"; expect 2 'FAIL config-malformed' "a value that is a comment is malformed, never empty"
t_retro_cfg "BASE_BRANCH=nope"; run bash "$R"; expect 3 'FAIL base-unreadable' "a base branch that does not exist is a failed read"
t_retro_cfg
cp "$CFG" "$T_TMP/outside.env"
( cd "$T_TMP" && OUT="$(bash "$FIX/work/$R" --config "$T_TMP/outside.env" 2>&1)"; echo "$?" > "$T_TMP/rc"; printf '%s\n' "$OUT" > "$T_TMP/out" )
OUT="$(cat "$T_TMP/out")"; RC="$(cat "$T_TMP/rc")"; LAST="$(printf '%s\n' "$OUT" | tail -1)"
expect 3 'FAIL not-a-repo' "outside a git repository: a failed read, nothing printed as a number"
refute_out '^COMMITS ' "and no commit count"
t_done
