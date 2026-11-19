#!/usr/bin/env bash
# pending-question-reprint.sh — Stop hook: the question the agent is still waiting on is shown again at the end of
# the turn, so it does not scroll out of sight.
# hooks-pack: 1
#
# Wired as: Stop, no matcher, timeout 10 (onFailure has no effect on Stop and is not set).
# The file: ${PENDING_QUESTIONS_DIR:-$HOME/.claude/pending-questions}/<session id>, written by the agent the moment it
# asks a question and deleted the moment the user answers (CLAUDE.md, Tool Discipline, "Pending question").
#
# Prints {"systemMessage": "Waiting on your answer (asked HH:MM): ..."} when the file is non-empty, younger than 24
# hours, and either its text changed since the last reprint or the session transcript grew by at least
# PQ_REPRINT_MIN_BYTES (default 20000) since then. Long text is cut at PQ_MAX_BYTES (default 4000) with a pointer to
# the file. Files and reprint state older than 24 hours in that folder are deleted, but only those named like a
# session id ([A-Za-z0-9_-]+): anything else in the folder is never touched.
#
# It protects nothing, so it never holds a turn open: every error path writes one line to stderr and exits 0, and it
# never emits "decision" or "continue". State: <dir>/.state/<session id> (checksum and transcript size).

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
. "$HOOK_DIR/hook-lib.sh" || exit 0

note() { echo "pending-question-reprint: $1" >&2; exit 0; }

DIR="${PENDING_QUESTIONS_DIR:-$HOME/.claude/pending-questions}"
MIN="${PQ_REPRINT_MIN_BYTES:-20000}"; MAX="${PQ_MAX_BYTES:-4000}"
case "$MIN$MAX" in *[!0-9]*|'') note "PQ_REPRINT_MIN_BYTES and PQ_MAX_BYTES must be whole numbers" ;; esac

IN="$(hk_stdin_file)" || note "cannot read the hook input"
trap 'rm -f "$IN"' EXIT

# Reap: questions and state older than 24 hours belong to sessions that are over. Only session-id names are deleted.
reap() {  # reap <dir> — find itself filters the names, so no file name passes through the shell
  [ -d "$1" ] || return 0
  LC_ALL=C find "$1" -maxdepth 1 -type f -mmin +1440 ! -name '*[!A-Za-z0-9_-]*' -exec rm -f {} + 2>/dev/null
}
reap "$DIR"; reap "$DIR/.state"

SID="$(hk_field "$IN" session_id)"; RC=$?
if [ "$RC" -eq 3 ]; then
  SID="$(LC_ALL=C sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' "$IN" | head -1)"
elif [ "$RC" -ne 0 ]; then
  SID=""
fi
[ -n "$SID" ] || SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || exit 0
case "$SID" in *[!A-Za-z0-9_-]*) note "session id has characters outside [A-Za-z0-9_-]; not used as a file name" ;; esac

F="$DIR/$SID"
[ -f "$F" ] || exit 0
[ -n "$(find "$F" -mmin -1440 2>/dev/null)" ] || exit 0
grep -q '[^[:space:]]' "$F" 2>/dev/null || exit 0

TP=""
if [ "$RC" -ne 3 ]; then TP="$(hk_field "$IN" transcript_path)" || TP=""; fi
SIZE=0
[ -n "$TP" ] && [ -f "$TP" ] && SIZE="$(wc -c < "$TP" | tr -d ' ')"
SUM="$(cksum < "$F" | awk '{print $1 "-" $2}')" || note "cannot checksum $F"

ST="$DIR/.state/$SID"
if [ -f "$ST" ]; then
  read -r OLD_SUM OLD_SIZE < "$ST" || { OLD_SUM=""; OLD_SIZE=0; }
  case "${OLD_SIZE:-}" in ''|*[!0-9]*) OLD_SIZE=0 ;; esac
  if [ "$OLD_SUM" = "$SUM" ] && [ $((SIZE - OLD_SIZE)) -lt "$MIN" ]; then exit 0; fi
fi
mkdir -p "$DIR/.state" 2>/dev/null && printf '%s %s\n' "$SUM" "$SIZE" > "$ST" 2>/dev/null || echo "pending-question-reprint: cannot write $ST (the question may be shown on every stop)" >&2

# The time it was asked: the file's modification time.
MT="$(stat -c %Y "$F" 2>/dev/null || stat -f %m "$F" 2>/dev/null)" || MT=""
HM=""
[ -n "$MT" ] && HM="$(date -d "@$MT" +%H:%M 2>/dev/null || date -r "$MT" +%H:%M 2>/dev/null)"
[ -n "$HM" ] || HM="earlier"

BYTES="$(wc -c < "$F" | tr -d ' ')"
TEXT="$(LC_ALL=C head -c "$MAX" "$F" | LC_ALL=C tr -d '\000-\010\013-\037\177')"
if [ "$BYTES" -gt "$MAX" ]; then
  # Drop a multi-byte character the cut split: trailing bytes >= 0x80 back to the last plain one.
  TEXT="$(printf '%s' "$TEXT" | LC_ALL=C awk 'BEGIN { for (i = 128; i < 256; i++) hi = hi sprintf("%c", i) }
    { line[NR] = $0 } END { s = line[NR]; while (length(s) > 0 && index(hi, substr(s, length(s), 1)) > 0) s = substr(s, 1, length(s) - 1)
      line[NR] = s; for (i = 1; i <= NR; i++) { if (i > 1) printf "\n"; printf "%s", line[i] } }')"
  TEXT="$TEXT
[truncated: the full text is in $F]"
fi

printf '{"systemMessage":"%s"}\n' "$(printf 'Waiting on your answer (asked %s):\n%s' "$HM" "$TEXT" | hk_json_escape)"
exit 0
