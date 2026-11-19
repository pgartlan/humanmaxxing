#!/usr/bin/env bash
# tools/hm-lock.sh: the install record. record writes one line per item, status compares a newer download.
. "$(dirname "$0")/../lib.sh"
L="$T_ROOT/tools/hm-lock.sh"

check "the repository has a valid VERSION" sh -c "grep -Eqx '[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?' '$T_ROOT/VERSION'"
check "the changelog names the current version or an Unreleased section" sh -c "grep -Eq '^## (Unreleased|\\[?$(cat "$T_ROOT/VERSION")\\]?)' '$T_ROOT/CHANGELOG.md'"

# A fake download (two skills, a template) and a project.
DL="$T_TMP/dl"; mkdir -p "$DL/skills/a/bin" "$DL/skills/b" "$DL/templates"
echo "1.0.0" > "$DL/VERSION"
echo "skill a" > "$DL/skills/a/SKILL.md"; echo "echo a" > "$DL/skills/a/bin/a.sh"
echo "skill b" > "$DL/skills/b/SKILL.md"; echo "template" > "$DL/templates/T.md"
mkdir -p "$T_TMP/proj/sub" && cd "$T_TMP/proj" && git init -q -b main . || exit 2
cd sub || exit 2

run bash "$L" status --from "$DL"; expect_rc 3 "no lock yet is an error, never 'current'"
expect_out 'no install record' "and says why"

run bash "$L" record --from "$DL" skills/a templates/T.md; expect 0 'RECORDED templates/T.md 1.0.0' "record two items from a subfolder"
check "the lock is at the top level" test -f "$T_TMP/proj/.claude/humanmaxxing.lock"
LOCK="$T_TMP/proj/.claude/humanmaxxing.lock"
check "one line per item" sh -c "[ \"\$(grep -c '^item ' '$LOCK')\" -eq 2 ]"

run bash "$L" status --from "$DL"; expect_rc 0 "same download: everything current"
expect_out '^ITEM skills/a current recorded=1.0.0 source=1.0.0$' "the skill is current"
expect_out '^NEW skills/b$' "an unrecorded skill in the download is listed as new"

# A newer download: one file inside skill a changes.
echo "2.0.0" > "$DL/VERSION"; echo "echo a2" > "$DL/skills/a/bin/a.sh"
run bash "$L" status --from "$DL"; expect_rc 1 "a changed file makes the item behind"
expect_out '^ITEM skills/a behind recorded=1.0.0 source=2.0.0$' "named, with both versions"
expect_out '^ITEM templates/T.md current recorded=1.0.0 source=2.0.0$' "an unchanged item stays current across a version bump"

# A rename inside the folder is a change too (paths are part of the hash).
run bash "$L" record --from "$DL" skills/a; expect_rc 0 "re-record after the merge"
check "re-recording replaces the line, never duplicates it" sh -c "[ \"\$(grep -c '^item skills/a ' '$LOCK')\" -eq 1 ]"
mv "$DL/skills/a/bin/a.sh" "$DL/skills/a/bin/renamed.sh"
run bash "$L" status --from "$DL"; expect_out '^ITEM skills/a behind' "a renamed file is a change"
mv "$DL/skills/a/bin/renamed.sh" "$DL/skills/a/bin/a.sh"

rm -rf "$DL/templates"
run bash "$L" status --from "$DL"; expect_rc 1 "an item the download dropped"
expect_out '^ITEM templates/T.md gone' "is reported as gone"
mkdir -p "$DL/templates"; echo "template" > "$DL/templates/T.md"

# Input checks.
run bash "$L" record --from "$DL" ../escape; expect_rc 2 "a path with .. is refused"
run bash "$L" record --from "$DL" skills/nope; expect_rc 3 "a missing product path is an error"
for bad in skills/a/ skills//a skills/./a 'skills\a' .; do
  run bash "$L" record --from "$DL" "$bad"; expect_rc 2 "a path written another way ($bad) is refused, so one item never has two rows"
done
cp "$LOCK" "$T_TMP/lock.before"
run bash "$L" record --from "$DL" skills/b skills/nope; expect_rc 3 "a record that fails part-way is an error"
refute_out '^RECORDED' "and claims no record: the lock was not written"
check "the lock is unchanged after a failed record" cmp -s "$LOCK" "$T_TMP/lock.before"
printf 'item skills/a %s 1.0.0' "$(bash "$L" hash "$DL/skills/a")" > "$T_TMP/nonl.lock"
cp "$LOCK" "$T_TMP/lock.keep"; cp "$T_TMP/nonl.lock" "$LOCK"
run bash "$L" status --from "$DL"; expect_out '^ITEM skills/a current' "a last lock line with no newline is still read"
cp "$T_TMP/lock.keep" "$LOCK"
# The lock is committed in the user's repository: Git for Windows (core.autocrlf=true) checks it out with CRLF.
run bash "$L" status --from "$DL"; LF_OUT="$OUT"; LF_RC=$RC
t_crlf "$T_TMP/lock.keep" "$LOCK"
run bash "$L" status --from "$DL"; expect_rc "$LF_RC" "a CRLF lock: the same status as the LF one"
check "…and the same report, no recorded version ending in a CR" test "$OUT" = "$LF_OUT"
run bash "$L" record --from "$DL" skills/a; expect_rc 0 "record into a CRLF lock"
check "…replaces the item's line, never adds a second one" test "$(grep -c ' skills/a ' "$LOCK")" = 1
cp "$T_TMP/lock.keep" "$LOCK"
printf 'item skills/a x 1.0.0\rjunk\n' > "$LOCK"
run bash "$L" status --from "$DL"; expect_rc 3 "a CR inside a lock line (not its end) is an error"
cp "$T_TMP/lock.keep" "$LOCK"
echo "not a version" > "$DL/VERSION"
run bash "$L" status --from "$DL"; expect_rc 3 "a download without a valid VERSION is an error"
printf '2.0.0\r\n' > "$DL/VERSION"
run bash "$L" status --from "$DL"; expect_out '^SOURCE version=2.0.0$' "a CRLF VERSION is read"
echo "garbage line" >> "$LOCK"
run bash "$L" status --from "$DL"; expect_rc 3 "a malformed lock is an error, never 'current'"

# The hash is stable and content-based.
H1="$(bash "$L" hash "$DL/skills/a")"; H2="$(bash "$L" hash "$DL/skills/a")"
check "the folder hash is stable" test "$H1" = "$H2"
check "the folder hash is hex" sh -c "printf '%s' '$H1' | grep -Eqx '[0-9a-f]{40}|[0-9a-f]{64}'"
if ! t_can_unreadable; then t_skip "an unreadable subfolder: chmod cannot take read access away here (root, or Windows)"
else
  mkdir -p "$DL/skills/a/locked"; echo x > "$DL/skills/a/locked/f"; chmod 000 "$DL/skills/a/locked"
  run bash "$L" hash "$DL/skills/a"; expect_rc 3 "an unreadable subfolder is an error, never a hash of part of the folder"
  chmod 755 "$DL/skills/a/locked"; rm -rf "$DL/skills/a/locked"
fi
cd "$T_TMP" || exit 2
run bash "$L" record --from "$DL" skills/a; expect_rc 3 "record outside a git repository is an error"
t_done
