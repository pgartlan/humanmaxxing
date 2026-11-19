#!/usr/bin/env bash
# retro-data.sh: GH_REPO in retro.env is exported to every gh query; empty or absent leaves gh's own resolution alone;
# a malformed value is a configuration error (exit 2) before anything is read.
. "$(dirname "$0")/../lib.sh"

t_retro_fixture ghrepo "TRACKER=github" "GH_REPO=acme/app"
t_retro_commit 2 "fix: a thing" src/a.ts
t_retro_push
mkdir -p "$FIX/fakebin"
GHLOG="$FIX/gh.log"
cat > "$FIX/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
# fake gh: records the GH_REPO it was given (or <unset>) and its arguments; every list is empty.
printf 'GH_REPO=%s ARGS=%s\n' "${GH_REPO-<unset>}" "$*" >> "$GHLOG"
case "$*" in *"--jq length"*) echo 0 ;; *) echo '' ;; esac
FAKE
chmod 755 "$FIX/fakebin/gh"
export GHLOG PATH="$FIX/fakebin:$PATH"

rm -f "$GHLOG"; run bash "$R"
check "set: gh was queried" test -s "$GHLOG"
check "set: every gh query saw GH_REPO=acme/app" sh -c '! grep -v "^GH_REPO=acme/app " "$1"' _ "$GHLOG"

t_retro_cfg "TRACKER=github" "GH_REPO="
rm -f "$GHLOG"; run bash "$R"
check "empty: gh was queried" test -s "$GHLOG"
check "empty: gh saw no GH_REPO (its default resolution)" sh -c '! grep -v "^GH_REPO=<unset> " "$1"' _ "$GHLOG"

t_retro_cfg "TRACKER=github"
rm -f "$GHLOG"; run bash "$R"
check "absent: gh saw no GH_REPO" sh -c '! grep -v "^GH_REPO=<unset> " "$1"' _ "$GHLOG"

for bad in "acme" "github.com/acme/app" "-x/app" "acme/a b"; do
  t_retro_cfg "TRACKER=github" "GH_REPO=$bad"
  rm -f "$GHLOG"; run bash "$R"
  expect 2 'config-malformed' "GH_REPO '$bad' is refused"
  check "and gh is never asked" test ! -e "$GHLOG"
done

t_done
