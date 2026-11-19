#!/usr/bin/env bash
# worktree-issue.sh — the GitHub issue steps of the issue flow, through `gh`: title, guard and claim.
#
#   worktree-issue.sh [--config F] title     print the issue's title on one line (ISSUE_TITLE_CMD)
#   worktree-issue.sh [--config F] guard     exit 0 when the issue may be started (ISSUE_GUARD_CMD)
#   worktree-issue.sh [--config F] claim     assign it to you, move it to in-progress, comment the branch (ISSUE_CLAIM_CMD)
#
# It is meant to be the command in those three slots, so it reads what the slots receive: ISSUE (and BRANCH for
# claim) from the environment, and WT_CONFIG (exported by the worktree scripts) or --config for its settings:
#   ISSUE_PROJECT       the GitHub project (board) as <owner>/<number>, e.g. acme/3. Empty = no board.
#   ISSUE_STATUS_FIELD  the board's single-select status field (default: Status)
#   ISSUE_STARTABLE     comma-separated statuses an issue may be started from (default: Backlog,Ready)
#   ISSUE_IN_PROGRESS   the status a claimed issue moves to (default: In progress)
#
# guard, with a board: the issue must be open, on the board, and in a startable status. Without a board: open, and
#   unassigned or assigned to you. Anything that cannot be read refuses (exit 3): a guard that could not look is not
#   a pass. --force on the create skips the guard entirely.
# claim: every step runs even if an earlier one failed; exit 1 when any failed (the create reports claim-failed).
#   The comment names the branch, never a local path.
# Exit codes: 0 done / may start · 1 refused (guard) or a claim step failed · 2 usage or configuration · 3 cannot read.
# Needs `gh`, signed in. With a board (ISSUE_PROJECT set) the token also needs the `project` scope
# (`gh auth refresh -s project`); without one, no board field is asked for. No jq needed: gh applies issue-board.jq.
ENV_CONFIG="${WT_CONFIG:-}"   # set by the worktree scripts for their slot commands; the library resets WT_CONFIG
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-lib.sh"
# shellcheck source=skills/worktree/bin/worktree-lib.sh
. "$LIB" || { echo "worktree-lib missing or broken" >&2; exit 2; }
WT_SCRIPT="worktree-issue"
WT_CONFIG="$ENV_CONFIG"
JQ_FILE="$WT_BIN/issue-board.jq"

say() { echo "$*"; }
fail() { echo "worktree-issue: $2" >&2; exit "$1"; }

VERB=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) [ "$#" -ge 2 ] || fail 2 "--config needs a file"; WT_CONFIG="$2"; shift 2 ;;
    title|guard|claim) [ -z "$VERB" ] || fail 2 "one verb only"; VERB="$1"; shift ;;
    *) fail 2 "usage: worktree-issue.sh [--config F] title|guard|claim (got '$1')" ;;
  esac
done
[ -n "$VERB" ] || fail 2 "usage: worktree-issue.sh [--config F] title|guard|claim"
[ -n "$WT_CONFIG" ] || WT_CONFIG="$WT_SKILL_DIR/worktree.env"
[ -r "$WT_CONFIG" ] || fail 2 "no configuration at $WT_CONFIG"
wt_kv_get "$WT_CONFIG" BASE_BRANCH >/dev/null 2>&1
[ "$?" -ne 2 ] || fail 2 "$WT_CONFIG is malformed (only KEY=value lines and # comments on their own lines; a value may not begin with #)"
wt_export_gh_repo   # GH_REPO from the config, when set, is what every gh call below targets
wt_is_number "${ISSUE:-}" || fail 2 "ISSUE is not set to an issue number (got '${ISSUE:-}')"
command -v gh >/dev/null 2>&1 || fail 3 "gh is not installed"
# gh's stderr goes to a file read only on failure: a warning on stderr must never become part of a value.
ERRF=$(mktemp "${TMPDIR:-/tmp}/wt-issue.XXXXXX") || fail 3 "cannot create a temporary file"
trap 'rm -f "$ERRF"' EXIT
gherr() { tr '\n' ' ' < "$ERRF"; }

if [ "$VERB" = title ]; then
  T=$(gh issue view "$ISSUE" --json title -q .title 2>"$ERRF") || fail 3 "could not read issue #$ISSUE: $(gherr)"
  printf '%s\n' "$T"; exit 0
fi

PROJECT=$(wt_cfg ISSUE_PROJECT "")
FIELD=$(wt_cfg ISSUE_STATUS_FIELD "Status")
STARTABLE=$(wt_cfg ISSUE_STARTABLE "Backlog,Ready" | sed 's/[[:space:]]*,[[:space:]]*/,/g; s/^[[:space:]]*//; s/[[:space:]]*$//')
INPROG=$(wt_cfg ISSUE_IN_PROGRESS "In progress")
P_OWNER=""; P_NUM=""
if [ -n "$PROJECT" ]; then
  P_OWNER="${PROJECT%/*}"; P_NUM="${PROJECT##*/}"
  case "$P_OWNER" in ''|*[!A-Za-z0-9-]*) fail 2 "ISSUE_PROJECT must be <owner>/<number> (got '$PROJECT')" ;; esac
  wt_is_number "$P_NUM" || fail 2 "ISSUE_PROJECT must be <owner>/<number> (got '$PROJECT')"
fi

# `gh repo view` with no argument ignores GH_REPO and reads the remotes, so a set GH_REPO is the name itself.
if [ -n "${GH_REPO:-}" ]; then NWO="$GH_REPO"
else NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>"$ERRF") || fail 3 "could not read this repository on GitHub: $(gherr)"; fi
case "$NWO" in */*) ;; *) fail 3 "unexpected repository name from gh: '$NWO'" ;; esac
ME=$(gh api user -q .login 2>"$ERRF") || fail 3 "could not read the signed-in GitHub user: $(gherr)"
case "$ME" in ''|*[!A-Za-z0-9_-]*) fail 3 "unexpected GitHub login from gh: '$ME'" ;; esac

# Board fields are asked for only when a board is configured: GitHub refuses them to a token without the project scope.
BOARD=''
[ -z "$PROJECT" ] || BOARD=' projectItems(first:20){nodes{id fieldValueByName(name:$field){... on ProjectV2ItemFieldSingleSelectValue{name}} project{id number owner{... on Organization{login} ... on User{login}} field(name:$field){... on ProjectV2SingleSelectField{id options{id name}}}}}}'
FARG=',$field:String!'; [ -n "$PROJECT" ] || FARG=''
QUERY='query($owner:String!,$name:String!,$num:Int!'"$FARG"'){repository(owner:$owner,name:$name){issue(number:$num){state assignees(first:20){nodes{login}}'"$BOARD"'}}}'
set -- -f query="$QUERY" -f owner="${NWO%%/*}" -f name="${NWO#*/}" -F num="$ISSUE"
[ -z "$PROJECT" ] || set -- "$@" -f field="$FIELD"
ROWS=$(gh api graphql "$@" --jq "$(cat "$JQ_FILE")" 2>"$ERRF") || fail 3 "could not read issue #$ISSUE and its board status: $(gherr)"

STATE=""; ASSIGNEES=""; ITEM=""; PROJ_ID=""; FIELD_ID=""; STATUS=""; OPT_ID=""; ONBOARD=0
US=$(printf '\037')
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }   # GitHub logins are case-insensitive
P_OWNER_LC=$(lc "$P_OWNER")
while IFS="$US" read -r kind a b c d e f; do
  case "$kind" in
    STATE) STATE="$a"; ASSIGNEES="$b" ;;
    ITEM) if [ -n "$PROJECT" ] && [ "$(lc "$a")" = "$P_OWNER_LC" ] && [ "$b" = "$P_NUM" ]; then ONBOARD=1; ITEM="$c"; PROJ_ID="$d"; FIELD_ID="$e"; STATUS="$f"; fi ;;
    OPT) if [ -n "$PROJECT" ] && [ "$(lc "$a")" = "$P_OWNER_LC" ] && [ "$b" = "$P_NUM" ] && [ "$c" = "$INPROG" ]; then OPT_ID="$d"; fi ;;
  esac
done <<EOF
$ROWS
EOF
[ -n "$STATE" ] || fail 3 "issue #$ISSUE: the answer had no state line"

if [ "$VERB" = guard ]; then
  [ "$STATE" = OPEN ] || { say "issue #$ISSUE is $STATE: only an open issue can be started"; exit 1; }
  if [ -n "$PROJECT" ]; then
    [ "$ONBOARD" -eq 1 ] || { say "issue #$ISSUE is not on board $PROJECT: put it on the board in a startable status first"; exit 1; }
    case ",$STARTABLE," in
      *",$STATUS,"*) say "issue #$ISSUE is '$STATUS' on $PROJECT: may be started"; exit 0 ;;
    esac
    say "issue #$ISSUE is '${STATUS:-no status}' on $PROJECT${ASSIGNEES:+ (assigned: $ASSIGNEES)}: only $STARTABLE may be started"
    exit 1
  fi
  case ",$ASSIGNEES," in
    ,,|",$ME,") say "issue #$ISSUE is open${ASSIGNEES:+ and assigned to you}: may be started"; exit 0 ;;
  esac
  say "issue #$ISSUE is assigned to $ASSIGNEES: someone else has it"
  exit 1
fi

# claim
BAD=0
if OUT=$(gh issue edit "$ISSUE" --add-assignee @me 2>&1); then say "assigned #$ISSUE to $ME"
else say "could not assign #$ISSUE: $OUT"; BAD=1; fi
if [ -n "$PROJECT" ]; then
  if [ "$ONBOARD" -ne 1 ]; then say "#$ISSUE is not on board $PROJECT: not moved"; BAD=1
  elif [ -z "$FIELD_ID" ] || [ -z "$OPT_ID" ]; then say "board $PROJECT has no '$FIELD' option '$INPROG': not moved"; BAD=1
  else
    M='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}'
    if OUT=$(gh api graphql -f query="$M" -f p="$PROJ_ID" -f i="$ITEM" -f f="$FIELD_ID" -f o="$OPT_ID" 2>&1); then say "moved #$ISSUE to '$INPROG' on $PROJECT"
    else say "could not move #$ISSUE on $PROJECT: $OUT"; BAD=1; fi
  fi
fi
BODY="Work started on branch \`${BRANCH:-unknown}\`."
if OUT=$(gh issue comment "$ISSUE" --body "$BODY" 2>&1); then say "commented on #$ISSUE"
else say "could not comment on #$ISSUE: $OUT"; BAD=1; fi
exit "$BAD"
