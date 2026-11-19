#!/usr/bin/env bash
# retro-data.sh framework currency: against a local download (through the download's own hm-lock.sh status) and
# against the release tags of a release repository (a local bare repository standing in for it; no network). It never
# records, never fetches, and an unreadable source is UNAVAILABLE, never "current".
. "$(dirname "$0")/../lib.sh"

t_retro_fixture cur
LOCKF="$FIX/work/.claude/humanmaxxing.lock"

# A download: VERSION, the real hm-lock.sh, two skills.
DL="$FIX/dl"; mkdir -p "$DL/tools" "$DL/skills/a" "$DL/skills/b"
cp "$T_ROOT/tools/hm-lock.sh" "$DL/tools/hm-lock.sh"
echo "0.2.0" > "$DL/VERSION"; echo "skill a" > "$DL/skills/a/SKILL.md"; echo "skill b" > "$DL/skills/b/SKILL.md"

# --- with a download ------------------------------------------------------------------------------------------------
run bash "$R" --download "$DL"
expect 3 'PARTIAL unavailable=currency$' "a download but no install record: unavailable"
expect_out '^UNAVAILABLE currency reason=hm-lock-failed .*no install record' "with hm-lock's own reason"
refute_out '^CURRENCY ' "and no currency line"

bash "$DL/tools/hm-lock.sh" record --from "$DL" skills/a >/dev/null || exit 2
git add -A && git commit -qm "record the install" && t_retro_push
LOCK_BEFORE="$(cat "$LOCKF")"
run bash "$R" --download "$DL"
expect 0 'PASS complete' "same release: complete"
expect_out '^CURRENCY source=download installed=0\.2\.0 available=0\.2\.0 behind=0 gone=0 current=1 new=1$' "current, with the download's new skill counted apart"
expect_out '^CURRENCY-ITEM current recorded=0\.2\.0 skills/a$' "the recorded item is current"
expect_out '^CURRENCY-ITEM new recorded=none skills/b$' "the unrecorded skill is new, not behind"

echo "0.3.0" > "$DL/VERSION"; echo "skill a, changed" > "$DL/skills/a/SKILL.md"
run bash "$R" --download "$DL"
expect 0 'PASS complete' "a newer download is read, not a failure"
expect_out '^CURRENCY source=download installed=0\.2\.0 available=0\.3\.0 behind=1 gone=0 current=0 new=1$' "one item behind"
expect_out '^CURRENCY-ITEM behind recorded=0\.2\.0 skills/a$' "named"
check "the lock is untouched (status, never record)" test "$(cat "$LOCKF")" = "$LOCK_BEFORE"
check "the working tree is clean after the run" test -z "$(git status --porcelain)"

rm -f "$FIX/dl2" 2>/dev/null; mkdir -p "$FIX/dl2"; echo "0.3.0" > "$FIX/dl2/VERSION"
run bash "$R" --download "$FIX/dl2"
expect_out '^UNAVAILABLE currency reason=download-without-hm-lock ' "a folder that is not a download is unavailable"
echo "not a version" > "$DL/VERSION"
run bash "$R" --download "$DL"
expect_out '^UNAVAILABLE currency reason=hm-lock-failed ' "a download with a broken VERSION is unavailable"
echo "0.3.0" > "$DL/VERSION"

# --- from the release repository's tags -------------------------------------------------------------------------------
REL="$FIX/release.git"; git init -q --bare -b main "$REL"
( cd "$FIX" && git clone -q "$REL" relwork 2>/dev/null && cd relwork && echo r > r && git add -A && git commit -qm r \
  && git tag v0.9.0 && git tag -a -m "ten" v0.10.0 && git tag v0.11.0-rc.1 && git tag v1.0 && git tag latest \
  && git push -q origin main --tags ) || exit 2
H="$(bash "$T_ROOT/tools/hm-lock.sh" hash "$DL/skills/a")"
printf '# HumanMaxxing install record\nitem skills/a %s 0.9.0\nitem skills/b %s 0.10.0\n' "$H" "$H" > "$LOCKF"
git add -A && git commit -qm "lock at mixed releases" && t_retro_push
t_retro_cfg "RELEASE_REPO_URL=$REL"
LOCK_BEFORE="$(cat "$LOCKF")"
run bash "$R"
expect 0 'PASS complete' "release tags read: complete"
expect_out '^CURRENCY source=tag tag=v0\.10\.0 installed=0\.9\.0,0\.10\.0 available=0\.10\.0 older=1 items=2$' "the newest release is v0.10.0: numeric, not v0.9.0; pre-releases and odd tags ignored"
expect_out '^CURRENCY-ITEM older recorded=0\.9\.0 skills/a$' "the item at the older release"
expect_out '^CURRENCY-ITEM current recorded=0\.10\.0 skills/b$' "the item at the newest release"
LOCK_KEEP="$(cat "$LOCKF")"
printf 'item skills/a %s 0.10.0-rc.1\n' "$H" > "$LOCKF"; run bash "$R"
expect_out '^CURRENCY-ITEM older recorded=0\.10\.0-rc\.1 skills/a$' "a pre-release install is older than its release"
printf 'item skills/a %s abc\n' "$H" > "$LOCKF"; run bash "$R"
expect_out '^UNAVAILABLE currency reason=lock-malformed ' "a recorded version that is not x.y.z is a malformed lock"
printf 'item skills/a %s 0.10.0\rx\n' "$H" > "$LOCKF"; run bash "$R"
expect_out '^UNAVAILABLE currency reason=lock-malformed ' "a CR inside a lock line (not its end) is a malformed lock"
# The lock is committed in the user's repository: Git for Windows (core.autocrlf=true) checks it out with CRLF.
printf '%s\n' "$LOCK_KEEP" > "$FIX/lock.lf"; t_crlf "$FIX/lock.lf" "$LOCKF"; run bash "$R"
expect_out '^CURRENCY source=tag tag=v0\.10\.0 installed=0\.9\.0,0\.10\.0 available=0\.10\.0 older=1 items=2$' "a CRLF lock reads as the LF one"
expect_out '^CURRENCY-ITEM current recorded=0\.10\.0 skills/b$' "…its last field without a carriage return"
printf '%s\n' "$LOCK_KEEP" > "$LOCKF"
( cd "$FIX/relwork" && git tag v0.10.2 && git push -q origin --tags ) || exit 2
run bash "$R"; expect_out '^CURRENCY source=tag tag=v0\.10\.2 .*available=0\.10\.2 older=2 items=2$' "a patch release makes both items older"
( cd "$FIX/relwork" && git tag 2.0.0 && git push -q origin --tags ) || exit 2
run bash "$R"; expect_out '^CURRENCY source=tag tag=2\.0\.0 ' "a tag without the v is a release too"
check "the lock is untouched by a tag run" test "$(cat "$LOCKF")" = "$LOCK_BEFORE"
check "and nothing but the rewritten configuration differs from the last commit" test "$(git status --porcelain)" = " M .claude/skills/retro/retro.env"
run bash "$R" --download "$DL"
expect 3 'PARTIAL unavailable=currency$' "a download older than the install (0.3.0 against items at 0.9.0 and 0.10.0): partial"
expect_out '^UNAVAILABLE currency reason=download-older-than-install the download is 0\.3\.0, an item is recorded at 0\.(9|10)\.0' "download-older-than-install, never 'behind'"
refute_out '^CURRENCY-ITEM behind' "no item is offered as behind from an older download"
echo "0.11.0" > "$DL/VERSION"; run bash "$R" --download "$DL"
expect_out '^CURRENCY source=download installed=0\.9\.0,0\.10\.0 available=0\.11\.0 ' "a download given on the command line wins over the release URL"
echo "0.3.0" > "$DL/VERSION"

# --- unavailable and not configured -----------------------------------------------------------------------------------
t_retro_cfg "RELEASE_REPO_URL=$FIX/no-such-repo.git"; run bash "$R"
expect 3 'PARTIAL unavailable=currency$' "an unreachable release repository: partial"
expect_out '^UNAVAILABLE currency reason=ls-remote-failed' "ls-remote-failed"
refute_out '^CURRENCY ' "no currency line"
EMPTY="$FIX/empty.git"; git init -q --bare -b main "$EMPTY"
( cd "$FIX/relwork" && git push -q "$EMPTY" main && git push -q "$EMPTY" v0.11.0-rc.1 ) || exit 2
t_retro_cfg "RELEASE_REPO_URL=$EMPTY"; run bash "$R"
expect_out '^UNAVAILABLE currency reason=no-release-tags$' "only a pre-release tag: no release to compare with"
t_retro_cfg "RELEASE_REPO_URL=$REL"
mv "$LOCKF" "$FIX/lock.keep"; run bash "$R"
expect 3 'PARTIAL unavailable=currency$' "no install record: partial"
expect_out '^UNAVAILABLE currency reason=no-install-record ' "no-install-record"
printf 'item skills/a\n' > "$LOCKF"; run bash "$R"
expect_out '^UNAVAILABLE currency reason=lock-malformed ' "a malformed lock is unavailable, never current"
printf '# only a comment\n' > "$LOCKF"; run bash "$R"
expect_out '^UNAVAILABLE currency reason=lock-malformed ' "a lock with no item is unavailable"
mv "$FIX/lock.keep" "$LOCKF"
t_retro_cfg "RELEASE_REPO_URL="; run bash "$R"
expect 0 'PASS complete' "no release source: a choice, complete"
expect_out '^NOT-CONFIGURED currency reason=release-source-not-configured$' "release source not configured"
t_retro_cfg "RELEASE_REPO_URL=--upload-pack=touch $FIX/pwned"; run bash "$R"
expect 2 'FAIL config-malformed' "a release URL that reads as an option is refused"
check "and nothing ran" test ! -e "$FIX/pwned"
t_done
