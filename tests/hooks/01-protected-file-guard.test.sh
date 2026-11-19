#!/usr/bin/env bash
# protected-file-guard.sh: an edit of a protected file is asked about (or refused where nobody can be asked), a read
# or an unlisted file passes silently, and no error path allows silently.
# Mutations this file must catch (run once by hand with HOOKS_UNDER_TEST=<mutated copy of hooks/>):
#   drop the symlink walk (hk_resolve returns the path as given) · drop the Bash branch · a missing list → allow ·
#   answer "ask" in bypassPermissions mode · treat every git subcommand as a read.
. "$(dirname "$0")/../lib.sh"

unset CLAUDE_PROJECT_DIR   # the session's start folder is given per case; never the runner's own
t_hook_fixture guard
E() { t_hook protected-file-guard "$(t_tool_json Edit file_path "$1" "${2:-default}" "${3:-$HR}")"; }
B() { t_hook protected-file-guard "$(t_tool_json Bash command "$1" "${2:-default}" "${3:-$HR}")"; }

# --- file tools -----------------------------------------------------------------------------------------------------
E "$HR/.gitignore";                         expect_decision ask  "Edit of a listed file → ask"
expect_out '\.gitignore' "the answer names the file"
expect_out 'protected-files\.txt' "the answer names the list it matched in"
expect_out "user's approval" "the answer names the rule"
t_hook protected-file-guard "$(t_tool_json Write file_path "$HR/.gitignore")"; expect_decision ask "Write of a listed file → ask"
t_hook protected-file-guard "$(t_tool_json NotebookEdit notebook_path "$HR/config/a.lock")"; expect_decision ask "NotebookEdit (notebook_path) of a listed file → ask"
E "$HR/src/app.ts";                         expect_decision none "Edit of an unlisted file → allowed silently"
E "$HR/.github/workflows/ci.yml";           expect_decision ask  "a * glob matches one level"
E "$HR/.github/workflows/sub/ci.yml";       expect_decision none "a * glob does not cross a /"
E "$HR/deep/er/secrets.json";               expect_decision ask  "a **/ glob matches at any depth (new file in new folders)"
E "$HR/secrets.json";                       expect_decision ask  "a **/ glob matches at the top level too"
E "$HR/config/x.lock";                      expect_decision ask  "new file in a protected directory → ask"
E ".gitignore";                             expect_decision ask  "a relative path is resolved against cwd"
mkdir -p "$HR/src"; E "$HR/src/../.gitignore"; expect_decision ask "a .. path is folded"
if t_can_symlink; then
  ln -s .gitignore "$HR/alias"; E "$HR/alias"; expect_decision ask "a symlink to a listed file → ask"
  mkdir -p "$HR/elsewhere"; ln -s "$HR/config" "$HR/elsewhere/cfg"; E "$HR/elsewhere/cfg/y.lock"; expect_decision ask "a path through a symlinked folder → ask"
else t_skip "symlinks to a listed file or folder: ln -s copies instead of linking here (Windows without developer mode)"; fi
E "$HR/.claude/hooks/hooks.env";            expect_decision ask  "the hooks folder is always protected"
expect_out "guard.s own files, always protected" "the answer says a built-in matched"
E "$HR/.claude/hooks/protected-file-guard.sh"; expect_decision ask "the guard itself is protected"
E "$HR/.claude/protected-files.txt";        expect_decision ask  "the list itself is always protected"

# Case: folded only where the filesystem folds case (the probe is stubbed both ways).
HOOKS_CASE_FOLD=1 E "$HR/.GitIgnore";       expect_decision ask  "case-varied name on a case-folding filesystem → ask"
HOOKS_CASE_FOLD=0 E "$HR/.GitIgnore";       expect_decision none "case-varied name on a case-sensitive filesystem → allowed"

# --- permission modes -----------------------------------------------------------------------------------------------
E "$HR/.gitignore" bypassPermissions;      expect_decision deny "bypassPermissions → deny (nobody is asked there)"
expect_out 'makes this change by hand' "the deny says how the human makes the edit"
E "$HR/.gitignore" dontAsk;                expect_decision deny "dontAsk → deny"
E "$HR/.gitignore" acceptEdits;            expect_decision ask  "acceptEdits → ask"
E "$HR/.gitignore" auto;                   expect_decision ask  "auto → ask"
E "$HR/src/app.ts" bypassPermissions;      expect_decision none "bypassPermissions, unlisted file → allowed"

# --- Bash -----------------------------------------------------------------------------------------------------------
for c in 'cat .gitignore' 'git diff .gitignore' 'grep -n x .gitignore | head -3' 'git -C . log -- .gitignore' \
         'cat .gitignore 2>/dev/null' 'wc -l .github/workflows/ci.yml && ls .github/workflows/' 'git add .gitignore' \
         'find .github/workflows -name x' 'bash .claude/hooks/hooks-check.sh' "bash $HR/.claude/hooks/hooks-check.sh" \
         'diff -r -x hooks.env /tmp/download/hooks .claude/hooks' 'jq .hooks .claude/settings.json' 'cmp a .gitignore'; do
  B "$c"; expect_decision none "read: $c"
done
for c in 'echo x > .gitignore' 'echo x >> .gitignore' 'tee .gitignore < /dev/null' "sed -i 's/a/b/' .gitignore" \
         'mv .gitignore x' 'rm .gitignore' 'git checkout -- .gitignore' 'cat .gitignore; rm -f y' \
         'echo x > .git\ignore' "echo x > '.git'ignore" 'find .github/workflows -delete' 'cp a .github/workflows/ci.yml' \
         'sort -o .gitignore .gitignore' 'git diff --output=.gitignore' 'cat .gitignore &' 'cat $(echo .gitignore)' \
         'python3 -c "open(\".gitignore\",\"w\")"' 'echo x > .claude/hooks/hooks.env' \
         'bash .claude/hooks/hooks-check.sh; rm x' 'bash .claude/hooks/commit-check.sh' 'bash .claude/hooks/hooks-check.sh > out' \
         'bash .claude/hooks/hooks-check.sh --x' 'jq . .claude/settings.json > .claude/settings.json'; do
  B "$c"; expect_decision ask "write or unprovable: $c"
done
B 'echo hello > notes.txt';               expect_decision none "a command that names no protected file → allowed"
B 'rm -rf build && make';                 expect_decision none "a destructive command that names no protected file is not this guard's business"
B 'echo x > .gitignore' bypassPermissions; expect_decision deny "Bash write in bypassPermissions → deny"

# --- review findings: writes hidden in the read list, parent folders, whole-tree git, the installer --------------------
for c in 'uniq /dev/null .gitignore' 'xxd x .gitignore' 'less -o .gitignore x' 'less -O.gitignore x' \
         'rg --pre ./x y .gitignore' 'git -c core.pager=x diff .gitignore' 'git diff --ext-diff .gitignore' \
         'git diff --textconv .gitignore'; do
  B "$c"; expect_decision ask "a 'read' that can write or run code: $c"
done
for c in 'rm -rf .claude' 'rm -rf .claude/' 'rm -rf .claude/*' 'rm -rf ./.claude' 'mv .claude /tmp/x' 'rm -rf .github' \
         "rm -rf $HR/.claude" 'cp -r /tmp/x .github/.' 'rm -rf .' 'rm -rf *' 'rm -rf ./*' \
         'git checkout HEAD~1 -- .github/' 'git restore -s HEAD~1 -- .github' 'git checkout .' 'git restore .' \
         'git clean -fdx' 'git reset --hard' 'git reset --hard HEAD~1' 'git stash' 'git stash pop' \
         'git apply x.patch' 'git am x.mbox' 'patch -p1 -i x.patch'; do
  B "$c"; expect_decision ask "a parent folder or the whole tree: $c"
done
for c in 'ls .claude' 'ls -la .github/' 'git status' 'git stash list' 'rm -rf build' 'docker build .' 'npm test' \
         'cp -r src dst' 'git diff .github' 'find . -name x' 'grep -r x .claude'; do
  B "$c"; expect_decision none "still not asked: $c"
done
# Output options bundle and abbreviate: `sort -uo F`, `sort --o=F`, `less -So F`, `less --log-f=F` all write F.
for c in 'sort -uo .gitignore .gitignore' 'sort --out=.gitignore .gitignore' 'sort --o=.gitignore x' \
         'sort -ro.claude/settings.json x' 'less -So.gitignore x' 'less -SO .gitignore x' 'less --log-f=.gitignore x' \
         'less --LOG-F=.gitignore x'; do
  B "$c"; expect_decision ask "a bundled or abbreviated output option is a write: $c"
done
for c in 'sort .gitignore' 'sort -u .gitignore' 'sort -r -n .gitignore' 'less -S .gitignore' 'less -N .gitignore'; do
  B "$c"; expect_decision none "sort and less without an output option are reads: $c"
done

# Spellings of the same folder or file: `.`, `..` and `//` inside a word, the top folder with a trailing slash, `..`
# and relative names from a subfolder session, ~/ spellings.
EVIL="$T_TMP/evil"; mkdir -p "$EVIL/.claude" "$HR/sub" "$HR/src"
for c in 'rm -rf sub/../.claude' 'rm -rf .//.claude' 'rm -r .claude/./hooks' 'rm .claude/./settings.json' \
         'cp x .claude//settings.json' 'cp x src/../.gitignore' "rm -rf $HR/" "cp -r $EVIL/.claude $HR/" \
         "rsync -a $EVIL/ $HR/" "rm -rf $HR/./" 'rm -rf ..'; do
  B "$c"; expect_decision ask "another spelling of a protected folder, file or the whole repository: $c"
done
for c in 'rm -rf ../.claude' 'rm -rf ..' "cp -r $EVIL/.claude ../" "cp -r $EVIL/.claude .." 'rm ../.gitignore' \
         'mv x ../.github/workflows/ci.yml'; do
  B "$c" default "$HR/sub"; expect_decision ask "from a subfolder session: $c"
done
B 'rm settings.json' default "$HR/.claude";  expect_decision ask "from inside .claude: a relative name is judged from the top"
for c in 'rm -rf build' 'ls ..' 'cat ../.gitignore' 'npm test' 'cp a b' 'rm -rf ./tmp'; do
  B "$c" default "$HR/sub"; expect_decision none "from a subfolder session, still not asked: $c"
done
B "cp notes.txt $T_TMP/";                     expect_decision none "copying into a folder above the repository is not asked"
HOME="$(dirname "$HR")" B "cp -r $EVIL/.claude ~/$(basename "$HR")/"; expect_decision ask "the repository spelled through ~/ with a trailing slash → ask"

B 'bash /tmp/download/hooks/bin/hooks-install.sh apply --update --hooks commit-check --settings .claude/settings.local.json --approved 1-2'
expect_decision ask "the installer's apply → ask (it writes the guard's own files)"
B 'bash /tmp/download/hooks/bin/hooks-install.sh plan --hooks commit-check --settings .claude/settings.local.json'
expect_decision none "the installer's plan writes nothing → not asked"

# --- re-review: deletes and extractions over the whole tree -------------------------------------------------------------
for c in 'find . -delete' 'find . -name x -delete' 'find . -name "*.tmp" -exec rm {} +' 'find .claude -delete' \
         'git rm -r .' 'tar xf a.tar' 'tar -xzf a.tgz' 'bsdtar -xf a.tar' '7z x a.7z' '7za x a.7z' '7zr e a.7z' 'cpio -i' 'cpio -id' 'unzip -o a.zip' 'unzip a.zip -d .'; do
  B "$c"; expect_decision ask "whole-tree delete or extraction: $c"
done
for c in 'find build -delete' 'find . -name x' 'git rm -r build' 'git rm -r --cached .' 'tar cf a.tar src' 'tar -czf out.tgz x' 'unzip -l a.zip' '7z l a.7z' 'bsdtar -tf a.tar' 'cpio -t'; do
  B "$c"; expect_decision none "not the protected tree, or not a write: $c"
done

# --- re-review: git pointed at a folder, git's whole-tree pathspecs, find with no folder ------------------------------
for c in 'git -C .claude checkout -- settings.json' 'git -C config checkout -- x.lock' 'git -C config rm x.lock' \
         'git --work-tree=.claude checkout -- settings.json' 'git --work-tree config checkout -- x.lock' \
         'find -name settings.json -delete' 'find -type f -delete' 'find -delete' \
         'git checkout HEAD -- :/' 'git restore --source=HEAD~1 :/' "git restore -s HEAD~1 -- ':(top)'" 'git checkout -- :/.gitignore' \
         "git checkout HEAD -- ':!README'" "git checkout HEAD -- ':^README'" "git restore -s HEAD~1 -- ':(exclude)README'"; do
  B "$c"; expect_decision ask "git -C, pathspec magic or a folderless find over the tree: $c"
done
B 'git -C ../.claude checkout -- settings.json' default "$HR/sub"; expect_decision ask "git -C from a subfolder, normalized against the cwd → ask"
HOOKS_CASE_FOLD=1 B 'git -C .claude checkout -- settings.json'; expect_decision ask "where case folds (words lowercased): git -C .claude → ask"
HOOKS_CASE_FOLD=1 B 'git -c core.x=y status'; expect_decision none "where case folds: git -c key=value is not a folder"
for c in 'find -name x' 'git -C src log' 'git -C build checkout -- out.txt' 'git checkout -- :/src/a.ts'; do
  B "$c"; expect_decision none "not the protected tree, or not a write: $c"
done
mkdir -p "$T_TMP/home2/.claude" "$T_TMP/outside"
T_STDIN="$(t_tool_json Edit file_path "$T_TMP/home2/.claude/settings.json" default "$T_TMP/outside")"
run env HOME="$T_TMP/home2" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"
expect_decision ask "the shell left the governed repository: ~/.claude/settings.json is still asked about (CLAUDE_PROJECT_DIR)"

# --- the onboarding's own later steps are never asked about (first install: nothing may delay its merge) ---------------
for c in 'git add -A && git commit -m "onboarding: step 8, hooks"' 'bash /tmp/dl/tools/hm-lock.sh record --from /tmp/dl hooks' \
         'git push -u origin onboarding' 'gh pr create --fill' 'gh pr merge 12 --squash' \
         'bash .claude/skills/ship/bin/ship-sync.sh --contract=2'; do
  B "$c"; expect_decision none "onboarding step, not asked: $c"
done
E "$HR/getting-started-progress.md";       expect_decision none "the ledger write is not asked about"
E "$HR/.claude/humanmaxxing.lock";         expect_decision none "the install record write is not asked about"
E "$HR/CLAUDE.md";                         expect_decision none "the CLAUDE.md edit is not asked about (unless listed)"

# --- other tools (added to the matcher by the user) -----------------------------------------------------------------
t_hook protected-file-guard "$(t_tool_json mcp__fs__write_file path "$HR/.gitignore")"; expect_decision ask "another tool naming a protected file → ask"
t_hook protected-file-guard "$(t_tool_json mcp__fs__write_file path "$HR/README")";     expect_decision none "another tool naming nothing protected → allowed"

# --- repositories: config is read where the call lands -------------------------------------------------------------
cd "$T_TMP" || exit 2
mkdir -p plain && (cd plain && git init -q -b main . && echo x > .gitignore)
E "$T_TMP/plain/.gitignore";              expect_decision none "a repository with no hooks.env is not governed → allowed"
t_hook_fixture second
printf 'other.txt\n' > .claude/protected-files.txt
SECOND="$HR"
t_hook_fixture "sp ace"
printf 'other.txt\n' > .claude/protected-files.txt
SPACED="$HR"
t_hook_fixture guard2
E "$SECOND/other.txt";                    expect_decision ask  "a file in a second repository is judged by that repository's list"
E "$SECOND/.gitignore";                   expect_decision none "…and not by the session repository's list"
B "echo x > $SECOND/other.txt";           expect_decision ask  "a Bash write into the second repository by absolute path → ask"
B "echo x > \"$SPACED/other.txt\"";       expect_decision ask  "a double-quoted path with a space into a second repository → ask"
B "echo x > '$SPACED/other.txt'";         expect_decision ask  "a single-quoted path with a space into a second repository → ask"
B "rm -rf '$SPACED/.claude'";             expect_decision ask  "a quoted spaced path to a second repository's .claude folder → ask"
touch "$SECOND/other.txt"
B "echo '$T_TMP/sec*/other.txt' > notes.txt"; expect_decision none "a glob in the command is not expanded by the guard (it would match the second repository's listed file)"

# --- a real linked worktree whose main checkout is not governed yet (the install runs in a worktree, then merges) -----
MAIN="$T_TMP/wt-main"; mkdir -p "$MAIN" && cd "$MAIN" || exit 2
git init -q -b main . && echo x > README && echo x > .gitignore && git add -A && git -c user.name=t -c user.email=t@t commit -qm init || exit 2
git worktree add -q "$T_TMP/wt-feat" -b feat || exit 2
MAIN="$(pwd -P)"
t_hook_install "$T_TMP/wt-feat"
E "$MAIN/.claude/settings.local.json";    expect_decision ask  "the main checkout's settings.local.json, from a governed worktree → ask"
expect_out 'settings file' "the answer says it is a settings file"
t_hook protected-file-guard "$(t_tool_json Write file_path "$MAIN/.claude/settings.local.json")"; expect_decision ask "Write of it → ask"
E "$MAIN/.claude/settings.local.json" bypassPermissions; expect_decision deny "…and deny in bypassPermissions"
E "$MAIN/.claude/settings.json";          expect_decision ask  "the main checkout's settings.json → ask"
B "echo {} > $MAIN/.claude/settings.local.json"; expect_decision ask "the same file from the shell → ask"
E "$MAIN/.gitignore";                     expect_decision none "an ordinary file in the ungoverned main checkout keeps its answer, even one the worktree's list names"
E "$HR/.gitignore";                       expect_decision ask  "the worktree's own listed file → ask"
E "$HR/sub/.claude/settings.json";        expect_decision ask  "a subfolder's .claude/settings.json → ask"
HOOKS_CASE_FOLD=1 E "$MAIN/.Claude/Settings.local.json"; expect_decision ask "a case-varied settings path where case folds → ask"
HOOKS_CASE_FOLD=0 E "$MAIN/.Claude/Settings.local.json"; expect_decision none "…and not where it does not (a different file there)"
mkdir -p "$T_TMP/home"
HOME="$T_TMP/home" E "$T_TMP/home/.claude/settings.json"; expect_decision ask "the user's ~/.claude/settings.json → ask"
E "$MAIN/.claude/settings.json" default "$T_TMP/plain"; expect_decision none "a session in an ungoverned repository is not asked about any settings file"
# Claude Code on Windows sends Windows paths (C:\…\file, and a C:\… cwd): they name the same files.
case "${OSTYPE:-}" in
  msys*|cygwin*)
    WHR="$(cygpath -w "$HR")"
    E "$WHR\\.gitignore" default "$WHR";           expect_decision ask  "a Windows path (C:\\…) to a listed file → ask"
    E "$WHR\\.github\\workflows\\ci.yml" default "$WHR"; expect_decision ask "a Windows path through a * glob → ask"
    E "$WHR\\src\\app.ts" default "$WHR";          expect_decision none "a Windows path to an unlisted file → allowed"
    E ".gitignore" default "$WHR";                 expect_decision ask  "a relative path against a Windows cwd → ask" ;;
  *) t_skip "Windows paths from Claude Code (C:\\…): only Git for Windows' bash has cygpath to map them" ;;
esac

# --- configuration errors: never a silent allow --------------------------------------------------------------------
t_hook_fixture cfg-missing
rm .claude/protected-files.txt
E "$HR/src/app.ts";                       expect_decision ask  "missing list → ask, whatever the file"
expect_out 'missing or unreadable' "the answer names the missing list"
E "$HR/src/app.ts" bypassPermissions;     expect_decision deny "missing list in bypassPermissions → deny"
t_hook_fixture cfg-malformed
echo 'not a key value line' >> .claude/hooks/hooks.env
E "$HR/src/app.ts";                       expect_decision ask  "malformed hooks.env → ask"
expect_out 'malformed' "the answer says hooks.env is malformed"
t_hook_fixture cfg-badglob
printf './x\n' >> .claude/protected-files.txt
E "$HR/src/app.ts";                       expect_decision ask  "a glob spelling the guard cannot honour → ask"
t_hook_fixture cfg-class
printf 'config/[ab].lock\n' >> .claude/protected-files.txt
E "$HR/config/a.lock";                    expect_decision ask  "a [ab] class in a glob is a configuration error → ask"
expect_out 'config/\[ab\]\.lock' "the answer names the glob"
# CRLF line ends (Git for Windows checks text out that way by default): hooks.env and the list read as with LF, and the
# PROTECTED_FILES_FILE path, read without a CR, opens.
t_hook_fixture cfg-crlf
t_crlf "$T_ROOT/hooks/hooks.env.example" .claude/hooks/hooks.env
cp .claude/protected-files.txt "$T_TMP/list.lf"; t_crlf "$T_TMP/list.lf" .claude/protected-files.txt
E "$HR/src/app.ts";                       expect_decision none "a CRLF copy of hooks.env.example and a CRLF list: an unlisted file is allowed"
E "$HR/.gitignore";                       expect_decision ask  "…a listed file is asked about"
expect_out 'protected-files\.txt' "…naming the list it matched in"
E "$HR/.github/workflows/ci.yml";         expect_decision ask  "…and a glob line of the CRLF list matches"
E "$HR/config/x.lock";                    expect_decision ask  "…and so does a wildcard line"
printf 'PROTECTED_FILES_FILE=.claude/protected-files.txt\rx\n' > .claude/hooks/hooks.env
E "$HR/src/app.ts";                       expect_decision ask  "a CR inside a hooks.env line (not its end) → ask"
expect_out 'malformed' "the answer says hooks.env is malformed"
t_kv_crlf_agree "$T_ROOT/hooks/hook-lib.sh" hk_kv_get "$T_ROOT/hooks/hooks.env.example" \
  "a CRLF copy of hooks.env.example reads every key as the LF original does, with no CR in any value"
t_hook_fixture cfg-comment
printf 'PROTECTED_FILES_FILE=.claude/protected-files.txt # the list\n' > .claude/hooks/hooks.env
E "$HR/src/app.ts";                       expect_decision ask  "a trailing # comment on a value → ask"
expect_out 'configuration is broken' "the answer says the configuration is broken"
T_HOOK_LIST='' t_hook_fixture cfg-empty
: > .claude/protected-files.txt
E "$HR/.gitignore";                       expect_decision none "empty list → nothing but the built-ins is protected"
E "$HR/.claude/hooks/hooks.env";          expect_decision ask  "empty list still protects the hooks folder"

# --- the settings files are always protected (user decision), listed or not ------------------------------------------
T_HOOK_LIST='.gitignore' t_hook_fixture settings-builtin
E "$HR/.claude/settings.json";            expect_decision ask  "settings.json is always protected, even when the list does not name it"
E "$HR/.claude/settings.local.json";      expect_decision ask  "settings.local.json is always protected, even when the list does not name it"
expect_out 'always protected' "the answer says it is a built-in"
B "jq '.disableAllHooks = true' .claude/settings.json > t && mv t .claude/settings.json"; expect_decision ask "switching the hooks off from the shell → ask"
B 'jq .hooks .claude/settings.local.json'; expect_decision none "reading the settings files is not asked about"
E "$HR/.claude/settings.json" bypassPermissions; expect_decision deny "settings.json in bypassPermissions → deny"
B 'bash /tmp/dl/hooks/bin/hooks-install.sh plan --hooks protected-file-guard --settings .claude/settings.json'; expect_decision none "the installer's plan naming settings.json is a read"
B 'bash /tmp/dl/hooks/bin/hooks-install.sh plan --hooks protected-file-guard --settings .claude/settings.json > .claude/settings.json'; expect_decision ask "…but not with a redirect"
B 'bash /tmp/dl/hooks/bin/hooks-install.sh apply --hooks protected-file-guard --settings .claude/settings.json --approved 1-2'; expect_decision ask "the installer's apply asks, once"

# --- globs: regex metacharacters, spaces, quotes and backslashes in listed names -------------------------------------
T_HOOK_LIST='a+b.txt
file(1).txt
my notes.txt
we"ird.txt
back\slash.txt' t_hook_fixture globs
E "$HR/a+b.txt";                          expect_decision ask  "a + in a glob is literal"
E "$HR/aab.txt";                          expect_decision none "…not a regex repeat"
E "$HR/file(1).txt";                      expect_decision ask  "parentheses in a glob are literal"
E "$HR/file1.txt";                        expect_decision none "…not a regex group"
E "$HR/my notes.txt";                     expect_decision ask  "a listed name with a space (Edit)"
B "echo x > 'my notes.txt'";              expect_decision ask  "a listed name with a space, quoted (Bash)"
B 'echo x > my\ notes.txt';               expect_decision ask  "a listed name with a space, backslash-escaped (Bash)"
B 'echo x > notes.txt';                   expect_decision none "…and a name that only shares its tail is not"
E "$HR/we\"ird.txt";                      expect_decision ask  "a listed name holding a double quote: the answer is valid JSON"
if t_can_name 'b\s'; then E "$HR/back\\slash.txt"; expect_decision ask  "a listed name holding a backslash: the answer is valid JSON"
else t_skip "a listed name holding a backslash: on Windows a backslash is a path separator, never part of a name"; fi
T_HOOK_LIST='v?.md' t_hook_fixture qmark
E "$HR/v1.md";                            expect_decision ask  "? matches one character"
E "$HR/v12.md";                           expect_decision none "…and only one"
# The case probe looks at the repository's own hooks.env, not the root folder's spelling.
t_hook_fixture case-probe
ln -s hooks.env .claude/hooks/HOOKS.ENV 2>/dev/null
HOOKS_CASE_FOLD='' E "$HR/.GitIgnore";  expect_decision ask  "where the repository's own hooks.env answers to its upper-case name, case is folded"

# --- input -----------------------------------------------------------------------------------------------------------
t_hook_fixture input
t_hook protected-file-guard 'this is not json';  expect_rc 2 "unreadable input → exit 2 (blocks the call)"
t_hook protected-file-guard '';                  expect_rc 2 "empty input → exit 2"
t_hook protected-file-guard '{"tool_name":"Read","tool_input":{}}'; expect_decision none "a tool input with nothing to judge → allowed"

# --- parsers: python3 only, then none ---------------------------------------------------------------------------------
NOJQ="$(t_path_without jq)"
if PATH="$NOJQ" python3 -I -c 'import json' >/dev/null 2>&1; then   # a python3 that runs (not Windows' Store alias)
  T_STDIN="$(t_tool_json Edit file_path "$HR/.gitignore")"; run env PATH="$NOJQ" bash "$HD/protected-file-guard.sh"; expect_decision ask "python3 only: listed file → ask"
  T_STDIN="$(t_tool_json Edit file_path "$HR/src/a.ts")"; run env PATH="$NOJQ" bash "$HD/protected-file-guard.sh"; expect_decision none "python3 only: unlisted file → allowed"
  T_STDIN="$(t_tool_json Bash command 'cat .gitignore')"; run env PATH="$NOJQ" bash "$HD/protected-file-guard.sh"; expect_decision none "python3 only: read → allowed"
  T_STDIN="$(t_tool_json Edit file_path "$HR/.gitignore" bypassPermissions)"; run env PATH="$NOJQ" bash "$HD/protected-file-guard.sh"; expect_decision deny "python3 only: bypass → deny"
else
  echo "  SKIP  python3 is not installed here: the python3-only path is not exercised"
fi
NONE="$(t_path_without jq python3)"
T_STDIN="$(t_tool_json Edit file_path "$HR/.gitignore")"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"; expect_decision ask "no parser: a call naming a protected file → ask"
expect_out 'install jq or python3' "no parser: the answer says how to get a precise answer"
T_STDIN="$(t_tool_json Edit file_path "$HR/src/a.ts")"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"; expect_decision ask "no parser: every file-tool call is asked about (a symlink cannot be followed without one)"
mkdir -p "$HR/state"; ln -s state "$HR/link"
T_STDIN="$(t_tool_json Edit file_path "$HR/link/State.txt")"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"; expect_decision ask "no parser: a path through a symlink → ask"
T_STDIN="$(t_tool_json Bash command 'npm test')"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"; expect_decision none "no parser: a command naming nothing protected → allowed"
t_hook_fixture cfg-noparser
echo 'not a key value line' >> .claude/hooks/hooks.env
T_STDIN="$(t_tool_json Bash command 'echo x > .gitignore')"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"; expect_decision ask "no parser and a broken configuration → ask"
refute_out 'unbound variable' "…with no shell error on the way"
t_hook_fixture input2
T_STDIN="$(t_tool_json Edit file_path "$HR/.gitignore" bypassPermissions)"; run env PATH="$NONE" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"; expect_decision deny "no parser: bypass mode is still read → deny"
# A python3 that is on PATH but does not run (Windows' Microsoft Store alias: "Python was not found", exit 49) is no
# parser, never "the input is not JSON" (exit 2 would block every tool call).
mkdir -p "$T_TMP/stubpy" && printf '#!/bin/sh\necho "Python was not found" >&2\nexit 49\n' > "$T_TMP/stubpy/python3" && chmod +x "$T_TMP/stubpy/python3"
T_STDIN="$(t_tool_json Edit file_path "$HR/src/a.ts")"; run env PATH="$T_TMP/stubpy:$NONE" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"
expect_decision ask "a python3 that does not run: the no-parser answer (ask), not exit 2"
T_STDIN="$(t_tool_json Bash command 'npm test')"; run env PATH="$T_TMP/stubpy:$NONE" CLAUDE_PROJECT_DIR="$HR" bash "$HD/protected-file-guard.sh"
expect_decision none "a python3 that does not run: a command naming nothing protected → allowed"
if command -v jq >/dev/null 2>&1; then
  # With jq for the input, python3 is only the path resolver: one that does not run, or that answers in Windows form
  # (a native python under Git for Windows: C:\…), is not used, and the resolver walks the path itself.
  mkdir -p "$T_TMP/winpy" && printf '#!/bin/sh\nprintf %%s "C:\\\\Users\\\\x"\n' > "$T_TMP/winpy/python3" && chmod +x "$T_TMP/winpy/python3"
  # (Where ln -s cannot link, the listed file itself: a C:\… answer taken as the path would still miss it.)
  if t_can_symlink; then ln -s .gitignore "$HR/alias4"; A4="$HR/alias4"; else A4="$HR/.gitignore"; fi
  for py in stubpy winpy; do
    T_STDIN="$(t_tool_json Edit file_path "$A4")"; run env PATH="$T_TMP/$py:$PATH" bash "$HD/protected-file-guard.sh"
    expect_decision ask "python3 as $py: a listed file (through a symlink where one can be made) is still resolved → ask"
    T_STDIN="$(t_tool_json Edit file_path "$HR/src/a.ts")"; run env PATH="$T_TMP/$py:$PATH" bash "$HD/protected-file-guard.sh"
    expect_decision none "python3 as $py: an unlisted file → allowed"
  done
fi

# --- the resolver without python3 walks symlinks itself ----------------------------------------------------------------
if t_can_symlink; then
  ln -s .gitignore "$HR/alias2"; ln -s alias2 "$HR/alias3"
  T_STDIN="$(t_tool_json Edit file_path "$HR/alias3")"; run env PATH="$(t_path_without python3)" bash "$HD/protected-file-guard.sh"; expect_decision ask "no python3: a chain of symlinks is walked → ask"
else t_skip "a chain of symlinks: ln -s copies instead of linking here (Windows without developer mode)"; fi
T_STDIN="$(t_tool_json Edit file_path "$HR/missing/../.gitignore")"; run env PATH="$(t_path_without python3)" bash "$HD/protected-file-guard.sh"; expect_decision ask "no python3: a .. in a missing tail is folded → ask"
# --- the settings fragment's guard handler, with the guard script missing ------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  t_hook_fixture handler
  H="$(jq -r '."protected-file-guard".handler.command' "$T_ROOT/hooks/settings.fragment.json")"
  T_STDIN="$(t_tool_json Edit file_path "$HR/src/a.ts")"; run env CLAUDE_PROJECT_DIR="$HR" bash -c "$H"; expect_decision none "handler: the guard script present → its own answer (none for an unlisted file)"
  rm "$HD/protected-file-guard.sh"
  run env CLAUDE_PROJECT_DIR="$HR" bash -c "$H"; expect_decision ask "handler: guard script missing while configured → every call is asked about"
  T_STDIN="$(t_tool_json Edit file_path "$HR/src/a.ts" bypassPermissions)"; run env CLAUDE_PROJECT_DIR="$HR" bash -c "$H"; expect_decision deny "handler: …and denied in bypassPermissions"
  rm -rf "$HR/.claude"
  T_STDIN="$(t_tool_json Edit file_path "$HR/src/a.ts")"; run env CLAUDE_PROJECT_DIR="$HR" bash -c "$H"; expect_rc 0 "handler: not installed here → the call goes ahead"
  refute_out 'permissionDecision' "…with no decision"
else
  echo "  SKIP settings-fragment handler cases (no jq)"
fi
t_done
