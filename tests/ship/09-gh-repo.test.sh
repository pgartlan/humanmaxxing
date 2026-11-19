#!/usr/bin/env bash
# GH_REPO in ship.env: exported to every gh call the scripts make (gh honors the variable); empty or absent leaves gh's
# own resolution alone; a malformed value is a configuration error before any gate. Also the per-branch PR-body file
# a fresh start clears.
. "$(dirname "$0")/../lib.sh"

t_fixture ghrepo "GH_REPO=acme/app"
t_branch feat/7-x
mkdir -p "$FIX/fakebin"
GHLOG="$FIX/gh.log"
cat > "$FIX/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
# fake gh: records the GH_REPO it was given (or <unset>) and its arguments; answers nothing (no PR).
printf 'GH_REPO=%s ARGS=%s\n' "${GH_REPO-<unset>}" "$*" >> "$GHLOG"
exit 1
FAKE
chmod 755 "$FIX/fakebin/gh"
export GHLOG PATH="$FIX/fakebin:$PATH"
cfg() { { echo "BASE_BRANCH=main"; for l in "$@"; do echo "$l"; done; } > .claude/skills/ship/ship.env; rm -f "$GHLOG"; }

t_init ""
expect 0 'SHIP-RESULT ship-init PASS' "init with GH_REPO set"

cfg "GH_REPO=acme/app"
run bash "$B/ship-status.sh" --contract=2
expect 0 'SHIP-RESULT ship-status PASS' "status runs with GH_REPO set"
check "gh was called by status" test -s "$GHLOG"
check "set: every gh call saw GH_REPO=acme/app" sh -c '! grep -v "^GH_REPO=acme/app " "$1"' _ "$GHLOG"

cfg "GH_REPO="
run bash "$B/ship-status.sh" --contract=2
expect 0 'SHIP-RESULT ship-status PASS' "status runs with GH_REPO empty"
check "empty: gh was called" test -s "$GHLOG"
check "empty: gh saw no GH_REPO (its default resolution)" sh -c '! grep -v "^GH_REPO=<unset> " "$1"' _ "$GHLOG"

cfg
run bash "$B/ship-status.sh" --contract=2
check "absent: gh saw no GH_REPO" sh -c '! grep -v "^GH_REPO=<unset> " "$1"' _ "$GHLOG"

cfg "GH_REPO="
GH_REPO=other/inherited run bash "$B/ship-status.sh" --contract=2
check "empty: an inherited GH_REPO is left as it is" sh -c '! grep -v "^GH_REPO=other/inherited " "$1"' _ "$GHLOG"

for bad in "acme" "github.com/acme/app" "acme/app/x" "-x/app" "acme/a b" "/app" "acme/"; do
  cfg "GH_REPO=$bad"
  run bash "$B/ship-status.sh" --contract=2
  expect 2 'SHIP-RESULT ship-status FAIL ship-env-malformed' "GH_REPO '$bad' is refused"
done

# cfg GH_REPO is how SKILL.md's prose gh commands read it.
cfg "GH_REPO=acme/app"
run bash "$B/ship-status.sh" --contract=2 cfg GH_REPO
expect 0 '^acme/app$' "cfg GH_REPO prints the value for the prose gh commands"

# The census fetches job logs by the repository's slug: GH_REPO wins over `gh repo view` (which reads the remotes).
mkdir -p "$FIX/fakecensus"
cat > "$FIX/fakecensus/gh" <<'FAKE'
#!/usr/bin/env bash
# fake gh for the census: one failed run with one failed job; repo view answers the remotes' (wrong) slug.
printf 'GH_REPO=%s ARGS=%s\n' "${GH_REPO-<unset>}" "$*" >> "$GHLOG"
case "$1 $2" in
  "run list") echo '[{"databaseId":11,"name":"ci","status":"completed","conclusion":"failure","event":"pull_request"}]' ;;
  "run view") echo '{"jobs":[{"databaseId":22,"name":"tests","conclusion":"failure"}]}' ;;
  "repo view") echo wrong/remote ;;
  api\ *) printf 'Error: boom\n' ;;
  *) exit 1 ;;
esac
FAKE
chmod 755 "$FIX/fakecensus/gh"
cfg "GH_REPO=acme/app"
PATH="$FIX/fakecensus:$PATH" run bash "$B/ship-census.sh" --contract=2 --sha "$(git rev-parse HEAD)"
expect 0 'SHIP-RESULT ship-census PASS built' "census with GH_REPO set builds"
check "census: the job log is fetched from the GH_REPO repository" grep -q 'ARGS=api repos/acme/app/actions/jobs/22/logs' "$GHLOG"
check "census: gh repo view (the remotes' slug) is never asked" sh -c '! grep -q "ARGS=repo view" "$1"' _ "$GHLOG"
cfg
PATH="$FIX/fakecensus:$PATH" run bash "$B/ship-census.sh" --contract=2 --sha "$(git rev-parse HEAD)"
expect 0 'SHIP-RESULT ship-census PASS built' "census with GH_REPO absent builds"
check "census, GH_REPO absent: the slug comes from gh repo view" grep -q 'ARGS=api repos/wrong/remote/actions/jobs/22/logs' "$GHLOG"

# The PR body lives in this worktree's ship-state, one file per branch; a fresh start clears it.
echo body > "$ST/pr-body-feat-7-x.md"
t_init "--fresh"
expect 0 'SHIP-RESULT ship-init PASS' "a fresh init"
check "a fresh start removes the previous ship's PR body" test ! -e "$ST/pr-body-feat-7-x.md"

t_done
