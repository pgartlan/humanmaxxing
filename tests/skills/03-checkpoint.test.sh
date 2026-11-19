#!/usr/bin/env bash
# checkpoint's rules that keep a commit from closing, stamping or leaking what it should not, and peer-review's merge
# path. The test-update guard is run functionally: the one line in SKILL.md, extracted and run on a fixture repo, so the
# qualifiers (untracked tests count, an unreadable merge-base or an empty change set HALTs, never passes) are pinned by
# behavior, not by a grep.
. "$(dirname "$0")/../lib.sh"
cd "$T_ROOT" || exit 2
CP=skills/checkpoint/SKILL.md
PR=skills/peer-review/SKILL.md

# --- commit messages never close an issue ----------------------------------------------------------------------------
check "checkpoint: commits reference issues with Refs only" grep -q 'Reference a tracked issue as `Refs #123` only' "$CP"
check "checkpoint: no closing keyword anywhere in a commit message, mid-line included" grep -q 'never a closing keyword anywhere in a commit$' "$CP"
check "checkpoint: mid-line qualifier present" grep -q 'message, mid-line included\*\*' "$CP"
check "checkpoint: Closes is never offered as a commit form" sh -c '! grep -q "Refs #123\` / \`Closes #123\`" "$1"' _ "$CP"
check "checkpoint: says why (closes at the default branch, past every gate)" grep -q 'that commit reaches the default branch, past every gate' "$CP"

# --- the tracker step runs only for merged work ----------------------------------------------------------------------
S37="$(awk '/^## Step 3.7/{f=1} /^## Step 4/{f=0} f' "$CP")"
has37() { printf '%s' "$S37" | grep -qF -- "$1"; }
check "checkpoint 3.7: only for work already merged into the base" has37 'Only for work that has ALREADY merged into `$BASE_BRANCH`.'
check "checkpoint 3.7: a feature-branch commit closes nothing; reports issues close at merge" sh -c 'printf "%s" "$1" | grep -qF "branch closes nothing" && printf "%s" "$1" | grep -qF "report \`issues close at merge\`"' _ "$S37"
check "checkpoint 3.7: a failed PR read is never taken as merged" has37 'A failed read is never taken as merged.'
check "checkpoint 3.7: the list is the merged PR body's closing keywords, never commits" has37 "merged PR body's closing-keyword issues, never the commit messages"
check "checkpoint 3.7: the sub-issue guard runs before either write" has37 'sub-issue guard runs before either write'
check "checkpoint 3.7: a parent with open children is retried, then HELD, never closed" sh -c 'printf "%s" "$1" | grep -qF "retry it after" && printf "%s" "$1" | grep -qF "HELD (open children)" && printf "%s" "$1" | grep -qF "never close the parent"' _ "$S37"
check "checkpoint 3.7: unreadable children are FAILED, never no children" has37 'never "no children"'
check "checkpoint 3.7: every write checked; one outcome per issue; INCOMPLETE" sh -c 'printf "%s" "$1" | grep -qF "Every write is checked" && printf "%s" "$1" | grep -qF "exactly one outcome" && printf "%s" "$1" | grep -qF "INCOMPLETE"' _ "$S37"

# --- the docs subagent reads this session's transcript only ----------------------------------------------------------
check "checkpoint docs: transcript found by this session's id" grep -qF -- '-name "${CLAUDE_CODE_SESSION_ID:?}.jsonl"' "$CP"
check "checkpoint docs: never the newest transcript; not found is a STOP" sh -c 'grep -qF "never fall back to the newest transcript" "$1" && grep -qF "STOP and" "$1" && ! grep -q "the most recent session transcript" "$1"' _ "$CP"
check "checkpoint docs: the marker is written with && and never elsewhere" sh -c 'grep -qF "SHIP_STATE=\"\$(git rev-parse --git-path ship-state)\" && mkdir -p \"\$SHIP_STATE\" &&" "$1" && grep -qF "never write the marker anywhere else" "$1"' _ "$CP"

# --- a skipped build is never a pass; no bare-timestamp sentinels ----------------------------------------------------
check "checkpoint: a skipped build is reported skipped, never passed" grep -qF 'as skipped, never as passed: the build did not run' "$CP"
check "checkpoint: no pass sentinel is written (nothing reads them)" sh -c '! grep -q "checkpoint-[a-z<>-]*-passed" "$1"' _ "$CP"
check "checkpoint: no one-block check run (a later green masks an earlier red)" sh -c '! grep -q "^\$LINT_CMD; \$TEST_CMD" "$1" && grep -qF "never one block judged" "$1"' _ "$CP"
check "checkpoint: a failed base fetch HALTs instead of rebasing onto a stale base" grep -qF 'not rebasing onto a stale base' "$CP"
check "checkpoint: an empty merge-base HALTs" grep -qF 'HALT: no merge-base with origin/$BASE_BRANCH' "$CP"
check "checkpoint: the UU check is gated on a zero-exit rebase with an autostash line" grep -qF 'exited 0 and printed a `Created autostash:' "$CP"
check "checkpoint: never fix a red by editing expected values or suppressing findings" grep -qF 'Never "fix" a red by changing a' "$CP"
check "checkpoint: domain checks validate, never apply" grep -qF 'A domain check validates and never applies' "$CP"
check "checkpoint: commit-only; never creates a PR or merges" sh -c 'grep -qF "It never" "$1" && grep -qF "No PR is created and nothing is merged" "$1" && ! grep -qE -- "--pr([^a-z-]|\$)" "$1"' _ "$CP"
check "checkpoint: a merged PR's branch gets no new push" grep -qF 'never onto a merged PR' "$CP"
check "checkpoint: behavior-neutral justification in the commit body; later is refused" sh -c 'grep -qF "provably behavior-neutral" "$1" && grep -q "\"I.ll add tests later\" is not a justification and is refused" "$1"' _ "$CP"

# --- the test-update guard, run --------------------------------------------------------------------------------------
LINE="$(grep -m1 "^BASE_BRANCH='<BASE_BRANCH>' CRITICAL_GLOBS_FILE=" "$CP")"
check "checkpoint guard: present as one line" test -n "$LINE"
GUARD="$(printf '%s' "$LINE" | sed "s/^.*' bash -c '//; s/'\$//")"
check "checkpoint guard: body extracted" sh -c 'printf "%s" "$1" | grep -q "^set -f;" && printf "%s" "$1" | grep -q "exit 10\$"' _ "$GUARD"
G="$T_TMP/guard"
(
  git init -q --bare "$G/origin.git" && git clone -q "$G/origin.git" "$G/w" 2>/dev/null && cd "$G/w" \
    && git checkout -q -b main && mkdir -p src tests && echo a > src/a.ts && echo t > tests/a.test.ts \
    && printf '# critical paths\n\nsrc/**\n' > crit.txt && echo '# only a comment' > none.txt \
    && git add . && git commit -qm init && git push -q origin main && git checkout -q -b feat
) || exit 2
g() { run sh -c 'cd "$1" && BASE_BRANCH="$2" CRITICAL_GLOBS_FILE="$3" TEST_GLOBS="$4" bash -c "$5"' _ "$G/w" "$1" "$2" "$3" "$GUARD"; }
g main crit.txt 'tests/** **/*.test.ts'
expect 20 'HALT: nothing changed' "guard: an empty change set HALTs (never a vacuous pass)"
echo b > "$G/w/src/a b.ts"
g main crit.txt 'tests/** **/*.test.ts'
expect 10 '^STOP: critical product code changed' "guard: a critical change with no test STOPs (untracked product file counts)"
expect_out '^COUPLING_PROD: src/a b\.ts$' "guard: names each product file, a path with a space intact"
g main missing.txt 'tests/** **/*.test.ts'
expect 20 '^HALT: cannot read missing\.txt' "guard: a named list that is missing HALTs, never 'no critical paths'"
g main none.txt 'tests/** **/*.test.ts'
expect 0 'holds only comments' "guard: a list of only comments makes nothing critical"
echo t2 > "$G/w/tests/b.test.ts"
g main crit.txt 'tests/** **/*.test.ts'
expect 0 '^PASS: a test file changed too' "guard: an untracked new test file counts as a test change"
rm "$G/w/tests/b.test.ts"; echo more >> "$G/w/tests/a.test.ts"
g main crit.txt 'tests/** **/*.test.ts'
expect 0 '^PASS: a test file changed too' "guard: a tracked test edit counts"
git -C "$G/w" checkout -q -- tests/a.test.ts
g nosuch crit.txt 'tests/** **/*.test.ts'
expect 20 '^HALT: no merge-base' "guard: an unresolvable merge-base HALTs, never passes"
g main '' ''
expect 0 'not configured' "guard: empty CRITICAL_GLOBS_FILE says not configured"
g main crit.txt ''
expect 20 'TEST_GLOBS not configured' "guard: a critical list without TEST_GLOBS HALTs"
rm "$G/w/src/a b.ts"; echo doc > "$G/w/README"
g main crit.txt 'tests/** **/*.test.ts'
expect 0 '^PASS: no critical product file changed' "guard: a change outside the critical globs passes"

# --- peer-review: a requested merge ----------------------------------------------------------------------------------
S8="$(awk '/^## Step 8/{f=1} /^---$/{if(f)exit} f' "$PR")"
has8() { printf '%s' "$S8" | grep -qF -- "$1"; }
check "peer-review: the verdict is posted before a merge; a failed post means no merge" sh -c 'printf "%s" "$1" | grep -qF "Post the verdict first" && printf "%s" "$1" | grep -qF "STOP and report it; no merge"' _ "$S8"
check "peer-review: queue means the label, never a plain gh pr merge on a queue-governed base" has8 'Never a plain `gh pr merge` on a queue-governed base'
check "peer-review: the queue governs BASE_BRANCH only; another base merges directly" has8 '`direct`, or a base the queue does not govern'
check "peer-review: never --admin unless instructed for this PR" has8 'Never `--admin`'
check "peer-review: a direct merge is verified by state and mergedAt" has8 '--json state,mergedAt'
check "peer-review: merge settings are read from ship's config when installed, never copied" grep -qF 'write `see ship.env` and read' "$PR"
check "peer-review: MERGE_METHOD is a Configuration key" grep -qx 'MERGE_METHOD=' "$PR"
t_done
