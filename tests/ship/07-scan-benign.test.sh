#!/usr/bin/env bash
# scan-conflicts: benign untracked entries (nested git repo listed as "sub/", dangling symlink) must not turn a clean tree into scan-failed.
. "$(dirname "$0")/../lib.sh"
sync() { run bash "$B/ship-sync.sh" --contract=2 "$@"; }

t_fixture scanbenign "DEFAULT_MODE=offload"
t_branch feat/7-x
t_init ""; expect 0 'ship-init PASS' "init"

mkdir nested && ( cd nested && git init -q . && echo hi > f.txt )
sync scan-conflicts; expect 0 'PASS' "an untracked nested git repo does not make scan-conflicts fail"

rm -rf nested
if ! t_can_symlink; then t_skip "a dangling symlink: ln -s cannot make one here (Windows without developer mode)"
else
ln -s /nonexistent/target dangling
sync scan-conflicts; expect 0 'PASS' "an untracked dangling symlink does not make scan-conflicts fail"
fi

t_done
