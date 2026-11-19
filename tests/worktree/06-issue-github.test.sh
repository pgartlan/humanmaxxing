#!/usr/bin/env bash
# worktree-issue.sh: the GitHub title / guard / claim commands behind the default issue slots, against a fake `gh`
# that answers from files and applies the script's real jq program (issue-board.jq) to a recorded GraphQL answer.
. "$(dirname "$0")/../lib.sh"
command -v jq >/dev/null 2>&1 || { OUT=""; t_fail "jq is installed (the fake gh applies issue-board.jq with it)"; t_done; exit 1; }

t_wt_fixture gh1
GHD="$FIX/gh"; mkdir -p "$GHD" "$FIX/fakebin"
cat > "$FIX/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
# fake gh: logs each call, fails a call kind when $GHD/fail.<kind> exists, answers from $GHD files.
printf '%s\n' "$*" >> "$GHD/calls.log"
kind=other
case "$1 $2" in
  "repo view") kind=repo ;; "api user") kind=user ;; "issue view") kind=title ;;
  "issue edit") kind=edit ;; "issue comment") kind=comment ;;
  "api graphql") case "$*" in *updateProjectV2ItemFieldValue*) kind=move ;; *) kind=query ;; esac ;;
esac
[ -e "$GHD/fail.$kind" ] && { echo "HTTP 502: fake $kind failure" >&2; exit 1; }
[ -e "$GHD/warn" ] && echo "A new release of gh is available: 9.9.9" >&2
case "$kind" in
  repo) echo acme/app ;;
  user) echo "${FAKE_LOGIN:-me}" ;;
  title) cat "$GHD/title" ;;
  query) prog=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && prog="$a"; prev="$a"; done
         # real gh writes LF; a native Windows jq.exe writes CRLF, so its CRs are dropped to answer as gh would
         o="$(jq -r "$prog" "$GHD/answer.json")" || exit $?; [ -z "$o" ] || printf '%s\n' "$o" | tr -d '\r' ;;
  move) for a in "$@"; do case "$a" in o=*) echo "${a#o=}" > "$GHD/moved.opt" ;; esac; done; echo '{}' ;;
  comment) prev=""; for a in "$@"; do [ "$prev" = "--body" ] && printf '%s\n' "$a" > "$GHD/comment.body"; prev="$a"; done ;;
esac
FAKE
chmod 755 "$FIX/fakebin/gh"
export GHD PATH="$FIX/fakebin:$PATH"
I="$B/worktree-issue.sh"
echo "Fix login page" > "$GHD/title"

# answer <state> <assignee|-> <items...>; an item is owner/number:status (status may be empty, "-" = no field)
answer() {
  local state="$1" who="$2"; shift 2
  local nodes="" sep="" it owner num st fld vbn
  for it in "$@"; do
    owner="${it%%/*}"; num="${it#*/}"; num="${num%%:*}"; st="${it#*:}"
    if [ "$st" = "-" ]; then fld=null; vbn=null; else
      fld='{"id":"F'"$num"'","options":[{"id":"oReady","name":"Ready"},{"id":"oProg","name":"In progress"},{"id":"oBack","name":"Backlog"}]}'
      if [ -n "$st" ]; then vbn='{"name":"'"$st"'"}'; else vbn=null; fi
    fi
    nodes="$nodes$sep"'{"id":"I'"$num"'","fieldValueByName":'"$vbn"',"project":{"id":"P'"$num"'","number":'"$num"',"owner":{"login":"'"$owner"'"},"field":'"$fld"'}}'
    sep=","
  done
  local as='[]'; [ "$who" = "-" ] || as='[{"login":"'"$who"'"}]'
  printf '{"data":{"repository":{"issue":{"state":"%s","assignees":{"nodes":%s},"projectItems":{"nodes":[%s]}}}}}\n' "$state" "$as" "$nodes" > "$GHD/answer.json"
}
reset_gh() { rm -f "$GHD"/fail.* "$GHD/warn" "$GHD/calls.log" "$GHD/moved.opt" "$GHD/comment.body"; }
issue() { local v="$1"; shift; ISSUE="$v" BRANCH="7-fix-login-page" run bash "$I" --config "$CFG" "$@"; }

# --- title ----------------------------------------------------------------------------------------------------------------
t_wt_cfg nob.env
issue 7 title; expect 0 '^Fix login page$' "title prints the issue's title, one line"
touch "$GHD/fail.title"; issue 7 title; expect_rc 3 "an unreadable title is exit 3"; reset_gh
ISSUE=x run bash "$I" --config "$CFG" title; expect_rc 2 "ISSUE must be a number"
issue 7 frobnicate; expect_rc 2 "an unknown verb is a usage error"

# --- guard, no board ----------------------------------------------------------------------------------------------------
answer OPEN -; issue 7 guard; expect 0 'may be started' "no board: an open, unassigned issue may be started"
answer OPEN me; issue 7 guard; expect 0 'assigned to you' "no board: assigned to you may be started"
answer OPEN alice; issue 7 guard; expect 1 'assigned to alice' "no board: someone else's issue is refused"
answer CLOSED -; issue 7 guard; expect 1 'is CLOSED' "a closed issue is refused"
touch "$GHD/fail.query"; issue 7 guard; expect_rc 3 "an unreadable issue refuses (exit 3), never passes"; reset_gh
touch "$GHD/fail.repo"; issue 7 guard; expect_rc 3 "an unreadable repository refuses"; reset_gh

# --- guard, with a board --------------------------------------------------------------------------------------------------
t_wt_cfg board.env "ISSUE_PROJECT=acme/3"
answer OPEN - "acme/3:Ready"; issue 7 guard; expect 0 "'Ready' on acme/3: may be started" "on the board in Ready: may be started"
answer OPEN - "acme/3:Backlog"; issue 7 guard; expect_rc 0 "Backlog is startable by default"
answer OPEN alice "acme/3:In progress"; issue 7 guard; expect 1 "'In progress' on acme/3 \(assigned: alice\)" "in progress: refused, naming who has it"
answer OPEN - "acme/3:"; issue 7 guard; expect 1 "'no status'" "on the board with no status: refused"
answer OPEN - "other/9:Ready"; issue 7 guard; expect 1 'not on board acme/3' "only on another board: refused"
answer OPEN - "other/9:-" "acme/3:Ready"; issue 7 guard; expect_rc 0 "the right board is found among several, even after one with no status field"
t_wt_cfg board2.env "ISSUE_PROJECT=acme/3" "ISSUE_STARTABLE=Ready"
answer OPEN - "acme/3:Backlog"; issue 7 guard; expect_rc 1 "ISSUE_STARTABLE narrows the startable statuses"
t_wt_cfg bad.env "ISSUE_PROJECT=acme"; issue 7 guard; expect_rc 2 "ISSUE_PROJECT without a number is a configuration error"

# Without a board no board field is asked for (GitHub refuses those to a token without the project scope), and an answer
# that carries none is read as an ordinary open issue.
t_wt_cfg nob.env; reset_gh
printf '{"data":{"repository":{"issue":{"state":"OPEN","assignees":{"nodes":[]}}}}}\n' > "$GHD/answer.json"
issue 7 guard; expect 0 'may be started' "no board: an answer with no board fields is an open, unassigned issue"
check "no board: the query asks for no board field" bash -c '! grep -q "projectItems(first" "$1"' _ "$GHD/calls.log"
reset_gh; t_wt_cfg board.env "ISSUE_PROJECT=acme/3"; answer OPEN - "acme/3:Ready"; issue 7 guard
check "with a board: the query asks for the board fields" grep -q 'projectItems(first' "$GHD/calls.log"
# Owners are matched without regard to case (GitHub logins are case-insensitive); spaces around the commas of
# ISSUE_STARTABLE are not part of a status.
t_wt_cfg upper.env "ISSUE_PROJECT=Acme/3"; answer OPEN - "acme/3:Ready"; issue 7 guard
expect_rc 0 "ISSUE_PROJECT=Acme/3 matches the board owned by acme"
t_wt_cfg spaced.env "ISSUE_PROJECT=acme/3" "ISSUE_STARTABLE=Backlog, Ready"; answer OPEN - "acme/3:Ready"; issue 7 guard
expect_rc 0 "ISSUE_STARTABLE=Backlog, Ready still starts a Ready issue"
# A warning gh prints on stderr never becomes part of a value.
reset_gh; t_wt_cfg nob.env; touch "$GHD/warn"; issue 7 title; expect 0 '^Fix login page$' "a gh warning on stderr is not part of the title"
check "the title is the only line printed" test "$(printf '%s\n' "$OUT" | wc -l)" -eq 1
reset_gh
# A login with an underscore (managed-user accounts) is a login, not an unexpected answer.
t_wt_cfg nob.env; answer OPEN octo_acme; export FAKE_LOGIN=octo_acme; issue 7 guard; unset FAKE_LOGIN
expect 0 'assigned to you' "a login with an underscore is read, and an issue assigned to it may be started"
# A malformed configuration is refused, never read as defaults (which would drop the board and loosen the guard).
printf 'BASE_BRANCH=main\nISSUE_PROJECT= # acme/3\n' > "$FIX/malformed.env"
ISSUE=7 run bash "$I" --config "$FIX/malformed.env" guard
expect_rc 2 "a malformed configuration is a configuration error, not a guard without a board"

# --- claim ------------------------------------------------------------------------------------------------------------
t_wt_cfg board.env "ISSUE_PROJECT=acme/3"
answer OPEN - "acme/3:Ready"; reset_gh; issue 7 claim
expect_rc 0 "claim: assign, move and comment all succeed"
check "it assigned the issue to the caller" grep -q '^issue edit 7 --add-assignee @me' "$GHD/calls.log"
check "it moved the card to the in-progress option" test "$(cat "$GHD/moved.opt" 2>/dev/null)" = oProg
check "the comment names the branch" grep -qF '`7-fix-login-page`' "$GHD/comment.body"
check "the comment holds no local path" sh -c '! grep -q "/" "$1"' _ "$GHD/comment.body"
reset_gh; touch "$GHD/fail.edit"; issue 7 claim
expect 1 'commented on #7' "a failed assign is exit 1, and the later steps still run"
check "the card was still moved" test -f "$GHD/moved.opt"
reset_gh; t_wt_cfg doing.env "ISSUE_PROJECT=acme/3" "ISSUE_IN_PROGRESS=Doing"; issue 7 claim
expect_rc 1 "an in-progress status the board lacks is a failed claim"
expect_out "has no 'Status' option 'Doing': not moved" "and says what is missing"
reset_gh; t_wt_cfg board.env "ISSUE_PROJECT=acme/3"; answer OPEN - "other/9:Ready"; issue 7 claim
expect_out 'not on board acme/3: not moved' "an issue off the board is assigned and commented, not moved"
reset_gh; t_wt_cfg nob.env; answer OPEN -; issue 7 claim
expect_rc 0 "no board: assign and comment only"
check "no board: no move was attempted" sh -c '! grep -q updateProjectV2ItemFieldValue "$1"' _ "$GHD/calls.log"

# --- through worktree-create, with the example file's slot lines ---------------------------------------------------------
SLOTS=$(grep -E '^(ISSUE_TITLE_CMD|ISSUE_GUARD_CMD|ISSUE_CLAIM_CMD|PUSH_ON_ISSUE)=' "$T_ROOT/skills/worktree/worktree.env.example")
check "the example file turns on title, guard, claim and push" test "$(printf '%s\n' "$SLOTS" | grep -c .)" -eq 4
# shellcheck disable=SC2086
IFS='
'; t_wt_cfg flow.env $SLOTS "ISSUE_PROJECT=acme/3"; unset IFS
answer OPEN alice "acme/3:In progress"; reset_gh
run bash "$B/worktree-create.sh" --config "$CFG" 7
expect 1 'WORKTREE-RESULT worktree-create FAIL guard-refused issue=7' "the default guard refuses an issue already in progress"
check "nothing was created" test ! -e "$FIX/7-fix-login-page"
answer OPEN - "acme/3:Ready"; reset_gh
run bash "$B/worktree-create.sh" --config "$CFG" 7
CREATE_OUT="$OUT"
expect 0 'WORKTREE-RESULT worktree-create PASS created path=[^ ]*/7-fix-login-page' "a Ready issue is created from its title"
expect_out '^claimed issue 7$' "and claimed"
check "the branch was pushed" test -n "$(git ls-remote "$ORIGIN" refs/heads/7-fix-login-page)"
check "the claim moved the card" test "$(cat "$GHD/moved.opt" 2>/dev/null)" = oProg
check "the slot commands read the create's own config (the board), not the skill's default file" sh -c 'printf "%s\n" "$1" | grep -q "on acme/3: may be started"' _ "$CREATE_OUT"
t_done
