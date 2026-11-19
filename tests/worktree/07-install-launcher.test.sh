#!/usr/bin/env bash
# worktree-install-launcher.sh: writes the per-machine `maxx-start` command, which runs the primary copy's launcher
# from any directory; never overwrites a file it did not write.
. "$(dirname "$0")/../lib.sh"
R='WORKTREE-RESULT worktree-install-launcher'

t_wt_fixture l1 "START_CMD=echo session" "START_MODELS=opus" "START_DEFAULT_MODEL=opus"
BIN="$FIX/bin"
run bash "$B/worktree-install-launcher.sh" --dir "$BIN"
expect 0 "$R PASS installed path=$FIXP/bin/maxx-start" "writes maxx-start by default"
check "it is executable" test -x "$BIN/maxx-start"
check "it changes into the primary working copy" grep -qF "cd $FIXP/primary" "$BIN/maxx-start"
check "no --parent without a machine override (the launcher reads the setting itself)" sh -c '! grep -q -- "--parent" "$1"' _ "$BIN/maxx-start"
expect_out "is not on your PATH" "it says when the folder is not on PATH"

# It works from anywhere: a bad argument reaches the real launcher in the primary copy.
t_wt_run_in "$T_TMP" "$BIN/maxx-start" not-an-issue!
expect 2 'WORKTREE-RESULT worktree-start FAIL usage' "run from another directory, it reaches the launcher"

run bash "$B/worktree-install-launcher.sh" --dir "$BIN"
expect 0 "$R PASS current path=" "a second run finds it current"

# From a sibling worktree it still points at the primary copy.
git worktree add -q "$FIX/side" -b side || exit 2
t_wt_run_in "$FIX/side" bash .claude/skills/worktree/bin/worktree-install-launcher.sh --dir "$BIN" --name maxx-start-2
expect_rc 0 "installs from a sibling worktree"
check "and still targets the primary copy" grep -qF "cd $FIXP/primary" "$BIN/maxx-start-2"

# A file it did not write is never replaced.
printf '#!/bin/sh\necho mine\n' > "$BIN/mine"
run bash "$B/worktree-install-launcher.sh" --dir "$BIN" --name mine
expect 1 "$R FAIL exists-foreign" "someone else's file of that name is refused"
check "and left as it was" grep -q 'echo mine' "$BIN/mine"

# A file it wrote earlier is updated (here: a different config file now).
t_wt_cfg other.env "START_CMD=echo session"
run bash "$B/worktree-install-launcher.sh" --dir "$BIN" --config "$CFG"
expect 0 "$R PASS installed" "its own earlier file is replaced"
check "a non-default config is passed through" grep -qF -- "--config $FIXP/other.env" "$BIN/maxx-start"

run env WORKTREE_PARENT_DIR="$FIX" bash "$B/worktree-install-launcher.sh" --dir "$BIN" --name maxx-start-env
expect_rc 0 "installs with a machine override"
check "a machine's WORKTREE_PARENT_DIR is passed as --parent" grep -qF -- "--parent $FIXP" "$BIN/maxx-start-env"

run bash "$B/worktree-install-launcher.sh" --dir "$BIN" --name 'bad name'
expect_rc 2 "a name with a space is refused"
run bash "$B/worktree-install-launcher.sh" --dir "$BIN" --bogus
expect_rc 2 "an unknown option is refused"
t_done
