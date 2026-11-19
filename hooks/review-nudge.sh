#!/usr/bin/env bash
# review-nudge.sh — Stop hook: when this session's implementation looks done and no review covers the tree, remind
# the agent, once, to run the review-code skill before it stops, reports done, hands off or compacts.
# hooks-pack: 1
#
# Wired as: Stop, no matcher, timeout 30 (onFailure has no effect on Stop and is not set).
#
# Why: the rules say the code review runs before any completion claim. A prose rule decays; the agent wraps up with
# "done" on unreviewed code, and the ship skill's halt only fires if someone invokes ship. This is the mechanical
# backstop at the moment the agent stops. It is a nudge, not a gate: the ship skill's review check is the gate, so a
# missed nudge costs one step at ship time, while a false nudge costs a model turn. Every rule below leans quiet when
# it cannot measure.
#
# Fires only when ALL hold (any other case: exit 0, nothing printed):
#   - stop_hook_active is not true (never a loop), and this session has not been nudged yet (one marker per session
#     under `git rev-parse --git-path hooks-review-nudge`, written only when it fires: a no-change stop never spends it);
#   - the repository is governed (.claude/hooks/hooks.env) and has .claude/skills/review-code/SKILL.md and the ship
#     skill's .claude/skills/ship/bin/ship-sentinel.sh (no review skill = nothing to nudge toward);
#   - there is work: an uncommitted change, or a clean tree whose HEAD was committed less than two hours ago (the
#     post-commit case: the handoff right after a checkpoint commit is where the reminder matters most; an old HEAD is
#     not this session's work);
#   - the change is reviewable: ship's own review fingerprint (`ship-sentinel.sh fingerprint`, every changed path on the
#     branch minus ship's DOCS_ALLOWLIST) is not the fingerprint of an empty change set. Docs-only work is not gated,
#     and the classification is ship's, so the two can never disagree;
#   - the review is missing: `ship-sentinel.sh verify review` exits exactly 1 (absent, stale, or for another tree).
#     Exit 0 (covered) and any other exit (the reader could not decide, the script failed) are quiet: a nudge never
#     rests on a measurement error. Under REVIEW_GATE=manual in ship.env, verify reads the manual attestation instead,
#     so the nudge fires until a review or an attestation covers this tree;
#   - this session wrote a reviewable file: an Edit, Write or NotebookEdit in the session transcript whose path is in
#     this repository and not matched by ship's DOCS_ALLOWLIST (DOCS_KEEP_BOUND re-includes, as in ship). A transcript
#     that is missing, unreadable, or has a tool-use line no parser can read counts as "wrote something" (the nudge
#     stays armed), since a scan that cannot read cannot prove "nothing written".
#
# Known residuals, stated rather than implied:
#   - a change made only with Bash (sed -i, a heredoc, tee) is not seen by the transcript scan, so such a session is
#     not nudged (fails toward quiet; the ship gate still halts);
#   - a session that changed nothing can still be nudged when a concurrent session in the same worktree wrote code and
#     this session wrote a reviewable file of its own; the tree cannot attribute a change to a session;
#   - a symlinked or differently spelled repository path in the transcript is not matched (fails toward quiet).
#
# Output: HOOKS_MODE=enforce → {"decision":"block","reason":"..."} once per session (the stop is held once; stopping
# again goes through). HOOKS_MODE=warn (the first install) → {"systemMessage":"warn-only: ..."} and the same line on
# stderr, never a decision. Internal errors write one line to stderr and exit 0.

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
. "$HOOK_DIR/hook-lib.sh" || exit 0

quiet() { [ -n "${1:-}" ] && echo "review-nudge: $1" >&2; exit 0; }
WINDOW_SECS=7200

IN="$(hk_stdin_file)" || quiet "cannot read the hook input"
trap 'rm -f "$IN"' EXIT
[ "$(hk_parser)" = none ] && quiet "no jq or python3: cannot read the hook input, not nudging"
SA="$(hk_field "$IN" stop_hook_active)"; [ $? -eq 2 ] && quiet "the hook input is not JSON"
[ "$SA" = true ] && exit 0
SID="$(hk_field "$IN" session_id)" || SID=""
[ -n "$SID" ] || SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || quiet "no session id: not nudging"
case "$SID" in *[!A-Za-z0-9_-]*) quiet "session id has characters outside [A-Za-z0-9_-]: not nudging" ;; esac
CWD="$(hk_field "$IN" cwd)" || CWD=""
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$PWD"
TOP="$(hk_toplevel "$CWD")" || exit 0
LTOP="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || LTOP="$TOP"

[ -f "$TOP/$HOOKS_ENV_REL" ] || exit 0
[ -f "$TOP/.claude/skills/review-code/SKILL.md" ] || exit 0
SS="$TOP/.claude/skills/ship/bin/ship-sentinel.sh"
[ -r "$SS" ] || exit 0

MD="$(git -C "$TOP" rev-parse --git-path hooks-review-nudge 2>/dev/null)" || quiet "cannot resolve the git directory"
case "$MD" in /*) ;; *) MD="$TOP/$MD" ;; esac
MARK="$MD/$SID"
[ -f "$MARK" ] && exit 0

# Work to gate: a dirty tree, or a clean one whose HEAD is recent.
if [ -z "$(git -C "$TOP" status --porcelain 2>/dev/null)" ]; then
  HT="$(git -C "$TOP" log -1 --format=%ct 2>/dev/null)"
  case "$HT" in ''|*[!0-9]*) exit 0 ;; esac
  [ $(( $(date +%s) - HT )) -lt "$WINDOW_SECS" ] || exit 0
fi

# Reviewable: ship's review fingerprint differs from the empty change set's.
# The ship scripts refuse a call without their contract version (that guards an agent following stale instructions);
# this read-only hook passes the version the installed bin/ itself declares.
SC="$(sed -n 's/^SKILL_CONTRACT=\([0-9][0-9]*\).*/\1/p' "$TOP/.claude/skills/ship/bin/ship-lib.sh" 2>/dev/null | head -1)"
[ -n "$SC" ] || quiet "ship's contract version is unreadable: not nudging"
FP="$(cd "$TOP" && bash "$SS" --contract="$SC" fingerprint 2>/dev/null)"; FRC=$?
FP="$(printf '%s\n' "$FP" | head -1)"
EMPTY="$( { command -v sha256sum >/dev/null 2>&1 && printf '' | sha256sum; } || { command -v shasum >/dev/null 2>&1 && printf '' | shasum -a 256; } )"
EMPTY="$(printf '%s' "$EMPTY" | cut -c1-64)"
printf '%s' "$FP" | grep -Eqx '[0-9a-f]{64}' || quiet "ship's fingerprint could not be computed: not nudging"
[ "$FRC" -eq 0 ] || quiet "ship's fingerprint failed: not nudging"
[ -n "$EMPTY" ] && [ "$FP" = "$EMPTY" ] && exit 0

# Review missing: only a clean exit 1 arms the nudge.
VOUT="$(cd "$TOP" && bash "$SS" --contract="$SC" verify review 2>/dev/null)"; VRC=$?
[ "$VRC" -eq 1 ] || exit 0
VLINE="$(printf '%s\n' "$VOUT" | grep -E '^REVIEW: ' | head -1)"

# This session wrote a reviewable file (or the scan cannot prove it did not).
SHIPENV="$TOP/.claude/skills/ship/ship.env"
DOCS=""; KEEP=""
if [ -f "$SHIPENV" ]; then
  DOCS="$(hk_kv_get "$SHIPENV" DOCS_ALLOWLIST 2>/dev/null)" || DOCS=""
  KEEP="$(hk_kv_get "$SHIPENV" DOCS_KEEP_BOUND 2>/dev/null)" || KEEP=""
fi
TP="$(hk_field "$IN" transcript_path)" || TP=""
WROTE=unknown
if [ -n "$TP" ] && [ -r "$TP" ]; then
  PATHS="$(grep -F '"tool_use"' "$TP" 2>/dev/null)"; grc=$?
  if [ "$grc" -le 1 ]; then
    case "$(hk_parser)" in
      jq) LIST="$(printf '%s\n' "$PATHS" | jq -R -r 'select(length > 0) | (try fromjson catch "\u0001UNPARSED") |
            if type == "string" then . else (.message.content[]? | objects | select(.type == "tool_use")
              | select(.name == "Edit" or .name == "Write" or .name == "MultiEdit" or .name == "NotebookEdit")
              | (.input.file_path // .input.notebook_path // "")) end' 2>/dev/null)"; prc=$? ;;
      *) LIST="$(printf '%s\n' "$PATHS" | python3 -I -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        print("\x01UNPARSED"); continue
    c = (o.get("message") or {}).get("content") if isinstance(o, dict) else None
    for b in c if isinstance(c, list) else []:
        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
            i = b.get("input") or {}
            print(i.get("file_path") or i.get("notebook_path") or "")
' 2>/dev/null)"; prc=$? ;;
    esac
    if [ "$prc" -eq 0 ] && [ -n "$PATHS" ] && head -n 50 "$TP" | grep -q '^{'; then
      N="$(printf '%s\n' "$LIST" | R1="$TOP/" R2="$LTOP/" DOCS="$DOCS" KEEP="$KEEP" awk '
        $0 == "" { next }
        $0 == "\001UNPARSED" { n++; next }
        { p = $0
          if (substr(p, 1, 1) == "/") {
            if (index(p, ENVIRON["R1"]) == 1) p = substr(p, length(ENVIRON["R1"]) + 1)
            else if (index(p, ENVIRON["R2"]) == 1) p = substr(p, length(ENVIRON["R2"]) + 1)
            else next
          }
          if (ENVIRON["DOCS"] != "" && p ~ ENVIRON["DOCS"] && !(ENVIRON["KEEP"] != "" && p ~ ENVIRON["KEEP"])) next
          n++ }
        END { print n + 0 }')"
      case "$N" in 0) WROTE=no ;; ''|*[!0-9]*) ;; *) WROTE=yes ;; esac
    elif [ "$prc" -eq 0 ] && [ -z "$PATHS" ] && head -n 50 "$TP" | grep -q '^{'; then
      WROTE=no
    fi
  fi
fi
[ "$WROTE" = no ] && exit 0

mkdir -p "$MD" 2>/dev/null && : > "$MARK" 2>/dev/null || echo "review-nudge: cannot write $MARK (the nudge may repeat)" >&2

MSG="This session changed reviewable files and no code review covers the current tree (${VLINE:-verify review: not covered}). Run the review-code skill now, before you report done, hand off, or compact: the ship skill halts without it, and compacting first loses the review's context. This reminder fires once per session; if the review was done another way, or this stop is a genuine wait on the user, stop again."
if [ "$(hk_mode "$TOP")" = warn ]; then
  echo "warn-only: $MSG" >&2
  printf '{"systemMessage":"%s"}\n' "$(printf 'warn-only: %s' "$MSG" | hk_json_escape)"
else
  printf '{"decision":"block","reason":"%s"}\n' "$(printf '%s' "$MSG" | hk_json_escape)"
fi
exit 0
