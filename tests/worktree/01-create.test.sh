#!/usr/bin/env bash
# worktree-create (plain flow): layout, branch and upstream state, base update, config validation, copy and post-create
# steps, refusals, read failures, locking, and the stale-registration and interrupted-create cases. Every assertion
# reads the result back from git or the filesystem as well as from the exit code and the last line.
. "$(dirname "$0")/../lib.sh"
R='WORKTREE-RESULT worktree-create'
create() { run bash "$B/worktree-create.sh" "$@"; }
head_of() { git -C "$1" rev-parse HEAD; }
cfg_of() { git config --get "$1" 2>/dev/null; }

# --- plain clone: layout, upstream, tip ----------------------------------------------------------------------------
t_wt_fixture p1
create feat/x
expect 0 "$R PASS created path=[^ ]*/feat-x branch=feat/x base=main attached=0" "plain create reports path, branch, base"
check "the folder is a sibling of the primary checkout" test -e "$FIX/feat-x/.git"
check "branch feat/x maps to folder feat-x, with no feat/ directory" test ! -d "$FIX/feat"
check "git lists the physical sibling path" t_wt_has_path "$FIXP/feat-x"
check "git lists the branch" t_wt_listed feat/x
check "HEAD of the new worktree is the remote base tip" test "$(head_of "$FIX/feat-x")" = "$(t_wt_tip main)"
check "a new branch has no upstream remote (--no-track)" test -z "$(cfg_of branch.feat/x.remote)"
check "a new branch has no upstream merge ref" test -z "$(cfg_of branch.feat/x.merge)"
check "a new worktree starts clean" test -z "$(git -C "$FIX/feat-x" status --porcelain)"
check "the primary stays on main" test "$(git rev-parse --abbrev-ref HEAD)" = main
check "the primary stays clean" test -z "$(git status --porcelain)"
check "the fetch refspec is still the one standard value" test "$(git config --get-all remote.origin.fetch)" = '+refs/heads/*:refs/remotes/origin/*'
check "nothing was pushed by a plain create" test -z "$(git ls-remote origin refs/heads/feat/x)"

# --- the base moved on the remote: the new branch starts at the new tip, the local base follows ------------------------
t_wt_remote_commit main f1.txt v1
newtip="$(t_wt_tip main)"
create y
expect 0 "$R PASS created path=[^ ]*/y branch=y base=main attached=0" "create after the remote base moved"
check "the new worktree starts at the fetched remote tip" test "$(head_of "$FIX/y")" = "$newtip"
check "the local base was fast-forwarded in the primary" test "$(git rev-parse main)" = "$newtip"
check "the primary working tree has the new file" test -f f1.txt

# --- local base update: skipped when dirty, untouched when diverged, skipped by --no-base-update --------------------
t_wt_remote_commit main f2.txt v2
tip2="$(t_wt_tip main)"; old="$(git rev-parse main)"
echo scratch >> README
create dirty-base
expect 0 "$R PASS created" "a dirty base worktree does not fail the create"
check "the local base was not moved while it had tracked changes" test "$(git rev-parse main)" = "$old"
check "the uncommitted change is still there" grep -q scratch README
check "the new branch still starts at the remote tip" test "$(head_of "$FIX/dirty-base")" = "$tip2"
git checkout -q README
create after-clean
expect 0 "$R PASS created" "create once the base worktree is clean again"
check "the base moves forward once clean" test "$(git rev-parse main)" = "$tip2"

echo local > local.txt; git add local.txt; git commit -qm "local only"
localtip="$(git rev-parse main)"
t_wt_remote_commit main f3.txt v3
create diverged
expect 0 "$R PASS created" "a diverged local base does not fail the create"
check "a diverged local base is never rewritten" test "$(git rev-parse main)" = "$localtip"
check "the new branch is off the remote base, not the local one" test "$(head_of "$FIX/diverged")" = "$(t_wt_tip main)"
git reset -q --hard origin/main 2>/dev/null; git fetch -q origin; git reset -q --hard origin/main

t_wt_remote_commit main f4.txt v4
old="$(git rev-parse main)"
create --no-base-update nobu
expect 0 "$R PASS created" "--no-base-update is accepted"
check "--no-base-update leaves the local base alone" test "$(git rev-parse main)" = "$old"

# --- base not checked out anywhere: moved when it fast-forwards, untouched when diverged -----------------------------
t_wt_fixture p-nb
git checkout -q -b elsewhere
t_wt_remote_commit main g1.txt g1
create nb1
expect 0 "$R PASS created" "base not checked out: create"
check "a base that is not checked out is fast-forwarded by fetch" test "$(git rev-parse main)" = "$(t_wt_tip main)"
check "the primary stays on its own branch" test "$(git rev-parse --abbrev-ref HEAD)" = elsewhere
git worktree add -q --no-track -b scratch-d "$FIX/scratch-d" main
echo x > "$FIX/scratch-d/x.txt"; git -C "$FIX/scratch-d" add x.txt; git -C "$FIX/scratch-d" commit -qm x
git branch -f main scratch-d
div="$(git rev-parse main)"
git worktree remove --force "$FIX/scratch-d"
t_wt_remote_commit main g2.txt g2
create nb2
expect 0 "$R PASS created" "base not checked out and diverged: create"
check "a diverged base that is not checked out stays untouched" test "$(git rev-parse main)" = "$div"
check "the new branch is off the remote base" test "$(head_of "$FIX/nb2")" = "$(t_wt_tip main)"

# --- attach an existing remote branch; suffix collision ----------------------------------------------------------------
t_wt_fixture p-attach
t_wt_remote_commit feat/z z.txt z
create feat/z
expect 0 "$R PASS created path=[^ ]*/feat-z branch=feat/z base=main attached=1" "an existing remote branch is attached"
check "the attached branch tracks its own remote branch (remote)" test "$(cfg_of branch.feat/z.remote)" = origin
check "the attached branch tracks its own remote branch (merge)" test "$(cfg_of branch.feat/z.merge)" = refs/heads/feat/z
check "HEAD is the remote branch tip, not the base tip" test "$(head_of "$FIX/feat-z")" = "$(t_wt_tip feat/z)"
check "the attached checkout has the branch's file" test -f "$FIX/feat-z/z.txt"

t_wt_fixture p-coll
t_wt_remote_commit feat/x x.txt x
create x
expect 0 "$R PASS created path=[^ ]*/x branch=x base=main attached=0" "remote has feat/x, creating x makes a NEW branch"
check "x starts at the base tip" test "$(head_of "$FIX/x")" = "$(t_wt_tip main)"
check "x has no upstream" test -z "$(cfg_of branch.x.remote)"
check "x did not pick up the suffix match's file" test ! -e "$FIX/x/x.txt"
check "the remote still has no branch x" test -z "$(git ls-remote origin refs/heads/x)"

# --- refusals that leave nothing behind ---------------------------------------------------------------------------------
t_wt_fixture p-ref
mkdir "$FIX/pe"
create pe
expect 1 "$R FAIL path-exists" "an existing folder is never attached to"
check "the leftover empty folder is untouched" test -d "$FIX/pe"
check "the leftover folder is still empty" test -z "$(ls -A "$FIX/pe")"
check "no branch pe was created" test -z "$(git for-each-ref refs/heads/pe)"
rmdir "$FIX/pe"
create pe
expect 0 "$R PASS created" "the same create succeeds once the leftover folder is gone (no stale lock)"
git worktree remove --force "$FIX/pe" >/dev/null 2>&1; git branch -D pe >/dev/null 2>&1

git branch be
create be
expect 1 "$R FAIL branch-exists" "a local branch that is not on the remote is refused"
check "no folder was made for it" test ! -e "$FIX/be"
t_wt_remote_commit rb r.txt r
git fetch -q origin
git worktree add -q -B rb "$FIX/elsewhere-rb" origin/rb
create rb
expect 1 "$R FAIL branch-exists" "a branch checked out in another worktree is refused"
check "no second checkout of rb exists" test ! -e "$FIX/rb"
check "only the explicit extra worktree exists" test "$(t_wt_count)" = 2

# --- config validation -----------------------------------------------------------------------------------------------
t_wt_fixture p-cfg
create --config "$FIX/nope.env" c1
expect 2 "$R FAIL (usage|config-[a-z-]+)" "a missing config file is exit 2"
printf 'BASE_BRANCH=\n' > "$FIX/empty.env"
create --config "$FIX/empty.env" c2
expect 2 "$R FAIL (usage|config-[a-z-]+)" "an empty BASE_BRANCH is exit 2"
printf 'COPY_FILES=\n' > "$FIX/nobase.env"
create --config "$FIX/nobase.env" c3
expect 2 "$R FAIL (usage|config-[a-z-]+)" "an absent BASE_BRANCH is exit 2"
t_wt_cfg cap-word.env BRANCH_MAX_LEN=abc
create --config "$CFG" c4
expect 2 "$R FAIL (usage|config-[a-z-]+)" "a non-numeric BRANCH_MAX_LEN is exit 2"
t_wt_cfg cap-low.env BRANCH_MAX_LEN=5
create --config "$CFG" c5
expect 2 "$R FAIL (usage|config-[a-z-]+)" "BRANCH_MAX_LEN below 20 is exit 2"
t_wt_cfg cap-high.env BRANCH_MAX_LEN=500
create --config "$CFG" c6
expect 2 "$R FAIL (usage|config-[a-z-]+)" "BRANCH_MAX_LEN above 200 is exit 2"
t_wt_cfg mode.env POST_CREATE_MODE=sometimes
create --config "$CFG" c7
expect 2 "$R FAIL (usage|config-[a-z-]+)" "an unknown POST_CREATE_MODE is exit 2"
t_wt_cfg push.env PUSH_ON_ISSUE=maybe
create --config "$CFG" c8
expect 2 "$R FAIL (usage|config-[a-z-]+)" "a PUSH_ON_ISSUE that is not 0 or 1 is exit 2"
t_wt_pristine "no config failure created anything"

# hostile arguments: nothing created, exit 2
create ""
expect 2 "$R FAIL usage" "an empty argument is a usage error"
create --force-me
expect 2 "$R FAIL usage" "a flag-looking branch is an unknown option"
create -x
expect 2 "$R FAIL usage" "a branch starting with a dash is refused"
create "has space"
expect 2 "$R FAIL usage" "a branch name with a space is refused"
create a..b
expect 2 "$R FAIL usage" "a branch name with .. is refused"
create
expect 2 "$R FAIL usage" "no argument at all is a usage error"
create --bogus x
expect 2 "$R FAIL usage" "an unknown option is exit 2, never ignored"
create 0
expect 2 "$R FAIL usage" "issue number 0 is refused"
create 007
expect 2 "$R FAIL usage" "an issue number with leading zeros is refused"
create 7 7
expect 2 "$R FAIL usage" "a duplicated issue number is refused"
t_wt_pristine "no hostile argument created anything"
create 7,,8
expect 2 "$R FAIL usage" "an empty element in a comma list is refused"

# a config value that looks like command substitution is data, never evaluated
t_wt_cfg hostile.env 'COPY_FILES=$(touch '"$FIX"'/pwned1)' 'START_MODELS=$(touch '"$FIX"'/pwned2)' 'WORKTREE_PARENT_DIR=$(touch '"$FIX"'/pwned3)'
create --config "$CFG" hostile-cfg
check "no config value was executed (1)" test ! -e "$FIX/pwned1"
check "no config value was executed (2)" test ! -e "$FIX/pwned2"
check "no config value was executed (3)" test ! -e "$FIX/pwned3"

# --- COPY_FILES ----------------------------------------------------------------------------------------------------------
t_wt_fixture p-copy
mkdir -p sub; echo secret > .env.local; echo cfg > sub/dir.cfg; echo a > "sp ace.txt"
printf '.env.local\nsub/dir.cfg\nsp ace.txt\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
t_wt_cfg copy.env 'COPY_FILES=.env.local sub/dir.cfg missing.txt'
create --config "$CFG" copy1
expect 0 "$R PASS created" "COPY_FILES with a missing source still creates"
check "an ignored file was copied" test "$(cat "$FIX/copy1/.env.local")" = secret
check "a nested file was copied with its directory" test "$(cat "$FIX/copy1/sub/dir.cfg")" = cfg
expect_out 'missing\.txt' "a missing source is named in a printed warning"
check "copied ignored files keep the worktree clean" test -z "$(git -C "$FIX/copy1" status --porcelain)"
echo changed >> README
t_wt_cfg copy2.env COPY_FILES=README
create --config "$CFG" copy2
expect 0 "$R PASS created" "copying a tracked file"
check "an existing file is never overwritten" test "$(cat "$FIX/copy2/README")" = base
git checkout -q README
t_wt_cfg copy3.env 'COPY_FILES=/etc/hostname'
create --config "$CFG" copy3
expect 2 "$R FAIL (usage|config-[a-z-]+)" "an absolute COPY_FILES path is exit 2"
check "and creates nothing" test ! -e "$FIX/copy3"
t_wt_cfg copy4.env 'COPY_FILES=../outside'
create --config "$CFG" copy4
expect 2 "$R FAIL (usage|config-[a-z-]+)" "a COPY_FILES path with .. is exit 2"
check "and creates nothing (..)" test ! -e "$FIX/copy4"
t_wt_cfg copy5.env 'COPY_FILES=sub/../../x'
create --config "$CFG" copy5
expect 2 "$R FAIL (usage|config-[a-z-]+)" "a .. in the middle of a COPY_FILES path is exit 2"
if ! t_can_unreadable; then t_skip "a source that cannot be read: chmod cannot take read access away here (root, or Windows)"
else
  echo nope > unreadable.txt; chmod 000 unreadable.txt
  printf 'unreadable.txt\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
  t_wt_cfg copy6.env COPY_FILES=unreadable.txt "POST_CREATE_CMD=echo ran > $FIX/ran6"
  create --config "$CFG" copy6
  expect 6 "$R FAIL copy-failed path=[^ ]+ branch=copy6" "a source that cannot be read is copy-failed"
  check "the worktree is left in place" test -e "$FIX/copy6/.git"
  check "later steps still ran after the failed copy" test -f "$FIX/ran6"
  chmod 644 unreadable.txt
fi

# --- POST_CREATE_CMD -------------------------------------------------------------------------------------------------------
t_wt_fixture p-post
t_wt_cfg pc-ok.env "POST_CREATE_CMD=echo \$PWD \$BRANCH \$WORKTREE_PATH >> $FIX/pc.rec"
create --config "$CFG" feat/pc
expect 0 "$R PASS created" "post-create in wait mode succeeds"
check "post-create ran in the new worktree, with BRANCH and WORKTREE_PATH exported" grep -Eq '/feat-pc feat/pc [^ ]*/feat-pc$' "$FIX/pc.rec"
t_wt_cfg pc-fail.env 'POST_CREATE_CMD=exit 3'
create --config "$CFG" pcf
expect 6 "$R FAIL post-create-failed path=[^ ]+ branch=pcf" "a failing wait-mode post-create is exit 6"
check "the worktree is left in place" test -e "$FIX/pcf/.git"
check "its branch exists" t_wt_listed pcf
# The command waits on a gate file the test opens only after create returns (no stopwatch: a loaded machine is slow
# but cannot finish a command that is still waiting). The gate gives up after 30 s, leaving <gate>.timeout and failing,
# so a create that waits fails (whether or not it writes a status file), never hangs.
printf 'i=0; while [ ! -e "$1" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done\n[ -e "$1" ] || { : > "$1.timeout"; echo gate-timeout; exit 1; }\necho bg-finished\n' > "$FIX/gate.sh"
t_wt_cfg pc-bg.env POST_CREATE_MODE=background "POST_CREATE_CMD=bash $FIX/gate.sh $FIX/pcbg.go"
create --config "$CFG" pcbg
expect 0 "$R PASS created" "background post-create: create passes"
check "and returns without waiting for it (the command is still held at its gate)" \
  test ! -e "$FIX/pcbg.go.timeout" -a -z "$(t_wt_gitfile "$FIX/pcbg" status)"
touch "$FIX/pcbg.go"
logf="$(t_wt_gitfile "$FIX/pcbg" log)"
check "a log file exists in the worktree's git dir" test -n "$logf"
check "the log path is printed" test -n "$logf" -a -n "$(printf '%s\n' "$OUT" | grep -F "$(basename "${logf:-none}")")"
check "the status file appears when the command ends" t_wt_wait_gitfile "$FIX/pcbg" status 80
statf="$(t_wt_gitfile "$FIX/pcbg" status)"
check "the exit status of the background command is 0" test "$(tr -d ' \n' < "${statf:-/dev/null}")" = 0
check "its output went to the log" grep -q bg-finished "${logf:-/dev/null}"
t_wt_cfg pc-bgf.env POST_CREATE_MODE=background 'POST_CREATE_CMD=exit 5'
create --config "$CFG" pcbgf
expect 0 "$R PASS created" "a failing background command does not fail the create"
check "its failure is in the status file" t_wt_wait_gitfile "$FIX/pcbgf" status 80
check "the status file holds the exit code 5" test "$(tr -d ' \n' < "$(t_wt_gitfile "$FIX/pcbgf" status)")" = 5

# --- an empty or skipped install never leaves anything waiting for a status file; --no-hook-setup ------------------------
t_wt_cfg pc-none.env POST_CREATE_MODE=background
create --config "$CFG" --background pcnone
expect 0 "$R PASS created .*setup=none" "no POST_CREATE_CMD: setup=none"
check "…and it says so, with no exit-status file promised" sh -c 'printf "%s\n" "$1" | grep -q "post-create: none configured (no exit-status file)" && ! printf "%s\n" "$1" | grep -q "exit status will be in"' _ "$OUT"
check "…and no status file is written" test -z "$(t_wt_gitfile "$FIX/pcnone" status)"
t_wt_cfg pc-skip.env "POST_CREATE_CMD=echo ran > $FIX/ran-skip"
create --config "$CFG" --background --no-install pcskip
expect 0 "$R PASS created .*setup=skipped" "--no-install: setup=skipped"
check "--no-install: the install did not run" test ! -e "$FIX/ran-skip"
check "--no-install: no exit-status file is promised" sh -c '! printf "%s\n" "$1" | grep -q "exit status will be in"' _ "$OUT"
# An install that switches on a hooks manager writes core.hooksPath into the shared config (husky's prepare does).
t_wt_cfg pc-hooks.env 'POST_CREATE_CMD=echo "husky=${HUSKY:-unset} lefthook=${LEFTHOOK:-unset}" > hk.rec; git config core.hooksPath .husky/_'
git config --unset-all core.hooksPath 2>/dev/null
create --config "$CFG" --no-hook-setup pchk1
expect 0 "$R PASS created .*setup=ok" "--no-hook-setup (wait mode): the install runs"
check "--no-hook-setup: the install ran with HUSKY=0 and LEFTHOOK=0" grep -qx 'husky=0 lefthook=0' "$FIX/pchk1/hk.rec"
check "--no-hook-setup: the hooks path the install set is undone in the shared config" test -z "$(git config --get core.hooksPath)"
check "--no-hook-setup: the change is reported" sh -c 'printf "%s\n" "$1" | grep -q "post-create changed core.hooksPath (to .\.husky/_.); put back as it was"' _ "$OUT"
git config core.hooksPath custom-hooks
create --config "$CFG" --background --no-hook-setup pchk2
check "--no-hook-setup (background): the status file appears" t_wt_wait_gitfile "$FIX/pchk2" status 80
check "--no-hook-setup (background): an existing hooks path is put back, not removed" test "$(git config --get core.hooksPath)" = custom-hooks
check "--no-hook-setup (background): the install's exit status is still 0" test "$(tr -d ' \n' < "$(t_wt_gitfile "$FIX/pchk2" status)")" = 0
t_wt_cfg pc-claim.env 'POST_CREATE_CMD=true' 'ISSUE_TITLE_CMD=' 'ISSUE_GUARD_CMD=' 'PUSH_ON_ISSUE=0' "ISSUE_CLAIM_CMD=echo husky=\${HUSKY:-unset} > $FIX/claim.rec"
create --config "$CFG" --no-hook-setup 77
check "--no-hook-setup: HUSKY reaches the install only, never the claim (or push) after it" grep -qx 'husky=unset' "$FIX/claim.rec"
t_wt_cfg pc-hooksfail.env 'POST_CREATE_CMD=git config core.hooksPath .husky/_; exit 5'
git config --unset-all core.hooksPath 2>/dev/null
create --config "$CFG" --no-hook-setup pchk4
expect 6 "$R FAIL post-create-failed path=[^ ]+ branch=pchk4" "--no-hook-setup: an install that fails is still exit 6"
check "--no-hook-setup: a failing install's hooks path is still undone" test -z "$(git config --get core.hooksPath)"
CFG="$FIX/pc-hooks.env"
git config --unset-all core.hooksPath
create --config "$CFG" pchk3
check "without --no-hook-setup the install's hooks path stays (the skill's normal behaviour)" test "$(git config --get core.hooksPath)" = .husky/_
check "without --no-hook-setup HUSKY is not set for the install" grep -qx 'husky=unset lefthook=unset' "$FIX/pchk3/hk.rec"
git config --unset-all core.hooksPath

# --- no remote -----------------------------------------------------------------------------------------------------------
t_wt_fixture p-lo
git remote remove origin
echo localwork > lw.txt; git add lw.txt; git commit -qm "local base work"
t_wt_cfg lo.env BASE_REMOTE=
create --config "$CFG" lo1
expect 0 "$R PASS created path=[^ ]*/lo1 branch=lo1 base=main attached=0" "no-remote mode creates"
check "the branch is off the LOCAL base" test "$(head_of "$FIX/lo1")" = "$(git rev-parse main)"
check "no upstream" test -z "$(cfg_of branch.lo1.remote)"
check "no remote was configured by the create" test -z "$(git remote)"
check "no remote-tracking refs appeared" test -z "$(git for-each-ref refs/remotes)"

mkdir "$FIX/empty-repo"; ( cd "$FIX/empty-repo" && git init -q -b main . )
t_wt_cfg nc.env BASE_REMOTE=
( cd "$FIX/empty-repo" && run bash "$PRIMARY/$B/worktree-create.sh" --config "$CFG" nc1; echo "$RC" > "$FIX/nc.rc"; printf '%s\n' "$LAST" > "$FIX/nc.last" )
RC="$(cat "$FIX/nc.rc")"; LAST="$(cat "$FIX/nc.last")"
expect 1 "$R FAIL no-commits" "a repository with no commits is refused"
check "and nothing was created next to it" test ! -e "$FIX/nc1"

# --- read failures: nothing created ----------------------------------------------------------------------------------------
t_wt_fixture p-rf
mv "$ORIGIN" "$FIX/origin.gone"
create rf1
expect 3 "$R FAIL (fetch-failed|ls-remote-failed)" "an unreachable remote is exit 3, never 'branch absent'"
t_wt_pristine "nothing created while the remote is unreachable"
mv "$FIX/origin.gone" "$ORIGIN"
create rf1
expect 0 "$R PASS created" "the same create succeeds with the remote reachable"
printf 'BASE_BRANCH=no-such-base\n' > "$FIX/nosuch.env"
create --config "$FIX/nosuch.env" rf2
expect 3 "$R FAIL fetch-failed" "a base branch the remote does not have is a failed fetch"
check "nothing was left for rf2" test ! -e "$FIX/rf2"
check "no branch rf2" test -z "$(git for-each-ref refs/heads/rf2)"

# --- bare layout -------------------------------------------------------------------------------------------------------------
t_wt_bare_fixture bare1
check "the bare fixture has no fetch refspec to begin with" test -z "$(git -C "$FIX/.bare" config --get-all remote.origin.fetch)"
create feat/b
expect 0 "$R PASS created path=[^ ]*/feat-b branch=feat/b base=main attached=0" "create from the bare layout"
check "the sibling is in the parent of the calling worktree" test -e "$FIX/feat-b/.git"
check "the fetch refspec was repaired to the one standard value" test "$(git -C "$FIX/.bare" config --get-all remote.origin.fetch)" = '+refs/heads/*:refs/remotes/origin/*'
check "HEAD is the remote base tip" test "$(head_of "$FIX/feat-b")" = "$(t_wt_tip main)"
check "no upstream on the new branch" test -z "$(cfg_of branch.feat/b.remote)"
create b2
expect 0 "$R PASS created" "a second create in the bare layout"
check "the refspec repair is idempotent (still exactly one value)" test "$(git -C "$FIX/.bare" config --get-all remote.origin.fetch | wc -l | tr -d ' ')" = 1
check "the base worktree stayed on main" test "$(git -C "$FIX/main" rev-parse --abbrev-ref HEAD)" = main

# --- where it is run from ---------------------------------------------------------------------------------------------------------
t_wt_fixture p-from
git worktree add -q --no-track -b other "$FIX/other-wt" origin/main
mkdir -p .claude/sub
( cd .claude/sub && run bash "$PRIMARY/$B/worktree-create.sh" from-sub; echo "$RC" > "$FIX/rc1"; printf '%s\n' "$LAST" > "$FIX/last1" )
RC="$(cat "$FIX/rc1")"; LAST="$(cat "$FIX/last1")"
expect 0 "$R PASS created path=[^ ]*/from-sub " "run from a subdirectory of the primary"
check "the sibling landed next to the primary, not inside the subdirectory" test -e "$FIX/from-sub/.git"
( cd "$FIX/other-wt" && run bash "$PRIMARY/$B/worktree-create.sh" from-sib; echo "$RC" > "$FIX/rc2"; printf '%s\n' "$LAST" > "$FIX/last2" )
RC="$(cat "$FIX/rc2")"; LAST="$(cat "$FIX/last2")"
expect 0 "$R PASS created path=[^ ]*/from-sib " "run from a sibling worktree"
check "the new sibling is a sibling of the caller's folder" test -e "$FIX/from-sib/.git"

# --- WORKTREE_PARENT_DIR, including a path with a space ----------------------------------------------------------------------------
t_wt_fixture p-par
mkdir "$FIX/sp ace"
t_wt_cfg par.env "WORKTREE_PARENT_DIR=$FIX/sp ace"
create --config "$CFG" inpar
expect 0 "$R PASS created" "WORKTREE_PARENT_DIR with a space"
check "the folder is under the configured parent" test -e "$FIX/sp ace/inpar/.git"
check "git lists that path" t_wt_has_path "$FIXP/sp ace/inpar"
check "nothing landed in the default parent" test ! -e "$FIX/inpar"

# --- locking --------------------------------------------------------------------------------------------------------------------------
t_wt_fixture p-lock
t_wt_hold_install
create warm
expect 0 "$R PASS created" "warm-up create (makes the worktrees dir exist)"
common="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
snap() { find "$common" -mindepth 1 -maxdepth 3 | sort; }
t_wt_hold_on
bash "$B/worktree-create.sh" lk1 > "$FIX/first.out" 2>&1 &
firstpid=$!
t_wt_wait_file "$FIX/hold.reached" 100
snap > "$FIX/during.lst"
create lk1
expect 1 "$R FAIL create-in-progress" "a second create of the same folder while one holds the lock"
t_wt_hold_off
wait "$firstpid"; firstrc=$?
check "the create that held the lock finished with 0" test "$firstrc" = 0
check "and its worktree exists exactly once" test "$(git worktree list --porcelain | grep -c 'branch refs/heads/lk1$')" = 1
snap > "$FIX/after.lst"
lockentry="$(comm -23 "$FIX/during.lst" "$FIX/after.lst" | grep -v '/worktrees/' | tail -1)"
check "a lock existed during the create and is gone after it (released on exit)" test -n "$lockentry"
rm -f "$FIX/hold" "$FIX/go"
case "$lockentry" in
  */lk1)
    stale="${lockentry%lk1}stale1"; fresh="${lockentry%lk1}fresh1"
    mkdir -p "$stale" && touch -t 200001010000 "$stale"
    create stale1
    expect 0 "$R PASS created" "a lock older than 10 minutes is taken over"
    check "and the taken-over lock is gone afterwards" test ! -e "$stale"
    check "no leftover entry from the takeover next to the lock" test "$(ls -A "$(dirname "$stale")" | wc -l | tr -d ' ')" = 0
    mkdir -p "$fresh"
    create fresh1
    expect 1 "$R FAIL create-in-progress" "a lock that is not stale is respected"
    check "and left in place" test -d "$fresh"
    check "no worktree was made under a live lock" test ! -e "$FIX/fresh1"
    ;;
  *) t_fail "the lock entry could not be identified as <dir>/<folder>" "found: ${lockentry:-nothing}" ;;
esac
rm -f "$common/hooks/post-checkout"

# two plain creates racing for one branch
t_wt_fixture p-race
for n in 1 2 3; do
  ( bash "$B/worktree-create.sh" "race$n" > "$FIX/ra$n" 2>&1; echo $? > "$FIX/ra$n.rc" ) &
  ( bash "$B/worktree-create.sh" "race$n" > "$FIX/rb$n" 2>&1; echo $? > "$FIX/rb$n.rc" ) &
  wait
  codes="$(sort "$FIX/ra$n.rc" "$FIX/rb$n.rc" | tr '\n' ' ')"
  check "race $n: one create wins (0), the other is refused (1)" test "$codes" = "0 1 "
  check "race $n: exactly one worktree for the branch" test "$(git worktree list --porcelain | grep -c "branch refs/heads/race$n\$")" = 1
  loser="$(cat "$FIX/ra$n" "$FIX/rb$n" | grep -c 'FAIL \(create-in-progress\|path-exists\|branch-exists\)')"
  check "race $n: the loser says why" test "$loser" = 1
done

# --- interrupted creates (test seam) and stale registrations -----------------------------------------------------------------
t_wt_fixture p-int
run env WORKTREE_TEST_STOP_AFTER=add bash "$B/worktree-create.sh" 33-stray
expect 0 "$R PASS created path=[^ ]*/33-stray " "WORKTREE_TEST_STOP_AFTER alone does nothing: a normal create"
check "the stray-variable create left no lock behind and a marker-free plain branch" t_wt_listed 33-stray
run env WORKTREE_TEST_MODE=1 WORKTREE_TEST_STOP_AFTER=add bash "$B/worktree-create.sh" 31-halfway
expect_rc 99 "stop after add (seam on): exit 99"
refute_out '^WORKTREE-RESULT' "stop after add: no result line"
check "stop after add: the worktree exists" test -e "$FIX/31-halfway/.git"
check "stop after add: no marker was written yet" test ! -e "$(t_wt_gitdir "$FIX/31-halfway")/worktree-issues"
run env WORKTREE_TEST_MODE=1 WORKTREE_TEST_STOP_AFTER=copy bash "$B/worktree-create.sh" 32-later
expect_rc 99 "stop after copy (seam on): exit 99"
refute_out '^WORKTREE-RESULT' "stop after copy: no result line"
check "stop after copy: the worktree exists" test -e "$FIX/32-later/.git"
check "stop after copy: the branch is registered" t_wt_listed 32-later
create 31-halfway
expect 1 "$R FAIL (path-exists|create-in-progress)" "creating over an interrupted create's folder is refused"
check "and the interrupted worktree is untouched" test -e "$FIX/31-halfway/.git"

t_wt_fixture p-stale
create gone1
expect 0 "$R PASS created" "stale registration: first create"
rm -rf "$FIX/gone1"
create gone1
expect 1 "$R FAIL branch-exists" "folder deleted by hand: the registration is pruned and the leftover local branch is reported"
check "git prune ran: no prunable entry is listed" test -z "$(git worktree list --porcelain | grep -i prunable)"
create gone-other
expect 0 "$R PASS created" "after the prune another create works"
t_wt_remote_commit gone2 g.txt g
create gone2
expect 0 "$R PASS created path=[^ ]*/gone2 .*attached=1" "attach a remote branch"
rm -rf "$FIX/gone2"
create gone2
expect 0 "$R PASS created path=[^ ]*/gone2 .*attached=1" "folder deleted by hand, remote branch exists: the stale registration is pruned and the create succeeds"
check "the new checkout is registered once" test "$(git worktree list --porcelain | grep -c 'branch refs/heads/gone2$')" = 1
check "and has the remote branch's file" test -f "$FIX/gone2/g.txt"

# --- stale-lock boundary and a CRLF configuration file --------------------------------------------------------------------
# (the lock directory is found the same way as above: a create holds it between the add and the marker)
t_wt_fixture p-lock2
t_wt_hold_install
create warm
t_wt_hold_on
bash "$B/worktree-create.sh" lkb > "$FIX/first.out" 2>&1 &
firstpid=$!
t_wt_wait_file "$FIX/hold.reached" 100
common="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
lockdir="$(find "$common" -mindepth 1 -maxdepth 3 -type d -name lkb | grep -v '/worktrees/' | tail -1)"
t_wt_hold_off
wait "$firstpid"
rm -f "$FIX/hold" "$FIX/go" "$common/hooks/post-checkout"
if [ -n "$lockdir" ]; then
  ldir="$(dirname "$lockdir")"
  # Portable ages: GNU `touch -d '5 minutes ago'` does not exist on BSD/macOS. A lock just made is young; a fixed
  # old timestamp (`touch -t`, POSIX) is stale.
  mkdir -p "$ldir/young"
  create young
  expect 1 "$R FAIL create-in-progress" "a fresh lock is not stale"
  check "and it is left in place" test -d "$ldir/young"
  check "and nothing was created for it" test ! -e "$FIX/young"
  mkdir -p "$ldir/old" && touch -t 200001010000 "$ldir/old"
  create old
  expect 0 "$R PASS created" "a lock far older than ten minutes is taken over"
  check "the old lock's worktree exists" test -e "$FIX/old/.git"
else
  t_fail "the lock directory could not be located" "found: nothing"
fi
# CRLF line ends (Git for Windows checks text out that way by default) are line ends: the path value is used as is.
t_wt_cfg crlf.env
printf 'BASE_BRANCH=main\r\nWORKTREE_PARENT_DIR=%s/crlf-parent\r\n' "$FIXP" > "$CFG"
mkdir -p "$FIX/crlf-parent"
create --config "$CFG" crlf-branch
expect 0 "$R PASS created path=$FIXP/crlf-parent/crlf-branch branch=crlf-branch base=main" "a configuration file with CRLF line endings reads as with LF"
check "…and the worktree is in the configured parent folder, not one whose name ends in a CR" test -e "$FIX/crlf-parent/crlf-branch/.git"
check "…and git lists that path" t_wt_has_path "$FIXP/crlf-parent/crlf-branch"
printf 'BASE_BRANCH=main\r\nPOST_CREATE_CMD=echo a\rb\r\n' > "$CFG"
create --config "$CFG" cr-inside-branch
expect 2 "$R FAIL config-malformed" "a CR inside a line (not its end) is still malformed"
t_kv_crlf_agree "$T_ROOT/skills/worktree/bin/worktree-lib.sh" wt_kv_get "$T_ROOT/skills/worktree/worktree.env.example" \
  "a CRLF copy of worktree.env.example reads every key as the LF original does, with no CR in any value"
printf 'BASE_BRANCH=main\nPOST_CREATE_CMD=   # nothing to install\n' > "$CFG"
create --config "$CFG" comment-branch
expect 2 "$R FAIL config-malformed" "a comment where a value should be is refused"
printf 'BASE_BRANCH=main\nPOST_CREATE_CMD=\t# a tab before the comment\n' > "$CFG"
create --config "$CFG" tab-comment-branch
expect 2 "$R FAIL config-malformed" "a comment after a tab, where a value should be, is refused too"
printf 'BASE_BRANCH=main\nISSUE_TITLE_CMD=echo "issue #$ISSUE"\n' > "$CFG"
create --config "$CFG" hash-in-value
expect_rc 0 "a # inside a value (not at its start) is still a value"
check "and no branch cr-inside-branch was made" test -z "$(git for-each-ref refs/heads/cr-inside-branch)"
check "and no folder was made" test ! -e "$FIX/cr-inside-branch"

# --- BASE_REMOTE naming a remote that does not exist ------------------------------------------------------------------------------
t_wt_fixture p-rem
t_wt_cfg rem.env BASE_REMOTE=nope
create --config "$CFG" feat/q
expect 2 "$R FAIL config-remote" "a BASE_REMOTE that names no remote is exit 2"
check "nothing was written to git config for it" test -z "$(git config --get-regexp '^remote\.nope' 2>/dev/null)"
check "so adding that remote afterwards works" git remote add nope "$ORIGIN"
check "and no branch or folder was made" test -z "$(git for-each-ref refs/heads/feat/q)" -a ! -e "$FIX/feat-q"

# --- a local branch that is also on the remote ---------------------------------------------------------------------------------------
t_wt_fixture p-ff
git branch lb main
t_wt_remote_commit lb f.txt remote-one
create lb
expect 0 "$R PASS created path=[^ ]*/lb .*attached=1" "a local branch behind its remote branch is used"
check "it was fast-forwarded to the remote tip" test "$(git -C "$FIX/lb" rev-parse HEAD)" = "$(t_wt_tip lb)"
check "and has the remote's file" test -f "$FIX/lb/f.txt"
check "its upstream is the remote branch" test "$(git config --get branch.lb.remote)/$(git config --get branch.lb.merge)" = "origin/refs/heads/lb"
t_wt_remote_commit la a.txt one
git fetch -q origin
git branch la origin/la
ahead="$(git commit-tree -p la -m local-extra 'la^{tree}')" && git update-ref refs/heads/la "$ahead"
create la
expect 0 "$R PASS created path=[^ ]*/la .*attached=1" "a local branch ahead of its remote branch is used as it is"
check "it kept its own commit" test "$(git -C "$FIX/la" rev-parse HEAD)" = "$ahead"
check "its upstream is the remote branch (ahead)" test "$(git config --get branch.la.remote)" = origin
t_wt_remote_commit ld d.txt remote-side
git fetch -q origin
other="$(git commit-tree -p main -m local-side 'main^{tree}')" && git branch ld "$other"
cnt="$(t_wt_count)"
create ld
expect 1 "$R FAIL branch-exists" "a diverged local branch is refused"
check "nothing was created for it" test ! -e "$FIX/ld" -a "$(t_wt_count)" = "$cnt"
check "and the local branch is untouched" test "$(git rev-parse refs/heads/ld)" = "$other"

# --- a failing git worktree add that is not a name collision ------------------------------------------------------------------------
if ! t_can_unreadable; then t_skip "a parent folder git cannot write into: chmod cannot take access away here (root, or Windows)"
else
  t_wt_fixture p-add
  mkdir "$FIX/ro" && chmod 555 "$FIX/ro"
  run env WORKTREE_PARENT_DIR="$FIX/ro" bash "$B/worktree-create.sh" rofail
  expect 1 "$R FAIL add-failed" "a parent folder git cannot write into is add-failed, not branch-exists"
  check "the branch the failed add made is gone again" test -z "$(git for-each-ref refs/heads/rofail)"
  chmod 755 "$FIX/ro"
  run env WORKTREE_PARENT_DIR="$FIX/ro" bash "$B/worktree-create.sh" rofail
  expect 0 "$R PASS created" "and the retry is not refused by a leftover branch"
fi

# --- COPY_FILES entries are literal names ---------------------------------------------------------------------------------------------
t_wt_fixture p-glob
echo s > x.env; echo s > y.env; mkdir -p sub
t_wt_cfg glob.env 'COPY_FILES=*.env'
t_wt_run_in "$PRIMARY/sub" bash "$PRIMARY/$B/worktree-create.sh" --config "$CFG" globbed
expect 0 "$R PASS created" "a glob in COPY_FILES does not fail the create"
check "a glob entry copied nothing" test ! -e "$FIX/globbed/x.env" -a ! -e "$FIX/globbed/y.env"
expect_out 'not found' "and says the literal name was not found"

# --- a failed status in the base working copy is not "clean" -------------------------------------------------------------------------
t_wt_fixture p-badbase
printf 'junk' > "$(git rev-parse --absolute-git-dir)/index"
create feat/after-bad-index
if [ "$RC" = 0 ]; then
  check "the base was not reported as updated" test -z "$(printf '%s\n' "$LAST" | grep 'base_update=updated')"
else
  t_pass "the create refused outright on an unreadable index (also not clean)"
fi

# --- a behind local branch is brought forward BEFORE the checkout (a failing post-checkout hook cannot leave it stale) -----------
t_wt_fixture p-hook
git branch hb main
t_wt_remote_commit hb h.txt remote-h
common="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
mkdir -p "$common/hooks"; printf '#!/bin/sh\nexit 1\n' > "$common/hooks/post-checkout"; chmod +x "$common/hooks/post-checkout"
create hb
hrc="$RC"; hlast="$LAST"
check "the local branch equals the remote tip whatever the hook did" test "$(git rev-parse refs/heads/hb)" = "$(t_wt_tip hb)"
check "and has its upstream set" test "$(git config --get branch.hb.remote)" = origin -a "$(git config --get branch.hb.merge)" = refs/heads/hb
if [ "$hrc" = 0 ]; then
  check "a PASS created means the worktree is at the remote tip" test "$(git -C "$FIX/hb" rev-parse HEAD)" = "$(t_wt_tip hb)"
else
  OUT="the create answered rc=$hrc: $hlast"; t_pass "a failed add is reported, not a PASS created ($hlast)"
fi
rm -f "$common/hooks/post-checkout"

t_done
