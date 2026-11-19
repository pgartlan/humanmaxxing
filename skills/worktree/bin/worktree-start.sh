#!/usr/bin/env bash
# worktree-start.sh — from issue number(s) to a session in the right worktree, in one command.
#
#   worktree-start.sh [--config F] [--force] [--parent DIR] <word>...
#
# Words are issue numbers (comma lists allowed) and at most one model name from START_MODELS, in any position.
# Reuses the worktree recorded for exactly that issue set, or creates it with worktree-create.sh, then changes into
# it and replaces this process with START_CMD (MODEL, ISSUES, BRANCH and WORKTREE_PATH exported). Run it from inside
# the repository, in a terminal the session can take over. After the `launching` result line the exit code is
# START_CMD's own.
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-lib.sh"
# shellcheck source=skills/worktree/bin/worktree-lib.sh
. "$LIB" || { echo "worktree-lib missing or broken" >&2; exit 2; }
WT_SCRIPT="worktree-start"

FORCE=0; WORDS=""
usage() { wt_die 2 usage "usage: worktree-start.sh [--config F] [--force] [--parent DIR] [<model>] <issue>...${1:+ ($1)}"; }
while [ "$#" -gt 0 ]; do
  a="$1"; shift
  case "$a" in
    --config) [ "$#" -gt 0 ] || usage "--config needs a file"; WT_CONFIG="$1"; shift ;;
    --parent) [ "$#" -gt 0 ] || usage "--parent needs a directory"; export WORKTREE_PARENT_DIR="$1"; shift ;;
    --force) FORCE=1 ;;
    -*) usage "unknown option $a" ;;
    *[!A-Za-z0-9,._-]*|'') usage "expected an issue number or a model name, got '$a'" ;;
    ,*|*,|*,,*) usage "not an issue list: $a" ;;
    *) WORDS="${WORDS:+$WORDS }$(printf '%s' "$a" | tr ',' ' ')" ;;
  esac
done

wt_load_config
[ -z "$WT_CONFIG" ] || WT_CONFIG="$(cd "$(dirname "$WT_CONFIG")" && pwd -P)/$(basename "$WT_CONFIG")"
wt_repo_init

START_CMD=$(wt_cfg START_CMD "")
[ -n "$START_CMD" ] || wt_die 2 config-start-cmd "START_CMD is not set in $WT_CONFIG"
MODELS=$(wt_cfg START_MODELS "")
MODEL=""; ISSUES=""
for w in $WORDS; do
  case "$w" in
    *[!0-9]*)
      lw=$(printf '%s' "$w" | LC_ALL=C tr '[:upper:]' '[:lower:]')
      case " $MODELS " in *" $lw "*) ;; *) usage "expected an issue number or one of: ${MODELS:-(START_MODELS is empty)}; got '$w'" ;; esac
      if [ -n "$MODEL" ] && [ "$MODEL" != "$lw" ]; then usage "two different models: $MODEL and $lw"; fi
      MODEL="$lw" ;;
    0*) usage "not an issue number: $w" ;;
    *) case " $ISSUES " in *" $w "*) usage "issue $w given twice" ;; esac
       ISSUES="${ISSUES:+$ISSUES }$w" ;;
  esac
done
[ -n "$ISSUES" ] || usage "no issue number given"
# The first issue as typed names a new branch; the set itself has no order, so lookups use it sorted.
TYPED="$ISSUES"
ISSUES=$(printf '%s\n' $ISSUES | sort -n | tr '\n' ' '); ISSUES="${ISSUES% }"
[ -n "$MODEL" ] || MODEL=$(wt_cfg START_DEFAULT_MODEL "")
JOINED=$(printf '%s' "$ISSUES" | tr ' ' '-')
WAIT_MAX=$(wt_cfg START_WAIT_SECONDS 120)
wt_is_number "$WAIT_MAX" || wt_die 2 config-malformed "START_WAIT_SECONDS must be a number (got '$WAIT_MAX')"

# find_dir — sets DIR and DIR_BRANCH to the worktree for exactly this issue set. A recorded marker always decides: every
# worktree is checked for one first. Only when none matches does a worktree with no marker (a create that died before
# writing it) match, on a branch named <numbers> or <numbers>-<slug> whose slug does not start with another number.
# The base branch's working copy is never a candidate: work does not start there. Return 3: a marker cannot be read.
find_dir() {
  local rows path branch sha rec rest fb="" fb_branch=""
  DIR=""; DIR_BRANCH=""
  rows=$(wt_worktrees)
  while IFS="$WT_TAB" read -r path branch sha; do
    [ -n "$path" ] && [ -d "$path" ] || continue
    [ "$branch" != "$WT_BASE" ] || continue
    rec=$(wt_issues_of "$path") || return 3
    if [ -n "$rec" ]; then
      if [ "$rec" = "$JOINED" ]; then DIR="$path"; DIR_BRANCH="$branch"; return 0; fi
      continue
    fi
    [ -z "$fb" ] || continue
    case "$branch" in
      "$JOINED") fb="$path"; fb_branch="$branch" ;;
      "$JOINED"-*) rest="${branch#"$JOINED"-}"; rest="${rest%%-*}"
                   case "$rest" in ''|*[!0-9]*) fb="$path"; fb_branch="$branch" ;; esac ;;
    esac
  done <<EOF_ROWS
$rows
EOF_ROWS
  [ -n "$fb" ] || return 1
  DIR="$fb"; DIR_BRANCH="$fb_branch"; return 0
}

find_dir; rc=$?
[ "$rc" -ne 3 ] || wt_die 3 marker-unreadable "a worktree's issue marker exists but cannot be read; fix its permissions and retry"
if [ "$rc" -eq 0 ]; then
  echo "Found existing worktree: $DIR"
else
  echo "No worktree for issue set $JOINED yet: creating it."
  CLOG=$(mktemp "${TMPDIR:-/tmp}/worktree-start.XXXXXX") || wt_die 2 usage "cannot create a temporary file"
  if [ "$FORCE" -eq 1 ]; then
    # shellcheck disable=SC2086
    bash "$WT_BIN/worktree-create.sh" --config "$WT_CONFIG" --force --background $TYPED >"$CLOG" 2>&1; crc=$?
  else
    # shellcheck disable=SC2086
    bash "$WT_BIN/worktree-create.sh" --config "$WT_CONFIG" --background $TYPED >"$CLOG" 2>&1; crc=$?
  fi
  cat "$CLOG"
  CREASON=$(tail -1 "$CLOG" | awk '$1 == "WORKTREE-RESULT" { print $4 }')
  rm -f "$CLOG"
  if [ "$crc" -ne 0 ] && [ "$crc" -ne 6 ]; then
    # Another session may have created the same worktree between the lookup and the create. Look once more.
    sleep 2
    find_dir; rc=$?
    # Only these two can be another session part-way through the same create; every other refusal is final.
    case "$CREASON" in path-exists|create-in-progress) IN_THE_WAY=1 ;; *) IN_THE_WAY=0 ;; esac
    if [ "$rc" -ne 0 ] && [ "$IN_THE_WAY" -eq 1 ]; then
      # A folder or a create in progress stood in the way: another session may be part-way through the same create.
      # Wait for it to become this issue set's checkout, up to the bound.
      WAITED=2
      while [ "$rc" -ne 0 ] && [ "$WAITED" -lt "$WAIT_MAX" ]; do sleep 1; WAITED=$((WAITED + 1)); find_dir; rc=$?; done
      [ "$rc" -eq 0 ] || wt_die 3 not-a-checkout "something is in the way of the worktree for issue set $JOINED and it did not become a valid checkout within ${WAIT_MAX}s (see the create output above); inspect or remove it and retry"
    fi
    if [ "$rc" -ne 0 ]; then
      # Carry the create's own reason and code, so a caller routing on this script's last line sees why.
      echo "STOP: the worktree could not be created (see the create output above)."
      wt_result FAIL "${CREASON:-create-failed}" "issues=$JOINED" "create-exit=$crc"; exit "$crc"
    fi
    echo "Found the worktree another session created: $DIR"
  else
    find_dir || wt_die 3 not-a-checkout "the create finished but no worktree for issue set $JOINED can be found"
    [ "$crc" -eq 0 ] || echo "warning: the worktree was created but a later step failed (see above); starting anyway"
  fi
fi

# Never start a session in a half-written checkout.
WAITED=0
until git -C "$DIR" rev-parse --verify -q HEAD >/dev/null 2>&1; do
  [ "$WAITED" -lt "$WAIT_MAX" ] || wt_die 3 not-a-checkout "$DIR exists but did not become a valid checkout within ${WAIT_MAX}s; inspect or remove it and retry"
  sleep 1; WAITED=$((WAITED + 1))
done

cd "$DIR" || wt_die 3 not-a-checkout "cannot enter $DIR"
export MODEL ISSUES BRANCH="$DIR_BRANCH" WORKTREE_PATH="$DIR"
wt_result PASS launching "path=$DIR" "branch=$DIR_BRANCH" "model=${MODEL:-none}" "issues=$JOINED"
exec bash -c "$START_CMD"
