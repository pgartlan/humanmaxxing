#!/usr/bin/env bash
# The two bindings: the CHECK binding (Phase 1, task results, the phase1 marker: the working tree's content, whole tree)
# and the REVIEW fingerprint (changed paths only). The check binding's edge cases, the untracked-file relevance rule and
# the gates that use it, all on real repositories.
. "$(dirname "$0")/../lib.sh"
TAB="$(printf '\t')"
p1() { bash "$(git rev-parse --show-toplevel)/$B/ship-sentinel.sh" --contract=2 fingerprint --phase1 2>/dev/null | sed -n 1p; }
rv() { bash "$(git rev-parse --show-toplevel)/$B/ship-sentinel.sh" --contract=2 fingerprint 2>/dev/null | sed -n 1p; }
sen() { run bash "$B/ship-sentinel.sh" --contract=2 "$@"; }
task() { run bash "$B/ship-run.sh" --contract=2 start "$@"; }
push() { run bash "$B/ship-push.sh" --contract=2 "$@"; }
is_tree() { case "$1" in *[!0-9a-f]*|'') return 1 ;; esac; [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]; }

# --- round 1: what the check binding sees ------------------------------------------------------------------
t_fixture bind "DEFAULT_MODE=local" "CRITICAL_GLOBS_FILE=.claude/critical-paths.txt" \
  'DOCS_ALLOWLIST=(\.md$|\.txt$|^docs/|(^|/)CHANGELOG)' 'DOCS_KEEP_BOUND=^docs/api/' "ISSUE_MARKER_FILE=./.issue-numbers"
mkdir -p docs/api && echo s > docs/api/s.md && git add -A && git commit -qm "keep-bound doc" && git push -q origin main
t_branch feat/7-x
t_init ""; expect 0 'ship-init PASS' "init"
BF="$FIX"

sen fingerprint --phase1
expect 0 'ship-sentinel PASS fingerprint' "the check binding prints with a PASS line"
V0=$(p1)
check "it is a 40-hex tree id in a SHA-1 repository" test "${#V0}" = 40

echo new > lib/new.ts; V1=$(p1)
check "an untracked add moves it" test "$V1" != "$V0"
git add lib/new.ts; check "staging the file keeps it" test "$(p1)" = "$V1"
git commit -qm "Refs #7 new"; check "committing the file keeps it" test "$(p1)" = "$V1"
echo edit >> lib/u.ts; check "a tracked edit moves it" test "$(p1)" != "$V1"
git checkout -q lib/u.ts; check "reverting the edit restores it" test "$(p1)" = "$V1"
rm lib/n.ts; check "an unstaged delete moves it" test "$(p1)" != "$V1"
git checkout -q lib/n.ts
if t_tracks_mode; then
  R1=$(rv); chmod +x lib/new.ts
  check "a mode change moves the check binding" test "$(p1)" != "$V1"
  check "but not the review fingerprint of a path the branch already changes (contents only)" test "$(rv)" = "$R1"
  chmod -x lib/new.ts
else t_skip "a mode change: git does not record the executable bit here (core.fileMode=false, Windows)"; fi
echo more >> docs/x.md; check "a docs-allowlisted edit does not move it" test "$(p1)" = "$V1"
git checkout -q docs/x.md
echo more >> docs/api/s.md; check "a DOCS_KEEP_BOUND edit moves it" test "$(p1)" != "$V1"
git checkout -q docs/api/s.md
echo 7 > .issue-numbers; check "the ISSUE_MARKER_FILE (spelled ./) does not move it" test "$(p1)" = "$V1"
rm -f .issue-numbers

# Base moves outside ship-sync.
t_base_commit docs/y.md docs-only; git rebase -q origin/main
check "a docs-only base commit does not move it" test "$(p1)" = "$V1"
t_base_commit lib/base.ts b1; RB=$(rv); git rebase -q origin/main
check "a base commit to a code file moves it" test "$(p1)" != "$V1"
check "the review fingerprint does not move on that base commit" test "$(rv)" = "$RB"

# --- the split: review stays valid, Phase 1 does not ---------------------------------------------------------
run bash "$B/ship-sync.sh" --contract=2; expect 0 'PASS synced' "sync"
task lint -- true; expect 0 'ship-run PASS' "a task"
sen write phase1; expect 0 'PASS phase1-written' "phase1 written"
printf '%s\n%s\n%s\n' "$(rv)" "$(date +%s)" "$(git rev-parse HEAD)" > "$ST/review-code-ran"
push; expect 0 'ship-push PASS' "the first push"
echo fix >> lib/u.ts; git commit -qam "fix: Refs #7"
task lint -- true; sen write phase1; expect 0 'PASS phase1-written' "phase1 re-earned after the fix"
push --kind fix --round 1 --review manual; expect 0 'ship-push PASS' "a fix push recorded in the review chain"
TIP=$(git ls-remote origin refs/heads/feat/7-x | cut -f1)
t_base_commit lib/base.ts b2; git rebase -q origin/main
sen verify review; expect 0 'ship-sentinel PASS review-fresh' "the review stays valid across a base move"
sen verify phase1; expect 1 'FAIL phase1-tree-moved' "Phase 1 does not"
run bash "$B/ship-status.sh" --contract=2
expect_out '^STEP phase1: tree-moved' "the phase1 marker is stale"
expect_out '^STEP pushed: ok' "the other markers keep the review fingerprint"
push --kind rebase --review full; expect 1 'FAIL phase1-invalid' "the local-mode push refuses"
check "nothing was pushed" test "$TIP" = "$(git ls-remote origin refs/heads/feat/7-x | cut -f1)"

# --- the untracked gate ---------------------------------------------------------------------------------------
task lint -- true; sen write phase1; expect 0 'PASS phase1-written' "phase1 on the moved base"
mkdir -p lib/sub lib2; echo x > lib/sub/x.ts; echo y > lib2/y.ts; echo s > 'lib/sp ace.ts'; echo r > scratch.txt
echo '*.log' >> .git/info/exclude; echo g > lib/ignored.log
sen untracked; expect 0 'PASS untracked relevant=2 ignored=2' "untracked files are sorted"
mkdir -p lib/new && echo n > lib/new/a.ts && echo m > lib/new/b.ts
sen untracked; expect_out "^RELEVANT${TAB}lib/new/a.ts\$" "an untracked directory is listed as its files"
expect_out "^RELEVANT${TAB}lib/new/b.ts\$" "every one of them"
cd lib/sub || exit 2; run bash "../../$B/ship-sentinel.sh" --contract=2 untracked; cd ../.. || exit 2
expect_out "^RELEVANT${TAB}lib/new/a.ts\$" "run from a subdirectory, it still sees the whole tree"
expect_out "^IGNORED${TAB}scratch.txt\$" "including files outside that subdirectory"
rm -rf lib/new
refute_out 'ignored.log' "a gitignored file is never listed"
expect_out "^RELEVANT${TAB}lib/sub/x.ts\$" "a file below a changed directory is relevant"
expect_out "^RELEVANT${TAB}lib/sp ace.ts\$" "a path with a space is listed intact"
expect_out "^IGNORED${TAB}lib2/y.ts\$" "a sibling directory whose name shares a prefix is not"
expect_out "^IGNORED${TAB}scratch.txt\$" "a root file is not, while the branch changes no root file"
CHAIN=$(wc -l < "$ST/review-chain")
push --kind fix --round 2 --review manual; expect 7 'FAIL untracked-relevant' "local mode: exit 7 (untracked), not 1 (phase1)"
check "the review chain was not appended" test "$(wc -l < "$ST/review-chain")" = "$CHAIN"
echo dirty >> lib/n.ts
push --kind fix --round 2 --review manual; expect 7 'FAIL dirty-tree' "a dirty tree is reported first"
git checkout -q lib/n.ts
task lint -- true; sen write phase1; expect 0 'PASS phase1-written' "phase1 written with the untracked files present"
sen verify phase1 --committed; expect 1 'FAIL untracked-relevant' "verify --committed refuses a relevant untracked file"
expect_out '^lib/sub/x.ts$' "and names it"
rm -rf lib/sub 'lib/sp ace.ts'
task lint -- true; sen write phase1
sen verify phase1 --committed; expect 0 'PASS phase1-ok' "ignored files do not block the gate"
expect_out '^NOTE untracked, not near this branch' "they are listed"
expect_out '^lib2/y.ts$' "by path"
echo z > lib2/z.ts
sen verify phase1; expect 1 'FAIL phase1-tree-moved' "but any untracked change still moves the binding"
rm -f lib2/z.ts
sen verify phase1; expect 0 'PASS phase1-ok' "and removing it restores it"
SAVED=$(git rev-parse refs/remotes/origin/main)
git update-ref -d refs/remotes/origin/main
sen verify phase1 --committed; expect 3 'FAIL merge-base-unresolved' "verify --committed with an unresolvable merge-base is exit 3, never a pass"
git update-ref refs/remotes/origin/main "$SAVED"
check "the base ref is restored" test "$(git rev-parse refs/remotes/origin/main)" = "$SAVED"
echo r2 >> CHANGELOG.md; git commit -qam "Refs #7 changelog"
sen untracked; expect_out "^RELEVANT${TAB}scratch.txt\$" "a root file is relevant once the branch changes a root file"
echo 7 > .issue-numbers
sen untracked; refute_out "issue-numbers" "the ISSUE_MARKER_FILE is never listed"
rm -rf lib2 scratch.txt .issue-numbers

# Relevance edges: directory names compare as strings; an uncommitted edit counts; a directory the branch only deletes from.
mkdir -p a.b aXb && echo 1 > a.b/x.ts && git add a.b && git commit -qm "Refs #7 a.b"
echo f > aXb/f.ts
sen untracked; expect_out "^IGNORED${TAB}aXb/f.ts\$" "a.b does not match aXb"
rm -rf aXb
git rm -q lib/n.ts && git commit -qm "Refs #7 drop n"
mkdir -p lib/deep/er && echo d > lib/deep/er/d.ts
sen untracked; expect_out "^RELEVANT${TAB}lib/deep/er/d.ts\$" "a directory the branch only deletes from counts, at any depth"
rm -rf lib/deep
echo edit >> docs/x.md
mkdir -p docs/new && echo n > docs/new/n.md
sen untracked; expect_out "^RELEVANT${TAB}docs/new/n.md\$" "a directory changed only by an uncommitted edit counts"
git checkout -q docs/x.md; rm -rf docs/new

# Known gap, pinned so a change of behaviour shows up here: a new top-level directory (the index case is in the seed fixture).
mkdir -p newpkg && echo n > newpkg/n.ts
sen untracked; expect_out "^IGNORED${TAB}newpkg/n.ts\$" "known gap: a new top-level directory the branch touches nowhere else"
rm -rf newpkg

# --- round 2: broken assumptions ------------------------------------------------------------------------------
V=$(p1)
: > .git/index.lock
check "a held index.lock does not block it" test "$(p1)" = "$V"
check "and the lock is untouched" test -f .git/index.lock
CK0=$(cksum < .git/index); p1 >/dev/null
check "the real index is byte-identical while the lock is held" test "$(cksum < .git/index)" = "$CK0"
rm -f .git/index.lock

# The real index changing during the computation: every output is a tree id or an error line, never garbage.
echo race >> lib/u.ts; rm -f "$FIX/stop"
( while [ ! -f "$FIX/stop" ]; do git add lib/u.ts 2>/dev/null || true; git reset -q lib/u.ts 2>/dev/null || true; done ) &
LP=$!; BAD=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  O=$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint --phase1 2>&1); ORC=$?; L1=$(printf '%s\n' "$O" | sed -n 1p)
  if [ "$ORC" -eq 0 ]; then is_tree "$L1" || BAD=$i
  elif [ "$ORC" -eq 3 ]; then case "$L1" in SENTINEL-ERROR:*) ;; *) BAD=$i ;; esac
  else BAD=$i; fi
done
touch "$FIX/stop"; wait "$LP"; rm -f "$FIX/stop" .git/index.lock
git reset -q lib/u.ts 2>/dev/null; git checkout -q lib/u.ts
check "under a racing index every result is a tree id or an error line (bad run: $BAD)" test "$BAD" = 0

git update-index -q --refresh
git ls-files -s > "$FIX/ls.before"; git diff --cached --name-status > "$FIX/dc.before"
p1 >/dev/null
git ls-files -s > "$FIX/ls.after"; git diff --cached --name-status > "$FIX/dc.after"
check "the real index is unchanged (entries)" cmp -s "$FIX/ls.before" "$FIX/ls.after"
check "the real index is unchanged (nothing staged)" cmp -s "$FIX/dc.before" "$FIX/dc.after"

V=$(p1)
git update-index --assume-unchanged lib/u.ts; echo au >> lib/u.ts
check "an edit to an assume-unchanged file moves it" test "$(p1)" != "$V"
git update-index --no-assume-unchanged lib/u.ts; git checkout -q lib/u.ts
git update-index --skip-worktree lib/u.ts; echo sw >> lib/u.ts
check "an edit to a skip-worktree file moves it" test "$(p1)" != "$V"
git update-index --no-skip-worktree lib/u.ts; git checkout -q lib/u.ts
check "and both flags leave the value as it was once reverted" test "$(p1)" = "$V"
check "the file for the absent skip-worktree case exists" test -f app/api/r.ts
git update-index --skip-worktree app/api/r.ts && rm -f app/api/r.ts
check "a skip-worktree file absent on disk keeps its recorded content" test "$(p1)" = "$V"
git update-index --no-skip-worktree app/api/r.ts; git checkout -q app/api/r.ts


mkdir -p tmpout; mkdir -p "$FIX/tmp"
check "temporary files are removed after a success" sh -c "TMPDIR='$FIX/tmp' bash '$B/ship-sentinel.sh' --contract=2 fingerprint --phase1 >/dev/null && test -z \"\$(ls -A '$FIX/tmp')\""
rmdir tmpout

git init -q nested && ( cd nested && echo x > f && git add f && git commit -qm n ) >/dev/null
sen fingerprint --phase1; expect 3 'FAIL fingerprint-error' "an untracked nested repository with a commit is an error"
expect_out 'untracked nested repository nested/' "naming it"
rm -rf nested; mkdir -p outer/inner && git init -q outer/inner
sen fingerprint --phase1; expect 3 'FAIL fingerprint-error' "one without a commit inside an untracked directory too"
expect_out 'outer/inner/' "naming it"
check "temporary files are removed after an error" sh -c "TMPDIR='$FIX/tmp' bash '$B/ship-sentinel.sh' --contract=2 fingerprint --phase1 >/dev/null; test -z \"\$(ls -A '$FIX/tmp')\""
rm -rf outer
mkdir -p vendor/x && git init -q vendor/x && echo vendor/ >> .git/info/exclude
sen fingerprint --phase1; expect 0 'PASS fingerprint' "an ignored nested repository is fine"
rm -rf vendor

NL="lib/bad
name.ts"
if t_can_name "a
b"; then
echo x > "$NL"
sen fingerprint --phase1; expect 3 'FAIL fingerprint-error' "a path with a newline is an error"
sen untracked; expect 3 'FAIL untracked-unreadable' "for the relevance list too"
else t_skip "a path with a newline: this filesystem cannot make one (Windows)"; fi
rm -f "$NL"

printf '*.bin filter=gone\n' > .gitattributes; git add .gitattributes; git commit -qm "Refs #7 attrs"
git config filter.gone.clean false; git config filter.gone.required true
echo b > lib/x.bin
sen fingerprint --phase1; expect 3 'FAIL fingerprint-error' "a required filter that fails is an error, never a value"
task lint -- true; sen write phase1; expect 3 'FAIL reader-error' "and phase1 cannot be written"
rm -f lib/x.bin; git config --unset filter.gone.required; git config --unset filter.gone.clean
git rm -q .gitattributes; git commit -qm "Refs #7 drop attrs"

V=$(p1); mv .git/index "$FIX/index.saved"
sen fingerprint --phase1; expect 3 'FAIL fingerprint-error' "a missing real index with a HEAD is an error"
mv "$FIX/index.saved" .git/index

if ! t_can_unreadable; then t_skip "an unreadable index: chmod cannot take read access away here (root, or Windows)"
else
  chmod 000 .git/index
  sen fingerprint --phase1; expect 3 'FAIL fingerprint-error' "an unreadable real index is an error"
  chmod 644 .git/index
fi

# Tracked files under an ignored directory stay in (the throwaway index is seeded from the real one).
mkdir -p build && echo keep > build/keep.out && git add build/keep.out && git commit -qm "Refs #7 build" && echo build/ >> .gitignore
git add .gitignore && git commit -qm "Refs #7 ignore build"
V=$(p1); cd lib || exit 2; VSUB=$(p1); cd .. || exit 2; check "the same value from a subdirectory" test "$VSUB" = "$V"
git worktree add -q "$FIX/linked" HEAD 2>/dev/null
VL=$(cd "$FIX/linked" && p1); check "the same value from a linked worktree of the same content" test "$VL" = "$V"
git worktree remove --force "$FIX/linked"
HK="$(git rev-parse --git-path hooks)"; mkdir -p "$HK"
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$FIX" > "$HK/post-index-change"; chmod +x "$HK/post-index-change"
rm -f "$FIX/hook-ran"; p1 >/dev/null
check "the user's index hooks do not run on the scratch index" test ! -f "$FIX/hook-ran"
rm -f "$HK/post-index-change"
ALT="$FIX/alt-index"; GIT_INDEX_FILE="$ALT" git read-tree --empty
cp "$ALT" "$FIX/alt.copy"
check "an inherited GIT_INDEX_FILE (an empty alternate index) is ignored" test "$(GIT_INDEX_FILE="$ALT" p1)" = "$V"
check "and the alternate index is untouched" cmp -s "$ALT" "$FIX/alt.copy"

# An edit landing between collect and the sentinel write never gets a sentinel. The seam: a clean filter (it still runs
# in the scratch index) that edits a tracked file the first time it is called from ship-sentinel.sh itself. Every ship
# script exports SHIP_LOG named after itself, and in write phase1 the sentinel script's own computation comes after
# collect (which runs as ship-run.sh), so the edit always lands between the two.
printf '*.cf filter=edit\n' > .gitattributes; echo c > a.cf; git add -A; git commit -qm "Refs #7 cf" || exit 2
printf '#!/bin/sh\ncase "$SHIP_LOG" in *ship-sentinel.log) [ -f "%s/fired" ] || { touch "%s/fired"; echo racer >> "%s/lib/u.ts"; } ;; esac\ncat\n' "$FIX" "$FIX" "$PWD" > "$FIX/clean.sh"; chmod +x "$FIX/clean.sh"
git config filter.edit.clean "$FIX/clean.sh"
task lint -- true; touch a.cf; rm -f "$FIX/fired" "$ST/ship-phase1-passed"
sen write phase1; expect 1 'FAIL tasks-not-green' "an edit landing after collect never gets a sentinel"
expect_out 'tree changed while the tasks were being checked' "the write itself refuses it"
check "no sentinel was written" test ! -f "$ST/ship-phase1-passed"
check "the seam fired" test -f "$FIX/fired"
git config --unset filter.edit.clean; git checkout -q lib/u.ts; git rm -q a.cf .gitattributes; git commit -qm "Refs #7 drop cf"

# Two tasks finishing together, then the old binding format.
task lint -- true
task a -- true & PA=$!; task b -- true & PB=$!; wait $PA $PB
check "both tasks recorded a result" test -f "$ST/tasks/a.exit" -a -f "$ST/tasks/b.exit"
sen write phase1; expect 0 'PASS phase1-written' "two tasks that finished together"
printf '%s\n%s\n%s\n' "$(printf 'a%.0s' $(seq 64))" "$(git rev-parse HEAD)" "$(date +%s)" > "$ST/ship-phase1-passed"
sen verify phase1; expect 1 'FAIL phase1-tree-moved' "an old 64-hex sentinel is stale"
expect_out 'binding format changed' "and says why"
printf 'rc=0\nepoch=%s\nhead=%s\nfp=%s\n' "$(date +%s)" "$(git rev-parse HEAD)" "$(printf 'b%.0s' $(seq 64))" > "$ST/tasks/a.exit"
sen write phase1; expect 1 'FAIL tasks-not-green' "an old 64-hex task result is stale"
run bash "$B/ship-run.sh" --contract=2 collect a --same-tree
expect_out 'binding format changed' "and says why"

# --- the review fingerprint is unchanged: literals computed with the scripts before the check binding existed ---------
t_fixture pin "DEFAULT_MODE=offload" "CRITICAL_GLOBS_FILE=.claude/critical-paths.txt" \
  'DOCS_ALLOWLIST=(\.md$|\.txt$|^docs/|(^|/)CHANGELOG)' 'DOCS_KEEP_BOUND=^docs/api/'
t_branch feat/7-x
mkdir -p docs/api && echo s > docs/api/s.md && echo p > lib/p.ts && echo d >> docs/x.md && git rm -q lib/n.ts && git commit -qm "Refs #7 pin" && echo u > lib/untracked.ts
check "the pin fixture's state is exactly as computed" test "$(git status --porcelain | tr '\n' '|')" = " M docs/x.md|?? docs/api/|?? lib/p.ts|?? lib/untracked.ts|"
check "review fingerprint (default kind) unchanged" test "$(rv)" = dd0351b1f5c66babc02f5b9419e72611b8984c77ee38bdcd45881ee86d7986fa
check "review fingerprint (--critical) unchanged" test "$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint --critical | sed -n 1p)" = 6603c66da3a23fa2b17763ccaeb989160557e28db8c0831e8e3a28546bce062a
check "review fingerprint (--raw) unchanged" test "$(bash "$B/ship-sentinel.sh" --contract=2 fingerprint --raw | sed -n 1p)" = 7e9674f8c4b5eb4deb96eff7cf5203935deea5e6133302b8f264efbfb1b9aa74

# --- seeding: with nothing excluded and a clean tree, the value is HEAD's tree (an unseeded index would drop build/keep.out)
t_fixture seed "DEFAULT_MODE=local"
mkdir -p build && echo keep > build/keep.out && git add build/keep.out && echo build/ > .gitignore && git add .gitignore
git commit -qm "tracked file under an ignored directory"
check "on a clean tree with no exclusions it is HEAD's tree" test "$(p1)" = "$(git rev-parse 'HEAD^{tree}')"
cd lib || exit 2; VSUB=$(p1); cd .. || exit 2; check "from a subdirectory too" test "$VSUB" = "$(git rev-parse 'HEAD^{tree}')"
NL="lib/bad
name.ts"
if t_can_name "a
b"; then
echo x > "$NL"
sen fingerprint --phase1; expect 3 'FAIL fingerprint-error' "a newline path is an error with no DOCS_ALLOWLIST set too"
rm -f "$NL"
else t_skip "a newline path with no DOCS_ALLOWLIST: this filesystem cannot make one (Windows)"; fi
git push -q origin main
echo z > lib/z.ts
sen untracked; expect_out "^IGNORED${TAB}lib/z.ts\$" "with no change on the branch every untracked file is ignored"
rm -f lib/z.ts
git checkout -q -b feat/5-g && mkdir -p lib/sub lib/solo && echo a > lib/sub/a.ts && echo s > lib/solo/s.ts && git add lib && git commit -qm "Refs #5 g"
echo b > lib/b.ts
sen untracked; expect_out "^IGNORED${TAB}lib/b.ts\$" "a change in lib/sub does not make its parent lib relevant"
rm -f lib/b.ts
git rm -q --cached lib/solo/s.ts
sen untracked; expect 0 'PASS untracked' "known gap, pinned: a file removed from the index"
expect_out "^IGNORED${TAB}lib/solo/s.ts\$" "whose directory has no other change reads IGNORED (listed, not blocking)"
git add lib/solo/s.ts
# A directory the branch only deletes from (this branch touches nothing else under app/): deletions count.
git rm -q app/api/r.ts && git commit -qm "Refs #5 drop r" || exit 2
mkdir -p app/api && echo q > app/api/q.ts
sen untracked; expect 0 'PASS untracked relevant=1' "a directory the branch only deletes from counts"
expect_out "^RELEVANT${TAB}app/api/q.ts\$" "the file there is relevant"

# --- unborn repository ----------------------------------------------------------------------------------------
mkdir -p "$T_TMP/unborn" && cd "$T_TMP/unborn" && git init -q -b main . && mkdir -p .claude/skills
cp -R "$T_ROOT/skills/ship" .claude/skills/ship && echo "BASE_BRANCH=main" > .claude/skills/ship/ship.env && echo u > u.txt
run bash .claude/skills/ship/bin/ship-sentinel.sh --contract=2 fingerprint --phase1
expect 0 'PASS fingerprint' "an unborn repository gives a value"
check "a tree id" is_tree "$(printf '%s\n' "$OUT" | sed -n 1p)"

# --- SHA-256 repository (when this git supports it) -----------------------------------------------------------
if git init -q --object-format=sha256 "$T_TMP/probe256" >/dev/null 2>&1; then
  mkdir -p "$T_TMP/s256" && cd "$T_TMP/s256" && git init -q --object-format=sha256 -b main . && mkdir -p .claude/skills lib
  cp -R "$T_ROOT/skills/ship" .claude/skills/ship && echo "BASE_BRANCH=main" > .claude/skills/ship/ship.env && echo l > lib/u.ts
  git add -A && git commit -qm init
  run bash .claude/skills/ship/bin/ship-sentinel.sh --contract=2 fingerprint --phase1
  expect 0 'PASS fingerprint' "a SHA-256 repository gives a value"
  check "of 64 hex" test "$(printf '%s\n' "$OUT" | sed -n 1p | tr -d '\n' | wc -c | tr -d ' ')" = 64
  echo "DEFAULT_MODE=local" >> .claude/skills/ship/ship.env && git commit -qam "mode" \
    && git init -q --bare --object-format=sha256 -b main "$T_TMP/s256o.git" && git remote add origin "$T_TMP/s256o.git" \
    && git push -q -u origin main && git checkout -q -b feat/5-s && echo x >> lib/u.ts && git commit -qam "Refs #5 s" || exit 2
  run bash .claude/skills/ship/bin/ship-init.sh --contract=2 --skill-dir "$PWD/.claude/skills/ship"; expect 0 'ship-init PASS' "init in a SHA-256 repository"
  run bash .claude/skills/ship/bin/ship-run.sh --contract=2 start lint -- true
  run bash .claude/skills/ship/bin/ship-sentinel.sh --contract=2 write phase1; expect 0 'PASS phase1-written' "phase1 written with a 64-hex binding"
  run bash .claude/skills/ship/bin/ship-sentinel.sh --contract=2 verify phase1; expect 0 'PASS phase1-ok' "and verified"
  run bash .claude/skills/ship/bin/ship-sentinel.sh --contract=2 fingerprint; expect 0 'PASS fingerprint' "the review fingerprint works there too"
else
  echo "  SKIP sha256: this git has no --object-format=sha256"
fi

# --- cone-mode sparse checkout (git 2.34 or later) ------------------------------------------------------------
cd "$BF/work" || exit 2
V=$(p1)
if git sparse-checkout set --cone lib .claude >/dev/null 2>&1; then
  VS=$(p1)
  check "a sparse checkout gives the same value as the full one" test "$VS" = "$V"
  mkdir -p app/api && echo u > app/api/new.ts
  check "an untracked file outside the cone moves it" test "$(p1)" != "$VS"
  rm -f app/api/new.ts
  echo changed > app/api/r.ts
  sen fingerprint --phase1; expect 0 'PASS fingerprint' "an edited file outside the cone is not an error"
  check "and moves it" test "$(p1)" != "$VS"
  rm -f app/api/r.ts
  git sparse-checkout disable >/dev/null 2>&1
else
  echo "  SKIP sparse: git sparse-checkout --cone unavailable"
fi

t_done
