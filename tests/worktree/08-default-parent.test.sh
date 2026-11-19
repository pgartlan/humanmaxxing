#!/usr/bin/env bash
# The default worktree folder: one per repository (<parent of the main checkout>/<its name>-worktrees), made by the
# first create and by nothing else; a bare-repository layout keeps its worktrees beside the bare repository.
. "$(dirname "$0")/../lib.sh"
R='WORKTREE-RESULT worktree-create'
# Drops the fixture's pinned folder and commits that, so a worktree checked out later has the same configuration.
unpin() {
  grep -v '^WORKTREE_PARENT_DIR=' .claude/skills/worktree/worktree.env > "$T_TMP/we" && cp "$T_TMP/we" .claude/skills/worktree/worktree.env \
    && git commit -qam "default worktree folder" && git push -q origin main || exit 2
}

t_wt_fixture d1; unpin
run bash "$B/worktree-list.sh"
expect_rc 0 "list works before the folder exists"
check "list does not create the folder" test ! -e "$FIX/primary-worktrees"
run bash "$B/worktree-create.sh" feat/one
expect 0 "$R PASS created path=$FIXP/primary-worktrees/feat-one " "the first worktree goes in <repo>-worktrees"
check "the folder was made" test -d "$FIX/primary-worktrees/feat-one/.git" -o -f "$FIX/primary-worktrees/feat-one/.git"
check "nothing was put beside the repository" test ! -e "$FIX/feat-one"
t_wt_run_in "$FIX/primary-worktrees/feat-one" bash .claude/skills/worktree/bin/worktree-create.sh feat/two
expect 0 "$R PASS created path=$FIXP/primary-worktrees/feat-two " "created from inside a worktree: the same folder, not nested"
run env WORKTREE_PARENT_DIR="$FIX/nope" bash "$B/worktree-create.sh" feat/three
expect 2 "$R FAIL config-parent-dir" "a chosen folder that does not exist is refused, never created"

t_wt_bare_fixture d2; unpin
run bash "$B/worktree-create.sh" feat/one
expect 0 "$R PASS created path=$FIXP/feat-one " "a bare-repository layout keeps its worktrees beside the bare repository"
t_done
