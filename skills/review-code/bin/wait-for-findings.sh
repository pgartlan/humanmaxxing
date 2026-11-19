#!/usr/bin/env bash
# wait-for-findings.sh — wait until every expected reviewer has written its completion marker; with --check, look once.
# Read by review-code (Step 5 watcher, Step 14 sentinel hold) and review-plan (its watcher and its approval hold).
#
# WHY: a reviewer's "done" message is a hint, not proof, and an idle lead is not reliably woken by a message. A findings
# file existing is not "done" either: reviewers write early. The guaranteed wake is a background process that exits;
# the guaranteed hold is this same rule run once before a sentinel is written. It is the ONLY place the hold is
# enforced: the ship skill's reader checks the sentinel's fingerprint, not the markers, so a sentinel written by hand,
# or with a shortened list, bypasses it.
#
#   wait-for-findings.sh --dir <findings-dir> --run-id <id> --expect <entry,entry,...> [--timeout <secs>] [--poll <secs>] [--check]
#   wait-for-findings.sh --run-env <run.env> --dir <findings-dir> [--timeout <secs>] [--poll <secs>] [--check]
#
#   --run-env   read RUN_ID= and EXPECT= from this file (the copy the lead wrote at spawn); never retype the list
#   --expect    comma-separated entries: <name> (peer and isolated modes) or <name>:R1 / <name>:R2 (mediated mode)
#   --timeout   MINIMUM seconds to wait (default 2700); the wait is TIMEOUT..TIMEOUT+1 s, never shorter
#   --poll      seconds between looks (default 15; WAIT_FOR_FINDINGS_POLL overrides the default)
#   --check     look exactly once, never sleep
#
# An entry is satisfied when <dir>/<name>.md exists and its LAST NON-EMPTY line (trailing whitespace and CR ignored)
# is exactly `<!-- REVIEW-COMPLETE <name> <run-id> -->`, or `<!-- REVIEW-COMPLETE <name> <run-id> R<k> -->` for an
# entry <name>:R<k>. An :R1 entry is also satisfied by <dir>/round1/<name>.md (mediated mode copies round 1 there
# before round 2 rewrites the file). Nothing looser counts: not "the file exists", not "the marker is somewhere in it",
# not a marker carrying another run's id.
#
# EXIT-CODES:
#   0    every expected marker present                 (last line: READY: n/n)
#   1    --check only: a marker is missing; did not wait (last line: MISSING: a,b)
#   124  timeout with markers still missing            (last line: MISSING: a,b)
#   2    usage error (bad flag, bad name, bad run id, bad number, unreadable or incomplete --run-env)
#   3    --dir does not exist, or vanished mid-wait — fail loud, never "no files yet"
# Portability: bash 3.2 (macOS) — a SECONDS-bounded loop and sleep; no GNU timeout, no associative arrays.
set -u

DIR=""; RUN_ID=""; EXPECT=""; RUN_ENV=""; TIMEOUT=2700; POLL="${WAIT_FOR_FINDINGS_POLL:-15}"; CHECK=0

usage() { echo "usage: wait-for-findings.sh (--run-env <file> | --run-id <id> --expect <a,b,...>) --dir <dir> [--timeout <s>] [--poll <s>] [--check]" >&2; }
die_usage() { echo "wait-for-findings.sh: $1" >&2; usage; exit 2; }
is_posint() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; [ "${#1}" -le 9 ] && [ "$((10#$1))" -gt 0 ]; }
is_token() { case "$1" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die_usage "--dir needs a value"; DIR="$2"; shift 2 ;;
    --run-id) [ $# -ge 2 ] || die_usage "--run-id needs a value"; RUN_ID="$2"; shift 2 ;;
    --expect) [ $# -ge 2 ] || die_usage "--expect needs a value"; EXPECT="$2"; shift 2 ;;
    --run-env) [ $# -ge 2 ] || die_usage "--run-env needs a value"; RUN_ENV="$2"; shift 2 ;;
    --timeout) [ $# -ge 2 ] || die_usage "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
    --poll) [ $# -ge 2 ] || die_usage "--poll needs a value"; POLL="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h | --help) usage; exit 2 ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

if [ -n "$RUN_ENV" ]; then
  [ -z "$RUN_ID" ] && [ -z "$EXPECT" ] || die_usage "--run-env replaces --run-id and --expect; pass one or the other"
  [ -r "$RUN_ENV" ] || die_usage "--run-env file not readable: $RUN_ENV"
  RUN_ID="$(sed -n 's/^RUN_ID=//p' "$RUN_ENV" | tail -n 1 | tr -d '\r')"
  EXPECT="$(sed -n 's/^EXPECT=//p' "$RUN_ENV" | tail -n 1 | tr -d '\r')"
  [ -n "$RUN_ID" ] && [ -n "$EXPECT" ] || die_usage "$RUN_ENV lacks RUN_ID= or EXPECT="
fi
[ -n "$DIR" ] || die_usage "--dir is required"
[ -n "$RUN_ID" ] || die_usage "--run-id is required"
[ -n "$EXPECT" ] || die_usage "--expect is required"
is_token "$RUN_ID" || die_usage "--run-id must match [A-Za-z0-9._-]+ (got '$RUN_ID')"
is_posint "$TIMEOUT" || die_usage "--timeout must be a positive integer (got '$TIMEOUT')"
is_posint "$POLL" || die_usage "--poll must be a positive integer (got '$POLL')"
TIMEOUT=$((10#$TIMEOUT)); POLL=$((10#$POLL))

OLD_IFS="$IFS"; IFS=','; set -f
# shellcheck disable=SC2086
set -- $EXPECT
set +f; IFS="$OLD_IFS"
[ $# -gt 0 ] || die_usage "--expect listed no entries"
for e in "$@"; do
  case "$e" in
    *:R[0-9]) is_token "${e%:R*}" || die_usage "bad entry '$e'" ;;
    *) is_token "$e" || die_usage "bad entry '$e' (want <name> or <name>:R<k>)" ;;
  esac
done
ENTRIES="$*"; TOTAL=$#

[ -d "$DIR" ] || { echo "wait-for-findings.sh: findings dir not found: $DIR" >&2; exit 3; }

last_nonempty() { grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -n 1 | sed 's/[[:space:]]*$//'; }

# entry_done <entry> -> 0 when its file ends with its exact marker.
entry_done() {
  local e="$1" name round marker f
  case "$e" in
    *:R[0-9]) name="${e%:R*}"; round="R${e##*:R}"; marker="<!-- REVIEW-COMPLETE $name $RUN_ID $round -->" ;;
    *) name="$e"; round=""; marker="<!-- REVIEW-COMPLETE $name $RUN_ID -->" ;;
  esac
  f="$DIR/$name.md"
  [ -f "$f" ] && [ "$(last_nonempty "$f")" = "$marker" ] && return 0
  f="$DIR/round1/$name.md"
  [ "$round" = R1 ] && [ -f "$f" ] && [ "$(last_nonempty "$f")" = "$marker" ] && return 0
  return 1
}

missing() {
  local out="" e
  for e in $ENTRIES; do
    entry_done "$e" || out="${out:+$out,}$e"
  done
  printf '%s' "$out"
}

SECONDS=0; LIMIT=$((TIMEOUT + 1))
while :; do
  [ -d "$DIR" ] || { echo "wait-for-findings.sh: findings dir vanished: $DIR" >&2; exit 3; }
  M="$(missing)"
  [ -n "$M" ] || { echo "READY: $TOTAL/$TOTAL"; exit 0; }
  [ "$CHECK" -eq 0 ] || { echo "MISSING: $M"; exit 1; }
  [ "$SECONDS" -lt "$LIMIT" ] || { echo "MISSING: $M"; exit 124; }
  R=$((LIMIT - SECONDS))
  if [ "$R" -lt "$POLL" ]; then sleep "$R"; else sleep "$POLL"; fi
done
