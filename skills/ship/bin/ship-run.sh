#!/usr/bin/env bash
# ship-run.sh — the exit-file runner for every long check the skill fires in the background.
#
#   ship-run.sh --contract=N start <name>                     (a CHECK_TASKS name: runs its configured CHECK_CMD_<name>)
#   ship-run.sh --contract=N required                         the CHECK_TASKS names for this mode, one per line (empty = unset)
#   ship-run.sh --contract=N start <name> -- <command> [args...]
#       An empty command (or `bash -c ''`) is exit 2 `empty-command`: it would exit 0 and record green. A configured name
#       given a typed command is exit 2 `configured-task`.
#       Purges the stale exit file FIRST (an old green would satisfy a later collect instantly), runs the command
#       with stdout+stderr to $SHIP_STATE/tasks/<name>.log, then writes $SHIP_STATE/tasks/<name>.exit LAST and
#       atomically (rc=, epoch=, head=). Prints `TASK <name> PASS|FAIL rc=<n> log=<path>` and the log's last 20
#       lines on FAIL. Exit 0 PASS · 1 FAIL · 10 already-running (a copy of this task is live: wait for it).
#       Run it as a `run_in_background: true` Bash call with an explicit timeout; a task killed by the harness
#       bound leaves NO exit file, which collect reports as WAIT, never as green.
#       Every started name is appended to $SHIP_STATE/tasks.list (the launch-time record `write phase1` requires).
#       The exit file also records fp= (the check binding, ship_fp_phase1, when the task ended: a fixer task vouches for the
#       tree it leaves behind) and mb_start= / mb= (the merge-base with the base branch at launch and at the end). `write
#       phase1` refuses a task whose fp is not the current binding or whose base moved while it ran, so a check that ran
#       before a later edit, or partly on an older base, never vouches for the current tree.
#   ship-run.sh --contract=N collect [<name>[,<name>...]] [--same-tree]
#       No names = every task in tasks.list. --same-tree also fails (exit 1, `stale-tree tasks=`) tasks whose fp is not the
#       current check binding, or whose mb_start and mb differ (the base moved while the task ran); on success it prints
#       `collect: binding <value>`, the binding every task was checked against. Exit 0 every task recorded rc=0 · 1 at least one recorded non-zero (named) · 4 WAIT: a named task has
#       no exit file yet (named; still running, never started, or killed) · 3 an exit file is unreadable.
#   ship-run.sh --contract=N reset <name>[,<name>...]     remove their exit files (before a re-run).
# EXIT-CODES: 0 1 2 3 4 10
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ship-lib.sh"; source "$LIB" || { echo "ship-lib missing/broken" >&2; exit 2; }
ship_lib_init ship-run
ship_require_mode

VERB="${1:-}"; [ -n "$VERB" ] && shift
T="${SHIP_STATE:?}/tasks"
name_ok() { case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac; }

case "$VERB" in
  start)
    NAME="${1:-}"; name_ok "$NAME" || ship_die 2 usage "start needs a task name ([A-Za-z0-9_.-])"
    shift
    CFGCMD=$(ship_cfg "CHECK_CMD_$NAME" "" 2>/dev/null) || CFGCMD=""
    case "$NAME" in *[!A-Za-z0-9_]*) CFGCMD="" ;; esac
    if [ "$#" -eq 0 ]; then
      # A configured check runs its configured command: the command is bound to the name, never retyped.
      [ -n "$CFGCMD" ] || ship_die 2 usage "start <name> -- <command...> (or configure CHECK_CMD_$NAME in ship.env)"
      set -- bash -c "$CFGCMD"
    else
      [ "${1:-}" = "--" ] || ship_die 2 usage "start <name> -- <command...>"; shift
      [ "$#" -ge 1 ] || ship_die 2 usage "no command given after --"
      [ -z "$CFGCMD" ] || ship_die 2 configured-task "'$NAME' is configured (CHECK_CMD_$NAME): run 'start $NAME' with no command, so the configured one runs"
    fi
    # An empty command exits 0 and would record a green that checked nothing: refuse it (a blank slot is never a task).
    if [ -z "$(printf '%s' "$*" | tr -d '[:space:]')" ]; then ship_die 2 empty-command "the command for '$NAME' is empty"; fi
    case "$1" in bash|sh|*/bash|*/sh)
      if [ "${2:-}" = -c ] && [ -z "$(printf '%s' "${3:-}" | tr -d '[:space:]')" ]; then ship_die 2 empty-command "'$1 -c' with an empty script for '$NAME': an unconfigured slot is not launched, it is listed as not configured"; fi ;;
    esac
    PID="$T/$NAME.pid"
    if [ -f "$PID" ] && kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null; then
      echo "TASK $NAME already-running pid=$(cat "$PID")"; ship_result ship-run SKIP already-running "task=$NAME"; exit 10
    fi
    rm -f "${T:?}/${NAME:?}.exit" "${T:?}/${NAME:?}.exit.tmp"
    grep -qx "$NAME" "$SHIP_STATE/tasks.list" 2>/dev/null || echo "$NAME" >> "$SHIP_STATE/tasks.list"
    echo $$ > "$PID"
    HEAD=$(git rev-parse HEAD 2>/dev/null || echo unknown)
    MBS=$(ship_merge_base 2>/dev/null) || MBS=unknown
    { echo "=== $NAME $(date -u +%Y-%m-%dT%H:%M:%SZ) head=$HEAD"; echo "+ $*"; } > "$T/$NAME.log"
    "$@" >> "$T/$NAME.log" 2>&1; RC=$?
    [ "$(cat "$PID" 2>/dev/null)" = "$$" ] || { echo "TASK $NAME SUPERSEDED (a fresh init or a newer start took over; this result is discarded)"; ship_result ship-run FAIL superseded "task=$NAME"; exit 1; }
    FPT=$(ship_fp_phase1 2>/dev/null) || FPT=unknown   # the tree the task's result describes (recorded at END, after any fixer wrote)
    MBE=$(ship_merge_base 2>/dev/null) || MBE=unknown
    if ! { printf 'rc=%s\nepoch=%s\nhead=%s\nfp=%s\nmb_start=%s\nmb=%s\n' "$RC" "$(date +%s)" "$HEAD" "$FPT" "$MBS" "$MBE" > "$T/$NAME.exit.tmp" && mv -f "$T/$NAME.exit.tmp" "$T/$NAME.exit"; }; then
      rm -f "${PID:?}"; echo "TASK $NAME UNRECORDED rc=$RC (the exit file could not be written)"; ship_result ship-run FAIL exit-write-failed "task=$NAME"; exit 3
    fi
    rm -f "${PID:?}"
    ship_fixloop_log task "name=$NAME" "rc=$RC"
    if [ "$RC" -eq 0 ]; then echo "TASK $NAME PASS rc=0 log=$T/$NAME.log"; ship_result ship-run PASS "task=$NAME"; exit 0; fi
    echo "TASK $NAME FAIL rc=$RC log=$T/$NAME.log"; echo "--- last 20 log lines ---"; tail -n 20 "$T/$NAME.log"
    ship_result ship-run FAIL task-red "task=$NAME" "rc=$RC"; exit 1 ;;
  collect)
    SAME=0; LIST=""
    for a in "$@"; do case "$a" in --same-tree) SAME=1 ;; *) LIST="$a" ;; esac; done
    if [ -z "$LIST" ]; then LIST=$(paste -sd, - < "$SHIP_STATE/tasks.list" 2>/dev/null); [ -n "$LIST" ] || ship_die 2 usage "collect: no task recorded in tasks.list and no names given"; fi
    RED=""; WAIT=""; BAD=""; STALE=""; CUR=$(git rev-parse HEAD 2>/dev/null); FPNOW=""
    [ "$SAME" -eq 0 ] || FPNOW=$(ship_fp_phase1) || ship_die 3 fingerprint-error "$FPNOW"
    for n in $(printf '%s' "$LIST" | tr ',' ' '); do
      name_ok "$n" || ship_die 2 usage "bad task name '$n'"
      f="$T/$n.exit"
      if [ ! -f "$f" ]; then WAIT="$WAIT $n"; echo "collect: $n WAIT (no exit file: running, never started, or killed by the bound)"; continue; fi
      rc=$(ship_kv_get "$f" rc) || { BAD="$BAD $n"; echo "collect: $n UNREADABLE ($f)"; continue; }
      case "$rc" in ''|*[!0-9]*) BAD="$BAD $n"; echo "collect: $n UNREADABLE rc='$rc'"; continue ;; esac
      h=$(ship_kv_get "$f" head 2>/dev/null) || h=""
      if [ "$rc" -eq 0 ]; then
        note=""; [ -n "$h" ] && [ "$h" != "$CUR" ] && note=" (note: ran on an older HEAD)"
        tf=$(ship_kv_get "$f" fp 2>/dev/null) || tf=""
        ms=$(ship_kv_get "$f" mb_start 2>/dev/null) || ms=""; me=$(ship_kv_get "$f" mb 2>/dev/null) || me=""
        if [ "$SAME" -eq 1 ]; then
          if [ -n "$tf" ] && [ "$tf" != unknown ] && [ "${#tf}" -ne "${#FPNOW}" ]; then STALE="$STALE $n"; echo "collect: $n STALE-TREE (binding format changed: written by an older ship; re-run it)"; continue; fi
          if [ -z "$ms" ] || [ "$ms" = unknown ] || [ "$ms" != "$me" ]; then STALE="$STALE $n"; echo "collect: $n STALE-TREE (the base moved while it ran, or its base was not recorded; re-run it)"; continue; fi
          if [ "$tf" != "$FPNOW" ]; then
            if [ -z "$tf" ] || [ "$tf" = unknown ]; then STALE="$STALE $n"; echo "collect: $n STALE-TREE (its tree was not recorded; re-run it)"; continue; fi
            STALE="$STALE $n"; echo "collect: $n STALE-TREE (ran on another tree: an edit or a base sync since; re-run it)"; continue
          fi
        fi
        echo "collect: $n PASS$note"
      else RED="$RED $n"; echo "collect: $n FAIL rc=$rc log=$T/$n.log"; fi
    done
    [ -z "$BAD" ] || { ship_result ship-run FAIL unreadable "tasks=$(echo $BAD | tr ' ' ',')"; exit 3; }
    [ -z "$RED" ] || { ship_result ship-run FAIL red "tasks=$(echo $RED | tr ' ' ',')"; exit 1; }
    [ -z "$STALE" ] || { ship_result ship-run FAIL stale-tree "tasks=$(echo $STALE | tr ' ' ',')"; exit 1; }
    [ -z "$WAIT" ] || { ship_result ship-run WAIT pending "tasks=$(echo $WAIT | tr ' ' ',')"; exit 4; }
    [ "$SAME" -eq 0 ] || echo "collect: binding $FPNOW"   # the exact value every task was checked against (write phase1 stamps it)
    ship_result ship-run PASS all-green; exit 0 ;;
  required)
    ship_required_tasks "$SHIP_MODE"
    ship_result ship-run PASS required; exit 0 ;;
  reset)
    LIST="${1:-}"; [ -n "$LIST" ] || ship_die 2 usage "reset <name>[,<name>...]"
    for n in $(printf '%s' "$LIST" | tr ',' ' '); do name_ok "$n" || ship_die 2 usage "bad task name '$n'"; rm -f "${T:?}/${n:?}.exit" "${T:?}/${n:?}.exit.tmp"; done
    ship_result ship-run PASS reset; exit 0 ;;
  *) ship_die 2 usage "usage: ship-run.sh start <name> -- <cmd...> | collect <names> | reset <names>" ;;
esac
