#!/usr/bin/env bash
# pending-question-reprint.sh: an open question is shown again at the end of a turn, once per change or per stretch
# of conversation, as one valid JSON object; nothing is printed when there is nothing to show; it never fails a stop.
# Mutation this file must catch (run once by hand with HOOKS_UNDER_TEST=<mutated copy of hooks/>): remove the growth
# gate (reprint on every stop).
. "$(dirname "$0")/../lib.sh"

t_hook_fixture pq
export PENDING_QUESTIONS_DIR="$T_TMP/pq" PQ_REPRINT_MIN_BYTES=1000
mkdir -p "$PENDING_QUESTIONS_DIR"
TR="$T_TMP/transcript.jsonl"; echo start > "$TR"
STOP="{\"session_id\":\"s1\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
P() { t_hook pending-question-reprint "${1:-$STOP}"; }
msg() { if command -v jq >/dev/null 2>&1; then printf '%s' "$OUT" | jq -r .systemMessage; else printf '%s' "$OUT"; fi; }
valid() {
  if command -v jq >/dev/null 2>&1; then printf '%s' "$OUT" | jq -e 'keys == ["systemMessage"]' >/dev/null 2>&1
  else case "$OUT" in '{"systemMessage":"'*'"}') return 0 ;; *) return 1 ;; esac; fi
}

P; expect_rc 0 "no question file → exit 0"; check "no question file → nothing printed" test -z "$OUT"
printf 'Which database should the tests use?\nA) sqlite  B) postgres\n' > "$PENDING_QUESTIONS_DIR/s1"
P; expect_rc 0 "open question → exit 0"
check "open question → one valid JSON object with only systemMessage" valid
case "$(msg)" in *'Which database should the tests use?'*'B) postgres'*) t_pass "the message carries the whole question" ;; *) t_fail "the message carries the whole question" ;; esac
case "$(msg)" in 'Waiting on your answer (asked '[0-9][0-9]:[0-9][0-9]'):'*) t_pass "the message names the time it was asked" ;; *) t_fail "the message names the time it was asked" ;; esac
refute_out '"decision"|"continue"' "never a decision or continue field"
P; check "second stop, no growth, same text → nothing" test -z "$OUT"
head -c 500 /dev/zero | tr '\0' x >> "$TR"
P; check "growth below the threshold → nothing" test -z "$OUT"
head -c 1200 /dev/zero | tr '\0' x >> "$TR"
P; check "growth past the threshold → reprinted" valid
P; check "…and then quiet again" test -z "$OUT"
printf 'A new question?\n' > "$PENDING_QUESTIONS_DIR/s1"
P; case "$(msg)" in *'A new question?'*) t_pass "a rewritten question → reprinted at once" ;; *) t_fail "a rewritten question → reprinted at once" ;; esac
printf '  \n\t\n' > "$PENDING_QUESTIONS_DIR/s1"
P; check "whitespace-only file → nothing" test -z "$OUT"

# Escaping: quotes, backslashes, tabs, newlines and an ESC must come out as valid JSON with no control character.
printf 'Pick "A" or \\B?\tok\n\033[31mred\033[0m\n' > "$PENDING_QUESTIONS_DIR/s1"
P; check "quotes, backslash, tab, ESC → still valid JSON" valid
if printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '\033')"; then t_fail "no raw ESC in the output"; else t_pass "no raw ESC in the output"; fi
if command -v jq >/dev/null 2>&1; then
  case "$(msg)" in *'Pick "A" or \B?'*) t_pass "quotes and backslash survive the round trip" ;; *) t_fail "quotes and backslash survive the round trip" ;; esac
fi

# Truncation, with a multi-byte character split at the cut.
{ head -c 3999 /dev/zero | tr '\0' a; printf '\303\251'; head -c 3000 /dev/zero | tr '\0' b; } > "$PENDING_QUESTIONS_DIR/s1"
P; check "over-long question → still valid JSON" valid
expect_out 'truncated: the full text is in' "over-long question → a pointer to the full file"
if python3 -I -c '' >/dev/null 2>&1; then   # one that runs (Windows' Store alias is on PATH and does not)
  if printf '%s' "$OUT" | python3 -I -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null; then t_pass "a split multi-byte character is dropped (output is valid UTF-8)"; else t_fail "a split multi-byte character is dropped (output is valid UTF-8)"; fi
fi

# Age: a 25-hour-old question is not shown, and is deleted with its state.
echo old > "$PENDING_QUESTIONS_DIR/s2"; mkdir -p "$PENDING_QUESTIONS_DIR/.state"; echo "1-1 0" > "$PENDING_QUESTIONS_DIR/.state/s2"
touch -t "$(date -d '25 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-25H +%Y%m%d%H%M)" "$PENDING_QUESTIONS_DIR/s2" "$PENDING_QUESTIONS_DIR/.state/s2"
P "{\"session_id\":\"s2\",\"transcript_path\":\"$TR\"}"
check "a 25-hour-old question → nothing" test -z "$OUT"
check "…and the file is deleted" test ! -e "$PENDING_QUESTIONS_DIR/s2"
check "…and its state is deleted" test ! -e "$PENDING_QUESTIONS_DIR/.state/s2"
# The reap deletes only names shaped like a session id: another file in the folder is never touched, however old.
echo keep > "$PENDING_QUESTIONS_DIR/notes.txt"; echo old > "$PENDING_QUESTIONS_DIR/s4"
touch -t "$(date -d '25 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-25H +%Y%m%d%H%M)" "$PENDING_QUESTIONS_DIR/notes.txt" "$PENDING_QUESTIONS_DIR/s4"
P
check "an old file not named like a session id is kept" test -e "$PENDING_QUESTIONS_DIR/notes.txt"
check "…while an old session-id file is deleted" test ! -e "$PENDING_QUESTIONS_DIR/s4"
NLF="$PENDING_QUESTIONS_DIR/$(printf 'x\nkeepme')"; echo keep > "$HR/keepme"; echo old > "$NLF"
touch -t "$(date -d '25 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-25H +%Y%m%d%H%M)" "$NLF"
P
check "an old file whose name holds a newline is kept" test -e "$NLF"
check "…and nothing outside the folder is deleted through its name" test -e "$HR/keepme"

# Bad or missing input never fails the stop.
P '{"session_id":"../etc/passwd"}'; expect_rc 0 "unsafe session id → exit 0"; refute_out 'systemMessage' "unsafe session id → nothing shown"
P ''; expect_rc 0 "empty stdin → exit 0"
P 'not json'; expect_rc 0 "not JSON → exit 0"
printf 'from env\n' > "$PENDING_QUESTIONS_DIR/envsid"
T_STDIN='{}'; run env CLAUDE_CODE_SESSION_ID=envsid bash "$HD/pending-question-reprint.sh"
expect_out 'from env' "no session_id on stdin → the session id from the environment"
T_STDIN="$STOP"; run env PQ_REPRINT_MIN_BYTES=lots bash "$HD/pending-question-reprint.sh"; expect_rc 0 "a bad setting → exit 0"

# No parser: the session id is still found.
printf 'no parser question\n' > "$PENDING_QUESTIONS_DIR/s3"
T_STDIN="{\"session_id\":\"s3\",\"transcript_path\":\"$TR\"}"; run env PATH="$(t_path_without jq python3)" bash "$HD/pending-question-reprint.sh"
expect_out 'no parser question' "no jq and no python3 → still shown"
t_done
