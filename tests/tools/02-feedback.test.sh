#!/usr/bin/env bash
# tools/hm-feedback.sh: preview writes the exact payload and its fingerprint; send sends only that payload, only to the
# feedback service, and refuses the user's paths, remote, git identity and secrets. A fake local service stands in.
. "$(dirname "$0")/../lib.sh"
F="$T_ROOT/tools/hm-feedback.sh"

check "the product names one feedback destination, the public endpoint" sh -c \
  '[ "$(grep -rhoE "https?://[A-Za-z0-9.-]*humanmaxxing[A-Za-z0-9.-]*/api/[a-z]+" "$1/tools" "$1/getting-started.claude.md" | sort -u)" = "https://humanmaxxing.ai/api/feedback" ]' _ "$T_ROOT"

# The fake service: records each body, answers per $T_TMP/mode (ok | reject).
cat > "$T_TMP/srv.py" <<'EOF'
import http.server, json, os, sys
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = self.rfile.read(n)
        open(os.path.join(d, "body"), "wb").write(body)
        open(os.path.join(d, "ctype"), "w").write(self.headers.get("Content-Type", ""))
        mode = open(os.path.join(d, "mode")).read().strip()
        code, out = {"ok": (201, {"id": "FB-7"}), "ok200": (200, {"id": "FB-8"})}.get(mode, (400, {"error": "invalid"}))
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(out).encode())
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
EOF
echo ok > "$T_TMP/mode"
# A Python 3 that runs: python3, else python (Windows installs it under that name; its `python3` may be the Microsoft
# Store alias, which does not run).
PY=""
for c in python3 python; do
  "$c" -I -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1 && { PY="$c"; break; }
done
if [ -z "$PY" ]; then t_skip "the send path: no Python 3 here to run the fake feedback service"; t_done; exit $?; fi
"$PY" -I "$T_TMP/srv.py" "$T_TMP" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$T_TMP"' EXIT   # keeps the harness's own cleanup
for _ in $(seq 50); do [ -s "$T_TMP/port" ] && break; sleep 0.1; done
[ -s "$T_TMP/port" ] || { echo "fake service did not start"; exit 2; }
HM_FEEDBACK_URL="http://127.0.0.1:$(cat "$T_TMP/port")/api/feedback"; export HM_FEEDBACK_URL

# A project with a remote and a git identity.
P="$T_TMP/acme-shop"; mkdir -p "$P" && cd "$P" && git init -q -b main . || exit 2
git config user.name "Jane Example"; git config user.email "jane@example.test"
git remote add origin git@github.com:acme/shop-api.git
N="$T_TMP/notes.md"; C="$T_TMP/comment.md"; PL="$T_TMP/payload.json"
printf '1. Phase 1, Inherited history: unclear when to ask. Asked it.\n' > "$N"
printf 'Great overall.\n' > "$C"

run bash "$F" preview --notes "$N" --comment "$C" --contact "jane@example.test" --out "$PL"
expect_rc 0 "preview of clean notes succeeds"
expect_out '^FINGERPRINT [0-9a-f]{40}$' "it prints the fingerprint"
expect_out 'Reply to: jane@example.test' "it shows the contact (the user's own choice, not refused)"
expect_out 'Great overall' "it shows the other feedback"
check "the payload has the contract's fields" jq -e '.schema == 1 and .kind == "onboarding" and .contact == "jane@example.test" and (.notes|test("Inherited history")) and (.version|test("^[0-9]+\\."))' "$PL"
FP="$(printf '%s\n' "$OUT" | sed -n 's/^FINGERPRINT //p')"

run bash "$F" send --approved 0000000000000000000000000000000000000000 "$PL"
expect_rc 2 "a fingerprint that is not the approved one is refused"
check "and nothing reached the service" test ! -e "$T_TMP/body"

run bash "$F" send --approved "$FP" "$PL"
expect 0 "Thank you. Your feedback was sent; its reference is FB-7." "the approved payload is sent and the reference shown"
check "the service received exactly the approved bytes" cmp -s "$T_TMP/body" "$PL"
check "as JSON" grep -q 'application/json' "$T_TMP/ctype"
check "and it is marked sent" test -e "$PL.sent"
rm -f "$T_TMP/body"
run bash "$F" send --approved "$FP" "$PL"
expect 0 "This feedback was already sent; it is never sent twice." "a second send of the same payload is refused politely"
check "and nothing reached the service twice" test ! -e "$T_TMP/body"

# Edited after the preview: refused, nothing sent.
rm -f "$T_TMP/body"; printf ' ' >> "$PL"
run bash "$F" send --approved "$FP" "$PL"; expect_rc 2 "an edit after the approval is refused"
check "and nothing was sent" test ! -e "$T_TMP/body"

# The service refuses, or cannot be reached: exit 5, the payload stays.
run bash "$F" preview --notes "$N" --out "$PL"; FP="$(printf '%s\n' "$OUT" | sed -n 's/^FINGERPRINT //p')"
expect_out 'Reply to: \(no reply wanted\)' "no contact: says no reply is wanted"
echo reject > "$T_TMP/mode"
run bash "$F" send --approved "$FP" "$PL"; expect_rc 5 "a refusal by the service is 'not sent'"
expect_out '^NOT-SENT http=400$' "with the service's answer"
check "the payload stays" test -f "$PL"
check "and is not marked sent" test ! -e "$PL.sent"
echo ok200 > "$T_TMP/mode"
run bash "$F" send --approved "$FP" "$PL"; expect_rc 5 "only 201 counts as sent (a 200 is not the contract)"
check "and a 200 is not marked sent" test ! -e "$PL.sent"
run env HM_FEEDBACK_URL="http://127.0.0.1:9/api/feedback" bash "$F" send --approved "$FP" "$PL"
expect_rc 5 "an unreachable service is 'not sent'"; expect_out '^NOT-SENT unreachable$' "and says so"

# The checks: each of these in the notes is refused, and no payload is left behind.
leak() {  # $1 = description, $2 = text
  printf 'Phase 1: %s\n' "$2" > "$T_TMP/bad.md"; rm -f "$T_TMP/bad.json"
  run bash "$F" preview --notes "$T_TMP/bad.md" --out "$T_TMP/bad.json"
  expect_rc 4 "refused: $1"
  check "no payload left for: $1" test ! -e "$T_TMP/bad.json"
}
leak "the home folder" "read $HOME/notes"
leak "the project's folder" "ran it in $P"
leak "the remote's address" "the remote git@github.com:acme/shop-api.git"
leak "the remote's owner/name" "fork of acme/shop-api"
leak "the git email" "author jane@example.test"
leak "the git name" "asked jane example"
leak "a private key" "-----BEGIN RSA PRIVATE KEY-----"
leak "a cloud key" "$(printf 'AKIA%s' ABCDEFGHIJKLMNOP)"  # built at run time: a secret scanner would flag a literal key here
leak "a service token" "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
leak "a JWT" "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.x"
leak "a password assignment" "found password = 'hunter2hunter2'"
expect_out 'a password or key assignment' "the refusal names what it found"
refute_out 'hunter2' "and never repeats the secret"

# send checks again: a payload edited by hand (and fingerprinted afresh) still cannot carry a secret.
echo ok > "$T_TMP/mode"; rm -f "$T_TMP/body"
jq --arg h "$HOME" '.notes = "see \($h)"' "$PL" > "$T_TMP/hand.json"
run bash "$F" send --approved "$(git hash-object "$T_TMP/hand.json")" "$T_TMP/hand.json"
expect_rc 4 "send runs the checks itself"; check "and nothing was sent" test ! -e "$T_TMP/body"

# The comment is checked too; the contact is not.
printf 'see %s\n' "$HOME" > "$T_TMP/c2.md"
run bash "$F" preview --notes "$N" --comment "$T_TMP/c2.md" --out "$T_TMP/c2.json"; expect_rc 4 "the comment is checked"
for bad in "not an email" "jos\303\251@example.com" "a!b@x.co" ".a@x.co" "a..b@x.co" "a@x.c0"; do
  run bash "$F" preview --notes "$N" --contact "$(printf "$bad")" --out "$T_TMP/c3.json"; expect_rc 2 "a contact the service would refuse is refused first: $bad"
done
run bash "$F" preview --notes "$N" --contact "o'neil+hm@mail.example.co" --out "$T_TMP/c4.json"; expect_rc 0 "an address with ' and + is accepted"
printf ' \n\t\n' > "$T_TMP/blank.md"
run bash "$F" preview --notes "$T_TMP/blank.md" --out "$T_TMP/c5.json"; expect_rc 4 "notes that are only whitespace are refused"
head -c 20001 /dev/zero | tr '\0' 'a' > "$T_TMP/big.md"
run bash "$F" preview --notes "$T_TMP/big.md" --out "$T_TMP/big.json"; expect_rc 4 "notes over the size cap are refused"

# Fail closed: no HOME, outside a project, a non-local override, an empty fingerprint.
run env -u HOME bash "$F" preview --notes "$N" --out "$T_TMP/h.json"; expect_rc 3 "no HOME: refused, never scanned as clean"
check "and no payload written" test ! -e "$T_TMP/h.json"
run sh -c 'cd "$1" && bash "$2" preview --notes "$3" --out "$1/o.json"' _ "$T_TMP" "$F" "$N"
expect_rc 3 "outside a git work tree the checks cannot run: refused"
run env HM_FEEDBACK_URL="https://example.com/api/feedback" bash "$F" preview --notes "$N" --out "$T_TMP/u.json"
expect_rc 3 "the address override is only for a local test service"
run bash "$F" send --approved "" "$PL"; expect_rc 2 "an empty fingerprint is refused"

# A refused preview removes an earlier payload of the same name; a new preview removes the old sent marker.
run bash "$F" preview --notes "$N" --out "$T_TMP/r.json"; expect_rc 0 "a good preview"
: > "$T_TMP/r.json.sent"
printf 'see %s\n' "$HOME" > "$T_TMP/r.md"
run bash "$F" preview --notes "$T_TMP/r.md" --out "$T_TMP/r.json"; expect_rc 4 "then a refused one"
check "leaves no older payload behind" test ! -e "$T_TMP/r.json"
check "nor its sent marker" test ! -e "$T_TMP/r.json.sent"

# The contact is one line: a second line would ride along unchecked.
run bash "$F" preview --notes "$N" --contact "$(printf 'a@x.co\nsee /home/someone')" --out "$T_TMP/m.json"
expect_rc 2 "a contact with a second line is refused"

# More forms that are refused, and ordinary prose that is not.
leak "the project's folder name alone" "in the acme-shop repo"
leak "the remote's repository name alone" "the shop-api service"
leak "a bearer token" "header Bearer abcdefghijklmnop12345678"
leak "credentials in an address" "postgres://admin:pw1234@db.example/x"
leak "a control character" "$(printf 'odd \033[31m text')"
leak "an unquoted key with digits" "$(printf 'api key: %s' abcd1234efgh)"  # built at run time, like the cloud key
for ok in "the token: wording was unclear here" "the task-specific-instructions-were-unclear part" "the password step was unclear"; do
  printf 'Phase 1: %s\n' "$ok" > "$T_TMP/ok.md"
  run bash "$F" preview --notes "$T_TMP/ok.md" --out "$T_TMP/ok.json"; expect_rc 0 "ordinary prose is not refused: $ok"
done

# send re-checks a hand-edited payload: unknown keys, a bad contact, a leak in the comment.
echo ok > "$T_TMP/mode"; rm -f "$T_TMP/body"
for edit in '.extra = "x"' '.contact = "a@x.co\nsee /tmp"' ".comment = \"see $HOME\""; do
  jq "$edit" "$T_TMP/ok.json" > "$T_TMP/e.json"
  run bash "$F" send --approved "$(git hash-object --no-filters "$T_TMP/e.json")" "$T_TMP/e.json"
  expect_rc 4 "send refuses a hand edit: $edit"
done
check "and nothing was sent for any of them" test ! -e "$T_TMP/body"

# Second-pass cases: the override cannot smuggle another host; --out never destroys the notes; product words pass.
run env HM_FEEDBACK_URL="http://127.0.0.1:80@evil.example/x" bash "$F" preview --notes "$N" --out "$T_TMP/v.json"
expect_rc 3 "an override with user info naming another host is refused"
run env HM_FEEDBACK_URL="$(printf 'http://127.0.0.1:1\nhttp://evil.example/x')" bash "$F" preview --notes "$N" --out "$T_TMP/v.json"
expect_rc 3 "an override with a second line is refused"
run bash "$F" send --approved "$(printf '%040d\nx' 0)" "$PL"; expect_rc 2 "a fingerprint with a second line is refused"
cp "$N" "$T_TMP/keep.md"
run bash "$F" preview --notes "$T_TMP/keep.md" --out "$T_TMP/keep.md"; expect_rc 2 "--out cannot be the notes file"
check "and the notes are still there" cmp -s "$N" "$T_TMP/keep.md"
run bash "$F" preview --notes "$N" --out "$T_TMP/keep.md"; expect_rc 2 "--out cannot overwrite a file that is not a payload"
check "which is left as it was" cmp -s "$N" "$T_TMP/keep.md"
S="$T_TMP/skills"; mkdir -p "$S" && git -C "$S" init -q . || exit 2
printf '1. the skills folder was unclear\n' > "$T_TMP/sk.md"
run sh -c 'cd "$1" && bash "$2" preview --notes "$3" --out "$4"' _ "$S" "$F" "$T_TMP/sk.md" "$T_TMP/sk.json"
expect_rc 0 "a project folder named like the product's own words does not refuse notes about them"
D="$T_TMP/digits"; mkdir -p "$D" && git -C "$D" init -q . && git -C "$D" remote add origin https://github.com/42coders/secretapp.git || exit 2
printf '1. fork of 42coders/secretapp\n' > "$T_TMP/dg.md"
run sh -c 'cd "$1" && bash "$2" preview --notes "$3" --out "$4"' _ "$D" "$F" "$T_TMP/dg.md" "$T_TMP/dg.json"
expect_rc 4 "a remote owner that starts with a digit is still caught"
run sh -c 'cd "$1" && bash "$2" bogus' _ "$T_TMP" "$F"; expect_rc 2 "an unknown command is a usage error even outside a project"
run bash "$F" bogus; expect_rc 2 "an unknown command is a usage error"
t_done
