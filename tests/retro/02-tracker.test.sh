#!/usr/bin/env bash
# retro-data.sh with TRACKER=github, against a fake `gh` that answers from files (no network) and applies the script's
# own --jq program with jq. A failed, missing or truncated read is UNAVAILABLE with no number, never a zero; and the
# run only ever reads.
. "$(dirname "$0")/../lib.sh"
command -v jq >/dev/null 2>&1 || { OUT=""; t_fail "jq is installed (the fake gh applies the script's --jq with it)"; t_done; exit 1; }

t_retro_fixture gh "TRACKER=github"
t_retro_commit 2 "fix: a thing" src/a.ts
t_retro_push
GHD="$FIX/gh"; mkdir -p "$GHD" "$FIX/fakebin"
cat > "$FIX/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
# fake gh: logs each call, fails a call kind when $GHD/fail.<kind> exists, answers $GHD/<kind>.json through --jq.
printf '%s\n' "$*" >> "$GHD/calls.log"
kind=other
case "$1 $2 $*" in
  "issue list "*"--state all"*) kind=opened ;;
  "issue list "*"--state closed"*) kind=closed ;;
  "pr list "*"--state merged"*) kind=prs ;;
esac
[ "$kind" = other ] && { echo "fake gh: unexpected call: $*" >&2; exit 64; }
[ -e "$GHD/fail.$kind" ] && { echo "HTTP 502: fake $kind failure" >&2; exit 1; }
[ -e "$GHD/raw.$kind" ] && { cat "$GHD/raw.$kind"; exit 0; }
prog=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && prog="$a"; prev="$a"; done
# Real gh writes LF; a native Windows jq.exe writes CRLF, so its CRs are dropped to answer as gh would.
set -o pipefail
jq -r "$prog" "$GHD/$kind.json" | tr -d '\r'
FAKE
chmod 755 "$FIX/fakebin/gh"
export GHD PATH="$FIX/fakebin:$PATH"
items() { local n="$1" i=1 s=""; while [ "$i" -le "$n" ]; do s="$s${s:+,}{\"number\":$i}"; i=$((i + 1)); done; echo "[$s]"; }
items 5 > "$GHD/opened.json"; items 2 > "$GHD/closed.json"
printf '%s\n' '[{"number":12,"title":"fix(auth): refresh the token"},{"number":13,"title":"feat: export"},{"number":14,"title":"Fix\tthe tab"}]' > "$GHD/prs.json"
reset_gh() { rm -f "$GHD"/fail.* "$GHD"/raw.* "$GHD/calls.log"; }

# --- everything answers -----------------------------------------------------------------------------------------------
reset_gh
# Racy-git: an index written in the same second as the files makes the next `git status` rewrite it. Settle it first.
sleep 1; git update-index -q --refresh >/dev/null 2>&1
# The snapshot is content only, never a time: status, refs, the index's entries, and every path in the git folder with
# each file's checksum (an mtime or `ls -l` listing changes when a minute ticks over). GIT_OPTIONAL_LOCKS=0 keeps the
# snapshot's own `git status` from refreshing (rewriting) the index.
snap() {
  GIT_OPTIONAL_LOCKS=0 git status --porcelain; git for-each-ref; git ls-files -s
  ( cd "$(git rev-parse --git-dir)" && find . -type d | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort )
}
SNAP_BEFORE="$(snap)"
run bash "$R"
SNAP_AFTER="$(snap)"
expect 0 '^RETRO-RESULT retro-data PASS complete$' "tracker answers: complete"
expect_out '^ISSUES opened=5 closed=2 net=\+3$' "issues opened and closed, with the backlog's direction"
expect_out '^PRS merged=3 fix=1$' "merged pull requests, and how many are fixes"
expect_out '^PR 12 fix fix\(auth\): refresh the token$' "each PR with its type and title last"
expect_out '^PR 13 feat feat: export$' "a feature PR"
check "the run changed nothing: status, refs, index and every file in the git folder are as they were" test "$SNAP_BEFORE" = "$SNAP_AFTER"
check "gh was only asked to list (read-only)" sh -c '! grep -vE "^(issue|pr) list " "$1"' _ "$GHD/calls.log"
check "gh was asked three questions" test "$(wc -l < "$GHD/calls.log" | tr -d ' ')" -eq 3
SINCE="$(printf '%s\n' "$OUT" | sed -n 's/^WINDOW days=7 since=\([^ ]*\) .*/\1/p')"
check "the issue query is bounded by the window's start" grep -qF -- "created:>=$SINCE" "$GHD/calls.log"
check "the closed query is bounded by the window's start" grep -qF -- "closed:>=$SINCE" "$GHD/calls.log"
check "the PR query is bounded by the window's start" grep -qF -- "merged:>=$SINCE" "$GHD/calls.log"
items 1 > "$GHD/opened.json"; items 4 > "$GHD/closed.json"; reset_gh
run bash "$R"; expect_out '^ISSUES opened=1 closed=4 net=-3$' "a shrinking backlog is a negative net"
items 0 > "$GHD/opened.json"; items 0 > "$GHD/closed.json"; echo '[]' > "$GHD/prs.json"; reset_gh
run bash "$R"
expect 0 'PASS complete' "a tracker that answers zero is a real zero"
expect_out '^ISSUES opened=0 closed=0 net=\+0$' "and is printed as one"
expect_out '^PRS merged=0 fix=0$' "no PR merged in the window"
items 5 > "$GHD/opened.json"; items 2 > "$GHD/closed.json"
printf '%s\n' '[{"number":12,"title":"fix: a"}]' > "$GHD/prs.json"

# --- a read that fails is never a zero --------------------------------------------------------------------------------
reset_gh; touch "$GHD/fail.closed"; run bash "$R"
expect 3 '^RETRO-RESULT retro-data PARTIAL unavailable=issues$' "a failed closed-issue query: partial, naming the section"
expect_out '^UNAVAILABLE issues reason=gh-failed HTTP 502: fake closed failure$' "with gh's own error"
refute_out '^ISSUES ' "and no issue numbers at all, not even the half that was read"
expect_out '^PRS merged=1 fix=1$' "the PR section is still read"
reset_gh; touch "$GHD/fail.prs"; run bash "$R"
expect 3 'PARTIAL unavailable=prs$' "a failed PR query: partial"
expect_out '^UNAVAILABLE prs reason=gh-failed ' "named"
refute_out '^PRS ' "with no PR count"
reset_gh; touch "$GHD/fail.opened" "$GHD/fail.prs"; run bash "$R"
expect 3 'PARTIAL unavailable=issues,prs$' "both failing: both named"
reset_gh; items 1000 > "$GHD/opened.json"; run bash "$R"
expect 3 'PARTIAL unavailable=issues$' "a list cut off at its limit is not a count"
expect_out '^UNAVAILABLE issues reason=truncated-at-1000' "and says it was cut off"
refute_out 'opened=' "no opened count is printed"
items 5 > "$GHD/opened.json"
reset_gh; echo 'Welcome to gh!' > "$GHD/raw.closed"; run bash "$R"
expect_out '^UNAVAILABLE issues reason=gh-unexpected-output' "an answer that is not a count is unavailable"
refute_out '^ISSUES ' "and prints no issue numbers"
reset_gh; printf 'abc\tfix: a\n' > "$GHD/raw.prs"; run bash "$R"
expect_out '^UNAVAILABLE prs reason=gh-unexpected-output' "a PR line without a number is unavailable"
refute_out '^PRS ' "and prints no PR count"
reset_gh

# --- no gh on this machine --------------------------------------------------------------------------------------------
# A PATH with no gh at all (the fake one and any real one; a gh installed beside git is replaced by links to the rest).
NOGH="$(t_path_without gh)"
reset_gh; OUT="$(PATH="$NOGH" bash "$R" 2>&1)"; RC=$?; LAST="$(printf '%s\n' "$OUT" | tail -1)"
expect 3 'PARTIAL unavailable=issues,prs$' "gh missing: partial"
expect_out '^UNAVAILABLE issues reason=gh-missing$' "issues: gh-missing"
expect_out '^UNAVAILABLE prs reason=gh-missing$' "PRs: gh-missing"
refute_out 'opened=|merged=' "and no number for either"
check "the fake gh was never reached" test ! -e "$GHD/calls.log"

# --- no tracker -------------------------------------------------------------------------------------------------------
t_retro_cfg "TRACKER=none"; reset_gh; run bash "$R"
expect 0 'PASS complete' "TRACKER=none is a choice: complete"
expect_out '^NOT-CONFIGURED issues reason=tracker-none$' "issues not configured"
expect_out '^NOT-CONFIGURED prs reason=tracker-none$' "PRs not configured"
check "gh is not called at all" test ! -e "$GHD/calls.log"
t_done
