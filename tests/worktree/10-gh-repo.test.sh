#!/usr/bin/env bash
# GH_REPO in worktree.env: worktree-issue.sh exports it to every gh call and uses it as the repository name (`gh repo
# view` with no argument ignores the variable); worktree-create exports it to the slot commands. Empty or absent leaves
# gh's own resolution alone; a malformed value is a configuration error (exit 2).
. "$(dirname "$0")/../lib.sh"

t_wt_fixture ghrepo
mkdir -p "$FIX/fakebin"
GHLOG="$FIX/gh.log"
cat > "$FIX/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
# fake gh: records the GH_REPO it was given (or <unset>) and its arguments; answers a title, a repo, a user.
printf 'GH_REPO=%s ARGS=%s\n' "${GH_REPO-<unset>}" "$*" >> "$GHLOG"
case "$1 $2" in
  "issue view") echo "Fix login page" ;; "repo view") echo origin/fromremotes ;; "api user") echo me ;;
  *) exit 1 ;;
esac
FAKE
chmod 755 "$FIX/fakebin/gh"
export GHLOG PATH="$FIX/fakebin:$PATH"
I="$B/worktree-issue.sh"
issue() { rm -f "$GHLOG"; ISSUE=7 BRANCH=7-x run bash "$I" --config "$CFG" "$@"; }

t_wt_cfg set.env "GH_REPO=acme/app"
issue title; expect 0 '^Fix login page$' "title with GH_REPO set"
check "set: gh saw GH_REPO=acme/app" sh -c '! grep -v "^GH_REPO=acme/app " "$1"' _ "$GHLOG"
issue guard
# (the GraphQL query spans lines, so only the record lines, the ones starting GH_REPO=, are judged)
check "set: guard's gh calls all saw GH_REPO=acme/app" sh -c 'grep -q "^GH_REPO=" "$1" && ! grep "^GH_REPO=" "$1" | grep -v "^GH_REPO=acme/app "' _ "$GHLOG"
check "set: the repository name is GH_REPO, never asked of gh repo view" sh -c '! grep -q "ARGS=repo view" "$1"' _ "$GHLOG"
check "set: the GraphQL query names acme/app" sh -c 'grep -q "owner=acme" "$1" && grep -q "name=app" "$1"' _ "$GHLOG"

t_wt_cfg empty.env "GH_REPO="
issue title; expect 0 '^Fix login page$' "title with GH_REPO empty"
check "empty: gh saw no GH_REPO (its default resolution)" sh -c '! grep -v "^GH_REPO=<unset> " "$1"' _ "$GHLOG"
issue guard
check "empty: the repository name comes from gh repo view" grep -q "ARGS=repo view" "$GHLOG"
check "empty: guard's gh calls saw no GH_REPO" sh -c 'grep -q "^GH_REPO=" "$1" && ! grep "^GH_REPO=" "$1" | grep -v "^GH_REPO=<unset> "' _ "$GHLOG"

t_wt_cfg absent.env
issue title
check "absent: gh saw no GH_REPO" sh -c '! grep -v "^GH_REPO=<unset> " "$1"' _ "$GHLOG"

for bad in "acme" "github.com/acme/app" "-x/app" "acme/a b"; do
  t_wt_cfg bad.env "GH_REPO=$bad"
  issue title; expect_rc 2 "worktree-issue: GH_REPO '$bad' is refused"
  check "and gh is never asked" test ! -e "$GHLOG"
done

# worktree-create exports it to the slot commands (a custom tracker's command reads it too).
printf '#!/bin/sh\necho "${GH_REPO-<unset>}" > "%s/slot.rec"\necho Fix login page\n' "$FIX" > "$FIX/title.sh"
t_wt_cfg cset.env "GH_REPO=acme/app" "ISSUE_TITLE_CMD=sh $FIX/title.sh" "ISSUE_GUARD_CMD=" "ISSUE_CLAIM_CMD=" "PUSH_ON_ISSUE=0"
run bash "$B/worktree-create.sh" --config "$CFG" 7
expect 0 'WORKTREE-RESULT worktree-create PASS created' "create with GH_REPO set"
check "the title slot command saw GH_REPO=acme/app" test "$(cat "$FIX/slot.rec")" = acme/app
t_wt_cfg cbad.env "GH_REPO=acme" "ISSUE_TITLE_CMD=sh $FIX/title.sh"
run bash "$B/worktree-create.sh" --config "$CFG" 8
expect 2 'WORKTREE-RESULT worktree-create FAIL config-malformed' "worktree-create: a malformed GH_REPO is refused before anything exists"

t_done
