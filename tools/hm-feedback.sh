#!/usr/bin/env bash
# hm-feedback.sh — send onboarding feedback to the HumanMaxxing maintainers, only as the user approved it.
#
# Run it from inside your project (the checks need the project's git folder, remote and identity; outside a git work
# tree it refuses). Nothing is sent by `preview`; `send` sends only the exact payload `preview` wrote.
#
#   hm-feedback.sh preview --notes <file> [--comment <file>] [--contact <email>] --out <payload.json>
#       Builds the payload, checks it (below), writes it to <payload.json>, prints it for the user to read, and prints
#       its fingerprint. An earlier payload (and its .sent marker) at <payload.json> is removed first, so a refused
#       preview never leaves an older payload behind. Exit 0 written · 2 usage, or a contact address the service would
#       refuse · 3 error (a missing tool, not inside a project, an unreadable file) · 4 refused by a check (the message
#       says which; rewrite the notes and run preview again).
#   hm-feedback.sh send --approved <fingerprint> <payload.json>
#       Sends the payload only if its fingerprint is still the one the user approved (any edit after the preview
#       changes it), after running the same checks again; the bytes checked are the bytes sent. A payload already
#       sent (its .sent marker exists) is never sent twice. Exit 0 sent (prints the reference) or already sent ·
#       2 usage or the fingerprint does not match · 3 error · 4 refused by a check · 5 not sent (the service did not
#       accept it or could not be reached: the payload stays where it is).
#
# Checks (on the notes and the comment; the contact is the user's own choice and is only checked to be one plain
# email address): the payload is refused if it contains this machine's home folder, the project's folder path or name,
# a git remote's address, owner/name or repository name, the git user's name or email, control characters, or a
# common secret format (a private key, a cloud or service token, a bearer token, credentials in a URL, a password or
# key assignment). The checks are a backstop for common forms, not proof: the notes describe this product's
# instructions, never the user's code.
#
# The service (the contract the endpoint implements):
#   POST <url>, Content-Type: application/json, body at most 32768 bytes:
#     {"schema": 1, "kind": "onboarding", "version": "<release>", "notes": "<text, at most 20000 bytes>",
#      "comment": "<text, at most 5000 bytes, may be empty>", "contact": "<an email address, or empty>"}
#   201 {"id": "<reference>"} accepted · 400 invalid · 413 too large · 429 too many requests · anything else: not sent.
#   The service sends the feedback to the maintainers privately; it never sends anything to the contact address
#   unless a maintainer replies by hand.
# The address is the one below. HM_FEEDBACK_URL overrides it for tests, and only with a local address.
set -u
LC_ALL=C; export LC_ALL
URL="${HM_FEEDBACK_URL:-https://humanmaxxing.ai/api/feedback}"
URL_RE='^(https://humanmaxxing\.ai/api/feedback|http://(127\.0\.0\.1|localhost):[0-9]{1,5}(/[A-Za-z0-9._~/-]*)?)$'
[[ "$URL" =~ $URL_RE ]] \
  || { echo "hm-feedback: HM_FEEDBACK_URL may only name a local test service (http://127.0.0.1:<port>/...)" >&2; exit 3; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 3
MAX_NOTES=20000; MAX_COMMENT=5000; MAX_BODY=32768

die() { echo "hm-feedback: $2" >&2; exit "$1"; }
usage() { die 2 "usage: hm-feedback.sh preview --notes F [--comment F] [--contact EMAIL] --out F | send --approved FINGERPRINT F"; }
case "${1:-}" in preview|send) ;; *) usage ;; esac
for t in jq git; do command -v "$t" >/dev/null 2>&1 || die 3 "needs $t; your notes are unchanged"; done
[ -n "${HOME:-}" ] || die 3 "HOME is not set: the checks cannot tell your home folder; nothing was written or sent"
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$TOP" ] \
  || die 3 "run this from inside your project (a git work tree): the checks need its folder, remote and identity"

# The fingerprint is git's hash of the bytes alone (--no-filters: never of what an eol or clean filter makes of them).
FP_RE='^[0-9a-f]{40}([0-9a-f]{24})?$'
fingerprint() {
  local h; h="$(git hash-object --no-filters -- "$1" 2>/dev/null)" || return 3
  [[ "$h" =~ $FP_RE ]] || return 3
  printf '%s\n' "$h"
}

# The same address rule the service applies (one line of plain ASCII; no leading dot, no "..", at most 254
# characters), so an address is refused here, before the user approves it, not by the service after.
valid_contact() {
  local c="$1"
  [ -n "$c" ] || return 0
  case "$c" in *$'\n'*|*$'\r'*|.*|*..*) return 1 ;; esac
  [ "${#c}" -le 254 ] || return 1
  [ "$(printf '%s\n' "$c" | wc -l)" -eq 1 ] || return 1
  printf '%s\n' "$c" | grep -Eqx "[A-Za-z0-9_'+.-]*[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9-]*\.)+[A-Za-z]{2,}"
}

# Prints one line per check that matched the text in file $1; prints nothing when it is clean. Returns non-zero
# only when a check could not run (the caller treats that as an error, never as clean).
scan() {
  local f="$1" s url rest name
  [ -r "$f" ] || return 3
  hit() { grep -qiF -- "$2" "$f" && echo "  - $1"; return 0; }
  # A name as a whole word (not inside a longer word or path segment), case-insensitive, when it has 4+ characters.
  # The product's own words are skipped: notes about these instructions need them (a project folder named "skills").
  hitword() {
    local e
    [ "${#2}" -ge 4 ] || return 0
    case "$(printf '%s' "$2" | tr 'A-Z' 'a-z')" in
      humanmaxxing|skills|tools|templates|tests|docs|onboarding|getting-started|claude|agents|hooks|main|master) return 0 ;;
    esac
    e="$(printf '%s' "$2" | sed 's/[].[^$*+?(){}|\\]/\\&/g')"
    grep -qiE -- "(^|[^A-Za-z0-9._-])${e}(\$|[^A-Za-z0-9_-])" "$f" && echo "  - $1"
    return 0
  }
  [ "${#HOME}" -gt 1 ] && hit "your home folder's path" "$HOME"
  hit "your project's folder path" "$TOP"
  hitword "your project's folder name" "$(basename "$TOP")"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    hit "a git remote's address" "$url"
    rest="${url%.git}"; rest="${rest%/}"; rest="${rest#*://}"; rest="${rest#*@}"
    case "$url" in   # ssh://host:2222/owner/name: drop the port (only a scheme URL has one)
      *://*) case "${rest%%/*}" in *:[0-9]*) rest="${rest#*/}" ;; *) rest="${rest#*[:/]}" ;; esac ;;
      *) rest="${rest#*[:/]}" ;;
    esac
    case "$rest" in */*) hit "a git remote's owner/name ($rest)" "$rest"; name="${rest##*/}"
                         hitword "a git remote's repository name ($name)" "$name" ;; esac
  done <<EOF
$(git remote 2>/dev/null | while IFS= read -r r; do git remote get-url "$r" 2>/dev/null; done)
EOF
  s="$(git config user.email 2>/dev/null)"; [ "${#s}" -ge 4 ] && hit "your git email" "$s"
  s="$(git config user.name 2>/dev/null)"; [ "${#s}" -ge 4 ] && hit "your git name" "$s"
  # Control characters other than tab, newline and carriage return (escape sequences would show differently on screen).
  [ "$(tr -d '\011\012\015\040-\176\200-\377' < "$f" | wc -c)" -eq 0 ] || echo "  - control characters"
  grep -qE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$f" && echo "  - a private key"
  grep -qE -- '(AKIA|ASIA)[0-9A-Z]{16}' "$f" && echo "  - a cloud access key"
  grep -qE -- '(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9-]{10,}|(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}|sk_(live|test)_[A-Za-z0-9]{16,}|AIza[0-9A-Za-z_-]{35})' "$f" \
    && echo "  - a service token"
  grep -qE -- 'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}' "$f" && echo "  - a signed token (JWT)"
  grep -qiE -- 'bearer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}' "$f" && echo "  - a bearer token"
  grep -qE -- '[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]+@' "$f" && echo "  - credentials in an address"
  # A password or key assignment: a quoted value, or an unquoted one with a digit in it (plain prose such as
  # "token: unclear wording" stays allowed).
  local k='(password|passwd|secret|api[_ -]?key|token)["'"'"']?[[:space:]]*[:=][[:space:]]*'
  { grep -qiE -- "${k}[\"'][^[:space:]\"']{8,}" "$f" \
    || grep -oiE -- "${k}[^[:space:]\"']{8,}" "$f" | sed -E 's/^[^:=]*[:=][[:space:]]*//' | grep -q '[0-9]'; } \
    && echo "  - a password or key assignment"
  return 0
}

# Checks a payload file: shape, sizes, contact, and the scan of its free-text fields. Exits 4 with the reasons on a
# failure, 3 when a check could not run.
check_payload() {
  local p="$1" text found
  jq -e '(keys == ["comment","contact","kind","notes","schema","version"]) and .schema == 1 and .kind == "onboarding"
         and (.version|type) == "string" and (.notes|type) == "string" and (.comment|type) == "string"
         and (.contact|type) == "string"' "$p" >/dev/null 2>&1 \
    || die 4 "$p is not a payload this script wrote"
  [ "$(wc -c < "$p")" -le "$MAX_BODY" ] || die 4 "the payload is larger than $MAX_BODY bytes: shorten the notes"
  [ "$(jq -j '.notes' "$p" | wc -c)" -le "$MAX_NOTES" ] || die 4 "the notes are longer than $MAX_NOTES bytes"
  [ "$(jq -j '.comment' "$p" | wc -c)" -le "$MAX_COMMENT" ] || die 4 "the comment is longer than $MAX_COMMENT bytes"
  valid_contact "$(jq -j '.contact' "$p")" || die 4 "the contact is not one plain email address"
  text="$(mktemp "${TMPDIR:-/tmp}/hm-feedback.XXXXXX")" || die 3 "cannot make a temporary file"
  jq -r '.notes, .comment' "$p" > "$text" || { rm -f "$text"; die 3 "cannot read $p"; }
  found="$(scan "$text")" || { rm -f "$text"; die 3 "the checks could not run; nothing was written or sent"; }
  rm -f "$text"
  [ -z "$found" ] || { printf 'hm-feedback: not sent. The notes or the comment contain:\n%s\nReplace each with a generic description ("the API folder", "a token") and run preview again.\n' "$found" >&2; exit 4; }
}

[ "$#" -ge 1 ] || usage
CMD="$1"; shift
case "$CMD" in
  preview)
    NOTES=""; COMMENT=""; CONTACT=""; OUT=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --notes) [ "$#" -ge 2 ] || usage; NOTES="$2"; shift 2 ;;
        --comment) [ "$#" -ge 2 ] || usage; COMMENT="$2"; shift 2 ;;
        --contact) [ "$#" -ge 2 ] || usage; CONTACT="$2"; shift 2 ;;
        --out) [ "$#" -ge 2 ] || usage; OUT="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$NOTES" ] && [ -n "$OUT" ] || usage
    [ -f "$NOTES" ] || die 3 "no notes file at $NOTES"
    [ -z "$COMMENT" ] || [ -f "$COMMENT" ] || die 3 "no comment file at $COMMENT"
    # --out is only ever a payload: never the notes, the comment, or any other existing file.
    { [ "$OUT" != "$NOTES" ] && ! { [ -e "$OUT" ] && [ "$OUT" -ef "$NOTES" ]; }; } || die 2 "--out must not be the notes file"
    [ -z "$COMMENT" ] || { [ "$OUT" != "$COMMENT" ] && ! { [ -e "$OUT" ] && [ "$OUT" -ef "$COMMENT" ]; }; } \
      || die 2 "--out must not be the comment file"
    if [ -e "$OUT" ]; then
      jq -e 'keys == ["comment","contact","kind","notes","schema","version"]' "$OUT" >/dev/null 2>&1 \
        || die 2 "--out names an existing file that is not a feedback payload: $OUT"
    fi
    rm -f -- "$OUT" "$OUT.sent" || die 3 "cannot remove the earlier payload at $OUT"
    [ "$(wc -c < "$NOTES")" -le "$MAX_NOTES" ] || die 4 "the notes are longer than $MAX_NOTES bytes: shorten them"
    grep -q '[^[:space:]]' "$NOTES" || die 4 "the notes file is empty: there is nothing to send"
    [ -z "$COMMENT" ] || [ "$(wc -c < "$COMMENT")" -le "$MAX_COMMENT" ] || die 4 "the comment is longer than $MAX_COMMENT bytes"
    valid_contact "$CONTACT" || die 2 "--contact must be one plain email address on one line"
    VERSION="$(cat "$HERE/../VERSION" 2>/dev/null)" || die 3 "no VERSION beside this script's folder"
    TMP="$(mktemp "$OUT.XXXXXX")" || die 3 "cannot write beside $OUT"
    jq -n --arg version "$VERSION" --rawfile notes "$NOTES" --arg contact "$CONTACT" \
      --rawfile comment "${COMMENT:-/dev/null}" \
      '{schema: 1, kind: "onboarding", version: $version, notes: $notes, comment: $comment, contact: $contact}' \
      > "$TMP" || { rm -f "$TMP"; die 3 "cannot write $OUT"; }
    # A refused payload is never left on disk.
    ( check_payload "$TMP" ) || { RC=$?; rm -f "$TMP"; exit "$RC"; }
    FP="$(fingerprint "$TMP")" || { rm -f "$TMP"; die 3 "cannot fingerprint the payload"; }
    mv -f "$TMP" "$OUT" || { rm -f "$TMP"; die 3 "cannot write $OUT"; }
    echo "This is exactly what would be sent to the HumanMaxxing maintainers ($URL):"
    echo "----"
    jq -r '"Release: \(.version)\nReply to: \(if .contact == "" then "(no reply wanted)" else .contact end)\n\nNotes:\n\(.notes)\nOther feedback:\n\(if .comment == "" then "(none)" else .comment end)"' "$OUT"
    echo "----"
    echo "FINGERPRINT $FP"
    ;;
  send)
    [ "${1:-}" = "--approved" ] && [ "$#" -eq 3 ] || usage
    APPROVED="$2"; P="$3"
    [[ "$APPROVED" =~ $FP_RE ]] || die 2 "--approved must be the FINGERPRINT line preview printed"
    command -v curl >/dev/null 2>&1 || die 3 "needs curl; nothing was sent, the payload stays at $P"
    [ -f "$P" ] || die 3 "no payload at $P"
    # Check and send one private copy, so the bytes checked are exactly the bytes sent.
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/hm-feedback.XXXXXX")" || die 3 "cannot make a temporary folder"
    trap 'rm -rf "$WORK"' EXIT
    cp -- "$P" "$WORK/payload.json" || die 3 "cannot read $P"
    FP="$(fingerprint "$WORK/payload.json")" || die 3 "cannot fingerprint $P"
    [ "$FP" = "$APPROVED" ] \
      || die 2 "$P changed since it was approved (fingerprint differs): run preview again and show it to the user"
    if [ -e "$P.sent" ]; then
      echo "ALREADY-SENT"; echo "This feedback was already sent; it is never sent twice."; exit 0
    fi
    ( check_payload "$WORK/payload.json" ) || exit $?
    echo "Sending to $URL"
    CODE="$(curl -q -sS -o "$WORK/resp" -w '%{http_code}' --proto '=https,http' --max-time 20 -X POST \
      -H 'Content-Type: application/json' --data-binary "@$WORK/payload.json" "$URL" 2>"$WORK/err")" || CODE="000"
    ID="$(jq -r '.id // empty' "$WORK/resp" 2>/dev/null)"
    case "$CODE" in
      201)
        [ -n "$ID" ] || ID="(no reference given)"
        : > "$P.sent" || echo "hm-feedback: sent, but could not write $P.sent: do not send it again" >&2
        echo "SENT reference=$ID"; echo "Thank you. Your feedback was sent; its reference is $ID." ;;
      000) echo "NOT-SENT unreachable"
           echo "The feedback service could not be reached ($(head -c 200 "$WORK/err" | tr '\n' ' ')). Nothing was sent; the payload stays at $P."
           exit 5 ;;
      *) echo "NOT-SENT http=$CODE"; echo "The feedback service did not accept it (HTTP $CODE). Nothing was sent; the payload stays at $P."; exit 5 ;;
    esac
    ;;
  *) usage ;;
esac
