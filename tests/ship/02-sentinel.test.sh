#!/usr/bin/env bash
# ship-sentinel: fingerprint parity with an independent implementation of the documented algorithm, the sentinel
# readers (fresh, mismatch, stale, exempt, malformed), categorize, and manual attestation.
. "$(dirname "$0")/../lib.sh"

# An independent fingerprint: the algorithm as review-code's sentinel reference states it, written without ship-lib.
# $1 = base ref, $2 = optional ERE file (keep only matching records).
cat > "$T_TMP/fence.sh" <<'F'
set -o pipefail
BASE=$(git merge-base HEAD "$1") || exit 1
LIST=$(mktemp) && RECORDS=$(mktemp) || exit 1
{ git -c core.quotePath=false diff --name-status --no-renames "$BASE" &&
  git -c core.quotePath=false ls-files --others --exclude-standard | sed "s/^/A$(printf '\t')/"; } | LC_ALL=C sort -u > "$LIST" || exit 1
if [ -n "${2:-}" ]; then grep -E -f "$2" "$LIST" > "$LIST.f" || true; mv -f "$LIST.f" "$LIST"; fi
: > "$RECORDS"
while IFS="$(printf '\t')" read -r status path; do
  [ -n "$path" ] || exit 1
  if [ -f "$path" ]; then h=$( (sha256sum 2>/dev/null || shasum -a 256) < "$path" | cut -c1-64) || exit 1; else h=DELETED; fi
  printf '%s\t%s\t%s\n' "$status" "$path" "$h" >> "$RECORDS"
done < "$LIST"
(sha256sum 2>/dev/null || shasum -a 256) < "$RECORDS" | cut -c1-64
rm -f "$LIST" "$RECORDS"
F
fence() { bash "$T_TMP/fence.sh" origin/main "${1:-}"; }
fp() { bash "$B/ship-sentinel.sh" --contract=2 fingerprint "$@" | head -1; }

t_fixture sentinel "DEFAULT_MODE=offload" "CRITICAL_GLOBS_FILE=.claude/critical-paths.txt" \
  'DOCS_ALLOWLIST=(\.md$|\.txt$|^docs/|(^|/)CHANGELOG)' "REVIEW_TTL_SECONDS=43200" "E2E_TTL_SECONDS=43200"
t_branch feat/7-x
echo new > lib/new.ts; echo dd >> docs/x.md; git add -A; git commit -qm "Refs #7 more"
t_init ""
expect 0 'ship-init PASS' "init"

printf 'app/api/**\nlib/**\n' | bash -c ". '$B/ship-lib.sh'; ship_globs_to_ere" > "$T_TMP/crit.ere"
check "glob to ERE conversion produced a pattern" test -s "$T_TMP/crit.ere"

RAW="$(fp --raw)"; CRIT="$(fp --critical)"; TREE="$(fp)"
[ "$RAW" = "$(fence)" ] && t_pass "raw fingerprint equals the independent implementation" \
  || { OUT="ship=$RAW fence=$(fence)"; t_fail "raw fingerprint equals the independent implementation"; }
[ "$CRIT" = "$(fence "$T_TMP/crit.ere")" ] && t_pass "critical fingerprint equals the filtered independent implementation" \
  || { OUT="ship=$CRIT fence=$(fence "$T_TMP/crit.ere")"; t_fail "critical fingerprint parity"; }
echo more >> docs/x.md
[ "$(fp)" = "$TREE" ] && t_pass "tree fingerprint ignores a docs-allowlisted edit" || { OUT=""; t_fail "tree fingerprint ignores docs"; }
[ "$(fp --raw)" != "$RAW" ] && t_pass "raw fingerprint sees the docs edit" || { OUT=""; t_fail "raw fingerprint sees docs"; }
git checkout -q docs/x.md

run bash "$B/ship-sentinel.sh" --contract=2 categorize
expect 0 'SHIP-RESULT ship-sentinel PASS nonexempt n=[0-9]+' "categorize finds critical files"

# A review runs before the ship commits: staging and committing the reviewed bytes must not move any fingerprint.
echo untracked > lib/later.ts; echo also > app/api/later.ts
U_TREE="$(fp)"; U_RAW="$(fp --raw)"; U_CRIT="$(fp --critical)"
[ "$U_RAW" = "$(fence)" ] && [ "$U_CRIT" = "$(fence "$T_TMP/crit.ere")" ] \
  && t_pass "fingerprint parity holds with untracked files present" || { OUT="raw $U_RAW vs $(fence)"; t_fail "fingerprint parity holds with untracked files present"; }
run bash "$B/ship-sentinel.sh" --contract=2 categorize
expect_out '^NONEXEMPT lib/later.ts$' "an untracked critical file is non-exempt (not lost to a tab-less sed)"
expect_out '^NONEXEMPT app/api/later.ts$' "and so is a second one"
git add -A
[ "$(fp)" = "$U_TREE" ] && [ "$(fp --raw)" = "$U_RAW" ] && [ "$(fp --critical)" = "$U_CRIT" ] \
  && t_pass "staging an untracked file does not change any fingerprint" || { OUT="tree $U_TREE -> $(fp)"; t_fail "staging an untracked file does not change any fingerprint"; }
git commit -qm "Refs #7 later"
[ "$(fp)" = "$U_TREE" ] && [ "$(fp --raw)" = "$U_RAW" ] && [ "$(fp --critical)" = "$U_CRIT" ] \
  && t_pass "committing it does not change any fingerprint" || { OUT="tree $U_TREE -> $(fp)"; t_fail "committing it does not change any fingerprint"; }
echo changed >> lib/later.ts
[ "$(fp)" != "$U_TREE" ] && t_pass "a content change after the commit does" || { OUT=""; t_fail "a content change after the commit does"; }
git checkout -q lib/later.ts

run bash "$B/ship-sentinel.sh" --contract=2 verify review
expect 1 'FAIL review-invalid' "no review sentinel fails the gate"
expect_out '^REVIEW: ABSENT' "as ABSENT"

# Write both sentinels the way the review companion does, then read them back.
NOW=$(date +%s); HEAD_SHA=$(git rev-parse HEAD)
printf '%s\n%s\n%s\n' "$(fp)" "$NOW" "$HEAD_SHA" > "$ST/review-code-ran"
printf '%s\n%s\n' "$(fp --critical)" "$NOW" > "$ST/real-e2e-shipgate-passed"
run bash "$B/ship-sentinel.sh" --contract=2 verify gates
expect 0 'SHIP-RESULT ship-sentinel PASS' "fresh sentinels pass both gates"
expect_out 'FRESH' "and read FRESH"

echo x >> lib/new.ts
run bash "$B/ship-sentinel.sh" --contract=2 verify gates
expect 1 'FAIL' "editing a critical file invalidates the gates"
expect_out 'HASH-MISMATCH' "as HASH-MISMATCH"
git checkout -q lib/new.ts

printf 'EXEMPT: docs-only, nothing critical\n%s\n%s\n' "$NOW" "$(fp)" > "$ST/real-e2e-shipgate-passed"
run bash "$B/ship-sentinel.sh" --contract=2 verify e2e
expect 0 'PASS' "an EXEMPT e2e sentinel bound to the tree passes"
expect_out 'EXEMPT' "and reads EXEMPT"
echo y >> lib/u.ts
run bash "$B/ship-sentinel.sh" --contract=2 verify e2e
expect 1 'FAIL e2e-invalid' "an exemption does not survive a tree change"
expect_out '^E2E: STALE-EXEMPT' "as STALE-EXEMPT"
git checkout -q lib/u.ts

printf '%s\n%s\n%s\n' "$(fp)" "$((NOW - 50000))" "$HEAD_SHA" > "$ST/review-code-ran"
run bash "$B/ship-sentinel.sh" --contract=2 verify review
expect 1 'FAIL review-invalid' "a sentinel older than the TTL fails"
expect_out '^REVIEW: STALE age=' "as STALE"

printf '%s\n9999999999\n%s\n' "$(fp)" "$HEAD_SHA" > "$ST/review-code-ran"
run bash "$B/ship-sentinel.sh" --contract=2 verify review
expect 1 'FAIL review-invalid' "a future epoch fails"
expect_out '^REVIEW: MALFORMED' "as MALFORMED"

printf 'SENTINEL-ERROR: hash failed\n%s\n' "$NOW" > "$ST/review-code-ran"
run bash "$B/ship-sentinel.sh" --contract=2 verify review
expect 3 'FAIL reader-error' "a sentinel carrying an error line is a reader error, never valid"
rm -f "$ST/review-code-ran"

# Critical-glob configuration fails closed.
printf 'bad/{a,b}/**\n' >> .claude/critical-paths.txt
run bash "$B/ship-sentinel.sh" --contract=2 categorize
expect 3 'FAIL filter-(unbuildable|invalid)' "an unsupported glob is an error, never 'no match'"
expect_out 'glob spellings the converter cannot honour' "and names the offending line"
printf 'app/api/**\nlib/**\n' > .claude/critical-paths.txt
mv .claude/critical-paths.txt "$FIX/cp.bak"
run bash "$B/ship-sentinel.sh" --contract=2 categorize
expect 3 'FAIL filter-unbuildable' "a named globs file that is missing is an error, never 'no globs'"
mv "$FIX/cp.bak" .claude/critical-paths.txt

# CRLF line ends (Git for Windows checks text out that way by default): ship.env and the globs file read as with LF.
# The CRITICAL_GLOBS_FILE value is a path: with a CR left on it, the file would be "unreadable".
run bash "$B/ship-sentinel.sh" --contract=2 categorize; LF_OUT="$OUT"; LF_RC=$RC
cp .claude/skills/ship/ship.env "$FIX/env.bak"; cp .claude/critical-paths.txt "$FIX/cp.bak"
t_crlf "$FIX/env.bak" .claude/skills/ship/ship.env; t_crlf "$FIX/cp.bak" .claude/critical-paths.txt
run bash "$B/ship-status.sh" --contract=2 cfg CRITICAL_GLOBS_FILE
expect 0 '^\.claude/critical-paths\.txt$' "a CRLF ship.env: the globs-file path reads without a CR"
check "…and that path opens" test -r "$LAST"
run bash "$B/ship-sentinel.sh" --contract=2 categorize
expect "$LF_RC" 'SHIP-RESULT ship-sentinel PASS nonexempt n=[0-9]+' "a CRLF ship.env and a CRLF globs file categorize as with LF"
expect_out '^NONEXEMPT lib/new\.ts$' "…and a critical file is still non-exempt"
# (EXEMPT-COUNT differs: the two rewritten files are themselves changed, exempt paths.)
[ "$(printf '%s\n' "$OUT" | grep '^NONEXEMPT ')" = "$(printf '%s\n' "$LF_OUT" | grep '^NONEXEMPT ')" ] \
  && t_pass "…with the same NONEXEMPT list as the LF files" || t_fail "…with the same NONEXEMPT list as the LF files" "LF: $LF_OUT"
mv "$FIX/env.bak" .claude/skills/ship/ship.env; mv "$FIX/cp.bak" .claude/critical-paths.txt

sed -i.bak 's|^CRITICAL_GLOBS_FILE=.*|CRITICAL_GLOBS_FILE=|' .claude/skills/ship/ship.env
run bash "$B/ship-sentinel.sh" --contract=2 categorize
expect 10 'SKIP all-exempt' "an empty CRITICAL_GLOBS_FILE opts out: every diff exempt"
printf '%s\n%s\n' "$(fp --critical)" "$NOW" > "$ST/real-e2e-shipgate-passed"
run bash "$B/ship-sentinel.sh" --contract=2 verify e2e
expect 1 'FAIL e2e-invalid' "a hash-form e2e sentinel over an empty critical set fails"
expect_out '^E2E: MALFORMED' "as MALFORMED"
mv .claude/skills/ship/ship.env.bak .claude/skills/ship/ship.env

# Manual attestation.
run bash "$B/ship-sentinel.sh" --contract=2 attest review --note "x"
expect 2 'FAIL not-manual' "attest is refused while REVIEW_GATE is sentinel"
echo "REVIEW_GATE=manual" >> .claude/skills/ship/ship.env
run bash "$B/ship-sentinel.sh" --contract=2 verify gates
expect 1 'FAIL' "manual mode with no attestation fails"
expect_out 'MANUAL-ABSENT' "as MANUAL-ABSENT"
# The shipping agent never attests its own work: without the user's words the attestation is refused.
run bash "$B/ship-sentinel.sh" --contract=2 attest review --note "read the diff by hand against HEAD"
expect 2 'FAIL no-user-confirmation' "an attestation without the user's words is refused"
check "and nothing was written" test ! -e "$ST/manual-review"
run bash "$B/ship-sentinel.sh" --contract=2 attest review --note "x" --user "   "
expect 2 'FAIL no-user-confirmation' "blank user words are refused too"
printf '%s\n%s\n%s\n' "$(fp)" "$(date +%s)" "agent wrote this" > "$ST/manual-review"
run bash "$B/ship-sentinel.sh" --contract=2 verify review
expect 1 'FAIL review-invalid' "a hand-written 3-line attestation (no user line) is not valid"
expect_out '^REVIEW: MALFORMED' "as MALFORMED"
run bash "$B/ship-sentinel.sh" --contract=2 attest review --note "read the diff by hand against HEAD" --user "I reviewed it, ship it"
expect 0 'PASS' "attest review with the user's words"
run bash "$B/ship-sentinel.sh" --contract=2 attest e2e --note "ran three requests against a local server" --user "override-testing for a local-only change"
expect 0 'PASS' "attest e2e with the user's waiver"
run bash "$B/ship-sentinel.sh" --contract=2 verify gates
expect 0 'PASS' "attested gates pass"
expect_out 'MANUAL-ATTESTED.*user: "I reviewed it, ship it"' "and read MANUAL-ATTESTED quoting the user"
# The E2E attestation is bound to the critical-path content, as the sentinel it stands in for: a non-critical edit keeps it.
echo zz >> docs/notes.txt; echo zz > other.cfg
run bash "$B/ship-sentinel.sh" --contract=2 verify e2e
expect 0 'PASS' "an E2E attestation survives a change outside the critical paths"
rm -f other.cfg; git checkout -q docs 2>/dev/null; rm -f docs/notes.txt
echo zz >> lib/u.ts
run bash "$B/ship-sentinel.sh" --contract=2 verify review
expect 1 'FAIL review-invalid' "an attestation does not survive a tree change"
expect_out '^REVIEW: MANUAL-STALE' "as MANUAL-STALE"
run bash "$B/ship-sentinel.sh" --contract=2 verify e2e
expect 1 'FAIL e2e-invalid' "nor does the E2E one survive a critical-path change"
git checkout -q lib/u.ts

# Manual mode, a diff that touches no critical path: E2E-exempt with no attestation (the categorizer decides on each read).
rm -f "$ST/manual-e2e"
printf '# all off\n' > .claude/critical-paths.txt
run bash "$B/ship-sentinel.sh" --contract=2 verify e2e
expect 0 'PASS' "manual mode, no critical path changed: exempt without any attestation"
expect_out '^E2E: EXEMPT' "as EXEMPT"
mv .claude/critical-paths.txt "$FIX/cp.bak"
run bash "$B/ship-sentinel.sh" --contract=2 verify e2e
expect 3 'FAIL reader-error' "manual mode with an unreadable globs file is an error, never exempt"
mv "$FIX/cp.bak" .claude/critical-paths.txt
printf 'app/api/**\nlib/**\n' > .claude/critical-paths.txt

t_done
